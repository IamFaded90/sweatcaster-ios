"""Read-only GitHub snapshots and local code retrieval for Agent Workspace."""

from __future__ import annotations

import math
import os
import re
import shutil
import sqlite3
import stat
import struct
import subprocess
import tempfile
from contextlib import closing
from pathlib import Path, PurePosixPath
from threading import RLock


class RepositoryError(ValueError):
    pass


class RepositoryInUse(RepositoryError):
    pass


_SLUG = re.compile(r"[A-Za-z0-9_-]+/[A-Za-z0-9_.-]+", re.ASCII)
_SOURCE = {".swift", ".py", ".js", ".ts", ".tsx", ".rs", ".go", ".java", ".md", ".rst"}


class RepositoryLibrary:
    snapshot_changes = RLock()

    def __init__(self, workspace: Path, database: Path, embed):
        self.workspace = workspace.resolve()
        self.database = database
        self.embed = embed

    def _repo(self, slug: str) -> Path:
        if not _SLUG.fullmatch(slug) or slug.endswith((".", ".git")):
            raise RepositoryError("Brug et GitHub-navn på formen ejer/projekt.")
        owner, name = slug.lower().split("/")
        if name in {".", ".."} or name.startswith("."):
            raise RepositoryError("Projektnavnet er ikke tilladt.")
        target = self.workspace / "repositories" / owner / name
        for path in (target, *target.parents):
            if path == self.workspace:
                break
            if path.is_symlink() or getattr(path, "is_junction", lambda: False)():
                raise RepositoryError("Genveje er ikke tilladt i projekter.")
        if target.resolve() != target:
            raise RepositoryError("Projektstien er ikke tilladt.")
        return target

    @staticmethod
    def _git(cwd: Path, *args: str, timeout: int = 20, index: Path | None = None,
             stdin: bytes | None = None) -> bytes:
        env = {key: value for key, value in os.environ.items() if not key.upper().startswith("GIT_")}
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["GCM_INTERACTIVE"] = "Never"
        if index is not None:
            env["GIT_INDEX_FILE"] = str(index)
        try:
            result = subprocess.run(
                ["git", "-c", "protocol.allow=never", "-c", "protocol.https.allow=always",
                 "-c", "http.followRedirects=false", *args], cwd=cwd, env=env,
                input=stdin, capture_output=True, check=True, timeout=timeout,
            )
        except (OSError, subprocess.SubprocessError) as exc:
            raise RepositoryError("Git-handlingen fejlede. Tjek lokal Git-adgang og projektnavn.") from exc
        return result.stdout

    def clone(self, slug: str) -> str:
        with self.snapshot_changes:
            return self._clone(slug)

    def _clone(self, slug: str) -> str:
        target = self._repo(slug)
        target.parent.mkdir(parents=True, exist_ok=True)
        if target.exists():
            raise RepositoryError("Projektet findes allerede i Agent Workspace.")
        with tempfile.TemporaryDirectory(dir=target.parent) as staging:
            parent = Path(staging)
            self._git(parent, "clone", "--bare", "--depth=1", "--no-tags",
                      f"https://github.com/{slug}.git", "snapshot", timeout=180)
            (parent / "snapshot").rename(target)
        return slug.lower()

    def remove_snapshot(self, slug: str) -> bool:
        if not self.snapshot_changes.acquire(blocking=False):
            raise RepositoryInUse("Vent til PC’en er færdig med Git-arbejdet.")
        try:
            repo = self._repo(slug)
            if not repo.exists():
                return False
            self._head(slug)
            if self._git(repo, "rev-parse", "--is-bare-repository").strip() != b"true":
                raise RepositoryError("Kun FadedAI’s lokale Git-kopi kan slettes her.")
            origin = self._git(repo, "config", "--local", "--get", "remote.origin.url").decode().strip()
            if origin.lower() != f"https://github.com/{slug.lower()}.git":
                raise RepositoryError("Git-kopiens oprindelse matcher ikke det valgte GitHub-projekt.")
            head = self._git(repo, "symbolic-ref", "HEAD").strip()
            refs = self._git(repo, "for-each-ref", "--format=%(refname)").splitlines()
            worktrees = self._git(repo, "worktree", "list", "--porcelain").splitlines()
            if refs != [head] or sum(line.startswith(b"worktree ") for line in worktrees) != 1:
                raise RepositoryInUse("Den lokale kopi har ekstra grene eller arbejdsmapper. Behold kopien.")
            with closing(self._connect()) as db, db:
                db.execute("DELETE FROM code_chunks WHERE repo = ?", (slug.lower(),))
                def delete_read_only_file(unlink, path, error_info):
                    error = error_info[1]
                    if os.name != "nt" or unlink is not os.unlink or not isinstance(error, PermissionError):
                        raise error
                    file = Path(path)
                    flags = file.lstat()
                    if (not stat.S_ISREG(flags.st_mode) or flags.st_mode & stat.S_IWRITE
                            or flags.st_nlink != 1 or not file.resolve().is_relative_to(repo)):
                        raise error
                    file.chmod(flags.st_mode | stat.S_IWRITE)
                    try:
                        unlink(file)
                    except OSError:
                        file.chmod(flags.st_mode)
                        raise

                shutil.rmtree(repo, onerror=delete_read_only_file)
            return True
        finally:
            self.snapshot_changes.release()

    def _head(self, slug: str) -> tuple[Path, str]:
        repo = self._repo(slug)
        if not repo.is_dir():
            raise RepositoryError("Projektet er ikke klonet i Agent Workspace.")
        directory = Path(os.fsdecode(self._git(repo, "rev-parse", "--absolute-git-dir").rstrip(b"\r\n"))).resolve()
        if directory not in {repo, repo / ".git"}:
            raise RepositoryError("Projektet bruger et Git-lager uden for Agent Workspace.")
        revision = self._git(repo, "rev-parse", "--verify", "HEAD^{commit}").decode("ascii").strip()
        return repo, revision

    def refresh(self, slug: str) -> str:
        with self.snapshot_changes:
            return self._refresh(slug)

    def _refresh(self, slug: str) -> str:
        repo, base = self._head(slug)
        if self._git(repo, "rev-parse", "--is-bare-repository").strip() != b"true":
            raise RepositoryError("GitHub-opdatering kræver et isoleret Git-snapshot.")
        ref = self._git(repo, "symbolic-ref", "HEAD").decode("ascii").strip()
        if not ref.startswith("refs/heads/"):
            raise RepositoryError("Git-snapshottet har ingen kildegren.")
        self._git(repo, "fetch", "--no-tags", "--no-recurse-submodules", "--no-auto-maintenance",
                  f"https://github.com/{slug}.git", ref, timeout=180)
        revision = self._git(repo, "rev-parse", "--verify", "FETCH_HEAD^{commit}").decode("ascii").strip()
        if base != revision:
            self._git(repo, "merge-base", "--is-ancestor", base, revision)
            self._git(repo, "-c", "core.hooksPath=" + str(repo / "fadedai-disabled-hooks"),
                      "update-ref", ref, revision, base)
        return revision

    @staticmethod
    def _allowed(path: str) -> bool:
        parts = path.split("/")
        return all(part and not part.startswith(".") and ":" not in part and "\\" not in part
                   and not any(ord(char) < 32 for char in part) for part in parts) and PurePosixPath(path).suffix.lower() in _SOURCE

    def _files(self, repo: Path, revision: str):
        for row in self._git(repo, "ls-tree", "-rlz", revision).split(b"\x00"):
            if not row:
                continue
            meta, raw_path = row.split(b"\t", 1)
            mode, kind, oid, size = meta.split()
            path = raw_path.decode("utf-8", "replace")
            if mode in {b"100644", b"100755"} and kind == b"blob" and int(size) <= 64_000 and self._allowed(path):
                yield path, oid.decode("ascii")

    def read(self, slug: str, path: str) -> str:
        repo, revision = self._head(slug)
        for candidate, oid in self._files(repo, revision):
            if candidate == path:
                return self._git(repo, "cat-file", "blob", oid).decode("utf-8")
        raise RepositoryError("Filen findes ikke blandt de tilladte kildefiler.")

    def _connect(self):
        self.database.parent.mkdir(parents=True, exist_ok=True)
        conn = sqlite3.connect(self.database)
        conn.execute("""CREATE TABLE IF NOT EXISTS code_chunks (
            repo TEXT, revision TEXT, path TEXT, line INTEGER, body TEXT, vector BLOB,
            PRIMARY KEY (repo, path, line))""")
        return conn

    def _vectors(self, values: list[str]) -> list[bytes]:
        result = []
        for vector in self.embed(values):
            norm = math.hypot(*vector)
            if not norm or not math.isfinite(norm):
                raise RepositoryError("Embedding-modellen returnerede en ugyldig vektor.")
            result.append(struct.pack(f"<{len(vector)}f", *(value / norm for value in vector)))
        if len(result) != len(values):
            raise RepositoryError("Embedding-modellen returnerede for få vektorer.")
        return result

    def index(self, slug: str) -> dict:
        with self.snapshot_changes:
            return self._index(slug)

    def _index(self, slug: str) -> dict:
        repo, revision = self._head(slug)
        chunks = []
        for path, oid in self._files(repo, revision):
            try:
                lines = self._git(repo, "cat-file", "blob", oid).decode("utf-8").splitlines()
            except UnicodeDecodeError:
                continue
            for start in range(0, len(lines), 24):
                body = "\n".join(lines[start:start + 24]).strip()[:2400]
                if body:
                    chunks.append((path, start + 1, body))
                if len(chunks) >= 2000:
                    raise RepositoryError("Projektet overstiger grænsen på 2.000 kodeafsnit.")
        rows = []
        for start in range(0, len(chunks), 32):
            batch = chunks[start:start + 32]
            vectors = self._vectors([f"{path}\n{body}" for path, _, body in batch])
            rows.extend((slug.lower(), revision, *chunk, vector) for chunk, vector in zip(batch, vectors))
        with closing(self._connect()) as conn, conn:
            conn.execute("DELETE FROM code_chunks WHERE repo = ?", (slug.lower(),))
            conn.executemany("INSERT INTO code_chunks VALUES (?, ?, ?, ?, ?, ?)", rows)
        return {"revision": revision, "chunks": len(rows)}

    def search(self, slug: str, query: str) -> list[dict]:
        repo, revision = self._head(slug)
        if not query.strip() or len(query) > 1000:
            raise RepositoryError("Søgningen skal være mellem 1 og 1.000 tegn.")
        with closing(self._connect()) as conn:
            rows = conn.execute(
                "SELECT path, line, body, vector FROM code_chunks WHERE repo = ? AND revision = ?",
                (slug.lower(), revision),
            ).fetchall()
        if not rows or self.embed is None:
            return self._search_snapshot(repo, revision, query)
        try:
            packed = self._vectors([query])[0]
        except (RepositoryError, OSError, RuntimeError, ValueError):
            return self._search_snapshot(repo, revision, query)
        shape = f"<{len(packed) // 4}f"
        vector = struct.unpack(shape, packed)
        terms = self._terms(query)
        matches = []
        for path, line, body, candidate in rows:
            if len(candidate) == len(packed):
                score = sum(a * b for a, b in zip(vector, struct.unpack(shape, candidate)))
                exact = sum(term in (path + "\n" + body).casefold() for term in terms)
                matches.append((score + 0.13 * exact, path, line, body))
        return [{"path": path, "line": line, "text": body} for _, path, line, body in sorted(matches, reverse=True)[:5]]

    @staticmethod
    def _terms(query: str) -> list[str]:
        stop = {"der", "som", "med", "til", "fra", "hvor", "hvad", "hvordan", "the", "and", "for", "what", "where", "how"}
        tokens = re.findall(r"[^\W_][\w]{1,63}", query.casefold())
        return list(dict.fromkeys(word for word in tokens if word not in stop))[:6]

    def _search_snapshot(self, repo: Path, revision: str, query: str) -> list[dict]:
        """Get useful results after cloning, even if the local embedding model has not been installed."""
        terms = self._terms(query)
        if not terms:
            return []
        allowed = dict(self._files(repo, revision))
        by_path = {path: (sum(term in path.casefold() for term in terms), 1, "") for path in allowed}
        flags = [flag for term in terms for flag in ("-e", term)]
        patterns = [f":(icase,glob)**/*{suffix}" for suffix in sorted(_SOURCE)]
        try:
            matches = self._git(repo, "grep", "-n", "-i", "-I", "-z", "-F", "--no-textconv", "--max-count=3",
                                *flags, revision, "--", *patterns, timeout=12)
        except RepositoryError:
            matches = b""
        prefix = revision.encode("ascii") + b":"
        for row in matches.splitlines():
            path_data, delimiter, excerpt = row.partition(b"\x00")
            line_data, separator, body = excerpt.partition(b"\x00")
            if not delimiter or not separator or not path_data.startswith(prefix) or not line_data.isdigit():
                continue
            path = path_data[len(prefix):].decode("utf-8", "replace")
            if path not in allowed:
                continue
            line = int(line_data)
            text = body.decode("utf-8", "replace").strip()[:2400]
            path_score = sum(term in path.casefold() for term in terms)
            hits = sum(term in text.casefold() for term in terms)
            score = path_score + 2 * hits
            if score > by_path[path][0]:
                by_path[path] = (score, line, text)
        ranked = sorted(by_path.items(), key=lambda row: (-row[1][0], row[0]))
        return [{"path": path, "line": line, "text": text or path}
                for path, (score, line, text) in ranked[:5] if score > 0]


def mcp_server(library: RepositoryLibrary, **options):
    from mcp.server.fastmcp import FastMCP

    server = FastMCP("FadedAI repository library", **options)

    @server.tool()
    def read_repository_file(repository: str, path: str) -> str:
        """Read a source file from an approved local GitHub snapshot."""
        return library.read(repository, path)

    @server.tool()
    def search_repository(repository: str, query: str) -> list[dict]:
        """Find related source passages in the local repository index."""
        return library.search(repository, query)

    return server


def main() -> None:
    import argparse
    import json

    from assistant_library import open_embedder

    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--workspace", type=Path, required=True)
    parser.add_argument("--database", type=Path, required=True)
    parser.add_argument("--embedding-dir", type=Path, required=True)
    commands = parser.add_subparsers(dest="command", required=True)
    for name in ("clone", "index"):
        commands.add_parser(name).add_argument("repository")
    commands.add_parser("mcp")
    args = parser.parse_args()

    embedder = None

    def embed(values: list[str]):
        nonlocal embedder
        if embedder is None:
            embedder = open_embedder(args.embedding_dir)
        return embedder(values)

    library = RepositoryLibrary(args.workspace, args.database, embed)
    if args.command == "mcp":
        mcp_server(library).run(transport="stdio")
    else:
        operation = library.clone if args.command == "clone" else library.index
        print(json.dumps(operation(args.repository), ensure_ascii=False))


if __name__ == "__main__":
    main()

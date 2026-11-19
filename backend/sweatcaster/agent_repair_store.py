"""Persistent repair receipts and isolated copies; approval reuses CodeBatch."""

from base64 import b64encode
from contextlib import closing
import difflib
from hashlib import sha256
from io import BytesIO
import json
import os
from pathlib import Path
import re
import shutil
import sqlite3
from threading import RLock
from tempfile import TemporaryDirectory
from time import time
from uuid import UUID
from zipfile import ZipFile, ZIP_DEFLATED

from sweatcaster.agent_repair_evidence import mac_handoff, redact
from sweatcaster.repository_library import RepositoryError

DEMO = "fadedai/repair-demo"
DEMO_FILES = {
    "prices.py": "def total_after_discount(price, percent):\n    if not 0 <= percent <= 100:\n        raise ValueError('percent')\n    return round(price * percent / 100, 2)\n",
    "test_prices.py": "import unittest\nfrom prices import total_after_discount\n\nclass PricesTest(unittest.TestCase):\n    def test_twenty_percent(self):\n        self.assertEqual(total_after_discount(100, 20), 80)\n    def test_no_discount(self):\n        self.assertEqual(total_after_discount(250, 0), 250)\n    def test_full_discount(self):\n        self.assertEqual(total_after_discount(100, 100), 0)\n",
}


def process_stamp(pid):
    """Read process identity only; never send a signal or terminate a process."""
    if type(pid) is not int or pid <= 0:
        return None
    if os.name == "nt":
        import ctypes
        from ctypes import wintypes
        kernel = ctypes.WinDLL("kernel32", use_last_error=True)
        kernel.OpenProcess.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
        kernel.OpenProcess.restype = wintypes.HANDLE
        kernel.CloseHandle.argtypes = [wintypes.HANDLE]
        kernel.GetProcessTimes.argtypes = [wintypes.HANDLE] + [ctypes.POINTER(wintypes.FILETIME)] * 4
        handle = kernel.OpenProcess(0x1000, False, pid)
        if not handle:
            return "unknown" if ctypes.get_last_error() == 5 else None
        try:
            values = [wintypes.FILETIME() for _ in range(4)]
            if not kernel.GetProcessTimes(handle, *(ctypes.byref(value) for value in values)):
                return "unknown"
            return str((values[0].dwHighDateTime << 32) | values[0].dwLowDateTime)
        finally:
            kernel.CloseHandle(handle)
    try:
        return Path(f"/proc/{pid}/stat").read_text().rpartition(")")[2].split()[19]
    except (OSError, IndexError):
        return None


def identifier(raw):
    try:
        if not isinstance(raw, str) or len(raw) != 36:
            raise ValueError
        return str(UUID(raw))
    except ValueError as exc:
        raise ValueError("Opgaven har ikke et gyldigt id.") from exc


class RepairStore:
    def __init__(self, root, batch):
        self.root = Path(root).resolve() / "agent-repair"
        self.root.mkdir(parents=True, exist_ok=True)
        self.path = self.root / "repairs.sqlite3"
        self.batch = batch
        self.lock = RLock()
        with self.db() as db, db:
            db.execute("CREATE TABLE IF NOT EXISTS repairs(id TEXT PRIMARY KEY,body TEXT NOT NULL,created REAL NOT NULL)")

    def db(self):
        return closing(sqlite3.connect(self.path, timeout=10))

    def put(self, job):
        with self.lock, self.db() as db, db:
            db.execute("INSERT INTO repairs VALUES (?,?,?) ON CONFLICT(id) DO UPDATE SET body=excluded.body",
                       (identifier(job["id"]), json.dumps(job, ensure_ascii=False), job["created"]))

    def get(self, raw):
        with self.db() as db:
            row = db.execute("SELECT body FROM repairs WHERE id=?", (identifier(raw),)).fetchone()
        if row is None:
            raise ValueError("Reparationsopgaven findes ikke længere.")
        return json.loads(row[0])

    def jobs(self):
        with self.db() as db:
            rows = db.execute("SELECT body FROM repairs ORDER BY created DESC LIMIT 20").fetchall()
        return [json.loads(row[0]) for row in rows]

    def recover(self):
        with self.lock:
            for job in self.jobs():
                if job["state"] not in {"reproducing", "fixing", "testing"}:
                    continue
                current = process_stamp(job.get("workerPID"))
                if current == "unknown" or current is not None and current == job.get("workerStamp"):
                    continue
                job.update(state="interrupted", summary="PC-serveren blev stoppet under arbejdet. Beviser og kopier er bevaret; genoptag kontrollen før godkendelse.")
                self.put(job)

    @staticmethod
    def public(job):
        return {key: job.get(key) for key in ("id", "repository", "state", "summary", "steps", "evidence", "before", "after", "diff", "attempts", "baseRevision", "branch", "commit", "handoff", "macReport")}

    def demo(self):
        library = self.batch.repository
        with library.snapshot_changes:
            repo = library._repo(DEMO)
            if repo.exists():
                return
            repo.parent.mkdir(parents=True, exist_ok=True)
            git = library._git
            git(repo.parent, "init", "--bare", str(repo))
            git(repo, "symbolic-ref", "HEAD", "refs/heads/main")
            entries = []
            for name, source in DEMO_FILES.items():
                blob = git(repo, "hash-object", "-w", "--stdin", stdin=source.encode()).decode().strip()
                entries.append(f"100644 blob {blob}\t{name}\n")
            tree = git(repo, "mktree", stdin="".join(entries).encode()).decode().strip()
            commit = git(repo, "-c", "user.name=FadedAI", "-c", "user.email=fadedai@localhost", "-c", "commit.gpgsign=false",
                         "commit-tree", tree, "-m", "Local FadedAI repair demonstration").decode().strip()
            git(repo, "update-ref", "refs/heads/main", commit)

    def projects(self):
        result = [{"id": DEMO, "title": "Prøv: ret en forkert rabat", "files": [{"id": name, "test": name.startswith("test_")} for name in DEMO_FILES]}]
        folder = self.batch.repository.workspace / "repositories"
        candidates = sorted(folder.glob("*/*"))[:20] if folder.is_dir() else []
        for path in candidates:
            slug = path.parent.name + "/" + path.name
            if slug == DEMO:
                continue
            try:
                repo, revision = self.batch.repository._head(slug)
                files = [{"id": name, "test": Path(name).name.startswith("test_") or Path(name).stem.endswith("_test")}
                         for name, _blob in self.batch.repository._files(repo, revision)
                         if name.endswith((".py", ".swift")) and len(name) <= 240][:600]
                if len(json.dumps(result + [{"id": slug, "title": slug, "files": files}]).encode("utf-8")) > 850000:
                    break
                result.append({"id": slug, "title": slug, "files": files})
            except RepositoryError:
                continue
        return result

    def snapshot(self, slug, selected):
        if slug == DEMO:
            self.demo()
        library = self.batch.repository
        with library.snapshot_changes:
            repo, revision = library._head(slug)
            blobs = dict(library._files(repo, revision))
            if (not isinstance(selected, list) or len(selected) > 5 or any(not isinstance(name, str) for name in selected)
                    or len(set(selected)) != len(selected)):
                raise ValueError("Vælg højst fem kildefiler.")
            files = {}
            for name in selected:
                if name not in blobs or not name.endswith((".py", ".swift")):
                    raise ValueError("Vælg en Python- eller Swift-kildefil fra projektet.")
                source = library._git(repo, "cat-file", "blob", blobs[name]).decode("utf-8")
                if len(source) > 16000 or redact(source) != source:
                    raise ValueError("En kildefil er for stor eller indeholder noget, der ligner en adgangsnøgle. Vælg en anden fil.")
                files[name] = source
            names = library._git(repo, "ls-tree", "-rz", "--name-only", revision)
            if len(names) > 2_000_000:
                raise ValueError("Projektets filoversigt er for stor.")
            paths = names.decode("utf-8").split("\x00")
        return revision, files, paths

    def copy(self, job, stage, files):
        directory = self.root / "copies" / identifier(job["id"]) / stage
        for name, content in files.items():
            if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*(?:/[A-Za-z_][A-Za-z0-9_]*)*[.](?:py|swift)", name):
                raise ValueError("Arbejdskopien indeholder et ugyldigt filnavn.")
            file = directory / name
            file.parent.mkdir(parents=True, exist_ok=True)
            if file.resolve() != file:
                raise ValueError("Arbejdskopien må ikke bruge genveje.")
            file.write_text(content, encoding="utf-8")

    def proposal(self, job, original, changes, *, verified=True):
        changes = changes | job.get("generatedTests", {})
        diff = "".join("".join(line if line.endswith("\n") else line + "\n\\ No newline at end of file\n" for line in difflib.unified_diff(
            original.get(name, "").splitlines(keepends=True), source.splitlines(keepends=True),
            fromfile="a/" + name if name in original else "/dev/null", tofile="b/" + name))
                       for name, source in changes.items() if source != original.get(name, ""))
        if not diff:
            raise ValueError("Der blev ikke lavet nogen ændring.")
        job.update(diff=diff, batchID=UUID(job["id"]).hex)
        result = {"base_revision": job["baseRevision"], "diff": diff,
                  "tests": [job["after"]["command"]] if verified else job["macTestPlan"],
                  "checks": ["Samme frosne test fejlede før rettelsen og bestod efter rettelsen.",
                             "Testhash: " + job["after"]["testDigest"]] if verified else ["Swift-forslag. Ingen Apple-bygning eller runtime-test er kørt."],
                  "requires_approval": True,
                  "repair_evidence": {"id": job["id"], "before": job["before"], "after": job["after"]}}
        with closing(self.batch._connect()) as db, db:
            db.execute("INSERT INTO code_batch (id,repo,goal,files,status,result,created,updated,priority) VALUES(?,?,?,?,?,?,?,?,0)",
                       (job["batchID"], job["repository"], job["evidence"]["report"][:1000], json.dumps(list(changes)),
                        "review", json.dumps(result), job["created"], time()))

    def approve(self, raw):
        with self.lock:
            job = self.get(raw)
            if job["state"] in {"approved", "approvedForMac"}:
                return job
            on_mac = job["state"] == "reviewOnMac"
            if not on_mac and (job["state"] != "review" or not (job.get("after") or {}).get("passed")):
                raise ValueError("Kun en gennemprøvet ændring kan godkendes.")
            result = self.batch.apply(job["batchID"])
            job.update(state="approvedForMac" if on_mac else "approved", branch=result["branch"], commit=result["commit"],
                       summary="Forslaget er godkendt på en separat lokal gren til Mac-test. Apple-bygning og test mangler stadig." if on_mac
                       else "Den testede ændring er godkendt på en separat lokal gren. Der er ikke pushet eller bygget en IPA.")
            job["handoff"] = mac_handoff(job["repository"], job["baseRevision"], job["paths"], job["evidence"],
                                           approved=job["commit"], approved_branch=job["branch"], patch=job["diff"],
                                           test_digest=(job.get("after") or {}).get("testDigest"))
            self.put(job)
            return job

    def bundle(self, raw):
        job = self.get(raw)
        if not job.get("handoff"):
            raise ValueError("Godkend ændringen først, eller opret en Mac-opgave fra iPhone-loggen.")
        if job.get("batchID") and job["state"] not in {"approved", "approvedForMac"}:
            raise ValueError("Godkend forslaget, før ændringen pakkes til Mac-test.")
        content = BytesIO()
        with ZipFile(content, "w", compression=ZIP_DEFLATED) as archive:
            if job.get("commit"):
                branch = job.get("branch", "")
                if not re.fullmatch(r"fadedai/review-[a-f0-9]{32}", branch) or not re.fullmatch(r"[a-f0-9]{40,64}", job["baseRevision"]):
                    raise ValueError("Den lokale godkendte gren kunne ikke bekræftes.")
                repo, _revision = self.batch.repository._head(job["repository"])
                # Git-for-Windows bundle can still fail on long loose-ref paths.
                # A short-lived ref repository reads existing objects via alternates,
                # exports only the delta, and leaves no export file behind.
                with TemporaryDirectory(prefix="fadedai-repair-export-") as staging:
                    short = Path(staging).resolve()
                    git = self.batch.repository._git
                    git(short, "init", "--bare", ".")
                    (short / "objects/info/alternates").write_bytes(((repo / "objects").as_posix() + "\n").encode("utf-8"))
                    git(short, "update-ref", "refs/heads/" + branch, job["commit"])
                    delta = git(short, "bundle", "create", "-", branch, "^" + job["baseRevision"])
                if len(delta) > 500000:
                    raise ValueError("Den godkendte ændringspakke er for stor til appen. Den lokale gren er bevaret på PC’en: " + branch)
                archive.writestr("approved-change.bundle", delta)
            archive.writestr("handoff.json", json.dumps(job["handoff"], ensure_ascii=False, indent=2))
            archive.writestr("evidence.json", json.dumps(job["evidence"], ensure_ascii=False, indent=2))
            archive.writestr("change.patch", job.get("diff", ""))
            for name, source in job.get("frozenTests", {}).items():
                archive.writestr("reproduction/" + name, source)
            archive.writestr("README.txt", "FadedAI reparationsopgave\n" + job["summary"] + "\n\n" + "\n".join(job["handoff"]["steps"]) +
                            "\n\nImport af den præcise lokale revision (kræver grundrevisionen):\n" + json.dumps(job["handoff"].get("sourceCommands", []), indent=2) +
                            "\n\nApple-kommandoer (argumenter, som Mac-arbejderen skal køre):\n" + json.dumps(job["handoff"]["commands"], indent=2) +
                            "\nDette er en fejlrapport/ændring til en Mac, ikke en IPA.\n")
        packet = {"name": "FadedAI-reparation-" + job["id"] + ".zip", "data": b64encode(content.getvalue()).decode(), "handoff": job["handoff"]}
        if len(content.getvalue()) > 700000 or len(json.dumps(packet).encode("utf-8")) > 1_000_000:
            raise ValueError("Rapportpakken er for stor til appen. Opgaven og den godkendte lokale gren er bevaret på PC’en.")
        return packet

    def remove(self, raw):
        with self.lock:
            job = self.get(raw)
            if job["state"] in {"reproducing", "fixing", "testing"}:
                raise ValueError("Vent på kontrollen, før rapporten slettes.")
            if job.get("batchID") and job["state"] not in {"approved", "approvedForMac"}:
                try:
                    self.batch.reject(job["batchID"])
                except RepositoryError:
                    pass
            folder = self.root / "copies" / identifier(raw)
            if folder.exists():
                if folder.resolve() != folder or not folder.is_relative_to(self.root):
                    raise ValueError("Rapportmappen kunne ikke bekræftes.")
                shutil.rmtree(folder)
            with self.db() as db, db:
                db.execute("DELETE FROM repairs WHERE id=?", (job["id"],))
        return {"deleted": True}

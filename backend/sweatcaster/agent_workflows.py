"""Local specialist dispatch, semantic memory and daily repository indexing."""

from __future__ import annotations

import hashlib
import json
import sqlite3
import struct
import tempfile
import threading
from contextlib import closing
from datetime import datetime
from pathlib import Path
from zoneinfo import ZoneInfo

from sweatcaster.repository_library import RepositoryError, RepositoryLibrary


class AgentWorkflows:
    def __init__(self, root: Path, library: RepositoryLibrary, observe=lambda *_: None):
        root.mkdir(parents=True, exist_ok=True)
        self.root, self.library, self.observe = root, library, observe
        with closing(self._connect()) as db, db:
            db.execute("""CREATE TABLE IF NOT EXISTS memories (
                id TEXT PRIMARY KEY, scope TEXT NOT NULL, kind TEXT NOT NULL,
                body TEXT NOT NULL, vector BLOB NOT NULL)""")
            db.execute("""CREATE TABLE IF NOT EXISTS routine_runs (
                id TEXT PRIMARY KEY, status TEXT NOT NULL)""")

    def _connect(self):
        return sqlite3.connect(self.root / "workflows.sqlite3", timeout=5)

    def remember(self, scope: str, kind: str, text: str) -> str:
        scope, text = scope.strip().lower(), text.strip()
        if kind not in {"preference", "architecture"} or not 1 <= len(text) <= 1000:
            raise RepositoryError("Vælg præference eller arkitektur, og angiv højst 1.000 tegn.")
        if scope != "global":
            self.library._head(scope)
        if scope == "global" and kind != "preference":
            raise RepositoryError("Arkitektur skal tilhøre et bestemt repo.")
        key = hashlib.sha256(json.dumps([scope, kind, text]).encode()).hexdigest()
        vector = self.library._vectors([text])[0]
        with closing(self._connect()) as db, db:
            db.execute("BEGIN IMMEDIATE")
            if db.execute("SELECT count(*) FROM memories").fetchone()[0] >= 2000:
                if not db.execute("SELECT 1 FROM memories WHERE id=?", (key,)).fetchone():
                    raise RepositoryError("Hukommelsen er fuld.")
            db.execute("INSERT OR REPLACE INTO memories VALUES (?, ?, ?, ?, ?)", (key, scope, kind, text, vector))
        return key

    def memories(self) -> list[dict]:
        with closing(self._connect()) as db:
            return [{"id": key, "scope": scope, "kind": kind, "text": body}
                    for key, scope, kind, body in db.execute("SELECT id, scope, kind, body FROM memories ORDER BY id")]

    def forget(self, key: str) -> bool:
        with closing(self._connect()) as db, db:
            return db.execute("DELETE FROM memories WHERE id=?", (key,)).rowcount == 1

    def recall(self, repo: str, goal: str) -> list[str]:
        with closing(self._connect()) as db:
            rows = db.execute("SELECT body, vector FROM memories WHERE scope IN ('global', ?)", (repo,)).fetchall()
        if not rows:
            return []
        query = self.library._vectors([goal])[0]
        shape = f"<{len(query) // 4}f"
        vector = struct.unpack(shape, query)
        scored = [(sum(a * b for a, b in zip(vector, struct.unpack(shape, item))), body)
                  for body, item in rows if len(query) == len(item)]
        return [body for score, body in sorted(scored, reverse=True)[:3] if score >= 0.25]

    def research(self, job: str, repo: str, goal: str) -> dict:
        self.observe(job, "researcher", "Research: søger i lokal kode", "running")
        try:
            hits = self.library.search(repo, goal)
            notes = self.recall(repo, goal)
        except Exception:
            self.observe(job, "researcher", "Research: lokalt indeks kunne ikke læses", "failed")
            return {}
        self.observe(job, "researcher", "Research: lokal recherche gennemført", "completed")
        return {"source_references": [{"path": hit["path"], "line": hit["line"], "text": hit["text"][:180]}
                                       for hit in hits[:3]], "preferences": [note[:200] for note in notes]}

    def validate(self, job: str, changes: dict) -> list[str]:
        self.observe(job, "manager", "Test: kontrollerer syntaks og afgrænsning", "running")
        checks = []
        try:
            for path, source in changes.items():
                if path.endswith(".py"):
                    compile(source, path, "exec")
                    checks.append(f"Python-syntaks kontrolleret: {path}")
                elif path.endswith(".json"):
                    json.loads(source)
                    checks.append(f"JSON-format kontrolleret: {path}")
        except (SyntaxError, ValueError):
            self.observe(job, "manager", "Test: foreslået kode kunne ikke læses", "failed")
            raise
        self.observe(job, "manager", "Test: forslag klar til gennemgang", "completed")
        return checks

    def routines(self) -> list[dict]:
        try:
            with (self.root / "routines.json").open("rb") as source:
                raw = source.read(16385)
            routines = json.loads(raw) if len(raw) <= 16384 else []
        except (OSError, ValueError, RecursionError):
            return []
        return [row for row in routines[:10] if self._valid_routine(row)] if isinstance(routines, list) else []

    @staticmethod
    def _valid_routine(row) -> bool:
        return (isinstance(row, dict) and set(row) == {"action", "repo", "hour"}
                and row["action"] in ("reindex_repository", "refresh_repository")
                and isinstance(row["repo"], str) and 1 <= len(row["repo"]) <= 150
                and type(row["hour"]) is int and 0 <= row["hour"] <= 23)

    def configure_routines(self, routines: list[dict]) -> None:
        if len(routines) > 10 or not all(self._valid_routine(row) for row in routines):
            raise RepositoryError("Angiv op til 10 Git-rutiner med gyldig time og repo.")
        for row in routines:
            self.library._head(row["repo"])
        pairs = {(row["repo"].lower(), row["action"]) for row in routines}
        if len(pairs) != len(routines):
            raise RepositoryError("Samme handling må kun planlægges én gang pr. repo.")
        with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", dir=self.root, delete=False) as file:
            temp = Path(file.name)
            json.dump(routines, file)
        try:
            temp.replace(self.root / "routines.json")
        finally:
            temp.unlink(missing_ok=True)

    @staticmethod
    def _run_key(local: datetime, routine: dict) -> str:
        suffix = ":refresh" if routine["action"] == "refresh_repository" else ""
        return hashlib.sha256(f"{local.date()}:{routine['repo'].strip().lower()}{suffix}".encode()).hexdigest()

    def routine_status(self, now: datetime) -> list[dict]:
        local = now.astimezone(ZoneInfo("Europe/Copenhagen"))
        with closing(self._connect()) as db:
            entries = []
            for routine in self.routines():
                row = db.execute("SELECT status FROM routine_runs WHERE id=?", (self._run_key(local, routine),)).fetchone()
                entries.append({**routine, "today": row[0] if row else "waiting"})
            return entries

    def run_due(self, now: datetime) -> None:
        local = now.astimezone(ZoneInfo("Europe/Copenhagen"))
        for routine in self.routines():
            repo, hour, action = (routine[key] for key in ("repo", "hour", "action"))
            if hour > local.hour:
                continue
            key = self._run_key(local, routine)
            with closing(self._connect()) as db, db:
                claimed = db.execute("INSERT OR IGNORE INTO routine_runs VALUES (?, 'running')", (key,)).rowcount
            if not claimed:
                continue
            self.observe(key, "researcher", "Planlagt lokal indeksering", "running")
            try:
                if action == "refresh_repository":
                    self.library.refresh(repo)
                self.library.index(repo)
                state = "completed"
            except Exception:
                state = "failed"
            with closing(self._connect()) as db, db:
                db.execute("UPDATE routine_runs SET status=? WHERE id=?", (state, key))
            self.observe(key, "researcher", "Planlagt lokal indeksering", state)


def configured_workflows(settings, workspace: Path):
    from assistant_library import open_embedder
    from sweatcaster.coord import ModelCoord
    from sweatcaster.documents import asset_embedding_dir

    root = settings.output_root / "agent-workflows"
    index = settings.output_root.parent / "assistant-data" / "code-index.sqlite"
    coord = ModelCoord(settings.output_root / "state.sqlite3")
    lock = threading.Lock()
    model = None

    def embed(texts):
        nonlocal model
        with lock:
            if model is None:
                model = open_embedder(asset_embedding_dir(settings))
            return model(texts)

    def observe(job, agent, text, status):
        try:
            coord.observe_tool(f"workflow:{job}:{agent}:{text.split(':')[0]}", agent, "workflow", text, status, settings.token)
        except sqlite3.Error:
            pass

    return AgentWorkflows(root, RepositoryLibrary(workspace, index, embed), observe)

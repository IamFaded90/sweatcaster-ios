"""On-demand computers for Adam and Eva.

The phone keeps the pairing token. This module stores tasks and files, and asks the local
AIO Computer containers to show a desktop. It does not copy Ollama models.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sqlite3
import subprocess
import threading
import time
import urllib.error
import urllib.request
from contextlib import closing
from pathlib import Path
from uuid import uuid4

TOKEN = re.compile(r"[A-Za-z0-9-]{8,80}")
FILE_NAME = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,79}")
LIVE_MARKERS = ("fadedai-checkpoint-20261107", "AppData\\Local\\SweatCaster\\app", "AppData/Local/SweatCaster/app")


class BotComputerError(ValueError):
    pass


class IsolationError(BotComputerError):
    pass


class ApprovalError(BotComputerError):
    pass


def read_env_file(path: Path) -> dict[str, str]:
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except OSError:
        return {}
    values = {}
    for line in lines:
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        key = key.strip()
        if key:
            values[key] = value.strip()
    return values


def setting_value(name: str, file_values: dict[str, str]) -> str:
    current = os.environ.get(name, "").strip()
    return current or file_values.get(name, "").strip()


def slug_for(name: str) -> str | None:
    key = name.strip().casefold()
    if key in {"adam", "eva"}:
        return key
    return None


def _check_token(value: str) -> str:
    if not isinstance(value, str) or not TOKEN.fullmatch(value):
        raise BotComputerError("Identiteten er ikke gyldig.")
    return value


def _check_path(value: str) -> str:
    if not isinstance(value, str) or not FILE_NAME.fullmatch(value) or ".." in value:
        raise BotComputerError("Filnavnet er ikke gyldigt.")
    return value


class UnavailableDocker:
    def online(self) -> bool:
        return False

    def start(self, slug: str) -> None:
        raise BotComputerError("Docker er offline")

    def restart(self, slug: str) -> None:
        raise BotComputerError("Docker er offline")

    def show(self, slug: str, filename: str) -> None:
        raise BotComputerError("Docker er offline")

    def click(self, slug: str, x: int, y: int) -> None:
        raise BotComputerError("Docker er offline")

    def screenshot(self, slug: str) -> bytes:
        raise BotComputerError("Docker er offline")

    def stats(self) -> str:
        return ""


class MemoryDocker(UnavailableDocker):
    def __init__(self, online: bool = True):
        self.is_online = online
        self.started: list[str] = []
        self.shown: list[tuple[str, str]] = []
        self.clicks: list[tuple[str, int, int]] = []
        self.restarted: list[str] = []

    def online(self) -> bool:
        return self.is_online

    def start(self, slug: str) -> None:
        if not self.is_online:
            raise BotComputerError("Docker er offline")
        self.started.append(slug)

    def restart(self, slug: str) -> None:
        self.restarted.append(slug)

    def show(self, slug: str, filename: str) -> None:
        self.shown.append((slug, filename))

    def click(self, slug: str, x: int, y: int) -> None:
        self.clicks.append((slug, x, y))

    def screenshot(self, slug: str) -> bytes:
        return b"\x89PNG\r\n\x1a\n" + slug.encode()

    def stats(self) -> str:
        return ""


class ComposeControl:
    """Talks to Docker Desktop. Containers stay on 127.0.0.1. The phone never uses these ports."""

    def __init__(self, compose_file: Path, root: Path):
        self.compose_file = compose_file
        self.root = root

    def online(self) -> bool:
        try:
            subprocess.run(["docker", "info"], check=True, capture_output=True, timeout=20)
            return True
        except (OSError, subprocess.SubprocessError):
            return False

    def start(self, slug: str) -> None:
        self._compose(["--profile", slug, "up", "-d", slug], timeout=180)
        self.root.joinpath("desks", slug, "files").mkdir(parents=True, exist_ok=True)

    def restart(self, slug: str) -> None:
        self._compose(["restart", slug], timeout=180)

    def stats(self) -> str:
        completed = subprocess.run(
            ["docker", "stats", "--no-stream", "--format", "{{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}"],
            check=True, capture_output=True, text=True, timeout=40,
        )
        lines = [line for line in completed.stdout.splitlines() if line.startswith("fadedai-bot-")]
        return "\n".join(lines)

    def show(self, slug: str, filename: str) -> None:
        safe = _check_path(filename)
        self._api(slug, "POST", "/v2/commands", {"command": f"xdg-open /home/sandbox/fadedai/{safe}"})

    def click(self, slug: str, x: int, y: int) -> None:
        self._api(slug, "POST", "/v2/computer/actions", {"action_type": "CLICK", "x": x, "y": y})

    def screenshot(self, slug: str) -> bytes:
        body = self._api(slug, "GET", "/v2/computer/screenshot", None)
        if not body.startswith(b"\x89PNG"):
            raise BotComputerError("Skrivebordet kunne ikke vises.")
        return body

    def _compose(self, args: list[str], timeout: int) -> None:
        env_file = self.root / ".env"
        command = ["docker", "compose", "--env-file", str(env_file), "-f", str(self.compose_file), *args]
        subprocess.run(command, check=True, cwd=self.compose_file.parent, timeout=timeout)

    def credential(self, slug: str) -> str:
        key_name = "ADAM_AIO_KEY" if slug == "adam" else "EVA_AIO_KEY"
        return setting_value(key_name, read_env_file(self.root / ".env"))

    def _api(self, slug: str, method: str, path: str, payload: dict | None) -> bytes:
        port = 8091 if slug == "adam" else 8092
        key = self.credential(slug)
        if not key:
            raise BotComputerError("Computerens nøgle mangler i data-mappen.")
        data = None if payload is None else json.dumps(payload).encode()
        request = urllib.request.Request(f"http://127.0.0.1:{port}{path}", data=data, method=method)
        request.add_header("Authorization", "Bearer " + key)
        if data:
            request.add_header("Content-Type", "application/json")
        try:
            with urllib.request.urlopen(request, timeout=20) as response:
                return response.read()
        except urllib.error.URLError as exc:
            raise BotComputerError("Docker er offline") from exc


class BotComputerOffice:
    def __init__(self, root: Path, docker=None, complete=None, clock=None):
        self.root = Path(root)
        self.root.mkdir(parents=True, exist_ok=True)
        self.docker = docker or UnavailableDocker()
        self.complete = complete or local_report
        self.clock = clock or time.time
        self.lock = threading.Lock()
        self.link = "dockerOffline"
        with self.lock:
            self._migrate()
            self._recover()

    def _connect(self):
        db = sqlite3.connect(self.root / "office.sqlite3", timeout=10)
        db.row_factory = sqlite3.Row
        return db

    def _migrate(self) -> None:
        with closing(self._connect()) as db, db:
            db.execute("""CREATE TABLE IF NOT EXISTS tasks (
                id TEXT PRIMARY KEY, bot_id TEXT NOT NULL, bot_name TEXT NOT NULL,
                idempotency_key TEXT NOT NULL UNIQUE, retry_key TEXT, instruction TEXT NOT NULL,
                input_path TEXT, status TEXT NOT NULL, result_text TEXT, result_path TEXT,
                error TEXT, attempt INTEGER NOT NULL, created REAL NOT NULL, updated REAL NOT NULL)""")
            db.execute("""CREATE TABLE IF NOT EXISTS files (
                owner_id TEXT NOT NULL, owner_name TEXT NOT NULL, path TEXT NOT NULL,
                text TEXT NOT NULL, shared_with TEXT NOT NULL, PRIMARY KEY (owner_id, path))""")

    def _recover(self) -> None:
        with closing(self._connect()) as db, db:
            db.execute(
                "UPDATE tasks SET status='failed', error=?, updated=? WHERE status='running'",
                ("Arbejdet blev afbrudt. Prøv igen.", self.clock()),
            )

    def probe(self) -> str:
        self.link = "online" if self.docker.online() else "dockerOffline"
        return self.link

    def submit(self, bot_id: str, name: str, instruction: str, key: str, input_path: str | None = None) -> dict:
        bot_id, key = _check_token(bot_id), _check_token(key)
        name = name.strip()
        instruction = instruction.strip()
        if not 1 <= len(name) <= 40 or not 1 <= len(instruction) <= 1000:
            raise BotComputerError("Angiv en kort opgave.")
        if input_path is not None:
            input_path = _check_path(input_path)
            self.open_file(bot_id, bot_id, input_path)
        with self.lock, closing(self._connect()) as db, db:
            db.execute("BEGIN IMMEDIATE")
            row = db.execute("SELECT * FROM tasks WHERE idempotency_key=?", (key,)).fetchone()
            if row:
                task = dict(row)
            else:
                now = self.clock()
                task = {
                    "id": uuid4().hex, "bot_id": bot_id, "bot_name": name, "idempotency_key": key,
                    "retry_key": None, "instruction": instruction, "input_path": input_path,
                    "status": "waiting", "result_text": None, "result_path": None, "error": None,
                    "attempt": 1, "created": now, "updated": now,
                }
                db.execute(
                    """INSERT INTO tasks VALUES
                    (:id,:bot_id,:bot_name,:idempotency_key,:retry_key,:instruction,:input_path,:status,
                     :result_text,:result_path,:error,:attempt,:created,:updated)""",
                    task,
                )
        task["link"] = self.probe()
        return task

    def task(self, task_id: str) -> dict:
        with self.lock, closing(self._connect()) as db:
            row = db.execute("SELECT * FROM tasks WHERE id=?", (task_id,)).fetchone()
        if row is None:
            raise BotComputerError("Opgaven findes ikke.")
        return dict(row)

    def tasks_for(self, bot_id: str) -> list[dict]:
        _check_token(bot_id)
        with self.lock, closing(self._connect()) as db:
            rows = db.execute("SELECT * FROM tasks WHERE bot_id=? ORDER BY created DESC", (bot_id,)).fetchall()
        return [dict(row) for row in rows]

    def cancel(self, task_id: str) -> dict:
        with self.lock, closing(self._connect()) as db, db:
            db.execute("BEGIN IMMEDIATE")
            row = db.execute("SELECT * FROM tasks WHERE id=?", (task_id,)).fetchone()
            if row is None:
                raise BotComputerError("Opgaven findes ikke.")
            if row["status"] in {"waiting", "running"}:
                db.execute("UPDATE tasks SET status='cancelled', updated=? WHERE id=?", (self.clock(), task_id))
            elif row["status"] != "cancelled":
                raise BotComputerError("Opgaven kan ikke annulleres.")
        return self.task(task_id)

    def retry(self, task_id: str, retry_key: str) -> dict:
        retry_key = _check_token(retry_key)
        with self.lock, closing(self._connect()) as db, db:
            db.execute("BEGIN IMMEDIATE")
            row = db.execute("SELECT * FROM tasks WHERE id=?", (task_id,)).fetchone()
            if row is None:
                raise BotComputerError("Opgaven findes ikke.")
            if row["retry_key"] == retry_key or row["status"] in {"waiting", "running"}:
                task = dict(row)
            elif row["status"] != "failed":
                raise BotComputerError("Kun en mislykket opgave kan prøves igen.")
            else:
                now = self.clock()
                db.execute(
                    """UPDATE tasks SET status='waiting', attempt=attempt+1, retry_key=?, error=NULL,
                       result_text=NULL, result_path=NULL, updated=? WHERE id=?""",
                    (retry_key, now, task_id),
                )
                task = dict(db.execute("SELECT * FROM tasks WHERE id=?", (task_id,)).fetchone())
        task["link"] = self.probe()
        return task

    def write_file(self, owner_id: str, owner_name: str, path: str, text: str) -> dict:
        owner_id, path = _check_token(owner_id), _check_path(path)
        owner_name = owner_name.strip()
        if not isinstance(text, str) or len(text) > 100_000 or not 1 <= len(owner_name) <= 40:
            raise BotComputerError("Filen kan ikke gemmes.")
        with self.lock, closing(self._connect()) as db, db:
            current = db.execute("SELECT shared_with FROM files WHERE owner_id=? AND path=?", (owner_id, path)).fetchone()
            shared = current["shared_with"] if current else "[]"
            db.execute(
                "INSERT OR REPLACE INTO files VALUES (?,?,?,?,?)",
                (owner_id, owner_name, path, text, shared),
            )
        self._write_desk(owner_name, path, text)
        return self._file_row(owner_id, path)

    def open_file(self, reader_id: str, owner_id: str, path: str) -> dict:
        reader_id, owner_id, path = _check_token(reader_id), _check_token(owner_id), _check_path(path)
        row = self._file_row(owner_id, path)
        shared = row["shared_with"]
        if reader_id != owner_id and reader_id not in shared:
            raise IsolationError("Den fil er ikke delt.")
        return row

    def share(self, owner_id: str, path: str, reader_id: str, approved: bool) -> dict:
        if approved is not True:
            raise ApprovalError("Deling kræver en eksplicit godkendelse.")
        reader_id = _check_token(reader_id)
        row = self.open_file(owner_id, owner_id, path)
        if reader_id == owner_id:
            raise BotComputerError("Vælg en anden bot.")
        shared = list(row["shared_with"])
        if reader_id not in shared:
            shared.append(reader_id)
        with self.lock, closing(self._connect()) as db, db:
            db.execute("UPDATE files SET shared_with=? WHERE owner_id=? AND path=?", (json.dumps(shared), owner_id, path))
        slug = slug_for(row["owner_name"]) or "bot"
        copy_name = _check_path(f"delt-{slug}-{path}"[:80])
        with self.lock, closing(self._connect()) as db:
            reader = db.execute("SELECT bot_name FROM tasks WHERE bot_id=? LIMIT 1", (reader_id,)).fetchone()
        reader_name = reader["bot_name"] if reader else ""
        if slug_for(reader_name):
            self._write_desk(reader_name, copy_name, row["text"])
        updated = self._file_row(owner_id, path)
        updated["shared_with"] = shared
        return updated

    def work_once(self) -> bool:
        if not self.docker.online():
            self.link = "dockerOffline"
            return False
        self.link = "online"
        job = self._claim()
        if job is None:
            return False
        slug = slug_for(job["bot_name"])
        if slug is None:
            self._finish(job["id"], "failed", None, None, "Kun Adam og Eva har en computer.")
            return True
        try:
            self.docker.start(slug)
            source = ""
            if job["input_path"]:
                source = self.open_file(job["bot_id"], job["bot_id"], job["input_path"])["text"]
            result = self.complete(job["instruction"], source)
            if not isinstance(result, str) or not result.strip():
                raise BotComputerError("Tomt resultat")
            if self._status(job["id"]) != "running":
                return True
            path = f"opgave-{job['id'][:8]}.txt"
            self.write_file(job["bot_id"], job["bot_name"], path, result)
            if self._status(job["id"]) != "running":
                self._delete_file(job["bot_id"], path)
                return True
            self._finish(job["id"], "done", result, path, None)
            try:
                self.docker.show(slug, path)
            except BotComputerError:
                pass
        except Exception:
            if self._status(job["id"]) == "running":
                self._finish(job["id"], "failed", None, None, "Opgaven mislykkedes. Prøv igen.")
        return True

    def click(self, bot_id: str, name: str, x: float, y: float, approved: bool) -> None:
        if approved is not True:
            raise ApprovalError("Overtag styring kræver en eksplicit godkendelse.")
        slug = slug_for(name)
        if slug is None or not self.docker.online():
            raise BotComputerError("Docker er offline")
        if not isinstance(x, (int, float)) or not isinstance(y, (int, float)) or not 0 <= x <= 1 or not 0 <= y <= 1:
            raise BotComputerError("Punktet ligger uden for skrivebordet.")
        self.docker.click(slug, round(x * 1920), round(y * 1080))

    def screenshot(self, name: str) -> bytes:
        slug = slug_for(name)
        if slug is None or not self.docker.online():
            raise BotComputerError("Docker er offline")
        self.docker.start(slug)
        return self.docker.screenshot(slug)

    def _claim(self):
        with self.lock, closing(self._connect()) as db, db:
            db.execute("BEGIN IMMEDIATE")
            row = db.execute("SELECT * FROM tasks WHERE status='waiting' ORDER BY created, id LIMIT 1").fetchone()
            if row is None:
                return None
            now = self.clock()
            done = db.execute(
                "UPDATE tasks SET status='running', updated=? WHERE id=? AND status='waiting'",
                (now, row["id"]),
            ).rowcount
            return dict(row) if done == 1 else None

    def _status(self, task_id: str) -> str:
        with self.lock, closing(self._connect()) as db:
            row = db.execute("SELECT status FROM tasks WHERE id=?", (task_id,)).fetchone()
        return row["status"] if row else "missing"

    def _finish(self, task_id: str, status: str, result: str | None, path: str | None, error: str | None) -> None:
        with self.lock, closing(self._connect()) as db, db:
            db.execute(
                """UPDATE tasks SET status=?, result_text=?, result_path=?, error=?, updated=?
                   WHERE id=? AND status='running'""",
                (status, result, path, error, self.clock(), task_id),
            )

    def _file_row(self, owner_id: str, path: str) -> dict:
        with self.lock, closing(self._connect()) as db:
            row = db.execute("SELECT * FROM files WHERE owner_id=? AND path=?", (owner_id, path)).fetchone()
        if row is None:
            raise BotComputerError("Filen findes ikke.")
        item = dict(row)
        item["shared_with"] = json.loads(item["shared_with"])
        return item

    def _delete_file(self, owner_id: str, path: str) -> None:
        with self.lock, closing(self._connect()) as db, db:
            row = db.execute("SELECT owner_name FROM files WHERE owner_id=? AND path=?", (owner_id, path)).fetchone()
            db.execute("DELETE FROM files WHERE owner_id=? AND path=?", (owner_id, path))
        if row:
            disk = self._desk_folder(row["owner_name"]) / path
            if disk.is_symlink() or disk.exists():
                disk.unlink()

    def _desk_folder(self, owner_name: str) -> Path:
        slug = slug_for(owner_name) or _check_token(owner_name)
        desk = self.root / "desks" / slug
        if desk.is_symlink():
            raise BotComputerError("Computerens mappe er ikke sikker.")
        folder = desk / "files"
        if folder.is_symlink():
            raise BotComputerError("Computerens mappe er ikke sikker.")
        folder.mkdir(parents=True, exist_ok=True)
        if not folder.resolve().is_relative_to(self.root.resolve()):
            raise BotComputerError("Computerens mappe er ikke sikker.")
        return folder

    def _write_desk(self, owner_name: str, path: str, text: str) -> None:
        path = _check_path(path)
        folder = self._desk_folder(owner_name)
        target = folder / path
        temporary = folder / f".skriv-{uuid4().hex}"
        try:
            flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0)
            try:
                handle = os.open(temporary, flags, 0o600)
            except OSError as exc:
                raise BotComputerError("Filen peger uden for computerens mappe.") from exc
            try:
                os.write(handle, text.encode("utf-8"))
            finally:
                os.close(handle)
            resolved_folder = folder.resolve()
            if temporary.is_symlink() or not temporary.resolve().is_relative_to(resolved_folder):
                raise BotComputerError("Filen peger uden for computerens mappe.")
            if target.is_symlink():
                target.unlink()
            os.replace(temporary, target)
            if target.is_symlink() or not target.resolve().is_relative_to(resolved_folder):
                if target.is_symlink() or target.exists():
                    target.unlink()
                raise BotComputerError("Filen peger uden for computerens mappe.")
        except BotComputerError:
            if temporary.is_symlink() or temporary.exists():
                temporary.unlink()
            raise
        except OSError as exc:
            if temporary.is_symlink() or temporary.exists():
                temporary.unlink()
            raise BotComputerError("Filen peger uden for computerens mappe.") from exc
        finally:
            if temporary.is_symlink() or temporary.exists():
                temporary.unlink()


def local_report(instruction: str, source: str) -> str:
    return f"Rapport\n\n{instruction.strip()}\n\n{source}"


def ollama_complete(instruction: str, source: str, model: str | None = None) -> str:
    model = (model if model is not None else os.environ.get("FADEDAI_OLLAMA_MODEL", "")).strip()
    if not model:
        raise BotComputerError("Sæt FADEDAI_OLLAMA_MODEL til en model, Ollama allerede har. Der hentes ikke en ny model.")
    body = json.dumps({
        "model": model,
        "messages": [
            {"role": "system", "content": "Skriv på dansk. Brug kun den vedlagte tekst."},
            {"role": "user", "content": instruction + "\n\n" + source},
        ],
        "stream": False,
    }).encode()
    request = urllib.request.Request("http://127.0.0.1:11434/api/chat", data=body, method="POST")
    request.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(request, timeout=120) as response:
            payload = json.loads(response.read().decode())
        return str(payload["message"]["content"])
    except (OSError, urllib.error.URLError, KeyError, TypeError, json.JSONDecodeError) as exc:
        raise BotComputerError("Ollama svarede ikke. Modellerne på F:\\FadedAI blev ikke ændret.") from exc


class BotComputerWorker:
    def __init__(self, office: BotComputerOffice):
        self.office = office
        self.stop = threading.Event()
        self.thread = threading.Thread(target=self._run, daemon=True)

    def start(self) -> None:
        self.thread.start()

    def _run(self) -> None:
        while not self.stop.wait(1):
            try:
                self.office.work_once()
            except Exception:
                continue


def logic_proof(root: Path) -> list[str]:
    docker = MemoryDocker()
    office = BotComputerOffice(root, docker=docker, complete=local_report, clock=lambda: 10)
    adam, eva = "adam-bot1", "eva-bot01"
    office.write_file(adam, "Adam", "kilde.txt", "Adam kender tallet 7.")
    first = office.submit(adam, "Adam", "Skriv en rapport ud fra kilde.txt", "key-adam-1", "kilde.txt")
    second = office.submit(adam, "Adam", "En anden opgave", "key-adam-1", "kilde.txt")
    if first["id"] != second["id"]:
        raise BotComputerError("Samme nøgle oprettede to opgaver.")
    office.write_file(eva, "Eva", "noter.txt", "Eva kender farven lilla.")
    eva_task = office.submit(eva, "Eva", "Skriv en rapport ud fra noter.txt", "key-eva-01", "noter.txt")
    if not office.work_once() or not office.work_once():
        raise BotComputerError("Arbejdet blev ikke kørt.")
    adam_done = office.task(first["id"])
    eva_done = office.task(eva_task["id"])
    if adam_done["status"] != "done" or "tallet 7" not in adam_done["result_text"]:
        raise BotComputerError("Adams rapport mangler kildeteksten.")
    if eva_done["status"] != "done" or "lilla" not in eva_done["result_text"] or "tallet 7" in eva_done["result_text"]:
        raise BotComputerError("Evas rapport brugte den forkerte fil.")
    lines = [
        f"Adam opgave {adam_done['id']} er {adam_done['status']}.",
        "Samme nøgle gav samme opgave.",
        f"Eva opgave {eva_done['id']} brugte en anden fil.",
    ]
    try:
        office.open_file(eva, adam, adam_done["result_path"])
    except IsolationError:
        lines.append("Eva kunne ikke åbne Adams rapport.")
    else:
        raise BotComputerError("Eva kunne åbne Adams rapport uden deling.")
    try:
        office.share(adam, adam_done["result_path"], eva, approved=False)
    except ApprovalError:
        lines.append("Deling uden godkendelse blev afvist.")
    else:
        raise BotComputerError("Deling blev godkendt uden et ja.")
    office.share(adam, adam_done["result_path"], eva, approved=True)
    opened = office.open_file(eva, adam, adam_done["result_path"])
    if "tallet 7" not in opened["text"]:
        raise BotComputerError("Eva kunne ikke åbne rapporten efter deling.")
    lines.append("Efter godkendt deling kunne Eva åbne Adams rapport.")
    revived = BotComputerOffice(root, docker=docker, complete=local_report, clock=lambda: 20)
    if revived.task(first["id"])["status"] != "done":
        raise BotComputerError("Opgaven forsvandt ved genstart.")
    if not (root / "desks" / "adam" / "files" / adam_done["result_path"]).is_file():
        raise BotComputerError("Filen manglede efter genstart.")
    lines.append("Efter genstart ligger filerne der stadig.")
    if revived.work_once():
        raise BotComputerError("Genstart startede arbejdet en gang til.")
    lines.append("Genstart startede ikke opgaven igen.")
    return lines


def _public_task(task: dict, link: str) -> dict:
    return {"link": link, "task": {key: task.get(key) for key in (
        "id", "bot_id", "bot_name", "idempotency_key", "retry_key", "instruction", "input_path",
        "status", "result_text", "result_path", "error", "attempt", "created", "updated")}}


def register_bot_computers(app, settings, authorize) -> None:
    from fastapi import Body, Request

    from sweatcaster.dto import ApiError

    root = Path(os.environ.get("FADEDAI_BOT_ROOT", str(Path(settings.output_root) / "bot-computers")))
    file_env = read_env_file(root / ".env")
    if not os.environ.get("FADEDAI_BOT_ROOT") and file_env.get("FADEDAI_BOT_ROOT"):
        root = Path(file_env["FADEDAI_BOT_ROOT"])
        file_env = read_env_file(root / ".env")
    compose = setting_value("FADEDAI_BOT_COMPOSE", file_env)
    documented = Path("D:/FadedAIData/bot-computers")
    if not compose and (documented / ".env").is_file():
        root = documented
        file_env = read_env_file(root / ".env")
        pointed = file_env.get("FADEDAI_BOT_ROOT", "").strip()
        if pointed:
            root = Path(pointed)
            file_env = read_env_file(root / ".env")
        compose = setting_value("FADEDAI_BOT_COMPOSE", file_env)
    docker = ComposeControl(Path(compose), root) if compose else UnavailableDocker()
    if setting_value("FADEDAI_BOT_COMPLETE", file_env) == "local":
        complete = local_report
    else:
        model = setting_value("FADEDAI_OLLAMA_MODEL", file_env)

        def complete(instruction, source, chosen=model):
            return ollama_complete(instruction, source, model=chosen)
    office = BotComputerOffice(root, docker=docker, complete=complete)
    worker = BotComputerWorker(office)
    worker.start()

    def fail(exc: Exception):
        if isinstance(exc, IsolationError):
            raise ApiError(403, "FORBIDDEN", "Den fil er ikke delt.") from exc
        if isinstance(exc, ApprovalError):
            raise ApiError(422, "INVALID_INPUT", str(exc)) from exc
        if isinstance(exc, BotComputerError) and "Docker" in str(exc):
            raise ApiError(503, "NOT_READY", "Docker er offline") from exc
        if isinstance(exc, BotComputerError):
            raise ApiError(422, "INVALID_INPUT", str(exc)) from exc
        raise ApiError(422, "INVALID_INPUT", "Computeren kunne ikke udføre det.") from exc

    @app.get("/api/modules/v1/bot-computers/health", include_in_schema=False)
    def health(request: Request):
        authorize(request, settings)
        return {"link": office.probe()}

    @app.put("/api/modules/v1/bot-computers/{bot_id}/tasks", include_in_schema=False)
    def submit(request: Request, bot_id: str, body: dict = Body(...)):
        authorize(request, settings)
        try:
            task = office.submit(bot_id, str(body.get("bot_name") or body.get("name") or ""),
                                 str(body.get("instruction") or ""), str(body.get("idempotency_key") or ""),
                                 body.get("input_path"))
        except (BotComputerError, TypeError) as exc:
            fail(exc)
        return _public_task(task, task.pop("link"))

    @app.get("/api/modules/v1/bot-computers/{bot_id}/tasks", include_in_schema=False)
    def listed(request: Request, bot_id: str):
        authorize(request, settings)
        try:
            return {"link": office.probe(), "tasks": office.tasks_for(bot_id)}
        except BotComputerError as exc:
            fail(exc)

    @app.put("/api/modules/v1/bot-computers/{bot_id}/tasks/{task_id}/cancel", include_in_schema=False)
    def cancel(request: Request, bot_id: str, task_id: str):
        authorize(request, settings)
        try:
            task = office.cancel(task_id)
            if task["bot_id"] != bot_id:
                raise BotComputerError("Opgaven findes ikke.")
            return {"task": task}
        except BotComputerError as exc:
            fail(exc)

    @app.put("/api/modules/v1/bot-computers/{bot_id}/tasks/{task_id}/retry", include_in_schema=False)
    def retry(request: Request, bot_id: str, task_id: str, body: dict = Body(...)):
        authorize(request, settings)
        try:
            current = office.task(task_id)
            if current["bot_id"] != bot_id:
                raise BotComputerError("Opgaven findes ikke.")
            task = office.retry(task_id, str(body.get("retry_key") or ""))
        except BotComputerError as exc:
            fail(exc)
        return _public_task(task, task.pop("link"))

    @app.get("/api/modules/v1/bot-computers/{bot_id}/files/{owner_id}", include_in_schema=False)
    def read(request: Request, bot_id: str, owner_id: str, name: str):
        authorize(request, settings)
        try:
            return {"file": office.open_file(bot_id, owner_id, name)}
        except (BotComputerError, IsolationError) as exc:
            fail(exc)

    @app.put("/api/modules/v1/bot-computers/files/share", include_in_schema=False)
    def share(request: Request, body: dict = Body(...)):
        authorize(request, settings)
        try:
            return {"file": office.share(str(body.get("owner_id") or ""), str(body.get("path") or ""),
                                         str(body.get("with") or ""), body.get("approved") is True)}
        except (BotComputerError, IsolationError, ApprovalError) as exc:
            fail(exc)

    @app.put("/api/modules/v1/bot-computers/{bot_id}/desktop", include_in_schema=False)
    def desktop(request: Request, bot_id: str, body: dict = Body(...)):
        authorize(request, settings)
        try:
            _check_token(bot_id)
            name = str(body.get("name") or "")
            if office.docker.online():
                slug = slug_for(name)
                if slug:
                    office.docker.start(slug)
            return {"link": office.probe()}
        except BotComputerError as exc:
            fail(exc)

    @app.get("/api/modules/v1/bot-computers/{bot_id}/desktop", include_in_schema=False)
    def frame(request: Request, bot_id: str, name: str):
        authorize(request, settings)
        from fastapi.responses import Response
        try:
            _check_token(bot_id)
            return Response(office.screenshot(name), media_type="image/png")
        except BotComputerError as exc:
            fail(exc)

    @app.put("/api/modules/v1/bot-computers/{bot_id}/desktop/input", include_in_schema=False)
    def pointer(request: Request, bot_id: str, body: dict = Body(...)):
        authorize(request, settings)
        try:
            _check_token(bot_id)
            office.click(bot_id, str(body.get("name") or ""), body.get("x"), body.get("y"), body.get("approved") is True)
            return {"ok": True}
        except (BotComputerError, ApprovalError, TypeError) as exc:
            fail(exc)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="FadedAI bot-computere")
    parser.add_argument("command", choices=("prove", "work"))
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--measure", action="store_true")
    parser.add_argument("--compose", type=Path)
    args = parser.parse_args(argv)
    root = args.root.resolve()
    if any(marker in str(root) for marker in LIVE_MARKERS):
        raise SystemExit("Den mappe er den kørende installation. Vælg en anden mappe.")
    file_env = read_env_file(root / ".env")
    if args.command == "work":
        compose = str(args.compose) if args.compose else setting_value("FADEDAI_BOT_COMPOSE", file_env)
        docker = ComposeControl(Path(compose), root) if compose else UnavailableDocker()
        model = setting_value("FADEDAI_OLLAMA_MODEL", file_env)
        if setting_value("FADEDAI_BOT_COMPLETE", file_env) == "local":
            complete = local_report
        else:
            def complete(instruction, source, chosen=model):
                return ollama_complete(instruction, source, model=chosen)
        BotComputerOffice(root, docker=docker, complete=complete).work_once()
        return 0
    lines = logic_proof(root)
    if args.measure:
        compose = args.compose
        control = ComposeControl(compose, root) if compose else None
        if control is None or not control.online():
            lines.append("Docker er offline. Skriveborde og RAM blev ikke målt.")
        else:
            control.start("adam")
            control.start("eva")
            measurement = control.stats()
            (root / "maaling.txt").write_text(measurement + "\n", encoding="utf-8")
            lines.append("Måling med docker stats --no-stream, mens Adam og Eva kører:")
            lines.append(measurement or "docker stats gav ingen bot-computere.")
            control.restart("adam")
            control.restart("eva")
            adam_files = list((root / "desks" / "adam" / "files").glob("opgave-*.txt"))
            eva_files = list((root / "desks" / "eva" / "files").glob("opgave-*.txt"))
            lines.append(f"Efter genstart af containerne: Adam {len(adam_files)} rapport, Eva {len(eva_files)} rapport.")
            lines.append("Containerne blev genstartet uden at slette deres filer. Et nyt job blev ikke oprettet.")
    else:
        lines.append("Docker blev ikke målt i dette kald.")
    text = "\n".join(lines) + "\n"
    (root / "bevis.txt").write_text(text, encoding="utf-8")
    print(text)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

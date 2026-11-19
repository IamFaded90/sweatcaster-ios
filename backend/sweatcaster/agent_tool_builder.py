"""Build, exercise, register and run per-owner PC tools from a bounded recipe."""

import base64
import hashlib
from contextlib import closing
import json
from pathlib import Path
import shutil
import sqlite3
from threading import Lock
import time
from uuid import UUID, uuid4

from fastapi import APIRouter, Body, Depends, Request, Response
from fastapi.responses import FileResponse

from sweatcaster.agent_tool_runtime import MAX_BYTES, basename, execute, program, self_test, validate_spec
from sweatcaster.dto import ApiError


def tool_id(value):
    try:
        return str(UUID(value))
    except (ValueError, TypeError, AttributeError):
        raise ApiError(422, "INVALID_INPUT", "Værktøjets id er ugyldigt.") from None


def propose(settings, brief):
    from sweatcaster.bot_computers import run_local_text
    from sweatcaster.ollama_gate import chat_payload

    instructions = (
        "Create a useful local file-processing tool for the request. Return only JSON with title (Danish, max60), "
        "description (Danish,max600) and steps (1-5 objects). Available step schemas: "
        '{"type":"image_resize","maxEdge":2048,"format":"jpeg","quality":90}; '
        '{"type":"rename","prefix":"billede","start":1}; '
        '{"type":"csv_columns","columns":["name","date"]}; '
        '{"type":"text_replace","find":"old","replace":"new"}; '
        '{"type":"zip","name":"resultat.zip"}. ZIP must be last. Never invent CSV column names or text replacements. '
        "Use only capabilities needed for the request. For an unsupported task, return "
        '{"error":"Kort dansk forklaring på det manglende værktøj"}.'
    )
    payload = chat_payload(settings, [{"role": "system", "content": instructions},
                                      {"role": "user", "content": brief}], stream=False, temperature=0.1)
    payload["format"] = "json"
    payload["options"]["num_predict"] = 500
    return json.loads(run_local_text(settings, payload, purpose="agent-tool-builder"))


class AgentTools:
    def __init__(self, settings, proposer=propose):
        self.settings = settings
        self.proposer = proposer
        self.root = Path(settings.output_root) / "agent-tools"
        self.root.mkdir(parents=True, exist_ok=True)
        self.database = self.root / "tools.sqlite3"
        self.build_lock = Lock()
        with closing(self._db()) as db:
            db.executescript("""
                CREATE TABLE IF NOT EXISTS tools (
                    id TEXT PRIMARY KEY, brief TEXT NOT NULL, spec TEXT NOT NULL,
                    checks TEXT NOT NULL, created REAL NOT NULL);
                CREATE TABLE IF NOT EXISTS runs (
                    id TEXT PRIMARY KEY, tool TEXT NOT NULL, files TEXT NOT NULL,
                    created REAL NOT NULL);
            """)
            if "input_hash" not in {row[1] for row in db.execute("PRAGMA table_info(runs)")}:
                db.execute("ALTER TABLE runs ADD COLUMN input_hash TEXT NOT NULL DEFAULT ''")
                db.commit()

    def _db(self):
        connection = sqlite3.connect(self.database, timeout=10)
        connection.row_factory = sqlite3.Row
        return connection

    def get(self, identifier):
        with closing(self._db()) as db:
            row = db.execute("SELECT * FROM tools WHERE id=?", (tool_id(identifier),)).fetchone()
        if row is None:
            raise ApiError(404, "NOT_FOUND", "Værktøjet er slettet eller findes ikke.")
        return {"id": row["id"], **json.loads(row["spec"]), "checks": json.loads(row["checks"]),
                "created": row["created"]}

    def list(self):
        with closing(self._db()) as db:
            ids = [row[0] for row in db.execute("SELECT id FROM tools ORDER BY created DESC LIMIT 40")]
        items = []
        for identifier in ids:
            try:
                items.append(self.get(identifier))
            except ApiError:
                pass
        return {"items": items}

    def complete(self, brief, files, request_id):
        """One agent request can construct its missing tool, test it, and use it."""
        identifier = tool_id(request_id)
        with closing(self._db()) as db:
            existing = db.execute("SELECT id FROM tools WHERE brief=? ORDER BY created DESC LIMIT 1", (brief,)).fetchone()
        tool = self.get(existing["id"]) if existing else self.build(brief, identifier)
        result = self.run(tool["id"], files, identifier)
        return {"tool": tool, "result": result}

    def build(self, brief, request_id, spec=None):
        identifier = tool_id(request_id)
        if not isinstance(brief, str) or not 1 <= len(brief.strip()) <= 1000:
            raise ApiError(422, "INVALID_INPUT", "Beskriv værktøjet med højst 1.000 tegn.")
        if not self.build_lock.acquire(blocking=False):
            raise ApiError(409, "NOT_READY", "Code Bot bygger allerede et værktøj.")
        try:
            with closing(self._db()) as db:
                old = db.execute("SELECT brief,spec FROM tools WHERE id=?", (identifier,)).fetchone()
                if old is not None:
                    if old["brief"] != brief or (spec is not None and json.loads(old["spec"]) != spec):
                        raise ApiError(409, "NOT_READY", "Dette byggeforslag er allerede brugt.")
                    return self.get(identifier)
                if db.execute("SELECT count(*) FROM tools").fetchone()[0] >= 40:
                    raise ApiError(409, "NOT_READY", "Slet et gammelt værktøj for at få plads.")
            try:
                raw = spec if spec is not None else self.proposer(self.settings, brief)
            except Exception as exc:
                from sweatcaster.bot_computers import ModelBusy
                if isinstance(exc, ModelBusy):
                    raise ApiError(503, "NOT_READY", "PC-modellen er optaget. Prøv igen om lidt.") from exc
                raise ApiError(503, "NOT_READY", "Code Bot kunne ikke bygge forslaget. Kontrollér PC-modellen.") from exc
            if isinstance(raw, dict) and isinstance(raw.get("error"), str):
                raise ApiError(409, "NOT_READY", raw["error"][:400])
            try:
                validated = validate_spec(raw)
                checks = self_test(validated)
            except (ValueError, AssertionError, OSError, UnicodeError, ImportError) as exc:
                raise ApiError(422, "INVALID_INPUT", "Værktøjet bestod ikke prøven. " + str(exc)[:200]) from exc
            with closing(self._db()) as db, db:
                db.execute("INSERT INTO tools VALUES (?,?,?,?,?)", (
                    identifier, brief, json.dumps(validated, ensure_ascii=False),
                    json.dumps(checks, ensure_ascii=False), time.time()))
            return self.get(identifier)
        finally:
            self.build_lock.release()

    def run(self, identifier, encoded_files, request_id):
        tool = self.get(identifier)
        run_id = tool_id(request_id)
        if not isinstance(encoded_files, list) or not 1 <= len(encoded_files) <= 20:
            raise ApiError(422, "INVALID_INPUT", "Vælg én til 20 filer.")
        files = {}
        try:
            for item in encoded_files:
                if not isinstance(item, dict) or set(item) != {"name", "data"}:
                    raise ValueError("En fil er ugyldig.")
                name = basename(item["name"])
                if name in files:
                    raise ValueError("To valgte filer har samme navn.")
                encoded = item["data"]
                if not isinstance(encoded, str) or len(encoded) > MAX_BYTES * 4 // 3 + 8:
                    raise ValueError("Filen er for stor.")
                files[name] = base64.b64decode(encoded, validate=True)
            if sum(map(len, files.values())) > MAX_BYTES:
                raise ValueError("Vælg filer på tilsammen højst 24 MB.")
            spec = {key: tool[key] for key in ("title", "description", "steps")}
            digest = hashlib.sha256(json.dumps(spec, sort_keys=True).encode())
            for name, data in files.items():
                digest.update(len(name.encode()).to_bytes(4, "little") + name.encode())
                digest.update(len(data).to_bytes(8, "little") + data)
            input_hash = digest.hexdigest()
            output = execute(spec, files)
        except (ValueError, OSError, UnicodeError, KeyError) as exc:
            raise ApiError(422, "INVALID_INPUT", str(exc)[:240]) from exc
        directory = self.root / "runs" / run_id
        # Commit with the tool row still present. Removal and concurrent retries share the same writer lock.
        with closing(self._db()) as db, db:
            db.execute("BEGIN IMMEDIATE")
            if db.execute("SELECT 1 FROM tools WHERE id=?", (tool["id"],)).fetchone() is None:
                raise ApiError(409, "NOT_READY", "Værktøjet blev slettet, mens det arbejdede.")
            old = db.execute("SELECT tool,files,input_hash FROM runs WHERE id=?", (run_id,)).fetchone()
            if old:
                if old["tool"] != tool["id"] or old["input_hash"] != input_hash:
                    raise ApiError(409, "NOT_READY", "Kørslen er allerede brugt til andre filer eller et andet værktøj.")
                return self.results(run_id)
            used = sum(sum(item["bytes"] for item in json.loads(row[0])) for row in db.execute("SELECT files FROM runs"))
            if db.execute("SELECT count(*) FROM runs").fetchone()[0] >= 100 or used + sum(map(len, output.values())) > 256_000_000:
                raise ApiError(409, "NOT_READY", "Slet nogle gamle resultater for at få plads.")
            if directory.exists():
                self._remove_folder(directory)
            directory.mkdir(parents=True, exist_ok=False)
            try:
                manifest = []
                for index, (name, data) in enumerate(output.items()):
                    (directory / str(index)).write_bytes(data)
                    manifest.append({"index": index, "name": name, "bytes": len(data)})
                db.execute("INSERT INTO runs (id,tool,files,created,input_hash) VALUES (?,?,?,?,?)",
                           (run_id, tool["id"], json.dumps(manifest), time.time(), input_hash))
            except Exception:
                self._remove_folder(directory)
                raise
        return self.results(run_id)

    def results(self, run_id):
        with closing(self._db()) as db:
            row = db.execute("SELECT tool,files FROM runs WHERE id=?", (tool_id(run_id),)).fetchone()
        if row is None:
            raise ApiError(404, "NOT_FOUND", "Resultatet er slettet.")
        return {"id": run_id, "tool": row["tool"], "files": json.loads(row["files"])}

    def runs(self, identifier):
        self.get(identifier)
        with closing(self._db()) as db:
            ids = [row[0] for row in db.execute("SELECT id FROM runs WHERE tool=? ORDER BY created DESC", (tool_id(identifier),))]
        return {"items": [self.results(run_id) for run_id in ids]}

    def _remove_folder(self, directory):
        root = (self.root / "runs").resolve()
        target = directory.resolve()
        if target.parent != root or directory.is_symlink():
            raise ValueError("Resultatets mappe ligger uden for værktøjets lager.")
        if directory.exists():
            shutil.rmtree(directory)

    def remove_run(self, run_id):
        with closing(self._db()) as db, db:
            db.execute("BEGIN IMMEDIATE")
            self._remove_folder(self.root / "runs" / tool_id(run_id))
            db.execute("DELETE FROM runs WHERE id=?", (run_id,))
        return {"removed": True}

    def remove(self, identifier):
        identifier = tool_id(identifier)
        with closing(self._db()) as db, db:
            db.execute("BEGIN IMMEDIATE")
            ids = [row[0] for row in db.execute("SELECT id FROM runs WHERE tool=?", (identifier,))]
            for run_id in ids:
                self._remove_folder(self.root / "runs" / tool_id(run_id))
            db.execute("DELETE FROM runs WHERE tool=?", (identifier,))
            db.execute("DELETE FROM tools WHERE id=?", (identifier,))
        return {"removed": True}

    def file(self, run_id, index):
        manifest = self.results(run_id)
        item = next((item for item in manifest["files"] if item["index"] == index), None)
        if item is None:
            raise ApiError(404, "NOT_FOUND", "Filen findes ikke.")
        directory = self.root / "runs" / tool_id(run_id)
        path = directory / str(index)
        if (directory.is_symlink() or directory.resolve().parent != (self.root / "runs").resolve()
                or not path.is_file() or path.is_symlink() or path.resolve().parent != directory.resolve()
                or path.stat().st_size != item["bytes"]):
            raise ApiError(404, "NOT_FOUND", "Filen er slettet.")
        return FileResponse(path, filename=item["name"], media_type="application/octet-stream",
                            headers={"Cache-Control": "no-store"})

    def file_data(self, run_id, index):
        response = self.file(run_id, index)
        path = Path(response.path)
        manifest = self.results(run_id)
        item = next(item for item in manifest["files"] if item["index"] == index)
        try:
            data = path.read_bytes()
        except OSError:
            raise ApiError(404, "NOT_FOUND", "Resultatfilen blev fjernet. Opdatér listen.") from None
        return {"name": item["name"], "data": base64.b64encode(data).decode("ascii")}


def register_agent_tools(app, settings, authorize):
    service = AgentTools(settings)

    def paired(request: Request, response: Response):
        authorize(request, settings)
        response.headers["Cache-Control"] = "no-store"

    router = APIRouter(prefix="/api/modules/v1/agent-tools", dependencies=[Depends(paired)], include_in_schema=False)

    @router.get("")
    def library():
        return service.list()

    @router.put("/build")
    def build(brief: str = Body(..., min_length=1, max_length=1000), requestID: str = Body(...), spec: dict | None = Body(None)):
        return service.build(brief, requestID, spec)

    @router.put("/complete")
    def complete(brief: str = Body(..., min_length=1, max_length=1000), files: list = Body(...),
                 requestID: str = Body(...)):
        return service.complete(brief, files, requestID)

    @router.get("/{identifier}/runs")
    def runs(identifier: str):
        return service.runs(identifier)

    @router.put("/{identifier}/run")
    def run(identifier: str, files: list = Body(...), requestID: str = Body(...)):
        return service.run(identifier, files, requestID)

    @router.get("/runs/{run_id}/files/{index}")
    def file(run_id: str, index: int):
        return service.file(run_id, index)

    @router.get("/runs/{run_id}/files/{index}/data")
    def data(run_id: str, index: int):
        return service.file_data(run_id, index)

    @router.get("/{identifier}/program")
    def source(identifier: str):
        tool = service.get(identifier)
        code = program({key: tool[key] for key in ("title", "description", "steps")})
        return Response(code, media_type="text/x-python", headers={"Cache-Control": "no-store"})

    @router.put("/runs/{run_id}/remove")
    def remove_run(run_id: str):
        return service.remove_run(run_id)

    @router.put("/{identifier}/remove")
    def remove(identifier: str):
        return service.remove(identifier)

    app.include_router(router)
    app.state.agent_tools = service
    return service

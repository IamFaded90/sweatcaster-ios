"""Run one paired 3D Studio job at a time and return a local USDZ."""

from __future__ import annotations

import json
import logging
import os
import sqlite3
import subprocess
import time
from contextlib import closing, contextmanager
from hashlib import sha256
from pathlib import Path
from tempfile import TemporaryDirectory
from threading import Lock, Thread
from uuid import UUID
from zipfile import BadZipFile, ZipFile

from fastapi import APIRouter, Depends, Request, Response
from fastapi.responses import FileResponse
from starlette.concurrency import run_in_threadpool

from sweatcaster.dto import ApiError
from sweatcaster.lumi_companion import normalize_reference

MODES = (
    ("shape-text", "Shap-E · fra tekst", 0),
    ("shape-image", "Shap-E · fra billede", 1),
)
MAX_MODEL = 40_000_000
MAX_BODY = 1_400_000
BLENDER_EXPORT = """
import bpy, sys
mesh, target = sys.argv[sys.argv.index('--') + 1:]
bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.wm.obj_import(filepath=mesh)
if not any(obj.type == 'MESH' for obj in bpy.context.scene.objects):
    raise ValueError("The model has no mesh.")
bpy.ops.wm.usd_export(filepath=target, export_materials=True)
"""


def _id(value):
    try:
        if str(UUID(value)) == value:
            return value
    except (ValueError, AttributeError, TypeError):
        pass
    raise ApiError(422, "INVALID_INPUT", "Ugyldigt 3D-job.")


def _program(variable):
    value = os.environ.get(variable)
    path = Path(value) if value else None
    return path if path and path.is_absolute() and path.is_file() else None


def _tools():
    blender = _program("FADEDAI_BLENDER")
    missing = [] if blender else ["Blender med USDZ-eksport"]
    interpreter = _program("FADEDAI_SHAPE_PYTHON")
    if not interpreter:
        missing.append("Shap-E-miljø og model")
    imports = os.environ.get("FADEDAI_SHAPE_IMPORTS")
    if imports and any(
        not path.is_absolute() or not path.is_dir()
        for path in map(Path, imports.split(os.pathsep))
    ):
        missing.append("Shap-E-biblioteker")
    return blender, interpreter, missing


def _run(command, *, seconds, env=None, cwd=None):
    subprocess.run(command, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                   check=True, timeout=seconds, env=env, cwd=cwd,
                   creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))


def _generate(mode, prompt, photo, tools, output):
    from sweatcaster import generate_studio_3d

    blender, interpreter, _ = tools
    with TemporaryDirectory(dir=output.parent, prefix=".mesh-") as scratch:
        work = Path(scratch)
        raw = work / "model.obj"
        command = [str(interpreter), str(Path(generate_studio_3d.__file__).resolve()), "shape", str(raw)]
        if mode == "shape-image":
            image = work / "reference.png"
            image.write_bytes(photo)
            command.extend(["--image", str(image)])
        else:
            command.append("--text=" + prompt)
        shape_cache = os.environ.get("FADEDAI_SHAPE_CACHE")
        working_directory = Path(shape_cache).resolve().parent if shape_cache else None
        imports = os.environ.get("FADEDAI_SHAPE_IMPORTS")
        shape_env = {**os.environ, "PYTHONPATH": imports} if imports else None
        _run(command, seconds=1_260, cwd=working_directory, env=shape_env)
        archive = work / "model.usdz"
        blender_env = {**os.environ, "TEMP": str(work), "TMP": str(work), "TMPDIR": str(work),
                       "BLENDER_USER_RESOURCES": str(work / "blender")}
        _run([str(blender), "--background", "--factory-startup", "--disable-autoexec", "--python-exit-code", "1",
              "--python-expr", BLENDER_EXPORT, "--", str(raw), str(archive)], seconds=120, env=blender_env)
        if not archive.is_file() or not 0 < archive.stat().st_size <= MAX_MODEL:
            raise ValueError("Invalid USDZ size")
        with ZipFile(archive) as model:
            if not any(entry.filename.endswith((".usd", ".usda", ".usdc")) for entry in model.infolist()):
                raise ValueError("Invalid USDZ archive")
        archive.replace(output)


class StudioMeshes:
    def __init__(self, directory):
        self.directory = directory.resolve()
        self.lock = Lock()
        self.recovered = False

    @contextmanager
    def database(self):
        self.directory.mkdir(parents=True, exist_ok=True)
        with closing(sqlite3.connect(self.directory / "jobs.sqlite3")) as db, db:
            db.row_factory = sqlite3.Row
            db.execute("""CREATE TABLE IF NOT EXISTS jobs (
                id TEXT PRIMARY KEY, mode TEXT NOT NULL, digest TEXT NOT NULL, state TEXT NOT NULL, created REAL NOT NULL
            )""")
            if not self.recovered:
                db.execute("UPDATE jobs SET state = 'failed' WHERE state = 'working'")
                db.commit()
                self.recovered = True
            yield db

    @staticmethod
    def summary(row):
        return {"id": row["id"], "mode": row["mode"], "state": row["state"]}

    def catalog(self):
        with self.lock, self.database() as db:
            latest = db.execute("SELECT * FROM jobs WHERE state != 'deleted' ORDER BY created DESC LIMIT 1").fetchone()
        missing = _tools()[2]
        modes = []
        for mode, title, photos in MODES:
            modes.append({"id": mode, "title": title, "photos": photos, "ready": not missing, "missing": missing})
        return {"modes": modes, "lastJob": self.summary(latest) if latest else None}

    def status(self, job_id):
        with self.lock, self.database() as db:
            job = db.execute("SELECT * FROM jobs WHERE id = ?", (_id(job_id),)).fetchone()
        if not job or job["state"] == "deleted":
            raise ApiError(404, "NOT_FOUND", "3D-jobbet blev ikke fundet på PC’en.")
        return self.summary(job)

    def submit(self, body):
        if not isinstance(body, dict):
            raise ApiError(422, "INVALID_INPUT", "Vælg en 3D-model.")
        job_id = _id(body.get("id"))
        mode = body.get("mode")
        prompt, photo = body.get("prompt"), body.get("photo")
        if (not isinstance(mode, str) or mode not in {entry[0] for entry in MODES} or not isinstance(prompt, str)
                or (mode == "shape-text" and (not 1 <= len(prompt.strip()) <= 1_000 or photo is not None))
                or (mode != "shape-text" and (prompt.strip() or not isinstance(photo, str)))):
            raise ApiError(422, "INVALID_INPUT", "Vælg tekst eller billede til den valgte model.")
        prompt = prompt.strip()
        reference = normalize_reference(photo) if photo is not None else None
        digest = sha256(json.dumps([mode, prompt, sha256(reference or b"").hexdigest()]).encode()).hexdigest()
        with self.lock:
            with self.database() as db:
                existing = db.execute("SELECT * FROM jobs WHERE id = ?", (job_id,)).fetchone()
                if existing:
                    if existing["state"] == "deleted":
                        raise ApiError(404, "NOT_FOUND", "3D-jobbet er slettet.")
                    if existing["digest"] != digest:
                        raise ApiError(409, "REQUEST_REUSED", "3D-jobbet har allerede andet indhold.")
                    return self.summary(existing)
                if db.execute("SELECT 1 FROM jobs WHERE state = 'working' LIMIT 1").fetchone():
                    raise ApiError(409, "NOT_READY", "Vent på 3D-jobbet, der kører på PC’en.")
                tools = _tools()
                if tools[2]:
                    raise ApiError(503, "NOT_READY", "Mangler på PC’en: " + ", ".join(tools[2]))
                db.execute("INSERT INTO jobs VALUES (?, ?, ?, 'working', ?)", (job_id, mode, digest, time.time()))
            worker = Thread(target=self.finish, args=(job_id, mode, prompt, reference, tools), daemon=True)
            try:
                worker.start()
            except RuntimeError:
                with self.database() as db:
                    db.execute("UPDATE jobs SET state = 'failed' WHERE id = ?", (job_id,))
                raise ApiError(503, "NOT_READY", "PC’en kunne ikke starte 3D-jobbet.") from None
        return {"id": job_id, "mode": mode, "state": "working"}

    def finish(self, job_id, mode, prompt, photo, tools):
        state = "failed"
        try:
            _generate(mode, prompt, photo, tools, self.directory / (job_id + ".usdz"))
            state = "ready"
        except (BadZipFile, OSError, ValueError, subprocess.SubprocessError) as exc:
            logging.getLogger(__name__).warning("Studio 3D failed (%s)", type(exc).__name__)
        finally:
            with self.lock, self.database() as db:
                db.execute("UPDATE jobs SET state = ? WHERE id = ?", (state, job_id))

    def file(self, job_id):
        job = self.status(job_id)
        path = self.directory / (job_id + ".usdz")
        if job["state"] != "ready" or not path.is_file() or path.is_symlink() or not 0 < path.stat().st_size <= MAX_MODEL:
            raise ApiError(404, "NOT_FOUND", "Der ligger ingen færdig 3D-model til jobbet på PC’en.")
        return path

    def remove(self, job_id):
        job_id = _id(job_id)
        with self.lock, self.database() as db:
            job = db.execute("SELECT state FROM jobs WHERE id = ?", (job_id,)).fetchone()
            if not job or job["state"] == "deleted":
                return {"ok": True}
            if job["state"] == "working":
                raise ApiError(409, "NOT_READY", "Vent til 3D-jobbet er afsluttet.")
            path = self.directory / (job_id + ".usdz")
            try:
                if path.resolve() != path or (path.exists() and not path.is_file()):
                    raise OSError("Unexpected file type")
                path.unlink(missing_ok=True)
            except OSError as exc:
                raise ApiError(503, "NOT_READY", "3D-modellen kunne ikke slettes fra PC’en.") from exc
            db.execute("UPDATE jobs SET state = 'deleted' WHERE id = ?", (job_id,))
        return {"ok": True}


def register_studio_meshes(app, settings, authorize):
    jobs = StudioMeshes(settings.output_root / "studio-3d")

    def paired(request: Request, response: Response):
        authorize(request, settings)
        response.headers["Cache-Control"] = "no-store"

    router = APIRouter(prefix="/api/modules/v1/studio-3d", dependencies=[Depends(paired)], include_in_schema=False)

    @router.get("")
    def catalog():
        return jobs.catalog()

    @router.put("")
    async def submit(request: Request):
        raw = bytearray()
        async for chunk in request.stream():
            if len(raw) + len(chunk) > MAX_BODY:
                raise ApiError(413, "INVALID_INPUT", "Vælg et billede på højst 1 MB.")
            raw.extend(chunk)
        try:
            body = json.loads(raw)
        except (ValueError, RecursionError) as exc:
            raise ApiError(422, "INVALID_INPUT", "3D-opgaven kunne ikke læses.") from exc
        return await run_in_threadpool(jobs.submit, body)

    @router.get("/{job_id}")
    def status(job_id: str):
        return jobs.status(job_id)

    @router.get("/{job_id}/file")
    def file(job_id: str):
        return FileResponse(jobs.file(job_id), media_type="model/vnd.usdz+zip", headers={"Cache-Control": "no-store"})

    @router.put("/{job_id}/remove")
    def remove(job_id: str):
        return jobs.remove(job_id)

    app.include_router(router)

"""Paired PC API for short Creative Studio videos from installed ComfyUI models."""

from __future__ import annotations

import json
import os
import re
import sqlite3
import stat
import time
from contextlib import closing, contextmanager
from dataclasses import replace
from hashlib import sha256
from pathlib import Path
from threading import Lock
from uuid import UUID

import requests
from fastapi import APIRouter, Depends, Request, Response
from starlette.concurrency import run_in_threadpool

from sweatcaster.dto import ApiError
from sweatcaster.lumi_companion import normalize_reference
from sweatcaster.studio_video_workflows import MODES, WAN_FALLBACKS, workflow

COMFY = "http://127.0.0.1:8188"
ANIMATION_COMFY = "http://127.0.0.1:8190"
ANIMATION_PREFIX = "8190:"
ANIMATION_MODE = next(mode for mode in MODES if mode.id == "animatediff")
ANIMATION_FP16 = replace(ANIMATION_MODE, models=ANIMATION_MODE.models[:-1] + (
    ("ADE_AnimateDiffLoaderGen1", "model_name", "mm_sd_v15_v2.fp16.safetensors"),
))
FOLDER = "FadedAI_Studio"
MAX_BODY = 2_680_000
MAX_VIDEO = 40_000_000
JOB_TIMEOUT = 2_700


def _unavailable(message):
    return ApiError(503, "NOT_READY", message)


def _id(value):
    try:
        if str(UUID(value)) == value:
            return value
    except (ValueError, AttributeError, TypeError):
        pass
    raise ApiError(422, "INVALID_INPUT", "Ugyldigt videojob.")


@contextmanager
def _comfy():
    with requests.Session() as session:
        session.trust_env = False
        try:
            yield session
        except (requests.RequestException, ValueError, TypeError, KeyError) as exc:
            raise _unavailable("ComfyUI kunne ikke svare på PC’en. Kontrollér, at det kører.") from exc


def _json(session, method, path, *, base=None, limit=400_000, **kwargs):
    with session.request(method, (base or COMFY) + path, timeout=(2, 10), allow_redirects=False,
                         stream=True, **kwargs) as response:
        if response.status_code != 200:
            if response.status_code == 400 and path == "/prompt":
                raise ApiError(502, "STUDIO_RECIPE_REJECTED", "ComfyUI afviste opskriften. Opdatér modellerne på PC’en.")
            raise _unavailable("Videomotoren på PC’en svarede ikke som forventet.")
        return json.loads(_read(response, limit))


def _read(response, limit):
    data = bytearray()
    for chunk in response.iter_content(65_536):
        data.extend(chunk)
        if len(data) > limit:
            raise ApiError(502, "NOT_READY", "ComfyUI sendte en fil, der er for stor.")
    return data


def _choices(field):
    if not isinstance(field, list) or not field:
        return ()
    if isinstance(field[0], list):
        return field[0]
    if len(field) > 1 and isinstance(field[1], dict):
        options = field[1].get("options")
        if isinstance(options, list):
            return options
    return ()


def _capabilities(session, *, base=None, modes=MODES):
    schemas = {}

    def schema(node):
        if node not in schemas:
            schemas[node] = _json(session, "GET", f"/object_info/{node}", base=base).get(node, {})
        return schemas[node]

    def requirements(mode):
        missing = []
        graph = workflow(mode, "Prøve", ["example.png"] * mode.photos, "probe", 1)
        for kind in sorted({entry["class_type"] for entry in graph.values()}):
            if not schema(kind):
                missing.append(kind)
        for node, field, filename in mode.models:
            required = schema(node).get("input", {}).get("required", {})
            if schema(node) and filename not in _choices(required.get(field)):
                missing.append(filename)
        return missing

    if not schema("SaveVideo"):
        return {}, False, {}
    old_export = schema("SaveVideo").get("input", {}).get("required", {}).get("format", [None])[0]
    modern_export = isinstance(old_export, str) and "DYNAMIC" in old_export
    available, selected = {}, {}
    for mode in modes:
        missing = requirements(mode)
        fallback = WAN_FALLBACKS.get(mode.id)
        if missing and fallback is not None:
            fallback_missing = requirements(fallback)
            if len(fallback_missing) <= len(missing):
                mode, missing = fallback, fallback_missing
        available[mode.id] = missing
        selected[mode.id] = mode
    return available, modern_export, selected


def _animation_backend(session):
    try:
        for mode in (ANIMATION_FP16, ANIMATION_MODE):
            available, modern, _ = _capabilities(session, base=ANIMATION_COMFY, modes=(mode,))
            if available.get(mode.id) == []:
                return mode, modern
    except (ApiError, requests.RequestException):
        pass
    return None, False


def _provider_target(provider):
    if provider.startswith(ANIMATION_PREFIX):
        return ANIMATION_COMFY, _id(provider.removeprefix(ANIMATION_PREFIX))
    return COMFY, _id(provider)


class StudioVideos:
    def __init__(self, path):
        self.path = path
        self.lock = Lock()

    @contextmanager
    def database(self):
        with closing(sqlite3.connect(self.path)) as db, db:
            db.row_factory = sqlite3.Row
            db.execute("""CREATE TABLE IF NOT EXISTS studio_jobs (
                id TEXT PRIMARY KEY, mode TEXT NOT NULL, digest TEXT NOT NULL, provider TEXT NOT NULL,
                state TEXT NOT NULL, created REAL NOT NULL
            )""")
            yield db

    def catalog(self):
        selected = {}
        try:
            with _comfy() as session:
                available, _, selected = _capabilities(session)
                if available.get(ANIMATION_MODE.id) and _animation_backend(session)[0] is not None:
                    available[ANIMATION_MODE.id] = []
            if not available:
                message = "Opdatér ComfyUI med videostøtte på PC’en."
            elif all(available.values()):
                message = "PC’en svarer. Se under den valgte model, hvad der mangler, før du kan lave video."
            else:
                message = None
        except ApiError as exc:
            available, message = {}, str(exc)
        with self.database() as db:
            previous = db.execute("SELECT id FROM studio_jobs WHERE state != 'deleted' ORDER BY created DESC LIMIT 1").fetchone()
        return {
            "modes": [{"id": mode.id, "title": selected.get(mode.id, mode).title, "photos": mode.photos,
                       "ready": mode.id in available and not available[mode.id],
                       "missing": available.get(mode.id, [])} for mode in MODES],
            "lastJob": previous["id"] if previous else None,
            "message": message,
        }

    def _job(self, job_id):
        with self.database() as db:
            job = db.execute("SELECT * FROM studio_jobs WHERE id = ?", (_id(job_id),)).fetchone()
        if job is None or job["state"] == "deleted":
            raise ApiError(404, "NOT_FOUND", "Videojobbet blev ikke fundet på PC’en.")
        return job

    def _set_state(self, job_id, state, provider=None):
        with self.database() as db:
            db.execute("UPDATE studio_jobs SET state = ?, provider = COALESCE(?, provider) WHERE id = ?",
                       (state, provider, job_id))

    def _result(self, session, job):
        if job["state"] == "failed":
            return "failed", None
        base, provider = _provider_target(job["provider"])
        payload = _json(session, "GET", "/history/" + provider, base=base, limit=500_000)
        entry = payload.get(provider, {})
        state = entry.get("status", {}).get("status_str")
        if state == "error":
            return "failed", None
        for item in entry.get("outputs", {}).get("save", {}).get("images", []):
            name = item.get("filename", "")
            if (item.get("type") == "output" and item.get("subfolder") == FOLDER
                    and re.fullmatch(re.escape(job["id"]) + r"_[0-9]{5}_[.]mp4", name)):
                return "ready", name
        if state == "success" or time.time() - job["created"] > JOB_TIMEOUT:
            return "failed", None
        return "working", None

    def status(self, job_id):
        job = self._job(job_id)
        with _comfy() as session:
            state, _ = self._result(session, job)
        return {"id": job_id, "mode": job["mode"], "state": state}

    def submit(self, body):
        if not isinstance(body, dict):
            raise ApiError(422, "INVALID_INPUT", "Vælg en beskrivelse og en videomodel.")
        job_id = _id(body.get("id"))
        prompt = body.get("prompt")
        mode = next((mode for mode in MODES if mode.id == body.get("mode")), None)
        photos = body.get("photos")
        if (mode is None or not isinstance(prompt, str) or not 1 <= len(prompt.strip()) <= 1_000
                or not isinstance(photos, list) or len(photos) != mode.photos):
            raise ApiError(422, "INVALID_INPUT", "Skriv op til 1.000 tegn, og vælg billeder til den valgte model.")
        photos = [normalize_reference(photo) for photo in photos]
        digest = sha256(json.dumps([mode.id, prompt.strip(), [sha256(photo).hexdigest()
                        for photo in photos]]).encode()).hexdigest()
        with self.lock, _comfy() as session:
            with self.database() as db:
                existing = db.execute("SELECT * FROM studio_jobs WHERE id = ?", (job_id,)).fetchone()
                latest = db.execute("SELECT * FROM studio_jobs WHERE state != 'deleted' ORDER BY created DESC LIMIT 1").fetchone()
            if existing is not None:
                if existing["state"] == "deleted":
                    raise ApiError(404, "NOT_FOUND", "Videojobbet er slettet.")
                if existing["digest"] != digest:
                    raise ApiError(409, "REQUEST_REUSED", "Jobbet har allerede en anden beskrivelse.")
                state, _ = self._result(session, existing)
                return {"id": job_id, "mode": mode.id, "state": state}
            if latest is not None and self._result(session, latest)[0] == "working":
                raise ApiError(409, "NOT_READY", "Vent på den video, der allerede kører på PC’en.")
            available, modern_export, selected = _capabilities(session)
            mode = selected.get(mode.id, mode)
            base = COMFY
            prefix = ""
            if mode.id == ANIMATION_MODE.id and available.get(mode.id):
                animation, modern = _animation_backend(session)
                if animation is not None:
                    mode, modern_export = animation, modern
                    available[mode.id] = []
                    base, prefix = ANIMATION_COMFY, ANIMATION_PREFIX
            if mode.id not in available or available[mode.id]:
                raise _unavailable("Den valgte videomodel eller ComfyUI-udvidelse mangler på PC’en.")
            stills = [self._upload(session, job_id, index, photo, base=base) for index, photo in enumerate(photos)]
            graph = workflow(mode, prompt.strip(), stills, job_id, UUID(job_id).int % (2**53))
            if not modern_export:
                output = graph["save"]["inputs"]
                output["codec"] = output.pop("format.codec")
            with self.database() as db:
                db.execute("INSERT INTO studio_jobs VALUES (?, ?, ?, ?, 'submitted', ?)",
                           (job_id, mode.id, digest, prefix + job_id, time.time()))
            try:
                result = _json(session, "POST", "/prompt", base=base, json={"prompt": graph, "prompt_id": job_id})
            except ApiError as exc:
                if exc.code == "STUDIO_RECIPE_REJECTED":
                    self._set_state(job_id, "failed")
                raise
            provider = _id(result.get("prompt_id"))
            self._set_state(job_id, "submitted", prefix + provider)
            return {"id": job_id, "mode": mode.id, "state": "working"}

    def _upload(self, session, job_id, index, photo, *, base=None):
        name = f"{job_id}-{index}.png"
        uploaded = _json(session, "POST", "/upload/image", base=base, data={"type": "temp", "subfolder": FOLDER},
                         files={"image": (name, photo, "image/png")})
        if uploaded.get("name") != name or uploaded.get("subfolder") != FOLDER or uploaded.get("type") != "temp":
            raise _unavailable("PC’en kunne ikke gemme det valgte billede midlertidigt.")
        return f"{FOLDER}/{name} [temp]"

    def file(self, job_id):
        job = self._job(job_id)
        with _comfy() as session:
            state, name = self._result(session, job)
            if state != "ready":
                raise ApiError(404, "NOT_FOUND", "Videoen er endnu ikke klar.")
            base, _ = _provider_target(job["provider"])
            with session.get(base + "/view", params={"filename": name, "type": "output", "subfolder": FOLDER},
                             timeout=(2, 40), allow_redirects=False, stream=True) as response:
                if response.status_code != 200:
                    raise ApiError(404, "NOT_FOUND", "Videofilen ligger ikke længere på PC’en.")
                data = _read(response, MAX_VIDEO)
            if data[4:8] != b"ftyp":
                raise ApiError(502, "NOT_READY", "PC’en sendte ikke en gyldig MP4-video.")
            return bytes(data)

    def remove(self, job_id):
        job_id = _id(job_id)
        with self.lock:
            with self.database() as db:
                job = db.execute("SELECT * FROM studio_jobs WHERE id = ?", (job_id,)).fetchone()
            if job is None or job["state"] == "deleted":
                return {"ok": True}
            with _comfy() as session:
                if self._result(session, job)[0] == "working":
                    raise ApiError(409, "NOT_READY", "Vent til videojobbet er afsluttet.")
            base, _ = _provider_target(job["provider"])
            directory = _output_directory(base)
            pattern = re.compile(re.escape(job_id) + r"_[0-9]{5}_[.]mp4")
            try:
                files = [file for file in directory.iterdir() if pattern.fullmatch(file.name)] if directory.exists() else []
                if any(file.resolve() != file or not stat.S_ISREG(file.lstat().st_mode) for file in files):
                    raise OSError("Unexpected file type")
                for file in files:
                    file.unlink(missing_ok=True)
            except OSError as exc:
                raise _unavailable("Videofilen kunne ikke slettes fra PC’en.") from exc
            self._set_state(job_id, "deleted")
        return {"ok": True}


def _output_directory(base):
    if base == ANIMATION_COMFY:
        variable, default = "FADEDAI_ANIMATION_OUTPUT_DIR", "F:/FadedAI/FadedBot-media/output"
    else:
        variable, default = "FADEDAI_COMFY_OUTPUT_DIR", "F:/FadedAI/ComfyUI/output"
    output = Path(os.environ.get(variable, default))
    if not output.is_absolute() or not output.is_dir():
        raise _unavailable("PC’ens videooutputmappe er ikke tilgængelig for sletning.")
    try:
        directory = output.resolve(strict=True) / FOLDER
        if directory.resolve() != directory or (directory.exists() and not directory.is_dir()):
            raise OSError("Unexpected output folder")
    except OSError as exc:
        raise _unavailable("PC’ens videooutputmappe er ikke tilgængelig for sletning.") from exc
    return directory


def register_studio_video(app, settings, authorize):
    videos = StudioVideos(settings.output_root / "studio-video.sqlite3")

    def paired(request: Request, response: Response):
        authorize(request, settings)
        response.headers["Cache-Control"] = "no-store"

    router = APIRouter(prefix="/api/modules/v1/studio-video", dependencies=[Depends(paired)],
                       include_in_schema=False)

    @router.get("")
    def catalog():
        return videos.catalog()

    @router.put("")
    async def submit(request: Request):
        raw = bytearray()
        async for chunk in request.stream():
            if len(raw) + len(chunk) > MAX_BODY:
                raise ApiError(413, "INVALID_INPUT", "Vælg billeder på højst 1 MB hver.")
            raw.extend(chunk)
        try:
            body = json.loads(raw)
        except (ValueError, RecursionError) as exc:
            raise ApiError(422, "INVALID_INPUT", "Videoopgaven kunne ikke læses.") from exc
        return await run_in_threadpool(videos.submit, body)

    @router.get("/{job_id}")
    def status(job_id: str):
        return videos.status(job_id)

    @router.get("/{job_id}/file")
    def file(job_id: str):
        return Response(videos.file(job_id), media_type="video/mp4", headers={"Cache-Control": "no-store"})

    @router.put("/{job_id}/remove")
    def remove(job_id: str):
        return videos.remove(job_id)

    app.include_router(router)
    return videos

"""Paired PC API for short Creative Studio videos from installed ComfyUI models."""

from __future__ import annotations

import json
import re
import sqlite3
import time
from contextlib import closing, contextmanager
from hashlib import sha256
from threading import Lock
from uuid import UUID

import requests
from fastapi import APIRouter, Depends, Request, Response
from starlette.concurrency import run_in_threadpool

from sweatcaster.dto import ApiError
from sweatcaster.lumi_companion import normalize_reference
from sweatcaster.studio_video_workflows import MODES, workflow

COMFY = "http://127.0.0.1:8188"
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


def _json(session, method, path, *, limit=400_000, **kwargs):
    with session.request(method, COMFY + path, timeout=(2, 10), allow_redirects=False,
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


def _capabilities(session):
    schemas = {}

    def schema(node):
        if node not in schemas:
            schemas[node] = _json(session, "GET", f"/object_info/{node}").get(node, {})
        return schemas[node]

    if not schema("SaveVideo"):
        return {}, False
    old_export = schema("SaveVideo").get("input", {}).get("required", {}).get("format", [None])[0]
    modern_export = isinstance(old_export, str) and "DYNAMIC" in old_export
    available = {}
    for mode in MODES:
        missing = []
        graph = workflow(mode, "Prøve", ["example.png"] * mode.photos, "probe", 1)
        for kind in sorted({entry["class_type"] for entry in graph.values()}):
            if not schema(kind):
                missing.append(kind)
        for node, field, filename in mode.models:
            required = schema(node).get("input", {}).get("required", {})
            if schema(node) and filename not in (required.get(field) or [[]])[0]:
                missing.append(filename)
        available[mode.id] = missing
    return available, modern_export


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
        try:
            with _comfy() as session:
                available, _ = _capabilities(session)
            if not available:
                message = "Opdatér ComfyUI med videostøtte på PC’en."
            elif all(available.values()):
                message = "PC’en svarer. Se under den valgte model, hvad der mangler, før du kan lave video."
            else:
                message = None
        except ApiError as exc:
            available, message = {}, str(exc)
        with self.database() as db:
            previous = db.execute("SELECT id FROM studio_jobs ORDER BY created DESC LIMIT 1").fetchone()
        return {
            "modes": [{"id": mode.id, "title": mode.title, "photos": mode.photos,
                       "ready": mode.id in available and not available[mode.id],
                       "missing": available.get(mode.id, [])} for mode in MODES],
            "lastJob": previous["id"] if previous else None,
            "message": message,
        }

    def _job(self, job_id):
        with self.database() as db:
            job = db.execute("SELECT * FROM studio_jobs WHERE id = ?", (_id(job_id),)).fetchone()
        if job is None:
            raise ApiError(404, "NOT_FOUND", "Videojobbet blev ikke fundet på PC’en.")
        return job

    def _set_state(self, job_id, state, provider=None):
        with self.database() as db:
            db.execute("UPDATE studio_jobs SET state = ?, provider = COALESCE(?, provider) WHERE id = ?",
                       (state, provider, job_id))

    def _result(self, session, job):
        if job["state"] == "failed":
            return "failed", None
        payload = _json(session, "GET", "/history/" + job["provider"], limit=500_000)
        entry = payload.get(job["provider"], {})
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
                latest = db.execute("SELECT * FROM studio_jobs ORDER BY created DESC LIMIT 1").fetchone()
            if existing is not None:
                if existing["digest"] != digest:
                    raise ApiError(409, "REQUEST_REUSED", "Jobbet har allerede en anden beskrivelse.")
                state, _ = self._result(session, existing)
                return {"id": job_id, "mode": mode.id, "state": state}
            if latest is not None and self._result(session, latest)[0] == "working":
                raise ApiError(409, "NOT_READY", "Vent på den video, der allerede kører på PC’en.")
            available, modern_export = _capabilities(session)
            if mode.id not in available or available[mode.id]:
                raise _unavailable("Den valgte videomodel eller ComfyUI-udvidelse mangler på PC’en.")
            stills = [self._upload(session, job_id, index, photo) for index, photo in enumerate(photos)]
            graph = workflow(mode, prompt.strip(), stills, job_id, UUID(job_id).int % (2**53))
            if not modern_export:
                output = graph["save"]["inputs"]
                output["codec"] = output.pop("format.codec")
            with self.database() as db:
                db.execute("INSERT INTO studio_jobs VALUES (?, ?, ?, ?, 'submitted', ?)",
                           (job_id, mode.id, digest, job_id, time.time()))
            try:
                result = _json(session, "POST", "/prompt", json={"prompt": graph, "prompt_id": job_id})
            except ApiError as exc:
                if exc.code == "STUDIO_RECIPE_REJECTED":
                    self._set_state(job_id, "failed")
                raise
            provider = _id(result.get("prompt_id"))
            self._set_state(job_id, "submitted", provider)
            return {"id": job_id, "mode": mode.id, "state": "working"}

    def _upload(self, session, job_id, index, photo):
        name = f"{job_id}-{index}.png"
        uploaded = _json(session, "POST", "/upload/image", data={"type": "temp", "subfolder": FOLDER},
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
            with session.get(COMFY + "/view", params={"filename": name, "type": "output", "subfolder": FOLDER},
                             timeout=(2, 40), allow_redirects=False, stream=True) as response:
                if response.status_code != 200:
                    raise ApiError(404, "NOT_FOUND", "Videofilen ligger ikke længere på PC’en.")
                data = _read(response, MAX_VIDEO)
            if data[4:8] != b"ftyp":
                raise ApiError(502, "NOT_READY", "PC’en sendte ikke en gyldig MP4-video.")
            return bytes(data)


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

    app.include_router(router)

"""Paired music discovery and short-lived stream resolution. No AI calls."""

import importlib.util
import re
import threading
from urllib.parse import urlsplit

from fastapi import APIRouter, Body, Depends, Request, Response
from sweatcaster.dto import ApiError

_lock = threading.Lock()


class QuietLog:
    def debug(self, _message): pass
    def warning(self, _message): pass
    def error(self, _message): pass


def video_id(value):
    if not isinstance(value, str) or re.fullmatch(r"[A-Za-z0-9_-]{11}", value) is None:
        raise ApiError(422, "INVALID_INPUT", "Vælg et musiknummer fra søgeresultaterne.")
    return value


def extract(target, *, flat):
    try:
        from yt_dlp import YoutubeDL
    except ImportError as exc:
        raise ApiError(503, "NOT_READY", "Musikdelen mangler sin PC-opdatering.") from exc
    if not _lock.acquire(blocking=False):
        raise ApiError(429, "TOO_MANY_REQUESTS", "PC’en finder allerede musik. Prøv igen om lidt.")
    try:
        options = {"quiet": True, "no_warnings": True, "logger": QuietLog(), "skip_download": True,
                   "extract_flat": flat, "noplaylist": True, "socket_timeout": 15, "retries": 1,
                   "cachedir": False, "js_runtimes": {"node": {}},
                   "format": "bestaudio[ext=m4a]/best[ext=mp4]"}
        with YoutubeDL(options) as source:
            return source.extract_info(target, download=False)
    except ApiError:
        raise
    except Exception as exc:
        # Do not expose provider output, signed URLs or local configuration in errors.
        raise ApiError(503, "NOT_READY", "Musikkilden kunne ikke åbnes. Prøv et andet nummer eller søg igen.") from exc
    finally:
        _lock.release()


def search(query):
    if not isinstance(query, str) or not 1 <= len(query.strip()) <= 160 or not query.isprintable():
        raise ApiError(422, "INVALID_INPUT", "Skriv navnet på en sang eller kunstner.")
    result = extract("ytsearch12:" + query.strip(), flat=True) or {}
    tracks = []
    for entry in result.get("entries", []):
        if not isinstance(entry, dict) or not re.fullmatch(r"[A-Za-z0-9_-]{11}", str(entry.get("id", ""))):
            continue
        duration = entry.get("duration")
        if duration is not None and (not isinstance(duration, (int, float)) or not 0 < duration < 14_400):
            continue
        tracks.append({"id": entry["id"], "title": str(entry.get("title") or "Uden titel")[:240],
                       "artist": str(entry.get("channel") or entry.get("uploader") or "YouTube")[:160],
                       "duration": duration})
    return {"tracks": tracks}


def stream(identifier):
    result = extract("https://www.youtube.com/watch?v=" + video_id(identifier), flat=False) or {}
    if result.get("is_live") or result.get("has_drm"):
        raise ApiError(409, "CONFLICT", "Dette nummer kan ikke afspilles her.")
    url = result.get("url", "")
    parsed = urlsplit(url)
    host = (parsed.hostname or "").lower()
    if parsed.scheme != "https" or not host.endswith(".googlevideo.com") or parsed.username or parsed.password:
        raise ApiError(503, "NOT_READY", "Musikkilden gav ikke en gyldig lydadresse.")
    return {"url": url, "expiresIn": 1800}


def register_music(app, settings, authorize):
    def paired(request: Request, response: Response):
        authorize(request, settings)
        response.headers["Cache-Control"] = "no-store"

    router = APIRouter(prefix="/api/modules/v1/music", dependencies=[Depends(paired)], include_in_schema=False)

    @router.get("")
    def status():
        return {"ready": importlib.util.find_spec("yt_dlp") is not None, "source": "YouTube", "version": 1}

    @router.put("/search")
    def find(payload: dict = Body(...)):
        return search(payload.get("query"))

    @router.put("/stream")
    def resolve(payload: dict = Body(...)):
        return stream(payload.get("id"))

    app.include_router(router)

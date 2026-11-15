"""Use a provisioned Windows Speech resource without sharing its key with iOS."""

from base64 import b64encode
import json
import os
from pathlib import Path
import re
from tempfile import NamedTemporaryFile
from xml.sax.saxutils import escape

import requests
from fastapi import Body, Request, Response

from sweatcaster.dto import ApiError
from sweatcaster.emby_settings import _protect

VOICE = "da-DK-ChristelNeural"
REGION = re.compile(r"[a-z0-9]{2,30}")
KEY = re.compile(r"[!-~]{1,512}")
MAX_AUDIO = 1_400_000


def settings_path():
    return Path(os.environ["LOCALAPPDATA"]) / "FadedAI" / "christel.dpapi"


def valid(key, region):
    return isinstance(key, str) and isinstance(region, str) and KEY.fullmatch(key) and REGION.fullmatch(region)


def credentials():
    for prefix in ("SPEECH", "AZURE_SPEECH"):
        key = os.environ.get(prefix + "_KEY", "").strip()
        region = os.environ.get(prefix + "_REGION", "").strip().lower()
        if valid(key, region):
            return key, region
    if os.name == "nt":
        try:
            with settings_path().open("rb") as stream:
                data = stream.read(32_769)
            if len(data) <= 32_768:
                key, region = json.loads(_protect(data, decrypt=True))
                if valid(key, region):
                    return key, region
        except (OSError, ValueError, KeyError, TypeError):
            pass
    return None


def store(key, region):
    if not valid(key, region):
        raise ValueError("Azure gav ingen gyldig nøgle og region.")
    target = settings_path()
    target.parent.mkdir(parents=True, exist_ok=True)
    protected = _protect(json.dumps([key, region]).encode("utf-8"))
    scratch = None
    try:
        with NamedTemporaryFile(dir=target.parent, delete=False) as stream:
            scratch = Path(stream.name)
            stream.write(protected)
        scratch.replace(target)
    finally:
        if scratch is not None:
            scratch.unlink(missing_ok=True)


def markup(text):
    if not isinstance(text, str) or not 1 <= len(text.encode("utf-8", errors="replace")) <= 8_000:
        raise ApiError(422, "INVALID_INPUT", "Vælg et kortere svar til oplæsning.")
    text = "".join(char for char in text if char in "\t\r\n"
                   or 32 <= ord(char) <= 0xD7FF or 0xE000 <= ord(char) <= 0xFFFD
                   or 0x10000 <= ord(char) <= 0x10FFFF)
    if not text.strip():
        raise ApiError(422, "INVALID_INPUT", "Vælg et svar med tekst.")
    return ('<speak version="1.0" xmlns="http://www.w3.org/2001/10/synthesis" xml:lang="da-DK">'
            f'<voice name="{VOICE}">{escape(text)}</voice></speak>').encode("utf-8")


def synthesize(text):
    body = markup(text)
    configuration = credentials()
    if configuration is None:
        raise ApiError(503, "NOT_READY", "Forbind først Christel med din Speech-ressource på PC’en.")
    key, region = configuration
    url = f"https://{region}.tts.speech.microsoft.com/cognitiveservices/v1"
    try:
        with requests.Session() as session:
            session.trust_env = False
            with session.post(url, data=body, headers={
                "Ocp-Apim-Subscription-Key": key,
                "Content-Type": "application/ssml+xml",
                "X-Microsoft-OutputFormat": "audio-24khz-48kbitrate-mono-mp3",
                "User-Agent": "FadedAI",
            }, timeout=(5, 25), allow_redirects=False, stream=True) as response:
                if response.status_code in {401, 403}:
                    raise ApiError(503, "NOT_READY", "Microsoft afviste Speech-adgangen. Tjek ressourcen på PC’en.")
                mime = response.headers.get("Content-Type", "").partition(";")[0].strip().lower()
                if response.status_code != 200 or mime not in {"audio/mpeg", "audio/mp3"}:
                    raise ValueError("Unexpected Speech response")
                audio = bytearray()
                for chunk in response.iter_content(65_536):
                    audio.extend(chunk)
                    if len(audio) > MAX_AUDIO:
                        raise ValueError("Speech response too large")
        if audio:
            return {"audio": b64encode(audio).decode("ascii")}
    except (requests.RequestException, ValueError) as exc:
        raise ApiError(502, "NOT_READY", "Microsoft kunne ikke levere oplæsningen.") from exc
    raise ApiError(502, "NOT_READY", "Microsoft leverede ingen oplæsning.")


def register_christel(app, settings, authorize):
    @app.get("/api/modules/v1/christel", include_in_schema=False)
    def status(request: Request, response: Response):
        authorize(request, settings)
        response.headers["Cache-Control"] = "no-store"
        return {"configured": credentials() is not None}

    @app.put("/api/modules/v1/christel", include_in_schema=False)
    def play(request: Request, response: Response, body: dict = Body(...)):
        authorize(request, settings)
        response.headers["Cache-Control"] = "no-store"
        return synthesize(body.get("text"))

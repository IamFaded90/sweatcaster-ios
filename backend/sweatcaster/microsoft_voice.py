"""Use a provisioned Windows Speech resource without sharing its key with iOS."""

from base64 import b64encode
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
from tempfile import NamedTemporaryFile, TemporaryDirectory
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

    @app.put("/api/modules/v1/kokoro", include_in_schema=False)
    def local_play(request: Request, response: Response, body: dict = Body(...)):
        authorize(request, settings)
        response.headers["Cache-Control"] = "no-store"
        return synthesize_local(body.get("text"), body.get("voice"))

    @app.get("/api/modules/v1/agent-local-voices", include_in_schema=False)
    def local_voices(request: Request, response: Response):
        from sweatcaster.kokoro_voice import kokoro_ready

        authorize(request, settings)
        response.headers["Cache-Control"] = "no-store"
        voices = []
        if roest_installation():
            voices += ["roest-mic", "roest-nic"]
        if kokoro_ready()[0]:
            voices += ["kokoro-heart", "kokoro-michael"]
        return {"voices": voices}

    @app.put("/api/modules/v1/agent-local-voices", include_in_schema=False)
    def local_agent_speech(request: Request, response: Response, body: dict = Body(...)):
        authorize(request, settings)
        response.headers["Cache-Control"] = "no-store"
        if body.get("voice") == "piper-da":
            return synthesize_danish(body.get("text"), settings)
        if body.get("voice") in {"roest-mic", "roest-nic"}:
            return synthesize_roest(body.get("text"), body["voice"])
        kokoro_voice = {"kokoro-heart": "af_heart", "kokoro-michael": "am_michael"}.get(
            body.get("voice") if isinstance(body.get("voice"), str) else ""
        )
        if kokoro_voice is None:
            raise ApiError(422, "INVALID_INPUT", "Vælg en dansk eller engelsk PC-stemme.")
        return synthesize_local(body.get("text"), kokoro_voice)


def roest_installation():
    configured = os.environ.get("FADEDAI_ROEST_ROOT", "").strip()
    if not configured:
        try:
            from .roest_location import ROOT as configured
        except ImportError:
            configured = ""
    root = Path(configured) if configured else Path(__file__).resolve().parents[2] / "build"
    python = root / "roest-venv" / "Scripts" / "python.exe"
    model = root / "roest-model"
    package = root / "roest-venv" / "Lib" / "site-packages" / "chatterbox" / "mtl_tts.py"
    required = [python, package, root / "roest-ready.json", model / "t3_mtl23ls_v2.safetensors", model / "s3gen.pt",
                model / "ve.pt", model / "grapheme_mtl_merged_expanded_v1.json"]
    if not all(item.is_file() for item in required):
        return None
    if any(len(list((model / "audio_samples").glob(f"00_{speaker}_00_*.wav"))) != 1
           for speaker in ("mic", "nic")):
        return None
    return python, model


def synthesize_roest(text, voice):
    if not isinstance(text, str) or not 1 <= len(text.strip()) <= 500:
        raise ApiError(422, "INVALID_INPUT", "Vælg op til 500 tegn dansk tekst.")
    installation = roest_installation()
    if not installation:
        raise ApiError(503, "NOT_READY", "Røst-stemmen mangler på PC’en.")
    python, model = installation
    try:
        with TemporaryDirectory(prefix="fadedai-roest-") as directory:
            audio = Path(directory) / "reply.wav"
            result = subprocess.run([str(python), str(Path(__file__).with_name("roest_worker.py")),
                                     str(model), str(audio), voice.removeprefix("roest-")],
                                    input=json.dumps({"text": text.strip()}, ensure_ascii=True).encode("utf-8"),
                                    capture_output=True, check=False, timeout=180,
                                    creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
            if result.returncode:
                raise ValueError("Røst did not produce audio.")
            with audio.open("rb") as handle:
                data = handle.read(4_000_001)
            if not 44 < len(data) <= 4_000_000 or data[:4] != b"RIFF" or data[8:12] != b"WAVE":
                raise ValueError("Invalid WAV.")
            return {"audio": b64encode(data).decode("ascii")}
    except (OSError, subprocess.TimeoutExpired, ValueError) as exc:
        raise ApiError(503, "NOT_READY", "Røst-stemmen kunne ikke læse teksten op på PC’en.") from exc


def danish_piper(settings):
    model_name = "da_DK-talesyntese-medium.onnx"
    asset_root = os.environ.get("FADEDAI_ASSET_ROOT")
    roots = ([Path(asset_root)] if asset_root else []) + [Path("F:/FadedAI"), Path("H:/FadedAI")]
    config_model = getattr(settings, "piper_model", None)
    candidates = [root / "FadedBot-voice" / "models" / model_name for root in roots]
    if config_model is not None and config_model.name == model_name:
        candidates.insert(0, config_model)
    model = next((path for path in candidates if path.is_file() and path.with_suffix(".onnx.json").is_file()), None)
    configured_bin = getattr(settings, "piper_bin", "piper")
    windows_bin = Path(os.environ.get("LOCALAPPDATA", "")) / "SweatCaster/bin/piper/piper.exe"
    # Optional isolated development install, beside the checkout. A deployed PC can
    # instead configure its existing Piper installation through FADEDAI_PIPER_BIN.
    local_bin = Path(__file__).resolve().parents[3] / ".local-piper" / "Scripts" / "piper.exe"
    override = os.environ.get("FADEDAI_PIPER_BIN", "").strip()
    binary = (shutil.which(override) if override else None) or shutil.which(configured_bin)
    if not binary:
        binary = next((str(path) for path in (windows_bin, local_bin) if path.is_file()), None)
    return (binary, model) if binary and model is not None else None


def synthesize_danish(text, settings):
    from sweatcaster.tts import piper_command

    if not isinstance(text, str) or not 1 <= len(text.strip()) <= 500:
        raise ApiError(422, "INVALID_INPUT", "Vælg op til 500 tegn dansk tekst.")
    installation = danish_piper(settings)
    if installation is None:
        raise ApiError(503, "NOT_READY", "Den danske stemmepakke mangler på den parrede PC.")
    binary, model = installation
    try:
        with TemporaryDirectory(prefix="fadedai-piper-") as directory:
            audio = Path(directory) / "reply.wav"
            result = subprocess.run(piper_command(binary, model, audio), input=text.strip().encode("utf-8"),
                                    capture_output=True, check=False, timeout=45,
                                    creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
            if result.returncode:
                raise ValueError("Piper did not produce audio.")
            with audio.open("rb") as handle:
                data = handle.read(4_000_001)
            if not 44 < len(data) <= 4_000_000 or data[:4] != b"RIFF" or data[8:12] != b"WAVE":
                raise ValueError("Invalid WAV.")
            return {"audio": b64encode(data).decode("ascii")}
    except (OSError, subprocess.TimeoutExpired, ValueError) as exc:
        raise ApiError(503, "NOT_READY", "Den danske PC-stemme kunne ikke læse teksten op.") from exc


def synthesize_local(text, voice):
    from sweatcaster.kokoro_voice import CHAT_VOICES, KokoroSynthesisError, kokoro_ready, synthesize_kokoro

    if not isinstance(text, str) or not 1 <= len(text.strip()) <= 500 or voice not in CHAT_VOICES:
        raise ApiError(422, "INVALID_INPUT", "Vælg en Kokoro-stemme og op til 500 tegn engelsk tekst.")
    if not kokoro_ready()[0]:
        raise ApiError(503, "NOT_READY", "Kokoro eller stemmepakken mangler på den parrede PC.")
    try:
        with TemporaryDirectory(prefix="fadedai-voice-") as directory:
            audio = Path(directory) / "reply.wav"
            synthesize_kokoro(text.strip(), audio, voice=voice)
            with audio.open("rb") as handle:
                data = handle.read(4_000_001)
            if not 44 < len(data) <= 4_000_000 or data[:4] != b"RIFF" or data[8:12] != b"WAVE":
                raise KokoroSynthesisError("Invalid WAV.")
            return {"audio": b64encode(data).decode("ascii")}
    except (OSError, KokoroSynthesisError) as exc:
        raise ApiError(503, "NOT_READY", "Kokoro kunne ikke læse teksten op på PC’en.") from exc

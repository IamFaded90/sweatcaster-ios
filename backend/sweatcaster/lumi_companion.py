"""Paired, bot-scoped local models for the optional adult companion Lumi."""

from __future__ import annotations

import base64
import binascii
from io import BytesIO
import json
import os
from pathlib import Path
import re
import stat
import time
import shutil
import subprocess
from concurrent.futures import ThreadPoolExecutor
from threading import Lock
from uuid import UUID, uuid4

import requests
from fastapi import APIRouter, Body, Depends, FastAPI, Request, Response

from sweatcaster.dto import ApiError

LUMI_ID = "ecba4ff7-69b2-5a9c-a028-d93ef6ec7983"
TEXT_MODEL = "hf.co/bartowski/Lumimaid-v0.2-12B-GGUF:Q4_K_M"
IMAGE_MODEL = "RealVisXL_V5.0_fp16.safetensors"
PONY_MODEL = "CyberRealisticPony_V18.0_F16.safetensors"
VIDEO_MODEL = "wan2.1_t2v_1.3B_fp16.safetensors"
VIDEO_CLIP = "umt5_xxl_fp8_e4m3fn_scaled.safetensors"
VIDEO_VAE = "wan_2.1_vae.safetensors"
OLLAMA = "http://127.0.0.1:11434"
COMFY = "http://127.0.0.1:8188"
MAX_REFERENCE = 1_000_000
VIDEO_OUTPUT_FOLDER = "FadedAI_Lumi"
_video_executor = ThreadPoolExecutor(max_workers=1, thread_name_prefix="lumi-video")
_video_lock = Lock()
_video_jobs: dict[str, dict] = {}
INSTRUCTIONS = (
    "You are Lumi, an adult, playful and flirtatious private companion. "
    "Be warm, imaginative and direct. Understand Danish, imperfect English, "
    "misspellings and mixed Danish/English. Infer intent from context. Never correct their "
    "spelling or grammar unless asked. Do not claim to have taken real-world "
    "actions or accessed accounts when you have not. "
    "Respond to the user's latest message in the ongoing conversation. "
    "Do not restart with a greeting or repeat your previous question after the user has answered it. "
    "If a message is too unclear to understand, ask one short clarification about that message."
)
SCENE_INITIATIVES = {
    "user": "Follow the user's lead. Wait for their next decision and do not steer the scene uninvited.",
    "together": "Build the scene together. Offer a natural next beat while leaving room for the user's choice.",
    "lumi": "Take initiative in character. Move one beat forward, choose a concrete detail, and leave the user's words and actions to them.",
}
SCENE_MOODS = {
    "playful": "Use playful adult flirting, teasing and warmth.",
    "romantic": "Use a romantic, affectionate tone with a slower buildup.",
    "bold": "Use more confident and suggestive adult flirting, matching what the user brings to the scene.",
}
SCENE_FIELDS = {"title": 80, "lumiRole": 300, "userRole": 300, "setting": 800}


def _message(value: object, *, limit: int = 4000) -> str:
    if not isinstance(value, str) or not 1 <= len(value.strip()) <= limit:
        raise ApiError(422, "INVALID_INPUT", "Skriv en kort besked til Lumi.")
    return value.strip()


def _bot(value: str) -> None:
    try:
        valid = str(UUID(value)) == LUMI_ID
    except (TypeError, ValueError, AttributeError):
        valid = False
    if not valid:
        raise ApiError(404, "NOT_FOUND", "Lumis private modeller tilhører kun Lumi.")


def _client() -> requests.Session:
    client = requests.Session()
    client.trust_env = False
    return client


def scene_instructions(card, initiative, opening):
    if not isinstance(initiative, str) or initiative not in SCENE_INITIATIVES or type(opening) is not bool:
        raise ApiError(422, "INVALID_INPUT", "Vælg, hvem der tager initiativ i scenen.")
    instructions = [SCENE_INITIATIVES["lumi" if opening else initiative]]
    if card is not None:
        if (not isinstance(card, dict) or set(card) != set(SCENE_FIELDS) | {"mood"}
                or not isinstance(card["mood"], str) or card["mood"] not in SCENE_MOODS):
            raise ApiError(422, "INVALID_INPUT", "Scenekortet kunne ikke læses.")
        scene = {}
        for key, limit in SCENE_FIELDS.items():
            value = card[key]
            if not isinstance(value, str) or len(value) > limit:
                raise ApiError(422, "INVALID_INPUT", "Forkort teksten på scenekortet.")
            scene[key] = value.strip()
        if not scene["title"]:
            raise ApiError(422, "INVALID_INPUT", "Giv scenekortet et navn.")
        instructions.append(SCENE_MOODS[card["mood"]])
        instructions.append("Use this fictional scene card as background: " + json.dumps(scene, ensure_ascii=False))
    if opening:
        instructions.append("Open or continue the current scene with one short proactive in-character turn. "
                            "If recent dialogue exists, continue from where it stopped. Do not restart or summarize. "
                            "Keep the user's reply open for them.")
    return " ".join(instructions)


def chat(message: str, history: list[dict] | None = None, *, language: str = "da-DK",
         scene=None, initiative="together", opening=False, scene_chat=False, client: requests.Session | None = None) -> str:
    message = _message(message)
    if history is None:
        history = []
    if not isinstance(history, list) or len(history) > 16:
        raise ApiError(422, "INVALID_INPUT", "Samtalen er for lang. Start en ny samtale.")
    if language not in ("da-DK", "en-US"):
        raise ApiError(422, "INVALID_INPUT", "Vælg dansk eller engelsk.")
    reply_language = "Danish" if language == "da-DK" else "English"
    instructions = INSTRUCTIONS + f" Reply in {reply_language} unless the user explicitly requests Danish or English."
    if scene_chat:
        instructions += " " + scene_instructions(scene, initiative, opening)
    messages = [{"role": "system", "content": instructions}]
    for item in history:
        if not isinstance(item, dict) or item.get("role") not in {"user", "assistant"}:
            raise ApiError(422, "INVALID_INPUT", "Samtalens historik er ugyldig.")
        messages.append({"role": item["role"], "content": _message(item.get("content"))})
    messages.append({"role": "user", "content": message})
    owned = client is None
    client = client or _client()
    try:
        response = client.post(OLLAMA + "/api/chat", json={"model": TEXT_MODEL, "messages": messages,
                              "stream": False, "options": {"num_ctx": 4096}},
                               timeout=(3, 180), allow_redirects=False)
        response.raise_for_status()
        answer = response.json()["message"]["content"]
        if not isinstance(answer, str) or not answer.strip():
            raise ValueError("empty response")
        return answer.strip()
    except (requests.RequestException, KeyError, TypeError, ValueError) as exc:
        raise ApiError(503, "NOT_READY", "Lumis tekstmodel svarer ikke på PC'en. Tjek Ollama.") from exc
    finally:
        if owned:
            client.close()


def normalize_reference(value):
    if not isinstance(value, str) or not 1 <= len(value) <= 4 * ((MAX_REFERENCE + 2) // 3):
        raise ApiError(422, "INVALID_INPUT", "Vælg ét referencebillede under 1 MB.")
    try:
        from PIL import Image, ImageOps
    except ImportError as exc:
        raise ApiError(503, "NOT_READY", "PC’en mangler billedbiblioteket Pillow.") from exc
    try:
        raw = base64.b64decode(value, validate=True)
        if len(raw) > MAX_REFERENCE:
            raise ValueError
        with Image.open(BytesIO(raw), formats=("JPEG", "PNG")) as selected:
            if not all(32 <= side <= 2048 for side in selected.size) or getattr(selected, "is_animated", False):
                raise ValueError
            image = ImageOps.exif_transpose(selected).convert("RGB")
            image.thumbnail((768, 768), Image.Resampling.LANCZOS)
            size = tuple(max(8, side - side % 8) for side in image.size)
            image = image.resize(size, Image.Resampling.LANCZOS)
            image.info.clear()
            output = BytesIO()
            image.save(output, "PNG")
        return output.getvalue()
    except (ValueError, OSError, binascii.Error, Image.DecompressionBombError) as exc:
        raise ApiError(422, "INVALID_INPUT", "Referencebilledet kunne ikke læses som et foto.") from exc


def _edit_mask(value, reference):
    from PIL import Image

    try:
        if reference is None or not isinstance(value, str) or not 1 <= len(value) <= 350_000:
            raise ValueError
        raw = base64.b64decode(value, validate=True)
        with Image.open(BytesIO(raw), formats=("PNG",)) as selected:
            if not all(32 <= side <= 1024 for side in selected.size) or getattr(selected, "is_animated", False):
                raise ValueError
            with Image.open(BytesIO(reference)) as photo:
                if abs(selected.width / selected.height - photo.width / photo.height) > 0.12:
                    raise ValueError
                mask = selected.convert("L").resize(photo.size, Image.Resampling.NEAREST)
            mask = mask.point(lambda level: 255 if level >= 128 else 0)
            if mask.getextrema()[1] == 0:
                raise ValueError
            output = BytesIO()
            mask.save(output, "PNG")
            return output.getvalue()
    except (binascii.Error, OSError, ValueError, Image.DecompressionBombError) as exc:
        raise ApiError(422, "INVALID_INPUT", "Markeringen passer ikke til referencefotoet. Prøv at tegne den igen.") from exc


def _temp_upload(client, name, data):
    uploaded = client.post(COMFY + "/upload/image", data={"type": "temp"},
                           files={"image": (name, data, "image/png")}, timeout=(3, 20), allow_redirects=False)
    uploaded.raise_for_status()
    receipt = uploaded.json()
    if (not isinstance(receipt, dict) or receipt.get("type") != "temp"
            or receipt.get("name") != name or receipt.get("subfolder", "") != ""):
        raise ApiError(502, "NOT_READY", "PC’en kunne ikke klargøre referencebilledet.")


def _remove_private_image_files(files):
    root = Path(os.environ.get("FADEDAI_COMFY_TEMP_DIR", "F:/FadedAI/ComfyUI/temp")).resolve()
    for name in files:
        if not re.fullmatch(r"(?:fadedai-private-[a-f0-9]{32}|ComfyUI_temp_[A-Za-z0-9_]{1,80})\.png", name):
            continue
        path = root / name
        try:
            if path.is_file() and not path.is_symlink():
                path.unlink()
        except OSError:
            pass


def _flux_available(client, adult=False):
    from sweatcaster import lumi_flux
    return lumi_flux.availability(client, COMFY, PONY_MODEL)["flux2Adult" if adult else "flux2"]


def _pony_available(client):
    from sweatcaster import lumi_flux
    return lumi_flux.availability(client, COMFY, PONY_MODEL)["pony"]


def image(prompt: str, *, reference=None, client: requests.Session | None = None, timeout: float = 300,
          private=False, mask=None, strength=None, seed=None, negative=None, engine=None) -> bytes:
    prompt = _message(prompt, limit=1000)
    if engine not in (None, "realvis", "pony", "flux2", "flux2-adult"):
        raise ApiError(422, "INVALID_INPUT", "Vælg en af PC'ens billedmodeller.")
    reference = normalize_reference(reference) if reference is not None else None
    mask = _edit_mask(mask, reference) if mask is not None else None
    if strength is not None and (type(strength) not in (int, float) or not 0.1 <= strength <= 1):
        raise ApiError(422, "INVALID_INPUT", "Vælg hvor meget referencebilledet må ændres.")
    if seed is not None and (type(seed) is not int or not 0 <= seed <= 0xFFFFFFFF):
        raise ApiError(422, "INVALID_INPUT", "Det valgte seed er ugyldigt.")
    if negative is not None and (not isinstance(negative, str) or len(negative) > 1_000):
        raise ApiError(422, "INVALID_INPUT", "Forkort beskrivelsen af, hvad billedet skal undgå.")
    owned = client is None
    client = client or _client()
    submitted = False
    finished = False
    temporary_files = []
    try:
        if engine not in ("flux2", "flux2-adult"):
            info = client.get(COMFY + "/object_info/CheckpointLoaderSimple", timeout=(3, 15), allow_redirects=False)
            info.raise_for_status()
            choices = info.json()["CheckpointLoaderSimple"]["input"]["required"]["ckpt_name"][0]
            selected_model = {"pony": PONY_MODEL}.get(engine, IMAGE_MODEL)
            if selected_model not in choices:
                raise ApiError(503, "NOT_READY", "Lumis billedmodel mangler i ComfyUI på PC'en.")
        graph = {
            "1": {"class_type": "CheckpointLoaderSimple", "inputs": {"ckpt_name": {"pony": PONY_MODEL}.get(engine, IMAGE_MODEL)}},
            "2": {"class_type": "CLIPTextEncode", "inputs": {"text": prompt, "clip": ["1", 1]}},
            "3": {"class_type": "CLIPTextEncode", "inputs": {"text": negative or "low quality, blurry, distorted, deformed anatomy, extra limbs, monster", "clip": ["1", 1]}},
            "4": {"class_type": "EmptyLatentImage", "inputs": {"width": 768, "height": 768, "batch_size": 1}},
            "5": {"class_type": "KSampler", "inputs": {"seed": seed if seed is not None else int(time.time_ns() % (2**53)),
                  "steps": 25, "cfg": 5.5, "sampler_name": "euler", "scheduler": "normal", "denoise": 1,
                  "model": ["1", 0], "positive": ["2", 0], "negative": ["3", 0], "latent_image": ["4", 0]}},
            "6": {"class_type": "VAEDecode", "inputs": {"samples": ["5", 0], "vae": ["1", 2]}},
            "7": {"class_type": "PreviewImage", "inputs": {"images": ["6", 0]}},
        }
        if reference is not None:
            prefix = "fadedai-private" if private else "fadedai-lumi"
            name = f"{prefix}-{uuid4().hex}.png"
            temporary_files.append(name)
            _temp_upload(client, name, reference)
            graph["8"] = {"class_type": "LoadImage", "inputs": {"image": name + " [temp]"}}
            graph["4"] = {"class_type": "VAEEncode", "inputs": {"pixels": ["8", 0], "vae": ["1", 2]}}
            graph["5"]["inputs"]["denoise"] = 0.55 if strength is None else strength
            if mask is not None:
                name = f"{prefix}-{uuid4().hex}.png"
                temporary_files.append(name)
                _temp_upload(client, name, mask)
                graph["9"] = {"class_type": "LoadImageMask", "inputs": {"image": name + " [temp]", "channel": "red"}}
                # Prepare the marked region as an inpaint latent instead of encoding
                # the original clothes into the region that should be repainted.
                graph["4"] = {"class_type": "VAEEncodeForInpaint", "inputs": {
                    "pixels": ["8", 0], "vae": ["1", 2], "mask": ["9", 0], "grow_mask_by": 8}}
                graph["11"] = {"class_type": "ImageCompositeMasked", "inputs": {
                    "destination": ["8", 0], "source": ["6", 0], "mask": ["9", 0], "x": 0, "y": 0, "resize_source": True}}
                graph["7"]["inputs"]["images"] = ["11", 0]
        if engine in ("flux2", "flux2-adult"):
            from sweatcaster import lumi_flux
            # Validate before submission; never fall back silently to a different model.
            if not _flux_available(client, adult=engine == "flux2-adult"):
                raise ApiError(503, "NOT_READY", "FLUX 2 mangler på PC’en. Vælg RealVisXL eller hent modellen.")
            width, height = 768, 768
            reference_name = temporary_files[0] if reference is not None else None
            mask_name = temporary_files[1] if mask is not None else None
            if reference is not None:
                from PIL import Image
                with Image.open(BytesIO(reference)) as source:
                    width = max(16, source.width - source.width % 16)
                    height = max(16, source.height - source.height % 16)
            graph = lumi_flux.graph(prompt, seed if seed is not None else int(time.time_ns() % (2**53)),
                                    width, height, reference_name, mask_name, adult=engine == "flux2-adult")
        queued = client.post(COMFY + "/prompt", json={"prompt": graph}, timeout=(3, 20), allow_redirects=False)
        queued.raise_for_status()
        prompt_id = str(queued.json()["prompt_id"])
        submitted = True
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            result = client.get(COMFY + "/history/" + prompt_id, timeout=(3, 15), allow_redirects=False)
            result.raise_for_status()
            entry = result.json().get(prompt_id)
            if entry:
                if entry.get("status", {}).get("status_str") == "error":
                    finished = True
                    raise ApiError(502, "NOT_READY", "ComfyUI kunne ikke lave billedet.")
                outputs = entry.get("outputs", {}).get("7", {}).get("images", [])
                if outputs:
                    item = outputs[0]
                    finished = True
                    if private and item.get("type") == "temp" and not item.get("subfolder"):
                        temporary_files.append(item["filename"])
                    rendered = client.get(COMFY + "/view", params={"filename": item["filename"],
                        "subfolder": item.get("subfolder", ""), "type": item.get("type", "output")},
                        timeout=(3, 30), allow_redirects=False)
                    rendered.raise_for_status()
                    data = rendered.content
                    if len(data) > 15_000_000 or not data.startswith(b"\x89PNG\r\n\x1a\n"):
                        raise ApiError(502, "NOT_READY", "ComfyUI sendte ikke et gyldigt billede.")
                    if private:
                        from PIL import Image

                        with Image.open(BytesIO(data), formats=("PNG",)) as preview:
                            clean = preview.convert("RGB")
                            clean.info.clear()
                            plain = BytesIO()
                            clean.save(plain, "PNG")
                            return plain.getvalue()
                    return data
            time.sleep(1)
        raise ApiError(504, "NOT_READY", "Billedet tog for lang tid. Prøv igen.")
    except (requests.RequestException, KeyError, TypeError, ValueError) as exc:
        raise ApiError(503, "NOT_READY", "ComfyUI svarer ikke på PC'en.") from exc
    finally:
        if private and (finished or not submitted):
            _remove_private_image_files(temporary_files)
            if finished:
                try:
                    client.post(COMFY + "/history", json={"delete": [prompt_id]}, timeout=(2, 3), allow_redirects=False)
                except requests.RequestException:
                    pass
        if submitted:
            try:
                client.post(COMFY + "/free", json={"unload_models": True, "free_memory": True},
                            timeout=(2, 3), allow_redirects=False)
            except requests.RequestException:
                pass
        if owned:
            client.close()


def video(prompt: str, *, client: requests.Session | None = None, timeout: float = 1200,
          output_id: str | None = None) -> bytes:
    """Render a short Wan 2.1 clip, then convert ComfyUI's WebM for iPhone playback."""
    prompt = _message(prompt, limit=1000)
    ffmpeg = shutil.which("ffmpeg")
    if ffmpeg is None:
        raise ApiError(503, "NOT_READY", "PC'en mangler FFmpeg til iPhone-video.")
    owned = client is None
    client = client or _client()
    try:
        for node, field, filename in (("UNETLoader", "unet_name", VIDEO_MODEL),
                                      ("CLIPLoader", "clip_name", VIDEO_CLIP),
                                      ("VAELoader", "vae_name", VIDEO_VAE)):
            info = client.get(COMFY + "/object_info/" + node, timeout=(3, 15), allow_redirects=False)
            info.raise_for_status()
            choices = info.json()[node]["input"]["required"][field][0]
            if filename not in choices:
                raise ApiError(503, "NOT_READY", "Lumis videomodel mangler i ComfyUI på PC'en.")
        graph = {
            "1": {"class_type": "UNETLoader", "inputs": {"unet_name": VIDEO_MODEL, "weight_dtype": "default"}},
            "2": {"class_type": "ModelSamplingSD3", "inputs": {"model": ["1", 0], "shift": 8}},
            "3": {"class_type": "CLIPLoader", "inputs": {"clip_name": VIDEO_CLIP, "type": "wan", "device": "default"}},
            "4": {"class_type": "CLIPTextEncode", "inputs": {"text": prompt, "clip": ["3", 0]}},
            "5": {"class_type": "CLIPTextEncode", "inputs": {"text": "low quality, blurry, static, watermark", "clip": ["3", 0]}},
            "6": {"class_type": "VAELoader", "inputs": {"vae_name": VIDEO_VAE}},
            "7": {"class_type": "EmptyHunyuanLatentVideo", "inputs": {"width": 512, "height": 288,
                                                                "length": 17, "batch_size": 1}},
            "8": {"class_type": "KSampler", "inputs": {"seed": int(time.time_ns() % (2**53)),
                  "steps": 20, "cfg": 6, "sampler_name": "uni_pc", "scheduler": "simple", "denoise": 1,
                  "model": ["2", 0], "positive": ["4", 0], "negative": ["5", 0], "latent_image": ["7", 0]}},
            "9": {"class_type": "VAEDecodeTiled", "inputs": {"samples": ["8", 0], "vae": ["6", 0],
                  "tile_size": 192, "overlap": 32, "temporal_size": 8, "temporal_overlap": 4}},
            "10": {"class_type": "SaveWEBM", "inputs": {"images": ["9", 0],
                   "filename_prefix": VIDEO_OUTPUT_FOLDER if output_id is None else f"{VIDEO_OUTPUT_FOLDER}/{output_id}",
                   "codec": "vp9", "fps": 12, "crf": 32}},
        }
        queued = client.post(COMFY + "/prompt", json={"prompt": graph}, timeout=(3, 20), allow_redirects=False)
        queued.raise_for_status()
        prompt_id = str(queued.json()["prompt_id"])
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            result = client.get(COMFY + "/history/" + prompt_id, timeout=(3, 15), allow_redirects=False)
            result.raise_for_status()
            entry = result.json().get(prompt_id)
            if entry:
                if entry.get("status", {}).get("status_str") == "error":
                    raise ApiError(502, "NOT_READY", "ComfyUI kunne ikke lave videoen.")
                output = entry.get("outputs", {}).get("10", {})
                files = output.get("images", []) or output.get("gifs", []) or output.get("videos", [])
                if files:
                    item = files[0]
                    if output_id and (item.get("type") != "output" or item.get("subfolder") != VIDEO_OUTPUT_FOLDER
                                      or not _video_filename(output_id).fullmatch(item.get("filename", ""))):
                        raise ApiError(502, "NOT_READY", "Videomotoren sendte en uventet fil.")
                    rendered = client.get(COMFY + "/view", params={"filename": item["filename"],
                        "subfolder": item.get("subfolder", ""), "type": item.get("type", "output")},
                        timeout=(3, 60), allow_redirects=False)
                    rendered.raise_for_status()
                    if len(rendered.content) > 35_000_000 or not rendered.content.startswith(b"\x1a\x45\xdf\xa3"):
                        raise ApiError(502, "NOT_READY", "ComfyUI sendte ikke en gyldig video.")
                    converted = subprocess.run([ffmpeg, "-hide_banner", "-loglevel", "error", "-i", "pipe:0",
                        "-an", "-c:v", "libx264", "-pix_fmt", "yuv420p", "-movflags",
                        "frag_keyframe+empty_moov", "-f", "mp4", "pipe:1"], input=rendered.content,
                        capture_output=True, timeout=120, check=True)
                    if not converted.stdout.startswith(b"\x00\x00") or len(converted.stdout) > 40_000_000:
                        raise ApiError(502, "NOT_READY", "PC'en kunne ikke gøre videoen klar til iPhone.")
                    return converted.stdout
            time.sleep(3)
        raise ApiError(504, "NOT_READY", "Videoen tog for lang tid. Prøv en kortere idé.")
    except (requests.RequestException, KeyError, TypeError, ValueError, subprocess.SubprocessError) as exc:
        raise ApiError(503, "NOT_READY", "Lumis videomotor svarer ikke på PC'en.") from exc
    finally:
        try:
            client.post(COMFY + "/free", json={"unload_models": True, "free_memory": True},
                        timeout=(2, 3), allow_redirects=False)
        except requests.RequestException:
            pass
        if owned:
            client.close()


def _video_filename(job_id: str):
    return re.compile(re.escape(job_id) + r"_[0-9]{5}_[.]webm")


def _remove_owned_video(job_id: str) -> None:
    output = Path(os.environ.get("FADEDAI_COMFY_OUTPUT_DIR", "F:/FadedAI/ComfyUI/output"))
    try:
        if not output.is_absolute() or not output.is_dir():
            raise OSError("Missing output folder")
        directory = output.resolve(strict=True) / VIDEO_OUTPUT_FOLDER
        if directory.resolve() != directory:
            raise OSError("Unexpected output folder")
        pattern = _video_filename(job_id)
        files = [file for file in directory.iterdir() if pattern.fullmatch(file.name)] if directory.exists() else []
        if any(file.resolve() != file or not stat.S_ISREG(file.lstat().st_mode) for file in files):
            raise OSError("Unexpected file type")
        for file in files:
            file.unlink(missing_ok=True)
    except OSError as exc:
        raise ApiError(503, "NOT_READY", "Lumis videofil kunne ikke slettes på PC’en.") from exc


def _render_video(job_id: str, prompt: str) -> None:
    try:
        payload = video(prompt, output_id=job_id)
        result = {"status": "ready", "data": payload, "removable": True}
    except Exception as exc:
        result = {"status": "failed", "message": getattr(exc, "message", "Videoen fejlede på PC'en.")}
    with _video_lock:
        _video_jobs[job_id] = result


def register_lumi(app: FastAPI, settings, authorize) -> None:
    def paired(request: Request, response: Response):
        authorize(request, settings)
        response.headers["Cache-Control"] = "no-store"

    router = APIRouter(prefix="/api/modules/v1/lumi/{bot_id}",
                       dependencies=[Depends(paired)], include_in_schema=False)

    @router.post("/chat")
    def chat_route(bot_id: str, body: dict = Body(...)):
        _bot(bot_id)
        return {"reply": chat(body.get("message"), body.get("history"), language=body.get("language", "da-DK"))}

    @router.post("/scene-chat")
    def scene_chat_route(bot_id: str, body: dict = Body(...)):
        _bot(bot_id)
        return {"reply": chat(body.get("message"), body.get("history"), language=body.get("language", "da-DK"),
                              scene=body.get("scene"), initiative=body.get("initiative", "together"),
                              opening=body.get("opening", False), scene_chat=True)}

    @router.post("/image")
    def image_route(bot_id: str, body: dict = Body(...)):
        _bot(bot_id)
        return Response(image(body.get("prompt"), reference=body.get("reference")), media_type="image/png",
                        headers={"Cache-Control": "no-store"})

    @router.post("/private-image")
    def private_image_route(bot_id: str, body: dict = Body(...)):
        _bot(bot_id)
        data = image(body.get("prompt"), reference=body.get("reference"), private=True, mask=body.get("mask"),
                     seed=body.get("seed"), strength=body.get("strength"), negative=body.get("negative"),
                     engine=body.get("engine"))
        return Response(data, media_type="image/png", headers={"Cache-Control": "no-store"})

    @router.post("/private-image-models")
    def private_image_models(bot_id: str):
        _bot(bot_id)
        client = _client()
        try:
            from sweatcaster import lumi_flux
            return lumi_flux.availability(client, COMFY, PONY_MODEL)
        finally:
            client.close()

    @router.post("/video")
    def video_route(bot_id: str, body: dict = Body(...)):
        _bot(bot_id)
        prompt = _message(body.get("prompt"), limit=1000)
        with _video_lock:
            if sum(job["status"] == "working" for job in _video_jobs.values()) >= 1:
                raise ApiError(409, "CONFLICT", "Lumi laver allerede en video.")
            _video_jobs.clear()
            job_id = str(uuid4())
            _video_jobs[job_id] = {"status": "working"}
        _video_executor.submit(_render_video, job_id, prompt)
        return {"id": job_id, "status": "working"}

    @router.get("/video/{job_id}")
    def video_status(bot_id: str, job_id: str):
        _bot(bot_id)
        with _video_lock:
            job = _video_jobs.get(job_id)
            if job is None:
                raise ApiError(404, "NOT_FOUND", "Videojobbet findes ikke.")
            return {key: value for key, value in job.items() if key != "data"} | {"id": job_id}

    @router.get("/video/{job_id}/file")
    def video_file(bot_id: str, job_id: str):
        _bot(bot_id)
        with _video_lock:
            job = _video_jobs.get(job_id)
            if job is None or job["status"] != "ready":
                raise ApiError(404, "NOT_FOUND", "Videoen er ikke klar.")
            payload = job["data"]
        return Response(payload, media_type="video/mp4", headers={"Cache-Control": "no-store"})

    @router.put("/video/{job_id}/remove")
    def remove_video(bot_id: str, job_id: str):
        _bot(bot_id)
        try:
            valid = str(UUID(job_id)) == job_id
        except (ValueError, TypeError):
            valid = False
        if not valid:
            raise ApiError(422, "INVALID_INPUT", "Ugyldigt videojob.")
        with _video_lock:
            job = _video_jobs.get(job_id)
            if job is not None and job["status"] == "working":
                raise ApiError(409, "NOT_READY", "Vent til videojobbet er afsluttet.")
            _remove_owned_video(job_id)
            _video_jobs.pop(job_id, None)
        return {"ok": True}

    app.include_router(router)

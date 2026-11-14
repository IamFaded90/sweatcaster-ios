"""Paired, bot-scoped local models for the optional adult companion Lumi."""

from __future__ import annotations

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
VIDEO_MODEL = "wan2.1_t2v_1.3B_fp16.safetensors"
VIDEO_CLIP = "umt5_xxl_fp8_e4m3fn_scaled.safetensors"
VIDEO_VAE = "wan_2.1_vae.safetensors"
OLLAMA = "http://127.0.0.1:11434"
COMFY = "http://127.0.0.1:8188"
_video_executor = ThreadPoolExecutor(max_workers=1, thread_name_prefix="lumi-video")
_video_lock = Lock()
_video_jobs: dict[str, dict] = {}
INSTRUCTIONS = (
    "You are Lumi, an adult, playful and flirtatious private companion. "
    "Be warm, imaginative and direct. Understand Danish, imperfect English, "
    "misspellings and mixed Danish/English. Infer intent from context. Reply in "
    "the user's language or mix unless they ask otherwise. Never correct their "
    "spelling or grammar unless asked. Do not claim to have taken real-world "
    "actions or accessed accounts when you have not."
)


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


def chat(message: str, history: list[dict] | None = None, *, client: requests.Session | None = None) -> str:
    message = _message(message)
    if history is None:
        history = []
    if not isinstance(history, list) or len(history) > 16:
        raise ApiError(422, "INVALID_INPUT", "Samtalen er for lang. Start en ny samtale.")
    messages = [{"role": "system", "content": INSTRUCTIONS}]
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


def image(prompt: str, *, client: requests.Session | None = None, timeout: float = 300) -> bytes:
    prompt = _message(prompt, limit=1000)
    owned = client is None
    client = client or _client()
    submitted = False
    try:
        info = client.get(COMFY + "/object_info/CheckpointLoaderSimple", timeout=(3, 15), allow_redirects=False)
        info.raise_for_status()
        choices = info.json()["CheckpointLoaderSimple"]["input"]["required"]["ckpt_name"][0]
        if IMAGE_MODEL not in choices:
            raise ApiError(503, "NOT_READY", "Lumis billedmodel mangler i ComfyUI på PC'en.")
        graph = {
            "1": {"class_type": "CheckpointLoaderSimple", "inputs": {"ckpt_name": IMAGE_MODEL}},
            "2": {"class_type": "CLIPTextEncode", "inputs": {"text": prompt, "clip": ["1", 1]}},
            "3": {"class_type": "CLIPTextEncode", "inputs": {"text": "low quality, blurry, distorted", "clip": ["1", 1]}},
            "4": {"class_type": "EmptyLatentImage", "inputs": {"width": 768, "height": 768, "batch_size": 1}},
            "5": {"class_type": "KSampler", "inputs": {"seed": int(time.time_ns() % (2**53)),
                  "steps": 25, "cfg": 5.5, "sampler_name": "euler", "scheduler": "normal", "denoise": 1,
                  "model": ["1", 0], "positive": ["2", 0], "negative": ["3", 0], "latent_image": ["4", 0]}},
            "6": {"class_type": "VAEDecode", "inputs": {"samples": ["5", 0], "vae": ["1", 2]}},
            "7": {"class_type": "SaveImage", "inputs": {"filename_prefix": "FadedAI_Lumi", "images": ["6", 0]}},
        }
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
                    raise ApiError(502, "NOT_READY", "ComfyUI kunne ikke lave billedet.")
                outputs = entry.get("outputs", {}).get("7", {}).get("images", [])
                if outputs:
                    item = outputs[0]
                    rendered = client.get(COMFY + "/view", params={"filename": item["filename"],
                        "subfolder": item.get("subfolder", ""), "type": item.get("type", "output")},
                        timeout=(3, 30), allow_redirects=False)
                    rendered.raise_for_status()
                    data = rendered.content
                    if len(data) > 15_000_000 or not data.startswith(b"\x89PNG\r\n\x1a\n"):
                        raise ApiError(502, "NOT_READY", "ComfyUI sendte ikke et gyldigt billede.")
                    return data
            time.sleep(1)
        raise ApiError(504, "NOT_READY", "Billedet tog for lang tid. Prøv igen.")
    except (requests.RequestException, KeyError, TypeError, ValueError) as exc:
        raise ApiError(503, "NOT_READY", "ComfyUI svarer ikke på PC'en.") from exc
    finally:
        if submitted:
            try:
                client.post(COMFY + "/free", json={"unload_models": True, "free_memory": True},
                            timeout=(2, 3), allow_redirects=False)
            except requests.RequestException:
                pass
        if owned:
            client.close()


def video(prompt: str, *, client: requests.Session | None = None, timeout: float = 1200) -> bytes:
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
            "9": {"class_type": "VAEDecode", "inputs": {"samples": ["8", 0], "vae": ["6", 0]}},
            "10": {"class_type": "SaveWEBM", "inputs": {"images": ["9", 0],
                   "filename_prefix": "FadedAI_Lumi", "codec": "vp9", "fps": 12, "crf": 32}},
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


def _render_video(job_id: str, prompt: str) -> None:
    try:
        payload = video(prompt)
        result = {"status": "ready", "data": payload}
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
        return {"reply": chat(body.get("message"), body.get("history"))}

    @router.post("/image")
    def image_route(bot_id: str, body: dict = Body(...)):
        _bot(bot_id)
        return Response(image(body.get("prompt")), media_type="image/png",
                        headers={"Cache-Control": "no-store"})

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

    app.include_router(router)

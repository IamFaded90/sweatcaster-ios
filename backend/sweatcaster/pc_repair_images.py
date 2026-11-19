"""Retry only a known failed, bounded text-to-image graph from local history."""

from io import BytesIO
import json
import os
from pathlib import Path
import re
import stat
from uuid import UUID

from PIL import Image

from sweatcaster.dto import ApiError
from sweatcaster.pc_image_engine import EngineUnavailable, ORIGIN

MAX_IMAGE = 15_000_000
NODES = frozenset(("CheckpointLoaderSimple", "CLIPTextEncode", "EmptyLatentImage", "KSampler", "VAEDecode", "SaveImage"))


def identifier(value):
    try:
        if not isinstance(value, str) or len(value) != 36:
            raise ValueError
        return str(UUID(value))
    except (ValueError, TypeError, AttributeError) as exc:
        raise ApiError(422, "INVALID_INPUT", "Vælg en gyldig billedopgave.") from exc


def graph_from(entry, installed):
    """Reject custom nodes, uploads, video, oversized jobs and arbitrary file writes."""
    if not isinstance(entry, dict) or not isinstance(entry.get("status"), dict) or entry["status"].get("status_str") != "error":
        raise ValueError("Jobbet er ikke markeret som mislykket.")
    prompt = entry.get("prompt")
    if not isinstance(prompt, list) or len(prompt) < 3:
        raise ValueError("Den oprindelige opskrift blev ikke gemt af motoren.")
    graph = prompt[2]
    if not isinstance(graph, dict) or not 1 <= len(graph) <= 16 or len(json.dumps(graph)) > 32_000:
        raise ValueError("Denne opskrift kan ikke genoptages automatisk.")
    kinds, checkpoint = [], None
    for key, node in graph.items():
        if not isinstance(key, str) or not isinstance(node, dict) or node.get("class_type") not in NODES:
            raise ValueError("Denne opgave skal åbnes igen i sit studie, så referencer og udvidelser bevares.")
        kind, values = node["class_type"], node.get("inputs")
        if not isinstance(values, dict):
            raise ValueError("Opskriften mangler indstillinger.")
        kinds.append(kind)
        if kind == "CheckpointLoaderSimple":
            checkpoint = values.get("ckpt_name")
            if not isinstance(checkpoint, str) or checkpoint not in installed:
                raise ValueError("Den oprindelige billedmodel mangler. Jeg skifter ikke til en anden model.")
        elif kind == "EmptyLatentImage":
            if (any(type(values.get(side)) is not int or not 64 <= values[side] <= 1024 for side in ("width", "height"))
                    or type(values.get("batch_size")) is not int or values["batch_size"] != 1):
                raise ValueError("Kun ét billede på højst 1024 × 1024 kan genoptages her.")
        elif kind == "KSampler":
            if type(values.get("steps")) is not int or not 1 <= values["steps"] <= 50:
                raise ValueError("Denne opskrift er for stor til automatisk genoptagelse.")
        elif kind == "CLIPTextEncode":
            if not isinstance(values.get("text"), str) or len(values["text"]) > 2000:
                raise ValueError("Beskrivelsen er for stor til automatisk genoptagelse.")
        elif kind == "SaveImage" and values.get("filename_prefix") != "FadedAI":
            raise ValueError("Jeg genoptager kun billeder med FadedAI’s kendte filmønster.")
        for value in values.values():
            if isinstance(value, list) and (len(value) != 2 or value[0] not in graph or type(value[1]) is not int or not 0 <= value[1] <= 4):
                raise ValueError("Opskriftens forbindelser kunne ikke bekræftes.")
    if (checkpoint is None or kinds.count("EmptyLatentImage") != 1 or kinds.count("KSampler") != 1
            or kinds.count("SaveImage") != 1):
        raise ValueError("Kun en enkel billedopgave med ét resultat kan genoptages her.")
    return graph, checkpoint


def failed_images(control):
    try:
        entries = control.json("GET", "/history", params={"max_items": 8}, limit=500_000)
        installed = control.installed()
    except EngineUnavailable:
        return []
    result = []
    for key, entry in reversed(list(entries.items())):
        try:
            key = identifier(key)
            graph, checkpoint = graph_from(entry, installed)
            size = next(node["inputs"] for node in graph.values() if node["class_type"] == "EmptyLatentImage")
            result.append({"id": key, "title": "Prøv den mislykkede billedopgave igen",
                           "detail": f"Samme model, beskrivelse og seed · {size['width']} × {size['height']} · {checkpoint}"})
        except (ApiError, ValueError, KeyError, TypeError, RecursionError):
            continue
    return result[:4]


def failed_graph(control, prompt_id):
    prompt_id = identifier(prompt_id)
    entries = control.json("GET", "/history/" + prompt_id, limit=100_000)
    try:
        return graph_from(entries.get(prompt_id), control.installed())[0]
    except ValueError as exc:
        raise ApiError(409, "NOT_READY", str(exc)) from exc


def image_result(control, prompt_id):
    entry = control.json("GET", "/history/" + identifier(prompt_id), limit=150_000).get(prompt_id)
    if not entry:
        return None
    if entry.get("status", {}).get("status_str") == "error":
        raise ApiError(503, "NOT_READY", "Billedopgaven fejlede igen. Indstillingerne blev bevaret; ingen anden model blev valgt.")
    candidates = [item for output in entry.get("outputs", {}).values() for item in output.get("images", [])]
    if not candidates:
        return None
    item = candidates[0]
    name, folder, kind = item.get("filename"), item.get("subfolder", ""), item.get("type")
    if (not isinstance(name, str) or folder != "" or kind not in ("temp", "output")
            or not re.fullmatch(r"(?:FadedAI_[0-9]{1,10}_|ComfyUI_temp_[A-Za-z0-9_]{1,100})\.png", name)):
        raise EngineUnavailable("Motorens billedfil kunne ikke bekræftes.")
    with control.session.get(ORIGIN + "/view", params={"filename": name, "subfolder": folder, "type": kind},
                             timeout=(2, 10), stream=True, allow_redirects=False) as response:
        if response.status_code != 200:
            raise EngineUnavailable("Det færdige billede kunne ikke hentes.")
        data = bytearray()
        for chunk in response.iter_content(65_536):
            data.extend(chunk)
            if len(data) > MAX_IMAGE:
                raise EngineUnavailable("Billedet er for stort til telefonen.")
    try:
        with Image.open(BytesIO(data), formats=("PNG",)) as picture:
            if max(picture.size) > 1024:
                raise ValueError("oversized")
            picture.load()
    except (ValueError, OSError, Image.DecompressionBombError) as exc:
        raise EngineUnavailable("Billedfilen var ikke et gyldigt PNG-billede.") from exc
    return bytes(data), {"filename": name, "type": kind}


def remove_image(item):
    if not item:
        return
    root = Path(os.environ.get("FADEDAI_COMFY_TEMP_DIR" if item["type"] == "temp" else "FADEDAI_COMFY_OUTPUT_DIR",
                               "F:/FadedAI/ComfyUI/" + ("temp" if item["type"] == "temp" else "output"))).absolute()
    path = root / item["filename"]
    try:
        if root.resolve() != root or path.resolve() != path:
            raise OSError("Unexpected link")
        if path.exists() and not stat.S_ISREG(path.lstat().st_mode):
            raise OSError("Unexpected file")
        path.unlink(missing_ok=True)
    except OSError as exc:
        raise ApiError(503, "NOT_READY", "Billedfilen kunne ikke slettes. Prøv igen fra PC’en.") from exc

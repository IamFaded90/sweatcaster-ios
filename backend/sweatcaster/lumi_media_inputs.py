"""Decode local studio references before submitting them to ComfyUI."""

import base64
import binascii
import os
from pathlib import Path
import re
from io import BytesIO

from sweatcaster.dto import ApiError

MAX_REFERENCE = 1_000_000


def discard_image_later(client, client_factory, comfy, prompt_id, owned_inputs, remove):
    from sweatcaster.lumi_video_files import discard_prompt

    def remove_artifacts(session):
        history = session.get(comfy + "/history/" + prompt_id, timeout=(2, 3), allow_redirects=False)
        history.raise_for_status()
        record = history.json().get(prompt_id, {})
        images = record.get("outputs", {}).get("7", {}).get("images", [])
        owned_outputs = [item["filename"] for item in images if item.get("type") == "temp"
                         and not item.get("subfolder") and isinstance(item.get("filename"), str)]
        remove([*owned_inputs, *owned_outputs])

    discard_prompt(client, client_factory, comfy, prompt_id, False, remove_artifacts)


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

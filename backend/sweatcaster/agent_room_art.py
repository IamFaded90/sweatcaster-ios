"""Render the selected sketch with the PC's installed, local FLUX model."""

from io import BytesIO
import re
from time import monotonic
from uuid import UUID, uuid4

import requests

from sweatcaster import lumi_companion, lumi_flux
from sweatcaster.bot_computers import ModelBusy
from sweatcaster.dto import ApiError
from sweatcaster.pc_image_engine import ComfyControl, EngineUnavailable, ORIGIN


def latent_size(width, height):
    ratio = min(1_024 / max(width, height), (780_000 / (width * height)) ** 0.5)
    return tuple(max(64, round(side * ratio / 16) * 16) for side in (width, height))


def render_room(sketch, title, brief, cancelled, *, client=None, sleep=None, timeout=240):
    from time import sleep as wait
    try:
        from PIL import Image
    except ImportError as exc:
        raise ApiError(503, "NOT_READY", "PC’en mangler billedbiblioteket til landsbyrum.") from exc

    hold = sleep or wait
    owns_session = client is None
    client = client or requests.Session()
    client.trust_env = False
    temporary = []
    job = None
    finished = False
    try:
        motor = ComfyControl(session=client)
        if motor.queue():
            raise ModelBusy()
        if not lumi_flux.availability(client, ORIGIN, lumi_companion.PONY_MODEL)["flux2"]:
            raise ApiError(503, "NOT_READY", "Den lokale FLUX 2-model til landsbyrum mangler på PC’en.")
        if cancelled():
            raise InterruptedError()
        with Image.open(BytesIO(sketch), formats=("JPEG",)) as source:
            width, height = latent_size(*source.size)
            scaled = source.resize((width, height), Image.Resampling.LANCZOS)
            normalized = BytesIO()
            scaled.save(normalized, "PNG")
        name = f"fadedai-private-{uuid4().hex}.png"
        temporary.append(name)
        lumi_companion._temp_upload(client, name, normalized.getvalue())
        instruction = (
            "Transform this floor-plan sketch into a fully rendered room for a premium isometric 2D pixel-art village game. "
            "Preserve the sketch layout, walls, flooring and furniture positions. Rich warm practical lights, dark petrol blues, "
            "clean hand-painted texture, crisp consistent perspective and hard cast shadows. Single empty room fills the frame. "
            "Leave the front walkway open so separate characters can be added later. Draw no people, numbers, captions or interface. "
            f"Room title: {title}. Requested design: {brief}"
        )
        graph = lumi_flux.graph(instruction, uuid4().int & 0xFFFFFFFF, width, height, name)
        response = client.post(ORIGIN + "/prompt", json={"prompt": graph}, timeout=(3, 15), allow_redirects=False)
        response.raise_for_status()
        job = str(response.json()["prompt_id"])
        if len(job) != 36 or str(UUID(job)) != job:
            raise ValueError("Unexpected render id")
        deadline = monotonic() + timeout
        while monotonic() < deadline:
            entry = motor.json("GET", "/history/" + job, limit=100_000).get(job) or {}
            if entry.get("status", {}).get("status_str") == "error":
                finished = True
                raise ApiError(502, "NOT_READY", "PC’ens billedmotor kunne ikke tegne rummet. Prøv igen fra den gemte skitse.")
            images = entry.get("outputs", {}).get("7", {}).get("images")
            if images:
                finished = True
                file = images[0]
                filename = file.get("filename")
                if (file.get("type") != "temp" or file.get("subfolder", "") != ""
                        or not isinstance(filename, str) or not re.fullmatch(r"ComfyUI_temp_[A-Za-z0-9_]{1,80}\.png", filename)):
                    raise ValueError("Unexpected preview output")
                temporary.append(filename)
                if cancelled():
                    raise InterruptedError()
                with client.get(ORIGIN + "/view", params={"filename": filename, "type": "temp"},
                                timeout=(3, 20), allow_redirects=False, stream=True) as image:
                    image.raise_for_status()
                    data = bytearray()
                    for chunk in image.iter_content(65_536):
                        data.extend(chunk)
                        if len(data) > 16_000_000:
                            raise ValueError("Room artwork too large")
                return bytes(data)
            hold(1)
        raise ApiError(504, "NOT_READY", "Rummet tog for lang tid. Den oprindelige skitse er gemt til et nyt forsøg.")
    except EngineUnavailable as exc:
        raise ApiError(503, "NOT_READY", "Start billedmotoren på PC’en, og prøv at bygge rummet igen.") from exc
    except (requests.RequestException, KeyError, TypeError, ValueError) as exc:
        raise ApiError(502, "NOT_READY", "PC’ens billedmotor gav et uventet svar. Prøv igen.") from exc
    finally:
        if finished or job is None:
            lumi_companion._remove_private_image_files(temporary)
        if finished and job is not None:
            try:
                client.post(ORIGIN + "/history", json={"delete": [job]}, timeout=(2, 3), allow_redirects=False).close()
            except requests.RequestException:
                pass
        if owns_session:
            client.close()

"""Valid data for a room; the installed app owns all drawing and actions."""

import base64
from hashlib import sha256
from io import BytesIO
import math
from uuid import UUID

from sweatcaster.dto import ApiError


CHARACTERS = frozenset("adam atlas milo noah theo eva luna iris nova saga lumi".split())
MAX_SKETCH = 1_900_000
MAX_ARTWORK = 2_600_000
POSITIONS = ((0.40, 0.53), (0.61, 0.53), (0.19, 0.53), (0.82, 0.53),
             (0.40, 0.83), (0.61, 0.83), (0.19, 0.83), (0.82, 0.83))


def invalid(message):
    return ApiError(422, "INVALID_INPUT", message)


def identifier(value):
    try:
        return str(UUID(value))
    except (ValueError, TypeError, AttributeError):
        raise invalid("Vælg et gyldigt rum eller en landsbyfigur.") from None


def text(value, limit, *, empty=False):
    if not isinstance(value, str) or len(value) > limit or "\0" in value or (not empty and not value.strip()):
        raise invalid("Tjek rummets navn og beskrivelse.")
    return value.strip()


def normalized(raw, *, sketch=False):
    try:
        from PIL import Image, ImageOps
    except ImportError as exc:
        raise ApiError(503, "NOT_READY", "PC’en mangler billedbiblioteket til landsbyrum.") from exc
    max_input = MAX_SKETCH if sketch else 16_000_000
    try:
        if not isinstance(raw, bytes) or not 1 <= len(raw) <= max_input:
            raise ValueError
        with Image.open(BytesIO(raw), formats=("JPEG", "PNG")) as file:
            if (not all(64 <= side <= 4_096 for side in file.size)
                    or file.width * file.height > 12_000_000 or getattr(file, "is_animated", False)):
                raise ValueError
            source = ImageOps.exif_transpose(file).convert("RGBA")
            if not 0.56 <= source.width / source.height <= 2.25:
                raise ValueError
            white = Image.new("RGB", source.size, "white")
            white.paste(source, mask=source.getchannel("A"))
            white.thumbnail((1_920, 1_920), Image.Resampling.LANCZOS)
            out = BytesIO()
            white.save(out, "JPEG", quality=93, subsampling=0, optimize=True)
            if out.tell() > MAX_ARTWORK:
                raise ValueError
            return out.getvalue(), white.width, white.height
    except (ValueError, OSError, Image.DecompressionBombError) as exc:
        if sketch:
            raise invalid("Vælg en almindelig JPG- eller PNG-skitse under 1,9 MB. Undgå meget smalle billeder.") from exc
        raise ApiError(502, "NOT_READY", "Billedmotoren afleverede et rum, der ikke kunne åbnes.") from exc


def decode_sketch(value):
    if not isinstance(value, str) or len(value) > 4 * ((MAX_SKETCH + 2) // 3):
        raise invalid("Vælg ét billede under 1,9 MB.")
    try:
        raw = base64.b64decode(value, validate=True)
    except ValueError:
        raise invalid("Skitsefilen kunne ikke læses.") from None
    return normalized(raw, sketch=True)[0]


def figures(value):
    if not isinstance(value, list) or not 1 <= len(value) <= len(POSITIONS):
        raise invalid("Vælg mellem én og otte figurer i landsbyen.")
    values = []
    ids = set()
    for raw, (x, y) in zip(value, POSITIONS):
        if not isinstance(raw, dict):
            raise invalid("Vælg figurer fra landsbyen.")
        key = identifier(raw.get("id"))
        character = raw.get("character")
        if key in ids or not isinstance(character, str) or character not in CHARACTERS:
            raise invalid("Vælg forskellige figurer fra landsbyen.")
        ids.add(key)
        values.append(dict(id=key, name=text(raw.get("name"), 60), character=character, x=x, y=y, scale=1.0))
    return values


def make_version(artwork, figures, instruction):
    data, width, height = normalized(artwork)
    checks = check_viewport(figures)
    return data, {"revision": 1, "instruction": instruction, "artwork": sha256(data).hexdigest(),
                  "width": width, "height": height, "figures": figures,
                  "hotspots": [{"id": "room-info", "title": "Om rummet", "x": 0.15, "y": 0.14,
                               "w": 0.23, "h": 0.18, "action": "details", "botID": None}], "checks": checks}


def check_viewport(figures):
    # The app uses the same relative touch zones. Keep all centers in their
    # dedicated lanes so figures remain reachable even at minimum zoom.
    for index, figure in enumerate(figures):
        if (figure["x"], figure["y"]) != POSITIONS[index] or not 0.7 <= figure["scale"] <= 1.65:
            raise invalid("Figuren passer ikke i rummets zoomområde.")
        half_height = 0.09 * figure["scale"]
        if not (0.095 <= figure["x"] <= 0.905 and half_height <= figure["y"] <= 1 - half_height):
            raise invalid("Figuren går uden for billedets ramme.")
        if any(abs(figure["x"] - other["x"]) < 0.19
               and abs(figure["y"] - other["y"]) < 0.09 * (figure["scale"] + other["scale"])
               for other in figures[:index]):
            raise invalid("To figurers trykområder ligger oven i hinanden.")
    return ["Baggrundsbilledet er åbnet og har gyldige mål.", "Figurernes trykområder ligger inde i scenen.",
            "Rummet bruger kun de indbyggede landsbyhandlinger."]


def revise(version, figure_id, scale, instruction, next_revision):
    key = identifier(figure_id)
    if type(scale) not in (int, float) or not math.isfinite(scale) or not 0.7 <= scale <= 1.65:
        raise invalid("Figurens størrelse skal være mellem 70 og 165 procent.")
    matching = next((figure for figure in version["figures"] if figure["id"] == key), None)
    if not matching:
        raise invalid("Vælg en figur, der er med i rummet.")
    if abs(matching["scale"] - scale) < 0.001:
        raise invalid("Vælg en anden størrelse til figuren.")
    values = [dict(figure, scale=scale) if figure["id"] == key else figure for figure in version["figures"]]
    return dict(version, revision=next_revision, figures=values, instruction=text(instruction, 250),
                checks=check_viewport(values) + ["Baggrund, lys og de øvrige figurer er bevaret."])

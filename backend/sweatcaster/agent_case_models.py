"""Validated case facts and an inspectable complaint draft; no invented purchase facts."""

import base64
from hashlib import sha256
from io import BytesIO
import json
import re
from uuid import UUID, uuid4

from PIL import Image, ImageOps

from sweatcaster.dto import ApiError


ADDRESS = re.compile(r"[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+")
MAIL_ID = re.compile(r"[0-9a-fA-F]{1,128}")


def identifier(value):
    try:
        return str(UUID(str(value)))
    except (ValueError, TypeError, AttributeError):
        raise ApiError(422, "INVALID_INPUT", "Åbn en gyldig sag.") from None


def text(value, maximum, *, empty=False):
    if not isinstance(value, str) or len(value.strip()) > maximum or "\0" in value or (not value.strip() and not empty):
        raise ApiError(422, "INVALID_INPUT", "Tjek sagens tekstfelter.")
    return value.strip()


def fields(body):
    return {"title": text(body.get("title"), 160), "merchant": text(body.get("merchant", ""), 160, empty=True),
            "problem": text(body.get("problem"), 3000), "desired": text(body.get("desired", ""), 1000, empty=True),
            "reference": text(body.get("reference", ""), 200, empty=True)}


def photo(encoded):
    try:
        if not isinstance(encoded, str) or len(encoded) > 4_000_000:
            raise ValueError
        data = base64.b64decode(encoded, validate=True)
        with Image.open(BytesIO(data)) as source:
            if source.width * source.height > 40_000_000:
                raise ValueError
            image = ImageOps.exif_transpose(source).convert("RGB")
            for edge in (1280, 1024, 800, 640):
                image.thumbnail((edge, edge))
                for quality in (84, 76, 65, 50):
                    out = BytesIO()
                    image.save(out, "JPEG", quality=quality)
                    if out.tell() <= 200_000:
                        return out.getvalue()
        raise ValueError
    except (OSError, ValueError, Image.DecompressionBombError):
        raise ApiError(422, "INVALID_INPUT", "Fotoet kunne ikke klargøres. Vælg et almindeligt billede på højst 40 megapixel.") from None


def draft(case, recipient=""):
    source = case.get("receipt")
    body = ["Hej" + (" " + case["merchant"] if case["merchant"] else "") + ",", "", case["problem"]]
    if case["reference"]:
        body += ["", "Ordre-/købsreference: " + case["reference"]]
    if source:
        body += ["", "Jeg henviser til kvitteringsmailen med emnet “" + source["subject"] + "” fra " + source["sender"] + "."]
    if case["desired"]:
        body += ["", "Jeg ønsker: " + case["desired"]]
    body += ["", "Vil I vende tilbage med en løsning?", "", "Venlig hilsen"]
    return reviewed({"recipient": recipient, "subject": "Reklamation: " + case["title"], "body": "\n".join(body)}, case, require_address=False)


def reviewed(body, case, *, require_address=True):
    recipient = text(body.get("recipient", ""), 254, empty=not require_address)
    if recipient and not ADDRESS.fullmatch(recipient):
        raise ApiError(422, "INVALID_INPUT", "Skriv én gyldig e-mailadresse til forhandlerens kundeservice.")
    subject, value = text(body.get("subject"), 200), text(body.get("body"), 8000)
    if any(ord(c) < 32 for c in subject):
        raise ApiError(422, "INVALID_INPUT", "Mailens emne skal stå på én linje.")
    result = {"sender": case.get("gmailEmail", ""), "recipient": recipient, "subject": subject, "body": value,
              "photos": [{k: p[k] for k in ("id", "name", "bytes", "sha256")} for p in case["photos"]]}
    result["digest"] = sha256(json.dumps(result, sort_keys=True, ensure_ascii=False).encode()).hexdigest()
    return result


def event(case, kind, description):
    from time import time
    case["events"].append({"id": str(uuid4()), "kind": kind, "text": description, "created": time()})
    case["events"] = case["events"][-100:]

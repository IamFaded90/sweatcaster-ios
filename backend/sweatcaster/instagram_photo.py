"""Prepare a user-selected JPEG for Composio's Instagram image_file input."""

from base64 import b64decode
from binascii import Error as Base64Error
from hashlib import md5
from io import BytesIO
from urllib.parse import urlsplit

import requests

from sweatcaster.dto import ApiError


MAX_JPEG_BYTES = 4 * 1024 * 1024
CREATE_MEDIA = "INSTAGRAM_POST_IG_USER_MEDIA"


def decode_photo(encoded):
    if not isinstance(encoded, str) or len(encoded) > 4 * ((MAX_JPEG_BYTES + 2) // 3):
        raise ApiError(422, "INVALID_INPUT", "Vælg et foto på højst 4 MB.")
    try:
        data = b64decode(encoded, validate=True)
        if not 0 < len(data) <= MAX_JPEG_BYTES:
            raise ValueError
    except (Base64Error, ValueError) as exc:
        raise ApiError(422, "INVALID_INPUT", "Billedet kunne ikke læses. Vælg det igen.") from exc
    from PIL import Image
    try:
        with Image.open(BytesIO(data), formats=("JPEG",)) as image:
            if image.width * image.height > 12_000_000:
                raise ValueError
            image.load()
    except (OSError, ValueError, Image.DecompressionBombError) as exc:
        raise ApiError(422, "INVALID_INPUT", "Vælg et gyldigt JPEG-foto til opslaget.") from exc
    return data


def storage_url(value):
    # Composio returns the storage provider's signed upload URL, never a user-supplied URL.
    try:
        url = urlsplit(value) if isinstance(value, str) else None
        if not url or url.scheme != "https" or url.port not in (None, 443) or url.username is not None:
            return False
        host = (url.hostname or "").lower()
        return host.endswith((".amazonaws.com", ".r2.cloudflarestorage.com")) and bool(url.query)
    except ValueError:
        return False


def stage_photo(library, data):
    name = "instagram.jpg"
    mime = "image/jpeg"
    result = library.request("POST", "/files/upload/request", payload={
        "toolkit_slug": "instagram", "tool_slug": CREATE_MEDIA, "filename": name,
        "mimetype": mime, "md5": md5(data, usedforsecurity=False).hexdigest(),
    })
    key = result.get("key")
    signed = result.get("new_presigned_url") or result.get("newPresignedUrl")
    if not isinstance(key, str) or not key or not storage_url(signed):
        raise ApiError(502, "NOT_READY", "Composio kunne ikke klargøre billedet. Prøv igen.")
    try:
        with requests.Session() as client:
            client.trust_env = False
            with client.put(signed, data=data, headers={"Content-Type": mime},
                            timeout=(5, 35), allow_redirects=False, stream=True) as response:
                if not 200 <= response.status_code < 300:
                    raise requests.HTTPError()
    except requests.RequestException:
        raise ApiError(502, "NOT_READY", "Fotoet kunne ikke overføres til Instagram via Composio.") from None
    return {"name": name, "mimetype": mime, "s3key": key}

"""Read one authorised YouTube channel snapshot using the Windows user's connection."""

from __future__ import annotations

import base64
import binascii
import http.client
import json
import os
import re
import tempfile
import threading
from pathlib import Path
from time import monotonic
from urllib.error import HTTPError
from urllib.parse import urlencode
from urllib.request import ProxyHandler, Request, build_opener

from sweatcaster.emby_library import NoRedirects
from sweatcaster.emby_settings import _protect
from sweatcaster.google_desktop import GoogleDesktopError, refresh_desktop

SCOPE = "https://www.googleapis.com/auth/youtube.readonly"
CHANNELS_URL = "https://www.googleapis.com/youtube/v3/channels"
MAX_SETTINGS = 32_768
FIELDS = "items(id,snippet(title,customUrl),statistics(subscriberCount,hiddenSubscriberCount,videoCount,viewCount))"
_connection_lock = threading.Lock()


class YouTubeError(Exception):
    def __init__(self, status, message):
        super().__init__(message)
        self.status = status
        self.message = message


def _settings_path():
    local = os.environ.get("LOCALAPPDATA")
    if os.name != "nt" or not local:
        raise OSError("YouTube settings require the local Windows account.")
    return Path(local) / "FadedAI" / "youtube.json"


def _validated(value):
    if not isinstance(value, dict) or value.keys() != {"client_id", "client_secret", "refresh_token"}:
        raise ValueError("Invalid YouTube settings.")
    client_id, secret, token = (value[key] for key in ("client_id", "client_secret", "refresh_token"))
    if not isinstance(client_id, str) or not re.fullmatch(r"[A-Za-z0-9_-]{1,200}\.apps\.googleusercontent\.com", client_id):
        raise ValueError("Invalid Google Desktop client ID.")
    if not all(isinstance(s, str) and re.fullmatch(r"[!-~]{1,2048}", s) for s in (secret, token)):
        raise ValueError("Invalid Google credentials.")
    return value


def load_connection():
    if os.name != "nt":
        return None
    try:
        with _settings_path().open("rb") as source:
            data = source.read(MAX_SETTINGS + 1)
    except FileNotFoundError:
        return None
    try:
        if len(data) > MAX_SETTINGS:
            raise ValueError
        record = json.loads(data)
        if not isinstance(record, dict) or record.get("version") != 1:
            raise ValueError
        encoded = record.get("protected")
        if not isinstance(encoded, str):
            raise ValueError
        return _validated(json.loads(_protect(base64.b64decode(encoded, validate=True), decrypt=True)))
    except (ValueError, binascii.Error, RecursionError) as exc:
        raise YouTubeError(503, "Den gemte YouTube-forbindelse kunne ikke læses. Forbind igen på PC’en.") from exc


def save_connection(connection):
    target = _settings_path()
    target.parent.mkdir(parents=True, exist_ok=True)
    raw = json.dumps(_validated(connection)).encode("utf-8")
    record = {"version": 1, "protected": base64.b64encode(_protect(raw)).decode("ascii")}
    temporary = None
    try:
        with tempfile.NamedTemporaryFile("w", encoding="ascii", dir=target.parent, prefix=".youtube-",
                                         suffix=".tmp", delete=False) as output:
            temporary = Path(output.name)
            json.dump(record, output)
        temporary.replace(target)
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def remove_connection():
    _settings_path().unlink(missing_ok=True)


def channels_for_token(token, *, redact=()):
    if not isinstance(token, str) or not re.fullmatch(r"[!-~]{1,2048}", token):
        raise YouTubeError(502, "Google returnerede ikke en gyldig adgang.")
    url = CHANNELS_URL + "?" + urlencode({"part": "snippet,statistics", "mine": "true",
                                          "maxResults": 5, "fields": FIELDS})
    request = Request(url, headers={"Accept": "application/json", "Authorization": "Bearer " + token})
    result = _google_json(request, denied="Google afviste opslaget. Tjek YouTube Data API og login på PC’en.")
    if not isinstance(result.get("items"), list):
        raise YouTubeError(502, "YouTube returnerede ikke et gyldigt kanalopslag.")
    return [channel for row in result["items"][:5]
            if (channel := _channel(row, (*redact, token))) is not None]


def _google_json(request, *, denied):
    try:
        deadline = monotonic() + 10
        with build_opener(ProxyHandler({}), NoRedirects()).open(request, timeout=6) as response:
            data = bytearray()
            while len(data) <= 128_000:
                if monotonic() > deadline:
                    raise TimeoutError
                chunk = response.read1(min(8192, 128_001 - len(data)))
                if not chunk:
                    break
                data.extend(chunk)
        if len(data) > 128_000:
            raise ValueError
        result = json.loads(data)
        if not isinstance(result, dict):
            raise ValueError
    except HTTPError as exc:
        exc.close()
        if exc.code in (400, 401, 403):
            raise YouTubeError(502, denied) from exc
        raise YouTubeError(502, "Google returnerede et uventet svar.") from exc
    except (OSError, http.client.HTTPException) as exc:
        raise YouTubeError(503, "PC’en kunne ikke nå YouTube.") from exc
    except (ValueError, RecursionError) as exc:
        raise YouTubeError(502, "Google returnerede et uventet svar.") from exc
    return result


def _channel(row, secrets):
    if not isinstance(row, dict) or not isinstance(row.get("id"), str):
        return None
    channel_id = row["id"]
    if not re.fullmatch(r"UC[A-Za-z0-9_-]{22}", channel_id) or channel_id in secrets:
        return None
    snippet = row.get("snippet")
    if not isinstance(snippet, dict) or not isinstance(snippet.get("title"), str):
        return None

    def display(value):
        if not isinstance(value, str):
            return ""
        for secret in secrets:
            if secret:
                value = value.replace(secret, "[skjult]")
        return " ".join(value.split())[:180]

    result = {"id": channel_id, "title": display(snippet["title"]), "handle": display(snippet.get("customUrl"))}
    statistics = row.get("statistics")
    if isinstance(statistics, dict):
        for key in ("videoCount", "viewCount", "subscriberCount"):
            if key == "subscriberCount" and statistics.get("hiddenSubscriberCount") is True:
                continue
            value = statistics.get(key)
            if isinstance(value, str) and re.fullmatch(r"[0-9]{1,20}", value):
                result[key] = value
    return result


def read_channels():
    with _connection_lock:
        try:
            connection = load_connection()
            if connection is None:
                return {"configured": False, "channels": []}
            credentials = refresh_desktop(connection, (SCOPE,), connection["refresh_token"])
            if credentials.refresh_token and credentials.refresh_token != connection["refresh_token"]:
                if load_connection() == connection:
                    save_connection({**connection, "refresh_token": credentials.refresh_token})
        except OSError as exc:
            raise YouTubeError(503, "Den gemte YouTube-forbindelse kunne ikke læses. Forbind igen på PC’en.") from exc
        except GoogleDesktopError as exc:
            raise YouTubeError(502, str(exc)) from exc
    secrets = (connection["refresh_token"], credentials.refresh_token, connection["client_secret"])
    return {"configured": True, "channels": channels_for_token(credentials.access_token, redact=secrets)}

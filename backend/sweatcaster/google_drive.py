"""List Google Drive metadata for the paired iPhone using Windows OAuth."""
from __future__ import annotations

import os
import re
import threading
from pathlib import Path
from urllib.parse import urlencode
from urllib.request import Request

from sweatcaster.google_desktop import GoogleDesktopError, refresh_desktop
from sweatcaster.youtube_connection import YouTubeError, _google_json, _load_connection, _save_connection

SCOPE = "https://www.googleapis.com/auth/drive.metadata.readonly"
FILES_URL = "https://www.googleapis.com/drive/v3/files"
FOLDER = "application/vnd.google-apps.folder"
FILE_ID = re.compile(r"[A-Za-z0-9_-]{1,200}")
_lock = threading.Lock()


class DriveError(YouTubeError):
    pass


def settings_path():
    local = os.environ.get("LOCALAPPDATA")
    if os.name != "nt" or not local:
        raise OSError("Google Drive kræver Windows-brugeren, der kører FadedAI.")
    return Path(local) / "FadedAI" / "google-drive.json"


def load_connection():
    try:
        return _load_connection(settings_path)
    except YouTubeError as exc:
        raise DriveError(503, "Google Drive-forbindelsen kunne ikke læses. Forbind igen på PC’en.") from exc


def save_connection(connection):
    with _lock:
        _save_connection(settings_path, connection)


def remove_connection():
    with _lock:
        settings_path().unlink(missing_ok=True)


def files_for_token(token, *, parent=None, page=None, redact=()):
    if not isinstance(token, str) or not re.fullmatch(r"[!-~]{1,2048}", token):
        raise DriveError(502, "Google returnerede ikke en gyldig adgang.")
    if parent is not None and (not isinstance(parent, str) or not FILE_ID.fullmatch(parent)):
        raise DriveError(422, "Mappen har et ugyldigt id.")
    if page is not None and (not isinstance(page, str) or not re.fullmatch(r"[!-~]{1,4096}", page)):
        raise DriveError(422, "Siden er ugyldig. Hent listen igen.")
    params = {
        "q": f"trashed = false and '{parent or 'root'}' in parents",
        "fields": "files(id,name,mimeType),nextPageToken",
        "pageSize": 50,
        "orderBy": "folder,name_natural",
        "supportsAllDrives": "true",
        "includeItemsFromAllDrives": "true",
    }
    if page is not None:
        params["pageToken"] = page
    request = Request(FILES_URL + "?" + urlencode(params),
                      headers={"Accept": "application/json", "Authorization": "Bearer " + token})
    try:
        result = _google_json(request, denied="Google afviste opslaget. Tjek Drive API og login på PC’en.",
                              unreachable="PC’en kunne ikke nå Google Drive.")
    except YouTubeError as exc:
        raise DriveError(exc.status, exc.message) from exc
    if not isinstance(result.get("files"), list):
        raise DriveError(502, "Google Drive returnerede ikke en gyldig filliste.")
    secrets = tuple(value for value in (*redact, token) if value)
    items = []
    used = set()
    for row in result["files"][:50]:
        if not isinstance(row, dict):
            continue
        entry, name = row.get("id"), row.get("name")
        if not isinstance(entry, str) or not FILE_ID.fullmatch(entry) or not isinstance(name, str):
            continue
        if entry in used or any(secret in entry for secret in secrets):
            continue
        used.add(entry)
        for secret in secrets:
            name = name.replace(secret, "[skjult]")
        items.append({"id": entry, "name": " ".join(name.split())[:220] or "Uden navn",
                      "folder": row.get("mimeType") == FOLDER})
    cursor = result.get("nextPageToken")
    if not isinstance(cursor, str) or cursor == page or not re.fullmatch(r"[!-~]{1,4096}", cursor):
        cursor = None
    if cursor and any(secret in cursor for secret in secrets):
        cursor = None
    return {"configured": True, "files": items, "nextPage": cursor}


def read_files(*, parent=None, page=None):
    with _lock:
        try:
            connection = load_connection()
            if connection is None:
                return {"configured": False, "files": []}
            credentials = refresh_desktop(connection, (SCOPE,), connection["refresh_token"])
            if credentials.refresh_token and credentials.refresh_token != connection["refresh_token"]:
                if load_connection() == connection:
                    _save_connection(settings_path, {**connection, "refresh_token": credentials.refresh_token})
        except OSError as exc:
            raise DriveError(503, "Google Drive-forbindelsen kunne ikke læses på PC’en.") from exc
        except GoogleDesktopError as exc:
            raise DriveError(502, str(exc)) from exc
    secrets = (connection["refresh_token"], credentials.refresh_token, connection["client_secret"])
    return files_for_token(credentials.access_token, parent=parent, page=page, redact=secrets)

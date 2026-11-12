"""Per-Windows-user Emby settings protected by DPAPI."""

from __future__ import annotations

import base64
import binascii
import ctypes
import json
import os
import tempfile
from ctypes import wintypes
from pathlib import Path

MAX_SETTINGS_BYTES = 32 * 1024
CRYPTPROTECT_UI_FORBIDDEN = 0x01


class _DataBlob(ctypes.Structure):
    _fields_ = [("size", wintypes.DWORD), ("data", ctypes.POINTER(ctypes.c_ubyte))]


def _protect(payload: bytes, *, decrypt: bool = False) -> bytes:
    if os.name != "nt":
        raise OSError("Emby Windows settings require Windows.")
    crypt32 = ctypes.WinDLL("crypt32", use_last_error=True)
    kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
    transform = crypt32.CryptUnprotectData if decrypt else crypt32.CryptProtectData
    description_type = ctypes.POINTER(wintypes.LPWSTR) if decrypt else wintypes.LPCWSTR
    transform.argtypes = [
        ctypes.POINTER(_DataBlob), description_type, ctypes.POINTER(_DataBlob), ctypes.c_void_p,
        ctypes.c_void_p, wintypes.DWORD, ctypes.POINTER(_DataBlob),
    ]
    transform.restype = wintypes.BOOL
    kernel32.LocalFree.argtypes = [ctypes.c_void_p]
    kernel32.LocalFree.restype = ctypes.c_void_p

    buffer = (ctypes.c_ubyte * len(payload)).from_buffer_copy(payload)
    source = _DataBlob(len(payload), ctypes.cast(buffer, ctypes.POINTER(ctypes.c_ubyte)))
    target = _DataBlob()
    try:
        if not transform(ctypes.byref(source), None, None, None, None,
                         CRYPTPROTECT_UI_FORBIDDEN, ctypes.byref(target)):
            raise ctypes.WinError(ctypes.get_last_error())
        if not 1 <= target.size <= MAX_SETTINGS_BYTES:
            raise ValueError("Invalid protected Emby settings size.")
        return ctypes.string_at(target.data, target.size)
    finally:
        ctypes.memset(ctypes.addressof(buffer), 0, len(payload))
        if target.data:
            ctypes.memset(target.data, 0, target.size)
            kernel32.LocalFree(ctypes.cast(target.data, ctypes.c_void_p))


def _settings_path() -> Path:
    local = os.environ.get("LOCALAPPDATA")
    if os.name != "nt" or not local:
        raise OSError("The Windows user's local application folder is unavailable.")
    return Path(local) / "FadedAI" / "emby.json"


def _validated(settings: object) -> dict[str, str]:
    limits = {"url": 2048, "user_id": 128, "token": 256, "web_url": 2048}
    if not isinstance(settings, dict) or not {"url", "user_id", "token"} <= settings.keys() <= limits.keys():
        raise ValueError("Invalid Emby settings fields.")
    for key, value in settings.items():
        if not isinstance(value, str) or not 1 <= len(value) <= limits[key]:
            raise ValueError("Invalid Emby settings values.")
    return settings


def load_local_settings() -> dict[str, str] | None:
    if os.name != "nt":
        return None
    path = _settings_path()
    try:
        with path.open("rb") as source:
            payload = source.read(MAX_SETTINGS_BYTES + 1)
    except FileNotFoundError:
        return None
    if len(payload) > MAX_SETTINGS_BYTES:
        raise ValueError("Emby settings file is too large.")
    try:
        stored = json.loads(payload)
        if not isinstance(stored, dict) or stored.get("version") != 1 or not isinstance(stored.get("protected"), str):
            raise ValueError("Invalid Emby settings file.")
        encrypted = base64.b64decode(stored["protected"], validate=True)
        return _validated(json.loads(_protect(encrypted, decrypt=True)))
    except (binascii.Error, RecursionError) as exc:
        raise ValueError("Invalid Emby settings file.") from exc


def save_local_settings(settings: dict[str, str]) -> None:
    validated = _validated(settings)
    encrypted = _protect(json.dumps(validated, ensure_ascii=False).encode("utf-8"))
    payload = json.dumps({"version": 1, "protected": base64.b64encode(encrypted).decode("ascii")})
    if len(payload) > MAX_SETTINGS_BYTES:
        raise ValueError("Emby settings file is too large.")
    path = _settings_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(mode="w", encoding="ascii", dir=path.parent,
                                         prefix=".emby-", suffix=".tmp", delete=False) as output:
            temporary = Path(output.name)
            output.write(payload)
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, path)
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def remove_local_settings() -> None:
    _settings_path().unlink(missing_ok=True)

"""Per-user Windows settings for the FadedAI Composio project."""

import json
import os
from pathlib import Path
import re
from tempfile import NamedTemporaryFile

from sweatcaster.emby_settings import _protect

PROVIDERS = ("googledrive", "github", "gmail", "googlesheets", "notion")
FIELDS = ("key", *PROVIDERS, "gmail_consumer_key")


def settings_path():
    return Path(os.environ["LOCALAPPDATA"]) / "FadedAI" / "composio.dpapi"


def validate(values):
    if not isinstance(values, dict) or not {"key", "googledrive", "github"} <= set(values) <= set(FIELDS):
        raise ValueError("Ugyldig Composio-opsætning.")
    values = dict.fromkeys(FIELDS, "") | values
    if not all(isinstance(value, str) and len(value) <= 1024 for value in values.values()):
        raise ValueError("Ugyldig Composio-opsætning.")
    if not values["key"] or not re.fullmatch(r"[!-~]{1,1024}", values["key"]):
        raise ValueError("Indsæt Composio-projektnøglen uden mellemrum.")
    configs = [values[provider] for provider in PROVIDERS if values[provider]]
    if not all(re.fullmatch(r"ac_[A-Za-z0-9_-]{1,128}", config) for config in configs):
        raise ValueError("Et valgfrit login-id skal begynde med ac_.")
    consumer_key = values["gmail_consumer_key"]
    if consumer_key and not re.fullmatch(r"ck_[A-Za-z0-9_-]{8,1021}", consumer_key):
        raise ValueError("Gmail-nøglen fra Composio For You skal begynde med ck_.")
    return values


def load():
    if os.name != "nt":
        return {}
    try:
        with settings_path().open("rb") as stream:
            data = stream.read(32769)
        if len(data) > 32768:
            return {}
        return validate(json.loads(_protect(data, decrypt=True)))
    except (OSError, KeyError, ValueError):
        return {}


def save(values):
    data = _protect(json.dumps(validate(values)).encode("utf-8"))
    path = settings_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    scratch = None
    try:
        with NamedTemporaryFile(dir=path.parent, delete=False) as stream:
            scratch = Path(stream.name)
            stream.write(data)
        scratch.replace(path)
    finally:
        if scratch is not None:
            scratch.unlink(missing_ok=True)

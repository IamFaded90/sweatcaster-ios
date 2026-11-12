"""Google Desktop OAuth for setup tools and services running on the user's PC."""

from __future__ import annotations

import json
from collections.abc import Mapping, Sequence
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from http.client import HTTPException
from pathlib import Path
from urllib.error import HTTPError
from urllib.parse import urlencode
from urllib.request import HTTPRedirectHandler, ProxyHandler, Request, build_opener


_AUTH_URLS = {"https://accounts.google.com/o/oauth2/auth", "https://accounts.google.com/o/oauth2/v2/auth"}
_TOKEN_URL = "https://oauth2.googleapis.com/token"
_MAX_JSON_BYTES = 32_768


class GoogleDesktopError(Exception):
    """A Google authorization error safe to show without credentials or response bodies."""


@dataclass(frozen=True)
class GoogleDesktopToken:
    access_token: str = field(repr=False)
    refresh_token: str | None = field(repr=False)
    expires_at: datetime | None


def _json_object(stream) -> dict:
    raw = stream.read(_MAX_JSON_BYTES + 1)
    if len(raw) > _MAX_JSON_BYTES:
        raise ValueError
    document = json.loads(raw)
    if not isinstance(document, dict):
        raise ValueError
    return document


def _client_config(client_file: Path) -> dict:
    try:
        with client_file.open("rb") as source:
            config = _json_object(source)
        client = config["installed"]
        if ("web" in config or not isinstance(client, dict) or client.get("auth_uri") not in _AUTH_URLS
                or client.get("token_uri") != _TOKEN_URL):
            raise ValueError
        if any(not isinstance(client.get(key), str) or not client[key] for key in ("client_id", "client_secret")):
            raise ValueError
        return config
    except (OSError, KeyError, TypeError, ValueError, RecursionError):
        raise GoogleDesktopError("Vælg JSON-filen til en Google OAuth-klient af typen Desktop-app.") from None


def load_desktop_client(client_file: Path) -> dict[str, str]:
    """Return only the validated client fields needed for a refresh."""
    client = _client_config(client_file)["installed"]
    return {key: client[key] for key in ("client_id", "client_secret")}


def authorize_desktop(client_file: Path, scopes: Sequence[str], *, offline: bool = False) -> GoogleDesktopToken:
    """Authorize through the system browser and a short-lived loopback listener."""
    config = _client_config(client_file)
    try:
        from google_auth_oauthlib.flow import InstalledAppFlow
    except ImportError:
        raise GoogleDesktopError("Installér google-auth-oauthlib i Python-miljøet på PC’en.") from None
    try:
        flow = InstalledAppFlow.from_client_config(config, scopes=list(scopes), autogenerate_code_verifier=True)
        options = {"access_type": "offline", "prompt": "consent"} if offline else {"access_type": "online"}
        credentials = flow.run_local_server(
            host="127.0.0.1", port=0, timeout_seconds=180,
            authorization_prompt_message="Åbner Google i browseren. Log ind for at give FadedAI adgang.",
            success_message="Du kan lukke denne fane og gå tilbage til FadedAI-opsætningen.",
            **options,
        )
    except Exception:
        raise GoogleDesktopError("Google-godkendelsen blev afbrudt eller kunne ikke gennemføres.") from None
    if not credentials.token or (offline and not credentials.refresh_token):
        raise GoogleDesktopError("Google returnerede ikke den adgang, FadedAI bad om. Forbind igen.")
    expiry = credentials.expiry
    if expiry is not None and expiry.tzinfo is None:
        expiry = expiry.replace(tzinfo=timezone.utc)
    return GoogleDesktopToken(credentials.token, credentials.refresh_token if offline else None, expiry)


class _RejectRedirects(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def refresh_desktop(client: Path | Mapping[str, str], scopes: Sequence[str], refresh_token: str) -> GoogleDesktopToken:
    """Exchange a saved refresh token with Google without opening a browser."""
    values = load_desktop_client(client) if isinstance(client, Path) else client
    if (not isinstance(values, Mapping)
            or any(not isinstance(values.get(key), str) or not values[key] for key in ("client_id", "client_secret"))
            or not isinstance(refresh_token, str) or not refresh_token):
        raise GoogleDesktopError("Google-forbindelsen skal godkendes igen.")
    request = Request(_TOKEN_URL, data=urlencode({
        "client_id": values["client_id"],
        "client_secret": values["client_secret"],
        "refresh_token": refresh_token,
        "grant_type": "refresh_token",
    }).encode("ascii"), headers={
        "Accept": "application/json",
        "Content-Type": "application/x-www-form-urlencoded",
    })
    try:
        with build_opener(ProxyHandler({}), _RejectRedirects()).open(request, timeout=12) as response:
            result = _json_object(response)
        access_token = result["access_token"]
        expires_in = result["expires_in"]
        granted = result.get("scope")
        rotated = result.get("refresh_token", refresh_token)
        if (not isinstance(access_token, str) or not access_token or type(expires_in) is not int
                or not 0 < expires_in <= 86_400 or not isinstance(rotated, str) or not rotated
                or (granted is not None and (not isinstance(granted, str) or not set(scopes) <= set(granted.split())))):
            raise ValueError
        return GoogleDesktopToken(access_token, rotated, datetime.now(timezone.utc) + timedelta(seconds=expires_in))
    except HTTPError as exc:
        with exc:
            if exc.code in (400, 401, 403):
                raise GoogleDesktopError("Google-forbindelsen skal godkendes igen.") from None
            raise GoogleDesktopError(f"Google afviste fornyelsen med HTTP {exc.code}. Prøv igen.") from None
    except (OSError, HTTPException, KeyError, ValueError, RecursionError):
        raise GoogleDesktopError("Google-forbindelsen kunne ikke fornyes. Prøv igen.") from None

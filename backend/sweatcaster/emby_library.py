"""Read the configured Emby user's library without exposing Emby credentials."""

from __future__ import annotations

import http.client
import ipaddress
import json
import os
import re
from dataclasses import dataclass, field
from time import monotonic
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode, urlsplit
from urllib.request import HTTPRedirectHandler, ProxyHandler, Request, build_opener

PAGE_SIZE = 30
MAX_OFFSET = 1_000_000
MAX_RESPONSE_BYTES = 2 * 1024 * 1024
MAX_PUBLIC_INFO_BYTES = 32 * 1024
REQUEST_TIMEOUT = 5
ID_PATTERN = re.compile(r"[A-Za-z0-9_-]{1,128}")
PRIMARY_ENV = ("FADEDAI_EMBY_URL", "FADEDAI_EMBY_USER_ID", "FADEDAI_EMBY_TOKEN")
LOCAL_NETWORKS = tuple(ipaddress.ip_network(block) for block in (
    "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "100.64.0.0/10", "fc00::/7",
))


class EmbyLibraryError(Exception):
    def __init__(self, status: int, message: str):
        super().__init__(message)
        self.status = status


@dataclass(frozen=True)
class EmbyConfiguration:
    api_base: str
    user_id: str
    token: str = field(repr=False)
    web_url: str | None = None

    @classmethod
    def from_environment(cls) -> EmbyConfiguration | None:
        try:
            server, user_id, token = (os.environ.get(key, "").strip() for key in PRIMARY_ENV)
            web = os.environ.get("FADEDAI_EMBY_WEB_URL", "").strip()
            if not any(key in os.environ for key in PRIMARY_ENV):
                saved = _load_saved_settings()
                if saved is not None:
                    server, user_id, token = (saved.get(key, "").strip() for key in ("url", "user_id", "token"))
                    web = web or saved.get("web_url", "").strip()
            if not (server or user_id or token or web):
                return None
            api_base = emby_api_base(server)
            if not valid_id(user_id) or not valid_token(token):
                raise ValueError("Invalid Emby authentication settings")
            web_url = parse_configured_url(web, https_only=True).geturl() if web else None
            if web_url and token in web_url:
                raise ValueError("The web URL cannot contain the token")
        except (OSError, ValueError) as exc:
            raise EmbyLibraryError(503, "Emby-opsætningen på PC’en mangler eller er ugyldig.") from exc
        return cls(api_base, user_id, token, web_url)


def _load_saved_settings() -> dict[str, str] | None:
    if os.name != "nt":
        return None
    from sweatcaster.emby_settings import load_local_settings

    return load_local_settings()


def valid_id(value: object) -> bool:
    return isinstance(value, str) and ID_PATTERN.fullmatch(value) is not None


def valid_token(value: str) -> bool:
    return re.fullmatch(r"[!-~]{1,256}", value) is not None


def is_local(host: str) -> bool:
    if host == "localhost":
        return True
    try:
        address = ipaddress.ip_address(host)
    except ValueError:
        return False
    return address.is_loopback or any(address in network for network in LOCAL_NETWORKS)


def parse_configured_url(value: str, *, https_only: bool = False):
    if len(value) > 2048 or any(character.isspace() for character in value):
        raise ValueError("Invalid Emby URL")
    url = urlsplit(value)
    port = url.port
    if (not url.hostname or url.username is not None or url.password is not None or port == 0
            or "?" in value or "#" in value or "\\" in value
            or not re.fullmatch(r"(?:/[A-Za-z0-9_.~-]+)*/?", url.path)
            or any(part in {".", ".."} for part in url.path.split("/"))):
        raise ValueError("Invalid Emby URL")
    if url.scheme != "https" and (https_only or url.scheme != "http" or not is_local(url.hostname)):
        raise ValueError("Emby requires HTTPS outside the local network")
    return url


def emby_api_base(value: str) -> str:
    api_url = parse_configured_url(value)
    path = api_url.path.rstrip("/")
    if path.rsplit("/", 1)[-1].casefold() != "emby":
        path += "/emby"
    return api_url._replace(path=path).geturl()


class NoRedirects(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def _read_bounded_json(response, *, limit: int, deadline: float):
    data = bytearray()
    while len(data) <= limit:
        if monotonic() > deadline:
            raise TimeoutError
        chunk = response.read1(min(65536, limit + 1 - len(data)))
        if not chunk:
            break
        data.extend(chunk)
    if len(data) > limit:
        raise ValueError("Emby response exceeds size limit")
    return json.loads(data)


def find_secure_server(address: str) -> str | None:
    """Check Emby's public endpoint over HTTPS without a token or a password."""
    supplied = urlsplit(address)
    if supplied.scheme == "https":
        candidates = [parse_configured_url(address, https_only=True).geturl()]
    elif address[:7].lower() == "http://":
        # Reuse the configured URL checks without making an HTTP request.
        secured = parse_configured_url("https" + address[4:], https_only=True)
        host = secured.hostname
        if ":" in host:
            host = f"[{host}]"
        candidates = [secured._replace(netloc=host).geturl(), secured._replace(netloc=f"{host}:8920").geturl()]
    else:
        raise ValueError("Invalid Emby URL")

    opener = build_opener(ProxyHandler({}), NoRedirects())
    for candidate in candidates:
        request = Request(f"{emby_api_base(candidate)}/System/Info/Public", headers={"Accept": "application/json"})
        deadline = monotonic() + REQUEST_TIMEOUT
        try:
            with opener.open(request, timeout=REQUEST_TIMEOUT) as response:
                info = _read_bounded_json(response, limit=MAX_PUBLIC_INFO_BYTES, deadline=deadline)
            if (isinstance(info, dict) and valid_id(info.get("Id"))
                    and all(isinstance(info.get(key), str) and info[key].strip() for key in ("ServerName", "Version"))):
                return candidate
        except HTTPError as exc:
            exc.close()
        except (OSError, ValueError, RecursionError, http.client.HTTPException):
            continue
    return None


def fetch_emby(config: EmbyConfiguration, resource: str, parameters: dict) -> dict:
    url = f"{config.api_base}/Users/{config.user_id}/{resource}?{urlencode(parameters)}"
    request = Request(url, headers={"Accept": "application/json", "X-Emby-Token": config.token})
    opener = build_opener(ProxyHandler({}), NoRedirects())
    deadline = monotonic() + REQUEST_TIMEOUT
    try:
        with opener.open(request, timeout=REQUEST_TIMEOUT) as response:
            result = _read_bounded_json(response, limit=MAX_RESPONSE_BYTES, deadline=deadline)
            if not isinstance(result, dict) or not isinstance(result.get("Items"), list):
                raise ValueError("Emby response is missing the item list")
            return result
    except HTTPError as exc:
        exc.close()
        if exc.code in {408, 429, 502, 503, 504}:
            raise EmbyLibraryError(503, "Emby-serveren svarer ikke lige nu.") from exc
        raise EmbyLibraryError(502, "Emby afviste opslaget. Tjek brugerens adgang og opsætningen på PC’en.") from exc
    except (OSError, URLError) as exc:
        raise EmbyLibraryError(503, "PC’en kunne ikke få forbindelse til Emby-serveren.") from exc
    except (ValueError, RecursionError, http.client.HTTPException) as exc:
        raise EmbyLibraryError(502, "Emby sendte et svar, som FadedAI ikke kunne læse.") from exc


def display_text(value: object, limit: int) -> str:
    if not isinstance(value, str):
        return ""
    return " ".join(value[:limit * 2].split())[:limit]


def library_item(row: object, config: EmbyConfiguration, is_root_view: bool) -> dict | None:
    if not isinstance(row, dict) or not valid_id(row.get("Id")) or row["Id"] == config.token:
        return None
    title = display_text(row.get("Name"), 240)
    if not title:
        return None
    item_type = display_text(row.get("Type"), 64)
    kind = display_text(row.get("CollectionType"), 64) or item_type or "Item"
    folder = (is_root_view or row.get("IsFolder") is True
              or item_type in {"Folder", "CollectionFolder", "Series", "Season", "MusicAlbum", "MusicArtist"})
    item = {"id": row["Id"], "title": title.replace(config.token, "[skjult]"),
            "kind": kind.replace(config.token, "[skjult]"), "folder": folder}
    parts = [display_text(row.get(key), 120) for key in ("SeriesName", "Album")]
    year = row.get("ProductionYear")
    if type(year) is int and 1800 <= year <= 2200:
        parts.append(str(year))
    subtitle = " · ".join(dict.fromkeys(part for part in parts if part and part != title))
    if subtitle:
        item["subtitle"] = subtitle.replace(config.token, "[skjult]")
    if config.web_url and not folder and valid_id(row.get("ServerId")) and row["ServerId"] != config.token:
        fragment = "!/item?" + urlencode({"id": row["Id"], "serverId": row["ServerId"]})
        item["webURL"] = urlsplit(config.web_url)._replace(fragment=fragment).geturl()
    return item


def read_library(*, parent: str | None = None, search: str = "", offset: int = 0) -> dict:
    if ((parent is not None and not valid_id(parent)) or len(search) > 120
            or not 0 <= offset <= MAX_OFFSET):
        raise EmbyLibraryError(422, "Emby-opslaget er ugyldigt.")
    config = EmbyConfiguration.from_environment()
    if config is None:
        return {"configured": False, "items": [], "nextOffset": None}

    search = search.strip()
    is_root_view = parent is None and not search
    if is_root_view:
        result = fetch_emby(config, "Views", {"IncludeExternalContent": "false"})
        rows = result["Items"][offset:offset + PAGE_SIZE]
        total = len(result["Items"])
    else:
        parameters = {"StartIndex": offset, "Limit": PAGE_SIZE, "SortBy": "SortName"}
        if parent is not None:
            parameters["ParentId"] = parent
        if search:
            parameters.update(SearchTerm=search, Recursive="true")
        result = fetch_emby(config, "Items", parameters)
        rows = result["Items"][:PAGE_SIZE]
        total = result.get("TotalRecordCount")

    end = offset + len(rows)
    has_more = end < total if type(total) is int else len(rows) == PAGE_SIZE
    items = [item for row in rows if (item := library_item(row, config, is_root_view)) is not None]
    next_offset = end if rows and has_more and end <= MAX_OFFSET else None
    return {"configured": True, "items": items, "nextOffset": next_offset}

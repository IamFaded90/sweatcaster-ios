"""Read a small, user-requested set of results from the PC's local SearXNG."""

from __future__ import annotations

import http.client
import ipaddress
import json
import re
import unicodedata
from html import unescape
from time import monotonic
from urllib.parse import urlencode, urlsplit, urlunsplit

MAX_QUERY_LENGTH = 180
MAX_RESULTS = 5
MAX_RESPONSE_BYTES = 256 * 1024
REQUEST_TIMEOUT = 5
HOST_LABEL = re.compile(r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?")


class SearXNGError(Exception):
    def __init__(self, status: int, message: str):
        super().__init__(message)
        self.status = status
        self.message = message


def _public_url(value: object) -> str | None:
    if (not isinstance(value, str) or not 1 <= len(value) <= 2048
            or "\\" in value or any(c.isspace() or unicodedata.category(c).startswith("C") for c in value)):
        return None
    try:
        parts = urlsplit(value)
        if (parts.scheme not in {"http", "https"} or not parts.hostname
                or parts.username is not None or parts.password is not None or parts.port == 0):
            return None
        host = parts.hostname.rstrip(".").encode("idna").decode("ascii").lower()
        port = parts.port
        try:
            address = ipaddress.ip_address(host)
        except ValueError:
            labels = host.split(".")
            if (len(labels) < 2 or len(host) > 253 or labels[-1].isdigit()
                    or any(HOST_LABEL.fullmatch(label) is None for label in labels)
                    or host.endswith((".localhost", ".local", ".internal", ".home.arpa"))):
                return None
        else:
            if not address.is_global or address.is_multicast:
                return None
            host = f"[{address}]" if address.version == 6 else str(address)
        authority = host if port is None else f"{host}:{port}"
        return urlunsplit((parts.scheme, authority, parts.path or "/", parts.query, ""))
    except (ValueError, UnicodeError):
        return None


def _text(value: object, limit: int, max_bytes: int) -> str:
    if not isinstance(value, str):
        return ""
    value = unescape(value[:limit * 4])
    display = "".join(" " if unicodedata.category(c).startswith("C") else c for c in value)
    return " ".join(display.split())[:limit].encode("utf-8")[:max_bytes].decode("utf-8", errors="ignore")


def _results(payload: object) -> list[dict[str, str]]:
    if not isinstance(payload, dict) or not isinstance(payload.get("results"), list):
        raise ValueError("Missing SearXNG results")
    rows = []
    seen = set()
    for item in payload["results"]:
        if not isinstance(item, dict):
            continue
        url = _public_url(item.get("url"))
        title = _text(item.get("title"), 140, 300)
        if not url or len(url.encode("utf-8")) > 700 or not title or url in seen:
            continue
        seen.add(url)
        rows.append({"title": title, "url": url, "snippet": _text(item.get("content"), 280, 400)})
        if len(rows) == MAX_RESULTS:
            break
    return rows


def _read_json(response: http.client.HTTPResponse, deadline: float) -> object:
    body = bytearray()
    while len(body) <= MAX_RESPONSE_BYTES:
        if monotonic() >= deadline:
            raise TimeoutError
        chunk = response.read1(min(16384, MAX_RESPONSE_BYTES + 1 - len(body)))
        if not chunk:
            break
        body.extend(chunk)
    if len(body) > MAX_RESPONSE_BYTES:
        raise ValueError("SearXNG response exceeds size limit")
    return json.loads(body)


def search_web(query: object) -> list[dict[str, str]]:
    """Send a user-provided query to the loopback search service."""
    if (not isinstance(query, str) or len(query) > MAX_QUERY_LENGTH
            or any(unicodedata.category(c).startswith("C") for c in query) or len(query.strip()) < 3):
        raise SearXNGError(422, "Skriv en websøgning på 3 til 180 tegn.")
    form = urlencode({"q": query.strip(), "format": "json", "categories": "general"}).encode("ascii")
    # A direct loopback connection does not consult proxy settings or follow redirects.
    connection = http.client.HTTPConnection("127.0.0.1", 8080, timeout=REQUEST_TIMEOUT)
    deadline = monotonic() + REQUEST_TIMEOUT
    try:
        connection.request("POST", "/search", form, headers={
            "Accept": "application/json",
            "Content-Type": "application/x-www-form-urlencoded",
        })
        with connection.getresponse() as response:
            if response.status == 403:
                raise SearXNGError(503, "SearXNG afviste opslaget. Tjek, at JSON er slået til på PC’en.")
            if response.status in {408, 429, 502, 503, 504}:
                raise SearXNGError(503, "SearXNG er midlertidigt utilgængelig. Prøv igen om lidt.")
            if response.status != 200 or response.headers.get_content_type() != "application/json":
                raise ValueError("Unexpected SearXNG response")
            return _results(_read_json(response, deadline))
    except OSError as exc:
        raise SearXNGError(503, "Websøgningen på PC’en svarer ikke. Tjek, at SearXNG kører i Docker.") from exc
    except (http.client.HTTPException, ValueError, RecursionError) as exc:
        raise SearXNGError(502, "Websøgningen gav et svar, som FadedAI ikke kunne læse.") from exc
    finally:
        connection.close()

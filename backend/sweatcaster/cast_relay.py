"""Paired-PC Cast relay for public media URLs, with short-lived receiver links."""
from dataclasses import dataclass, field
import http.client
import ipaddress
import json
import re
import secrets
import socket
import ssl
import threading
import time
from urllib.parse import urljoin, urlsplit

from fastapi import Request, Response
from fastapi.responses import StreamingResponse

from sweatcaster.dto import ApiError


PREFIX = "/api/modules/v1/cast-relay"
HLS = {"application/vnd.apple.mpegurl", "application/x-mpegurl", "audio/mpegurl"}
MEDIA = HLS | {"video/mp4", "video/mp2t", "video/webm", "audio/aac", "audio/mp4", "audio/mpeg",
               "audio/ac3", "audio/eac3", "text/vtt", "application/octet-stream"}
RANGE = re.compile(r"bytes=(?:\d{1,19}-\d{0,19}|-\d{1,19})\Z")
URI = re.compile(r'\bURI="([^"]+)"')
TOKEN = re.compile(r"[A-Za-z0-9_-]{24,64}\Z")
LAN = tuple(ipaddress.ip_network(net) for net in ("10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16"))
MAX_PLAYLIST = 2 * 1024 * 1024
PLAYLIST_MARKER = b"#EXTM3U"
PLAYLIST_TYPES_TO_VERIFY = {"", "application/octet-stream", "text/plain", "image/jpeg", "image/png"}
TLS = ssl.create_default_context()
CORS = {
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Methods": "GET, HEAD, OPTIONS",
    "Access-Control-Allow-Headers": "Range",
    "Access-Control-Allow-Private-Network": "true",
    "Access-Control-Expose-Headers": "Content-Range, Content-Length, Accept-Ranges",
    "Cache-Control": "no-store",
}


def source_url(value):
    if (not isinstance(value, str) or not 1 <= len(value) <= 4096 or not value.isascii()
            or any(ord(char) <= 32 or ord(char) == 127 for char in value)):
        raise ValueError("Invalid media URL")
    parsed = urlsplit(value)
    if (parsed.scheme not in {"http", "https"} or not parsed.hostname or parsed.username is not None
            or parsed.password is not None or parsed.fragment or "%" in parsed.hostname
            or parsed.port not in {None, 80 if parsed.scheme == "http" else 443}):
        raise ValueError("Invalid media origin")
    return parsed


def connect_public(destination, timeout, source_address=None):
    host, port = destination
    addresses = socket.getaddrinfo(host, port, family=socket.AF_INET, type=socket.SOCK_STREAM)
    ips = [ipaddress.IPv4Address(row[4][0]) for row in addresses]
    if not ips or any(not ip.is_global or ip.is_multicast or ip.is_reserved for ip in ips):
        raise ValueError("Media host must be public")
    for family, kind, protocol, _, address in addresses:
        connection = socket.socket(family, kind, protocol)
        try:
            connection.settimeout(timeout)
            if source_address:
                connection.bind(source_address)
            connection.connect(address)
            return connection
        except OSError:
            connection.close()
    raise OSError("Media host unreachable")


def open_media(url, method, byte_range, referer):
    for _ in range(5):
        parsed = source_url(url)
        secure = parsed.scheme == "https"
        cls = http.client.HTTPSConnection if secure else http.client.HTTPConnection
        options = {"context": TLS} if secure else {}
        connection = cls(parsed.hostname, parsed.port, timeout=10, **options)
        # Use the checked socket address while retaining the original Host and TLS identity.
        connection._create_connection = connect_public
        # Media hosts commonly validate browser headers even when Chromecast is
        # fetching the stream from the paired PC. Do not forward phone cookies or
        # credentials; this relay serves public sources only.
        headers = {"Accept": "*/*", "Accept-Encoding": "identity", "User-Agent": "Mozilla/5.0"}
        if byte_range:
            headers["Range"] = byte_range
        if referer:
            headers["Referer"] = referer
            origin = urlsplit(referer)
            headers["Origin"] = f"{origin.scheme}://{origin.netloc}"
        path = parsed.path or "/"
        if parsed.query:
            path += "?" + parsed.query
        try:
            connection.request(method, path, headers=headers)
            response = connection.getresponse()
            if response.status in {301, 302, 303, 307, 308}:
                url = urljoin(url, response.getheader("Location", ""))
                connection.close()
                continue
            return connection, response, url
        except BaseException:
            connection.close()
            raise
    raise ValueError("Too many redirects")


def identifying_type(response, url):
    kind = response.getheader("Content-Type", "").split(";", 1)[0].strip().lower()
    if kind in {"", "application/octet-stream", "text/plain"} and urlsplit(url).path.lower().endswith(".m3u8"):
        return "application/vnd.apple.mpegurl"
    return kind


@dataclass
class RelaySession:
    referer: str
    expires: float = field(default_factory=lambda: time.monotonic() + 8 * 3600)
    routes: dict = field(default_factory=dict)
    resources: dict = field(default_factory=dict)
    lock: threading.Lock = field(default_factory=threading.Lock)

    def route(self, url):
        source_url(url)
        with self.lock:
            if url in self.resources:
                return self.resources[url]
            if len(self.routes) >= 28_000:
                raise ValueError("Film contains too many resources")
            token = secrets.token_urlsafe(18)
            self.routes[token] = url
            self.resources[url] = token
            return token


def rewrite_hls(data, url, session, receiver_token):
    if len(data) > MAX_PLAYLIST:
        raise ValueError("Playlist too large")
    source_lines = data.decode("utf-8-sig").splitlines()
    if not source_lines or source_lines[0] != PLAYLIST_MARKER.decode("ascii"):
        raise ValueError("Invalid playlist")

    def local(uri):
        target = session.route(urljoin(url, uri))
        return f"{PREFIX}/play/{receiver_token}/{target}"

    lines = []
    for line in source_lines:
        if line.startswith("#"):
            line = URI.sub(lambda match: 'URI="' + local(match[1]) + '"', line)
        elif line.strip():
            line = local(line.strip())
        lines.append(line)
    return ("\n".join(lines) + "\n").encode()


def register_cast_relay(app, settings, authorize):
    sessions = {}
    sessions_lock = threading.Lock()
    slots = threading.BoundedSemaphore(16)

    @app.put(PREFIX, include_in_schema=False)
    async def new_relay(request: Request, response: Response):
        authorize(request, settings)
        data = bytearray()
        async for chunk in request.stream():
            if len(data) + len(chunk) > 9_000:
                raise ApiError(422, "INVALID_INPUT", "Cast-linket er for langt.")
            data.extend(chunk)
        try:
            body = json.loads(data)
            if not isinstance(body, dict):
                raise ValueError("Invalid payload")
            url = body.get("url")
            source_url(url)
            referer = source_url(body["origin"]) if body.get("origin") else None
        except (ValueError, TypeError):
            raise ApiError(422, "INVALID_INPUT", "PC’en kunne ikke bruge filmens adresse.") from None
        session = RelaySession(f"{referer.scheme}://{referer.netloc}/" if referer else "")
        route = session.route(url)
        receiver_token = secrets.token_urlsafe(24)
        with sessions_lock:
            now = time.monotonic()
            for token in list(sessions):
                if sessions[token].expires < now:
                    del sessions[token]
            while len(sessions) >= 4:
                del sessions[next(iter(sessions))]
            sessions[receiver_token] = session
        response.headers["Cache-Control"] = "no-store"
        return {"path": f"{PREFIX}/play/{receiver_token}/{route}"}

    @app.api_route(PREFIX + "/play/{receiver_token}/{route}", methods=["GET", "HEAD", "OPTIONS"], include_in_schema=False)
    def play_relay(request: Request, receiver_token: str, route: str):
        if not TOKEN.fullmatch(receiver_token) or not TOKEN.fullmatch(route):
            return Response(status_code=404, headers=CORS)
        try:
            peer = ipaddress.ip_address(request.client.host if request.client else "")
        except ValueError:
            return Response(status_code=404, headers=CORS)
        if not any(peer in subnet for subnet in LAN):
            return Response(status_code=404, headers=CORS)
        with sessions_lock:
            session = sessions.get(receiver_token)
        if session is None or session.expires < time.monotonic():
            return Response(status_code=404, headers=CORS)
        with session.lock:
            url = session.routes.get(route)
        if url is None:
            return Response(status_code=404, headers=CORS)
        if request.method == "OPTIONS":
            return Response(status_code=204, headers=CORS)
        byte_range = request.headers.get("range")
        if byte_range and not RANGE.fullmatch(byte_range):
            return Response(status_code=416, headers=CORS)
        if not slots.acquire(blocking=False):
            return Response(status_code=503, headers=CORS)
        connection = None
        keep_open = False
        try:
            connection, upstream, final_url = open_media(url, request.method, byte_range, session.referer)
            kind = identifying_type(upstream, final_url)
            if upstream.status == 416:
                headers = dict(CORS)
                if upstream.getheader("Content-Range"):
                    headers["Content-Range"] = upstream.getheader("Content-Range")
                return Response(status_code=416, headers=headers)
            if upstream.status not in {200, 206}:
                return Response(status_code=502, headers=CORS)
            prefix = b""
            if request.method == "GET" and upstream.status == 200 and kind in PLAYLIST_TYPES_TO_VERIFY:
                prefix = upstream.read(12)
                marker = prefix.removeprefix(b"\xef\xbb\xbf").splitlines()[0:1]
                if marker == [PLAYLIST_MARKER]:
                    kind = "application/vnd.apple.mpegurl"
            if kind not in MEDIA:
                return Response(status_code=502, headers=CORS)
            if kind in HLS and request.method == "GET":
                data = rewrite_hls(prefix + upstream.read(MAX_PLAYLIST + 1 - len(prefix)), final_url, session, receiver_token)
                return Response(data, media_type=kind, headers=CORS)
            headers = dict(CORS)
            for name in ("Content-Length", "Content-Range", "Accept-Ranges"):
                if upstream.getheader(name):
                    headers[name] = upstream.getheader(name)
            if request.method == "HEAD":
                return Response(status_code=upstream.status, media_type=kind, headers=headers)

            def stream():
                try:
                    if prefix:
                        yield prefix
                    while chunk := upstream.read(128 * 1024):
                        yield chunk
                finally:
                    connection.close()
                    slots.release()

            keep_open = True
            return StreamingResponse(stream(), status_code=upstream.status, media_type=kind, headers=headers)
        except (OSError, ValueError, http.client.HTTPException):
            return Response(status_code=502, headers=CORS)
        finally:
            if not keep_open:
                if connection is not None:
                    connection.close()
                slots.release()

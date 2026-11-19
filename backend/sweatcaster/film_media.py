"""Read a bounded window of an accessible VOD through the same public-media checks as Cast."""
from contextlib import contextmanager
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import re
import http.client
import secrets
import shutil
import subprocess
import threading
from urllib.parse import urljoin, urlsplit

from sweatcaster.cast_relay import MAX_PLAYLIST, RANGE, RelaySession, open_media, source_url


class FilmSourceError(Exception):
    pass


def rewrite_playlist(data, source, local):
    lines = data.decode("utf-8-sig").splitlines()
    if not lines or lines[0].strip() != "#EXTM3U" or len(data) > MAX_PLAYLIST:
        raise FilmSourceError("Filmens afspilningsliste kunne ikke læses.")
    # Live playlists have no confirmed film-relative origin. Keys are never retrieved.
    if not any(line.startswith("#EXT-X-STREAM-INF:") for line in lines) and "#EXT-X-ENDLIST" not in lines:
        raise FilmSourceError("Filmvennen kan kun tidsfæste en film med en fast begyndelse.")
    result = []
    for line in lines:
        line = line.strip()
        if not line:
            continue
        if line.startswith(("#EXT-X-KEY:", "#EXT-X-SESSION-KEY:")):
            if line != "#EXT-X-KEY:METHOD=NONE":
                raise FilmSourceError("Denne film har et beskyttet spor.")
            continue
        if not line.startswith("#"):
            result.append(local(urljoin(source, line)))
            continue
        directive = line.partition(":")[0]
        if directive not in {
            "#EXTM3U", "#EXT-X-STREAM-INF", "#EXT-X-MEDIA", "#EXT-X-MAP", "#EXTINF",
            "#EXT-X-BYTERANGE", "#EXT-X-TARGETDURATION", "#EXT-X-ENDLIST", "#EXT-X-VERSION",
            "#EXT-X-MEDIA-SEQUENCE", "#EXT-X-INDEPENDENT-SEGMENTS", "#EXT-X-PLAYLIST-TYPE",
            "#EXT-X-DISCONTINUITY", "#EXT-X-DISCONTINUITY-SEQUENCE",
        }:
            continue
        if directive in {"#EXT-X-MEDIA", "#EXT-X-MAP"}:
            if "URI=" in line:
                match = re.search(r'(?:[:,])URI="([^"]+)"', line)
                if not match or line.count("URI=") != 1:
                    raise FilmSourceError("Filmens sporadresse kunne ikke læses.")
                line = line[:match.start(1)] + local(urljoin(source, match[1])) + line[match.end(1):]
        result.append(line)
    return ("\n".join(result) + "\n").encode()


@contextmanager
def readable_source(source, origin=None, user_agent="Mozilla/5.0"):
    source_url(source)
    referer = ""
    if origin:
        parts = source_url(origin)
        referer = parts._replace(path=parts.path or "/", query="", fragment="").geturl()
    session = RelaySession(referer)
    secret = secrets.token_urlsafe(24)
    problem = []
    remaining = 64 * 1024 * 1024
    budget_lock = threading.Lock()

    def limited_read(response, size):
        nonlocal remaining
        with budget_lock:
            size = min(size, remaining)
            if not size:
                raise FilmSourceError("Kilden leverede for mange data til et kort filmudsnit.")
            remaining -= size
        data = response.read(size)
        with budget_lock:
            remaining += size - len(data)
        return data

    class Reader(BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass

        def do_GET(self):
            self.serve("GET")

        def do_HEAD(self):
            self.serve("HEAD")

        def serve(self, method):
            path = self.path.split("/")
            if len(path) != 4 or path[1] != secret:
                self.send_error(404)
                return
            with session.lock:
                url = session.routes.get(path[2])
            if not url:
                self.send_error(404)
                return
            byte_range = self.headers.get("Range")
            if byte_range and not RANGE.fullmatch(byte_range):
                self.send_error(416)
                return
            connection = None
            try:
                connection, response, final = open_media(url, method, byte_range, referer, user_agent)
                if response.status not in (200, 206):
                    self.send_error(502)
                    return
                if byte_range and not byte_range.startswith("bytes=0-") and response.status != 206:
                    raise FilmSourceError("Kilden tillader ikke at hente et kort udsnit ved TV’ets tidspunkt.")
                kind = response.getheader("Content-Type", "").partition(";")[0].lower()
                prefix = limited_read(response, 10) if method == "GET" else b""
                if prefix.lstrip(b"\xef\xbb\xbf").startswith(b"#EXTM3U"):
                    data = rewrite_playlist(prefix + limited_read(response, MAX_PLAYLIST + 1), final, local)
                    self.send_response(200)
                    self.send_header("Content-Type", "application/vnd.apple.mpegurl")
                    self.send_header("Content-Length", str(len(data)))
                    self.end_headers()
                    self.wfile.write(data)
                    return
                if kind.startswith("text/html") or "mpegurl" in kind and method == "GET":
                    raise FilmSourceError("Kilden leverede ingen læsbar video.")
                self.send_response(response.status)
                for key in ("Content-Type", "Content-Length", "Content-Range", "Accept-Ranges"):
                    if value := response.getheader(key):
                        self.send_header(key, value)
                self.end_headers()
                if method == "GET":
                    self.wfile.write(prefix)
                    while block := limited_read(response, 64 * 1024):
                        self.wfile.write(block)
            except (ConnectionError, OSError, http.client.HTTPException):
                return
            except (ValueError, FilmSourceError, UnicodeError) as exc:
                problem[:] = [str(exc) if isinstance(exc, FilmSourceError) else "Filmens kilde kan ikke læses."]
                self.send_error(502)
            finally:
                if connection:
                    connection.close()

    server = ThreadingHTTPServer(("127.0.0.1", 0), Reader)
    base = f"http://127.0.0.1:{server.server_port}/{secret}"

    def local(url):
        token = session.route(url)
        ext = Path(urlsplit(url).path).suffix.lower()
        safe_ext = ext if re.fullmatch(r"\.[a-z0-9]{1,6}", ext) else ".bin"
        return f"{base}/{token}/media{safe_ext}"

    root = local(source)
    worker = threading.Thread(target=server.serve_forever, daemon=True)
    worker.start()
    try:
        yield root, problem
    finally:
        server.shutdown()
        server.server_close()
        worker.join(timeout=2)


def decode(media, start, duration, args, *, timeout=30):
    if not shutil.which("ffmpeg"):
        raise FilmSourceError("FFmpeg mangler på PC’en.")
    command = ["ffmpeg", "-nostdin", "-hide_banner", "-loglevel", "error", "-rw_timeout", "6000000",
               "-protocol_whitelist", "http,tcp", "-format_whitelist",
               "hls,mov,matroska,webm,mpegts,aac,mp3,webvtt,srt",
               "-ss", f"{start:.3f}", "-i", media, "-t", f"{duration:.3f}", *args]
    try:
        result = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                timeout=timeout, check=False)
    except (OSError, subprocess.TimeoutExpired):
        return b""
    return result.stdout if result.returncode == 0 else b""

import json
import re
import shutil
import socket
import subprocess
import tempfile
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from threading import Thread
from unittest.mock import patch

from fastapi import FastAPI, HTTPException
from fastapi.responses import JSONResponse
from fastapi.testclient import TestClient

from sweatcaster import cast_relay


class Fixture(BaseHTTPRequestHandler):
    def do_GET(self):
        media = getattr(self.server, "fmp4", {})
        if self.path in media:
            kind, body = media[self.path]
            self.send_response(200)
            self.send_header("Content-Type", kind)
        elif self.path.startswith("/protected/"):
            if (self.headers.get("Origin") != "https://cinema.invalid" or
                    self.headers.get("Referer") != "https://cinema.invalid/watch/movie/123" or
                    self.headers.get("User-Agent") != "Mozilla/5.0 FadedBrowser/1.0"):
                self.send_response(403)
                body = b""
            elif self.path == "/protected/master.m3u8":
                body = b'#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=450000\nstream.m3u8\n'
                self.send_response(200)
                self.send_header("Content-Type", "application/vnd.apple.mpegurl")
            elif self.path == "/protected/stream.m3u8":
                body = b'#EXTM3U\n#EXTINF:5,\nsegment.mp4\n#EXT-X-ENDLIST\n'
                self.send_response(200)
                self.send_header("Content-Type", "application/vnd.apple.mpegurl")
            else:
                body = b"video-data"
                self.send_response(200)
                self.send_header("Content-Type", "video/mp4")
        elif self.path == "/stream.m3u8":
            body = b'#EXTM3U\n#EXT-X-MAP:URI="init.mp4"\n#EXTINF:5,\nsegment.mp4\n#EXT-X-ENDLIST\n'
            self.send_response(200)
            self.send_header("Content-Type", "application/vnd.apple.mpegurl")
        elif self.path == "/master.m3u8":
            body = b'#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=450000\nplaylist.jpg\n'
            self.send_response(200)
            self.send_header("Content-Type", "application/vnd.apple.mpegurl")
        elif self.path in {"/playlist.jpg", "/photo.jpg"}:
            body = (b'\xef\xbb\xbf#EXTM3U\r\n#EXTINF:5,\nsegment.mp4\n#EXT-X-ENDLIST\n'
                    if self.path == "/playlist.jpg" else b"\xff\xd8\xff\xe0fake-image")
            self.send_response(200)
            self.send_header("Content-Type", "image/jpeg")
        elif self.path == "/redirect":
            self.send_response(302)
            self.send_header("Location", "http://127.0.0.1/private")
            body = b""
        elif self.path == "/browser-video.mp4":
            if (self.headers.get("Origin") != "https://cinema.invalid" or
                    self.headers.get("Referer") != "https://cinema.invalid/" or
                    self.headers.get("User-Agent") != "Mozilla/5.0"):
                self.send_response(403)
                body = b""
            else:
                body = b"video-data"
                self.send_response(200)
                self.send_header("Content-Type", "video/mp4")
        elif self.path in {"/init.mp4", "/segment.mp4"}:
            body = b"video-data"
            if self.headers.get("Range") == "bytes=2-5":
                body = body[2:6]
                self.send_response(206)
                self.send_header("Content-Range", "bytes 2-5/10")
            else:
                self.send_response(200)
            self.send_header("Content-Type", "video/mp4")
        else:
            self.send_response(404)
            body = b""
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


class CastRelayTests(unittest.TestCase):
    def setUp(self):
        self.upstream = ThreadingHTTPServer(("127.0.0.1", 0), Fixture)
        self.thread = Thread(target=self.upstream.serve_forever, daemon=True)
        self.thread.start()
        self.addCleanup(self.upstream.server_close)
        self.addCleanup(self.upstream.shutdown)
        real_connect = cast_relay.connect_public

        def fixture_connection(destination, timeout, source_address=None):
            if destination[0] == "fixture.invalid":
                return socket.create_connection(self.upstream.server_address, timeout)
            return real_connect(destination, timeout, source_address)

        self.enterContext(patch.object(cast_relay, "connect_public", fixture_connection))
        app = FastAPI()

        @app.exception_handler(cast_relay.ApiError)
        async def error_response(_, error):
            return JSONResponse(status_code=error.status_code, content={"error": error.code})

        def authorize(request, settings):
            if request.headers.get("Authorization") != "Bearer fixture":
                raise HTTPException(status_code=401)

        cast_relay.register_cast_relay(app, None, authorize)
        self.app = app
        self.client = self.enterContext(TestClient(app, client=("192.168.1.44", 50000)))

    def create(self, source):
        response = self.client.put(cast_relay.PREFIX, json={"url": source},
                                   headers={"Authorization": "Bearer fixture"})
        self.assertEqual(response.status_code, 200)
        return response.json()["path"]

    def test_receiver_can_fetch_playlist_and_ranges_without_phone_token(self):
        url = self.create("http://fixture.invalid/stream.m3u8")
        response = self.client.get(url)
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.headers["Access-Control-Allow-Origin"], "*")
        playlist = response.text.splitlines()
        self.assertIn('URI="/api/modules/v1/cast-relay/play/', playlist[1])
        self.assertNotIn("fixture.invalid", response.text)
        segment = self.client.get(playlist[3], headers={"Range": "bytes=2-5"})
        self.assertEqual(segment.status_code, 206)
        self.assertEqual(segment.headers["Content-Range"], "bytes 2-5/10")
        self.assertEqual(segment.content, b"deo-")
        self.assertEqual(self.client.get(playlist[3], headers={"Range": "bytes=1-2,4-5"}).status_code, 416)
        self.assertEqual(self.client.get(url[:-1] + "$").status_code, 404)
        self.assertEqual(self.client.options(playlist[3]).status_code, 204)

    def test_receiver_keeps_streaming_after_sender_disconnects_and_locks(self):
        with TestClient(self.app, client=("192.168.1.44", 50000)) as sender:
            response = sender.put(cast_relay.PREFIX,
                                  json={"url": "http://fixture.invalid/stream.m3u8"},
                                  headers={"Authorization": "Bearer fixture"})
            self.assertEqual(response.status_code, 200)
            receiver_url = response.json()["path"]
        future = cast_relay.time.monotonic() + 600
        with patch.object(cast_relay, "time") as clock, TestClient(self.app, client=("192.168.1.55", 52001)) as tv:
            clock.monotonic.return_value = future
            playlist = tv.get(receiver_url)
            self.assertEqual(playlist.status_code, 200)
            self.assertEqual(tv.get(playlist.text.splitlines()[3]).content, b"video-data")

    @unittest.skipUnless(shutil.which("ffmpeg") and shutil.which("ffprobe"), "requires FFmpeg")
    def test_receiver_decodes_fragmented_mp4_after_sender_closes(self):
        with tempfile.TemporaryDirectory() as folder:
            subprocess.run(["ffmpeg", "-v", "error", "-f", "lavfi", "-i", "testsrc2=s=64x64:r=10",
                            "-f", "lavfi", "-i", "sine=frequency=440", "-t", "3",
                            "-c:v", "libx264", "-threads", "1", "-g", "10", "-sc_threshold", "0", "-c:a", "aac",
                            "-f", "hls", "-hls_time", "1", "-hls_list_size", "0", "-hls_segment_type", "fmp4",
                            "-hls_segment_filename", "part%02d.m4s", "index.m3u8"], cwd=folder,
                           stdin=subprocess.DEVNULL, check=True, capture_output=True, timeout=20)
            types = {".m3u8": "application/vnd.apple.mpegurl", ".mp4": "video/mp4", ".m4s": "video/iso.segment"}
            self.upstream.fmp4 = {"/" + f.name: (types[f.suffix], f.read_bytes()) for f in Path(folder).iterdir()}
        with TestClient(self.app, client=("192.168.1.44", 50000)) as sender:
            started = sender.put(cast_relay.PREFIX, json={"url": "http://fixture.invalid/index.m3u8"},
                                 headers={"Authorization": "Bearer fixture"})
            self.assertEqual(started.status_code, 200)
            receiver_url = started.json()["path"]
        with TestClient(self.app, client=("192.168.1.55", 52001)) as receiver:
            playlist = receiver.get(receiver_url)
            self.assertEqual(playlist.status_code, 200)
            init = re.search(r'#EXT-X-MAP:URI="([^"]+)"', playlist.text)
            self.assertIsNotNone(init)
            initial = receiver.get(init[1])
            self.assertEqual(initial.status_code, 200)
            fragments = [line for line in playlist.text.splitlines() if line and not line.startswith("#")]
            self.assertEqual(len(fragments), 3)
            parts = [initial.content]
            for path in fragments:
                data = receiver.get(path)
                self.assertEqual(data.status_code, 200)
                self.assertEqual(data.headers["Content-Type"], "video/iso.segment")
                parts.append(data.content)
        probe = subprocess.run(["ffprobe", "-v", "error", "-count_frames", "-show_entries",
                                "stream=codec_name,nb_read_frames", "-of", "json", "pipe:0"],
                               input=b"".join(parts), check=True, capture_output=True, timeout=15)
        frames = {s["codec_name"]: int(s["nb_read_frames"]) for s in json.loads(probe.stdout)["streams"]}
        self.assertEqual(frames["h264"], 30)
        self.assertGreater(frames["aac"], 0)

    def test_pairing_required_and_no_private_destination_or_redirect(self):
        self.assertEqual(self.client.put(cast_relay.PREFIX, json={"url": "http://fixture.invalid"}).status_code, 401)
        self.assertEqual(self.client.get(self.create("http://127.0.0.1/private")).status_code, 502)
        self.assertEqual(self.client.get(self.create("http://fixture.invalid/redirect")).status_code, 502)
        with TestClient(self.app, client=("8.8.8.8", 50000)) as outside:
            self.assertEqual(outside.get(self.create("http://fixture.invalid/stream.m3u8")).status_code, 404)

    def test_pc_relay_includes_public_browser_origin_for_media_host(self):
        response = self.client.put(cast_relay.PREFIX,
            json={"url": "http://fixture.invalid/browser-video.mp4", "origin": "https://cinema.invalid/"},
            headers={"Authorization": "Bearer fixture"})
        self.assertEqual(response.status_code, 200)
        self.assertEqual(self.client.get(response.json()["path"]).content, b"video-data")

    def test_receiver_uses_browser_page_and_identity_for_entire_hls_chain(self):
        response = self.client.put(cast_relay.PREFIX, json={
            "url": "http://fixture.invalid/protected/master.m3u8",
            "origin": "https://cinema.invalid/watch/movie/123?private=discard",
            "userAgent": "Mozilla/5.0 FadedBrowser/1.0",
        }, headers={"Authorization": "Bearer fixture"})
        self.assertEqual(response.status_code, 200)
        # The receiver needs only its URL. It never relies on a phone-side server
        # or the phone's pairing token for later variants and media segments.
        with TestClient(self.app, client=("192.168.1.39", 50001)) as receiver:
            master = receiver.get(response.json()["path"])
            self.assertEqual(master.status_code, 200)
            variant = receiver.get(master.text.splitlines()[2])
            self.assertEqual(variant.status_code, 200)
            segment = receiver.get(variant.text.splitlines()[2])
            self.assertEqual(segment.status_code, 200)
            self.assertEqual(segment.content, b"video-data")

    def test_browser_identity_rejects_header_injection_and_invalid_types(self):
        for identity in ("browser\r\nCookie: secret", "browser\x7f", "browseræ", "x" * 513, ["browser"], 9):
            response = self.client.put(cast_relay.PREFIX, json={
                "url": "http://fixture.invalid/browser-video.mp4", "userAgent": identity,
            }, headers={"Authorization": "Bearer fixture"})
            self.assertEqual(response.status_code, 422)

    def test_recognizes_a_mislabeled_variant_without_serving_a_jpeg(self):
        master = self.client.get(self.create("http://fixture.invalid/master.m3u8"))
        variant = self.client.get(master.text.splitlines()[2])
        self.assertEqual(variant.status_code, 200)
        self.assertTrue(variant.headers["Content-Type"].startswith("application/vnd.apple.mpegurl"))
        self.assertEqual(self.client.get(variant.text.splitlines()[2]).content, b"video-data")
        self.assertEqual(self.client.get(self.create("http://fixture.invalid/photo.jpg")).status_code, 502)

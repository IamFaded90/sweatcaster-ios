import socket
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from threading import Thread
from unittest.mock import patch

from fastapi import FastAPI, HTTPException
from fastapi.testclient import TestClient

from sweatcaster import cast_relay


class Fixture(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/stream.m3u8":
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

    def test_pairing_required_and_no_private_destination_or_redirect(self):
        self.assertEqual(self.client.put(cast_relay.PREFIX, json={"url": "http://fixture.invalid"}).status_code, 401)
        self.assertEqual(self.client.get(self.create("http://127.0.0.1/private")).status_code, 502)
        self.assertEqual(self.client.get(self.create("http://fixture.invalid/redirect")).status_code, 502)
        with TestClient(self.app, client=("8.8.8.8", 50000)) as outside:
            self.assertEqual(outside.get(self.create("http://fixture.invalid/stream.m3u8")).status_code, 404)

    def test_pc_relay_includes_public_browser_origin_for_media_host(self):
        response = self.client.put(cast_relay.PREFIX,
            json={"url": "http://fixture.invalid/browser-video.mp4", "origin": "https://cinema.invalid/watch"},
            headers={"Authorization": "Bearer fixture"})
        self.assertEqual(response.status_code, 200)
        self.assertEqual(self.client.get(response.json()["path"]).content, b"video-data")

    def test_recognizes_a_mislabeled_variant_without_serving_a_jpeg(self):
        master = self.client.get(self.create("http://fixture.invalid/master.m3u8"))
        variant = self.client.get(master.text.splitlines()[2])
        self.assertEqual(variant.status_code, 200)
        self.assertTrue(variant.headers["Content-Type"].startswith("application/vnd.apple.mpegurl"))
        self.assertEqual(self.client.get(variant.text.splitlines()[2]).content, b"video-data")
        self.assertEqual(self.client.get(self.create("http://fixture.invalid/photo.jpg")).status_code, 502)

from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import shutil
import socket
import subprocess
from tempfile import TemporaryDirectory
import threading
import unittest
from unittest.mock import patch

from fastapi import FastAPI, HTTPException
from fastapi.responses import JSONResponse
from fastapi.testclient import TestClient
from sweatcaster import cast_relay, film_companion as film, film_media


class QuietFiles(SimpleHTTPRequestHandler):
    def log_message(self, *args): pass


class FilmTests(unittest.TestCase):
    def test_cue_cutoff_and_hls_refusals(self):
        source = "1\n00:00:00,000 --> 00:00:01,000\nHej\n\n2\n00:00:01,000 --> 00:00:03,000\nFarvel"
        self.assertEqual(film.parse_cues(source, 52, 53.9), [{"start": 52.0, "end": 53.0, "text": "Hej"}])
        base = "https://fixture.invalid/v/list.m3u8"
        self.assertRaises(film_media.FilmSourceError, film_media.rewrite_playlist,
                          b"#EXTM3U\n#EXTINF:4,\ns.ts\n", base, str)
        self.assertRaises(film_media.FilmSourceError, film_media.rewrite_playlist,
                          b'#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI="key"\n#EXT-X-ENDLIST', base, str)
        self.assertIn(b"fixture.invalid/v/s.ts", film_media.rewrite_playlist(
            b"#EXTM3U\n#EXTINF:4,\ns.ts\n#EXT-X-ENDLIST", base, str))

    def test_authentication_and_position(self):
        app = FastAPI()
        @app.exception_handler(film.ApiError)
        async def handle(_, error):
            return JSONResponse(status_code=error.status_code, content={"error": error.code})
        def auth(request, _):
            if not request.headers.get("Authorization"): raise HTTPException(401)
        film.register_film_companion(app, None, auth)
        client = TestClient(app, raise_server_exceptions=False)
        path = "/api/modules/v1/film-companion"
        body = {"source": "https://example.org/film.mp4", "position": 12, "mode": "scene"}
        self.assertEqual(client.put(path, json=body).status_code, 401)
        with patch.object(film, "read_window", return_value={"cues": [], "detail": "Ingen lyd"}) as read:
            self.assertEqual(client.put(path, json=body, headers={"Authorization": "test"}).json()["detail"], "Ingen lyd")
            for val in (0, -1, True, 100000):
                bad = client.put(path, json=dict(body, position=val), headers={"Authorization": "test"})
                self.assertEqual(bad.status_code, 422)
            future = {"start": 4, "end": 13, "text": "Future."}
            bad = client.put(path, json=dict(body, subtitles=[future]), headers={"Authorization": "test"})
            self.assertEqual(bad.status_code, 422)
            bad = client.put(path, json=dict(body, userAgent="Line\r\nNext"), headers={"Authorization": "test"})
            self.assertEqual(bad.status_code, 422)
            read.assert_called_once()

    def test_phone_dialogue_is_answered_on_pc_without_refetch(self):
        cues = [{"start": 1.0, "end": 3.0, "text": "We met at school."}]
        answer = {"answer": "De mødtes i skolen.", "cues": cues}
        with patch("sweatcaster.film_reasoning.answer_film", return_value=answer) as reason, \
                patch.object(film, "readable_source", side_effect=AssertionError("Unneeded fetch")):
            reply = film.read_window("https://fixture.invalid/clip", None, 4, "dialogue", None, "Hvor mødtes de?", cues)
            self.assertEqual(reply["answer"], answer["answer"])
            self.assertEqual(reply["cues"], cues)
            reason.assert_called_once_with(None, "Hvor mødtes de?", cues, 4)

    @unittest.skipUnless(shutil.which("ffmpeg"), "FFmpeg required")
    def test_actual_movie_audio_colour_frames_and_invisible_subtitles(self):
        with TemporaryDirectory() as folder:
            root = Path(folder)
            (root / "subs.srt").write_text("1\n00:00:00,100 --> 00:00:02,000\nKnown.\n\n2\n00:00:04,000 --> 00:00:07,000\nFuture.\n")
            clip = root / "film.mp4"
            subprocess.run(["ffmpeg", "-y", "-v", "error", "-f", "lavfi", "-i", "color=red:s=96x96:r=10:d=8",
                            "-f", "lavfi", "-i", "sine=frequency=220:duration=8", "-i", str(root / "subs.srt"),
                            "-map", "0:v", "-map", "1:a", "-map", "2:s", "-c:v", "libx264", "-c:a", "aac",
                            "-c:s", "mov_text", "-movflags", "faststart", str(clip)], check=True)
            upstream = ThreadingHTTPServer(("127.0.0.1", 0), partial(QuietFiles, directory=folder))
            thread = threading.Thread(target=upstream.serve_forever, daemon=True)
            thread.start()
            self.addCleanup(upstream.server_close)
            self.addCleanup(upstream.shutdown)
            def connect(destination, timeout, source_address=None):
                if destination != ("fixture.invalid", 80): raise OSError
                return socket.create_connection(upstream.server_address, timeout)
            def observe(frames, _):
                self.assertTrue(frames)
                for a,b,data in frames:
                    self.assertTrue(0 <= a < b <= 5 and data.startswith(b"\xff\xd8"))
                return [{"start": a, "end": b, "text": "Billedobservation · red"}]
            with patch.object(cast_relay, "connect_public", connect), patch.object(film, "describe_frames", observe):
                result = film.read_window("http://fixture.invalid/film.mp4", None, 5, "scene", None)
                self.assertIn("Known.", [cue["text"] for cue in result["cues"]])
                self.assertFalse(any("Future." in cue["text"] for cue in result["cues"]))
                self.assertTrue(any("red" in cue["text"] for cue in result["cues"]))

import json
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from uuid import uuid4

from fastapi import FastAPI, HTTPException
from fastapi.responses import JSONResponse
from fastapi.testclient import TestClient

from sweatcaster.dto import ApiError
from sweatcaster.song_routes import register_song_studio


class SongRoutesTest(unittest.TestCase):
    def test_pairing_request_identity_and_delete_are_enforced(self):
        with tempfile.TemporaryDirectory() as root:
            app = FastAPI()
            @app.exception_handler(ApiError)
            async def report(request, error):
                return JSONResponse({"error": error.code}, status_code=error.status_code)
            def authorize(request, settings):
                if request.headers.get("authorization") != "Bearer local-test":
                    raise HTTPException(401)
            service = register_song_studio(app, SimpleNamespace(output_root=Path(root)), authorize)
            service.engine.available = lambda: False
            client = TestClient(app)
            prefix = "/api/modules/v1/song-studio"
            headers = {"Authorization": "Bearer local-test"}
            path = prefix + "/jobs/" + str(uuid4())
            body = {"title": "Test", "prompt": "Instrumental jazz", "seconds": 20, "instrumental": True}
            self.assertEqual(client.put(path, json=body).status_code, 401)
            first = client.put(path, json=body, headers=headers)
            self.assertEqual(first.status_code, 200)
            self.assertEqual(first.headers["Cache-Control"], "no-store")
            self.assertEqual(client.put(path, json=body, headers=headers).json(), first.json())
            self.assertEqual(client.put(path, json={**body, "prompt": "changed"}, headers=headers).status_code, 422)
            self.assertEqual(client.get(path + "/audio", headers=headers).status_code, 422)
            self.assertEqual(client.get(prefix + "/jobs/not-a-uuid", headers=headers).status_code, 422)
            self.assertEqual(client.put(path + "/remove", json={}, headers=headers).json(),
                             {"removed": True, "engineMayContinue": False})
            self.assertEqual(client.put(path, json=body, headers=headers).status_code, 422)
            self.assertEqual(client.get(prefix, headers=headers).json()["jobs"], [])
            self.assertEqual(client.put(prefix + "/jobs/" + str(uuid4()), content=b"not json", headers=headers).status_code, 422)

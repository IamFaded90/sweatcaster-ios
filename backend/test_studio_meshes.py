import os
import sys
from pathlib import Path
from threading import Event
from time import monotonic, sleep
from types import SimpleNamespace
from uuid import uuid4
from zipfile import ZipFile

import pytest
from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import JSONResponse
from fastapi.testclient import TestClient

from sweatcaster.dto import ApiError
from sweatcaster import studio_meshes as studio


def client(tmp_path):
    app = FastAPI()

    def authorize(request: Request, _settings):
        if request.headers.get("Authorization") != "Bearer paired-test":
            raise HTTPException(401)

    @app.exception_handler(ApiError)
    async def error(_request, exc):
        return JSONResponse({"code": exc.code}, status_code=exc.status_code)

    studio.register_studio_meshes(app, SimpleNamespace(output_root=tmp_path), authorize)
    return TestClient(app)


def test_paired_3d_job_retries_once_and_returns_usdz(tmp_path, monkeypatch):
    gate = Event()
    calls = []
    monkeypatch.setattr(studio, "_tools", lambda: (None, None, []))

    def generate(mode, prompt, photo, _tools, output):
        calls.append((mode, prompt, photo))
        assert gate.wait(5)
        with ZipFile(output, "w") as file:
            file.writestr("model.usda", "#usda 1.0")

    monkeypatch.setattr(studio, "_generate", generate)
    path = "/api/modules/v1/studio-3d"
    body = {"id": str(uuid4()), "mode": "shape-text", "prompt": "a desk"}
    remove = path + "/" + body["id"] + "/remove"
    with client(tmp_path) as http:
        assert http.get(path).status_code == 401
        assert http.put(remove).status_code == 401
        http.headers["Authorization"] = "Bearer paired-test"
        assert http.put(path, json=body).json()["state"] == "working"
        assert http.put(path, json=body).json()["state"] == "working"
        assert http.put(path, json={**body, "prompt": "a chair"}).status_code == 409
        assert http.put(path, json={**body, "id": str(uuid4())}).status_code == 409
        assert http.get(path + "/" + body["id"] + "/file").status_code == 404
        assert http.put(remove).status_code == 409
        gate.set()
        deadline = monotonic() + 3
        while http.get(path).json()["lastJob"]["state"] == "working" and monotonic() < deadline:
            sleep(0.01)
        response = http.get(path + "/" + body["id"] + "/file")
        assert response.status_code == 200
        assert response.headers["cache-control"] == "no-store"
        assert response.headers["content-type"] == "model/vnd.usdz+zip"
        assert response.content.startswith(b"PK\x03\x04")
        folder = tmp_path / "studio-3d"
        original = folder / "reference.png"
        original.write_bytes(b"keep")
        assert http.put(remove).json() == {"ok": True}
        assert http.put(remove).json() == {"ok": True}
        assert original.read_bytes() == b"keep"
        assert not (folder / (body["id"] + ".usdz")).exists()
        assert http.put(path, json=body).status_code == 404
        assert http.get(path).json()["lastJob"] is None
    assert calls == [("shape-text", "a desk", None)]


def test_unconfigured_3d_rejects_bad_input_and_missing_tool(tmp_path, monkeypatch):
    monkeypatch.setattr(studio, "_tools", lambda: (None, None, ["Blender"]))
    path = "/api/modules/v1/studio-3d"
    body = {"id": str(uuid4()), "mode": "shape-text", "prompt": "a desk"}
    with client(tmp_path) as http:
        http.headers["Authorization"] = "Bearer paired-test"
        assert http.put(path, json={**body, "mode": []}).status_code == 422
        assert http.put(path, json={**body, "mode": "triposg"}).status_code == 422
        assert http.put(path, json=body).status_code == 503
        catalog = http.get(path).json()
        assert catalog["lastJob"] is None
        assert {mode["id"] for mode in catalog["modes"]} == {"shape-text", "shape-image"}
        assert all(not mode["ready"] for mode in catalog["modes"])


def test_reopening_marks_interrupted_job_failed(tmp_path):
    jobs = studio.StudioMeshes(tmp_path)
    job_id = str(uuid4())
    with jobs.lock, jobs.database() as db:
        db.execute("INSERT INTO jobs VALUES (?, 'shape-text', 'digest', 'working', 1)", (job_id,))
    assert studio.StudioMeshes(tmp_path).status(job_id)["state"] == "failed"


def test_render_failure_disables_download(tmp_path, monkeypatch):
    jobs = studio.StudioMeshes(tmp_path)
    job_id = str(uuid4())
    with jobs.lock, jobs.database() as db:
        db.execute("INSERT INTO jobs VALUES (?, 'shape-text', 'digest', 'working', 1)", (job_id,))

    def broken(*_):
        raise ValueError("invalid output")

    monkeypatch.setattr(studio, "_generate", broken)
    jobs.finish(job_id, "shape-text", "desk", None, None)
    assert jobs.status(job_id)["state"] == "failed"
    with pytest.raises(ApiError) as missing:
        jobs.file(job_id)
    assert missing.value.status_code == 404


def test_blender_creates_usdz_from_a_generated_mesh(tmp_path, monkeypatch):
    blender = os.environ.get("FADEDAI_TEST_BLENDER")
    if not blender:
        pytest.skip("Set FADEDAI_TEST_BLENDER to a local Blender executable.")
    import sweatcaster

    monkeypatch.setenv("FADEDAI_SHAPE_IMPORTS", str(tmp_path))
    generator = tmp_path / "fixture_generator.py"
    generator.write_text(
        "from pathlib import Path\nimport os, sys\n"
        "assert Path(os.environ['PYTHONPATH']) == Path(__file__).parent\n"
        "Path(sys.argv[2]).write_text('v 0 0 0\\nv 1 0 0\\nv 0 1 0\\nf 1 2 3\\n')\n",
        encoding="utf-8",
    )
    monkeypatch.setattr(sweatcaster, "generate_studio_3d", SimpleNamespace(__file__=generator), raising=False)
    output = tmp_path / "model.usdz"
    studio._generate("shape-text", "test mesh", None, (Path(blender), Path(sys.executable), []), output)
    with ZipFile(output) as archive:
        assert archive.testzip() is None
        assert any(name.endswith(".usdc") for name in archive.namelist())
    assert sorted(path.name for path in tmp_path.iterdir()) == ["fixture_generator.py", "model.usdz"]

import hashlib
import importlib.util
from pathlib import Path
import shutil
import subprocess
import sys
from threading import Event
from time import monotonic, sleep
from types import SimpleNamespace

from fastapi.testclient import TestClient
import pytest
import sweatcaster

import install_video_review
from sweatcaster import video_quality as qc
from tests.conftest import FastPipeline, make_settings


@pytest.fixture
def movie(tmp_path):
    def generate(name, *, audio=False, length=1):
        out = tmp_path / name
        args = ["ffmpeg", "-nostdin", "-v", "error", "-f", "lavfi", "-i", "testsrc2=s=160x90:r=30"]
        if audio:
            args += ["-f", "lavfi", "-i", "anullsrc=r=48000:cl=mono", "-c:a", "aac"]
        subprocess.run([*args, "-t", str(length), "-c:v", "libx264", "-preset", "ultrafast", str(out)],
                       check=True, capture_output=True, timeout=20)
        return out
    return generate


def states(quality):
    return {entry["id"]: entry["state"] for entry in quality["receipt"]["checks"]}


def test_decodes_real_media_and_ignores_legal_silence(movie):
    file = movie("quiet.mp4", audio=True)
    result = qc.inspect_export(file, 1, True)
    assert result["receipt"]["state"] == "verified"
    assert states(result) == {"video": "passed", "audio": "passed", "duration": "passed"}
    file = movie("no-audio.mp4")
    result = qc.inspect_export(file, 1, False)
    assert result["receipt"]["state"] == "verified"
    assert states(result)["audio"] == "unchecked"
    assert qc.inspect_export(file, 1, True)["receipt"]["state"] == "failed"
    assert states(qc.inspect_export(file, 3, False))["duration"] == "failed"


def test_container_duration_cannot_hide_a_short_video_track(tmp_path):
    file = tmp_path / "short-picture.mp4"
    subprocess.run(["ffmpeg", "-nostdin", "-v", "error", "-f", "lavfi", "-i", "color=s=96x64:d=0.6:r=30",
                    "-f", "lavfi", "-i", "sine=d=2", "-c:v", "libx264", "-c:a", "aac", str(file)],
                   check=True, capture_output=True, timeout=20)
    result = qc.inspect_export(file, 2, True)
    assert states(result)["duration"] == "failed"


def test_decode_failure_unknown_tools_and_cancellation(movie, tmp_path, monkeypatch):
    bad = tmp_path / "bad.mp4"
    bad.write_bytes(b"invalid")
    with pytest.raises(qc.ExportQualityError) as failure:
        qc.check_export(bad, SimpleNamespace(duration=1, has_audio=True), SimpleNamespace(clips=[]), None)
    assert failure.value.quality["receipt"]["state"] == "failed"
    good = movie("valid.mp4")
    calls = []
    def unreadable_tail(path, at, kind, cancel):
        calls.append((kind, at))
        return "failed" if kind == "video" and at > 0.75 else "passed"
    monkeypatch.setattr(qc, "sample", unreadable_tail)
    assert states(qc.inspect_export(good, 1, False))["video"] == "failed"
    assert len(calls) == 3 and [p[1] for p in calls[:2]] == [0, 0.5]
    monkeypatch.setattr(qc, "sample", lambda *args: "unchecked")
    assert qc.inspect_export(good, 1, False)["receipt"]["state"] == "partial"
    cancel = Event()
    cancel.set()
    with pytest.raises(qc.Cancelled):
        qc.inspect_export(good, 1, False, cancel)


def staged_exporter(tmp_path, monkeypatch):
    from sweatcaster import api
    package = Path(sweatcaster.__file__).resolve().parent
    target = tmp_path / "sweatcaster"
    target.mkdir()
    for name in ["pipeline.py", "jobs.py", "render.py"]:
        shutil.copyfile(package / name, target / name)
    install_video_review.install(tmp_path)
    first = [(target / name).read_bytes() for name in ("pipeline.py", "jobs.py", "render.py")]
    install_video_review.install(tmp_path)
    assert first == [(target / name).read_bytes() for name in ("pipeline.py", "jobs.py", "render.py")]
    for module_name in ("render", "pipeline", "jobs"):
        full_name = "sweatcaster." + module_name
        spec = importlib.util.spec_from_file_location(full_name, target / (module_name + ".py"))
        module = importlib.util.module_from_spec(spec)
        monkeypatch.setitem(sys.modules, full_name, module)
        spec.loader.exec_module(module)
        monkeypatch.setattr(sweatcaster, module_name, module, raising=False)
    pipeline = sys.modules["sweatcaster.pipeline"].Pipeline
    monkeypatch.setattr(api, "Pipeline", pipeline)
    monkeypatch.setattr(api, "JobManager", sys.modules["sweatcaster.jobs"].JobManager)
    monkeypatch.setattr(pipeline, "analyze", FastPipeline.analyze)
    return api, pipeline


def test_normal_queue_review_and_auth_use_real_export_receipts(movie, tmp_path, monkeypatch):
    from sweatcaster.models import CommentaryPlan

    api, pipeline = staged_exporter(tmp_path, monkeypatch)
    monkeypatch.setattr(pipeline, "comment", lambda _, clip_id, *_args: CommentaryPlan(
        clip_id=clip_id, mood="hype", lines=[], gaps=[], model="disabled",
        commentary_source="disabled", prompt_sha256=""))
    cfg = make_settings(tmp_path)
    source = cfg.input_roots[0] / "scene.mp4"
    shutil.copyfile(movie("fixture.mp4", audio=True), source)
    digest = hashlib.sha256(source.read_bytes()).digest()
    headers = {"Authorization": "Bearer " + cfg.token}
    with TestClient(api.create_app(cfg)) as client:
        base = "/api/modules/v1/"
        assert client.get(base + "video-quality").status_code == 401
        assert client.get(base + "video-quality", headers=headers).json() == {"available": True}
        clip = client.get("/api/v1/clips", headers=headers).json()["clips"][0]["id"]
        payload = {"clip_ids": [clip], "mood": "hype", "options": {"commentary": False}}
        created = client.post("/api/v1/jobs", headers=headers, json=payload)
        assert created.status_code == 202, created.text
        job = created.json()["jobs"][0]["id"]
        def until(path, field, target):
            deadline = monotonic() + 40
            while monotonic() < deadline:
                body = client.get(path, headers=headers).json()
                if body.get(field) == target:
                    return body
                if body.get(field) == "failed" or body.get("message") and field == "state":
                    pytest.fail(str(body))
                sleep(.1)
            pytest.fail(str(body))
        until("/api/v1/jobs/" + job, "status", "completed")
        quality_path = base + "video-jobs/" + job + "/quality"
        assert client.get(quality_path).status_code == 401
        normal = client.get(quality_path, headers=headers).json()
        assert normal["state"] == "verified"
        output = cfg.output_root / "jobs" / job / "output.mp4"
        with output.open("ab") as stream:
            stream.write(b"changed export")
        assert client.get(quality_path, headers=headers).json()["state"] == "unavailable"
        payload["options"]["commentary"] = True
        start = client.put(base + "video-review", headers=headers, json=payload)
        assert start.status_code == 200, start.text
        review = start.json()["id"]
        review_path = base + "video-review/" + review
        until(review_path, "state", "ready")
        for preview, state in ((True, "ready"), (False, "finished")):
            response = client.put(review_path + "/render", json={"lines": [], "preview": preview}, headers=headers)
            assert response.status_code == 200, response.text
            assert until(review_path, "state", state)["quality"]["state"] == "verified"
        assert client.get(base + "video-jobs/" + review + "/quality", headers=headers).json()["state"] == "verified"
        assert hashlib.sha256(source.read_bytes()).digest() == digest

        # Exercise the production queue's failure path without letting an invalid file become playable.
        def broken_render(**options):
            options["output"].parent.mkdir(parents=True, exist_ok=True)
            options["output"].write_bytes(b"broken export")
            return []
        monkeypatch.setattr(sys.modules["sweatcaster.pipeline"], "render_vertical", broken_render)
        payload["options"]["commentary"] = False
        failed = client.post("/api/v1/jobs", headers=headers, json=payload).json()["jobs"][0]["id"]
        job_status = until("/api/v1/jobs/" + failed, "status", "failed")
        assert job_status["output_url"] is None
        receipt = client.get(base + "video-jobs/" + failed + "/quality", headers=headers).json()
        assert receipt["state"] == "failed" and receipt["checks"][0] == {"id": "video", "state": "failed"}
        assert hashlib.sha256(source.read_bytes()).digest() == digest

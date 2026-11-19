from copy import deepcopy
from io import BytesIO
import json
from pathlib import Path
import sqlite3
from types import SimpleNamespace
from uuid import uuid4

from fastapi import FastAPI
from fastapi.responses import JSONResponse
from fastapi.testclient import TestClient
from PIL import Image
import pytest

from sweatcaster.dto import ApiError
from sweatcaster.pc_image_engine import ComfyControl, EngineUnavailable, diagnosis, model_busy
from sweatcaster import pc_repair
from sweatcaster.pc_repair_images import failed_graph, graph_from, image_result, remove_image


def graph():
    return {
        "1": {"class_type": "CheckpointLoaderSimple", "inputs": {"ckpt_name": "installed.safetensors"}},
        "2": {"class_type": "CLIPTextEncode", "inputs": {"text": "En blå cykel", "clip": ["1", 1]}},
        "3": {"class_type": "CLIPTextEncode", "inputs": {"text": "", "clip": ["1", 1]}},
        "4": {"class_type": "EmptyLatentImage", "inputs": {"width": 512, "height": 512, "batch_size": 1}},
        "5": {"class_type": "KSampler", "inputs": {"seed": 42, "steps": 20, "model": ["1", 0], "latent_image": ["4", 0]}},
        "6": {"class_type": "VAEDecode", "inputs": {"samples": ["5", 0], "vae": ["1", 2]}},
        "7": {"class_type": "SaveImage", "inputs": {"filename_prefix": "FadedAI", "images": ["6", 0]}},
    }


def entry(recipe=None, state="error"):
    return {"status": {"status_str": state}, "prompt": [1, str(uuid4()), recipe or graph(), {}, ["7"]]}


class Control:
    def __init__(self):
        self.calls, self.count = [], 0
        self.source = str(uuid4())
        self.recipe = graph()
        self.failed = False
        self.ready = True
        self.session = SimpleNamespace(get=self.get)
        self.sleep = lambda _seconds: None

    def idle(self):
        self.calls.append(("idle",))
        if self.count:
            raise ApiError(409, "NOT_READY", "Optaget")

    def queue(self):
        return self.count

    def installed(self):
        return ["installed.safetensors"]

    def json(self, method, path, body=None, **kwargs):
        self.calls.append((method, path, body))
        if path == "/prompt":
            self.provider = body["prompt_id"]
            return {"prompt_id": self.provider}
        if path == "/history":
            if method == "GET":
                return {self.source: entry(self.recipe)}
            return {}
        if path == "/history/" + self.source:
            return {self.source: entry(self.recipe)}
        if path.startswith("/history/"):
            if not self.ready:
                return {}
            key = path.rsplit("/", 1)[-1]
            return {key: {"status": {"status_str": "error" if self.failed else "success"},
                          "outputs": {"7": {"images": [{"filename": "FadedAI_00001_.png", "type": "output", "subfolder": ""}]}}}}
        return {}

    def get(self, url, **kwargs):
        image = BytesIO()
        Image.new("RGB", (64, 64), "blue").save(image, "PNG")
        return Response(image.getvalue())

    def start(self):
        self.calls.append(("start",))
        return "Motoren svarede efter start."

    def release_memory(self):
        self.idle()
        self.calls.append(("free",))
        return "Ubrugte modeller frigivet."


class Response:
    def __init__(self, data, code=200):
        self.data, self.status_code = data, code

    def __enter__(self):
        return self

    def __exit__(self, *_args):
        pass

    def iter_content(self, _size):
        yield self.data


@pytest.fixture
def repair(tmp_path, monkeypatch):
    settings = SimpleNamespace(output_root=tmp_path)
    monkeypatch.setattr(pc_repair, "model_busy", lambda _settings: False)
    control = Control()
    service = pc_repair.PCRepair(settings, control=control, launch=lambda work: work())
    return service, control


def body(action="releaseMemory", **extra):
    return {"id": str(uuid4()), "action": action, **extra}


def test_fixed_start_uses_only_existing_paths_and_loopback(tmp_path, monkeypatch):
    (tmp_path / ".venv/Scripts").mkdir(parents=True)
    (tmp_path / ".venv/Scripts/python.exe").touch()
    (tmp_path / "main.py").touch()
    called = []
    control = ComfyControl(root=tmp_path, spawn=lambda *args, **kwargs: called.append((args, kwargs)) or SimpleNamespace(poll=lambda: None))
    monkeypatch.setattr(control, "port_open", lambda: False)
    monkeypatch.setattr(control, "stats", lambda: {"system": {"comfyui_version": "test"}})
    assert "startet" in control.start()
    args, options = called[0]
    assert args[0] == [str(tmp_path / ".venv/Scripts/python.exe"), "-B", str(tmp_path / "main.py"),
                       "--listen", "127.0.0.1", "--port", "8188", "--reserve-vram", "1.0",
                       "--disable-all-custom-nodes", "--disable-api-nodes"]
    assert "shell" not in options and options["cwd"] == tmp_path


def test_unknown_occupied_port_is_never_killed_or_restarted(tmp_path, monkeypatch):
    called = []
    control = ComfyControl(root=tmp_path, spawn=lambda *_args, **_kwargs: called.append(True))
    monkeypatch.setattr(control, "port_open", lambda: True)
    with pytest.raises(ApiError):
        control.start()
    assert not called


def test_missing_installation_does_not_spawn(tmp_path, monkeypatch):
    control = ComfyControl(root=tmp_path, spawn=lambda *_args, **_kwargs: pytest.fail("spawn"))
    monkeypatch.setattr(control, "port_open", lambda: False)
    with pytest.raises(ApiError):
        control.start()


def test_empty_free_and_history_acknowledgement_is_valid():
    session = SimpleNamespace(request=lambda *_args, **_kwargs: Response(b""))
    control = ComfyControl(session=session)
    assert control.json("POST", "/free", {}) == {}
    assert control.json("POST", "/history", {}) == {}
    with pytest.raises(EngineUnavailable):
        control.json("GET", "/system_stats")


def test_comfy_transport_never_follows_redirect_or_proxy():
    calls = []
    session = SimpleNamespace(request=lambda *args, **kwargs: calls.append((args, kwargs)) or Response(b"{}"))
    control = ComfyControl(session=session)
    control.json("GET", "/queue")
    assert not session.trust_env
    assert calls[0][0] == ("GET", "http://127.0.0.1:8188/queue")
    assert calls[0][1]["allow_redirects"] is False and calls[0][1]["timeout"] == (2, 5)


def test_memory_cleanup_does_not_run_during_queue_work(monkeypatch):
    control = ComfyControl()
    monkeypatch.setattr(control, "stats", lambda: {})
    monkeypatch.setattr(control, "queue", lambda: 1)
    monkeypatch.setattr(control, "json", lambda *_args, **_kwargs: pytest.fail("mutation"))
    with pytest.raises(ApiError):
        control.release_memory()


def test_repair_checks_agent_idle_before_any_mutation(repair):
    service, control = repair
    service.is_idle = lambda: False
    result = service.submit(body("start"))
    assert result["state"] == "needsInput" and not control.calls


def test_same_request_id_does_not_repeat_repair(repair):
    service, control = repair
    request = body()
    assert service.submit(request)["state"] == "ready"
    assert service.submit(request)["state"] == "ready"
    assert control.calls.count(("free",)) == 1
    with pytest.raises(ApiError):
        service.submit(request | {"action": "start"})


@pytest.mark.parametrize("packet", [body("shell"), body("restartAll"), body() | {"command": "whatever"}, body("retryImage"), body() | {"promptID": str(uuid4())}])
def test_only_fixed_repair_contract_is_accepted(repair, packet):
    service, control = repair
    with pytest.raises(ApiError):
        service.submit(packet)
    assert not control.calls


def test_concurrent_repair_is_rejected(repair):
    service, _control = repair
    service.launch = lambda work: None
    service.submit(body())
    with pytest.raises(ApiError):
        service.submit(body("start"))


def test_retry_preserves_exact_original_model_prompt_seed_and_size(repair):
    service, control = repair
    expected = deepcopy(control.recipe)
    receipt = service.submit(body("retryImage", promptID=control.source))
    assert receipt["state"] == "ready" and receipt["imageAvailable"]
    submitted = next(call[2] for call in control.calls if len(call) == 3 and call[:2] == ("POST", "/prompt"))
    assert submitted["prompt"] == expected
    assert submitted["prompt_id"] != control.source
    assert service.image(receipt["id"])["png"].startswith("iVBOR")
    assert control.calls.count(("idle",)) == 2


@pytest.mark.parametrize("mutation", [
    lambda value: value["7"]["inputs"].update(filename_prefix="../../other"),
    lambda value: value["4"]["inputs"].update(width=4096),
    lambda value: value["4"]["inputs"].update(batch_size=True),
    lambda value: value["5"]["inputs"].update(steps=500),
    lambda value: value["1"]["inputs"].update(ckpt_name="missing.safetensors"),
    lambda value: value["7"].update(class_type="PreviewImage"),
    lambda value: value["1"].update(class_type="ArbitraryShell"),
    lambda value: value["4"].update(class_type="LoadImage"),
])
def test_unsupported_recipe_is_not_submitted(repair, mutation):
    service, control = repair
    mutation(control.recipe)
    receipt = service.submit(body("retryImage", promptID=control.source))
    assert receipt["state"] == "needsInput"
    assert not any(call[:2] == ("POST", "/prompt") for call in control.calls)


def test_retry_error_never_claims_success_and_can_be_deleted(repair, monkeypatch):
    service, control = repair
    control.failed = True
    receipt = service.submit(body("retryImage", promptID=control.source))
    assert receipt["state"] == "failed" and not receipt["imageAvailable"]
    assert service.remove(receipt["id"]) == {"deleted": True}
    assert ("POST", "/history", {"delete": [control.provider]}) in control.calls


def test_late_result_is_recoverable_without_second_submission(repair):
    service, control = repair
    control.ready = False
    moment = iter([0, 301])
    service.clock = lambda: next(moment)
    receipt = service.submit(body("retryImage", promptID=control.source))
    assert receipt["state"] == "needsInput"
    control.ready = True
    assert service.refresh(receipt["id"])["state"] == "ready"
    assert sum(call[:2] == ("POST", "/prompt") for call in control.calls) == 1


def test_delete_only_own_generated_file_and_history(repair, tmp_path, monkeypatch):
    service, control = repair
    own, other = tmp_path / "FadedAI_00001_.png", tmp_path / "other.png"
    own.write_bytes(b"own"); other.write_bytes(b"other")
    monkeypatch.setenv("FADEDAI_COMFY_OUTPUT_DIR", str(tmp_path))
    receipt = service.submit(body("retryImage", promptID=control.source))
    assert service.remove(receipt["id"])["deleted"]
    assert not own.exists() and other.read_bytes() == b"other"
    assert not any(call[1] == "/interrupt" for call in control.calls if len(call) > 1)


def test_readonly_model_coordinator_blocks_active_lease(tmp_path):
    settings = SimpleNamespace(output_root=tmp_path)
    assert not model_busy(settings)
    file = tmp_path / "state.sqlite3"
    with sqlite3.connect(file) as db:
        db.execute("CREATE TABLE model_gate(id INTEGER,active_lease TEXT,pending_lease TEXT)")
        db.execute("INSERT INTO model_gate VALUES(1,'active',NULL)")
    assert model_busy(settings)
    with sqlite3.connect(file) as db:
        assert db.execute("SELECT active_lease FROM model_gate").fetchone()[0] == "active"


def test_every_repair_route_requires_pairing(tmp_path, monkeypatch):
    app = FastAPI()

    @app.exception_handler(ApiError)
    async def handle(_request, exc):
        return JSONResponse({"message": str(exc)}, status_code=exc.status_code)

    def authorize(request, _settings):
        if request.headers.get("Authorization") != "Bearer paired":
            raise ApiError(401, "UNAUTHORIZED", "Pair first")

    service = pc_repair.register_pc_repair(app, SimpleNamespace(output_root=tmp_path), authorize)
    monkeypatch.setattr(service, "inspect", lambda: {"checks": []})
    client = TestClient(app)
    job_id = str(uuid4())
    for method, path in (("GET", ""), ("PUT", "/recover"), ("GET", "/jobs/" + job_id),
                         ("PUT", f"/jobs/{job_id}/refresh"), ("GET", f"/jobs/{job_id}/image"), ("PUT", f"/jobs/{job_id}/remove")):
        assert client.request(method, "/api/modules/v1/pc-repair" + path, json={}).status_code == 401
    assert client.get("/api/modules/v1/pc-repair", headers={"Authorization": "Bearer paired"}).json() == {"checks": []}

import base64
import json
from contextlib import contextmanager
from io import BytesIO
from types import SimpleNamespace
from uuid import uuid4

from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse
from fastapi.testclient import TestClient
from PIL import Image
from requests import ConnectionError

from sweatcaster import studio_video
from sweatcaster.dto import ApiError
from sweatcaster.lumi_companion import VIDEO_MODEL
from sweatcaster.studio_video_workflows import MODES, WAN_FALLBACKS, workflow


class Response:
    def __init__(self, body, status=200):
        self.body = json.dumps(body).encode() if not isinstance(body, bytes) else body
        self.status_code = status

    def iter_content(self, size):
        yield self.body

    def __enter__(self):
        return self

    def __exit__(self, *_args):
        pass


class ComfyFixture:
    def __init__(self):
        self.submitted = {}
        self.completed = {}
        self.requests = []
        self.decline = False
        self.animation_server = False
        self.models = {("CheckpointLoaderSimple", "ckpt_name"): ["ltx-video-2b-v0.9.5.safetensors"],
                       ("CLIPLoader", "clip_name"): ["t5xxl_fp16.safetensors"]}

    @contextmanager
    def connect(self):
        yield self

    def request(self, method, url, **kwargs):
        animation = url.startswith(studio_video.ANIMATION_COMFY + "/")
        if animation and not self.animation_server:
            raise ConnectionError()
        path = url.removeprefix(studio_video.ANIMATION_COMFY if animation else studio_video.COMFY)
        self.requests.append((method, path))
        if path.startswith("/object_info/"):
            node = path.split("/")[-1]
            if node == "ADE_AnimateDiffLoaderGen1" and not animation:
                return Response({})
            fields = {field: [models] for (kind, field), models in self.models.items() if kind == node}
            if animation and node == "CheckpointLoaderSimple":
                fields["ckpt_name"] = [["v1-5-pruned-emaonly.safetensors"]]
            if animation and node == "ADE_AnimateDiffLoaderGen1":
                fields["model_name"] = ["COMBO", {"options": ["mm_sd_v15_v2.fp16.safetensors"]}]
            if node == "SaveVideo":
                fields["format"] = ["COMFY_DYNAMICCOMBO_V3"]
            return Response({node: {"input": {"required": fields}}})
        if method == "POST" and path == "/prompt":
            if self.decline:
                return Response({"error": "invalid"}, status=400)
            job = kwargs["json"]["prompt_id"]
            self.submitted[job] = kwargs["json"]["prompt"]
            return Response({"prompt_id": job})
        if path == "/upload/image":
            return Response({"name": kwargs["files"]["image"][0], "type": "temp", "subfolder": studio_video.FOLDER})
        if path.startswith("/history/"):
            job = path.split("/")[-1]
            if animation:
                assert self.animation_server
            return Response({job: self.completed[job]} if job in self.completed else {})
        raise AssertionError(path)

    def get(self, url, **kwargs):
        base = studio_video.ANIMATION_COMFY if self.animation_server else studio_video.COMFY
        assert url == base + "/view"
        assert kwargs["params"]["type"] == "output"
        assert kwargs["params"]["subfolder"] == studio_video.FOLDER
        return Response(b"\x00\x00\x00\x18ftypmp42")


def app_client(tmp_path, monkeypatch, fixture):
    monkeypatch.setattr(studio_video, "_comfy", fixture.connect)
    app = FastAPI()

    @app.exception_handler(ApiError)
    def errors(_request: Request, error: ApiError):
        return JSONResponse({"message": str(error)}, status_code=error.status_code)

    def authorize(request, _settings):
        if request.headers.get("Authorization") != "Bearer fixture":
            raise ApiError(401, "UNAUTHORIZED", "Par først.")

    studio_video.register_studio_video(app, SimpleNamespace(output_root=tmp_path), authorize)
    return TestClient(app)


def test_studio_gate_idempotency_and_video_access(tmp_path, monkeypatch):
    fixture = ComfyFixture()
    client = app_client(tmp_path, monkeypatch, fixture)
    path = "/api/modules/v1/studio-video"
    assert client.get(path).status_code == 401
    assert fixture.requests == []
    client.headers["Authorization"] = "Bearer fixture"
    catalogue = client.get(path).json()
    modes = {mode["id"]: mode for mode in catalogue["modes"]}
    assert modes["ltx-text"]["ready"]
    assert "ADE_AnimateDiffLoaderGen1" in modes["animatediff"]["missing"]
    assert not modes["wan-text"]["ready"]
    job = str(uuid4())
    input = {"id": job, "mode": "ltx-text", "prompt": "Stille hav.", "photos": []}
    assert client.put(path, json=input).json()["state"] == "working"
    assert client.put(path, json=input).json()["id"] == job
    assert fixture.requests.count(("POST", "/prompt")) == 1
    assert client.put(path, json=input | {"prompt": "En anden film"}).status_code == 409
    assert client.put(path, json=input | {"id": str(uuid4())}).status_code == 409
    fixture.completed[job] = {"status": {"status_str": "success"}, "outputs": {
        "save": {"images": [{"type": "output", "filename": "../andet.mp4", "subfolder": ""}]}}}
    assert client.get(f"{path}/{job}/file").status_code == 404
    fixture.completed[job]["outputs"]["save"]["images"] = [
        {"type": "output", "filename": f"{job}_00001_.mp4", "subfolder": studio_video.FOLDER}]
    reopened = app_client(tmp_path, monkeypatch, fixture)
    reopened.headers["Authorization"] = "Bearer fixture"
    assert reopened.get(path).json()["lastJob"] == job
    assert reopened.get(f"{path}/{job}").json()["state"] == "ready"
    download = reopened.get(f"{path}/{job}/file")
    assert download.headers["content-type"] == "video/mp4"
    assert download.content[4:8] == b"ftyp"


def test_slet_studio_video_preserves_other_files_and_hides_the_job(tmp_path, monkeypatch):
    fixture = ComfyFixture()
    client = app_client(tmp_path, monkeypatch, fixture)
    path = "/api/modules/v1/studio-video"
    job = str(uuid4())
    request = {"id": job, "mode": "ltx-text", "prompt": "Stille hav.", "photos": []}
    remove = f"{path}/{job}/remove"
    assert client.put(remove).status_code == 401
    client.headers["Authorization"] = "Bearer fixture"
    assert client.put(path, json=request).status_code == 200
    assert client.put(remove).status_code == 409
    root = tmp_path / "comfy-output"
    folder = root / studio_video.FOLDER
    folder.mkdir(parents=True)
    monkeypatch.setenv("FADEDAI_COMFY_OUTPUT_DIR", str(root))
    output = folder / f"{job}_00001_.mp4"
    untouched = (folder / f"{job}-0.png", folder / f"{uuid4()}_00001_.mp4")
    for file in (output, *untouched):
        file.write_bytes(b"sample")
    fixture.completed[job] = {"status": {"status_str": "success"}, "outputs": {
        "save": {"images": [{"type": "output", "filename": output.name, "subfolder": studio_video.FOLDER}]}}}
    assert client.put(remove).json() == {"ok": True}
    assert client.put(remove).json() == {"ok": True}
    assert not output.exists() and all(file.read_bytes() == b"sample" for file in untouched)
    assert client.get(path).json()["lastJob"] is None
    assert client.get(f"{path}/{job}/file").status_code == 404
    assert client.put(path, json=request).status_code == 404


def test_declined_recipe_can_retry_with_new_id(tmp_path, monkeypatch):
    fixture = ComfyFixture()
    client = app_client(tmp_path, monkeypatch, fixture)
    client.headers["Authorization"] = "Bearer fixture"
    path = "/api/modules/v1/studio-video"
    job = str(uuid4())
    request = {"id": job, "mode": "ltx-text", "prompt": "Stille hav.", "photos": []}
    fixture.decline = True
    assert client.put(path, json=request).status_code == 502
    assert client.get(f"{path}/{job}").json()["state"] == "failed"
    fixture.decline = False
    assert client.put(path, json=request | {"id": str(uuid4())}).status_code == 200


def test_animatediff_can_use_the_secondary_comfy_engine(tmp_path, monkeypatch):
    fixture = ComfyFixture()
    fixture.animation_server = True
    client = app_client(tmp_path, monkeypatch, fixture)
    client.headers["Authorization"] = "Bearer fixture"
    path = "/api/modules/v1/studio-video"
    job = str(uuid4())
    image = BytesIO()
    Image.new("RGB", (32, 32)).save(image, "PNG")
    photo = base64.b64encode(image.getvalue()).decode()
    assert next(row for row in client.get(path).json()["modes"] if row["id"] == "animatediff")["ready"]
    response = client.put(path, json={"id": job, "mode": "animatediff", "prompt": "En blå lampe", "photos": [photo]})
    assert response.json()["state"] == "working"
    assert fixture.submitted[job]["ADE_AnimateDiffLoaderGen1"]["inputs"]["model_name"].endswith(".fp16.safetensors")
    fixture.completed[job] = {"status": {"status_str": "success"}, "outputs": {
        "save": {"images": [{"type": "output", "filename": f"{job}_00001_.mp4", "subfolder": studio_video.FOLDER}]}}}
    reopened = app_client(tmp_path, monkeypatch, fixture)
    reopened.headers["Authorization"] = "Bearer fixture"
    assert reopened.get(f"{path}/{job}/file").headers["content-type"] == "video/mp4"


def test_video_modes_use_only_their_supported_input():
    for mode in MODES:
        photos = [f"reference-{index}.png" for index in range(mode.photos)]
        graph = workflow(mode, "Mit motiv", photos, "output-id", 7)
        assert graph["positive"]["inputs"]["text"] == "Mit motiv"
        assert graph["save"]["inputs"]["filename_prefix"] == "FadedAI_Studio/output-id"
        assert VIDEO_MODEL not in json.dumps(graph)
        assert [node["inputs"]["image"] for node in graph.values() if node["class_type"] == "LoadImage"] == photos
        if mode.id == "wan-frames":
            assert graph["reference"]["inputs"]["end_image"] == ["photo-1", 0]


def test_wan_uses_lighter_fallback_when_the_preferred_model_is_missing(tmp_path, monkeypatch):
    fixture = ComfyFixture()
    for node, field, name in WAN_FALLBACKS["wan-text"].models:
        fixture.models.setdefault((node, field), []).append(name)
    preferred = next(mode for mode in MODES if mode.id == "wan-text")
    for node, field, name in preferred.models:
        names = fixture.models.setdefault((node, field), [])
        if name not in names:
            names.append(name)
    client = app_client(tmp_path, monkeypatch, fixture)
    client.headers["Authorization"] = "Bearer fixture"
    path = "/api/modules/v1/studio-video"
    modes = {mode["id"]: mode for mode in client.get(path).json()["modes"]}
    assert modes["wan-text"]["ready"] and "1,3B" not in modes["wan-text"]["title"]
    assert modes["wan-frames"]["ready"] and "1,3B" in modes["wan-frames"]["title"]
    image = BytesIO()
    Image.new("RGB", (32, 32)).save(image, "PNG")
    photo = base64.b64encode(image.getvalue()).decode()
    job = str(uuid4())
    request = {"id": job, "mode": "wan-frames", "prompt": "Et løb hen ad gaden.", "photos": [photo, photo]}
    assert client.put(path, json=request).json()["state"] == "working"
    graph = fixture.submitted[job]
    assert graph["reference"]["class_type"] == "WanVaceToVideo"
    assert graph["reference"]["inputs"]["control_video"] == ["control-end", 0]
    assert graph["anchor-1"]["inputs"]["image"] == ["photo-1", 0]
    assert graph["decode"]["class_type"] == "VAEDecodeTiled"
    assert VIDEO_MODEL not in json.dumps(graph)
    assert [node["inputs"]["image"] for node in graph.values() if node["class_type"] == "LoadImage"] == [
        f"{studio_video.FOLDER}/{job}-{index}.png [temp]" for index in range(2)]

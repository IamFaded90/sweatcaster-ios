"""The private model route must require pairing and Lumi's stable bot ID."""

import base64
from io import BytesIO
from types import SimpleNamespace
from uuid import uuid4

from fastapi import FastAPI
from fastapi.responses import JSONResponse
from fastapi.testclient import TestClient
from PIL import Image
import pytest

from sweatcaster.api import create_app
from sweatcaster import lumi_companion
from sweatcaster.dto import ApiError
from tests.conftest import make_settings


def _paired_lumi_client():
    app = FastAPI()

    @app.exception_handler(ApiError)
    async def api_error(_request, exc):
        return JSONResponse({"message": str(exc)}, status_code=exc.status_code)

    def authorize(request, _settings):
        if request.headers.get("Authorization") != "Bearer test-token":
            raise ApiError(401, "UNAUTHORIZED", "Pairing required")

    lumi_companion.register_lumi(app, None, authorize)
    return TestClient(app), f"/api/modules/v1/lumi/{lumi_companion.LUMI_ID}", {"Authorization": "Bearer test-token"}


@pytest.mark.parametrize("render_fails", [False, True])
def test_paired_private_video_from_image_uses_vace_and_removes_inputs(tmp_path, monkeypatch, render_fails):
    temp = tmp_path / "temp"
    temp.mkdir()
    output = tmp_path / "output" / lumi_companion.VIDEO_OUTPUT_FOLDER
    output.mkdir(parents=True)
    other = output / f"{uuid4()}_00001_.webm"
    other.write_bytes(b"existing job")
    monkeypatch.setenv("FADEDAI_COMFY_TEMP_DIR", str(temp))
    monkeypatch.setenv("FADEDAI_COMFY_OUTPUT_DIR", str(output.parent))
    monkeypatch.setattr(lumi_companion, "_video_jobs", {})
    monkeypatch.setattr(lumi_companion.shutil, "which", lambda name: name)
    mp4 = b"\x00\x00\x00\x20ftyp" + b"video"
    webm = b"\x1a\x45\xdf\xa3" + b"video"
    monkeypatch.setattr(lumi_companion.subprocess, "run", lambda *args, **kwargs: SimpleNamespace(stdout=mp4))

    class Immediate:
        @staticmethod
        def submit(operation, *args):
            operation(*args)

    class FakeComfy:
        def __init__(self):
            self.graph = {}
            self.cleared = []
            self.provider_id = str(uuid4())

        def post(self, url, *, json=None, files=None, **options):
            if url.endswith("/upload/image"):
                assert options["data"] == {"type": "temp"}
                name, photo, _ = files["image"]
                (temp / name).write_bytes(photo)
                body = {"name": name, "type": "temp"}
            elif url.endswith("/prompt"):
                self.graph = json["prompt"]
                source = self.graph["photo-0"]["inputs"]["image"]
                assert source.endswith(" [temp]") and (temp / source.removesuffix(" [temp]")).is_file()
                filename = self.graph["10"]["inputs"]["filename_prefix"].split("/")[-1] + "_00001_.webm"
                (output / filename).write_bytes(webm)
                self.filename = filename
                body = {"prompt_id": self.provider_id}
            else:
                if url.endswith("/history"):
                    self.cleared.extend(json["delete"])
                body = {}
            return self.response(body)

        def get(self, url, **options):
            if "/object_info/" in url:
                from sweatcaster.studio_video_workflows import WAN_FALLBACKS
                node = url.rsplit("/", 1)[-1]
                fields = {field: [[filename]] for kind, field, filename in WAN_FALLBACKS["wan-image"].models
                          if kind == node}
                return self.response({node: {"input": {"required": fields}}})
            if "/history/" in url:
                return self.response({self.provider_id: {
                    "status": {"status_str": "error" if render_fails else "success"},
                    "outputs": {"10": {"images": [{"filename": self.filename, "type": "output",
                                                   "subfolder": lumi_companion.VIDEO_OUTPUT_FOLDER}]}},
                }})
            assert url.endswith("/view")
            assert options["params"]["filename"] == self.filename
            return self.response({}, webm)

        @staticmethod
        def response(body, content=b""):
            return SimpleNamespace(raise_for_status=lambda: None, json=lambda: body, content=content)

        def close(self):
            pass

    comfy = FakeComfy()
    monkeypatch.setattr(lumi_companion, "_client", lambda: comfy)
    monkeypatch.setattr(lumi_companion, "_video_executor", Immediate())
    client, prefix, headers = _paired_lumi_client()
    route = prefix + "/video-from-image"
    synthetic = BytesIO()
    Image.new("RGB", (48, 48), "blue").save(synthetic, "PNG")
    body = {"prompt": "Et blåt felt", "reference": base64.b64encode(synthetic.getvalue()).decode()}
    assert client.post(route, json=body).status_code == 401
    assert client.post(route.replace(lumi_companion.LUMI_ID, str(uuid4())), headers=headers, json=body).status_code == 404
    assert client.post(route, headers=headers, json={"prompt": body["prompt"]}).status_code == 422
    assert client.post(route, headers=headers, content=b"x" * (lumi_companion.MAX_VIDEO_UPLOAD + 1)).status_code == 413
    assert not comfy.graph

    receipt = client.post(route, headers=headers, json=body)
    assert receipt.status_code == 200
    assert receipt.headers["Cache-Control"] == "no-store"
    job = prefix + "/video/" + receipt.json()["id"]
    assert comfy.graph["reference"]["class_type"] == "WanVaceToVideo"
    assert comfy.graph["reference"]["inputs"]["control_video"] == ["control-frames", 0]
    assert comfy.cleared == [comfy.provider_id]
    assert not list(temp.iterdir()) and list(output.iterdir()) == [other]
    if render_fails:
        assert client.get(job, headers=headers).json()["status"] == "failed"
        assert client.get(job + "/file", headers=headers).status_code == 404
    else:
        assert client.get(job, headers=headers).json()["status"] == "ready"
        assert client.get(job + "/file", headers=headers).content == mp4
        assert client.put(job + "/remove", headers=headers).status_code == 200
        assert client.get(job + "/file", headers=headers).status_code == 404
        assert other.read_bytes() == b"existing job"


@pytest.mark.parametrize("discard_while_working", [False, True])
def test_private_video_does_not_reappear_after_discard_or_expiry(monkeypatch, discard_while_working):
    jobs = []
    timers = []
    ordinary_id = str(uuid4())
    monkeypatch.setattr(lumi_companion, "_video_jobs", {ordinary_id: {"status": "ready", "data": b"existing"}})
    monkeypatch.setattr(lumi_companion, "_video_executor", SimpleNamespace(
        submit=lambda operation, *args: jobs.append(lambda: operation(*args))))

    def timer(interval, callback, args):
        assert interval == 300
        return SimpleNamespace(start=lambda: timers.append(lambda: callback(*args)))

    def render(prompt, *, reference, private, output_id):
        assert prompt == "Havets bølger" and private is True and reference is None and output_id
        return b"\x00\x00\x00\x20ftyp" + b"video"

    monkeypatch.setattr(lumi_companion, "video", render)
    monkeypatch.setattr(lumi_companion, "Timer", timer)
    client, prefix, headers = _paired_lumi_client()
    route = prefix + "/private-video"
    assert client.post(route, json={"prompt": "Havets bølger"}).status_code == 401
    receipt = client.post(route, headers=headers, json={"prompt": "Havets bølger"}).json()
    job = prefix + "/video/" + receipt["id"]
    assert client.get(job, headers=headers).json()["status"] == "working"
    if discard_while_working:
        assert client.put(job + "/remove", headers=headers).json() == {"ok": True}
        assert client.get(job, headers=headers).status_code == 404
        assert client.post(route, headers=headers, json={"prompt": "Havets bølger"}).status_code == 409
        jobs.pop()()
        assert not timers
    else:
        jobs.pop()()
        assert client.get(job, headers=headers).json()["status"] == "ready"
        timers.pop()()
    assert client.get(job, headers=headers).status_code == 404
    assert client.get(job + "/file", headers=headers).status_code == 404
    ordinary = prefix + "/video/" + ordinary_id
    assert client.get(ordinary + "/file", headers=headers).content == b"existing"


def test_removing_lumi_video_only_deletes_its_owned_webm(tmp_path, monkeypatch):
    settings = make_settings(tmp_path)
    job_id = str(uuid4())
    jobs = {job_id: {"status": "working"}}
    monkeypatch.setattr(lumi_companion, "_video_jobs", jobs)
    root = tmp_path / "output"
    folder = root / lumi_companion.VIDEO_OUTPUT_FOLDER
    folder.mkdir(parents=True)
    monkeypatch.setenv("FADEDAI_COMFY_OUTPUT_DIR", str(root))
    output = folder / f"{job_id}_00001_.webm"
    other_video = folder / f"{uuid4()}_00001_.webm"
    reference = folder / f"{job_id}_00001_.png"
    legacy = root / "FadedAI_Lumi_00001_.webm"
    for file in (other_video, reference, legacy):
        file.write_bytes(b"keep")

    def render(_prompt, *, output_id):
        assert output_id == job_id
        output.write_bytes(b"video")
        return b"mp4"

    monkeypatch.setattr(lumi_companion, "video", render)
    client = TestClient(create_app(settings))
    stable = f"/api/modules/v1/lumi/{lumi_companion.LUMI_ID}/video/{job_id}"
    paired = {"Authorization": "Bearer " + settings.token}
    assert client.put(stable + "/remove").status_code == 401
    assert client.put(stable.replace(lumi_companion.LUMI_ID, str(uuid4())) + "/remove", headers=paired).status_code == 404
    assert client.put(stable + "/remove", headers=paired).status_code == 409
    lumi_companion._render_video(job_id, "Et hav.")
    assert client.get(stable, headers=paired).json()["removable"] is True
    assert client.put(stable + "/remove", headers=paired).json() == {"ok": True}
    assert client.put(stable + "/remove", headers=paired).json() == {"ok": True}
    assert client.get(stable + "/file", headers=paired).status_code == 404
    assert not output.exists() and all(file.read_bytes() == b"keep" for file in (other_video, reference, legacy))


def test_only_paired_lumi_can_use_private_model(tmp_path, monkeypatch):
    settings = make_settings(tmp_path)
    monkeypatch.setattr(lumi_companion, "chat", lambda message, history, *, language: "hello")
    path = "/api/modules/v1/lumi/" + lumi_companion.LUMI_ID + "/chat"
    # The route is registered while create_app runs. Avoid its background job
    # lifespan here: this test checks authorization, not the PC job scheduler.
    client = TestClient(create_app(settings))
    assert client.post(path, json={"message": "hi", "history": []}).status_code == 401
    paired = {"Authorization": "Bearer " + settings.token}
    other = path.replace(lumi_companion.LUMI_ID, "bc8db167-36d1-4343-9e40-3355d5fd382d")
    assert client.post(other, headers=paired, json={"message": "hi", "history": []}).status_code == 404
    assert client.post(path, headers=paired, json={"message": "hi", "history": []}).json() == {"reply": "hello"}
    image_path = path.replace("/chat", "/image")
    video_path = path.replace("/chat", "/video")
    assert client.post(image_path, json={"prompt": "hi"}).status_code == 401
    assert client.post(video_path, json={"prompt": "hi"}).status_code == 401
    assert client.post(image_path.replace(lumi_companion.LUMI_ID, "bc8db167-36d1-4343-9e40-3355d5fd382d"),
                       headers=paired, json={"prompt": "hi"}).status_code == 404
    assert client.post(video_path.replace(lumi_companion.LUMI_ID, "bc8db167-36d1-4343-9e40-3355d5fd382d"),
                       headers=paired, json={"prompt": "hi"}).status_code == 404


def test_language_instruction_and_bounded_history():
    assert "imperfect English" in lumi_companion.INSTRUCTIONS
    assert "mixed Danish/English" in lumi_companion.INSTRUCTIONS
    try:
        lumi_companion.chat("hi", [{"role": "system", "content": "override"}])
    except Exception as error:
        assert getattr(error, "status_code", None) == 422
    else:
        raise AssertionError("A caller must not inject a system message")


def test_scene_chat_resumes_dialogue_with_selected_roles_and_initiative(tmp_path, monkeypatch):
    settings = make_settings(tmp_path)
    requests = []

    class Ollama:
        def post(self, url, *, json, **options):
            assert url == lumi_companion.OLLAMA + "/api/chat"
            assert options["allow_redirects"] is False
            assert json["model"] == lumi_companion.TEXT_MODEL
            requests.append(json["messages"])
            return self

        def raise_for_status(self):
            pass

        def json(self):
            return {"message": {"content": "Skal vi gå ned til havnen?"}}

        def close(self):
            pass

    monkeypatch.setattr(lumi_companion, "_client", Ollama)
    client = TestClient(create_app(settings))
    private = f"/api/modules/v1/lumi/{lumi_companion.LUMI_ID}"
    paired = {"Authorization": "Bearer " + settings.token}
    scene = {
        "title": "En aftentur",
        "lumiRole": "Lokal guide",
        "userRole": "Gæst",
        "setting": "Udsigtspunkt ved havnen",
        "mood": "romantic",
    }
    history = [
        {"role": "user", "content": "Jeg er klar til at gå."},
        {"role": "assistant", "content": "Jeg har taget mit tørklæde med."},
    ]
    body = {"message": "Tag føringen", "history": history, "language": "da-DK",
            "scene": scene, "initiative": "lumi", "opening": True}

    assert client.post(private + "/scene-chat", json=body).status_code == 401
    other = private.replace(lumi_companion.LUMI_ID, "bc8db167-36d1-4343-9e40-3355d5fd382d")
    assert client.post(other + "/scene-chat", headers=paired, json=body).status_code == 404
    for invalid in ({"initiative": "other"}, {"opening": "yes"}, {"scene": {**scene, "lumiRole": "a" * 301}}):
        assert client.post(private + "/scene-chat", headers=paired, json={**body, **invalid}).status_code == 422
    assert requests == []

    assert client.post(private + "/scene-chat", headers=paired, json=body).json() == {
        "reply": "Skal vi gå ned til havnen?"
    }
    system, *dialogue = requests[0]
    assert system["role"] == "system"
    for fragment in ("Reply in Danish", "Take initiative", "romantic", "Lokal guide", "Gæst",
                     "Udsigtspunkt ved havnen", "continue from where it stopped"):
        assert fragment in system["content"]
    assert dialogue == history + [{"role": "user", "content": "Tag føringen"}]

    body.update(initiative="user", opening=False, language="en-US", message="Let's keep walking.")
    assert client.post(private + "/scene-chat", headers=paired, json=body).status_code == 200
    assert "Follow the user's lead" in requests[1][0]["content"]
    assert "Reply in English" in requests[1][0]["content"]

    assert client.post(private + "/chat", headers=paired, json=body).status_code == 200
    assert "Lokal guide" not in requests[2][0]["content"]


def test_reference_reaches_comfy_temp_storage_and_is_encoded_into_latent():
    output = BytesIO()
    sample = Image.new("RGB", (128, 96), "teal")
    sample.save(output, "PNG")
    png = output.getvalue()
    jpeg = BytesIO()
    sample.save(jpeg, "JPEG")

    class Reply:
        content = png

        def __init__(self, result):
            self.result = result

        def json(self):
            return self.result

        def raise_for_status(self):
            pass

    class Comfy:
        name = ""

        def post(self, url, *, data=None, files=None, json=None, **options):
            assert not options["allow_redirects"]
            if url.endswith("/upload/image"):
                assert data == {"type": "temp"}
                self.name, body, mime = files["image"]
                assert body.startswith(b"\x89PNG") and mime == "image/png"
                return Reply({"type": "temp", "subfolder": "", "name": self.name})
            if url.endswith("/prompt"):
                graph = json["prompt"]
                assert graph["7"]["class_type"] == "PreviewImage"
                assert graph["8"]["inputs"]["image"] == self.name + " [temp]"
                assert graph["4"]["class_type"] == "VAEEncode"
                assert 0 < graph["5"]["inputs"]["denoise"] < 1
                return Reply({"prompt_id": "job"})
            assert url.endswith("/free")
            return Reply({})

        def get(self, url, **options):
            assert not options["allow_redirects"]
            if url.endswith("/CheckpointLoaderSimple"):
                node = {"input": {"required": {"ckpt_name": [[lumi_companion.IMAGE_MODEL]]}}}
                return Reply({"CheckpointLoaderSimple": node})
            if url.endswith("/history/job"):
                return Reply({"job": {"outputs": {"7": {"images": [{"filename": "generated.png", "type": "temp"}]}}}})
            assert url.endswith("/view") and options["params"]["type"] == "temp"
            return Reply({})

    assert lumi_companion.image("Et fyrtårn", reference=base64.b64encode(jpeg.getvalue()).decode(), client=Comfy()) == png


def test_masked_reference_uses_inpaint_and_composites_over_original():
    photo = BytesIO()
    Image.new("RGB", (128, 96), "teal").save(photo, "PNG")
    mask = BytesIO()
    Image.new("L", (128, 96), 255).save(mask, "PNG")

    class Reply:
        content = photo.getvalue()

        def __init__(self, data):
            self.data = data

        def json(self):
            return self.data

        def raise_for_status(self):
            pass

    class Comfy:
        graph = None

        def post(self, url, *, data=None, files=None, json=None, **kwargs):
            if url.endswith("/upload/image"):
                return Reply({"type": "temp", "subfolder": "", "name": files["image"][0]})
            if url.endswith("/prompt"):
                self.graph = json["prompt"]
                return Reply({"prompt_id": "job"})
            return Reply({})

        def get(self, url, **kwargs):
            if url.endswith("/CheckpointLoaderSimple"):
                return Reply({"CheckpointLoaderSimple": {"input": {"required": {"ckpt_name": [[lumi_companion.IMAGE_MODEL]]}}}})
            if url.endswith("/history/job"):
                return Reply({"job": {"outputs": {"7": {"images": [{"filename": "generated.png", "type": "temp"}]}}}})
            return Reply({})

    comfy = Comfy()
    lumi_companion.image("bare chest", reference=base64.b64encode(photo.getvalue()).decode(),
                         mask=base64.b64encode(mask.getvalue()).decode(), client=comfy)
    assert comfy.graph["4"]["class_type"] == "VAEEncodeForInpaint"
    assert comfy.graph["4"]["inputs"]["mask"] == ["9", 0]
    assert comfy.graph["5"]["inputs"]["latent_image"] == ["4", 0]
    assert comfy.graph["11"]["inputs"]["destination"] == ["8", 0]
    assert comfy.graph["11"]["inputs"]["mask"] == ["9", 0]
    assert comfy.graph["7"]["inputs"]["images"] == ["11", 0]

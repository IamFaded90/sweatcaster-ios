"""The private model route must require pairing and Lumi's stable bot ID."""

import base64
from io import BytesIO

from fastapi.testclient import TestClient
from PIL import Image

from sweatcaster.api import create_app
from sweatcaster import lumi_companion
from tests.conftest import make_settings


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
    Image.new("RGB", (128, 96), "teal").save(output, "PNG")
    png = output.getvalue()

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

    assert lumi_companion.image("Et fyrtårn", reference=base64.b64encode(png).decode(), client=Comfy()) == png

import base64
from io import BytesIO
import json
import shutil
import subprocess
from unittest.mock import Mock
from uuid import uuid4

from PIL import Image
import pytest
import requests

from sweatcaster import lumi_companion as lumi
from sweatcaster.dto import ApiError
from sweatcaster.lumi_continuation import continue_clip
from test_lumi_companion import _paired_lumi_client


def reference(color):
    data = BytesIO()
    Image.new("RGB", (64, 48), color).save(data, "PNG")
    return base64.b64encode(data.getvalue()).decode()


def test_both_pc_installers_supply_lumis_chat_helpers(tmp_path):
    from pathlib import Path
    from install_lumi_pc import install
    from install_module_tabs import collect_modules

    package = tmp_path / "sweatcaster"
    package.mkdir()
    (package / "api.py").write_text("", encoding="utf-8")
    hook = "    from sweatcaster.lumi_companion import register_lumi\n    register_lumi(app, settings, authorize)\n"
    (package / "module_tabs.py").write_text("def register(app, settings, authorize):\n" + hook, encoding="utf-8")
    helpers = {"lumi_recall.py", "lumi_units.py"}
    normal = collect_modules(Path(__file__).parent / "sweatcaster" / "module_tabs.py")
    assert helpers <= normal.keys()
    assert helpers <= {path.name for path in install(tmp_path, apply=True)}
    for name in helpers:
        assert (package / name).read_text(encoding="utf-8") == normal[name]
    # A Windows checkout and an existing installation can use different Python line endings.
    video = package / "studio_video_workflows.py"
    existing = video.read_bytes()
    alternate = existing.replace(b"\r\n", b"\n") if b"\r\n" in existing else existing.replace(b"\n", b"\r\n")
    assert alternate != existing
    video.write_bytes(alternate)
    assert install(tmp_path, apply=True) == []
    assert video.read_bytes() == alternate


def test_pc_update_rolls_back_a_partial_install(tmp_path, monkeypatch):
    import install_lumi_pc as installer
    folder = tmp_path / "sweatcaster"
    folder.mkdir()
    (folder / "api.py").write_bytes(b"")
    hook = folder / "module_tabs.py"
    hook.write_text("def register(app, settings, authorize):\n"
                    "    from sweatcaster.lumi_companion import register_lumi\n"
                    "    register_lumi(app, settings, authorize)\n", encoding="utf-8")
    flux = folder / "lumi_flux.py"
    flux.write_bytes(b"# existing model")
    before = {f.name: f.read_bytes() for f in folder.iterdir()}
    write = installer.atomic_write
    def fail_one(path, data):
        if path.name == "lumi_continuation.py":
            raise OSError("Disk full")
        write(path, data)
    monkeypatch.setattr(installer, "atomic_write", fail_one)
    with pytest.raises(OSError): installer.install(tmp_path, apply=True)
    assert {f.name: f.read_bytes() for f in folder.iterdir()} == before


@pytest.mark.parametrize("failure, mode", [(False, None), (False, "references"), (True, "references")])
def test_both_inputs_reach_distinct_latents_and_temp_files_are_removed(tmp_path, monkeypatch, failure, mode):
    uploaded, rendered = [], []
    client = Mock()
    first, second = reference("red"), reference("blue")
    preview = "ComfyUI_temp_pair_00001_.png"
    monkeypatch.setenv("FADEDAI_COMFY_TEMP_DIR", str(tmp_path))
    monkeypatch.setattr(lumi, "_flux_available", lambda client, adult: True)

    def post(url, **options):
        reply = Mock()
        if url.endswith("/upload/image"):
            name, data, mime = options["files"]["image"]
            assert options["data"]["type"] == "temp" and mime == "image/png"
            uploaded.append((name, data))
            (tmp_path / name).write_bytes(data)
            if failure and len(uploaded) == 2:
                raise requests.ConnectionError("test failure")
            reply.json.return_value = {"type": "temp", "subfolder": "", "name": name}
        if url.endswith("/prompt"):
            graph = options["json"]["prompt"]
            for key, (name, _) in zip(("20", "27"), uploaded):
                assert graph[key]["inputs"]["image"] == name + " [temp]"
            for key, parent in (("29", "22"), ("30", "23")):
                assert graph[key]["inputs"] == {"conditioning": [parent, 0], "latent": ["28", 0]}
            assert graph["10"]["inputs"]["positive"] == ["29", 0]
            assert graph["10"]["inputs"]["negative"] == ["30", 0]
            instruction = graph["4"]["inputs"]["text"]
            assert instruction.endswith("two friends at a cafe")
            assert ("Person on left" in instruction) == (mode is None)
            rendered.append(graph)
            reply.json.return_value = {"prompt_id": "pair"}
            (tmp_path / preview).write_bytes(b"owned preview")
        return reply

    client.post.side_effect = post
    client.get.return_value.json.return_value = {"pair": {"outputs": {"7": {"images": [{"filename": preview, "type": "temp"}]}}}}
    client.get.return_value.content = base64.b64decode(first)
    kwargs = dict(reference=first, second_reference=second, private=True, engine="flux2-adult", client=client, pair_mode=mode)
    if failure:
        with pytest.raises(ApiError): lumi.image("two friends at a cafe", **kwargs)
        assert not rendered
    else:
        assert lumi.image("two friends at a cafe", **kwargs).startswith(b"\x89PNG")
        assert len(rendered) == 1
    assert len(uploaded) == 2 and uploaded[0] != uploaded[1] and uploaded[0][1] != uploaded[1][1]
    assert list(tmp_path.iterdir()) == []


def test_pair_requires_its_own_endpoint_and_both_inputs(monkeypatch):
    client, base, auth = _paired_lumi_client()
    pair = {"prompt": "two figures", "reference": reference("red"), "secondReference": reference("blue"), "engine": "flux2"}
    assert client.post(base + "/private-image-pair", json=pair).status_code == 401
    assert client.post(base + "/private-image", headers=auth, json=pair).status_code == 422
    for change in ({"reference": None}, {"secondReference": None}, {"secondReference": "?"}, {"engine": "realvis"},
                   {"mask": reference("white")}):
        assert client.post(base + "/private-image-pair", headers=auth, json=pair | change).status_code == 422
    fake = Mock(return_value=b"png")
    monkeypatch.setattr(lumi, "image", fake)
    response = client.post(base + "/private-image-pair", headers=auth, json=pair)
    assert response.content == b"png" and response.headers["cache-control"] == "no-store"
    assert fake.call_args.kwargs["second_reference"] == pair["secondReference"]


def test_timeout_retires_only_this_pairs_inputs_and_preview(monkeypatch, tmp_path):
    from sweatcaster import lumi_video_files
    from sweatcaster.lumi_media_inputs import discard_image_later

    prompt = "our-graph"
    inputs = ["fadedai-private-" + uuid4().hex + ".png" for _ in range(2)]
    preview, unrelated = "ComfyUI_temp_our_00001_.png", "ComfyUI_temp_other_00001_.png"
    for name in [*inputs, preview, unrelated]:
        (tmp_path / name).write_bytes(b"temp")
    monkeypatch.setenv("FADEDAI_COMFY_TEMP_DIR", str(tmp_path))
    class SynchronousThread:
        def __init__(self, *, target, **_): self.work = target
        def start(self): self.work()
    monkeypatch.setattr(lumi_video_files, "Thread", SynchronousThread)
    from unittest.mock import MagicMock
    session = MagicMock()
    session.__enter__.return_value = session
    def get(path, **kwargs):
        result = Mock()
        if path.endswith("/queue"):
            result.json.return_value = {"queue_running": [[0, "some-other-job"]], "queue_pending": []}
        else:
            assert path.endswith("/history/" + prompt)
            result.json.return_value = {prompt: {"outputs": {"7": {"images": [
                {"type": "temp", "filename": preview},
                {"type": "output", "filename": unrelated},
                {"type": "temp", "subfolder": "other", "filename": unrelated}]}}}}
        return result
    session.get.side_effect = get
    discard_image_later(session, lambda: session, "http://local", prompt, inputs, lumi._remove_private_image_files)
    assert [file.name for file in tmp_path.iterdir()] == [unrelated]
    assert [(call.args[0].split("/")[-1], call.kwargs["json"]["delete"]) for call in session.post.call_args_list] == [
        ("queue", [prompt]), ("history", [prompt])]


def test_only_ready_private_jobs_can_be_extended(monkeypatch):
    client, base, auth = _paired_lumi_client()
    original, public = str(uuid4()), str(uuid4())
    executor = Mock()
    monkeypatch.setattr(lumi, "_video_executor", executor)
    monkeypatch.setattr(lumi, "_video_jobs", {original: {"private": True, "status": "ready", "data": b"original"},
                                              public: {"private": False, "status": "ready", "data": b"public"}})
    path = base + "/private-video-continue"
    payload = {"prompt": "continue walking", "previous": original}
    assert client.post(path, json=payload).status_code == 401
    for unknown in (public, str(uuid4())):
        assert client.post(path, headers=auth, json=payload | {"previous": unknown}).status_code == 404
    response = client.post(path, headers=auth, json=payload)
    assert response.status_code == 200 and response.json()["id"] != original
    assert executor.submit.call_args.args[-1] == b"original"
    assert lumi._video_jobs[original]["data"] == b"original"
    assert client.post(path, headers=auth, json=payload).status_code == 409


@pytest.mark.skipif(not shutil.which("ffmpeg") or not shutil.which("ffprobe"), reason="requires local ffmpeg and ffprobe")
@pytest.mark.parametrize("fragmented", [False, True])
def test_extension_preserves_original_frames_and_starts_from_its_final_frame(tmp_path, fragmented):
    def ffmpeg(*args):
        return subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", *args], cwd=tmp_path,
                              capture_output=True, check=True, timeout=20).stdout
    for name, color in (("one", "red"), ("two", "blue")):
        layout = ["-movflags", "frag_keyframe+empty_moov"] if fragmented else []
        ffmpeg("-f", "lavfi", "-i", f"color=c={color}:s=96x64:r=10:d=1", "-c:v", "libx264", "-pix_fmt", "yuv420p", *layout, name + ".mp4")
    def render(frame):
        with Image.open(BytesIO(frame)) as picture:
            r, _, b = picture.getpixel((24, 24))[:3]
            assert r > 200 and b < 30
        return (tmp_path / "two.mp4").read_bytes()
    joined = continue_clip((tmp_path / "one.mp4").read_bytes(), render)
    (tmp_path / "joined.mp4").write_bytes(joined)
    result = subprocess.check_output(["ffprobe", "-v", "error", "-select_streams", "v:0", "-count_frames", "-show_entries",
                                      "stream=nb_read_frames,duration", "-of", "json", "joined.mp4"], cwd=tmp_path)
    stream = json.loads(result)["streams"][0]
    assert stream["nb_read_frames"] == "20" and float(stream["duration"]) == pytest.approx(2)
    frames = lambda clip, start, count: ffmpeg("-ss", start, "-i", clip, "-frames:v", count, "-f", "rawvideo", "-pix_fmt", "rgb24", "pipe:1")
    assert frames("joined.mp4", "0", "10") == frames("one.mp4", "0", "10")
    assert frames("joined.mp4", "1", "10") == frames("two.mp4", "0", "10")

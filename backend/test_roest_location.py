import json
from pathlib import Path
from subprocess import CompletedProcess

from fastapi import FastAPI, Response

from install_fadedai_pc import install_roest_location
from sweatcaster import microsoft_voice


def make_runtime(root: Path):
    files = ["roest-venv/Scripts/python.exe", "roest-venv/Lib/site-packages/chatterbox/mtl_tts.py",
             "roest-model/t3_mtl23ls_v2.safetensors", "roest-model/s3gen.pt", "roest-model/ve.pt",
             "roest-model/grapheme_mtl_merged_expanded_v1.json",
             "roest-model/audio_samples/00_mic_00_sample.wav", "roest-model/audio_samples/00_nic_00_sample.wav"]
    for filename in files:
        path = root / filename
        path.parent.mkdir(parents=True, exist_ok=True)
        path.touch()
    (root / "roest-ready.json").write_text(json.dumps({"tested": ["mic", "nic"]}), encoding="utf-8")


def test_tested_runtime_is_registered_without_hardcoded_location(tmp_path):
    root = tmp_path / "model's directory"
    package = tmp_path / "package"
    package.mkdir()
    make_runtime(root)
    install_roest_location(package, root)
    namespace = {}
    exec((package / "roest_location.py").read_text(encoding="utf-8"), namespace)
    assert Path(namespace["ROOT"]) == root.resolve()


def test_incomplete_runtime_is_not_registered(tmp_path):
    root = tmp_path / "runtime"
    package = tmp_path / "package"
    package.mkdir()
    make_runtime(root)
    (root / "roest-model" / "s3gen.pt").unlink()
    install_roest_location(package, root)
    assert not (package / "roest_location.py").exists()


def test_existing_location_is_preserved(tmp_path):
    root = tmp_path / "runtime"
    package = tmp_path / "package"
    package.mkdir()
    make_runtime(root)
    location = package / "roest_location.py"
    location.write_text("ROOT = 'existing'\n", encoding="utf-8")
    install_roest_location(package, root)
    assert location.read_text(encoding="utf-8") == "ROOT = 'existing'\n"


def test_lumi_voice_is_available_only_with_its_own_reference(tmp_path, monkeypatch):
    make_runtime(tmp_path)
    monkeypatch.setenv("FADEDAI_ROEST_ROOT", str(tmp_path))
    monkeypatch.setattr("sweatcaster.kokoro_voice.kokoro_ready", lambda: (False, None))
    app = FastAPI()
    microsoft_voice.register_christel(app, None, lambda request, settings: None)
    route = "/api/modules/v1/agent-local-voices"
    calls = []

    def run(command, **options):
        calls.append((command[-1], json.loads(options["input"])["text"]))
        Path(command[-2]).write_bytes(b"RIFF0000WAVE" + bytes(48))
        return CompletedProcess(command, 0)

    monkeypatch.setattr(microsoft_voice.subprocess, "run", run)
    handlers = {next(iter(item.methods)): item.endpoint for item in app.routes if item.path == route}
    assert handlers["GET"](None, Response())["voices"] == ["roest-mic", "roest-nic"]
    (tmp_path / "roest-model/audio_samples/00_lumi_00_reference.wav").touch()
    assert handlers["GET"](None, Response())["voices"] == ["roest-mic", "roest-nic", "roest-lumi"]
    for voice in ("roest-lumi", "roest-nic"):
        assert handlers["PUT"](None, Response(), {"voice": voice, "text": "Hej!"})["audio"]
    assert calls == [("lumi", "Hej!"), ("nic", "Hej!")]


def test_new_danish_voices_use_distinct_synthetic_references(tmp_path, monkeypatch):
    from sweatcaster import kokoro_voice
    make_runtime(tmp_path)
    monkeypatch.setenv("FADEDAI_ROEST_ROOT", str(tmp_path))
    monkeypatch.setattr(kokoro_voice, "kokoro_ready", lambda: (True, "ready"))
    references = []

    def reference(text, path, *, voice):
        references.append(voice)
        path.write_bytes(voice.encode())

    def speak(command, **options):
        assert command[-2] == "synthetic"
        assert json.loads(options["input"])["text"] == "Godmorgen"
        Path(command[-3]).write_bytes(b"RIFF0000WAVE" + Path(command[-1]).read_bytes() + bytes(48))
        return CompletedProcess(command, 0)

    monkeypatch.setattr(kokoro_voice, "synthesize_kokoro", reference)
    monkeypatch.setattr(microsoft_voice.subprocess, "run", speak)
    app = FastAPI()
    microsoft_voice.register_christel(app, None, lambda request, settings: None)
    handlers = {next(iter(item.methods)): item.endpoint for item in app.routes
                if item.path == "/api/modules/v1/agent-local-voices"}
    assert {"roest-freja", "roest-storm"}.issubset(handlers["GET"](None, Response())["voices"])
    microsoft_voice.synthetic_reference.cache_clear()
    try:
        def play(voice):
            return handlers["PUT"](None, Response(), {"voice": voice, "text": "Godmorgen"})["audio"]
        freja = play("roest-freja")
        assert play("roest-storm") != freja
        assert play("roest-freja") == freja
        assert references == ["af_bella", "am_fenrir"]
    finally:
        microsoft_voice.synthetic_reference.cache_clear()

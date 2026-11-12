"""Exercise the voice installer and local narration without downloading models."""

from dataclasses import dataclass
import importlib.util
from pathlib import Path
import struct
import sys
from types import ModuleType, SimpleNamespace
import wave

import numpy as np
import pytest
import sweatcaster

import install_pc_video_voice as installer


@pytest.fixture
def staged(tmp_path, monkeypatch):
    source = Path(sweatcaster.__file__).parent
    destination = tmp_path / "sweatcaster"
    destination.mkdir()
    for name in (*installer.changes(), "kokoro_voice.py"):
        (destination / name).write_bytes((source / name).read_bytes())
    monkeypatch.setattr(installer, "atomic_write", lambda path, data: path.write_bytes(data))
    installer.install(tmp_path, apply=True)
    assert not installer.install(tmp_path, apply=True)

    def load(name):
        full_name = f"sweatcaster.{name}"
        spec = importlib.util.spec_from_file_location(full_name, destination / (name + ".py"))
        module = importlib.util.module_from_spec(spec)
        monkeypatch.setitem(sys.modules, full_name, module)
        spec.loader.exec_module(module)
        return module

    return load


def test_audio_is_pcm16_and_cpu_engine_is_reused(staged, tmp_path, monkeypatch):
    adapter = staged("kokoro_voice")
    model, voices = tmp_path / "model.onnx", tmp_path / "voices.bin"
    monkeypatch.setattr(adapter, "kokoro_files", lambda: (model, voices))
    sessions = []
    syntheses = []

    class FakeKokoro:
        @classmethod
        def from_session(cls, session, voice_file):
            assert session == "session"
            assert voice_file == str(voices)
            return cls()

        def create(self, text, *, voice, speed, lang):
            syntheses.append((text, speed))
            assert (voice, lang) == ("af_heart", "en-us")
            return np.asarray([-2.0, -0.5, 0.0, 0.5, 2.0], dtype=np.float32), 24_000

    def inference_session(path, *, sess_options, providers):
        sessions.append(path)
        assert providers == ["CPUExecutionProvider"]
        assert 1 <= sess_options.intra_op_num_threads <= 4
        assert sess_options.inter_op_num_threads == 1
        return "session"

    for name, values in (
        ("kokoro_onnx", {"Kokoro": FakeKokoro}),
        ("onnxruntime", {"SessionOptions": SimpleNamespace, "InferenceSession": inference_session}),
    ):
        module = ModuleType(name)
        vars(module).update(values)
        monkeypatch.setitem(sys.modules, name, module)
    for line, mood in (("Nice shot.", None), ("What a finish!", "hype")):
        output = tmp_path / "line.wav"
        assert adapter.synthesize_kokoro(line, output, mood=mood) == 5 / 24_000
        with wave.open(str(output), "rb") as audio:
            assert (audio.getnchannels(), audio.getsampwidth(), audio.getframerate()) == (1, 2, 24_000)
            assert struct.unpack("<5h", audio.readframes(5)) == (-32767, -16384, 0, 16384, 32767)
    assert sessions == [str(model)]
    assert syntheses == [("Nice shot.", 1.0), ("What a finish!", 1.08)]


@dataclass
class Settings:
    tts_mode: str
    commentary_mode: str = "auto"


def test_auto_uses_kokoro_then_falls_back_for_the_entire_video(staged, tmp_path, monkeypatch):
    adapter = staged("kokoro_voice")
    tts = staged("tts")
    voice = tmp_path / "piper.onnx"
    voice.touch()
    monkeypatch.setattr(tts, "piper_ready", lambda settings: (True, "ready"))
    monkeypatch.setattr(tts, "voice_for_mood", lambda settings, mood: (voice, None))
    monkeypatch.setattr(tts, "kokoro_ready", lambda: (True, "ready"))
    plan = SimpleNamespace(lines=[SimpleNamespace(text="First", t_start=0), SimpleNamespace(text="Second", t_start=1)])
    plan.mood = "hype"
    def speak(text, path, *, mood):
        assert mood == "hype"
        path.write_text("Kokoro " + text, encoding="utf-8")
        return 1.0
    monkeypatch.setattr(tts, "synthesize_kokoro", speak)
    bundle = tts.synthesize(plan, tmp_path, Settings("auto"), None)
    assert bundle.source == "kokoro"

    def broken_second_line(text, path, *, mood):
        if text == "Second":
            raise adapter.KokoroSynthesisError("Unavailable.")
        return speak(text, path, mood=mood)
    def piper(path, text, settings, model):
        path.write_text("Piper " + text, encoding="utf-8")
        return 1.0
    monkeypatch.setattr(tts, "synthesize_kokoro", broken_second_line)
    monkeypatch.setattr(tts, "_piper_wav", piper)
    bundle = tts.synthesize(plan, tmp_path, Settings("auto"), None)
    assert bundle.source == "piper"
    assert [clip.wav_path.read_text(encoding="utf-8") for clip in bundle.clips] == ["Piper First", "Piper Second"]
    assert any("Piper voice was used" in warning for warning in bundle.warnings)
    with pytest.raises(tts.TtsError, match="Unavailable"):
        tts.synthesize(plan, tmp_path, Settings("kokoro"), None)


def test_voice_preflight_accepts_kokoro_with_no_piper(staged, monkeypatch):
    staged("kokoro_voice")
    staged("tts")
    preflight = staged("preflight")
    dependencies = [{"name": name, "ready": name != "piper", "message": "Piper is missing."}
                    for name in preflight.DEPENDENCY_ORDER]
    monkeypatch.setattr(preflight, "_tool", lambda name: {"name": name, "ready": True, "message": "ready"})
    monkeypatch.setattr(preflight, "ollama_dependency", lambda _: {"name": "ollama", "ready": True, "message": "ready"})
    monkeypatch.setattr(preflight, "piper_ready", lambda _: (False, "Piper is missing."))
    monkeypatch.setattr(preflight, "whisper_status", lambda _: {"ok": False, "detail": "missing"})
    monkeypatch.setattr(preflight, "_easyocr_status", lambda _: {"ok": False, "detail": "missing"})
    monkeypatch.setattr(preflight, "kokoro_ready", lambda: (True, "Kokoro is ready."))
    voice = next(row for row in preflight.collect_dependencies(Settings("auto")) if row["name"] == "piper")
    assert voice == {"name": "piper", "ready": True, "message": "Kokoro is ready."}
    assert preflight.create_blockers(Settings("auto"), dependencies) is None
    assert preflight.create_blockers(Settings("piper"), dependencies) == "Piper is missing."
    monkeypatch.setattr(preflight, "kokoro_ready", lambda: (False, "Kokoro is missing."))
    assert preflight.create_blockers(Settings("kokoro"), dependencies) == "Kokoro is missing."
    assert preflight.create_blockers(Settings("auto"), dependencies) == "Piper is missing."

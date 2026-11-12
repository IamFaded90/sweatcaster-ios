"""Local English Kokoro narration using CPU inference and a bounded session."""

from __future__ import annotations

import importlib.util
import os
import threading
import wave
from functools import lru_cache
from pathlib import Path


class KokoroSynthesisError(RuntimeError):
    pass


def kokoro_dir() -> Path | None:
    asset = os.environ.get("FADEDAI_ASSET_ROOT", "").strip()
    if asset:
        return Path(asset) / "kokoro"
    for drive in ("F:/", "H:/"):
        root = Path(drive) / "FadedAI" / "kokoro"
        if root.is_dir():
            return root
    return None


def kokoro_files() -> tuple[Path, Path] | None:
    root = kokoro_dir()
    if root is None:
        return None
    model = root / "kokoro-v1.0.onnx"
    voices = root / "voices-v1.0.bin"
    if model.is_file() and voices.is_file():
        return model, voices
    return None


def kokoro_ready() -> tuple[bool, str]:
    if kokoro_files() is None:
        return False, "The local Kokoro voice files are missing."
    if importlib.util.find_spec("kokoro_onnx") is None:
        return False, "The local Kokoro voice package is not installed."
    return True, "Kokoro and its English voice files were found."


_engine_lock = threading.Lock()
_SPEED_BY_MOOD = {"roast": 0.98, "hype": 1.08, "sweaty": 0.95, "funny_npc": 1.03}


@lru_cache(maxsize=1)
def _engine(model: Path, voices: Path):
    from kokoro_onnx import Kokoro
    from onnxruntime import InferenceSession, SessionOptions

    options = SessionOptions()
    options.intra_op_num_threads = min(4, os.cpu_count() or 1)
    options.inter_op_num_threads = 1
    session = InferenceSession(str(model), sess_options=options, providers=["CPUExecutionProvider"])
    return Kokoro.from_session(session, str(voices))


def synthesize_kokoro(text: str, wav_path: Path, *, mood: str | None = None) -> float:
    found = kokoro_files()
    if found is None:
        raise FileNotFoundError("The local Kokoro voice files are missing.")
    try:
        import numpy as np

        with _engine_lock:
            engine = _engine(*found)
            samples, rate = engine.create(text[:500], voice="af_heart", speed=_SPEED_BY_MOOD.get(mood, 1.0), lang="en-us")
        samples = np.asarray(samples)
        rate = int(rate)
        if samples.ndim != 1 or not samples.size or rate <= 0 or not np.isfinite(samples).all():
            raise ValueError("Invalid audio samples.")
        pcm = np.rint(np.clip(samples, -1.0, 1.0) * 32767).astype("<i2")
        if not np.any(pcm):
            raise ValueError("Empty speech.")
    except ImportError as exc:
        raise FileNotFoundError("The local Kokoro voice package is not installed.") from exc
    except Exception as exc:
        raise KokoroSynthesisError("The local Kokoro voice could not speak this line.") from exc

    wav_path.parent.mkdir(parents=True, exist_ok=True)
    with wave.open(str(wav_path), "wb") as handle:
        handle.setnchannels(1)
        handle.setsampwidth(2)
        handle.setframerate(rate)
        handle.writeframes(pcm.tobytes())
    return len(pcm) / rate

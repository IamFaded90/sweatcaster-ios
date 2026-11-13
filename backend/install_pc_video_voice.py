"""Stage local Kokoro narration with mood-aware pacing and Piper fallback."""

from __future__ import annotations

import argparse
from hashlib import sha256
from pathlib import Path

from install_fadedai_pc import atomic_write


PREVIOUS_ADAPTER_HASHES = {
    "edbfa80e934f8cd20f7f247f8a4f75da8ff54b9c574bfab0ca342c787bfd3c01",
    "206316deb9254ea01736bef1e422c81c8cb0e650e97da890d94706a67cd583b7",
}
UNPACED_CALL = "duration = synthesize_kokoro(line.text, wav_path)"
PACED_CALL = "duration = synthesize_kokoro(line.text, wav_path, mood=plan.mood)"


def changes() -> dict[str, list[tuple[str, str]]]:
    return {
        "tts.py": [
            ("from dataclasses import dataclass", "from dataclasses import dataclass, replace"),
            (
                "from sweatcaster.config import Settings",
                "from sweatcaster.config import Settings\n"
                "from sweatcaster.kokoro_voice import KokoroSynthesisError, kokoro_ready, synthesize_kokoro",
            ),
            (
                '    use_synthetic = settings.tts_mode == "synthetic"\n'
                '    if settings.tts_mode == "auto":\n'
                '        ready, detail = piper_ready(settings)\n'
                '        if not ready:\n'
                '            raise TtsError(detail, code="DEPENDENCY_MISSING")\n'
                '    elif settings.tts_mode == "piper":\n'
                '        ready, detail = piper_ready(settings)\n'
                '        if not ready:\n'
                '            raise TtsError(detail, code="DEPENDENCY_MISSING")\n'
                '    elif settings.tts_mode == "kokoro":\n'
                '        use_synthetic = False\n'
                '    elif settings.tts_mode != "synthetic":\n'
                '        raise TtsError("Voice mode is not valid.")',
                '    mode = settings.tts_mode\n'
                '    if mode == "auto":\n'
                '        mode = "kokoro" if kokoro_ready()[0] else "piper"\n'
                '    if mode in {"kokoro", "piper"}:\n'
                '        ready, detail = kokoro_ready() if mode == "kokoro" else piper_ready(settings)\n'
                '        if not ready:\n'
                '            raise TtsError(detail, code="DEPENDENCY_MISSING")\n'
                '    elif mode != "synthetic":\n'
                '        raise TtsError("Voice mode is not valid.")',
            ),
            (
                '    if not use_synthetic and settings.tts_mode != "kokoro":',
                '    if mode == "piper":',
            ),
            (
                '        if settings.tts_mode == "kokoro":\n'
                '            from sweatcaster.kokoro_voice import synthesize_kokoro\n\n'
                '            try:\n'
                '                duration = synthesize_kokoro(line.text, wav_path)\n'
                '            except FileNotFoundError as exc:\n'
                '                raise TtsError(str(exc), code="DEPENDENCY_MISSING") from exc',
                '        if mode == "kokoro":\n'
                '            try:\n'
                '                duration = synthesize_kokoro(line.text, wav_path)\n'
                '            except (FileNotFoundError, KokoroSynthesisError) as exc:\n'
                '                if settings.tts_mode == "auto" and piper_ready(settings)[0]:\n'
                '                    fallback = synthesize(plan, workdir, replace(settings, tts_mode="piper"), cancel)\n'
                '                    fallback.warnings.insert(0, "Kokoro could not speak this video. The Piper voice was used.")\n'
                '                    return fallback\n'
                '                code = "DEPENDENCY_MISSING" if isinstance(exc, FileNotFoundError) else "PROCESSING_FAILED"\n'
                '                raise TtsError(str(exc), code=code) from exc',
            ),
            ('        elif use_synthetic:', '        elif mode == "synthetic":'),
        ],
        "render.py": [
            ("    NARRATION_PIPER,\n", "    NARRATION_KOKORO,\n    NARRATION_PIPER,\n"),
            (
                '{NARRATION_PIPER, NARRATION_SYNTHETIC, "disabled"}',
                '{NARRATION_KOKORO, NARRATION_PIPER, NARRATION_SYNTHETIC, "disabled"}',
            ),
        ],
        "preflight.py": [
            (
                "from sweatcaster.tts import piper_ready",
                "from sweatcaster.kokoro_voice import kokoro_ready\nfrom sweatcaster.tts import piper_ready",
            ),
            (
                '    piper_ok, piper_message = piper_ready(settings)\n',
                '    piper_ok, piper_message = piper_ready(settings)\n'
                '    if settings.tts_mode in {"auto", "kokoro"}:\n'
                '        kokoro_ok, kokoro_message = kokoro_ready()\n'
                '        if kokoro_ok or settings.tts_mode == "kokoro":\n'
                '            piper_ok, piper_message = kokoro_ok, kokoro_message\n',
            ),
            (
                '    if settings.tts_mode in {"auto", "piper"} and not rows["piper"]["ready"]:',
                '    if settings.tts_mode in {"auto", "kokoro"}:\n'
                '        ready, detail = kokoro_ready()\n'
                '        if settings.tts_mode == "kokoro":\n'
                '            return None if ready else detail\n'
                '        if ready:\n'
                '            return None\n'
                '    if settings.tts_mode in {"auto", "piper"} and not rows["piper"]["ready"]:',
            ),
        ],
    }


def install(root: Path, apply: bool = False) -> list[Path]:
    root = root.resolve(strict=True)
    staged: dict[Path, tuple[bytes | None, bytes]] = {}
    for name, edits in changes().items():
        path = root / "sweatcaster" / name
        if path.is_symlink() or not path.resolve(strict=True).is_relative_to(root):
            raise ValueError(f"Unexpected checkpoint path: {name}.")
        original = path.read_bytes()
        text = original.decode("utf-8").replace("\r\n", "\n")
        updated = text.replace(PACED_CALL, UNPACED_CALL) if name == "tts.py" else text
        for anchor, replacement in edits:
            if replacement in updated:
                continue
            if updated.count(anchor) != 1:
                raise ValueError(f"Unexpected checkpoint version: {name}.")
            updated = updated.replace(anchor, replacement)
        if name == "tts.py":
            if updated.count(UNPACED_CALL) != 1:
                raise ValueError("Unexpected Kokoro call site: tts.py.")
            updated = updated.replace(UNPACED_CALL, PACED_CALL)
        if updated != text:
            staged[path] = original, updated.encode("utf-8")

    adapter = root / "sweatcaster/kokoro_voice.py"
    if adapter.is_symlink() or not adapter.resolve().is_relative_to(root):
        raise ValueError("Unexpected Kokoro adapter path.")
    original = adapter.read_bytes() if adapter.exists() else None
    source = Path(__file__).with_name("sweatcaster").joinpath("kokoro_voice.py").read_bytes()
    original_normalized = original.replace(b"\r\n", b"\n") if original is not None else None
    if original_normalized != source.replace(b"\r\n", b"\n"):
        if original_normalized is not None and sha256(original_normalized).hexdigest() not in PREVIOUS_ADAPTER_HASHES:
            raise ValueError("Unexpected Kokoro adapter version.")
        staged[adapter] = original, source

    for path, (_, source) in staged.items():
        compile(source, str(path), "exec")
    if apply:
        for path, (original, _) in staged.items():
            backup = path.with_suffix(".py.before-kokoro-narration")
            if original is not None and not backup.exists():
                atomic_write(backup, original)
        written: list[Path] = []
        try:
            for path, (original, source) in staged.items():
                if (path.read_bytes() if path.exists() else None) != original:
                    raise ValueError(f"Checkpoint changed during update: {path.name}.")
                atomic_write(path, source)
                written.append(path)
        except (OSError, ValueError):
            for path in reversed(written):
                original = staged[path][0]
                if original is None:
                    path.unlink()
                else:
                    atomic_write(path, original)
            raise
    return list(staged)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("checkpoint", type=Path)
    parser.add_argument("--apply", action="store_true", help="Apply after stopping FadedAI on the PC.")
    args = parser.parse_args()
    paths = install(args.checkpoint, apply=args.apply)
    print(f"{'Updated' if args.apply else 'Checked'} {len(paths)} checkpoint files.")

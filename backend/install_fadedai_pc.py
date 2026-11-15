"""Prepare and apply the combined Windows backend update."""

from __future__ import annotations

from pathlib import Path
from tempfile import NamedTemporaryFile, TemporaryDirectory


def atomic_write(path: Path, data: bytes) -> None:
    temporary = None
    try:
        with NamedTemporaryFile(dir=path.parent, prefix=path.name + ".", delete=False) as stream:
            temporary = Path(stream.name)
            stream.write(data)
        temporary.replace(path)
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def read_source(path: Path, package: Path) -> bytes | None:
    if path.is_symlink() or path.resolve().parent != package:
        raise ValueError(f"Unexpected checkpoint source: {path.name}.")
    return path.read_bytes() if path.exists() else None


def install_launcher_status(package: Path) -> None:
    path = package / "fadedai.py"
    if not path.is_file():
        return
    code = path.read_text(encoding="utf-8")
    start = '    command = (\n        "$shortcut = Join-Path'
    end = "\n\ndef main() -> None:"
    health_helper = "def _open_qr_when_ready(io: BootIO) -> None:"
    if health_helper not in code or "    show_startup_status(io.root)" in code:
        return
    if code.count(start) != 1 or code.count(end) != 1:
        return
    code = code.replace(start, '    print("Klar til at forbinde · Åbn FadedAI på iPhone.", flush=True)\n' + start, 1)
    code = code.replace(end, "\n    from sweatcaster.pc_metrics import show_startup_status\n"
                        "    show_startup_status(io.root)\n" + end, 1)
    compile(code, str(path), "exec")
    path.write_bytes(code.encode("utf-8"))


def install(root: Path, *, apply: bool = True) -> list[Path]:
    from install_module_tabs import install as install_modules
    from install_pc_video_voice import install as install_voice
    from install_video_commentary import install as install_commentary
    from install_video_review import install as install_review

    root = root.resolve(strict=True)
    package = root / "sweatcaster"
    if package.is_symlink() or package.resolve(strict=True) != package or not (package / "api.py").is_file():
        raise ValueError("Choose the existing FadedAI PC checkpoint.")

    originals = {path.name: read_source(path, package) for path in package.glob("*.py")}
    with TemporaryDirectory(prefix="fadedai-pc-update-") as staging:
        staged_root = Path(staging)
        staged_package = staged_root / package.name
        staged_package.mkdir()
        for name, original in originals.items():
            if original is not None:
                (staged_package / name).write_bytes(original)

        install_modules(staged_root)
        install_commentary(staged_root, apply=True)
        install_voice(staged_root, apply=True)
        install_review(staged_root)
        install_launcher_status(staged_package)

        changes = {}
        for path in sorted(staged_package.glob("*.py")):
            updated = path.read_bytes()
            original = originals.get(path.name)
            if updated != original:
                changes[package / path.name] = original, updated

    if not apply:
        return list(changes)

    for path, (original, _) in changes.items():
        if read_source(path, package) != original:
            raise ValueError(f"Checkpoint changed during update: {path.name}.")
        backup = path.with_suffix(".py.before-fadedai-update")
        if original is not None and read_source(backup, package) is None:
            atomic_write(backup, original)

    written = []
    try:
        for path, (original, updated) in changes.items():
            if read_source(path, package) != original:
                raise ValueError(f"Checkpoint changed during update: {path.name}.")
            atomic_write(path, updated)
            written.append(path)
    except (OSError, ValueError):
        for path in reversed(written):
            original, _ = changes[path]
            if original is None:
                path.unlink()
            else:
                atomic_write(path, original)
        raise

    return list(changes)

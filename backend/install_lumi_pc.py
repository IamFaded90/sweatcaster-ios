"""Install only Lumi's paired route into the existing PC checkpoint."""

from __future__ import annotations

import argparse
from pathlib import Path

from install_fadedai_pc import atomic_write, read_source


def install(checkpoint: Path, *, apply: bool = False) -> list[Path]:
    checkpoint = checkpoint.resolve(strict=True)
    package = checkpoint / "sweatcaster"
    if package.is_symlink() or not (package / "api.py").is_file():
        raise ValueError("Choose the existing FadedAI PC checkpoint.")
    source = Path(__file__).resolve().parent / "sweatcaster"
    modules = ("studio_video_workflows.py", "lumi_flux.py", "lumi_video_files.py", "lumi_media_inputs.py",
               "lumi_continuation.py", "lumi_dialogue.py", "lumi_units.py", "lumi_recall.py", "lumi_companion.py")
    hook = package / "module_tabs.py"
    hook_bytes = read_source(hook, package)
    if hook_bytes is None:
        raise ValueError("The PC module hook is missing.")
    original = hook_bytes.decode("utf-8").replace("\r\n", "\n")
    import_line = "    from sweatcaster.lumi_companion import register_lumi\n"
    call_line = "    register_lumi(app, settings, authorize)\n"
    updated = original
    if import_line not in updated:
        anchor = "    from sweatcaster.bot_computer_routes import register_bot_computers\n"
        if updated.count(anchor) != 1:
            raise ValueError("The installed PC module hook changed unexpectedly.")
        updated = updated.replace(anchor, anchor + import_line)
    if call_line not in updated:
        anchor = "    computers = register_bot_computers(app, settings, authorize)\n"
        if updated.count(anchor) != 1:
            raise ValueError("The installed PC module hook changed unexpectedly.")
        updated = updated.replace(anchor, anchor + call_line)
    compile(updated, str(hook), "exec")
    changes = {}
    for name in modules:
        target = package / name
        data = (source / name).read_bytes()
        compile(data, str(target), "exec")
        current = read_source(target, package)
        if current is None or current.replace(b"\r\n", b"\n") != data.replace(b"\r\n", b"\n"):
            changes[target] = (current, data)
    if original != updated:
        changes[hook] = (hook_bytes, updated.replace("\n", "\r\n" if b"\r\n" in hook_bytes else "\n").encode("utf-8"))
    if not apply or not changes:
        return list(changes)
    backup = hook.with_suffix(".py.before-lumi")
    if hook in changes and read_source(backup, package) is None:
        atomic_write(backup, hook_bytes)
    written = []
    try:
        for target, (current, data) in changes.items():
            if read_source(target, package) != current:
                raise ValueError(f"Checkpoint changed during update: {target.name}.")
            atomic_write(target, data)
            written.append(target)
    except (OSError, ValueError):
        for target in reversed(written):
            current, data = changes[target]
            if read_source(target, package) == data:
                if current is None:
                    target.unlink()
                else:
                    atomic_write(target, current)
        raise
    return list(changes)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("checkpoint", type=Path)
    parser.add_argument("--apply", action="store_true")
    args = parser.parse_args()
    print("\n".join(str(path) for path in install(args.checkpoint, apply=args.apply)))

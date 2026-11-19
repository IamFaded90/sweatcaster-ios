"""Install only Lumi's paired route into the existing PC checkpoint."""

from __future__ import annotations

import argparse
from pathlib import Path


def install(checkpoint: Path, *, apply: bool = False) -> list[Path]:
    checkpoint = checkpoint.resolve(strict=True)
    package = checkpoint / "sweatcaster"
    if package.is_symlink() or not (package / "api.py").is_file():
        raise ValueError("Choose the existing FadedAI PC checkpoint.")
    source = Path(__file__).resolve().parent / "sweatcaster" / "lumi_companion.py"
    flux_source = source.with_name("lumi_flux.py")
    sources = (source, flux_source, source.with_name("studio_video_workflows.py"),
               source.with_name("lumi_video_files.py"))
    hook = package / "module_tabs.py"
    original = hook.read_text(encoding="utf-8")
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
    modules = {}
    for source_file in sources:
        data = source_file.read_bytes()
        compile(data, str(source_file), "exec")
        modules[package / source_file.name] = data
    changes = [path for path, data in modules.items() if not path.exists() or path.read_bytes() != data]
    if original != updated:
        changes.insert(0, hook)
    if not apply or not changes:
        return changes
    backup = hook.with_suffix(".py.before-lumi")
    if not backup.exists():
        backup.write_text(original, encoding="utf-8")
    for target, data in modules.items():
        target.write_bytes(data)
    try:
        hook.write_text(updated, encoding="utf-8")
    except OSError:
        hook.write_text(original, encoding="utf-8")
        raise
    return changes


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("checkpoint", type=Path)
    parser.add_argument("--apply", action="store_true")
    args = parser.parse_args()
    print("\n".join(str(path) for path in install(args.checkpoint, apply=args.apply)))

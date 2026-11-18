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
    module = package / source.name
    flux_module = package / flux_source.name
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
    compile(source.read_text(encoding="utf-8"), str(source), "exec")
    compile(flux_source.read_text(encoding="utf-8"), str(flux_source), "exec")
    changes = [path for path, old, new in ((hook, original.encode(), updated.encode()),
               (module, module.read_bytes() if module.exists() else b"", source.read_bytes()),
               (flux_module, flux_module.read_bytes() if flux_module.exists() else b"", flux_source.read_bytes())) if old != new]
    if not apply or not changes:
        return changes
    backup = hook.with_suffix(".py.before-lumi")
    if not backup.exists():
        backup.write_text(original, encoding="utf-8")
    module.write_bytes(source.read_bytes())
    flux_module.write_bytes(flux_source.read_bytes())
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

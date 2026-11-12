"""Copy the computer module into a checkpoint copy. Never point this at the running install."""

import argparse
from pathlib import Path

from sweatcaster.bot_computers import LIVE_MARKERS


def install(root: Path) -> None:
    text = str(root)
    if any(marker in text for marker in LIVE_MARKERS):
        raise SystemExit("Den mappe er den kørende installation. Lav en kopi først, og peg på kopien.")
    package = root / "sweatcaster"
    api = package / "api.py"
    if not api.is_file():
        raise SystemExit("Kopien mangler sweatcaster/api.py. Ingen filer blev skrevet.")
    source = Path(__file__).resolve().parent / "sweatcaster" / "bot_computers.py"
    anchor = "    register_modules(app, settings, _bearer)\n"
    addition = (
        anchor
        + "    from sweatcaster.bot_computers import register_bot_computers\n"
        + "    register_bot_computers(app, settings, _bearer)\n"
    )
    original = api.read_text(encoding="utf-8")
    if "register_bot_computers" in original:
        package.joinpath("bot_computers.py").write_text(source.read_text(encoding="utf-8"), encoding="utf-8")
        return
    if original.count(anchor) != 1:
        raise SystemExit("Kopien har ikke module-krogen. Kør install_module_tabs.py på kopien først. Ingen filer blev skrevet.")
    updated = original.replace(anchor, addition, 1)
    compile(updated, str(api), "exec")
    compile(source.read_text(encoding="utf-8"), str(source), "exec")
    backup = api.with_suffix(".py.before-bot-computers")
    if not backup.exists():
        backup.write_text(original, encoding="utf-8")
    package.joinpath("bot_computers.py").write_text(source.read_text(encoding="utf-8"), encoding="utf-8")
    api.write_text(updated, encoding="utf-8")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("checkpoint", type=Path)
    install(parser.parse_args().checkpoint.resolve())

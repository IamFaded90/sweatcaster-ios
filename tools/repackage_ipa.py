"""Update app/extension build numbers without changing any compiled binary."""
import argparse
import copy
import hashlib
from pathlib import Path
import plistlib
import re
import zipfile

ROOT = "Payload/FadedAI.app/"
INFOS = {ROOT + "Info.plist"} | {
    ROOT + f"PlugIns/{name}.appex/Info.plist"
    for name in ("FadedAIWidgets", "FadedAIShare", "FadedAIBroadcast")
}


def repackage(source, destination, version, expected_sha256):
    source, destination = Path(source).resolve(strict=True), Path(destination).resolve()
    if source == destination or destination.exists():
        raise ValueError("Output must be a new file; preserve the original IPA.")
    if not re.fullmatch(r"\d+(?:\.\d+){0,2}", version):
        raise ValueError("Build version must contain one to three numeric components.")
    with source.open("rb") as stream:
        digest = hashlib.file_digest(stream, "sha256").hexdigest()
    if digest != expected_sha256:
        raise ValueError("Source IPA does not match the verified native build.")
    with zipfile.ZipFile(source) as archive:
        names = archive.namelist()
        if len(names) != len(set(names)) or not INFOS <= set(names):
            raise ValueError("Expected unique ZIP entries and all four bundle plists.")
        replacements = {}
        for name in INFOS:
            original = archive.read(name)
            info = plistlib.loads(original)
            if not isinstance(info, dict) or not info.get("CFBundleExecutable") or "CFBundleVersion" not in info:
                raise ValueError("Invalid bundle metadata: " + name)
            info["CFBundleVersion"] = version
            fmt = plistlib.FMT_BINARY if original.startswith(b"bplist00") else plistlib.FMT_XML
            replacements[name] = plistlib.dumps(info, fmt=fmt, sort_keys=False)
        destination.parent.mkdir(parents=True, exist_ok=True)
        created = False
        try:
            with destination.open("xb") as stream:
                created = True
                with zipfile.ZipFile(stream, "w") as result:
                    for info in archive.infolist():
                        result.writestr(copy.copy(info), replacements.get(info.filename, archive.read(info)))
        except Exception:
            if created:
                destination.unlink(missing_ok=True)
            raise
    print(f"Repackaged build {version}; only the four app/extension plists changed.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("destination", type=Path)
    parser.add_argument("--version", required=True)
    parser.add_argument("--expected-sha256", required=True)
    args = parser.parse_args()
    repackage(args.source, args.destination, args.version, args.expected_sha256)

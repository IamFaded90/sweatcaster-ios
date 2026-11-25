"""Prepare a separate AltStore input IPA; no Apple account or upload.

The ad-hoc executable signature carries the requested entitlements for the final
signer to inspect. It is NOT a provisioning profile or an installable signature.
Only the main executable changes; all other ZIP entry bytes are preserved.
"""
import argparse
import copy
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import zipfile

from inspect_ipa_memory import inspect_ipa

MEMORY_KEY = "com.apple.developer.kernel.increased-memory-limit"
MAIN_INFO = "Payload/FadedAI.app/Info.plist"


def prepare(source: Path, destination: Path, entitlements: Path, *, ldid: Path | None = None) -> None:
    source, destination = source.resolve(strict=True), destination.resolve()
    if source == destination or destination.exists():
        raise ValueError("Output must be a new IPA; never replace the original download.")
    request = plistlib.loads(entitlements.read_bytes())
    if request.get(MEMORY_KEY) is not True:
        raise ValueError("The main app must explicitly request the increased memory limit.")
    codesign = shutil.which("codesign")
    if ldid is not None:
        ldid = ldid.resolve(strict=True)
        if not ldid.is_file() or not os.access(ldid, os.X_OK):
            raise ValueError("The explicitly selected ldid must be an executable file.")
    elif sys.platform != "darwin" or not codesign:
        raise ValueError("Use macOS codesign or explicitly pass --ldid; neither compiles the app.")
    inspect_ipa(source)
    destination.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(source) as archive:
        names = archive.namelist()
        if len(names) != len(set(names)) or names.count(MAIN_INFO) != 1:
            raise ValueError("Expected one FadedAI main bundle and unique ZIP entries.")
        info = plistlib.loads(archive.read(MAIN_INFO))
        executable = info["CFBundleExecutable"]
        if not isinstance(executable, str) or not executable or any(c in executable for c in "/\\\x00"):
            raise ValueError("Invalid main executable name.")
        binary_path = "Payload/FadedAI.app/" + executable
        if archive.getinfo(binary_path).file_size > 512 * 1024 * 1024:
            raise ValueError("Unexpectedly large main executable.")
        with tempfile.TemporaryDirectory(prefix="FadedAI-memory-", dir=destination.parent) as temporary:
            working = Path(temporary)
            binary = working / "FadedAI"
            binary.write_bytes(archive.read(binary_path))
            os.chmod(binary, 0o755)
            if ldid is not None:
                subprocess.run([str(ldid), "-S" + str(entitlements.resolve()), str(binary)], check=True)
                display = [str(ldid), "-e", str(binary)]
            else:
                subprocess.run([codesign, "--force", "--sign", "-", "--timestamp=none",
                                "--generate-entitlement-der", "--entitlements", str(entitlements.resolve()),
                                str(binary)], check=True)
                subprocess.run([codesign, "--verify", "--strict", str(binary)], check=True)
                display = [codesign, "--display", "--entitlements", ":-", str(binary)]
            claimed = subprocess.run(display,
                                     check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE).stdout
            if plistlib.loads(claimed).get(MEMORY_KEY) is not True:
                raise ValueError("The prepared executable does not contain the requested entitlement.")
            output = working / "memory-request.ipa"
            with zipfile.ZipFile(output, "w") as packed:
                packed.comment = archive.comment
                for item in archive.infolist():
                    data = binary.read_bytes() if item.filename == binary_path else archive.read(item)
                    packed.writestr(copy.copy(item), data)
            # Fail if packaging accidentally drops extensions, frameworks or other app data.
            with zipfile.ZipFile(output) as packed:
                if packed.namelist() != names:
                    raise ValueError("The IPA entry list changed during packaging.")
                for name in names:
                    if name != binary_path and packed.read(name) != archive.read(name):
                        raise ValueError("Packaging changed an entry other than the main executable.")
            report = inspect_ipa(output)
            if report["xml_increased_memory_limit"] is not True:
                raise ValueError("The final ZIP does not contain the requested memory metadata.")
            output.replace(destination)
    print("Prepared AltStore input IPA. Final account signing and an iPhone RAM test are still required.")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("destination", type=Path)
    parser.add_argument("--entitlements", type=Path, required=True)
    parser.add_argument("--ldid", type=Path, help="Explicit local ldid executable instead of macOS codesign")
    args = parser.parse_args()
    try:
        prepare(args.source, args.destination, args.entitlements, ldid=args.ldid)
    except (OSError, ValueError, KeyError, zipfile.BadZipFile, subprocess.CalledProcessError) as error:
        print(f"Memory-request packaging failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())

"""Check packaging and device framework loading without Xcode."""
import json
from pathlib import Path
import plistlib
import posixpath
import struct
import sys
import zipfile

ROOT = "Payload/FadedAI.app/"
VILLAGE = Path(__file__).resolve().parent / "App" / "Assets" / "Village"
VILLAGE_FOLDERS = ("cubism", "final", "vrm")
VILLAGE_REQUIRED = (
    "cubism/harper.html",
    "cubism/lumi.html",
    "cubism/live2dcubismcore.min.js",
    "final/characters.json",
    "vrm/index.html",
    "vrm/renderer.js",
    "vrm/orbit.vrm",
    "vrm/harper.vrm",
    "vrm/lumi.vrm",
    "vrm/LICENSE-three.txt",
    "vrm/LICENSE-three-vrm.txt",
)


def load_commands(data):
    # Universal frameworks use a big-endian fat header. Select the arm64 slice.
    magic, = struct.unpack_from(">I", data)
    if magic in (0xCAFEBABE, 0xCAFEBABF):
        count, = struct.unpack_from(">I", data, 4)
        wide = magic == 0xCAFEBABF
        for index in range(count):
            start = 8 + index * (32 if wide else 20)
            cpu, = struct.unpack_from(">I", data, start)
            if cpu == 0x0100000C:
                offset, size = struct.unpack_from(">QQ" if wide else ">II", data, start + 8)
                data = data[offset:offset + size]
                break
        else:
            raise ValueError("Missing arm64 slice")
    magic, cpu = struct.unpack_from("<II", data)
    if magic != 0xFEEDFACF or cpu != 0x0100000C:
        raise ValueError("Expected a 64-bit arm64 executable")
    count, = struct.unpack_from("<I", data, 16)
    position = 32
    paths, dependencies, platforms = [], [], set()
    for _ in range(count):
        command, size = struct.unpack_from("<II", data, position)
        if size < 8 or position + size > len(data):
            raise ValueError("Invalid Mach-O load command")
        if command == 0x32 and size >= 24:  # LC_BUILD_VERSION
            platforms.add(struct.unpack_from("<I", data, position + 8)[0])
        elif command == 0x25:  # LC_VERSION_MIN_IPHONEOS
            platforms.add(2)
        if command in (0x8000001C, 0xC, 0x80000018, 0x8000001F):
            offset, = struct.unpack_from("<I", data, position + 8)
            value = data[position + offset:position + size].split(b"\0", 1)[0].decode()
            if command == 0x8000001C:
                paths.append(value)
            else:
                dependencies.append((value, command == 0x80000018))
        position += size
    return paths, dependencies, platforms


def verify_resources(archive, files):
    for asset in VILLAGE_REQUIRED:
        path = ROOT + "Village/" + asset
        if path not in files or not archive.getinfo(path).file_size:
            raise ValueError(f"Missing or empty Village resource: {asset}")
    assets = []
    for folder in VILLAGE_FOLDERS:
        contents = [path.relative_to(VILLAGE).as_posix() for path in (VILLAGE / folder).rglob("*")
                    if path.is_file() and not path.name.startswith(".")]
        if not contents:
            raise ValueError(f"No local Village assets in {folder} to verify")
        assets.extend(contents)
    missing = sorted({ROOT + "Village/" + asset for asset in assets} - files)
    if missing:
        raise ValueError("Missing Village resources: " + ", ".join(missing))
    if any("triposg" in path.casefold() for path in files if path.startswith(ROOT)):
        raise ValueError("TripoSG must be excluded from the app")
    rules = [path for path in files
             if path.startswith(ROOT) and path.endswith("CastBrowserFeature.bundle/AdBlockingRules.json")]
    if len(rules) != 1:
        raise ValueError("Missing or ambiguous Underholdning package resources")
    loaded = json.loads(archive.read(rules[0]))
    if not isinstance(loaded, list) or not loaded or any(
        not isinstance(rule, dict) or not {"action", "trigger"} <= rule.keys() for rule in loaded
    ):
        raise ValueError("Invalid Underholdning content rules")


def verify(archive):
    root = ROOT
    info = plistlib.loads(archive.read(root + "Info.plist"))
    executable = root + info["CFBundleExecutable"]
    pending = [(executable, root.rstrip("/"), [])]
    for product, extension_point in (("FadedAIWidgets", "com.apple.widgetkit-extension"),
                                     ("FadedAIShare", "com.apple.share-services")):
        extension_root = root + f"PlugIns/{product}.appex/"
        extension = plistlib.loads(archive.read(extension_root + "Info.plist"))
        extension_executable = extension_root + extension["CFBundleExecutable"]
        if (extension["CFBundleVersion"] != info["CFBundleVersion"]
                or not extension["CFBundleIdentifier"].startswith(info["CFBundleIdentifier"] + ".")):
            raise ValueError(f"{product} and app bundle versions or identifiers do not match")
        if extension.get("NSExtension", {}).get("NSExtensionPointIdentifier") != extension_point:
            raise ValueError(f"{product} declares an unexpected extension point")
        pending.append((extension_executable, extension_root.rstrip("/"), []))
    files = set(archive.namelist())
    verify_resources(archive, files)
    app_paths, _, _ = load_commands(archive.read(executable))
    if "@executable_path/Frameworks" not in app_paths:
        raise ValueError("App cannot find embedded frameworks: missing @executable_path/Frameworks")
    main_binaries = {entry[0] for entry in pending}
    visited = set()
    while pending:
        binary, executable_root, inherited = pending.pop()
        key = (binary, executable_root)
        if key in visited:
            continue
        visited.add(key)
        paths, dependencies, platforms = load_commands(archive.read(binary))
        if platforms and platforms != {2}:
            raise ValueError(f"{binary} was not built for an iPhone device")
        if binary in main_binaries and platforms != {2}:
            raise ValueError(f"{binary} has no iPhone device platform")
        expanded = [posixpath.normpath(path.replace("@executable_path", executable_root)
                                      .replace("@loader_path", posixpath.dirname(binary)))
                    for path in paths] + inherited
        for dependency, weak in dependencies:
            if dependency.startswith(("/System/Library/", "/usr/lib/")):
                continue
            if dependency.startswith("@rpath/"):
                relative = dependency.removeprefix("@rpath/")
                candidates = [posixpath.normpath(path + "/" + relative) for path in expanded]
            else:
                candidates = [posixpath.normpath(dependency.replace("@executable_path", executable_root)
                                               .replace("@loader_path", posixpath.dirname(binary)))]
            resolved = next((candidate for candidate in candidates if candidate in files), None)
            if resolved is not None:
                pending.append((resolved, executable_root, expanded))
            elif not weak:
                raise ValueError(f"{binary} cannot load {dependency}")
    print(f"OK: build {info['CFBundleVersion']}, {len(visited)} arm64 binaries and embedded dependencies.")


if __name__ == "__main__":
    with zipfile.ZipFile(sys.argv[1]) as archive:
        verify(archive)

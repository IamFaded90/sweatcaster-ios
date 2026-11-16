"""Check device framework loading in the final unsigned IPA, without Xcode."""
import plistlib
import posixpath
import struct
import sys
import zipfile


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
    paths, dependencies = [], []
    for _ in range(count):
        command, size = struct.unpack_from("<II", data, position)
        if size < 8 or position + size > len(data):
            raise ValueError("Invalid Mach-O load command")
        if command in (0x8000001C, 0xC, 0x80000018, 0x8000001F):
            offset, = struct.unpack_from("<I", data, position + 8)
            value = data[position + offset:position + size].split(b"\0", 1)[0].decode()
            if command == 0x8000001C:
                paths.append(value)
            else:
                dependencies.append((value, command == 0x80000018))
        position += size
    return paths, dependencies


def verify(archive):
    root = "Payload/FadedAI.app/"
    info = plistlib.loads(archive.read(root + "Info.plist"))
    executable = root + info["CFBundleExecutable"]
    files = set(archive.namelist())
    app_paths, _ = load_commands(archive.read(executable))
    if "@executable_path/Frameworks" not in app_paths:
        raise ValueError("App cannot find embedded frameworks: missing @executable_path/Frameworks")
    pending = [(executable, [])]
    visited = set()
    while pending:
        binary, inherited = pending.pop()
        if binary in visited:
            continue
        visited.add(binary)
        paths, dependencies = load_commands(archive.read(binary))
        expanded = [posixpath.normpath(path.replace("@executable_path", root.rstrip("/"))
                                      .replace("@loader_path", posixpath.dirname(binary)))
                    for path in paths] + inherited
        for dependency, weak in dependencies:
            if dependency.startswith(("/System/Library/", "/usr/lib/")):
                continue
            if dependency.startswith("@rpath/"):
                relative = dependency.removeprefix("@rpath/")
                candidates = [posixpath.normpath(path + "/" + relative) for path in expanded]
            else:
                candidates = [posixpath.normpath(dependency.replace("@executable_path", root.rstrip("/"))
                                               .replace("@loader_path", posixpath.dirname(binary)))]
            resolved = next((candidate for candidate in candidates if candidate in files), None)
            if resolved is not None:
                pending.append((resolved, expanded))
            elif not weak:
                raise ValueError(f"{binary} cannot load {dependency}")
    print(f"OK: build {info['CFBundleVersion']}, {len(visited)} arm64 binaries and embedded dependencies.")


if __name__ == "__main__":
    with zipfile.ZipFile(sys.argv[1]) as archive:
        verify(archive)

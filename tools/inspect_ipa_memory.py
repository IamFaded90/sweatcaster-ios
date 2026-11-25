"""Inspect one IPA's embedded memory-request metadata without extracting or verifying it."""
import argparse
import json
from pathlib import Path
import plistlib
import re
import stat
import struct
import sys
import zipfile
from xml.parsers.expat import ExpatError

MAX_ARCHIVE = 8 * 1024**3
MAX_DIRECTORY = 16 * 1024**2
MAX_EXECUTABLE = 512 * 1024**2
MAX_PLIST = 1024**2
ARM64 = 0x0100000C
MEMORY_KEY = "com.apple.developer.kernel.increased-memory-limit"
NOTICE = ("Metadata only: this does not validate the code signature or provisioning profile, "
          "and does not guarantee available runtime RAM. DER-only entitlements are unknown.")


class InspectionError(ValueError):
    pass


def require(condition, message):
    if not condition:
        raise InspectionError(message)


def archive_bounds(stream):
    stream.seek(0, 2)
    size = stream.tell()
    require(22 <= size <= MAX_ARCHIVE, "IPA size is outside the supported bounds.")
    stream.seek(max(0, size - 65557))
    tail = stream.read(65557)
    position = len(tail)
    while True:
        position = tail.rfind(b"PK\x05\x06", 0, position)
        require(position >= 0, "Missing ZIP end-of-directory record.")
        if position + 22 <= len(tail):
            record = struct.unpack_from("<4s4H2IH", tail, position)
            if position + 22 + record[-1] == len(tail):
                break
    _, disk, directory_disk, disk_count, count, length, offset, _ = record
    require(disk == directory_disk == 0 and disk_count == count,
            "Split ZIP archives are not supported.")
    require(count != 0xFFFF and length != 0xFFFFFFFF and offset != 0xFFFFFFFF,
            "ZIP64 metadata is not supported by this bounded inspector.")
    require(count <= 50000 and length <= MAX_DIRECTORY,
            "ZIP directory exceeds the metadata limit.")
    end_position = size - len(tail) + position
    require(offset + length == end_position, "Invalid ZIP directory bounds.")


def archive_files(archive):
    entries = archive.infolist()
    require(len(entries) <= 50000, "Too many ZIP entries.")
    files = {}
    for entry in entries:
        name = entry.orig_filename
        parts = name.rstrip("/").split("/")
        require(name == entry.filename and len(name) <= 4096 and
                not any(ord(char) < 32 or ord(char) == 127 for char in name) and
                "\\" not in name and ":" not in name and
                all(part not in ("", ".", "..") for part in parts), "Unsafe ZIP entry path.")
        normalized = name.rstrip("/")
        require(normalized not in files, "Duplicate ZIP entry path.")
        files[normalized] = entry
    return files


def bounded_read(archive, entry, limit):
    require(not entry.is_dir() and not stat.S_ISLNK(entry.external_attr >> 16),
            "Selected archive entry is not a regular file.")
    require(not entry.flag_bits & 1 and entry.compress_type in (zipfile.ZIP_STORED, zipfile.ZIP_DEFLATED),
            "Encrypted or unsupported ZIP compression.")
    require(0 < entry.file_size <= limit, "Selected archive entry exceeds its size limit.")
    with archive.open(entry) as source:
        data = source.read(limit + 1)
    require(len(data) == entry.file_size and len(data) <= limit, "Invalid archive entry length.")
    return data


def arm64_slice(binary):
    require(len(binary) >= 8, "Truncated Mach-O header.")
    data = memoryview(binary)
    magic, = struct.unpack_from(">I", data)
    formats = {0xCAFEBABE: (">", False), 0xCAFEBABF: (">", True),
               0xBEBAFECA: ("<", False), 0xBFBAFECA: ("<", True)}
    if magic not in formats:
        return data
    endian, wide = formats[magic]
    count, = struct.unpack_from(endian + "I", data, 4)
    stride = 32 if wide else 20
    table_end = 8 + count * stride
    require(0 < count <= 64 and table_end <= len(data), "Invalid universal binary table.")
    ranges, selected = [], []
    for index in range(count):
        position = 8 + index * stride
        cpu, = struct.unpack_from(endian + "I", data, position)
        offset, size, alignment = struct.unpack_from(endian + ("QQI" if wide else "III"), data, position + 8)
        require(alignment <= 31 and offset >= table_end and size >= 32 and
                offset + size <= len(data) and offset % (1 << alignment) == 0,
                "Invalid universal binary slice bounds.")
        require(all(offset + size <= start or offset >= end for start, end in ranges),
                "Overlapping universal binary slices.")
        ranges.append((offset, offset + size))
        if cpu == ARM64:
            selected.append(data[offset:offset + size])
    require(len(selected) == 1, "Missing or ambiguous arm64 slice.")
    return selected[0]


def signature_blob(binary):
    data = arm64_slice(binary)
    require(len(data) >= 32, "Truncated arm64 Mach-O header.")
    magic, cpu, _, file_type, count, commands_size = struct.unpack_from("<6I", data)
    require(magic == 0xFEEDFACF and cpu == ARM64 and file_type == 2,
            "Expected an arm64 Mach-O executable.")
    commands_end = 32 + commands_size
    require(count <= 4096 and count <= commands_size // 8 and commands_end <= len(data),
            "Invalid Mach-O load-command bounds.")
    position, signature = 32, None
    for _ in range(count):
        require(position + 8 <= commands_end, "Truncated Mach-O load command.")
        command, length = struct.unpack_from("<II", data, position)
        require(length >= 8 and length % 8 == 0 and position + length <= commands_end,
                "Invalid Mach-O load-command length.")
        if command == 0x1D:  # LC_CODE_SIGNATURE; offsets are relative to the selected slice.
            require(signature is None and length == 16, "Duplicate or invalid code-signature command.")
            offset, size = struct.unpack_from("<II", data, position + 8)
            require(offset >= commands_end and size >= 12 and offset + size <= len(data),
                    "Invalid code-signature bounds.")
            signature = data[offset:offset + size]
        position += length
    require(position == commands_end, "Mach-O command count and size disagree.")
    return signature


def memory_request(signature):
    if signature is None:
        return False, False
    magic, length, count = struct.unpack_from(">3I", signature)
    table_end = 12 + count * 8
    require(magic == 0xFADE0CC0 and table_end <= length <= len(signature) and count <= 4096,
            "Invalid embedded-signature superblob.")
    seen, ranges, xml, der = set(), [], None, False
    for index in range(count):
        slot, offset = struct.unpack_from(">II", signature, 12 + index * 8)
        require(slot not in seen, "Duplicate signature blob slot.")
        seen.add(slot)
        require(offset >= table_end and offset + 8 <= length, "Invalid signature blob offset.")
        kind, size = struct.unpack_from(">II", signature, offset)
        require(size >= 8 and offset + size <= length, "Invalid signature blob length.")
        require(all(offset + size <= start or offset >= end for start, end in ranges),
                "Overlapping signature blobs.")
        ranges.append((offset, offset + size))
        if slot == 5 or kind == 0xFADE7171:
            require(slot == 5 and kind == 0xFADE7171 and size <= MAX_PLIST,
                    "Invalid XML entitlement blob.")
            xml = bytes(signature[offset + 8:offset + size])
        if slot == 7 or kind == 0xFADE7172:
            require(slot == 7 and kind == 0xFADE7172, "Invalid DER entitlement blob.")
            der = True
    if xml is None:
        return ("unknown" if der else False), der
    entitlements = plistlib.loads(xml, fmt=plistlib.FMT_XML)
    require(isinstance(entitlements, dict), "Entitlements must be a dictionary.")
    value = entitlements.get(MEMORY_KEY, False)
    return (value if type(value) is bool else "unknown"), der


def inspect_ipa(path):
    with Path(path).open("rb") as stream:
        archive_bounds(stream)
        with zipfile.ZipFile(stream) as archive:
            files = archive_files(archive)
            apps = {name.split("/")[1] for name in files if name.startswith("Payload/") and
                    len(name.split("/")) >= 2 and name.split("/")[1].endswith(".app")}
            require(len(apps) == 1, "Missing or ambiguous main application.")
            root = "Payload/" + apps.pop() + "/"
            require(root + "Info.plist" in files, "Main application Info.plist is missing.")
            info = plistlib.loads(bounded_read(archive, files[root + "Info.plist"], MAX_PLIST))
            require(isinstance(info, dict), "Invalid application Info.plist.")
            executable = info.get("CFBundleExecutable")
            require(isinstance(executable, str) and executable not in ("", ".", "..") and
                    "/" not in executable and "\\" not in executable and root + executable in files,
                    "Invalid or missing main executable.")
            bundle, build = info.get("CFBundleIdentifier"), info.get("CFBundleVersion")
            require(isinstance(bundle, str) and re.fullmatch(r"[A-Za-z0-9.-]{1,255}", bundle) and
                    isinstance(build, str) and re.fullmatch(r"[A-Za-z0-9.-]{1,64}", build),
                    "Invalid bundle identifier or build metadata.")
            binary = bounded_read(archive, files[root + executable], MAX_EXECUTABLE)
    signature = signature_blob(binary)
    request, der = memory_request(signature)
    return {"bundle_id": bundle, "build": build, "code_signature_present": signature is not None,
            "xml_increased_memory_limit": request, "der_entitlements_present": der}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, epilog=NOTICE)
    parser.add_argument("ipa", type=Path, help="Exact IPA file to inspect; never scans directories.")
    parser.add_argument("--require-memory-request", action="store_true",
                        help="Fail unless embedded XML explicitly contains a true memory request.")
    args = parser.parse_args(argv)
    try:
        report = inspect_ipa(args.ipa)
    except InspectionError as error:
        print("Cannot inspect IPA: " + str(error), file=sys.stderr)
        return 2
    except (OSError, ValueError, KeyError, TypeError, struct.error, zipfile.BadZipFile,
            RuntimeError, ExpatError, OverflowError, EOFError):
        print("Cannot inspect IPA: unreadable, malformed or unsupported archive data.", file=sys.stderr)
        return 2
    print(json.dumps(report, indent=2))
    print(NOTICE, file=sys.stderr)
    return 1 if args.require_memory_request and report["xml_increased_memory_limit"] is not True else 0


if __name__ == "__main__":
    sys.exit(main())

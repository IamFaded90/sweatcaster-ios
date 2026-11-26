"""Dependency fixtures for the IPA validator; no SDK or signing account needed."""
from contextlib import redirect_stdout
import io
import plistlib
import struct
import unittest
from unittest.mock import patch
import zipfile

import verify_ipa


def macho(rpaths=(), dependencies=()):
    commands = [struct.pack("<6I", 0x32, 24, 2, 0x120000, 0x120000, 0)]
    for command, offset, values in [(0x8000001C, 12, rpaths), (0xC, 24, dependencies)]:
        for value in values:
            name = value.encode() + b"\0"
            size = (offset + len(name) + 7) // 8 * 8
            body = struct.pack("<3I", command, size, offset) + bytes(offset - 12) + name
            commands.append(body.ljust(size, b"\0"))
    return struct.pack("<8I", 0xFEEDFACF, 0x0100000C, 0, 2, len(commands), sum(map(len, commands)), 0, 0) + b"".join(commands)


def fixture(dependency, rpaths=("/usr/lib/swift",), minimum_os="18.0"):
    buffer = io.BytesIO()
    root = verify_ipa.ROOT
    with zipfile.ZipFile(buffer, "w") as archive:
        archive.writestr(root + "Info.plist", plistlib.dumps({
            "CFBundleIdentifier": "dk.example.app", "CFBundleVersion": "103",
            "CFBundleExecutable": "FadedAI", "MinimumOSVersion": minimum_os,
        }))
        archive.writestr(root + "FadedAI", macho(["@executable_path/Frameworks"], ["@rpath/Test.framework/Test"]))
        archive.writestr(root + "Frameworks/Test.framework/Test", macho(rpaths, [dependency]))
        for product, point in [("FadedAIWidgets", "com.apple.widgetkit-extension"),
                               ("FadedAIShare", "com.apple.share-services"),
                               ("FadedAIBroadcast", "com.apple.broadcast-services-upload")]:
            folder = root + f"PlugIns/{product}.appex/"
            archive.writestr(folder + "Info.plist", plistlib.dumps({
                "CFBundleIdentifier": "dk.example.app." + product, "CFBundleVersion": "103",
                "CFBundleExecutable": product, "NSExtension": {"NSExtensionPointIdentifier": point},
            }))
            archive.writestr(folder + product, macho())
    buffer.seek(0)
    return buffer


class VerifyIPADependencyTests(unittest.TestCase):
    def verify(self, **kwargs):
        with zipfile.ZipFile(fixture(**kwargs)) as archive, patch.object(verify_ipa, "verify_resources"), redirect_stdout(io.StringIO()):
            verify_ipa.verify(archive)

    def test_system_swift_runtime_rpaths_are_valid_for_ios18(self):
        for library in ["libswiftCore.dylib", "libswift_Concurrency.dylib"]:
            with self.subTest(library=library):
                self.verify(dependency="@rpath/" + library)

    def test_missing_app_framework_is_still_rejected(self):
        for framework in ["OfflineSongRuntime", "whisper"]:
            with self.subTest(framework=framework), self.assertRaisesRegex(ValueError, "cannot load"):
                self.verify(dependency=f"@rpath/{framework}.framework/{framework}")

    def test_unknown_swift_library_cannot_masquerade_as_system_runtime(self):
        with self.assertRaisesRegex(ValueError, "cannot load"):
            self.verify(dependency="@rpath/libswiftNotShipped.dylib")

    def test_system_library_must_have_a_matching_rpath(self):
        with self.assertRaisesRegex(ValueError, "cannot load"):
            self.verify(dependency="@rpath/libswiftCore.dylib", rpaths=["/tmp"])

    def test_os_must_actually_provide_the_requested_runtime(self):
        for library, minimum in [("libswiftCore.dylib", "12.1"), ("libswift_Concurrency.dylib", "14.0")]:
            with self.subTest(library=library), self.assertRaisesRegex(ValueError, "cannot load"):
                self.verify(dependency="@rpath/" + library, minimum_os=minimum)

    def test_missing_or_invalid_minimum_os_does_not_bypass_validation(self):
        for minimum in ["", "unknown"]:
            with self.subTest(minimum=minimum), self.assertRaisesRegex(ValueError, "cannot load"):
                self.verify(dependency="@rpath/libswiftCore.dylib", minimum_os=minimum)


if __name__ == "__main__":
    unittest.main()

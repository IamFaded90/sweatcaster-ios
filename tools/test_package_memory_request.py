"""Packaging boundaries only; native signer execution is mocked in these unit tests."""
from contextlib import contextmanager
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import zipfile

import inspect_ipa_memory as inspector
import package_memory_request as packager
from test_inspect_ipa_memory import superblob, thin, xml


class PackageMemoryRequestTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name)
        self.source, self.output = root / "original.ipa", root / "memory-request.ipa"
        self.entitlements = root / "request.plist"
        self.entitlements.write_bytes(plistlib.dumps({packager.MEMORY_KEY: True}))
        info = {"CFBundleExecutable": "FadedAI", "CFBundleIdentifier": "dk.example.FadedAI",
                "CFBundleVersion": "94"}
        self.binary = "Payload/FadedAI.app/FadedAI"
        with zipfile.ZipFile(self.source, "w", compression=zipfile.ZIP_DEFLATED) as archive:
            archive.writestr(packager.MAIN_INFO, plistlib.dumps(info))
            archive.writestr(self.binary, thin())
            archive.writestr("Payload/FadedAI.app/PlugIns/Widget.appex/preserved", b"extension")
            archive.writestr("Payload/FadedAI.app/Assets/preserved", b"artwork")
        self.original = self.source.read_bytes()

    @contextmanager
    def simulated_codesign(self, include_request=True):
        def run(arguments, **_):
            if "--sign" in arguments:
                Path(arguments[-1]).write_bytes(thin(superblob([(5, xml(include_request))])))
            # Deliberately let --display claim true even for the incorrect-output test.
            claimed = plistlib.dumps({packager.MEMORY_KEY: True}) if "--display" in arguments else b""
            return subprocess.CompletedProcess(arguments, 0, stdout=claimed, stderr=b"")

        with patch.object(packager.sys, "platform", "darwin"), \
                patch.object(packager.shutil, "which", return_value="/mock/codesign"), \
                patch.object(packager.subprocess, "run", side_effect=run) as boundary:
            yield boundary

    def test_copy_retains_every_other_entry_and_original_archive(self):
        with self.simulated_codesign() as boundary:
            packager.prepare(self.source, self.output, self.entitlements)
        self.assertEqual(boundary.call_count, 3)
        self.assertEqual(self.source.read_bytes(), self.original)
        self.assertIs(inspector.inspect_ipa(self.output)["xml_increased_memory_limit"], True)
        with zipfile.ZipFile(self.source) as original, zipfile.ZipFile(self.output) as prepared:
            self.assertEqual(original.namelist(), prepared.namelist())
            for name in original.namelist():
                if name == self.binary:
                    self.assertNotEqual(original.read(name), prepared.read(name))
                else:
                    self.assertEqual(original.read(name), prepared.read(name))

    def test_wrong_signer_output_is_not_published(self):
        with self.simulated_codesign(include_request=False):
            with self.assertRaises(ValueError):
                packager.prepare(self.source, self.output, self.entitlements)
        self.assertFalse(self.output.exists())
        self.assertEqual(self.source.read_bytes(), self.original)

    def test_existing_destination_is_never_overwritten(self):
        self.output.write_bytes(b"keep-existing-download")
        with self.simulated_codesign() as boundary:
            with self.assertRaises(ValueError):
                packager.prepare(self.source, self.output, self.entitlements)
        boundary.assert_not_called()
        self.assertEqual(self.output.read_bytes(), b"keep-existing-download")
        self.assertEqual(self.source.read_bytes(), self.original)

    def test_nonmac_platform_refuses_without_modifying_original(self):
        with patch.object(packager.sys, "platform", "win32"), \
                patch.object(packager.shutil, "which", return_value=None), \
                patch.object(packager.subprocess, "run") as boundary:
            with self.assertRaises(ValueError):
                packager.prepare(self.source, self.output, self.entitlements)
        boundary.assert_not_called()
        self.assertFalse(self.output.exists())
        self.assertEqual(self.source.read_bytes(), self.original)

    def test_explicit_ldid_backend_preserves_archive_on_linux(self):
        executable = self.source.parent / "ldid"
        executable.write_bytes(b"mock executable")
        executable.chmod(0o755)

        def run(arguments, **_):
            if arguments[1].startswith("-S"):
                Path(arguments[-1]).write_bytes(thin(superblob([(5, xml(True))])))
            return subprocess.CompletedProcess(arguments, 0,
                stdout=plistlib.dumps({packager.MEMORY_KEY: True}), stderr=b"")

        with patch.object(packager.sys, "platform", "linux"), \
                patch.object(packager.os, "access", return_value=True), \
                patch.object(packager.subprocess, "run", side_effect=run) as boundary:
            packager.prepare(self.source, self.output, self.entitlements, ldid=executable)
        self.assertEqual(boundary.call_count, 2)
        self.assertEqual(self.source.read_bytes(), self.original)
        self.assertIs(inspector.inspect_ipa(self.output)["xml_increased_memory_limit"], True)


if __name__ == "__main__":
    unittest.main()

from contextlib import redirect_stdout
import hashlib
import io
from pathlib import Path
import plistlib
import tempfile
import unittest
import zipfile

from repackage_ipa import INFOS, ROOT, repackage


class RepackageIPATests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.source, self.output = self.root / "original.ipa", self.root / "new.ipa"

    def fixture(self, omit=None):
        with zipfile.ZipFile(self.source, "w") as archive:
            for name in sorted(INFOS - {omit}):
                archive.writestr(name, plistlib.dumps({"CFBundleVersion": "102", "CFBundleExecutable": "test", "untouched": "saved"}, fmt=plistlib.FMT_BINARY))
            for name in [ROOT + "FadedAI", ROOT + "Frameworks/Song.framework/Song"]:
                info = zipfile.ZipInfo(name)
                info.create_system = 3
                info.external_attr = 0o100755 << 16
                info.compress_type = zipfile.ZIP_DEFLATED
                archive.writestr(info, b"unchanged compiled binary")
        self.digest = hashlib.sha256(self.source.read_bytes()).hexdigest()

    def run_repackage(self, version="103", digest=None):
        with redirect_stdout(io.StringIO()):
            repackage(self.source, self.output, version, digest or self.digest)

    def test_changes_all_four_build_numbers_and_preserves_executables_and_permissions(self):
        self.fixture()
        original_bytes = self.source.read_bytes()
        self.run_repackage()
        with zipfile.ZipFile(self.source) as before, zipfile.ZipFile(self.output) as after:
            self.assertEqual(before.namelist(), after.namelist())
            for name in before.namelist():
                if name in INFOS:
                    info = plistlib.loads(after.read(name))
                    expected = plistlib.loads(before.read(name))
                    expected["CFBundleVersion"] = "103"
                    self.assertEqual(info, expected)
                else:
                    self.assertEqual(before.read(name), after.read(name))
                self.assertEqual(before.getinfo(name).external_attr, after.getinfo(name).external_attr)
                self.assertEqual(before.getinfo(name).compress_type, after.getinfo(name).compress_type)
        self.assertEqual(original_bytes, self.source.read_bytes())

    def test_rejects_a_different_source_artifact_before_writing_output(self):
        self.fixture()
        with self.assertRaisesRegex(ValueError, "verified native build"):
            self.run_repackage(digest="0" * 64)
        self.assertFalse(self.output.exists())

    def test_requires_all_app_extension_versions(self):
        self.fixture(omit=ROOT + "PlugIns/FadedAIShare.appex/Info.plist")
        with self.assertRaisesRegex(ValueError, "four bundle plists"):
            self.run_repackage()
        self.assertFalse(self.output.exists())

    def test_never_overwrites_existing_output(self):
        self.fixture()
        self.output.write_bytes(b"keep this download")
        with self.assertRaisesRegex(ValueError, "new file"):
            self.run_repackage()
        self.assertEqual(self.output.read_bytes(), b"keep this download")

    def test_rejects_invalid_build_versions(self):
        self.fixture()
        for version in ["", "103-fix", "1.2.3.4"]:
            with self.subTest(version=version), self.assertRaisesRegex(ValueError, "numeric"):
                self.run_repackage(version=version)


if __name__ == "__main__":
    unittest.main()

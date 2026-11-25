import tempfile
from pathlib import Path
import unittest

from report_xcode_errors import annotations


class XcodeAnnotationsTests(unittest.TestCase):
    def test_swift_locations_and_duplicate_diagnostics(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            log = root / "test.log"
            error = f"{root / 'App/Home.swift'}:42:7: error: missing value"
            log.write_text(f"warning: ignored\n\033[31m{error}\033[0m\n{error}\n", encoding="utf-8")
            self.assertEqual(list(annotations([root / "missing", log], root)),
                             ["::error file=App/Home.swift,line=42::missing value"])

    def test_linker_failures_redact_credentials_and_escape_annotations(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            log = root / "device.log"
            log.write_text("ld: failed https://user:password@github.com/file ghp_secret123 5%\n"
                           "clang++: error: linker command failed\n", encoding="utf-8")
            messages = list(annotations([log], root))
            self.assertEqual(messages, ["::error::ld: failed [skjult]github.com/file [skjult] 5%25",
                                        "::error::clang++: error: linker command failed"])

    def test_outside_workspace_and_output_limit(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            log = root / "device.log"
            log.write_text("../External.swift:9: error: dependency error\n" +
                           "\n".join(f"error: failure {number}" for number in range(20)), encoding="utf-8")
            messages = list(annotations([log], root, limit=3))
            self.assertEqual(messages, ["::error::dependency error", "::error::error: failure 0", "::error::error: failure 1"])


if __name__ == "__main__":
    unittest.main()

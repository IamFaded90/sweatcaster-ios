"""Synthetic ZIP/Mach-O fixtures; no signing account or installed IPA is accessed."""
from contextlib import redirect_stderr, redirect_stdout
import io
from pathlib import Path
import plistlib
import struct
import tempfile
import unittest
import warnings
import zipfile

import inspect_ipa_memory as inspector


def blob(slot, body):
    magic = {5: 0xFADE7171, 7: 0xFADE7172}.get(slot, 0xFADE0C02)
    return struct.pack(">II", magic, 8 + len(body)) + body


def superblob(slots):
    offset = 12 + 8 * len(slots)
    indexes, bodies = [], []
    for slot, body in slots:
        part = blob(slot, body)
        indexes.append(struct.pack(">II", slot, offset))
        bodies.append(part)
        offset += len(part)
    return struct.pack(">III", 0xFADE0CC0, offset, len(slots)) + b"".join(indexes + bodies)


def thin(signature=None):
    count, command_size = (0, 0) if signature is None else (1, 16)
    header = struct.pack("<8I", 0xFEEDFACF, inspector.ARM64, 0, 2, count, command_size, 0, 0)
    if signature is None:
        return header
    return header + struct.pack("<4I", 0x1D, 16, 64, len(signature)) + bytes(16) + signature


def xml(value=True):
    return plistlib.dumps({inspector.MEMORY_KEY: value, "private-test-key": "must-not-be-reported"})


def fat(binary, wide=False, endian=">"):
    # A second architecture before arm64 exposes accidental use of whole-file offsets.
    magic = 0xCAFEBABF if wide else 0xCAFEBABE
    first = bytearray(thin())
    struct.pack_into("<I", first, 4, 0x01000007)
    layout = "IIQQII" if wide else "IIIII"
    rows = []
    for cpu, offset, length in [(0x01000007, 1024, len(first)), (inspector.ARM64, 2048, len(binary))]:
        fields = [cpu, 0, offset, length, 9] + ([0] if wide else [])
        rows.append(struct.pack(endian + layout, *fields))
    result = bytearray(struct.pack(endian + "II", magic, 2) + b"".join(rows))
    result.extend(bytes(1024 - len(result)))
    result.extend(first)
    result.extend(bytes(2048 - len(result)))
    return bytes(result) + binary


class InspectIPAMemoryTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.path = Path(self.temporary.name) / "fixture.ipa"

    def write_ipa(self, executable, extras=(), info=None):
        info = info or {"CFBundleIdentifier": "dk.example.FadedAI", "CFBundleVersion": "94",
                        "CFBundleExecutable": "FadedAI"}
        with warnings.catch_warnings():
            warnings.simplefilter("ignore", UserWarning)
            with zipfile.ZipFile(self.path, "w", compression=zipfile.ZIP_DEFLATED) as archive:
                archive.writestr("Payload/FadedAI.app/Info.plist", plistlib.dumps(info))
                archive.writestr("Payload/FadedAI.app/FadedAI", executable)
                for name, data in extras:
                    archive.writestr(name, data)
        return self.path

    def test_unsigned_input_reports_no_request(self):
        report = inspector.inspect_ipa(self.write_ipa(thin()))
        self.assertEqual(report, {"bundle_id": "dk.example.FadedAI", "build": "94",
                                  "code_signature_present": False,
                                  "xml_increased_memory_limit": False, "der_entitlements_present": False})

    def test_xml_boolean_true_false_and_absent_key(self):
        for content, expected in [(xml(True), True), (xml(False), False), (plistlib.dumps({}), False)]:
            with self.subTest(expected=expected, content=content):
                report = inspector.inspect_ipa(self.write_ipa(thin(superblob([(5, content)]))))
                self.assertTrue(report["code_signature_present"])
                self.assertIs(report["xml_increased_memory_limit"], expected)

    def test_der_only_is_unknown_and_xml_with_der_is_reported(self):
        for slots, expected in [([(7, b"\x30\x00")], "unknown"),
                                ([(5, xml()), (7, b"\x30\x00")], True)]:
            report = inspector.inspect_ipa(self.write_ipa(thin(superblob(slots))))
            self.assertEqual(report["xml_increased_memory_limit"], expected)
            self.assertTrue(report["der_entitlements_present"])

    def test_nonboolean_memory_value_is_not_treated_as_true(self):
        for value in [1, "true"]:
            report = inspector.inspect_ipa(self.write_ipa(thin(superblob([(5, xml(value))]))))
            self.assertEqual(report["xml_increased_memory_limit"], "unknown")

    def test_fat_arm64_signature_uses_slice_relative_offset(self):
        binary = thin(superblob([(5, xml())]))
        for wide in [False, True]:
            for endian in [">", "<"]:
                with self.subTest(wide=wide, endian=endian):
                    report = inspector.inspect_ipa(self.write_ipa(fat(binary, wide, endian)))
                    self.assertIs(report["xml_increased_memory_limit"], True)

    def test_require_flag_and_output_do_not_claim_signature_validation(self):
        for slots, expected in [(None, 1), ([(5, xml(True))], 0), ([(5, xml(False))], 1),
                                ([(7, b"\x30\x00")], 1)]:
            self.write_ipa(thin(None if slots is None else superblob(slots)))
            output, errors = io.StringIO(), io.StringIO()
            with redirect_stdout(output), redirect_stderr(errors):
                status = inspector.main([str(self.path), "--require-memory-request"])
            self.assertEqual(status, expected)
            self.assertNotIn("must-not-be-reported", output.getvalue() + errors.getvalue())
            self.assertIn("does not validate", errors.getvalue())
            self.assertIn("does not guarantee", errors.getvalue())

    def test_bad_signature_and_fat_offsets_are_rejected(self):
        signed = thin(superblob([(5, xml())]))
        bad_signature = bytearray(signed)
        struct.pack_into("<I", bad_signature, 40, len(signed) + 1)
        bad_fat = bytearray(fat(signed))
        struct.pack_into(">I", bad_fat, 36, len(bad_fat) + 1)
        bad_blob = bytearray(signed)
        struct.pack_into(">I", bad_blob, 64 + 16, 8)  # Inside its own index table.
        for binary in [bad_signature, bad_fat, bad_blob]:
            with self.subTest(length=len(binary)):
                with self.assertRaises(inspector.InspectionError):
                    inspector.inspect_ipa(self.write_ipa(binary))

    def test_duplicate_signature_command_or_entitlement_slot_is_rejected(self):
        signature = superblob([(5, xml())])
        duplicate_command = bytearray(thin(signature))
        struct.pack_into("<II", duplicate_command, 16, 2, 32)
        duplicate_command[48:64] = duplicate_command[32:48]
        for binary in [duplicate_command, thin(superblob([(5, xml()), (5, xml(False))]))]:
            with self.assertRaises(inspector.InspectionError):
                inspector.inspect_ipa(self.write_ipa(binary))

    def test_ambiguous_main_apps_duplicate_entries_and_unsafe_paths_are_rejected(self):
        for extra in [("Payload/Other.app/Info.plist", b"unused"),
                      ("Payload/FadedAI.app/FadedAI", thin()), ("../outside", b"unused")]:
            with self.subTest(path=extra[0]):
                with self.assertRaises(inspector.InspectionError):
                    inspector.inspect_ipa(self.write_ipa(thin(), [extra]))

    def test_zip_directory_bounds_are_checked_before_opening(self):
        self.write_ipa(thin())
        data = bytearray(self.path.read_bytes())
        struct.pack_into("<I", data, len(data) - 22 + 12, inspector.MAX_DIRECTORY + 1)
        self.path.write_bytes(data)
        with self.assertRaises(inspector.InspectionError):
            inspector.inspect_ipa(self.path)

    def test_invalid_xml_returns_a_safe_cli_error_without_echoing_payload(self):
        self.write_ipa(thin(superblob([(5, b"<private-test-secret")])))
        output, errors = io.StringIO(), io.StringIO()
        with redirect_stdout(output), redirect_stderr(errors):
            status = inspector.main([str(self.path)])
        self.assertEqual(status, 2)
        self.assertEqual(output.getvalue(), "")
        self.assertNotIn("private-test-secret", errors.getvalue())


if __name__ == "__main__":
    unittest.main()

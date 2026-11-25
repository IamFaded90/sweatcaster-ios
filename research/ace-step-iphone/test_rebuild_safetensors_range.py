"""Synthetic tests for the research safetensors range reconstructor."""
import hashlib
import json
from pathlib import Path
import struct
import tempfile
import unittest

from safetensors import safe_open
import torch

from rebuild_safetensors_range import rebuild


class RebuildTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.data = struct.pack("<9H", 0, 0, 0x3f80, 0x4000, 0x4040, 0x4080, 0x40a0, 0x40c0, 0x40e0)
        self.doc = {"__metadata__": {"format": "pt"},
                    "decoder.a": {"dtype": "BF16", "shape": [2], "data_offsets": [0, 4]},
                    "encoder.a": {"dtype": "BF16", "shape": [3], "data_offsets": [4, 10]},
                    "encoder.b": {"dtype": "BF16", "shape": [2, 2], "data_offsets": [10, 18]}}
        self.header = self.root / "header.bin"
        self.fragment = self.root / "fragment.bin"
        self.original = self.root / "original.safetensors"
        self.output = self.root / "output.safetensors"
        self.fragment.write_bytes(self.data[4:])
        self._header(self.doc)

    def tearDown(self):
        self.temp.cleanup()

    def _header(self, document=None, raw=None):
        body = raw if raw is not None else json.dumps(document, separators=(",", ":")).encode()
        body += b" " * (-len(body) % 8)
        full = struct.pack("<Q", len(body)) + body
        self.header.write_bytes(full)
        self.original.write_bytes(full + self.data)
        self.header_sha = hashlib.sha256(full).hexdigest()
        self.component = {"safetensors_header_bytes": len(body), "tensor_prefix": "encoder.",
                          "tensor_count": 2, "tensor_dtype": "BF16",
                          "range_start_inclusive": len(full) + 4,
                          "range_end_inclusive": len(full) + len(self.data) - 1,
                          "range_bytes": len(self.data) - 4,
                          "range_sha256": hashlib.sha256(self.data[4:]).hexdigest()}

    def run_rebuild(self, output=None):
        rebuild(self.component, self.header, self.fragment, output or self.output, self.header_sha)

    def test_valid_subset_matches_original_and_is_deterministic(self):
        self.run_rebuild()
        other = self.root / "other.safetensors"
        self.run_rebuild(other)
        self.assertEqual(self.output.read_bytes(), other.read_bytes())
        with safe_open(str(self.original), framework="pt", device="cpu") as original, \
             safe_open(str(self.output), framework="pt", device="cpu") as rebuilt:
            self.assertEqual(set(rebuilt.keys()), {"encoder.a", "encoder.b"})
            self.assertEqual(rebuilt.metadata(), {"format": "pt"})
            for name in rebuilt.keys():
                self.assertTrue(torch.equal(original.get_tensor(name), rebuilt.get_tensor(name)))
        self.assertEqual(self.fragment.read_bytes(), self.data[4:])

    def test_rejects_wrong_header_digest_without_creating_output(self):
        with self.assertRaisesRegex(ValueError, "Header SHA-256"):
            rebuild(self.component, self.header, self.fragment, self.output, "0" * 64)
        self.assertFalse(self.output.exists())

    def test_rejects_corrupt_range_without_creating_output(self):
        damaged = bytearray(self.fragment.read_bytes())
        damaged[0] ^= 1
        self.fragment.write_bytes(damaged)
        with self.assertRaisesRegex(ValueError, "SHA-256 mismatch"):
            self.run_rebuild()
        self.assertFalse(self.output.exists())

    def test_rejects_mismatched_shape(self):
        self.doc["encoder.b"]["shape"] = [3, 2]
        self._header(self.doc)
        with self.assertRaisesRegex(ValueError, "Shape/offset"):
            self.run_rebuild()
        self.assertFalse(self.output.exists())

    def test_rejects_gaps_and_wrong_count(self):
        self.doc["encoder.b"]["data_offsets"] = [12, 20]
        self._header(self.doc)
        with self.assertRaisesRegex(ValueError, "not contiguous"):
            self.run_rebuild()
        self.component["tensor_count"] = 99
        with self.assertRaisesRegex(ValueError, "count mismatch"):
            self.run_rebuild()

    def test_rejects_duplicate_json_keys(self):
        self._header(raw=b'{"encoder.a":{},"encoder.a":{}}')
        with self.assertRaisesRegex(ValueError, "Duplicate JSON key"):
            self.run_rebuild()

    def test_rejects_overwrite_and_preserves_inputs(self):
        self.output.write_bytes(b"keep")
        header_before = self.header.read_bytes()
        original_before = self.original.read_bytes()
        with self.assertRaises(FileExistsError):
            self.run_rebuild()
        self.assertEqual(self.output.read_bytes(), b"keep")
        self.assertEqual(self.header.read_bytes(), header_before)
        self.assertEqual(self.original.read_bytes(), original_before)

    def test_rejects_dtype_and_header_length_mismatch(self):
        self.doc["encoder.a"]["dtype"] = "F16"
        self._header(self.doc)
        with self.assertRaisesRegex(ValueError, "Unsupported dtype"):
            self.run_rebuild()
        self.component["safetensors_header_bytes"] += 8
        with self.assertRaisesRegex(ValueError, "header length"):
            self.run_rebuild()


if __name__ == "__main__":
    unittest.main(verbosity=2)

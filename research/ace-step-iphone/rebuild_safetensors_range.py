"""Rebuild an independent safetensors file from a pinned header and data range.

Research-only proof of format. Requires an independently trusted SHA-256 of the
complete original header (8-byte length field plus JSON) as well as the
selected range digest in the manifest. The latter is locally derived from a
verified whole file, not an independently published official range digest.
The result keeps original tensor names, dtypes and bytes; it does not perform
the VAE weight-normalization or layout conversion required by the Swift port.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import struct
import tempfile

MAX_HEADER_BYTES = 100_000_000
CHUNK = 1024 * 1024


def _object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"Duplicate JSON key: {key}")
        result[key] = value
    return result


def rebuild(component: dict, header: Path, fragment: Path, output: Path,
            header_sha256: str) -> None:
    """Validate inputs and create a new file without overwriting any path."""
    header = header.resolve(strict=True)
    fragment = fragment.resolve(strict=True)
    if not output.parent.is_dir():
        raise ValueError("Output directory does not exist")
    if output.exists() or output.is_symlink():
        raise FileExistsError(output)
    # Header digest must come from a trusted, separately pinned record; deriving
    # it from the same downloaded header would not establish its provenance.
    if len(header_sha256) != 64 or any(c not in "0123456789abcdef" for c in header_sha256):
        raise ValueError("A pinned lowercase SHA-256 for the complete header is required")
    with header.open("rb") as source:
        raw_length = source.read(8)
        if len(raw_length) != 8:
            raise ValueError("Missing safetensors header length")
        length = struct.unpack("<Q", raw_length)[0]
        if length > MAX_HEADER_BYTES or length != component["safetensors_header_bytes"]:
            raise ValueError("Unexpected safetensors header length")
        body = source.read(length)
        if len(body) != length or source.read(1):
            raise ValueError("Header must contain exactly the length prefix and JSON")
        if hashlib.sha256(raw_length + body).hexdigest() != header_sha256:
            raise ValueError("Header SHA-256 mismatch")
    document = json.loads(body.decode("utf-8"), object_pairs_hook=_object)
    if not isinstance(document, dict):
        raise ValueError("Header is not a JSON object")
    prefix = component["tensor_prefix"]
    start = component["range_start_inclusive"]
    end = component["range_end_inclusive"]
    data_start = length + 8
    if end < start or end - start + 1 != component["range_bytes"]:
        raise ValueError("Invalid range in manifest")
    if fragment.stat().st_size != component["range_bytes"]:
        raise ValueError("Range size mismatch")

    metadata = document.get("__metadata__", {})
    if not isinstance(metadata, dict) or any(not isinstance(k, str) or not isinstance(v, str) for k, v in metadata.items()):
        raise ValueError("Invalid metadata")
    selected = []
    for name, tensor in document.items():
        if name == "__metadata__" or not name.startswith(prefix):
            continue
        if not isinstance(tensor, dict) or set(tensor) != {"dtype", "shape", "data_offsets"}:
            raise ValueError(f"Invalid descriptor for {name}")
        if tensor["dtype"] != component["tensor_dtype"] or tensor["dtype"] != "BF16":
            raise ValueError(f"Unsupported dtype for {name}")
        shape, offsets = tensor["shape"], tensor["data_offsets"]
        if not isinstance(shape, list) or any(type(v) is not int or v < 0 for v in shape):
            raise ValueError(f"Invalid shape for {name}")
        if not isinstance(offsets, list) or len(offsets) != 2 or any(type(v) is not int or v < 0 for v in offsets):
            raise ValueError(f"Invalid offsets for {name}")
        a, b = offsets
        elements = 1
        for dimension in shape:
            elements *= dimension
            if elements * 2 > component["range_bytes"]:
                raise ValueError(f"Oversized tensor: {name}")
        if b < a or b - a != elements * 2:
            raise ValueError(f"Shape/offset size mismatch for {name}")
        selected.append((a, b, name, shape))
    if len(selected) != component["tensor_count"]:
        raise ValueError("Tensor count mismatch")
    selected.sort()
    cursor = start - data_start
    if cursor < 0:
        raise ValueError("Range overlaps header")
    result = {}
    if metadata:
        result["__metadata__"] = metadata
    for a, b, name, shape in selected:
        if a != cursor:
            raise ValueError("Selected tensors are not contiguous in the trusted range")
        result[name] = {"dtype": "BF16", "shape": shape,
                        "data_offsets": [a - (start - data_start), b - (start - data_start)]}
        cursor = b
    if cursor != end + 1 - data_start:
        raise ValueError("Selected tensors do not exactly cover the trusted range")

    encoded = json.dumps(result, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
    encoded += b" " * (-len(encoded) % 8)
    # Prepare and flush a sibling temporary file. On Windows os.rename fails
    # if the destination exists; on POSIX use a hard link, which is likewise
    # exclusive (POSIX rename itself could replace an existing destination).
    fd, temp_name = tempfile.mkstemp(prefix=".range-rebuild-", dir=output.parent)
    temporary = Path(temp_name)
    try:
        with os.fdopen(fd, "wb") as dest, fragment.open("rb") as source:
            dest.write(struct.pack("<Q", len(encoded)))
            dest.write(encoded)
            digest = hashlib.sha256()
            count = 0
            for block in iter(lambda: source.read(CHUNK), b""):
                count += len(block)
                if count > component["range_bytes"]:
                    raise ValueError("Range grew during reconstruction")
                digest.update(block)
                dest.write(block)
            if count != component["range_bytes"] or digest.hexdigest() != component["range_sha256"]:
                raise ValueError("Range size or SHA-256 mismatch")
            dest.flush()
            os.fsync(dest.fileno())
        if os.name == "nt":
            os.rename(temporary, output)
        else:
            os.link(temporary, output)
    finally:
        temporary.unlink(missing_ok=True)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("manifest", type=Path)
    parser.add_argument("component", help="component name within manifest")
    parser.add_argument("header", type=Path, help="8-byte length followed by the complete header JSON")
    parser.add_argument("range_file", type=Path, help="raw verified contiguous tensor-data range")
    parser.add_argument("output", type=Path, help="new output path; existing files are never replaced")
    parser.add_argument("--header-sha256", required=True, help="pinned hash of length prefix + header JSON")
    args = parser.parse_args()
    manifest = json.loads(args.manifest.read_text(encoding="utf-8"), object_pairs_hook=_object)
    matches = [item for item in manifest["components"] if item["component"] == args.component]
    if len(matches) != 1:
        raise ValueError("Component not uniquely present in manifest")
    rebuild(matches[0], args.header, args.range_file, args.output, args.header_sha256)
    print(f"Created {args.output}: original BF16 tensors; no weight conversion performed.")


if __name__ == "__main__":
    main()

"""Prepare isolated local ranges for PhoneSongReferenceEndToEndChecks.swift.

Requires original ACE-Step VAE and turbo files. Creates a NEW directory only,
checks the extracted headers/ranges against research pins, and never modifies
source files. The caller owns cleanup of this directory after the test.
"""
import argparse
import hashlib
import json
from pathlib import Path


def copy_checked(source, destination, offset, count, expected):
    sha = hashlib.sha256()
    with source.open("rb") as src, destination.open("xb") as dst:
        src.seek(offset)
        remaining = count
        while remaining:
            block = src.read(min(1024 * 1024, remaining))
            if not block:
                raise ValueError(f"Short input: {source}")
            sha.update(block)
            dst.write(block)
            remaining -= len(block)
    if sha.hexdigest() != expected:
        raise ValueError(f"Fixture SHA-256 mismatch: {destination.name}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--vae", type=Path, required=True)
    parser.add_argument("--tokenizer", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True, help="New isolated directory")
    args = parser.parse_args()
    here = Path(__file__).resolve().parent
    manifest = json.loads((here / "official-range-manifest.json").read_text(encoding="utf-8"))
    pins = json.loads((here / "locally-derived-header-digests.json").read_text(encoding="utf-8"))
    if hashlib.sha256((here / "official-range-manifest.json").read_bytes()).hexdigest() != pins["range_manifest_sha256"]:
        raise ValueError("Research manifest hash differs from header-digest record")
    components = {item["component"]: item for item in manifest["components"]}
    args.output.mkdir(parents=False, exist_ok=False)
    (args.output / "home").mkdir()
    for source, key, name in [(args.vae, "vae_audio_encoder", "vae"),
                              (args.tokenizer, "audio_fsq_tokenizer", "tokenizer")]:
        info = components[key]
        source = source.resolve(strict=True)
        if source.stat().st_size != info["source_file_bytes"]:
            raise ValueError(f"Unexpected source size: {source}")
        header_pin = pins["components"][key]
        copy_checked(source, args.output / (name + "-header"), 0,
                     header_pin["header_bytes_including_length"], header_pin["header_sha256"])
        copy_checked(source, args.output / (name + "-range"), info["range_start_inclusive"],
                     info["range_bytes"], info["range_sha256"])
    print(f"Prepared verified local fixtures in {args.output}")


if __name__ == "__main__":
    main()

"""Install the allowlisted SDXL checkpoint used by Lumi's PC image route."""

from __future__ import annotations

import hashlib
import os
from pathlib import Path

import requests

URL = ("https://huggingface.co/SG161222/RealVisXL_V5.0/resolve/main/"
       "RealVisXL_V5.0_fp16.safetensors?download=true")
SHA256 = "6a35a7855770ae9820a3c931d4964c3817b6d9e3c6f9c4dabb5b3a94e5643b80"
NAME = "RealVisXL_V5.0_fp16.safetensors"
MAX_BYTES = 7_100_000_000


def install(folder: Path) -> Path:
    folder = folder.resolve(strict=True)
    if folder.name != "checkpoints" or folder.parent.name != "models":
        raise ValueError("Choose the ComfyUI/models/checkpoints folder.")
    target = folder / NAME
    if target.is_file() and digest(target) == SHA256:
        return target
    partial = folder / (NAME + ".part")
    offset = partial.stat().st_size if partial.exists() else 0
    if offset > MAX_BYTES:
        raise ValueError("The partial download is too large.")
    headers = {"Range": f"bytes={offset}-"} if offset else {}
    with requests.Session() as client:
        client.trust_env = False
        with client.get(URL, headers=headers, stream=True, timeout=(10, 60), allow_redirects=True) as response:
            response.raise_for_status()
            if offset and response.status_code != 206:
                offset = 0
            mode = "ab" if offset else "wb"
            total = offset
            next_report = ((total // 1_000_000_000) + 1) * 1_000_000_000
            with partial.open(mode) as output:
                for chunk in response.iter_content(chunk_size=4 * 1024 * 1024):
                    if not chunk:
                        continue
                    total += len(chunk)
                    if total > MAX_BYTES:
                        raise ValueError("The model download exceeded its expected size.")
                    output.write(chunk)
                    if total >= next_report:
                        print(f"Downloaded {total / 1_000_000_000:.1f} GB", flush=True)
                        next_report += 1_000_000_000
    if digest(partial) != SHA256:
        raise ValueError("The model checksum did not match the publisher's file.")
    os.replace(partial, target)
    return target


def digest(path: Path) -> str:
    checksum = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(4 * 1024 * 1024), b""):
            checksum.update(block)
    return checksum.hexdigest()


if __name__ == "__main__":
    import argparse

    parser = argparse.ArgumentParser()
    parser.add_argument("folder", type=Path)
    print(install(parser.parse_args().folder))

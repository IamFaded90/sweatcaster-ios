"""Download Comfy-Org's Wan 2.1 1.3B video assets with publisher checksums."""

from __future__ import annotations

import hashlib
import os
from pathlib import Path

import requests


FILES = (
    ("text_encoders", "umt5_xxl_fp8_e4m3fn_scaled.safetensors",
     "c3355d30191f1f066b26d93fba017ae9809dce6c627dda5f6a66eaa651204f68", 6_740_000_000),
    ("diffusion_models", "wan2.1_t2v_1.3B_fp16.safetensors",
     "be531024cd9018cb5b48c40cfbb6a6191645b1c792eb8bf4f8c1c6e10f924dc5", 2_840_000_000),
    ("vae", "wan_2.1_vae.safetensors",
     "2fc39d31359a4b0a64f55876d8ff7fa8d780956ae2cb13463b0223e15148976b", 254_000_000),
)
BASE = "https://huggingface.co/Comfy-Org/Wan-2.1/resolve/main/split_files/"


def digest(path: Path) -> str:
    value = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(4 * 1024 * 1024), b""):
            value.update(block)
    return value.hexdigest()


def install(root: Path) -> list[Path]:
    root = root.resolve(strict=True)
    if root.name != "models" or root.parent.name != "ComfyUI":
        raise ValueError("Choose the existing ComfyUI/models folder.")
    result = []
    with requests.Session() as client:
        client.trust_env = False
        for folder, filename, checksum, size in FILES:
            directory = (root / folder).resolve(strict=True)
            if directory.parent != root:
                raise ValueError("A model folder escaped ComfyUI/models.")
            target = directory / filename
            if target.is_file() and digest(target) == checksum:
                result.append(target)
                continue
            partial = directory / (filename + ".part")
            offset = partial.stat().st_size if partial.exists() else 0
            if offset > size + 100_000_000:
                raise ValueError("A partial model is larger than expected.")
            url = BASE + folder + "/" + filename + "?download=true"
            headers = {"Range": f"bytes={offset}-"} if offset else {}
            with client.get(url, headers=headers, stream=True, timeout=(10, 60)) as response:
                response.raise_for_status()
                if offset and response.status_code != 206:
                    offset = 0
                count = offset
                next_report = ((count // 1_000_000_000) + 1) * 1_000_000_000
                with partial.open("ab" if offset else "wb") as output:
                    for chunk in response.iter_content(4 * 1024 * 1024):
                        if not chunk:
                            continue
                        count += len(chunk)
                        if count > size + 100_000_000:
                            raise ValueError("A model download exceeded its published size.")
                        output.write(chunk)
                        if count >= next_report:
                            print(f"{filename}: {count / 1_000_000_000:.1f} GB", flush=True)
                            next_report += 1_000_000_000
            if digest(partial) != checksum:
                raise ValueError(f"Checksum mismatch: {filename}")
            os.replace(partial, target)
            result.append(target)
            print(f"Verified {filename}", flush=True)
    return result


if __name__ == "__main__":
    import argparse
    parser = argparse.ArgumentParser()
    parser.add_argument("models", type=Path)
    print("\n".join(str(path) for path in install(parser.parse_args().models)))

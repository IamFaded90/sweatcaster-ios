#!/usr/bin/env python3
"""Export the ACE-Step Oobleck encoder from its original safetensors checkpoint.

The output contains only encoder tensors in MLX Conv1d layout. Weight-norm is
folded in float32; Snake alpha/beta remain the checkpoint's raw log parameters.
This does not change the input checkpoint or install a model in FadedAI.

Conversion follows ACE-Step 1.5's MIT-licensed
``acestep/models/mlx/vae_convert.py`` (weight norm + Conv1d axis swap).
Requires the Python packages torch and safetensors, not MLX or Apple hardware.
"""

from __future__ import annotations

import argparse
import os
from pathlib import Path
import shutil
import tempfile

import torch
from safetensors import safe_open
from safetensors.torch import save_file


def export_encoder(source: Path, output: Path, dtype: str) -> None:
    source = source.resolve(strict=True)
    output = output.resolve()
    if source == output:
        raise ValueError("The output must be different from the source checkpoint")
    if output.exists():
        raise FileExistsError(f"Output already exists: {output}")
    if not output.parent.is_dir():
        raise FileNotFoundError(f"Output directory does not exist: {output.parent}")

    target_type = {"float16": torch.float16, "float32": torch.float32}[dtype]
    result: dict[str, torch.Tensor] = {}
    consumed: set[str] = set()
    largest_fusion_difference = 0.0

    with safe_open(str(source), framework="pt", device="cpu") as archive:
        keys = {key for key in archive.keys() if key.startswith("encoder.")}
        if not keys:
            raise ValueError("No encoder tensors were found in the checkpoint")
        for key in sorted(keys):
            if key in consumed:
                continue
            if key.endswith(".weight_g"):
                base = key.removesuffix(".weight_g")
                v_key = base + ".weight_v"
                if v_key not in keys:
                    raise ValueError(f"Missing weight-norm partner: {v_key}")
                g = archive.get_tensor(key).float()
                v = archive.get_tensor(v_key).float()
                if v.ndim != 3 or tuple(g.shape) != (v.shape[0], 1, 1):
                    raise ValueError(f"Unexpected Conv1d weight-norm shapes for {base}")
                norm = torch.linalg.vector_norm(v.flatten(1), dim=1).reshape(g.shape)
                if not torch.isfinite(norm).all() or (norm == 0).any():
                    raise ValueError(f"Invalid weight-norm denominator for {base}")
                fused = g * v / (norm + 1e-9)
                # Check our fusion against PyTorch's original weight_norm operation.
                reference = torch._weight_norm(v, g, 0)
                difference = (fused - reference).abs().max().item()
                largest_fusion_difference = max(largest_fusion_difference, difference)
                if not torch.allclose(fused, reference, rtol=1e-5, atol=1e-6):
                    raise ValueError(f"Weight-norm verification failed for {base}")
                # MLX Conv1d expects [out, kernel, input], not PyTorch's [out, input, kernel].
                name = base + ".weight"
                value = fused.permute(0, 2, 1).contiguous()
                consumed.update((key, v_key))
            elif key.endswith(".weight_v"):
                raise ValueError(f"Missing weight-norm partner for {key}")
            elif key.endswith((".alpha", ".beta")):
                # Values are log-scale; do not exponentiate. [C] broadcasts in MLX.
                value = archive.get_tensor(key).float().reshape(-1)
                name = key
                consumed.add(key)
            elif key.endswith(".bias"):
                value = archive.get_tensor(key).float()
                if value.ndim != 1:
                    raise ValueError(f"Unexpected bias shape: {key}")
                name = key
                consumed.add(key)
            else:
                raise ValueError(f"Unexpected encoder tensor: {key}")
            if name in result:
                raise ValueError(f"Duplicate output tensor: {name}")
            value = value.to(target_type).contiguous()
            if not torch.isfinite(value).all():
                raise ValueError(f"Non-finite output tensor after conversion: {name}")
            result[name] = value
    if consumed != keys:
        raise ValueError("Not all source encoder tensors were consumed")
    if not {"encoder.conv1.weight", "encoder.conv2.weight", "encoder.snake1.alpha", "encoder.snake1.beta"}.issubset(result):
        raise ValueError("Required encoder tensors are missing")

    # Verify the temporary file before exclusively creating the destination.
    # Exclusive creation never modifies the source or overwrites an existing file.
    fd, temporary_name = tempfile.mkstemp(prefix=".ace-encoder-", suffix=".safetensors", dir=output.parent)
    os.close(fd)
    temporary = Path(temporary_name)
    try:
        save_file(result, str(temporary), metadata={"format": "mlx", "dtype": dtype, "component": "ace-step-1.5-vae-encoder"})
        with safe_open(str(temporary), framework="pt", device="cpu") as check:
            if set(check.keys()) != set(result):
                raise ValueError("Saved encoder keys do not match converted tensors")
            for name, tensor in result.items():
                actual = check.get_tensor(name)
                if actual.shape != tensor.shape or actual.dtype != tensor.dtype or not torch.equal(actual, tensor):
                    raise ValueError(f"Saved tensor verification failed: {name}")
        with temporary.open("rb") as src:
            dst = output.open("xb")
            try:
                with dst:
                    shutil.copyfileobj(src, dst, length=4 * 1024 * 1024)
            except BaseException:
                output.unlink(missing_ok=True)
                raise
    finally:
        temporary.unlink(missing_ok=True)
    print(f"Source encoder tensors: {len(keys)}; exported tensors: {len(result)}")
    print(f"Largest weight-norm fusion difference vs PyTorch: {largest_fusion_difference:.3g}")
    print(f"Saved {dtype}: {output} ({output.stat().st_size:,} bytes)")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path, help="Original diffusion_pytorch_model.safetensors")
    parser.add_argument("output", type=Path, help="New encoder-only .safetensors path")
    parser.add_argument("--dtype", choices=("float16", "float32"), default="float16")
    args = parser.parse_args()
    export_encoder(args.source, args.output, args.dtype)


if __name__ == "__main__":
    main()

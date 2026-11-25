#!/usr/bin/env python3
"""Extract ACE-Step 1.5 turbo's audio-tokenizer weights for the iOS MLX port.

Linear tensors remain in PyTorch/MLX Linear layout [output, input]; unlike VAE
convolutions they must NOT be transposed in the file. All 32 tokenizer tensors
are copied and converted from the original BF16 checkpoint to FP16 (or FP32).
No model code is imported and the source is never modified. Requires torch and
safetensors; neither MLX nor Apple hardware is needed for export.
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


def expected_shapes() -> dict[str, tuple[int, ...]]:
    prefix = "tokenizer."
    result = {
        "audio_acoustic_proj.weight": (2048, 64),
        "audio_acoustic_proj.bias": (2048,),
        "attention_pooler.embed_tokens.weight": (2048, 2048),
        "attention_pooler.embed_tokens.bias": (2048,),
        "attention_pooler.special_token": (1, 1, 2048),
        "attention_pooler.norm.weight": (2048,),
        "quantizer.project_in.weight": (6, 2048),
        "quantizer.project_in.bias": (6,),
        "quantizer.project_out.weight": (2048, 6),
        "quantizer.project_out.bias": (2048,),
    }
    for layer in range(2):
        base = f"attention_pooler.layers.{layer}."
        result.update({
            base + "input_layernorm.weight": (2048,),
            base + "post_attention_layernorm.weight": (2048,),
            base + "mlp.down_proj.weight": (2048, 6144),
            base + "mlp.gate_proj.weight": (6144, 2048),
            base + "mlp.up_proj.weight": (6144, 2048),
            base + "self_attn.q_proj.weight": (2048, 2048),
            base + "self_attn.k_proj.weight": (1024, 2048),
            base + "self_attn.v_proj.weight": (1024, 2048),
            base + "self_attn.o_proj.weight": (2048, 2048),
            base + "self_attn.q_norm.weight": (128,),
            base + "self_attn.k_norm.weight": (128,),
        })
    return {prefix + key: shape for key, shape in result.items()}


def export_tokenizer(source: Path, output: Path, dtype: str) -> None:
    source = source.resolve(strict=True)
    output = output.resolve()
    if source == output:
        raise ValueError("The output must be different from the source checkpoint")
    if output.exists():
        raise FileExistsError(f"Output already exists: {output}")
    if not output.parent.is_dir():
        raise FileNotFoundError(f"Output directory does not exist: {output.parent}")

    target_type = {"float16": torch.float16, "float32": torch.float32}[dtype]
    expected = expected_shapes()
    result: dict[str, torch.Tensor] = {}
    max_cast_error = 0.0
    with safe_open(str(source), framework="pt", device="cpu") as archive:
        keys = {key for key in archive.keys() if key.startswith("tokenizer.")}
        if keys != set(expected):
            missing, extra = sorted(set(expected) - keys), sorted(keys - set(expected))
            raise ValueError(f"Unexpected tokenizer keys; missing={missing}, extra={extra}")
        for key in sorted(keys):
            original = archive.get_tensor(key)
            if tuple(original.shape) != expected[key]:
                raise ValueError(f"Unexpected shape for {key}: {tuple(original.shape)}")
            value = original.to(target_type).contiguous()
            if not torch.isfinite(value).all():
                raise ValueError(f"Non-finite output after conversion: {key}")
            difference = (value.float() - original.float()).abs().max().item()
            max_cast_error = max(max_cast_error, difference)
            result[key] = value

    fd, temporary_name = tempfile.mkstemp(prefix=".ace-tokenizer-", suffix=".safetensors", dir=output.parent)
    os.close(fd)
    temporary = Path(temporary_name)
    try:
        save_file(result, str(temporary), metadata={"format": "mlx", "dtype": dtype, "component": "ace-step-1.5-audio-tokenizer"})
        with safe_open(str(temporary), framework="pt", device="cpu") as check:
            if set(check.keys()) != set(result):
                raise ValueError("Saved tensor keys do not match")
            for key, tensor in result.items():
                actual = check.get_tensor(key)
                if actual.shape != tensor.shape or actual.dtype != tensor.dtype or not torch.equal(actual, tensor):
                    raise ValueError(f"Saved tensor verification failed: {key}")
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
    print(f"Exported {len(result)} tensors, {dtype}; max absolute cast error: {max_cast_error:.6g}")
    print(f"Saved: {output} ({output.stat().st_size:,} bytes)")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path, help="Original turbo model.safetensors")
    parser.add_argument("output", type=Path, help="New tokenizer-only .safetensors path")
    parser.add_argument("--dtype", choices=("float16", "float32"), default="float16")
    args = parser.parse_args()
    export_tokenizer(args.source, args.output, args.dtype)


if __name__ == "__main__":
    main()

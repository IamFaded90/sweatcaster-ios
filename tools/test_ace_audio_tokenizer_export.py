#!/usr/bin/env python3
"""Compare extracted tokenizer weights with the original ACE-Step CPU model.

Example (with ACE-Step's Python environment):
  python tools/test_ace_audio_tokenizer_export.py CHECKPOINT EXPORT --engine-dir ENGINE

Loads the *actual upstream tokenizer implementation*, once with original
weights and once with the exported weights, for silence, random acoustic
latents and a smooth synthetic pattern. This checks the export, not the Swift
implementation, generated audio quality, or iPhone memory use.
"""

from __future__ import annotations

import argparse
from pathlib import Path
import sys

import torch
from safetensors import safe_open


def tokenizer_weights(path: Path) -> dict[str, torch.Tensor]:
    with safe_open(str(path), framework="pt", device="cpu") as archive:
        return {
            key.removeprefix("tokenizer."): archive.get_tensor(key)
            for key in archive.keys()
            if key.startswith("tokenizer.")
        }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("checkpoint", type=Path, help="Original turbo model.safetensors")
    parser.add_argument("export", type=Path, help="Extracted tokenizer safetensors")
    parser.add_argument("--engine-dir", type=Path, required=True, help="ACE-Step checkout containing acestep/")
    parser.add_argument("--threads", type=int, default=2)
    args = parser.parse_args()
    if args.threads < 1:
        parser.error("--threads must be positive")
    checkpoint = args.checkpoint.resolve(strict=True)
    export = args.export.resolve(strict=True)
    engine = args.engine_dir.resolve(strict=True)
    if checkpoint == export:
        parser.error("Provide two different files")
    if not (engine / "acestep").is_dir():
        parser.error("--engine-dir must contain the upstream acestep package")
    if not (checkpoint.parent / "config.json").is_file():
        parser.error("The original config.json must be next to the checkpoint")

    # Some installed Transformers versions fail their optional auto-docstring
    # generation on the custom ACE-Step class; it doesn't affect inference.
    import transformers.utils
    original_docstring = transformers.utils.auto_docstring
    transformers.utils.auto_docstring = lambda obj=None, **kwargs: (lambda item: item) if obj is None else obj
    sys.path.insert(0, str(engine))
    try:
        from acestep.models.turbo.modeling_acestep_v15_turbo import AceStepAudioTokenizer, AceStepConfig
    finally:
        transformers.utils.auto_docstring = original_docstring

    torch.set_num_threads(args.threads)
    config = AceStepConfig.from_pretrained(str(checkpoint.parent), local_files_only=True)
    config._attn_implementation = "eager"
    model = AceStepAudioTokenizer(config).eval()
    original = tokenizer_weights(checkpoint)
    extracted = tokenizer_weights(export)
    if set(original) != set(extracted):
        raise ValueError("Checkpoint and export have different tokenizer keys")
    generator = torch.Generator(device="cpu").manual_seed(42)
    random = torch.randn((1, 2, 5, 64), generator=generator)
    smooth = torch.sin(torch.arange(2 * 5 * 64, dtype=torch.float32) / 31).reshape(1, 2, 5, 64)
    inputs = torch.cat((torch.zeros_like(random), random, smooth), dim=0)
    with torch.inference_mode():
        model.load_state_dict(original, strict=True)
        ref_vectors, ref_codes = model(inputs)
        model.load_state_dict(extracted, strict=True)
        out_vectors, out_codes = model(inputs)
    error = (ref_vectors - out_vectors).abs().max().item()
    same_codes = torch.equal(ref_codes, out_codes)
    print(f"Cases: {inputs.shape[0]}; acoustic shape: {tuple(inputs.shape)}")
    print(f"Identical FSQ codes: {same_codes}; max projected output error: {error:.9g}")
    print(f"Reference codes: {ref_codes.flatten().tolist()}")
    if not same_codes or not torch.allclose(ref_vectors, out_vectors, atol=1e-6, rtol=1e-5):
        raise AssertionError("Tokenizer outputs differ beyond the permitted tolerance")
    print("PASS: exported weights agree with the original PyTorch tokenizer on these cases")


if __name__ == "__main__":
    main()

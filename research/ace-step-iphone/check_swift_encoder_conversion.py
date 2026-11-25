"""Prepare/check synthetic fixtures against the existing Python converter.

Usage: python -B .../check_swift_encoder_conversion.py prepare NEW_DIRECTORY
       run the standalone Swift converter on input.safetensors → swift.safetensors
       python -B .../check_swift_encoder_conversion.py check DIRECTORY

The fixture is synthetic. It does not validate Apple hardware or model audio.
"""
import argparse
from pathlib import Path
import sys

import torch
from safetensors.torch import load_file, save_file


def prepare(root: Path):
    root.mkdir(parents=False, exist_ok=False)
    generator = torch.Generator().manual_seed(42)
    tensors = {
        "encoder.conv1.weight_g": torch.tensor([2.0, 1.0]).reshape(2, 1, 1),
        "encoder.conv1.weight_v": torch.tensor([3., 4., 0., 0., 0., 0., 0., 4.]).reshape(2, 2, 2),
        "encoder.conv1.bias": torch.tensor([1., -0.25]),
        "encoder.conv2.weight_g": torch.randn(4, 1, 1, generator=generator),
        "encoder.conv2.weight_v": torch.randn(4, 3, 5, generator=generator),
        "encoder.conv2.bias": torch.randn(4, generator=generator),
        "encoder.snake1.alpha": torch.tensor([-2., -0.125, 0., 0.5]).reshape(1, 4, 1),
        "encoder.snake1.beta": torch.tensor([1., -0.5, 0., 2.]).reshape(1, 4, 1),
    }
    save_file({name: value.to(torch.bfloat16) for name, value in tensors.items()}, str(root / "input.safetensors"))
    failures = {}
    failures["missing"] = {k: v for k, v in tensors.items() if k != "encoder.conv1.weight_v"}
    failures["zero_norm"] = {**tensors, "encoder.conv1.weight_v": torch.zeros(2, 2, 2)}
    failures["nonfinite"] = {**tensors, "encoder.conv1.weight_v": torch.full((2, 2, 2), float("nan"))}
    failures["overflow"] = {**tensors, "encoder.snake1.alpha": torch.full((1, 4, 1), 1e10)}
    failures["wrong_shape"] = {**tensors, "encoder.conv1.weight_g": torch.ones(1, 2, 1)}
    for name, case in failures.items():
        save_file({key: value.to(torch.bfloat16) for key, value in case.items()}, str(root / f"{name}.safetensors"))
    sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "tools"))
    from export_ace_vae_encoder import export_encoder
    export_encoder(root / "input.safetensors", root / "python.safetensors", "float16")
    print("Prepared synthetic BF16 fixture and Python oracle")


def check(root: Path):
    reference = load_file(str(root / "python.safetensors"))
    candidate = load_file(str(root / "swift.safetensors"))
    assert set(reference) == set(candidate), "Tensor key mismatch"
    worst = 0.0
    exact = True
    for key in reference:
        assert reference[key].shape == candidate[key].shape, key
        assert candidate[key].dtype == torch.float16, key
        delta = (reference[key].float() - candidate[key].float()).abs().max().item()
        worst = max(worst, delta)
        exact &= torch.equal(reference[key], candidate[key])
        assert torch.allclose(reference[key].float(), candidate[key].float(), atol=1e-5, rtol=1e-3), (key, delta)
    expected = torch.tensor([[[1.2, 0], [1.6, 0]], [[0, 0], [0, 1]]], dtype=torch.float16)
    assert torch.equal(candidate["encoder.conv1.weight"], expected), "Norm axis or transpose is wrong"
    assert torch.equal(candidate["encoder.snake1.alpha"], torch.tensor([-2., -.125, 0., .5], dtype=torch.float16))
    print(f"PASS: {len(reference)} tensors, max error {worst:g}, bit-exact {exact}; norm and transpose checked")
    print("Synthetic fixture only: not an MLX, iPhone or audio test.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("phase", choices=("prepare", "check"))
    parser.add_argument("directory", type=Path)
    args = parser.parse_args()
    (prepare if args.phase == "prepare" else check)(args.directory)

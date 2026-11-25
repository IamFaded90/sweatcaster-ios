"""Compare the proposed Swift FSQ arithmetic to the installed ACE-Step FSQ.

Run with ACE-Step's Python environment. Uses no model files, writes nothing,
and checks the scalar quantizer only; Swift/MLX still requires Apple hardware.
"""
import torch
from vector_quantize_pytorch import ResidualFSQ


def main():
    levels = torch.tensor([8., 8., 8., 5., 5., 5.])
    basis = torch.tensor([1., 8., 64., 512., 2560., 12800.])
    model = ResidualFSQ(dim=6, levels=[8, 8, 8, 5, 5, 5], num_quantizers=1).eval()
    torch.manual_seed(42)
    audio = torch.randn(1, 2048, 6) * 2
    with torch.inference_mode():
        original, indices = model(audio)
        soft_clamp = 1 + 1 / (levels - 1)
        bounded = (audio / soft_clamp).tanh() * soft_clamp
        bounded = bounded.clamp(-1, 1)
        bracket = torch.floor((levels - 1) * (bounded + 1) / 2 + 0.5)
        codes = (2 / (levels - 1)) * bracket - 1
        packed = (((codes + 1) / (2 / (levels - 1))) * basis).sum(-1).round().long()
        if not torch.equal(packed, indices.squeeze(-1)):
            raise AssertionError("FSQ packed indices differ")
        if not torch.equal(codes, original):
            raise AssertionError("FSQ scalar values differ")
    print(f"PASS: {packed.numel()} scalar-code vectors and packed indices agree on CPU")
    print("This is not a Swift/MLX or iPhone test.")


if __name__ == "__main__":
    main()

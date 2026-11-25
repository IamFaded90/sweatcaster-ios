"""Check the ACE VAE overlap/discard scheme against the local PyTorch model.

Example (inside the existing ACE-Step Python environment):
  python -B tools/check_song_encoder_reference.py F:/FadedAI/song-studio/engine/checkpoints/vae

This checks the reference math on CPU only. It does NOT execute the Swift/MLX
port or measure an iPhone's memory. No audio or model files are written.
"""
import argparse
import time

import torch
from diffusers.models import AutoencoderOobleck


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("checkpoint", help="Existing directory with VAE config and weights")
    args = parser.parse_args()
    torch.set_num_threads(2)
    vae = AutoencoderOobleck.from_pretrained(args.checkpoint, local_files_only=True).eval()

    # A deterministic, non-silent stereo signal, 1.2 seconds / 30 latents.
    # Splitting into cores of 15 exercises the seam and both clip boundaries.
    hop, frames, core, overlap = 1920, 30, 15, 12
    t = torch.arange(hop * frames, dtype=torch.float32) / 48000
    audio = torch.stack((0.2 * torch.sin(2 * torch.pi * 440 * t),
                         0.15 * torch.cos(2 * torch.pi * 731 * t)))[None]
    started = time.monotonic()
    with torch.inference_mode():
        whole = vae.encoder(audio)
        pieces = []
        for start in range(0, frames, core):
            end = min(start + core, frames)
            low, high = max(0, start - overlap), min(frames, end + overlap)
            encoded = vae.encoder(audio[:, :, low * hop:high * hop])
            pieces.append(encoded[:, :, start - low:end - low])
        tiled = torch.cat(pieces, dim=2)
        maximum_error = (whole - tiled).abs().max().item()
        mean, scale = tiled.chunk(2, dim=1)
        torch.manual_seed(241)
        noise = torch.randn_like(mean)
        sampled = mean + (torch.nn.functional.softplus(scale) + 1e-4) * noise
        assert tuple(whole.shape) == (1, 128, frames)
        assert torch.isfinite(sampled).all().item()
        if maximum_error >= 5e-5:
            raise AssertionError(f"Tiled encoder differs by {maximum_error:g}")
    print(f"PyTorch CPU: shape={list(whole.shape)}; maximum tile error={maximum_error:.8g}; "
          f"sample shape={list(sampled.shape)}; time={time.monotonic() - started:.1f}s")
    print("Swift/MLX and real iPhone memory/performance remain untested by this script.")


if __name__ == "__main__":
    main()

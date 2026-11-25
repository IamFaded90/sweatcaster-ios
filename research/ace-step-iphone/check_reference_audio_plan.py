"""Compare the pure reference plan directly against installed ACE-Step.

Run in the existing ACE Python environment:
  python -B research/ace-step-iphone/check_reference_audio_plan.py --engine-dir ENGINE

No audio files are written. This verifies the PC-side selection logic only,
not an iPhone implementation or iOS decoding/resampling.
"""
from __future__ import annotations

import argparse
from pathlib import Path
import sys
from unittest.mock import patch

import numpy as np
import torch

from reference_audio_plan import SEGMENT_FRAMES, TARGET_FRAMES, plan_reference


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--engine-dir", type=Path, required=True)
    args = parser.parse_args()
    sys.path.insert(0, str(args.engine_dir.resolve(strict=True)))
    from acestep.core.generation.handler.io_audio import IoAudioMixin

    class Host(IoAudioMixin):
        def is_silence(self, audio):
            return bool(torch.all(audio.abs() < 1e-6))

    torch.set_num_threads(2)
    for invalid in (0, -1, True, 2.5):
        try:
            plan_reference(invalid, lambda lo, hi: lo)
        except ValueError:
            pass
        else:
            raise AssertionError(f"Invalid frame count accepted: {invalid}")
    try:
        plan_reference(TARGET_FRAMES, lambda lo, hi: hi + 1)
    except ValueError:
        pass
    else:
        raise AssertionError("Out-of-range RNG accepted")

    # Includes extremely short, exact segment, just below/exactly 30 seconds,
    # and a longer source with non-trivial random-offset bounds.
    for length in (1, SEGMENT_FRAMES, TARGET_FRAMES - 1, TARGET_FRAMES, TARGET_FRAMES + 360_001):
        base = ((np.arange(length, dtype=np.int64) % 997) + 1).astype(np.float32) / 1000
        stereo = np.stack((base, -base), axis=1)
        for pick in (lambda lo, hi: lo, lambda lo, hi: (lo + hi) // 2, lambda lo, hi: hi):
            plan = plan_reference(length, pick)
            with patch("acestep.core.generation.handler.io_audio._read_audio_file", return_value=(stereo, 48_000)):
                with patch("acestep.core.generation.handler.io_audio.random.randint", side_effect=pick):
                    actual = Host().process_reference_audio("synthetic.wav")
            assert actual is not None
            expected = torch.cat([
                torch.from_numpy(stereo[(np.arange(SEGMENT_FRAMES) + start) % length].T.copy())
                for start in plan.starts
            ], dim=1)
            assert tuple(actual.shape) == (2, TARGET_FRAMES)
            assert torch.equal(actual, expected), f"Mismatch for length={length}, starts={plan.starts}"
    print("PASS: 15 boundary/offset cases match ACE-Step reference selection exactly")
    print("No Swift, iPhone, audio-decoder or resampling test was performed.")


if __name__ == "__main__":
    main()

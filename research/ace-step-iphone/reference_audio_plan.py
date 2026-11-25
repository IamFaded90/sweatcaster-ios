"""Pure frame-selection plan for ACE-Step's 30-second timbre reference.

This is research code, not included in FadedAI's production build. The input
frame count describes audio *after* conversion to stereo at 48 kHz. Each
span refers to the virtually repeated input, not a newly allocated waveform.
It follows `IoAudioMixin.process_reference_audio` from ACE-Step 1.5 (MIT).

The caller must separately reject silence, decode and normalize audio, and
sample uniformly within each inclusive offset bound. This plan is for timbre
references only: a remix source may need its full duration.
"""
from __future__ import annotations

from dataclasses import dataclass
from typing import Callable

SAMPLE_RATE = 48_000
SEGMENT_FRAMES = 10 * SAMPLE_RATE
TARGET_FRAMES = 3 * SEGMENT_FRAMES


@dataclass(frozen=True)
class ReferencePlan:
    original_frames: int
    repeats: int
    starts: tuple[int, int, int]
    segment_frames: int = SEGMENT_FRAMES


def plan_reference(original_frames: int, randint: Callable[[int, int], int]) -> ReferencePlan:
    """Choose ACE's front, middle and back segments with injectable RNG.

    `randint(lo, hi)` must choose an integer from the inclusive range. Large
    input is not copied; `starts` index a virtual sequence of `repeats` copies.
    """
    if isinstance(original_frames, bool) or not isinstance(original_frames, int) or original_frames <= 0:
        raise ValueError("original_frames must be a positive integer")
    repeats = max(1, (TARGET_FRAMES + original_frames - 1) // original_frames)
    total = original_frames * repeats
    segment_size = total // 3
    starts = []
    for base, available in ((0, segment_size), (segment_size, segment_size),
                            (2 * segment_size, total - 2 * segment_size)):
        maximum = max(0, available - SEGMENT_FRAMES)
        offset = randint(0, maximum)
        if isinstance(offset, bool) or not isinstance(offset, int) or not 0 <= offset <= maximum:
            raise ValueError("RNG returned a value outside the inclusive bound")
        starts.append(base + offset)
    return ReferencePlan(original_frames, repeats, tuple(starts))

"""ACE emits float WAV; store a portable PCM16 WAV for iPhone and validation."""

from array import array
import math
from pathlib import Path
import struct
import sys
import wave


def canonical_wave(path):
    path = Path(path)
    temporary = path.with_suffix(".pcm.tmp")
    try:
        with path.open("rb") as source:
            header = source.read(12)
            if len(header) != 12 or header[:4] != b"RIFF" or header[8:] != b"WAVE":
                raise ValueError("Not a RIFF WAVE")
            size = path.stat().st_size
            end = struct.unpack("<I", header[4:8])[0] + 8
            if not 44 <= end <= min(size, 70_000_000):
                raise ValueError("Incomplete WAV")
            info, audio = None, None
            while source.tell() + 8 <= end:
                key, count = struct.unpack("<4sI", source.read(8))
                start = source.tell()
                if start + count > end:
                    raise ValueError("Incomplete WAV chunk")
                if key == b"fmt ":
                    if not 16 <= count <= 64:
                        raise ValueError("Invalid WAV format")
                    info = struct.unpack("<HHIIHH", source.read(16))
                if key == b"data":
                    audio = (start, count)
                source.seek(start + count + count % 2)
            if info is None or audio is None:
                raise ValueError("Missing WAV audio")
            kind, channels, rate, byte_rate, align, bits = info
            if kind == 1:
                return
            if (kind != 3 or channels not in (1, 2) or bits not in (32, 64)
                    or not 8_000 <= rate <= 96_000 or align != channels * bits // 8
                    or byte_rate != rate * align or audio[1] % align):
                raise ValueError("Unsupported WAV audio")
            source.seek(audio[0])
            remaining = audio[1]
            with wave.open(str(temporary), "wb") as output:
                output.setnchannels(channels)
                output.setsampwidth(2)
                output.setframerate(rate)
                while remaining:
                    block = source.read(min(remaining, align * 16_384))
                    if not block:
                        raise ValueError("Incomplete audio")
                    samples = array("f" if bits == 32 else "d")
                    samples.frombytes(block)
                    if sys.byteorder != "little":
                        samples.byteswap()
                    if not all(math.isfinite(sample) for sample in samples):
                        raise ValueError("Nonfinite audio")
                    pcm = array("h", (int(max(-1, min(1, sample)) * 32767) for sample in samples))
                    if sys.byteorder != "little":
                        pcm.byteswap()
                    output.writeframesraw(pcm.tobytes())
                    remaining -= len(block)
        temporary.replace(path)
    finally:
        temporary.unlink(missing_ok=True)


def fit_wave(path, seconds):
    """Covers can follow source length; cut excess with a short fade, never loop/pad."""
    path = Path(path)
    temporary = path.with_suffix(".cut.tmp")
    try:
        with wave.open(str(path)) as source:
            target = round(seconds * source.getframerate())
            if source.getnframes() <= target:
                return
            if source.getsampwidth() != 2:
                raise ValueError("Only canonical PCM16 may be trimmed")
            data = bytearray(source.readframes(target))
            channels = source.getnchannels()
            fade = min(target, round(0.15 * source.getframerate()))
            for frame in range(fade):
                gain = (fade - frame - 1) / max(1, fade - 1)
                for channel in range(channels):
                    offset = ((target - fade + frame) * channels + channel) * 2
                    sample = struct.unpack_from("<h", data, offset)[0]
                    struct.pack_into("<h", data, offset, int(sample * gain))
            with wave.open(str(temporary), "wb") as output:
                output.setparams(source.getparams())
                output.writeframes(data)
        temporary.replace(path)
    finally:
        temporary.unlink(missing_ok=True)

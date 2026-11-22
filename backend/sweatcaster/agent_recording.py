"""Paired, on-demand transcription of short recordings using the installed multilingual Whisper."""
from array import array
import json
from pathlib import Path
import shutil
import subprocess
from tempfile import TemporaryDirectory

from fastapi import Request, Response
from starlette.concurrency import run_in_threadpool

from sweatcaster.dto import ApiError
from sweatcaster.film_companion import SLOT, speech
from sweatcaster.film_media import FilmSourceError

RATE = 16_000
SECONDS = 45
MAX_BYTES = 18_000_000


def decode(data, kind):
    probe, ffmpeg = shutil.which("ffprobe"), shutil.which("ffmpeg")
    if not (probe and ffmpeg):
        raise ApiError(503, "NOT_READY", "PC’en mangler FFmpeg til at læse lydfilen.")
    with TemporaryDirectory(prefix="faded-dictation-") as folder:
        file = Path(folder) / ("input." + kind)
        file.write_bytes(data)
        source = ["-protocol_whitelist", "file", "-f", "mov" if kind == "m4a" else "wav"]
        if kind == "m4a":
            source.extend(["-enable_drefs", "0", "-use_absolute_path", "0"])
        source.extend(["-i", str(file)])
        try:
            flags = {"stderr": subprocess.DEVNULL, "timeout": 15, "check": True,
                     "stdout": subprocess.PIPE, "creationflags": getattr(subprocess, "CREATE_NO_WINDOW", 0)}
            info = subprocess.run([probe, "-v", "error", "-select_streams", "a:0", "-show_entries",
                                   "stream=channels", "-of", "json", *source], **flags)
            channels = json.loads(info.stdout)["streams"][0]["channels"]
            if channels not in (1, 2):
                raise ValueError()
            result = subprocess.run([ffmpeg, "-nostdin", "-v", "error", "-xerror", *source, "-map", "0:a:0",
                                     "-t", str(SECONDS + 0.1), "-ac", str(channels), "-ar", str(RATE),
                                     "-c:a", "pcm_s16le", "-f", "s16le", "pipe:1"], **flags)
        except (OSError, subprocess.SubprocessError, ValueError, KeyError, IndexError, TypeError) as exc:
            raise ApiError(422, "INVALID_INPUT", "Vælg en læsbar WAV- eller M4A-fil med én eller to lydkanaler.") from exc
    if len(result.stdout) > SECONDS * RATE * channels * 2:
        raise ApiError(422, "INVALID_INPUT", "Vælg et uddrag på højst 45 sekunder.")
    if not result.stdout or len(result.stdout) % (channels * 2):
        raise ApiError(422, "INVALID_INPUT", "Optagelsen indeholder ingen læsbar lyd.")
    return array("h", result.stdout), channels


def timed_audio(samples):
    # Remove silent lead-in on each channel separately and keep its position in the source.
    # Whisper can otherwise put the first utterance at 0 on both microphones.
    block = RATE // 50
    first = last = None
    for offset in range(0, len(samples), block):
        window = samples[offset:offset + block]
        if sum(value * value for value in window) >= 32 * 32 * len(window):
            if first is None:
                first = offset
            last = offset + len(window)
    if first is None:
        return None
    first = max(0, first - block)
    last = min(len(samples), last + block)
    return samples[first:last].tobytes(), first / RATE, last / RATE


def shared_channel(left, right):
    if left == right:
        return left
    # Dual mono can be encoded at different volumes or with opposite polarity.
    l2 = r2 = cross = 0
    for a, b in zip(left, right):
        l2 += a * a
        r2 += b * b
        cross += a * b
    if l2 and r2 and cross * cross >= 0.999 * l2 * r2:
        return left if l2 >= r2 else right
    return None


def transcript(data, kind, language, separate, settings):
    pcm, channels = decode(data, kind)
    separate = separate and channels == 2
    if channels == 1:
        tracks = [pcm]
    else:
        left, right = pcm[0::2], pcm[1::2]
        common = shared_channel(left, right)
        if common is not None:
            separate = False
            tracks = [common]
        elif separate:
            tracks = [left, right]
        else:
            tracks = [array("h", ((a + b) // 2 for a, b in zip(left, right)))]
    cues = []
    for index, track in enumerate(tracks):
        timed = timed_audio(track)
        if timed:
            clip, start, end = timed
            # Whisper decodes in padded 30-second windows. Intersect cues with the actual
            # channel signal so a short final utterance survives a decoder endpoint beyond EOF.
            for cue in speech(clip, start, end + 30, settings, language=language):
                a, b = max(start, cue["start"]), min(end, cue["end"])
                if a < b:
                    cues.append({"start": a, "end": b, "text": cue["text"],
                                 "channel": index + 1 if separate else None})
    return {"separateChannels": separate, "cues": sorted(cues, key=lambda row: row["start"])}


def register_recording(app, settings, authorize):
    @app.post("/api/modules/v1/agent-recording/{kind}", include_in_schema=False)
    async def read_recording(kind: str, request: Request, response: Response, language: str = "da",
                             separate: bool = False):
        authorize(request, settings)
        response.headers["Cache-Control"] = "no-store"
        if kind not in {"wav", "m4a"} or language not in {"da", "en"}:
            raise ApiError(422, "INVALID_INPUT", "Vælg WAV eller M4A og dansk eller engelsk.")
        if not SLOT.acquire(blocking=False):
            raise ApiError(409, "NOT_READY", "PC’en er i gang med at genkende tale. Prøv igen om lidt.")
        try:
            data = bytearray()
            async for chunk in request.stream():
                if len(data) + len(chunk) > MAX_BYTES:
                    raise ApiError(413, "TOO_LARGE", "Vælg en optagelse på højst 18 MB.")
                data.extend(chunk)
            return await run_in_threadpool(transcript, data, kind, language, separate, settings)
        except FilmSourceError as error:
            raise ApiError(503, "NOT_READY", str(error)) from error
        finally:
            SLOT.release()

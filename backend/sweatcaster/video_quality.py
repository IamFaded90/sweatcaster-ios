"""Verify the encoded media and keep the result with its owning job."""

from fractions import Fraction
from math import isfinite
from pathlib import Path
import shutil
import subprocess

from sweatcaster.media import ffprobe_json
from sweatcaster.util import Cancelled, UserFacingError, check_cancel


class ExportQualityError(UserFacingError):
    def __init__(self, quality):
        super().__init__(quality["receipt"]["message"])
        self.quality = quality


def unavailable():
    return {"state": "unavailable", "checks": [], "message": "Der er ingen kontrol af denne videofil."}


def seconds(raw):
    try:
        value = float(raw)
    except (ValueError, TypeError):
        return None
    return value if isfinite(value) and value > 0 else None


def frame_duration(video):
    for field in ("avg_frame_rate", "r_frame_rate"):
        try:
            rate = Fraction(str(video.get(field)))
            duration = seconds(float(1 / rate))
            if duration:
                return duration
        except (ValueError, ZeroDivisionError, OverflowError):
            pass
    return 1 / 30


def sample(path, at, kind, cancel):
    check_cancel(cancel)
    if kind == "video":
        encode = ["-map", "0:v:0", "-an", "-frames:v", "1", "-vf", "scale=16:16",
                  "-pix_fmt", "gray", "-f", "rawvideo"]
    else:
        encode = ["-map", "0:a:0", "-vn", "-t", "0.1", "-ac", "1", "-ar", "8000", "-f", "s16le"]
    try:
        result = subprocess.run(
            ["ffmpeg", "-v", "error", "-nostdin", "-xerror", "-ss", f"{at:.6f}", "-i", str(path),
             *encode, "pipe:1"], stdin=subprocess.DEVNULL, capture_output=True, timeout=12, check=False,
            creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
        )
    except (OSError, subprocess.TimeoutExpired):
        check_cancel(cancel)
        return "unchecked"
    check_cancel(cancel)
    decoded = len(result.stdout) == 256 if kind == "video" else len(result.stdout) >= 2
    return "passed" if result.returncode == 0 and decoded else "failed"


def sampled(path, times, kind, cancel):
    overall = "passed"
    for at in times:
        state = sample(path, at, kind, cancel)
        if state == "failed":
            return state
        if state == "unchecked":
            overall = state
    return overall


def inspect_export(path: Path, expected_seconds: float, audio_expected: bool, cancel=None):
    """Check the actual video stream timeline rather than the muxed (audio/video) duration alone."""
    check_cancel(cancel)
    checks = {"video": "unchecked", "audio": "unchecked", "duration": "unchecked"}
    stamp = {}
    try:
        stat = path.stat()
        stamp = {"size": stat.st_size, "modified": stat.st_mtime_ns}
        data = ffprobe_json(path)
        streams = data.get("streams", [])
        video = next((s for s in streams if s.get("codec_type") == "video"), {})
        duration = seconds(video.get("duration"))
        expected = seconds(expected_seconds)
        if duration and expected:
            checks["duration"] = "passed" if abs(duration - expected) <= 0.125 else "failed"
        # Generators can emit 8/16/24 fps. Seek inside the actual last frame's interval.
        timeline = duration or seconds((data.get("format") or {}).get("duration"))
        if not video:
            checks["video"] = "failed"
        elif timeline:
            times = (0.0, timeline / 2, max(0, timeline - frame_duration(video) - 0.001))
            checks["video"] = sampled(path, times, "video", cancel)
        if audio_expected:
            if not any(s.get("codec_type") == "audio" for s in streams):
                checks["audio"] = "failed"
            elif timeline:
                # A forged duration or an audio track that ends early must not pass on headers alone.
                checks["audio"] = sampled(path, (0.0, timeline / 2, max(0, timeline - 0.12)), "audio", cancel)
    except FileNotFoundError:
        if not path.is_file():
            checks["video"] = "failed"
    except Cancelled:
        raise
    except UserFacingError:
        if shutil.which("ffprobe") and shutil.which("ffmpeg"):
            checks["video"] = "failed"
    except (OSError, subprocess.TimeoutExpired):
        pass
    check_cancel(cancel)
    required = ["video", "duration", *(["audio"] if audio_expected else [])]
    failed = [key for key in required if checks[key] == "failed"]
    if failed:
        state = "failed"
        messages = {"video": "Et billede i den færdige fil kunne ikke afspilles.",
                    "audio": "Det forventede lydspor kunne ikke afspilles gennem klippet.",
                    "duration": "Den færdige video har en anden varighed end planlagt."}
        message = " ".join(messages[key] for key in failed)
    elif any(checks[key] != "passed" for key in required):
        state, message = "partial", "PC’en kunne kun gennemføre en del af afspilningskontrollen."
    else:
        state = "verified"
        message = "PC’en afspillede billeder i starten, midten og slutningen og tjekkede varigheden. "
        message += "Lydsporet kunne afspilles." if audio_expected else "Klippet krævede ingen lyd."
    return {**stamp, "receipt": {"state": state, "message": message,
                                 "checks": [{"id": key, "state": value} for key, value in checks.items()]}}


def check_export(output, probe, bundle, cancel):
    quality = inspect_export(output, probe.duration, probe.has_audio or bool(bundle.clips), cancel)
    if quality["receipt"]["state"] == "failed":
        raise ExportQualityError(quality)
    return quality


def job_receipt(settings, store, job_id):
    from sweatcaster.dto import ApiError
    from sweatcaster.security import output_file

    job = store.get_job(job_id)
    if job is None:
        raise ApiError(404, "NOT_FOUND", "Videojobbet findes ikke.")
    quality = job.get("export_quality")
    if not isinstance(quality, dict) or job.get("output_removed"):
        return unavailable()
    if job["status"] == "completed" and job.get("output_ready"):
        try:
            stat = output_file(settings.output_root, job_id, "output.mp4").stat()
        except OSError:
            return unavailable()
        if (quality.get("size"), quality.get("modified")) != (stat.st_size, stat.st_mtime_ns):
            return unavailable()
        return quality["receipt"]
    if job["status"] == "failed" and quality["receipt"]["state"] == "failed":
        return quality["receipt"]
    return unavailable()

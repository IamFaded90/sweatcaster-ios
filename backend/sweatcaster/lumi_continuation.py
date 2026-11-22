"""Continue a private clip from its last frame and preserve the original opening."""

from pathlib import Path
import shutil
import subprocess
from tempfile import TemporaryDirectory

from sweatcaster.dto import ApiError


def continue_clip(previous, render):
    ffmpeg = shutil.which("ffmpeg")
    if not ffmpeg:
        raise ApiError(503, "NOT_READY", "PC’en mangler FFmpeg til at forlænge videoen.")

    def run(args, folder):
        return subprocess.run([ffmpeg, "-nostdin", "-hide_banner", "-loglevel", "error", "-y", *args],
                              cwd=folder, capture_output=True, check=True, timeout=120)

    try:
        with TemporaryDirectory(prefix="fadedai-lumi-") as folder:
            root = Path(folder)
            (root / "first.mp4").write_bytes(previous)
            run(["-sseof", "-1", "-i", "first.mp4", "-an", "-update", "1", "last.png"], folder)
            source = (root / "last.png").read_bytes()
            # The continuation is a fresh reference-conditioned render. The first clip is never regenerated.
            (root / "next.mp4").write_bytes(render(source))
            (root / "clips.txt").write_text("file first.mp4\nfile next.mp4\n", encoding="ascii")
            result = root / "joined.mp4"
            run(["-f", "concat", "-safe", "1", "-i", "clips.txt", "-map", "0:v:0",
                 "-c:v", "copy", "-movflags", "+faststart", result.name], folder)
            if not 8 <= result.stat().st_size <= 40_000_000:
                raise ApiError(422, "INVALID_INPUT", "Videoen er for stor til én forlængelse mere.")
            return result.read_bytes()
    except (OSError, subprocess.SubprocessError) as exc:
        raise ApiError(503, "NOT_READY", "PC’en kunne ikke samle de to videostykker.") from exc

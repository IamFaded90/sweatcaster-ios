"""Remove only Lumi-owned video artifacts from the local ComfyUI instance."""

import os
from pathlib import Path
import re
import stat
from threading import Thread
import time

import requests

from sweatcaster.dto import ApiError


def video_filename(job_id: str):
    return re.compile(re.escape(job_id) + r"_[0-9]{5}_[.]webm")


def remove_video(folder, job_id):
    output = Path(os.environ.get("FADEDAI_COMFY_OUTPUT_DIR", "F:/FadedAI/ComfyUI/output"))
    try:
        if not output.is_absolute() or not output.is_dir():
            raise OSError("Missing output folder")
        directory = output.resolve(strict=True) / folder
        if directory.resolve() != directory:
            raise OSError("Unexpected output folder")
        pattern = video_filename(job_id)
        files = [file for file in directory.iterdir() if pattern.fullmatch(file.name)] if directory.exists() else []
        if any(file.resolve() != file or not stat.S_ISREG(file.lstat().st_mode) for file in files):
            raise OSError("Unexpected file type")
        for file in files:
            file.unlink(missing_ok=True)
    except OSError as exc:
        raise ApiError(503, "NOT_READY", "Lumis videofil kunne ikke slettes på PC’en.") from exc


def discard_render(client, client_factory, comfy, folder, job_id, prompt_id, finished):
    def remove_files(session):
        remove_video(folder, job_id)
        if prompt_id is not None:
            response = session.post(comfy + "/history", json={"delete": [prompt_id]},
                                    timeout=(2, 3), allow_redirects=False)
            response.raise_for_status()

    if finished or prompt_id is None:
        try:
            remove_files(client)
            return
        except (requests.RequestException, ApiError):
            pass
    if prompt_id is not None and not finished:
        try:
            client.post(comfy + "/queue", json={"delete": [prompt_id]}, timeout=(2, 3), allow_redirects=False)
        except requests.RequestException:
            pass

    def finish_cleanup():
        # Removing a queue entry cannot interrupt a running ComfyUI graph.
        # Check this exact prompt before removing its files.
        with client_factory() as session:
            for _ in range(120):
                try:
                    if prompt_id is not None and not finished:
                        response = session.get(comfy + "/queue", timeout=(2, 3), allow_redirects=False)
                        response.raise_for_status()
                        queues = response.json()
                        if any(row[1] == prompt_id for row in queues["queue_running"] + queues["queue_pending"]):
                            time.sleep(10)
                            continue
                    remove_files(session)
                    return
                except (requests.RequestException, ApiError, KeyError, TypeError, IndexError, ValueError):
                    time.sleep(10)

    Thread(target=finish_cleanup, daemon=True, name="lumi-video-cleanup").start()

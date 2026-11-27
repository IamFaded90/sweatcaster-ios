"""Small adapter for the official ACE-Step 1.5 asynchronous API."""

import json
import os
from contextlib import ExitStack
from pathlib import Path
from urllib.parse import urljoin, urlsplit

import requests
from sweatcaster.song_audio import canonical_wave


class SongEngineError(RuntimeError):
    pass


class SongEngineOffline(SongEngineError):
    pass


class SongEngine:
    def __init__(self, base=None, session=None):
        self.base = (base or os.environ.get("FADEDAI_SONG_ENGINE", "http://127.0.0.1:8001")).rstrip("/")
        url = urlsplit(self.base)
        if url.scheme != "http" or url.hostname not in {"127.0.0.1", "localhost", "::1"} or url.username or url.query or url.fragment:
            raise SongEngineError("Musikmotoren skal køre lokalt på PC’en.")
        self.session = session or requests.Session()
        self.session.trust_env = False

    def _json(self, path, *, body=None, files=None, data=None):
        try:
            # The first submission after a lazy server start loads ACE-Step before
            # it returns a task ID. Keep that one request open long enough for a
            # cold load; retrying an uncertain submit could create a second song.
            timeout = (2, 3) if path == "/health" else (5, 360 if path == "/release_task" else 60)
            kwargs = {"timeout": timeout, "allow_redirects": False}
            if body is not None:
                kwargs["json"] = body
            if files is not None:
                kwargs.update(files=files, data=data)
            method = self.session.post if body is not None or files is not None else self.session.get
            response = method(self.base + path, **kwargs)
            response.raise_for_status()
            if len(response.content) > 2_000_000:
                raise ValueError("response too large")
            value = response.json()
            if value.get("code", 200) != 200 or value.get("error"):
                raise ValueError("engine rejected request")
            return value.get("data", value)
        except (requests.Timeout, requests.ConnectionError) as exc:
            raise SongEngineOffline("Forbindelsen til musikmotoren blev afbrudt. Det kendte job kontrolleres igen.") from exc
        except (requests.RequestException, ValueError, TypeError, AttributeError) as exc:
            raise SongEngineError("Musikmotoren på PC’en svarede ikke. Se opsætningen til Sangstudie.") from exc

    def available(self):
        try:
            value = self._json("/health")
            return isinstance(value, dict) and value.get("status") == "ok" and value.get("service") == "ACE-Step API"
        except SongEngineError:
            return False

    def submit(self, project, source=None, voice=None):
        payload = {
            "prompt": project["prompt"], "lyrics": project["lyrics"],
            "audio_duration": project["seconds"], "audio_format": "wav",
            "batch_size": 1, "thinking": False, "use_format": False,
            "task_type": "cover" if project["mode"] == "remix" else "text2music",
            "instrumental": project["instrumental"], "inference_steps": 8,
            "vocal_language": project.get("language", "da"),
        }
        if source or voice:
            with ExitStack() as stack:
                files = {}
                if source:
                    key = "src_audio" if project["mode"] == "remix" else "reference_audio"
                    files[key] = ("reference.wav", stack.enter_context(Path(source).open("rb")), "audio/wav")
                if voice:
                    files["reference_audio"] = ("my-voice.wav", stack.enter_context(Path(voice).open("rb")), "audio/wav")
                value = self._json("/release_task", files=files,
                                   data={k: str(v).lower() if isinstance(v, bool) else str(v) for k, v in payload.items()})
        else:
            value = self._json("/release_task", body=payload)
        task = value.get("task_id") if isinstance(value, dict) else None
        if not isinstance(task, str) or not 1 <= len(task) <= 160:
            raise SongEngineError("Musikmotoren returnerede ikke et jobnummer.")
        return task

    def poll(self, task):
        rows = self._json("/query_result", body={"task_id_list": [task]})
        if not isinstance(rows, list) or len(rows) != 1 or rows[0].get("task_id") != task:
            raise SongEngineError("Musikjobbet kunne ikke genkendes.")
        row = rows[0]
        if row.get("status") == 2:
            raise SongEngineError("Musikmotoren kunne ikke lave sangen. Originalen er bevaret.")
        if row.get("status") != 1:
            return None
        result = row.get("result")
        if isinstance(result, str):
            try:
                result = json.loads(result)
            except ValueError as exc:
                raise SongEngineError("Musikresultatet kunne ikke læses.") from exc
        if not isinstance(result, list) or not result or not isinstance(result[0], dict):
            raise SongEngineError("Musikresultatet mangler en lydfil.")
        path = result[0].get("file")
        if not isinstance(path, str):
            raise SongEngineError("Musikresultatet mangler en lydfil.")
        return path

    def download(self, path, destination):
        url = urljoin(self.base + "/", path)
        parsed, origin = urlsplit(url), urlsplit(self.base)
        if (parsed.scheme, parsed.netloc) != (origin.scheme, origin.netloc) or parsed.path != "/v1/audio":
            raise SongEngineError("Musikmotoren returnerede en uventet lydadresse.")
        try:
            with self.session.get(url, timeout=(5, 90), stream=True, allow_redirects=False) as response:
                response.raise_for_status()
                size = 0
                with Path(destination).open("wb") as target:
                    for chunk in response.iter_content(128_000):
                        size += len(chunk)
                        if size > 70_000_000:
                            raise SongEngineError("Sangfilen blev for stor. Prøv et kortere nummer.")
                        target.write(chunk)
            if size < 100:
                raise SongEngineError("Musikmotoren returnerede en tom fil.")
            canonical_wave(destination)
        except requests.RequestException as exc:
            raise SongEngineOffline("Den færdige sang kunne ikke hentes endnu. Det kendte job kontrolleres igen.") from exc
        except (ValueError, OSError) as exc:
            raise SongEngineError("Musikmotoren returnerede en lydfil, der ikke kunne læses.") from exc

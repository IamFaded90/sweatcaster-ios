"""Durable, paired song jobs. Never modifies source tracks or sends cloud audio."""

import base64
from hashlib import sha256
from io import BytesIO
import json
import math
from pathlib import Path
import threading
import time
from uuid import UUID
import wave

from sweatcaster.song_engine import SongEngine, SongEngineError, SongEngineOffline
from sweatcaster.song_audio import fit_wave


class SongStudioError(ValueError):
    pass


def trim_reference(source, destination, seconds):
    """Copy the requested prefix without changing the saved source reference."""
    with wave.open(str(source), "rb") as original:
        count = min(original.getnframes(), round(seconds * original.getframerate()))
        with wave.open(str(destination), "wb") as excerpt:
            excerpt.setparams(original.getparams())
            remaining = count
            while remaining:
                chunk = original.readframes(min(remaining, 16_384))
                frame_size = original.getnchannels() * original.getsampwidth()
                if not chunk or len(chunk) % frame_size:
                    raise SongStudioError("Musikreferencen kunne ikke læses færdig.")
                excerpt.writeframesraw(chunk)
                remaining -= len(chunk) // frame_size


def identifier(raw):
    try:
        return str(UUID(str(raw)))
    except ValueError:
        raise SongStudioError("Sangens ID kunne ikke læses.") from None


def fields(body):
    def text(key, maximum, required=False):
        value = body.get(key, "")
        if not isinstance(value, str) or len(value) > maximum or (required and not value.strip()):
            raise SongStudioError("Tjek sangens titel, beskrivelse og tekst.")
        return value.strip()
    if not isinstance(body, dict):
        raise SongStudioError("Sangens oplysninger mangler.")
    seconds = body.get("seconds", 30)
    if type(seconds) not in (int, float) or not math.isfinite(seconds) or not 10 <= seconds <= 180:
        raise SongStudioError("Vælg mellem 10 og 180 sekunder.")
    mode = body.get("mode", "new")
    if mode not in {"new", "inspiration", "remix"} or type(body.get("instrumental", False)) is not bool:
        raise SongStudioError("Vælg sang, inspiration eller remix.")
    language = body.get("language", "da")
    if language not in ("da", "en"):
        raise SongStudioError("Vælg dansk eller engelsk til sangteksten.")
    if mode == "remix" and not body.get("source"):
        raise SongStudioError("Et remix kræver selve lydfilen. En favoritmarkering er ikke en lydfil.")
    if body.get("voice") and (body.get("instrumental") or mode == "inspiration" and body.get("source")):
        raise SongStudioError("Prøv egen stemme med en ny sang eller et remix, uden instrumentalvalg.")
    return {"title": text("title", 100, True), "prompt": text("prompt", 1500, True),
            "lyrics": text("lyrics", 6000), "favorite": text("favorite", 220),
            "mode": mode, "seconds": float(seconds), "instrumental": body.get("instrumental", False), "language": language}


class SongStudio:
    def __init__(self, root, engine=None, idle=None):
        self.root = Path(root) / "song-studio"
        self.root.mkdir(parents=True, exist_ok=True)
        self.engine, self.idle = engine or SongEngine(), idle or (lambda: True)
        self.lock = threading.RLock()
        self.working = set()
        self.stop_signal, self.thread = threading.Event(), None

    def folder(self, key):
        return self.root / identifier(key)

    def save(self, value):
        path = self.folder(value["id"]) / "job.json"
        temporary = path.with_suffix(".tmp")
        temporary.write_text(json.dumps(value, ensure_ascii=False), encoding="utf-8")
        temporary.replace(path)

    def load(self, key):
        path = self.folder(key) / "job.json"
        if not path.is_file() or path.stat().st_size > 40_000:
            raise SongStudioError("Sangjobbet findes ikke.")
        return json.loads(path.read_text(encoding="utf-8"))

    @staticmethod
    def public(value):
        return {k: v for k, v in value.items() if k not in {"hash", "engineID"}}

    def submit(self, key, body):
        key = identifier(key)
        value = fields(body)
        incoming = {}
        for name in ("source", "voice"):
            raw = body.get(name)
            if raw is not None:
                try:
                    if not isinstance(raw, str) or len(raw) > 16_000_000:
                        raise ValueError
                    data = base64.b64decode(raw, validate=True)
                    if not 44 <= len(data) <= 12_000_000:
                        raise ValueError
                    incoming[name] = data
                except (ValueError, TypeError):
                    raise SongStudioError("Vælg en kort lydreference på højst 12 MB.") from None
        digest = sha256(json.dumps(value, sort_keys=True).encode()
                        + sha256(incoming.get("source", b"")).digest()
                        + sha256(incoming.get("voice", b"")).digest()).hexdigest()
        durations = {}
        for name, data in incoming.items():
            limit = 180 if name == "source" else 60
            try:
                durations[name] = self.checked_wave(BytesIO(data), maximum_seconds=limit)
            except SongStudioError:
                label = "Musikreferencen" if name == "source" else "Stemmereferencen"
                raise SongStudioError(f"{label} skal være en læsbar WAV på højst {limit} sekunder med højst to kanaler.") from None
        if value["mode"] == "remix" and value["seconds"] > durations["source"] + 0.1:
            raise SongStudioError("Remixet kan ikke være længere end lydklippet. Vælg en længere lydfil eller en kortere sang.")
        with self.lock:
            folder = self.folder(key)
            if (folder / "removed").exists():
                raise SongStudioError("Sangen er slettet. Start et nyt job.")
            if (folder / "job.json").is_file():
                old = self.load(key)
                if old["hash"] != digest:
                    raise SongStudioError("Dette jobnummer bruges allerede til en anden sang.")
                return self.public(old)
            folder.mkdir(exist_ok=True)
            for name, data in incoming.items():
                path = folder / (name + ".wav")
                path.write_bytes(data)
                try:
                    self.checked_wave(path, maximum_seconds=180 if name == "source" else 60)
                except SongStudioError:
                    path.unlink(missing_ok=True)
                    raise
            value.update(id=key, hash=digest, state="queued", created=time.time(), notice="Venter på PC’ens musikmotor.")
            self.save(value)
            return self.public(value)

    @staticmethod
    def checked_wave(path, maximum_seconds=190):
        try:
            with wave.open(path if hasattr(path, "read") else str(path)) as audio:
                seconds = audio.getnframes() / audio.getframerate()
                if audio.getnchannels() not in (1, 2) or audio.getsampwidth() not in (2, 3, 4) or not 1 <= seconds <= maximum_seconds:
                    raise ValueError
                expected = audio.getnframes() * audio.getnchannels() * audio.getsampwidth()
                if expected > 70_000_000 or len(audio.readframes(audio.getnframes())) != expected:
                    raise ValueError
        except (OSError, EOFError, wave.Error, ValueError, ZeroDivisionError):
            raise SongStudioError("Lydfilen skal være en læsbar WAV med højst to kanaler.") from None
        return seconds

    def list(self):
        with self.lock:
            values = []
            for path in self.root.glob("*/job.json"):
                try:
                    value = self.load(path.parent.name)
                    if value["state"] != "removed":
                        values.append(self.public(value))
                except (OSError, ValueError):
                    continue
            return {"jobs": sorted(values, key=lambda row: row["created"], reverse=True)[:100]}

    def remove(self, key):
        with self.lock:
            value = self.load(key)
            # ACE-Step has no per-job cancellation endpoint. Removing our
            # record does not guarantee that a submitted task stopped.
            engine_may_continue = value.get("engineMayContinue", False) or value["state"] in {"submitting", "rendering"} or (
                value["state"] == "failed" and "Afsendelsen blev afbrudt" in value.get("notice", "")
            )
            folder = self.folder(key)
            (folder / "removed").touch()
            value.update(state="removed", notice="Slettet.", cleanupPending=True,
                         engineMayContinue=engine_may_continue)
            self.save(value)
            pending = self._cleanup_removed_locked(key)
            result = {"removed": True, "engineMayContinue": engine_may_continue}
            if pending:
                result["cleanupPending"] = True
            return result

    def _cleanup_removed_locked(self, key):
        """Only delete this removed job's own files; retry locks after restart."""
        key = identifier(key)
        value = self.load(key)
        if value["state"] != "removed":
            return False
        if key in self.working:
            return True
        folder = self.folder(key)
        pending = False
        for name in ("song.wav", "song.tmp", "source.wav", "source-trimmed.wav", "voice.wav"):
            try:
                (folder / name).unlink(missing_ok=True)
            except OSError:
                # Windows can keep a reference or output open until the
                # in-flight transfer closes it. Preserve the durable marker.
                pending = True
        if value.get("cleanupPending") != pending:
            value["cleanupPending"] = pending
            self.save(value)
        return pending

    def _retry_cleanup_locked(self):
        for path in self.root.glob("*/job.json"):
            try:
                key = identifier(path.parent.name)
                value = self.load(key)
                if value.get("state") == "removed" and value.get("cleanupPending"):
                    self._cleanup_removed_locked(key)
            except (OSError, ValueError, KeyError):
                # A later pass can retry; never touch unrelated files.
                continue

    def work_once(self):
        with self.lock:
            self._retry_cleanup_locked()
            rows = self.list()["jobs"]
            row = next((x for x in reversed(rows) if x["state"] in {"queued", "rendering", "submitting"}
                        and x["id"] not in self.working), None)
            if row is None or not self.idle():
                return False
            value = self.load(row["id"])
            self.working.add(value["id"])
        try:
            if value["state"] == "submitting":
                raise SongEngineError("Afsendelsen blev afbrudt. Jobbet gentages ikke automatisk; tjek musikmotoren først.")
            if value["state"] == "queued":
                if not self.engine.available():
                    return False
                with self.lock:
                    if self.load(value["id"])["state"] == "removed":
                        return True
                    value["state"], value["notice"] = "submitting", "Sender til musikmotoren…"
                    self.save(value)
                source = self.folder(value["id"]) / "source.wav"
                voice = self.folder(value["id"]) / "voice.wav"
                trimmed = self.folder(value["id"]) / "source-trimmed.wav"
                try:
                    if value["mode"] == "remix" and source.exists():
                        trim_reference(source, trimmed, value["seconds"])
                        source_for_engine = trimmed
                    else:
                        source_for_engine = source if source.exists() else None
                    task = self.engine.submit(value, source_for_engine, voice if voice.exists() else None)
                finally:
                    try:
                        trimmed.unlink(missing_ok=True)
                    except OSError:
                        # Removal also retries this bounded per-job scratch file.
                        pass
                with self.lock:
                    if self.load(value["id"])["state"] == "removed":
                        return True
                    value.update(engineID=task, state="rendering", notice="PC’en skaber sangen.")
                    self.save(value)
            path = self.engine.poll(value["engineID"])
            if path is None:
                return False
            destination = self.folder(value["id"]) / "song.tmp"
            self.engine.download(path, destination)
            duration = self.checked_wave(destination)
            if duration + 0.1 < value["seconds"]:
                destination.unlink(missing_ok=True)
                raise SongEngineError("Musikmotoren leverede ikke den valgte længde. Prøv et nyt kort forsøg.")
            fit_wave(destination, value["seconds"])
            duration = self.checked_wave(destination)
            with self.lock:
                if self.load(value["id"])["state"] == "removed":
                    destination.unlink(missing_ok=True)
                    return True
                destination.replace(destination.with_name("song.wav"))
                value.update(state="completed", notice="Sangen er klar.", seconds=duration)
                self.save(value)
            return True
        except SongEngineOffline as exc:
            if value.get("engineID") and value["state"] == "rendering":
                with self.lock:
                    if self.load(value["id"])["state"] != "removed":
                        value["notice"] = str(exc)
                        self.save(value)
                return False
            # Unknown submit outcome must never be automatically submitted twice.
            with self.lock:
                if self.load(value["id"])["state"] != "removed":
                    value.update(state="failed", notice="Afsendelsen blev afbrudt. Tjek musikmotoren før et nyt forsøg.")
                    self.save(value)
            return True
        except (SongEngineError, SongStudioError, OSError) as exc:
            with self.lock:
                if self.load(value["id"])["state"] != "removed":
                    value.update(state="failed", notice=str(exc))
                    self.save(value)
            return True
        finally:
            with self.lock:
                self.working.discard(value["id"])
                try:
                    if self.load(value["id"])["state"] == "removed":
                        self._cleanup_removed_locked(value["id"])
                except (OSError, SongStudioError):
                    # The saved cleanupPending flag lets a later pass retry.
                    pass

    def start(self):
        if self.thread and self.thread.is_alive():
            return
        self.stop_signal.clear()
        def run():
            while not self.stop_signal.is_set():
                try:
                    self.work_once()
                except Exception:
                    import logging
                    logging.getLogger(__name__).exception("Song queue unavailable")
                self.stop_signal.wait(3)
        self.thread = threading.Thread(target=run, daemon=True, name="fadedai-song-studio")
        self.thread.start()

    def stop(self):
        self.stop_signal.set()
        if self.thread:
            self.thread.join(timeout=5)

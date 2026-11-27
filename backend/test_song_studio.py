import base64
from io import BytesIO
import json
from pathlib import Path
import sys
import threading
from uuid import uuid4
import wave

import pytest

from sweatcaster.song_engine import SongEngine, SongEngineError
from sweatcaster.song_studio import SongStudio, SongStudioError
from sweatcaster.song_audio import canonical_wave
from sweatcaster.song_engine import SongEngineOffline


def audio(seconds=2):
    data = BytesIO()
    with wave.open(data, "wb") as output:
        output.setnchannels(1)
        output.setsampwidth(2)
        output.setframerate(24000)
        output.writeframes(b"\x01\x00" * int(24000 * seconds))
    return data.getvalue()


def draft(**changes):
    return {"title": "Mit nummer", "prompt": "Warm instrumental house", "lyrics": "",
            "mode": "new", "seconds": 20, "instrumental": True, **changes}


def test_cold_submit_waits_for_model_load_without_extending_health_checks():
    class Response:
        content = b'{}'
        def raise_for_status(self): pass
        def json(self): return {"data": {"task_id": "one", "status": "ok", "service": "ACE-Step API"}}
    class Session:
        trust_env = True
        def __init__(self): self.calls = []
        def post(self, url, **kwargs): self.calls.append((url, kwargs)); return Response()
        def get(self, url, **kwargs): self.calls.append((url, kwargs)); return Response()
    session = Session()
    engine = SongEngine(session=session)
    assert engine.available()
    assert engine.submit(draft()) == "one"
    assert session.calls[0][1]["timeout"] == (2, 3)
    assert session.calls[1][1]["timeout"] == (5, 360)


def test_real_ace_float_wav_becomes_pcm_without_changing_duration(tmp_path):
    import struct
    data = struct.pack("<4f", -0.8, -0.2, 0.2, 0.8) * 24_000
    fmt = struct.pack("<HHIIHH", 3, 2, 48_000, 384_000, 8, 32)
    payload = b"fmt " + struct.pack("<I", len(fmt)) + fmt + b"data" + struct.pack("<I", len(data)) + data
    path = tmp_path / "ace.wav"
    path.write_bytes(b"RIFF" + struct.pack("<I", 4 + len(payload)) + b"WAVE" + payload)
    canonical_wave(path)
    assert SongStudio.checked_wave(path) == 1
    with wave.open(str(path)) as converted:
        assert converted.getsampwidth() == 2
        assert converted.getnchannels() == 2
        assert converted.readframes(1) != b"\0" * 4


def test_truncated_wave_cannot_be_marked_complete(tmp_path):
    path = tmp_path / "bad.wav"
    path.write_bytes(audio(2)[:-2000])
    with pytest.raises(SongStudioError):
        SongStudio.checked_wave(path)


class Engine:
    def __init__(self):
        self.calls = []
        self.ready = True
        self.answer = "/v1/audio?path=song.wav"
    def available(self):
        return self.ready
    def submit(self, value, source, voice):
        self.calls.append((value["id"], bool(source), bool(voice)))
        self.seconds = value["seconds"]
        return "engine-task"
    def poll(self, task):
        assert task == "engine-task"
        return self.answer
    def download(self, path, destination):
        Path(destination).write_bytes(audio(self.seconds))


def test_song_is_real_wave_and_repeated_request_is_not_generated_again(tmp_path):
    engine = Engine()
    store = SongStudio(tmp_path, engine=engine)
    key, body = str(uuid4()), draft()
    assert store.submit(key, body)["state"] == "queued"
    assert store.work_once()
    assert store.submit(key, body)["state"] == "completed"
    assert store.load(key)["seconds"] == 20
    assert (store.folder(key) / "song.wav").read_bytes().startswith(b"RIFF")
    assert len(engine.calls) == 1
    with pytest.raises(SongStudioError):
        store.submit(key, draft(prompt="different"))


def test_pending_job_resumes_without_second_submission(tmp_path):
    engine = Engine()
    engine.answer = None
    key = str(uuid4())
    SongStudio(tmp_path, engine=engine).submit(key, draft())
    store = SongStudio(tmp_path, engine=engine)
    assert not store.work_once()
    assert store.load(key)["state"] == "rendering"
    engine.answer = "/v1/audio?path=song.wav"
    assert SongStudio(tmp_path, engine=engine).work_once()
    assert len(engine.calls) == 1


def test_poll_network_failure_keeps_known_job_and_never_resubmits(tmp_path):
    engine = Engine()
    engine.answer = None
    store = SongStudio(tmp_path, engine=engine)
    key = str(uuid4())
    store.submit(key, draft())
    assert not store.work_once()
    def disconnected(_):
        raise SongEngineOffline("offline")
    engine.poll = disconnected
    assert not store.work_once()
    assert store.load(key)["state"] == "rendering"
    assert store.load(key)["engineID"] == "engine-task"
    engine.poll = lambda _: "/v1/audio?path=song.wav"
    assert store.work_once()
    assert len(engine.calls) == 1


def test_long_cover_is_cut_to_requested_length_without_padding(tmp_path):
    engine = Engine()
    engine.download = lambda path, destination: Path(destination).write_bytes(audio(30))
    store = SongStudio(tmp_path, engine=engine)
    key = str(uuid4())
    store.submit(key, draft())
    assert store.work_once()
    assert store.load(key)["state"] == "completed"
    assert SongStudio.checked_wave(store.folder(key) / "song.wav") == 20


def test_ambiguous_submission_is_never_replayed_after_restart(tmp_path):
    engine = Engine()
    store = SongStudio(tmp_path, engine=engine)
    key = str(uuid4())
    store.submit(key, draft())
    value = store.load(key)
    value["state"] = "submitting"
    store.save(value)
    assert SongStudio(tmp_path, engine=engine).work_once()
    assert store.load(key)["state"] == "failed"
    assert engine.calls == []


def test_busy_computer_or_offline_engine_does_not_consume_job(tmp_path):
    engine = Engine()
    store = SongStudio(tmp_path, engine=engine, idle=lambda: False)
    key = str(uuid4())
    store.submit(key, draft())
    assert not store.work_once()
    store.idle = lambda: True
    engine.ready = False
    assert not store.work_once()
    assert store.load(key)["state"] == "queued" and engine.calls == []


def test_reference_and_own_voice_are_separate_from_original_file(tmp_path):
    engine = Engine()
    store = SongStudio(tmp_path, engine=engine)
    key = str(uuid4())
    source = base64.b64encode(audio(20)).decode()
    body = draft(mode="remix", source=source, voice=source, instrumental=False)
    store.submit(key, body)
    assert store.work_once()
    assert engine.calls == [(key, True, True)]
    assert (store.folder(key) / "source.wav").read_bytes() == audio(20)
    assert "source" not in store.public(store.load(key))
    assert "voice" not in store.public(store.load(key))


def test_music_reference_can_be_180_seconds_but_voice_remains_limited_to_60(tmp_path):
    store = SongStudio(tmp_path, engine=Engine())
    source = base64.b64encode(audio(180)).decode()
    voice = base64.b64encode(audio(60)).decode()
    key = str(uuid4())
    assert store.submit(key, draft(mode="remix", source=source, voice=voice,
                                   seconds=180, instrumental=False))["state"] == "queued"
    assert SongStudio.checked_wave(store.folder(key) / "source.wav", maximum_seconds=180) == 180
    assert SongStudio.checked_wave(store.folder(key) / "voice.wav", maximum_seconds=60) == 60
    with pytest.raises(SongStudioError, match="180 sekunder"):
        store.submit(str(uuid4()), draft(source=base64.b64encode(audio(181)).decode()))
    with pytest.raises(SongStudioError, match="60 sekunder"):
        store.submit(str(uuid4()), draft(voice=base64.b64encode(audio(61)).decode(), instrumental=False))


def test_remix_refuses_a_reference_shorter_than_requested_song(tmp_path):
    store = SongStudio(tmp_path, engine=Engine())
    body = draft(mode="remix", source=base64.b64encode(audio(10)).decode(), seconds=20)
    with pytest.raises(SongStudioError, match="ikke være længere end lydklippet"):
        store.submit(str(uuid4()), body)


def test_remix_passes_trimmed_copy_to_engine_and_preserves_full_reference(tmp_path):
    class CheckingEngine(Engine):
        def submit(self, value, source, voice):
            assert source.name == "source-trimmed.wav"
            assert SongStudio.checked_wave(source, maximum_seconds=180) == 10
            assert SongStudio.checked_wave(source.parent / "source.wav", maximum_seconds=180) == 20
            return super().submit(value, source, voice)

    original = audio(20)
    store = SongStudio(tmp_path, engine=CheckingEngine())
    key = str(uuid4())
    store.submit(key, draft(mode="remix", source=base64.b64encode(original).decode(), seconds=10))
    assert store.work_once()
    assert store.load(key)["state"] == "completed"
    assert (store.folder(key) / "source.wav").read_bytes() == original
    assert not (store.folder(key) / "source-trimmed.wav").exists()
    assert SongStudio.checked_wave(store.folder(key) / "song.wav") == 10


def test_remix_keeps_original_when_engine_connection_fails(tmp_path):
    class DisconnectedEngine(Engine):
        def submit(self, value, source, voice):
            assert source.name == "source-trimmed.wav" and source.exists()
            raise SongEngineOffline("simulated connection failure")

    original = audio(20)
    store = SongStudio(tmp_path, engine=DisconnectedEngine())
    key = str(uuid4())
    store.submit(key, draft(mode="remix", source=base64.b64encode(original).decode(), seconds=10))
    assert store.work_once()
    assert store.load(key)["state"] == "failed"
    assert (store.folder(key) / "source.wav").read_bytes() == original
    assert not (store.folder(key) / "source-trimmed.wav").exists()


def test_delete_removes_audio_and_cannot_resurrect_old_job(tmp_path):
    store = SongStudio(tmp_path, engine=Engine())
    key = str(uuid4())
    store.submit(key, draft())
    store.work_once()
    assert store.remove(key) == {"removed": True, "engineMayContinue": False}
    assert not (store.folder(key) / "song.wav").exists()
    assert store.list() == {"jobs": []}
    with pytest.raises(SongStudioError):
        store.submit(key, draft())


def test_locked_windows_file_is_retried_after_restart_without_reviving_job(tmp_path, monkeypatch):
    store = SongStudio(tmp_path, engine=Engine())
    key = str(uuid4())
    source = base64.b64encode(audio(10)).decode()
    body = draft(mode="remix", source=source, seconds=10)
    store.submit(key, body)
    reference = store.folder(key) / "source.wav"
    unrelated = store.folder(key) / "notes.txt"
    unrelated.write_text("Beholdes", encoding="utf-8")
    original_unlink = Path.unlink
    locked = True

    def windows_unlink(path, *args, **kwargs):
        if path == reference and locked:
            raise PermissionError("simulated Windows sharing violation")
        return original_unlink(path, *args, **kwargs)

    monkeypatch.setattr(Path, "unlink", windows_unlink)
    assert store.remove(key) == {"removed": True, "engineMayContinue": False, "cleanupPending": True}
    assert reference.exists()
    assert store.load(key)["cleanupPending"] is True
    assert store.list() == {"jobs": []}
    with pytest.raises(SongStudioError):
        store.submit(key, body)
    restarted = SongStudio(tmp_path, engine=Engine())
    assert not restarted.work_once()
    assert reference.exists()
    locked = False
    restarted.idle = lambda: False  # Cleanup must also run while the PC is busy.
    assert not restarted.work_once()
    assert not reference.exists()
    assert unrelated.read_text(encoding="utf-8") == "Beholdes"
    assert restarted.load(key)["cleanupPending"] is False


@pytest.mark.skipif(sys.platform != "win32", reason="Windows sharing semantics")
def test_actual_windows_shared_file_is_removed_once_handle_closes(tmp_path):
    import ctypes
    from ctypes import wintypes

    kernel = ctypes.WinDLL("kernel32", use_last_error=True)
    kernel.CreateFileW.argtypes = (wintypes.LPCWSTR, wintypes.DWORD, wintypes.DWORD, wintypes.LPVOID,
                                  wintypes.DWORD, wintypes.DWORD, wintypes.HANDLE)
    kernel.CreateFileW.restype = wintypes.HANDLE
    kernel.CloseHandle.argtypes = (wintypes.HANDLE,)
    kernel.CloseHandle.restype = wintypes.BOOL
    store = SongStudio(tmp_path, engine=Engine())
    key = str(uuid4())
    store.submit(key, draft(mode="remix", source=base64.b64encode(audio(10)).decode(), seconds=10))
    reference = store.folder(key) / "source.wav"
    # Share reads and writes, but deny FILE_SHARE_DELETE while the handle is open.
    handle = kernel.CreateFileW(str(reference), 0x80000000, 0x00000001 | 0x00000002,
                                None, 3, 0x00000080, None)
    assert handle != wintypes.HANDLE(-1).value, ctypes.get_last_error()
    try:
        result = store.remove(key)
        assert result.get("cleanupPending") is True
        assert reference.exists()
    finally:
        assert kernel.CloseHandle(handle)
    assert not store.work_once()
    assert not reference.exists()
    assert store.load(key)["cleanupPending"] is False


def test_delete_during_download_finishes_cleanup_after_worker_closes_file(tmp_path):
    started, finish = threading.Event(), threading.Event()

    class SlowEngine(Engine):
        def download(self, path, destination):
            started.set()
            if not finish.wait(timeout=5):
                raise RuntimeError("test timed out")
            Path(destination).write_bytes(audio(self.seconds))

    store = SongStudio(tmp_path, engine=SlowEngine())
    key = str(uuid4())
    store.submit(key, draft())
    errors = []

    def run():
        try:
            store.work_once()
        except Exception as exc:
            errors.append(exc)

    thread = threading.Thread(target=run)
    thread.start()
    try:
        assert started.wait(timeout=5)
        result = store.remove(key)
        assert result == {"removed": True, "engineMayContinue": True, "cleanupPending": True}
        assert store.remove(key)["engineMayContinue"] is True
        assert store.list() == {"jobs": []}
    finally:
        finish.set()
        thread.join(timeout=5)
    assert not thread.is_alive()
    assert not errors
    assert not (store.folder(key) / "song.tmp").exists()
    assert not (store.folder(key) / "song.wav").exists()
    assert store.load(key)["cleanupPending"] is False


@pytest.mark.parametrize("state,notice,may_continue", [
    ("queued", "Venter", False),
    ("submitting", "Sender", True),
    ("rendering", "Skaber sangen", True),
    ("failed", "Afsendelsen blev afbrudt. Tjek musikmotoren før et nyt forsøg.", True),
    ("failed", "Ugyldig fil", False),
])
def test_delete_reports_when_engine_might_still_be_working(tmp_path, state, notice, may_continue):
    store = SongStudio(tmp_path, engine=Engine())
    key = str(uuid4())
    store.submit(key, draft())
    value = store.load(key)
    value.update(state=state, notice=notice)
    store.save(value)
    assert store.remove(key) == {"removed": True, "engineMayContinue": may_continue}
    assert store.list() == {"jobs": []}


def test_remix_needs_audio_and_invalid_reference_is_rejected(tmp_path):
    store = SongStudio(tmp_path, engine=Engine())
    for body in [draft(mode="remix", favorite="Only a title"),
                 draft(source="not base64"), draft(source=base64.b64encode(b"broken" * 30).decode()),
                 draft(seconds=float("nan"))]:
        with pytest.raises(SongStudioError):
            store.submit(str(uuid4()), body)


def test_download_cannot_follow_external_result_url(tmp_path):
    engine = SongEngine()
    with pytest.raises(SongEngineError):
        engine.download("https://example.org/v1/audio?path=song.wav", tmp_path / "song.wav")
    with pytest.raises(SongEngineError):
        SongEngine("https://example.org")


def test_too_short_output_is_not_reported_as_completed(tmp_path):
    engine = Engine()
    engine.download = lambda path, destination: Path(destination).write_bytes(audio())
    store = SongStudio(tmp_path, engine=engine)
    key = str(uuid4())
    store.submit(key, draft(seconds=30))
    assert store.work_once()
    assert store.load(key)["state"] == "failed"
    assert not (store.folder(key) / "song.wav").exists()


def test_progress_tracks_confirmed_engine_stages_without_resubmitting(tmp_path):
    engine = Engine()
    engine.answer = None
    store = SongStudio(tmp_path, engine=engine)
    key = str(uuid4())
    accepted = store.submit(key, draft())
    assert accepted["progress"]["stage"] == "queued"
    assert accepted["progress"]["lastChecked"] is None
    assert not store.work_once()
    running = store.public(store.load(key))
    assert running["progress"]["stage"] == "rendering"
    assert running["progress"]["lastChecked"] >= accepted["created"]
    assert "engineID" not in running
    old_download = engine.download
    def download(path, destination):
        assert store.public(store.load(key))["progress"]["stage"] == "saving"
        old_download(path, destination)
    engine.download = download
    engine.answer = "/v1/audio?path=song.wav"
    assert store.work_once()
    assert store.public(store.load(key))["progress"]["stage"] == "completed"
    assert len(engine.calls) == 1


def test_queue_explains_unavailable_engine_and_busy_pc(tmp_path):
    engine = Engine()
    engine.ready = False
    store = SongStudio(tmp_path, engine=engine)
    key = str(uuid4())
    store.submit(key, draft())
    assert not store.work_once()
    assert "ACE-Step svarer" in store.load(key)["notice"]
    store.idle = lambda: False
    assert not store.work_once()
    assert "andre opgaver" in store.load(key)["notice"]
    assert store.load(key)["state"] == "queued"
    assert engine.calls == []

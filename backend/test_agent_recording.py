from array import array
import io
import shutil
import subprocess
import wave

from fastapi import FastAPI, HTTPException
from fastapi.responses import JSONResponse
from fastapi.testclient import TestClient
import pytest

from sweatcaster import agent_recording as rec
from sweatcaster.dto import ApiError


def make_wav(channels=2, seconds=3, duplicate=False):
    count = rec.RATE * seconds
    samples = array("h", [0]) * (count * channels)
    for i in range(count):
        first = 1000 if rec.RATE // 2 <= i < rec.RATE else 0
        samples[channels*i] = first
        if channels == 2:
            samples[2*i+1] = first if duplicate else (2000 if rec.RATE * 2 <= i < rec.RATE * 5 // 2 else 0)
    stream = io.BytesIO()
    with wave.open(stream, "wb") as output:
        output.setparams((channels, 2, rec.RATE, 0, "NONE", ""))
        output.writeframes(samples.tobytes())
    return stream.getvalue()


@pytest.fixture
def api(monkeypatch):
    app = FastAPI()
    @app.exception_handler(ApiError)
    async def report(_, error):
        return JSONResponse({"error": error.code}, status_code=error.status_code)
    def authorize(request, settings):
        if request.headers.get("authorization") != "Bearer test":
            raise HTTPException(401)
    def speech(clip, start, end, settings, *, language):
        peak = max(array("h", clip))
        return [{"start": start, "end": end, "text": f"{language} {peak}"}]
    monkeypatch.setattr(rec, "speech", speech)
    rec.register_recording(app, None, authorize)
    return TestClient(app)


PAIR = {"Authorization": "Bearer test"}
ROUTE = "/api/modules/v1/agent-recording/"
requires_ffmpeg = pytest.mark.skipif(not shutil.which("ffmpeg") or not shutil.which("ffprobe"),
                                     reason="FFmpeg required")


def test_route_checks_auth_then_format_size_and_slot(api, monkeypatch):
    assert api.post(ROUTE + "wav").status_code == 401
    assert api.post(ROUTE + "txt", headers=PAIR).status_code == 422
    assert api.post(ROUTE + "wav?language=xx", headers=PAIR).status_code == 422
    monkeypatch.setattr(rec, "MAX_BYTES", 3)
    assert api.post(ROUTE + "wav", content=b"1234", headers=PAIR).status_code == 413
    with rec.SLOT:
        assert api.post(ROUTE + "wav", content=b"123", headers=PAIR).status_code == 409


@requires_ffmpeg
def test_separate_channels_keep_relative_time_and_combined_is_default(api):
    source = make_wav()
    response = api.post(ROUTE + "wav?separate=true", headers=PAIR, content=source)
    assert response.status_code == 200 and response.headers["cache-control"] == "no-store"
    body = response.json()
    assert body["separateChannels"]
    assert [(row["channel"], row["text"]) for row in body["cues"]] == [(1, "da 1000"), (2, "da 2000")]
    assert [(row["start"], row["end"]) for row in body["cues"]] == [(.48, 1.02), (1.98, 2.52)]
    mixed = api.post(ROUTE + "wav?language=en", headers=PAIR, content=source).json()
    assert not mixed["separateChannels"] and len(mixed["cues"]) == 1
    assert mixed["cues"][0]["channel"] is None and mixed["cues"][0]["text"] == "en 1000"


@requires_ffmpeg
@pytest.mark.parametrize("channels", [1, 2])
def test_mono_and_identical_stereo_never_claim_separate_speakers(api, channels):
    result = api.post(ROUTE + "wav?separate=true", headers=PAIR,
                      content=make_wav(channels, duplicate=True)).json()
    assert not result["separateChannels"]
    assert len(result["cues"]) == 1 and result["cues"][0]["channel"] is None


@requires_ffmpeg
def test_m4a_and_duration_checks(api, tmp_path):
    file = tmp_path / "recording.m4a"
    subprocess.run(["ffmpeg", "-nostdin", "-v", "error", "-f", "wav", "-i", "pipe:0", "-c:a", "aac", str(file)],
                   input=make_wav(), check=True)
    response = api.post(ROUTE + "m4a?separate=true", headers=PAIR, content=file.read_bytes())
    assert response.status_code == 200 and [row["channel"] for row in response.json()["cues"]] == [1, 2]
    assert api.post(ROUTE + "m4a", headers=PAIR, content=b"bad file").status_code == 422
    assert api.post(ROUTE + "wav", headers=PAIR, content=make_wav(1, seconds=46)).status_code == 422


def test_silent_channels_do_not_reach_recognizer():
    assert rec.timed_audio(array("h", [0]) * 16000) is None


def test_dual_mono_survives_gain_difference_opposite_polarity_and_mixdown():
    left = array("h", [1000, -500, 25, -50] * 400)
    right = array("h", [-sample // 2 for sample in left])
    assert rec.shared_channel(left, right) == left
    assert rec.shared_channel(left, array("h", [0] * len(left))) is None


def test_channel_overlap_is_preserved_and_padded_cues_stay_within_file(monkeypatch):
    pcm = array("h")
    for frame in range(rec.RATE * 3):
        pcm.extend((800 if rec.RATE // 2 <= frame < rec.RATE * 2 else 0,
                    900 if rec.RATE <= frame < rec.RATE * 5 // 2 else 0))
    monkeypatch.setattr(rec, "decode", lambda *_: (pcm, 2))
    def padded(clip, start, end, settings, *, language):
        return [{"start": start, "end": end, "text": "Ord"},
                {"start": end - .1, "end": end, "text": "Uden for klippet"}]
    monkeypatch.setattr(rec, "speech", padded)
    rows = rec.transcript(b"", "wav", "da", True, None)["cues"]
    assert [(r["start"], r["end"], r["channel"]) for r in rows] == [(.48, 2.02, 1), (.98, 2.52, 2)]

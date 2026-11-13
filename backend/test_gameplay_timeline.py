"""Run against an installed checkpoint package without changing its files."""

from __future__ import annotations

from array import array
import json
from pathlib import Path
import shutil
import subprocess
import sys
from types import ModuleType, SimpleNamespace

import pytest
import sweatcaster

import install_video_commentary as installer


@pytest.fixture
def staged(tmp_path, monkeypatch):
    package = Path(sweatcaster.__file__).resolve().parent
    target = tmp_path / "sweatcaster"
    target.mkdir()
    for source in installer.changes():
        name = Path(source).name
        (target / name).write_bytes((package / name).read_bytes())
    for name in ("gameplay_hud.py", "gameplay_vision.py"):
        previous = package / name
        if previous.is_file():
            (target / name).write_bytes(previous.read_bytes())
    # Test the actual staged Python source while leaving the live checkpoint untouched.
    monkeypatch.setattr(installer, "atomic_write", lambda path, data: path.write_bytes(data))
    installer.install(tmp_path, apply=True)
    assert not installer.install(tmp_path)

    def load(name):
        path = target / f"{name}.py"
        module = ModuleType(f"staged_{name}")
        monkeypatch.setitem(sys.modules, module.__name__, module)
        exec(compile(path.read_bytes(), str(path), "exec"), module.__dict__)
        return module

    monkeypatch.syspath_prepend(str(target))
    hud = load("gameplay_hud")
    hud.GameplayEvent = load("models").GameplayEvent
    monkeypatch.setitem(sys.modules, "sweatcaster.gameplay_hud", hud)
    return load


@pytest.mark.parametrize(("fps", "budget"), [(2, 32), (1, 16)])
def test_ocr_samples_full_duration_with_dense_ending(staged, monkeypatch, fps, budget):
    analysis = staged("analysis")
    monkeypatch.setattr(analysis, "_read_frames", lambda *args: iter([b"frame"] * (180 * fps)))
    times = [time for time, _ in analysis._timeline_frames(Path("clip.mp4"), 2, 2, 180, fps, budget, None)]
    assert times[0] == 0
    assert any(70 <= time <= 110 for time in times)
    assert times[-4 * fps:] == [176 + index / fps for index in range(4 * fps)]
    assert len(times) <= budget + 4 * fps


def test_late_gameplay_survives_evidence_cap_and_render_keeps_full_clip(staged, monkeypatch):
    analysis = staged("analysis")
    monkeypatch.setitem(sys.modules, "sweatcaster.gameplay_vision", staged("gameplay_vision"))
    pipeline = staged("pipeline")

    def event(at, kind, source="tesseract"):
        return analysis.GameplayEvent(id=str(at), kind=kind, source=source, t_start=at, t_end=at,
                                      text=f"Event at {at}", confidence=0.7)

    events = analysis.aggregate([
        event(4, "kill"), *(event(i, "ocr_text") for i in range(5, 45)),
        event(160, "audio_spike", "audio_rms"), event(168, "kill"),
    ])
    assert len(events) == 24
    assert {event.t_start for event in events if event.kind == "kill"} == {4, 168}
    clip = SimpleNamespace(probe=SimpleNamespace(duration=180), events=events, keyframes=[], crop_mode_used="auto")
    reaction = SimpleNamespace(t_start=168, event_ids=["168"])
    timed = SimpleNamespace(lines=[reaction])
    rendered = []
    monkeypatch.setattr(pipeline, "attach_estimated_timings", lambda *_: timed)
    monkeypatch.setattr(pipeline, "render_vertical", lambda **kwargs: rendered.append(kwargs) or [])
    monkeypatch.setattr(pipeline, "trim_rendered", lambda *_: pytest.fail("Render removed earlier footage"))
    pipeline.Pipeline.render(
        SimpleNamespace(sounds={}), source=Path("original.mp4"), output=Path("result.mp4"),
        workdir=Path("."), analysis=clip, plan=SimpleNamespace(commentary_source="local"),
        bundle=SimpleNamespace(clips=[], source="local"), job={"denoise": False}, cancel=None,
    )
    assert rendered[0]["probe"].duration == 180
    assert rendered[0]["lines"] == [reaction]


def test_audio_keeps_a_late_spike_after_the_first_eight(staged, monkeypatch):
    analysis = staged("analysis")
    amplitudes = [0, 7000, 0, 0] * 10 + [0] * 70 + [4000, 12000, 0]
    pcm = array("h", (value for amplitude in amplitudes for value in [amplitude] * 800)).tobytes()
    monkeypatch.setattr(analysis, "require_ffmpeg", lambda: None)
    monkeypatch.setattr(analysis.subprocess, "run", lambda *a, **kw: SimpleNamespace(returncode=0, stdout=pcm))
    probe = SimpleNamespace(has_audio=True, duration=len(amplitudes) / 10)
    events, status = analysis.detect_spikes(Path("clip.mp4"), probe, None)
    assert status["ok"] and len(events) == 8
    assert events[-1].t_start == 11
    assert events[-1].evidence["peak"] == pytest.approx(12000 / 32768, abs=0.0001)


def test_commentary_stays_with_a_cited_ending_even_if_model_returns_zero(staged):
    commentary = staged("commentary")
    event = commentary.GameplayEvent(id="ending", kind="objective", source="tesseract", t_start=29.5,
                                     t_end=30, text="Target captured", confidence=0.7)
    payload = {"lines": [{"text": "The target is captured.", "event_ids": [event.id], "t_start": 0}]}
    lines, _, _ = commentary.validate_commentary(payload, events=[event], duration=30, allowlist=[],
                                                allow_cues=False, recent=[], enforce_repeat=False)
    assert lines[0].t_start == 29
    plan = commentary.CommentaryPlan.model_construct(lines=lines)
    timed = commentary.attach_estimated_timings(plan, [2], 30)
    assert timed.lines[0].t_start == 28
    assert timed.lines[0].t_end == 30


def test_spoken_reaction_rejects_frame_captions_and_detector_reports(staged):
    commentary = staged("commentary")
    caption = "A player stands next to a narrow doorway."
    visual = commentary.GameplayEvent(id="frame", kind="visual_observation", source="ollama_vision",
                                      t_start=26, t_end=26, text=caption, confidence=0.55)
    kill = commentary.GameplayEvent(id="finish", kind="kill", source="windows_ocr",
                                    t_start=27, t_end=27, text="ELIMINATED Opponent", confidence=0.7)
    options = dict(events=[visual, kill], duration=30, allowlist=[], allow_cues=False,
                   recent=[], enforce_repeat=False)
    for text, event_id in [(caption, visual.id), (f"Wow, {caption}", visual.id),
                           ("The screenshot shows a doorway.", visual.id),
                           ("One kill was observed.", kill.id)]:
        payload = {"lines": [{"text": text, "event_ids": [event_id], "t_start": 26}]}
        with pytest.raises(commentary.CommentaryError, match="React in your own words"):
            commentary.validate_commentary(payload, **options)

    payload = {"lines": [{"text": "Oof, that doorway feels tight.", "event_ids": [visual.id], "t_start": 26}]}
    lines, _, _ = commentary.validate_commentary(payload, **options)
    assert lines[0].text == "Oof, that doorway feels tight."
    payload["lines"][0]["text"] = "Nice elimination!"
    with pytest.raises(commentary.CommentaryError, match="invented a kill"):
        commentary.validate_commentary(payload, **options)
    payload["lines"][0]["event_ids"] = [kill.id]
    assert commentary.validate_commentary(payload, **options)[0][0].event_ids == [kill.id]


def test_player_death_is_not_supported_by_a_confirmed_elimination(staged):
    commentary = staged("commentary")
    kill = commentary.GameplayEvent(id="kill", kind="kill", source="windows_ocr",
                                    t_start=23, t_end=23, text="ELIMINATED Opponent", confidence=0.7)
    death = commentary.GameplayEvent(id="death", kind="death", source="windows_ocr",
                                     t_start=27, t_end=27, text="ELIMINATED BY Opponent", confidence=0.7)
    options = dict(events=[kill, death], duration=30, allowlist=[], allow_cues=False, recent=[], enforce_repeat=False)
    payload = {"lines": [{"text": "You got eliminated before you could enjoy it.", "event_ids": [kill.id]}]}
    with pytest.raises(commentary.CommentaryError, match="invented a death"):
        commentary.validate_commentary(payload, **options)
    payload["lines"][0]["event_ids"] = [death.id]
    assert commentary.validate_commentary(payload, **options)[0][0].event_ids == [death.id]
    payload["lines"][0]["text"] = "Nice shot!"
    with pytest.raises(commentary.CommentaryError, match="setback"):
        commentary.validate_commentary(payload, **options)
    payload["lines"][0]["text"] = "You went down right after sending that rival flying!"
    with pytest.raises(commentary.CommentaryError, match="second action"):
        commentary.validate_commentary(payload, **options)
    payload["lines"][0] = {"text": "You took out a whole team before getting eliminated yourself!",
                           "event_ids": [kill.id, death.id]}
    with pytest.raises(commentary.CommentaryError, match="team wipes"):
        commentary.validate_commentary(payload, **options)


def test_roast_retries_when_it_misses_the_end_and_keeps_kill_and_death_separate(staged):
    commentary = staged("commentary")

    def event(id, at, kind, source, text):
        return commentary.GameplayEvent(id=id, kind=kind, source=source, t_start=at,
                                        t_end=at, text=text, confidence=0.7)

    early = event("early", 4, "kill", "tesseract", "ELIMINATED Early")
    late = event("late", 26, "kill", "windows_ocr", "ELIMINATED Late")
    scoreboard = event("hud", 27, "objective", "windows_ocr", "Objective marker")
    final_death = event("death", 28, "death", "windows_ocr", "ELIMINATED BY Opponent")
    calls = []

    def chat(system, user, temperature):
        calls.append((system, user, temperature))
        if len(calls) == 1:
            body = json.loads(user)
            assert body["focus_event_id"] == final_death.id
            assert body["focus_event_kind"] == "death"
            assert body["json_shape"]["lines"][0]["event_ids"] == [final_death.id]
            assert "punchline" in body["style"]
            return json.dumps({"lines": [{"text": "Nice elimination!", "event_ids": [early.id]}]})
        assert "React to focus_event_id" in user
        return json.dumps({"lines": [
                               {"text": "You left that elimination a little late, didn't you?",
                                "event_ids": [late.id], "t_start": 2},
                               {"text": "Well, that was a very short honeymoon.",
                                "event_ids": [final_death.id], "t_start": 2},
                           ],
                           "gaps": ["The player was eliminated again near the middle of the clip."]})

    plan = commentary.write_commentary(settings=SimpleNamespace(commentary_mode="auto", ollama_model="local"),
                                       clip_id="clip", mood="roast", events=[early, late, scoreboard, final_death],
                                       duration=30, sounds=SimpleNamespace(allowlist=[]), recent=[], allow_cues=False,
                                       client=SimpleNamespace(chat=chat))
    assert len(calls) == 2
    assert plan.lines[0].event_ids == [late.id]
    assert plan.lines[0].t_start == 25.5
    assert plan.lines[1].event_ids == [final_death.id]
    assert plan.lines[1].t_start == 27.5
    assert plan.gaps == []


def test_vision_samples_ending_first_then_adds_observations_in_timeline_order(staged, monkeypatch):
    vision = staged("gameplay_vision")
    analysis = SimpleNamespace(probe=SimpleNamespace(duration=120), events=[], extractor_status={})
    positions = vision._frame_times(analysis)
    assert positions[0] == 119.75
    assert 90 < positions[1] < 119
    assert positions[2:] == pytest.approx([60, 18, 86.4, 36])
    monkeypatch.setattr(vision, "_observe", lambda *args: [(p, "A blue doorway is visible.") for p in positions])
    vision.add_visual_evidence(analysis, Path("clip.mp4"), None, None)
    assert [event.t_start for event in analysis.events] == sorted(positions)
    assert all(event.kind == "visual_observation" for event in analysis.events)
    commentary = staged("commentary")
    assert commentary.focus_event(analysis.events).t_start == positions[0]


def test_last_retry_limits_the_model_to_the_verified_ending_beat(staged):
    commentary = staged("commentary")
    kill = commentary.GameplayEvent(id="early", kind="kill", source="windows_ocr",
                                    t_start=17, t_end=17, text="ELIMINATED", confidence=0.7)
    death = commentary.GameplayEvent(id="ending", kind="death", source="windows_ocr",
                                     t_start=19, t_end=19, text="ELIMINATED BY Rival", confidence=0.7)
    calls = []

    def chat(_system, prompt, _temperature):
        calls.append(prompt)
        if len(calls) < 3:
            return json.dumps({"lines": [{"text": "You took out a whole team!", "event_ids": [kill.id]}]})
        body, _instruction = prompt.rsplit("\n", 1)
        assert [event["id"] for event in json.loads(body)["events"]] == [death.id]
        return json.dumps({"lines": [{"text": "Oof, that ending had no mercy.", "event_ids": [death.id]}]})

    plan = commentary.write_commentary(settings=SimpleNamespace(commentary_mode="auto", ollama_model="local"),
                                       clip_id="clip", mood="roast", events=[kill, death], duration=21,
                                       sounds=SimpleNamespace(allowlist=[]), recent=[], allow_cues=False,
                                       client=SimpleNamespace(chat=chat))
    assert len(calls) == 3 and plan.lines[0].event_ids == [death.id]


@pytest.mark.skipif(not shutil.which("ffmpeg"), reason="FFmpeg is needed for the synthetic clip.")
def test_motion_scan_finds_a_visual_change_at_the_end(staged, tmp_path):
    vision = staged("gameplay_vision")
    clip = tmp_path / "clip.mkv"
    source = "color=black:s=160x90:d=7[pre];color=white:s=160x90:d=2[end];[pre][end]concat=n=2:v=1:a=0"
    subprocess.run(["ffmpeg", "-v", "error", "-f", "lavfi", "-i", source, "-c:v", "ffv1", str(clip)],
                   check=True, capture_output=True, timeout=20)
    position = vision._late_motion_time(clip, 9, None)
    assert position == pytest.approx(7, abs=0.25)
    analysis = SimpleNamespace(probe=SimpleNamespace(duration=9), events=[])
    assert vision._frame_times(analysis, position)[1] == position
    assert vision._frame(clip, position)


def test_windows_ocr_checks_both_ends_and_prioritizes_confirmed_gameplay(staged):
    hud = sys.modules["sweatcaster.gameplay_hud"]
    times = [time for time, _ in hud._hud_samples([None] * 180, 60, 3)]
    assert 16 / 3 in times
    assert any(25 < time < 30 for time in times)
    assert times[-1] == 179 / 3
    assert len(times) <= 78

    assert hud.classify_hud_text("ELIMINATED Enemy") == "kill"
    assert hud.classify_hud_text("ELIMINATED BY Enemy") == "death"
    assert hud.classify_hud_text("RESPAWN AVAILABLE IN 18") == "death"
    assert hud.classify_hud_text("0 ELIMINATIONS / HEADSHOTS") == "ocr_text"
    assert hud.classify_hud_text("When eliminated, wait to respawn.") == "ocr_text"
    assert hud.classify_hud_text("When eliminated by an opponent, wait to respawn.") == "ocr_text"
    assert hud.classify_hud_text("AnotherPlayer killed TheirEnemy") == "ocr_text"
    assert hud.classify_hud_text("You were killed") == "death"
    assert hud.classify_hud_text("Objective marker") == "ocr_text"

    kill = SimpleNamespace(kind="kill", t_start=5.0)
    death = SimpleNamespace(kind="death", t_start=17.0)
    scenery = SimpleNamespace(kind="visual_observation", t_start=15.5)
    irrelevant = SimpleNamespace(kind="ocr_text", t_start=16.0)
    assert hud.commentary_evidence([kill, scenery, irrelevant, death]) == [kill, scenery, death]
    assert hud.commentary_evidence([scenery]) == [scenery]


def test_windows_ocr_retains_the_finish_even_after_an_earlier_batch_fails(staged, monkeypatch):
    pytest.importorskip("PIL")
    hud = sys.modules["sweatcaster.gameplay_hud"]
    monkeypatch.setattr(hud, "sys", SimpleNamespace(platform="win32"))
    monkeypatch.setattr(hud.shutil, "which", lambda name: "powershell.exe")
    monkeypatch.setattr(hud, "_MAX_OCR_BATCH_BYTES", 3 * 16 * 16)
    calls = []

    def read(_executable, batch):
        calls.append(len(batch))
        if len(calls) == 1:
            return None
        return [[]] * len(batch) if len(calls) < 10 else [[], [], ["ELIMINATED Rival"]]

    monkeypatch.setattr(hud, "_read_windows_hud", read)
    probe = SimpleNamespace(width=16, height=16, duration=10)
    roi = hud.NormalizedROI(preset="full", x=0, y=0, w=1, h=1)
    frames = [bytes(16 * 16 * 3)] * 30
    events, status = hud.windows_hud_events(Path("clip.mp4"), probe, roi, lambda *args: iter(frames), None)
    assert calls == [3] * 10
    assert status["live_verified"] and "only some" in status["detail"]
    assert [(event.kind, event.t_start) for event in events] == [("kill", 9.667)]


def test_windows_ocr_source_obeys_exact_result_validation(staged):
    hud = sys.modules["sweatcaster.gameplay_hud"]
    commentary = staged("commentary")
    event = hud.GameplayEvent(id="result", kind="objective", source="windows_ocr", t_start=3,
                              t_end=3.3, text="Scoreboard 2", confidence=0.7)
    options = dict(events=[event], duration=8, allowlist=[], allow_cues=False, recent=[], enforce_repeat=False)
    payload = {"lines": [{"text": "A scoreboard of 2? That's cheeky.", "event_ids": [event.id], "t_start": 3}]}
    lines, _, _ = commentary.validate_commentary(payload, **options)
    assert lines[0].event_ids == [event.id]
    payload["lines"][0]["text"] = "The scoreboard says 2."
    with pytest.raises(commentary.CommentaryError, match="React in your own words"):
        commentary.validate_commentary(payload, **options)
    payload["lines"][0]["text"] = "A scoreboard of 9? That's cheeky."
    with pytest.raises(commentary.CommentaryError, match="result not shown"):
        commentary.validate_commentary(payload, **options)


def test_fortnite_crown_beat_is_not_a_backstab_or_second_elimination(staged):
    hud = sys.modules["sweatcaster.gameplay_hud"]
    commentary = staged("commentary")
    line = "ONE SHALL RULE Eliminated a crown wearer while wearing a crown +250 XP"
    assert hud.classify_hud_text(line) == "objective"
    crown = hud.GameplayEvent(id="crown", kind="objective", source="windows_ocr", t_start=3,
                              t_end=3.3, text=line, confidence=0.7)
    banner = hud.GameplayEvent(id="kill", kind="kill", source="windows_ocr", t_start=3.3,
                               t_end=3.6, text="ELIMINATED", confidence=0.7)
    assert commentary.focus_event([crown, banner]).id == crown.id
    assert "Fortnite replay specialist" in hud.specialist_prompt(None, [crown])
    options = dict(events=[crown, banner], duration=8, allowlist=[], allow_cues=False,
                   recent=[], enforce_repeat=False)
    for text, reason in (
        ("Wow, two eliminations in a row! You really got that guy with the backstab.", "separately confirmed"),
        ("That backstab was nasty.", "cited visual observation"),
        ("You picked up that crown.", "picked it up"),
    ):
        payload = {"lines": [{"text": text, "event_ids": [crown.id, banner.id], "t_start": 3}]}
        with pytest.raises(commentary.CommentaryError, match=reason):
            commentary.validate_commentary(payload, **options)
    reaction = {"lines": [{"text": "Two crowns in one fight? That's a royal grudge match.",
                           "event_ids": [crown.id], "t_start": 3}]}
    assert commentary.validate_commentary(reaction, **options)[0][0].event_ids == [crown.id]


def test_the_finals_cites_the_cashout_stage_without_inventing_the_player(staged, tmp_path):
    hud = sys.modules["sweatcaster.gameplay_hud"]
    commentary = staged("commentary")
    base = tmp_path / "Recordings"
    finals = base / "THE_FINALS"
    fortnite = base / "Fortnite"
    settings = SimpleNamespace(input_roots=(base, finals, fortnite),
                               root_labels=("Recordings", "THE FINALS", "Fortnite"))
    assert hud.game_for_clip(finals / "game.mp4", settings) == "the_finals"
    assert hud.game_for_clip(fortnite / "game.mp4", settings) == "fortnite"
    assert hud.game_for_clip(base / "Random" / "Fortnite.mp4", settings) is None
    assert hud.classify_hud_text("CASHOUT STOLEN") == "objective"
    event = hud.GameplayEvent(id="cashout", kind="objective", source="windows_ocr", t_start=3,
                              t_end=3.3, text="CASHOUT STOLEN", confidence=0.7)
    assert "THE FINALS replay specialist" in hud.specialist_prompt(None, [event])
    assert "THE FINALS replay specialist" in hud.specialist_prompt("the_finals", [])
    options = dict(events=[event], duration=8, allowlist=[], allow_cues=False,
                   recent=[], enforce_repeat=False)
    for text, reason in (
        ("You stole the cashout.", "does not identify"),
        ("That cashout has been completed.", "different stage"),
    ):
        payload = {"lines": [{"text": text, "event_ids": [event.id], "t_start": 3}]}
        with pytest.raises(commentary.CommentaryError, match=reason):
            commentary.validate_commentary(payload, **options)
    reaction = {"lines": [{"text": "That's one spicy cashout steal.", "event_ids": [event.id], "t_start": 3}]}
    assert commentary.validate_commentary(reaction, **options)[0][0].event_ids == [event.id]

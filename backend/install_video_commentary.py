"""Stage grounded commentary on a compatible FadedAI PC checkpoint."""

from __future__ import annotations

import argparse
from hashlib import sha256
from pathlib import Path

from install_fadedai_pc import atomic_write


PREVIOUS_VISION_HASHES = {
    "7f961981355748e27bc888f5f9c4d7cd41e44a7a1a2814838183d8fca0bf1570",
    "997f53745858774fdf2a6b722d043a3885aad681f93d5e662f21dc08fd527e71",
}
PREVIOUS_HUD_HASHES = {"db67e99e3dfa7ce623127c8c026222555325e1e47082e7cf65ca623c06a0e665"}
LEGACY_RESULT_SOURCE = '                event.source in {"tesseract", "easyocr"}\n'
RESULT_SOURCE = '                event.source in {"tesseract", "easyocr", "windows_ocr"}\n'
REACTION_GROUNDING = "Ground your reaction in one concrete detail from a cited event."
REACTION_ATTRIBUTION = "Use screen text and speech as supporting evidence without reading it back."
FOCUS_ATTRIBUTION = "An elimination claim needs its own confirmed kill event ID."
PREVIOUS_CLAIM_CHECK = (
    '        if _KILL_RE.search(text) and not any(event.kind == "kill" for event in cited):\n'
    '            raise CommentaryError("The reaction invented a kill. Nothing was kept.")\n'
    '        if _DEATH_RE.search(text) and not any(event.kind == "death" for event in cited):\n'
    '            raise CommentaryError("The reaction invented a death. Nothing was kept.")\n'
)
CLAIM_CHECK = (
    '        player_went_down = bool(_PLAYER_DEATH_RE.search(text))\n'
    '        other_claims = _PLAYER_DEATH_RE.sub("", text)\n'
    '        if _KILL_RE.search(other_claims) and not any(event.kind == "kill" for event in cited):\n'
    '            raise CommentaryError("The reaction invented a kill. Nothing was kept.")\n'
    '        if (player_went_down or _DEATH_RE.search(text)) and not any(event.kind == "death" for event in cited):\n'
    '            raise CommentaryError("The reaction invented a death. Nothing was kept.")\n'
)

BEAT_EDITS = {
    "sweatcaster/analysis.py": [
        (
            '    if rois and not any(event.kind == "kill" and event.t_start >= probe.duration / 2 for event in ocr_events):\n',
            '    # A mid-clip hit does not establish what happened at the finish.\n'
            '    ending = max(0.0, probe.duration - 5.0)\n'
            '    if rois and not any(event.kind == "kill" and event.t_start >= ending for event in ocr_events):\n',
        ),
    ],
    "sweatcaster/commentary.py": [
        (
            '    highlights = [event for event in observed if event.kind == "kill" or (\n'
            '        event.kind == "objective" and re.search(r"\\b(?:victory|defeat|captured)\\b", event.text or "", re.I)\n'
            '    )]\n'
            '    candidates = highlights or [event for event in observed if event.kind == "death"]\n',
            '    confirmed = [event for event in observed if event.kind in {"kill", "death"} or (\n'
            '        event.kind == "objective" and re.search(\n'
            '            r"\\b(?:victory|defeat|captured|round won|round lost)\\b", event.text or "", re.I\n'
            '        )\n'
            '    )]\n'
            '    candidates = confirmed or [event for event in events if event.kind == "visual_observation"]\n',
        ),
        (
            '    r"(?:image|screenshot|frame) (?:shows|depicts|contains)|"\n',
            '    r"(?:image|screenshot|frame) (?:shows|depicts|contains)|"\n'
            '    r"(?:screen|scoreboard|HUD) (?:says|reads|shows)|"\n',
        ),
        (
            '        if event.kind != "visual_observation" or not event.text:\n',
            '        if not event.text:\n',
        ),
        (
            'def repeats_visual_caption(text: str, events: list[GameplayEvent]) -> bool:\n',
            'def repeats_evidence_text(text: str, events: list[GameplayEvent]) -> bool:\n',
        ),
        (
            '        if _REPORTING_RE.search(text) or repeats_visual_caption(text, events):\n'
            '            raise CommentaryError("React in your own words. Leave frame captions and detector reports out of speech.")\n',
            '        if _REPORTING_RE.search(text) or repeats_evidence_text(text, events):\n'
            '            raise CommentaryError("React in your own words. Leave screen text, captions and detector reports out of speech.")\n',
        ),
        (
            '        "React to that beat with an opinion or a playful comparison. Use one line unless a separate, "\n',
            '        "React to that beat with an opinion or a playful comparison. Nearby picture and sound can supply context. "\n'
            '        "When a distinct confirmed elimination and player death both matter, give each its own line and cite them separately. "\n'
            '        "Use one line unless a separate, "\n',
        ),
    ],
}


def changes() -> dict[str, list[tuple[str, str]]]:
    return {
        "sweatcaster/coord.py": [
            ('    def try_acquire(self, tag: str, purpose: str) -> str | None:',
             '    def try_acquire(self, tag: str, purpose: str, *, allow_pending: bool = True) -> str | None:'),
            ('            elif not row["pending_lease"]:\n',
             '            elif allow_pending and not row["pending_lease"]:\n'),
        ],
        "sweatcaster/models.py": [
            ('    "motion",\n]\nEventSource', '    "motion",\n    "visual_observation",\n]\nEventSource'),
            ('    "motion_heuristic",\n]', '    "motion_heuristic",\n    "ollama_vision",\n]'),
            ('    "audio_rms",\n    "motion_heuristic",\n', '    "audio_rms",\n    "windows_ocr",\n    "motion_heuristic",\n'),
        ],
        "sweatcaster/vision.py": [
            ('def iter_vision_text(settings: Settings, tag: str, prompt: str, image_b64: str) -> Iterator[str]:',
             'def iter_vision_text(\n'
             '    settings: Settings, tag: str, prompt: str, image_b64: str, *,\n'
             '    read_timeout: int = 120, num_predict: int = 300,\n'
             ') -> Iterator[str]:'),
            ('"num_predict": 300', '"num_predict": num_predict'),
            ('timeout=(3, 120)', 'timeout=(3, read_timeout)'),
            ('                piece = ((data.get("message") or {}).get("content")) or ""\n',
             '                if not isinstance(data, dict):\n'
             '                    continue\n'
             '                message = data.get("message")\n'
             '                piece = message.get("content") if isinstance(message, dict) else None\n'),
        ],
        "sweatcaster/analysis.py": [
            ('from sweatcaster.config import Settings\n',
             'from sweatcaster.config import Settings\n'
             'from sweatcaster.gameplay_hud import classify_hud_text, windows_hud_events\n'),
            ('KILL_WORDS = (\n'
             '    "kill",\n    "kills",\n    "killed",\n    "ace",\n    "eliminated",\n'
             '    "elimination",\n    "headshot",\n    "headshots",\n)\n'
             'DEATH_WORDS = ("died", "death", "dead")\n'
             'OBJECTIVE_WORDS = ("victory", "defeat", "objective", "captured")\n\n\n', ''),
            ('    tokens = {part.strip(".,!?:;\\\"\'").lower() for part in text.split()}\n'
             '    if tokens & set(KILL_WORDS):\n        return "kill"\n'
             '    if tokens & set(DEATH_WORDS):\n        return "death"\n'
             '    if tokens & set(OBJECTIVE_WORDS):\n        return "objective"\n'
             '    return "ocr_text"\n',
             '    return classify_hud_text(text)\n'),
            ('    clipped = merged[:24]\n',
             '    # Keep representative evidence throughout the clip before applying the cap.\n'
             '    if len(merged) > 24:\n'
             '        duration = max(1.0, max(event.t_end for event in merged))\n'
             '        ranked = sorted(range(len(merged)), key=lambda index: (\n'
             '            merged[index].kind not in {"kill", "death", "objective"},\n'
             '            -merged[index].confidence, -merged[index].t_start,\n'
             '        ))\n'
             '        quarters: dict[int, int] = {}\n'
             '        for index in ranked:\n'
             '            quarter = min(3, int(4 * merged[index].t_start / duration))\n'
             '            quarters.setdefault(quarter, index)\n'
             '        selected = list(dict.fromkeys([*quarters.values(), *ranked]))[:24]\n'
             '        clipped = [merged[index] for index in sorted(selected)]\n'
             '    else:\n'
             '        clipped = merged\n'),
            ('def _ocr_frames(\n',
             'def _timeline_frames(path, width, height, duration, fps, budget, cancel):\n'
             '    """Bound OCR work and read every sample in the last four seconds."""\n'
             '    from math import ceil\n'
             '\n'
             '    ending = max(0.0, duration - 4.0)\n'
             '    stride = max(1, ceil(ending * fps / budget))\n'
             '    for index, raw in enumerate(_read_frames(path, width, height, fps, cancel)):\n'
             '        time = index / fps\n'
             '        if time >= duration:\n'
             '            break\n'
             '        if time >= ending or index % stride == 0:\n'
             '            yield time, raw\n'
             '\n\n'
             'def _ocr_frames(\n'),
            ('    seen: set[tuple[str, str]] = set()\n'
             '    index = 0\n'
             '    fps = 2.0\n'
             '    try:\n'
             '        for raw in _read_frames(path, analysis_w, analysis_h, fps, cancel):\n'
             '            frame = np.frombuffer(raw, dtype=np.uint8).reshape((analysis_h, analysis_w, 3)).copy()\n'
             '            t = index / fps\n',
             '    seen: dict[tuple[str, str], float] = {}\n'
             '    try:\n'
             '        for t, raw in _timeline_frames(path, analysis_w, analysis_h, probe.duration, 2.0, 32, cancel):\n'
             '            frame = np.frombuffer(raw, dtype=np.uint8).reshape((analysis_h, analysis_w, 3)).copy()\n'),
            ('                if key in seen:\n                    continue\n                seen.add(key)\n',
             '                kind = _classify_ocr(text)\n'
             '                previous = seen.get(key)\n'
             '                seen[key] = t\n'
             '                if previous is not None and (kind == "ocr_text" or t - previous <= 6.0):\n'
             '                    continue\n'),
            ('                        kind=_classify_ocr(text),\n                        source="tesseract",\n',
             '                        kind=kind,\n                        source="tesseract",\n'),
            ('            index += 1\n            if index > 40:\n                break\n', ''),
            ('    index = 0\n'
             '    try:\n'
             '        for raw in _read_frames(path, analysis_w, analysis_h, 1.0, cancel):\n'
             '            frame = np.frombuffer(raw, dtype=np.uint8).reshape((analysis_h, analysis_w, 3)).copy()\n'
             '            t = float(index)\n',
             '    try:\n'
             '        for t, raw in _timeline_frames(path, analysis_w, analysis_h, probe.duration, 1.0, 16, cancel):\n'
             '            frame = np.frombuffer(raw, dtype=np.uint8).reshape((analysis_h, analysis_w, 3)).copy()\n'),
            ('            index += 1\n            if index > 20:\n                break\n'
             '    except Exception:\n        return [], {\n'
             '            "ok": False,\n            "live_verified": False,\n'
             '            "detail": "EasyOCR failed. No on-screen text was invented.",\n',
             '    except UserFacingError:\n        raise\n'
             '    except Exception:\n        return [], {\n'
             '            "ok": False,\n            "live_verified": False,\n'
             '            "detail": "EasyOCR failed. No on-screen text was invented.",\n'),
            ('    for index, rms in enumerate(rms_values):\n',
             '    peak = 0.0\n    for index, rms in enumerate(rms_values):\n'),
            ('            active = (index, index)\n', '            active = (index, index)\n            peak = rms\n'),
            ('            active = (active[0], index)\n',
             '            active = (active[0], index)\n            peak = max(peak, rms)\n'),
            ('                events.append((t0, t1, rms_values[active[0]]))\n            active = None\n',
             '                events.append((t0, t1, peak))\n            active = None\n'),
            ('            events.append((t0, t1, rms_values[active[0]]))\n    gameplay = []\n',
             '            events.append((t0, t1, peak))\n    gameplay = []\n'),
            ('    for index, (t0, t1, peak) in enumerate(events[:8], start=1):\n',
             '    # Keep the latest spike alongside the strongest ones, without guessing its cause.\n'
             '    strongest = sorted(events[:-1], key=lambda item: (item[2], item[0]), reverse=True)[:7]\n'
             '    for index, (t0, t1, peak) in enumerate(sorted([*strongest, *events[-1:]]), start=1):\n'),
            ('    if not ocr_state.get("ok"):\n'
             '        notes.append(ocr_state.get("detail") or "On-screen text was not read.")\n'
             '        easy_events, easy_state = _easyocr_events(path, probe, rois, settings, cancel)\n'
             '        extractor["easyocr"] = easy_state\n'
             '        if easy_state.get("ok"):\n'
             '            ocr_events = easy_events\n'
             '            notes.append(easy_state.get("detail", ""))\n'
             '        elif settings.easyocr_mode == "on":\n'
             '            notes.append(easy_state.get("detail", ""))\n'
             '    else:\n'
             '        extractor["easyocr"] = _easyocr_status(settings)\n'
             '        if not ocr_events:\n'
             '            notes.append("No on-screen text was found in the selected box.")\n',
             '    if rois and not any(event.kind == "kill" and event.t_start >= probe.duration / 2 for event in ocr_events):\n'
             '        windows_events, windows_state = windows_hud_events(path, probe, rois[0], _read_frames, cancel)\n'
             '        extractor["windows_ocr"] = windows_state\n'
             '        ocr_events.extend(windows_events)\n'
             '    if not ocr_state.get("ok") and not extractor.get("windows_ocr", {}).get("ok"):\n'
             '        easy_events, easy_state = _easyocr_events(path, probe, rois, settings, cancel)\n'
             '        extractor["easyocr"] = easy_state\n'
             '        if easy_state.get("ok"):\n'
             '            ocr_events.extend(easy_events)\n'
             '    else:\n'
             '        extractor["easyocr"] = _easyocr_status(settings)\n'),
            ('    if not any(event.kind == "kill" for event in events):\n'
             '        notes.append("No kill was observed.")\n',
             '    if not any(event.kind == "kill" for event in events):\n'
             '        hud_read = any(extractor.get(source, {}).get("live_verified")\n'
             '                       for source in ("tesseract", "windows_ocr", "easyocr"))\n'
             '        if hud_read:\n'
             '            notes.append("Ingen eliminering kunne bekræftes i de HUD-udsnit, PC’en læste.")\n'
             '        else:\n'
             '            notes.append("PC’en kunne ikke læse spillets HUD. Elimineringer kunne ikke verificeres.")\n'),
            ('    if not voice_state.get("ok"):\n'
             '        notes.append(voice_state.get("detail") or "Speech was not transcribed.")\n',
             '    if settings.whisper_mode == "on" and probe.has_audio and not voice_state.get("ok"):\n'
             '        notes.append("PC’en kunne ikke transskribere tale i klippet.")\n'),
        ],
        "sweatcaster/pipeline.py": [
            ('from sweatcaster.media import Probe\n',
             'from sweatcaster.gameplay_hud import commentary_evidence\nfrom sweatcaster.media import Probe\n'),
            ('from sweatcaster.dto import roi_model\n',
             'from sweatcaster.dto import roi_model\nfrom sweatcaster.gameplay_vision import add_visual_evidence\n'),
            ('        return analyze_clip(\n', '        analysis = analyze_clip(\n'),
            ('            fixed_box=fixed_box,\n        )\n',
             '            fixed_box=fixed_box,\n        )\n'
             '        if job.get("commentary", True) and self.settings.commentary_mode == "auto":\n'
             '            add_visual_evidence(analysis, path, self.settings, cancel)\n'
             '        return analysis\n'),
            ('            events=analysis.events,\n', '            events=commentary_evidence(analysis.events),\n'),
            ('    """Keep a short segment around the first observed kill; never invent later footage."""\n',
             '    """Keep the ending and shorten the lead-in only when the game shows a kill."""\n'),
            ('    event = kills[0]\n', '    event = kills[-1]\n'),
            ('    end = min(analysis.probe.duration, max(event.t_end, event.t_start) + 7.0)\n',
             '    end = analysis.probe.duration\n'),
            ('        if focus and timed.lines:\n'
             '            # Start the reaction near the beginning of the edited highlight.\n'
             '            target = min(focus[0] + 0.6, focus[1] - 0.3)\n'
             '            shifted = []\n'
             '            for line in timed.lines:\n'
             '                delta = target - line.t_start\n'
             '                shifted.append(line.model_copy(update={\n'
             '                    "t_start": round(target, 3),\n'
             '                    "t_end": round(min(focus[1], line.t_end + delta), 3),\n'
             '                    "word_timings": [word.model_copy(update={"t_start": round(word.t_start + delta, 3)})\n'
             '                                     for word in line.word_timings],\n'
             '                }))\n'
             '                target = min(focus[1] - 0.3, target + max(1.0, line.t_end - line.t_start) + 0.3)\n'
             '            timed = timed.model_copy(update={"lines": shifted})\n',
             '        if focus and timed.lines:\n'
             '            cited = {event_id for line in timed.lines for event_id in line.event_ids}\n'
             '            cited_before_focus = any(event.id in cited and event.t_start < focus[0]\n'
             '                                     for event in analysis.events)\n'
             '            if cited_before_focus or any(line.t_start < focus[0] for line in timed.lines):\n'
             '                focus = None\n'),
            ('            warnings.append("The video was shortened around an observed kill.")\n',
             '            warnings.append("The lead-in was shortened before the last observed kill. The ending was kept.")\n'),
        ],
        "sweatcaster/commentary.py": [
            ('_THINK_RE = re.compile(r"<think>.*?</think>", re.I | re.S)\n',
             '_PLAYER_DEATH_RE = re.compile(\n'
             '    r"\\b(?:you|the player) (?:(?:were|was|got) (?:eliminated|killed|knocked out)|went down)\\b"\n'
             '    r"|\\b(?:eliminated|killed|knocked out) (?:you|the player)\\b", re.I\n'
             ')\n'
             '_THINK_RE = re.compile(r"<think>.*?</think>", re.I | re.S)\n'),
            ('    "roast": "Tone: a short dry aside about the observed play. One mild remark. No shouting.",\n',
             '    "roast": "Tone: playful, deadpan banter about the play, not the player. Give the moment a short "\n'
             '             "punchline or a cheeky comparison. Aim for 6 to 14 words and say it directly to a friend. "\n'
             '             "Skip generic praise and neutral recap.",\n'),
            ('def build_user_prompt(\n',
             'def focus_event(events: list[GameplayEvent]) -> GameplayEvent | None:\n'
             '    """Choose a gameplay beat from the full timeline before asking for a reaction."""\n'
             '    observed = [event for event in events if event.source in {"tesseract", "easyocr", "windows_ocr"}]\n'
             '    highlights = [event for event in observed if event.kind == "kill" or (\n'
             '        event.kind == "objective" and re.search(r"\\b(?:victory|defeat|captured)\\b", event.text or "", re.I)\n'
             '    )]\n'
             '    candidates = highlights or [event for event in observed if event.kind == "death"]\n'
             '    return max(candidates, key=lambda event: (event.t_start, event.confidence), default=None)\n'
             '\n\n'
             'def build_user_prompt(\n'),
            ('    body = {\n        "mood": mood,\n',
             '    focus = focus_event(events)\n'
             '    body = {\n'
             '        "mood": mood,\n'
             '        "focus_event_id": focus.id if focus else None,\n'),
            ('            "gaps": ["What was missing, if anything."],\n', ''),
            ('    prompt_hash = sha256_text(SYSTEM_PROMPT + "\\n" + user)\n',
             '    system = SYSTEM_PROMPT + (\n'
             '        " If focus_event_id is supplied, make it the main beat and cite it on a line by itself. "\n'
             '        "React to that beat with an opinion or a playful comparison. Use one line unless a separate, "\n'
             '        "verified event makes a second line worth hearing. Speak to the player, not about an image. "\n'
             '        "Leave the diagnosis to the app. Return only lines, never gaps or analysis."\n'
             '    )\n'
             '    prompt_hash = sha256_text(system + "\\n" + user)\n'),
            ('    attempt_user = user\n    rejected_output = None\n',
             '    attempt_user = user\n    rejected_output = None\n    focus = focus_event(events)\n'),
            ('        raw = ollama.chat(SYSTEM_PROMPT, attempt_user, 0.35 if attempt == 0 else 0.45)\n',
             '        raw = ollama.chat(system, attempt_user, 0.55 if attempt == 0 else 0.40)\n'),
            ('            payload = parse_json_object(raw)\n',
             '            payload = {"lines": parse_json_object(raw).get("lines")}\n'),
            ('                enforce_repeat=True,\n            )\n            return CommentaryPlan(\n',
             '                enforce_repeat=True,\n            )\n'
             '            if focus and not any(line.event_ids == [focus.id] for line in lines):\n'
             '                raise CommentaryError("React to focus_event_id and cite it alone on its line.")\n'
             '            return CommentaryPlan(\n'),
            ('        if not events and not _ACK_RE.search(text):\n',
             '        if re.search(r"\\b(?:ocr|whisper|detector|timestamp|(?:start|middle|end) of (?:the|this) clip)\\b", text, re.I):\n'
             '            raise CommentaryError("Keep analysis terminology and clip timestamps out of the reaction.")\n'
             '        if not events and not _ACK_RE.search(text):\n'),
            ('The model never receives pixels. It only receives the event list. If the text\n'
             'is not usable English, or it claims a kill the events do not support, the line\n'
             'is rejected. There is no canned narration fallback.',
             'The writer receives evidence with time and source, including any local frame\n'
             'observation. It never receives clip bytes. Unsupported claims are rejected.'),
            ('_DEATH_RE = re.compile(r"\\b(deaths?|died|dying)\\b", re.I)\n',
             '_DEATH_RE = re.compile(r"\\b(deaths?|died|dying)\\b", re.I)\n'
             '_RESULT_RE = re.compile(r"\\b(victory|defeat|winner|won|lost the (?:game|match|round)|score(?:d|board)?)\\b(?![\'’])", re.I)\n'
             '_NUMBER_RE = re.compile(r"\\b[0-9]+\\b")\n'
             '_AUDIO_RE = re.compile(r"\\b(audio|sound(?:s|ed)?|loud(?:er|ness)?|noise|spike|heard|quiet|volume)\\b", re.I)\n'
             '_ACTION_RE = re.compile(r"\\b(players?|opponents?|enemies|enemy|weapon|guns?|gunfire|shots?|"\n'
             '                        r"shoot(?:ing|s)?|reload(?:ing|s|ed)?|attack(?:ing|s|ed)?|explosion|footsteps|"\n'
             '                        r"runn?ing|jump(?:ing|s|ed)?|dodg(?:ing|es|ed)|fights?|fighting)\\b", re.I)\n'),
            ('    "Use only events you are given. Never invent kills, deaths, scores, or players. "\n'
             '    "If no kill event is present, do not say anyone was killed. "\n'
             '    "If the event list is empty, say that nothing readable happened. "\n',
             f'    "{REACTION_GROUNDING} "\n'
             '    "A visual_observation describes one still frame, not what happened before or after it. "\n'
             '    "An audio_spike only means a loud moment, never shots, impacts, footsteps, or action. "\n'
             f'    "{REACTION_ATTRIBUTION} "\n'
             '    "Never guess a player identity, intention, kill, death, score, or winner. "\n'
             '    "A kill or death needs that kind of event in this line\'s event_ids. "\n'
             '    "If there is only loudness, say what is audible and that the action is unclear. "\n'
             '    "If no events were observed, say you could not tell what happened. "\n'),
            ('    "End with normal punctuation. Use at most one exclamation mark in the whole reaction. "\n',
             '    "Review the entire evidence timeline through the last seconds before choosing what to describe. "\n'
             '    "For an FPS clip, prioritize the clearest gameplay event over the setup. Give later evidence equal attention. "\n'
             '    "If the decisive observed event is near the end, focus the reaction there. "\n'
             '    "End with normal punctuation. Use at most one exclamation mark in the whole reaction. "\n'),
            ('    "Do not stack hype words. Return one JSON object and no other text."\n',
             f'    "{FOCUS_ATTRIBUTION} "\n'
             '    "Cite a separate death event if mentioning that the player later went down. "\n'
             '    "Ignore lobby labels, usernames, and interface decoration. "\n'
             '    "Do not stack hype words. Return one JSON object and no other text."\n'),
            ('        t_start = min(max(0.0, t_start), max(0.0, duration - 0.3))\n',
             '        if cited:\n'
             '            gameplay = [event for event in cited if event.kind in {"kill", "death", "objective"}]\n'
             '            observed_at = max(event.t_start for event in (gameplay or cited))\n'
             '            t_start = min(max(t_start, observed_at - 0.5), observed_at + 0.5)\n'
             '        t_start = min(max(0.0, t_start), max(0.0, duration - 0.3))\n'),
            ('        if start >= clip_duration - 0.2:\n'
             '            start = max(0.0, clip_duration - min(audio_duration, clip_duration))\n',
             '        if start + audio_duration > clip_duration:\n'
             '            start = max(cursor, clip_duration - min(audio_duration, clip_duration))\n'),
            ('def _supports(pattern: re.Pattern[str], event: GameplayEvent, kind: str) -> bool:\n'
             '    if event.kind == kind:\n'
             '        return True\n'
             '    return bool(pattern.search(event.text or ""))\n\n\n', ''),
            ('        if _KILL_RE.search(text) and not any(_supports(_KILL_RE, event, "kill") for event in events):\n'
             '            raise CommentaryError("The reaction invented a kill. Nothing was kept.")\n'
             '        if _DEATH_RE.search(text) and not any(_supports(_DEATH_RE, event, "death") for event in events):\n'
             '            raise CommentaryError("The reaction invented a death. Nothing was kept.")\n', ''),
            ('            ids.append(str(event_id))\n',
             '            ids.append(str(event_id))\n'
             '        cited = [known[event_id] for event_id in ids]\n'
             + CLAIM_CHECK +
             '        result_words = {match.group().casefold() for match in _RESULT_RE.finditer(text)}\n'
             '        if result_words:\n'
             '            numbers = set(_NUMBER_RE.findall(text))\n'
             '            if not any(\n'
             + RESULT_SOURCE +
             '                and result_words <= {match.group().casefold() for match in _RESULT_RE.finditer(event.text or "")}\n'
             '                and numbers <= set(_NUMBER_RE.findall(event.text or ""))\n'
             '                for event in cited\n'
             '            ):\n'
             '                raise CommentaryError("The reaction claimed a result not shown on screen.")\n'
             '        if cited and all(event.kind == "audio_spike" for event in cited):\n'
             '            if not _AUDIO_RE.search(text) or _ACTION_RE.search(text):\n'
             '                raise CommentaryError("Loudness alone does not identify an action. Describe only the sound.")\n'),
            ('                "roi": event.roi,\n', '                "roi": event.roi,\n                "confidence": event.confidence,\n'),
            ('    if not any(event.kind == "kill" for event in events):\n'
             '        if not any("kill" in gap.lower() for gap in gaps):\n'
             '            gaps.append("No kill was observed.")\n',
             '    if not any(event.kind == "kill" for event in events):\n'
             '        # Analysis reports the actual HUD coverage to the user.\n'
             '        gaps = [gap for gap in gaps if not _KILL_RE.search(gap)]\n'),
            ('    "You write one or two spoken English sentences for a gameplay clip. "\n'
             '    "Sound like a person talking, with contractions, not like an announcer. "\n',
             '    "You are the friend watching this FPS replay. Write one or two short spoken English reactions. "\n'
             '    "React to the moment in your own words. Sound like a friend with an opinion about the play. "\n'
             '    "Use observations to choose what to react to. Never quote or paraphrase a frame caption. "\n'
             '    "Keep screen text, timestamps, detector results and missing evidence out of spoken lines. "\n'
             '    "If the action is unclear, react modestly to what you can tell. Never say no kill was observed. "\n'),
            ('Tone: a slightly odd friend who only reports what happened. No catchphrase.',
             'Tone: a slightly odd friend reacting to the moment. One playful aside. No catchphrase.'),
            ('_ACK_RE = re.compile(\n',
             '_REPORTING_RE = re.compile(\n'
             '    r"\\b(?:in (?:this|the) (?:image|screenshot|frame)|"\n'
             '    r"(?:image|screenshot|frame) (?:shows|depicts|contains)|"\n'
             '    r"(?:no )?(?:kills?|deaths?|eliminations?) (?:was |were )?(?:observed|detected|confirmed))\\b", re.I\n'
             ')\n'
             '_ACK_RE = re.compile(\n'),
            ('def too_similar(text: str, recent: list[str]) -> bool:\n',
             'def repeats_visual_caption(text: str, events: list[GameplayEvent]) -> bool:\n'
             '    reaction = normalize_reaction(text)\n'
             '    for event in events:\n'
             '        if event.kind != "visual_observation" or not event.text:\n'
             '            continue\n'
             '        caption = normalize_reaction(event.text)\n'
             '        if len(caption.split()) >= 4 and (\n'
             '            f" {caption} " in f" {reaction} " or jaccard(reaction, caption) >= 0.85\n'
             '        ):\n'
             '            return True\n'
             '    return False\n'
             '\n'
             '\n'
             'def too_similar(text: str, recent: list[str]) -> bool:\n'),
            ('        if enforce_repeat and too_similar(text, recent + [normalize_reaction(line.text) for line in lines]):\n',
             '        if _REPORTING_RE.search(text) or repeats_visual_caption(text, events):\n'
             '            raise CommentaryError("React in your own words. Leave frame captions and detector reports out of speech.")\n'
             '        if enforce_repeat and too_similar(text, recent + [normalize_reaction(line.text) for line in lines]):\n'),
        ],
    }


def install(root: Path, apply: bool = False) -> list[Path]:
    root = root.resolve(strict=True)
    staged: dict[Path, tuple[bytes | None, bytes]] = {}
    for name, edits in changes().items():
        path = root / name
        if path.is_symlink() or not path.resolve(strict=True).is_relative_to(root):
            raise ValueError(f"Unexpected checkpoint path: {name}.")
        original = path.read_bytes()
        current = path.read_text(encoding="utf-8")
        updated = current
        beat_edits = BEAT_EDITS.get(name, [])
        # Reconcile older compatible checkpoints and make the same update a no-op on rerun.
        for previous, final in beat_edits:
            if updated.count(final) == 1:
                updated = updated.replace(final, previous)
        if name == "sweatcaster/commentary.py":
            if updated.count(LEGACY_RESULT_SOURCE) == 1:
                updated = updated.replace(LEGACY_RESULT_SOURCE, RESULT_SOURCE)
            updated = updated.replace(
                "Start with one concrete detail from a cited event. Add style after the observation.",
                REACTION_GROUNDING,
            ).replace(
                "Report screen text as what the display says, and speech as what was heard.",
                REACTION_ATTRIBUTION,
            ).replace(
                "If there is a confirmed in-game elimination, mention it with its own event ID.",
                FOCUS_ATTRIBUTION,
            ).replace(
                "0.55 if attempt == 0 else 0.85", "0.35 if attempt == 0 else 0.45",
            ).replace(
                PREVIOUS_CLAIM_CHECK, CLAIM_CHECK,
            )
        for anchor, replacement in [*edits, *beat_edits]:
            if replacement and replacement in updated:
                continue
            count = updated.count(anchor)
            if count == 0 and not replacement:
                continue
            if count != 1:
                raise ValueError(f"Unexpected checkpoint version: {name}. No sources were changed.")
            updated = updated.replace(anchor, replacement)
        compile(updated, str(path), "exec")
        if current != updated:
            staged[path] = original, updated.encode("utf-8")

    for name, allowed_hashes in (("gameplay_vision.py", PREVIOUS_VISION_HASHES),
                                 ("gameplay_hud.py", PREVIOUS_HUD_HASHES)):
        helper = root / "sweatcaster" / name
        source = (Path(__file__).resolve().parent / "sweatcaster" / name).read_bytes()
        if helper.is_symlink() or not helper.resolve().is_relative_to(root):
            raise ValueError(f"Unexpected helper path: {name}.")
        compile(source, str(helper), "exec")
        if not helper.exists():
            staged[helper] = None, source
        else:
            previous = helper.read_bytes()
            if previous != source:
                if sha256(previous.replace(b"\r\n", b"\n")).hexdigest() not in allowed_hashes:
                    raise ValueError(f"Unrecognized helper: {name}. No sources were changed.")
                staged[helper] = previous, source

    if apply:
        for path, (original, _) in staged.items():
            backup = path.with_suffix(".py.before-gameplay-commentary")
            if original is not None and not backup.exists():
                atomic_write(backup, original)
        changed = []
        try:
            for path, (original, updated) in staged.items():
                current = path.read_bytes() if path.exists() else None
                if current != original:
                    raise ValueError(f"Checkpoint changed during update: {path.name}.")
                atomic_write(path, updated)
                changed.append(path)
        except (OSError, ValueError):
            for path in reversed(changed):
                original = staged[path][0]
                if original is None:
                    path.unlink()
                else:
                    atomic_write(path, original)
            raise
    return list(staged)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("checkpoint", type=Path)
    parser.add_argument("--apply", action="store_true", help="Apply after stopping FadedAI on the PC.")
    args = parser.parse_args()
    paths = install(args.checkpoint, apply=args.apply)
    print(f"{'Updated' if args.apply else 'Checked'} {len(paths)} checkpoint files.")

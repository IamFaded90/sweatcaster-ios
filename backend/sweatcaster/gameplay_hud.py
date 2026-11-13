"""Read explicit FPS HUD text with the local Windows OCR engine when available."""

from __future__ import annotations

import base64
import json
from math import ceil, sqrt
from pathlib import Path
import re
import shutil
import subprocess
import sys

from sweatcaster.models import GameplayEvent, NormalizedROI, ROI_PRESETS, roi_pixels
from sweatcaster.util import check_cancel, even


_DEATH = re.compile(
    r"\b(?:(?:eliminated|killed|knocked out) by|you (?:(?:were|got) (?:eliminated|killed|knocked out)|"
    r"died|are dead)|respawn available|elimineret af|du dode)\b"
)
_ELIMINATION = re.compile(r"^(?:(?:you )?(?:eliminated|killed|eliminerede)|you scored an elimination)\b")
_OBJECTIVE = re.compile(r"^(?:victory|defeat|round (?:won|lost)|(?:objective|target) captured)\b")
_CROWN_BEAT = re.compile(r"\b(?:one shall rule|eliminated a crown wearer while wearing a crown)\b")
_CASHOUT_BEAT = re.compile(r"^(?:cash[ -]?out (?:started|stolen|complete(?:d)?|secured)|vault opened)\b")
_GAME_NAMES = {
    "fortnite": re.compile(r"\bfortnite\b", re.I),
    "the_finals": re.compile(r"\b(?:the[ _-]+finals|thefinals)\b", re.I),
}
_HUD_SOURCES = {"windows_ocr", "tesseract", "easyocr"}
_MULTIKILL = re.compile(
    r"\b(?:(double|triple|quadruple)[ -](?:kill|elimination)|"
    r"(two|three|four|[2-9])\s+(?:kills|eliminations)|"
    r"(two|three|four|[2-9])\s+(?:opponents|players|enemies)\s+(?:down|eliminated)|"
    r"(?:eliminated|killed|took out)\s+(two|three|four|[2-9])\s+(?:opponents|players|enemies)|"
    r"(both)\s+(?:opponents|players|enemies)\b)", re.I,
)
_COUNT_WORDS = {"double": 2, "triple": 3, "quadruple": 4, "two": 2, "three": 3, "four": 4, "both": 2}
_TACTIC_CLAIMS = tuple(re.compile(pattern, re.I) for pattern in (
    r"\b(?:back[ -]?stab\w*|stabbed? (?:him |her |them )?in the back|knife (?:in|to) the back)\b",
    r"\b(?:behind (?:him|her|them|the opponent|the enemy)|from behind|flank(?:ed|ing|s)?)\b",
    r"\b(?:ambush(?:ed|ing)?|caught (?:him|her|them) off guard|snuck up|sneak(?:ing)? up)\b",
    r"\b(?:switch(?:ed|ing)? targets?|swapp(?:ed|ing) targets?|changed targets?)\b",
    r"\b(?:snip(?:ed|ing)|quickscope\w*|noscope\w*|no[ -]scop\w*|point[ -]blank)\b",
    r"\b(?:shotgun|sniper(?: rifle)?|assault rifle|submachine gun|smg|grenade|rocket launcher|sword|dagger)\b",
))
_FORTNITE_CLAIM = re.compile(r"\b(?:crown(?:s|ed)?|storm circle|reboot(?:ed|ing)?|zero build)\b", re.I)
_FINALS_CLAIM = re.compile(r"\b(?:cash[ -]?out(?:s)?|vault(?:s)?)\b", re.I)
_CASHOUT_ACTOR = re.compile(
    r"\b(?:you|your team|your squad)\b.{0,22}\b(?:stole|started|secured|finished|completed|opened|lost)\b"
    r".{0,26}\b(?:cash[ -]?out|vault)\b", re.I,
)
_CASHOUT_ACTIONS = (
    (re.compile(r"\b(?:steal|steals|stealing|stole|stolen)\b", re.I), "cashout stolen"),
    (re.compile(r"\b(?:start|starts|started|starting)\b", re.I), "cashout started"),
    (re.compile(r"\b(?:secure|secured|complete|completed|finished)\b", re.I), "cashout complete"),
    (re.compile(r"\b(?:open|opens|opened|opening)\b", re.I), "vault opened"),
)
_CROWN_PICKUP = re.compile(r"\b(?:pick(?:ed|ing)? up|grab(?:bed|bing)?|claim(?:ed|ing)?)\b.{0,18}\bcrown\b", re.I)
_WHITE_HUD = [255] * 230 + [0] * 26
_MAX_OCR_BATCH_BYTES = 12 * 1024 * 1024
_GAMEPLAY_KINDS = {"kill", "death", "objective"}


def _words(text: str) -> str:
    return " ".join(re.findall(r"\w+", text.casefold())).replace("ø", "o")


def classify_hud_text(text: str) -> str:
    words = _words(text)
    if re.search(r"\b(?:if|when|not|can be) (?:eliminated|killed)\b", words):
        return "ocr_text"
    if _CROWN_BEAT.search(words) or _CASHOUT_BEAT.search(words):
        return "objective"
    if _DEATH.search(words):
        return "death"
    if _ELIMINATION.search(words):
        return "kill"
    if _OBJECTIVE.search(words):
        return "objective"
    return "ocr_text"


def game_for_clip(path: Path, settings) -> str | None:
    """Use the longest matching configured root, then its child folder names."""
    roots = [(root, label) for root, label in zip(settings.input_roots, settings.root_labels)
             if path.is_relative_to(root)]
    if roots:
        root, label = max(roots, key=lambda pair: len(pair[0].parts))
        labels = (label, root.name, *path.relative_to(root).parts[:-1])
    else:
        labels = (path.parent.name,)
    found = {game for game, pattern in _GAME_NAMES.items()
             if any(pattern.search(label.replace("_", " ")) for label in labels)}
    return next(iter(found)) if len(found) == 1 else None


def specialist_prompt(game: str | None, events: list[GameplayEvent]) -> str:
    if game is None:
        evidence = [_words(event.text or "") for event in events if event.source in _HUD_SOURCES]
        fortnite = any(_CROWN_BEAT.search(words) or "victory royale" in words for words in evidence)
        finals = any(_CASHOUT_BEAT.search(words) for words in evidence)
        if fortnite != finals:
            game = "fortnite" if fortnite else "the_finals"
    if game == "fortnite":
        return (
            " You are the Fortnite replay specialist. ONE SHALL RULE is a single crown-versus-crown "
            "elimination accolade, not a second elimination, a crown pickup or a match win. "
            "A crown on the ground is loot, not proof of pickup. React to the crown duel when its "
            "banner confirms it. Mention the storm, shield, or building only with cited evidence."
        )
    if game == "the_finals":
        return (
            " You are the THE FINALS replay specialist. In Cashout, opening a vault, starting a cashout, "
            "stealing it, and completing it are different events. A team HUD notification does not "
            "identify the player who did it or prove a round win. React to the confirmed objective beat."
        )
    return ""


def game_objective(text: str) -> bool:
    words = _words(text)
    return bool(_CROWN_BEAT.search(words) or _CASHOUT_BEAT.search(words))


def unsupported_game_claim(text: str, cited: list[GameplayEvent]) -> str | None:
    hud = [event for event in cited if event.source in _HUD_SOURCES]
    visuals = [event.text or "" for event in cited if event.kind == "visual_observation"]
    for match in _MULTIKILL.finditer(text):
        token = next(value for value in match.groups() if value is not None).casefold()
        required = int(token) if token.isdecimal() else _COUNT_WORDS[token]
        confirmed = set()
        for event in hud:
            if event.kind != "kill":
                continue
            banner = _words(event.text or "")
            named = re.fullmatch(r"(?:you )?eliminated (\w+)", banner)
            if named and named[1] not in {"opponent", "enemy", "player"}:
                confirmed.add(named[1])
        if len(confirmed) < required:
            return "A count needs separately confirmed eliminations. One banner or accolade is one event."
    for pattern in _TACTIC_CLAIMS:
        if pattern.search(text) and not any(pattern.search(observation) for observation in visuals):
            return "A tactic or weapon needs its own cited visual observation. React to the confirmed outcome."
    if _FORTNITE_CLAIM.search(text):
        crown_beat = any(_CROWN_BEAT.search(_words(event.text or "")) for event in hud)
        claims = {match.group().lower() for match in _FORTNITE_CLAIM.finditer(text)}
        supported = {match.group().lower() for source in [*visuals, *(event.text or "" for event in hud)]
                     for match in _FORTNITE_CLAIM.finditer(source)}
        supported = {word.rstrip("s") for word in supported}
        if crown_beat:
            supported.update({"crown", "crowned"})
        if any(claim.rstrip("s") not in supported for claim in claims):
            return "Only mention Fortnite details that appear in the cited evidence."
    if _CROWN_PICKUP.search(text) and not any(_CROWN_PICKUP.search(source) for source in visuals):
        return "A visible crown or elimination accolade does not confirm that the player picked it up."
    if _FINALS_CLAIM.search(text):
        objectives = [_words(event.text or "").replace("cash out", "cashout") for event in hud]
        objectives = [objective for objective in objectives if _CASHOUT_BEAT.search(objective)]
        for claim in _FINALS_CLAIM.finditer(text):
            noun = _words(claim.group()).replace(" ", "").rstrip("s")
            if not any(objective.startswith(noun) for objective in objectives):
                return "Only mention a cashout or vault when the cited HUD confirms that objective."
        if _CASHOUT_ACTOR.search(text):
            return "A team notification does not identify who made that play. React without assigning the action."
        for action, required in _CASHOUT_ACTIONS:
            if action.search(text) and not any(objective.startswith(required) for objective in objectives):
                return "The cited objective shows a different stage of the cashout or vault."
    return None


def commentary_evidence(events: list[GameplayEvent]) -> list[GameplayEvent]:
    # A confirmed banner tells the writer what happened. Nearby picture or
    # sound tells it what to react to without quoting the banner.
    gameplay = [event for event in events if event.kind in _GAMEPLAY_KINDS]
    if gameplay:
        return [event for event in events if event.kind in _GAMEPLAY_KINDS or (
            event.kind in {"visual_observation", "audio_spike"}
            and any(abs(event.t_start - beat.t_start) <= 3.0 for beat in gameplay)
        )]
    return [event for event in events if event.kind != "ocr_text"]


def _hud_regions(primary: NormalizedROI) -> list[tuple[NormalizedROI, str]]:
    if primary.preset in {"custom", "full"}:
        return [(primary, "raw")]
    x, y, w, h = ROI_PRESETS["top_right"]
    # Keep the whole announcement, including a separate "BY" or opponent name.
    announcement = NormalizedROI(preset="bottom_center", x=0.18, y=0.54, w=0.64, h=0.28)
    respawn = NormalizedROI(preset="bottom_center", x=0.30, y=0.92, w=0.40, h=0.08)
    accolades = NormalizedROI(preset="custom", x=0.08, y=0.08, w=0.84, h=0.24)
    return [
        (announcement, "enlarge"), (announcement, "bright"), (respawn, "bright"),
        (accolades, "enlarge"),
        (primary, "raw"),
        *([(NormalizedROI(preset="top_right", x=x, y=y, w=w, h=h), "raw")]
          if primary.preset != "top_right" else []),
    ]


_OCR_SCRIPT = r"""
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
Add-Type -AssemblyName System.Runtime.WindowsRuntime
$null = [Windows.Media.Ocr.OcrEngine, Windows.Foundation, ContentType=WindowsRuntime]
$null = [Windows.Media.Ocr.OcrResult, Windows.Foundation, ContentType=WindowsRuntime]
$null = [Windows.Graphics.Imaging.SoftwareBitmap, Windows.Foundation, ContentType=WindowsRuntime]
$null = [Windows.Graphics.Imaging.BitmapPixelFormat, Windows.Foundation, ContentType=WindowsRuntime]
$language = [Windows.Globalization.Language, Windows.Globalization, ContentType=WindowsRuntime]::new('en-US')
$engine = [Windows.Media.Ocr.OcrEngine]::TryCreateFromLanguage($language)
if ($null -eq $engine) { $engine = [Windows.Media.Ocr.OcrEngine]::TryCreateFromUserProfileLanguages() }
if ($null -eq $engine) { exit 2 }
$asTask = [System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
    $_.Name -eq 'AsTask' -and $_.IsGenericMethodDefinition -and $_.GetParameters().Count -eq 1 -and
    $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1'
} | Select-Object -First 1
$ocrTask = $asTask.MakeGenericMethod([Windows.Media.Ocr.OcrResult])
$results = New-Object 'System.Collections.Generic.List[object]'
foreach ($entry in (ConvertFrom-Json -InputObject ([Console]::In.ReadToEnd()))) {
    $bytes = [Convert]::FromBase64String($entry.pixels)
    $buffer = [System.Runtime.InteropServices.WindowsRuntime.WindowsRuntimeBufferExtensions]::AsBuffer($bytes)
    $bitmap = [Windows.Graphics.Imaging.SoftwareBitmap]::CreateCopyFromBuffer(
        $buffer, [Windows.Graphics.Imaging.BitmapPixelFormat]::Gray8, $entry.width, $entry.height)
    try {
        $task = $ocrTask.Invoke($null, @($engine.RecognizeAsync($bitmap)))
        $result = $task.GetAwaiter().GetResult()
        $lines = @($result.Lines | Select-Object -First 20 | ForEach-Object { $_.Text })
        $results.Add($lines)
    } finally {
        $bitmap.Dispose()
    }
}
[Console]::WriteLine((ConvertTo-Json -InputObject ($results.ToArray()) -Depth 3 -Compress))
"""


def _read_windows_hud(executable: str, batch: list[dict]) -> list | None:
    script = base64.b64encode(_OCR_SCRIPT.encode("utf-16-le")).decode("ascii")
    try:
        result = subprocess.run(
            [executable, "-NoLogo", "-NoProfile", "-NonInteractive", "-EncodedCommand", script],
            input=json.dumps(batch, separators=(",", ":")).encode("ascii"),
            capture_output=True, timeout=30, check=False,
            creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
        )
        if result.returncode == 0 and len(result.stdout) < 512_000:
            rows = json.loads(result.stdout)
            if isinstance(rows, list) and len(rows) == len(batch):
                return rows
    except (OSError, ValueError, subprocess.TimeoutExpired):
        pass
    return None


def _hud_samples(frames, duration: float, fps: int):
    tail = max(8.0, duration - 5.0)
    stride = max(1, ceil((tail - 8.0) * fps / 38))
    for index, frame in enumerate(frames):
        time = index / fps
        if time >= duration:
            break
        if time < 8.0 or time >= tail or index % stride == 0:
            yield time, frame


def windows_hud_events(path, probe, primary_roi, read_frames, cancel) -> tuple[list[GameplayEvent], dict]:
    executable = shutil.which("powershell.exe") if sys.platform == "win32" else None
    failed = {"ok": False, "live_verified": False, "detail": "Windows OCR could not read the game HUD."}
    if not executable:
        return [], failed
    try:
        from PIL import Image
    except ImportError:
        return [], failed
    if probe.width < 2 or probe.height < 2:
        return [], failed
    width = even(min(probe.width, 1440, int(sqrt(1_000_000 * probe.width / probe.height))))
    height = even(max(2, round(probe.height * width / probe.width)))
    if width < 2 or width * height > 1_050_000:
        return [], failed
    regions = _hud_regions(primary_roi)
    batch: list[dict] = []
    positions: list[tuple[float, str]] = []
    readings: list[tuple[tuple[float, str], object]] = []
    batch_bytes = 0
    missed = 0

    def read_batch() -> None:
        nonlocal batch_bytes, missed
        check_cancel(cancel)
        rows = _read_windows_hud(executable, batch)
        if rows is None:
            missed += len(batch)
        else:
            readings.extend(zip(positions, rows))
        batch.clear()
        positions.clear()
        batch_bytes = 0
        check_cancel(cancel)

    fps = 3
    frames = read_frames(path, width, height, fps, cancel)
    for time, raw in _hud_samples(frames, probe.duration, fps):
        check_cancel(cancel)
        frame = Image.frombytes("RGB", (width, height), raw, "raw", "BGR").convert("L")
        for region, mode in regions:
            x, y, w, h = roi_pixels(region, width, height)
            crop = frame.crop((x, y, x + w, y + h))
            if mode in {"enlarge", "bright"}:
                crop = crop.resize((w * 2, h * 2), Image.Resampling.LANCZOS)
            if mode == "bright":
                crop = crop.point(_WHITE_HUD)
            size = crop.width * crop.height
            if batch and batch_bytes + size > _MAX_OCR_BATCH_BYTES:
                read_batch()
            batch.append({"width": crop.width, "height": crop.height,
                          "pixels": base64.b64encode(crop.tobytes()).decode("ascii")})
            positions.append((time, region.preset))
            batch_bytes += size
    if batch:
        read_batch()
    if not readings:
        return [], failed
    events = []
    seen: dict[tuple[str, str], float] = {}
    for (time, region), lines in readings:
        if not isinstance(lines, list):
            continue
        labels = [" ".join(raw.split())[:120] for raw in lines if isinstance(raw, str) and raw.strip()]
        for index, text in enumerate(labels):
            if text.casefold() in {"eliminated", "killed"} and index + 1 < len(labels):
                following = labels[index + 1]
                if re.match(r"by\b", following, re.I):
                    text = f"{text} {following}"
            kind = classify_hud_text(text)
            if kind == "ocr_text":
                continue
            if kind == "kill" and region == "top_right" and text.casefold() in {"eliminated", "killed"}:
                continue
            if kind == "kill" and text.casefold().startswith("eliminated"):
                # Opponent names are often stylized or noisy. The game banner is the evidence.
                text = "ELIMINATED"
            key = kind, "respawn available" if text.casefold().startswith("respawn available") else text.casefold()
            previous = seen.get(key)
            seen[key] = time
            if previous is not None and time - previous <= 2.0:
                continue
            events.append(GameplayEvent(
                id=f"win{len(events) + 1}", kind=kind, source="windows_ocr", roi=region, text=text,
                t_start=round(time, 3), t_end=round(min(probe.duration, time + 1 / 3), 3), confidence=0.7,
            ))
    detail = ("Windows OCR read only some sampled HUD regions." if missed
              else "Windows OCR read sampled frames in the game's HUD.")
    return events, {"ok": True, "live_verified": True, "hits": len(events), "detail": detail}

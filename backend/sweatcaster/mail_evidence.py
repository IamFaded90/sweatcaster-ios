"""Check proposed appointment facts against visible Gmail text. Persist only a source locator."""

from datetime import date, datetime, timedelta
from hashlib import sha256
import re


MONTHS = [
    ("januar", "january", "jan"), ("februar", "february", "feb"), ("marts", "march", "mar"),
    ("april", "apr"), ("maj", "may"), ("juni", "june", "jun"), ("juli", "july", "jul"),
    ("august", "aug"), ("september", "sep", "sept"), ("oktober", "october", "okt", "oct"),
    ("november", "nov"), ("december", "dec"),
]
MONTH = {name: n for n, names in enumerate(MONTHS, 1) for name in names}
DATE = (r"(?P<day>\d{1,2})[./-](?P<month>\d{1,2})[./-](?P<year>\d{4})"
        r"|(?P<iso>\d{4}-\d{2}-\d{2})"
        r"|(?P<wordday>\d{1,2})\.?\s+(?P<wordmonth>" + "|".join(MONTH) + r")\.?\s+(?P<wordyear>\d{4})"
        r"|(?P<relative>i overmorgen|i morgen|i dag|tomorrow|today)")
SLOT = re.compile(r"(?<!\w)(?:" + DATE + r")(?:\s*(?:,|T)\s*|\s+)(?:(?P<marker>kl(?:okken)?\.?|at)\s*)?"
                  r"(?P<hour>\d{1,2})(?:[:.](?P<minute>[0-5]\d))?(?:\s*(?P<period>[ap])\.?m\.?)?(?!\w|[.:]\d)", re.I)
END = re.compile(r"^\s*(?:[-–]|til\b|to\b)\s*(?:kl\.?\s*)?(\d{1,2})[:.]([0-5]\d)\b", re.I)
SUBJECT = r"(?:aftale(?:n)?|tid(?:en)?|besøg(?:et)?|booking|appointment|reservation|møde(?:t)?)"
REVISION = {
    "cancelled": re.compile(r"\b(?:" + SUBJECT + r"\s+(?:(?:er|blev|bliver|is|was|has been)\s+)?"
                            r"(?:(?:nu|blevet)\s+)?(?:aflyst|annulleret|cancelled|canceled)|(?:vi (?:har aflyst|aflyser)|we (?:cancelled|canceled))"
                            r"\s+(?:din |dit |your )?" + SUBJECT + r")\b", re.I),
    "rescheduled": re.compile(r"\b(?:" + SUBJECT + r"\s+(?:(?:er|blev|bliver|is|was|has been)\s+)?"
                              r"(?:(?:nu|blevet)\s+)?(?:flyttet|rykket|ombooket|ændret|rescheduled)|(?:vi (?:har flyttet|flytter)|we rescheduled)"
                              r"\s+(?:din |dit |your )?" + SUBJECT + r")\b", re.I),
}
CONDITIONAL = re.compile(r"\b(?:hvis|såfremt|dersom|if|unless|kan|could|may|might|ikke|not)\b", re.I)
OLD_SLOT = re.compile(r"(?:\b(?:fra|from|tidligere|oprindelig|originally|previously|ankomst|check-in)\s*[:–-]?\s*)$", re.I)
OTHER_TIME = re.compile(r"\b(?:svarfrist|betalingsfrist|afbudsfrist|senest|deadline|reply by|pay by|cancel by|"
                        r"check[- ]in|mød(?:e)?\s+(?:op\s+)?(?:senest|tidligst))\b", re.I)


def line_range(text, pos, end):
    """Prefer the containing line. Keep excessively long HTML paragraphs close to the match."""
    lo = max(text.rfind("\n", 0, pos) + 1, pos - 110)
    right = text.find("\n", end)
    hi = min(right if right != -1 else len(text), end + 130)
    return lo, hi


def explicit_date(match, received):
    groups = match.groupdict()
    try:
        if groups["iso"]:
            return date.fromisoformat(groups["iso"])
        if groups["relative"]:
            days = {"i overmorgen": 2, "i morgen": 1, "tomorrow": 1, "i dag": 0, "today": 0}
            return received.date() + timedelta(days=days[groups["relative"].lower()])
        if groups["wordday"]:
            return date(int(groups["wordyear"]), MONTH[groups["wordmonth"].lower()], int(groups["wordday"]))
        return date(int(groups["year"]), int(groups["month"]), int(groups["day"]))
    except (KeyError, ValueError):
        return None


def hour_value(hour, period):
    h = int(hour)
    if not period:
        return h
    if not 1 <= h <= 12:
        return -1
    return h % 12 + (12 if period.lower() == "p" else 0)


def source_locator(text, message_id, span=None):
    result = {"message": message_id, "digest": sha256(text.encode()).hexdigest()}
    if span:
        result["range"] = list(span)
    return result


def check_proposal(kind, summary, text, received, zone, message_id):
    """Ambiguous facts stay suggestions. A previous or conditional change never invalidates another event."""
    if kind == "unrelated":
        return kind, summary, None
    revision = None
    if kind in REVISION:
        for match in REVISION[kind].finditer(text):
            lo, hi = line_range(text, *match.span())
            if CONDITIONAL.search(text[lo:hi]) is None and "?" not in text[lo:hi]:
                revision = (lo, hi)
                break
        if revision is None:
            return "unrelated", None, None
    if not summary:
        return kind, summary, source_locator(text, message_id, revision)
    if kind == "confirmed" and any(regex.search(text) for regex in REVISION.values()):
        return "unrelated", None, None
    if summary["title"].casefold() not in text.casefold():
        summary["title"] = "Aftale fra Gmail"
    if summary["location"] and summary["location"].casefold() not in text.casefold():
        summary["location"] = ""
    slot = None
    if summary["start"] is not None:
        starts = datetime.fromtimestamp(summary["start"], zone)
        candidates = []
        for match in SLOT.finditer(text):
            lo, hi = line_range(text, *match.span())
            if not (match["marker"] or match["minute"] or match["period"]):
                continue
            if (CONDITIONAL.search(text[lo:hi]) or "?" in text[lo:hi] or OTHER_TIME.search(text[lo:match.start()])
                    or OLD_SLOT.search(text[lo:match.start()])
                    or re.match(r"\s*(?:UTC|GMT|Z\b|[+-]\d{2}:?\d{2}|[ECMP][DS]T\b)", text[match.end():], re.I)):
                continue
            candidates.append((explicit_date(match, received), hour_value(match["hour"], match["period"]),
                               int(match["minute"] or 0), match))
        distinct = {c[:3] for c in candidates}
        if distinct == {(starts.date(), starts.hour, starts.minute)}:
            slot = candidates[0][3]
        else:
            summary["start"] = None
    end = END.match(text[slot.end():]) if slot else None
    if summary["end"] is not None:
        ends = datetime.fromtimestamp(summary["end"], zone)
        if not end or ends.date() != starts.date() or (ends.hour, ends.minute) != tuple(map(int, end.groups())):
            summary["end"] = None
    span = None
    if slot:
        span = line_range(text, slot.start(), slot.end() + (end.end() if end else 0))
    return kind, summary, source_locator(text, message_id, span or revision)

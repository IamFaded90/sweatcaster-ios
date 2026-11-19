"""Read and recheck an explicit reschedule in the connected Gmail inbox."""

from datetime import datetime, timedelta
from email.utils import parseaddr
from concurrent.futures import ThreadPoolExecutor
import re
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from fastapi import Body, Request, Response

from sweatcaster.dto import ApiError
from sweatcaster.mail_appointments import GMAIL, MAIL_ID, mail_text, tidy
from sweatcaster.mail_evidence import (
    CONDITIONAL, END, OLD_SLOT, OTHER_TIME, REVISION, SLOT, explicit_date, hour_value, line_range,
)


PATH = "/api/modules/v1/mail-reschedule"
THREADS = GMAIL.rsplit("/", 1)[0] + "/threads"
SEARCH = ('newer_than:60d -in:sent {"flyttet" "rykket" "ombooket" "ændret" "rescheduled"}')
TERMS = {
    "tandlægen": "{tandlæge tandlægen tandklinik}",
    "lægen": "{læge lægen lægehus}", "værkstedet": "{værksted værkstedet autoværksted}",
}


def slot_time(match, received, zone):
    day = explicit_date(match, received)
    hour = hour_value(match["hour"], match["period"])
    if day is None or not 0 <= hour <= 23:
        return None
    value = datetime(day.year, day.month, day.day, hour, int(match["minute"] or 0), tzinfo=zone)
    return value if value.utcoffset() == value.replace(fold=1).utcoffset() else None


def reschedule(message, thread, zone, now):
    text = mail_text(message, allow_snippet=False)
    if not text:
        return None
    if REVISION["cancelled"].search(text):
        return None
    revisions = []
    for match in REVISION["rescheduled"].finditer(text):
        lo, hi = line_range(text, *match.span())
        if not CONDITIONAL.search(text[lo:hi]) and "?" not in text[lo:hi]:
            revisions.append((lo, hi))
    if not revisions:
        return None
    new, old = {}, set()
    try:
        received = datetime.fromtimestamp(int(message["internalDate"]) / 1000, tz=zone)
    except (KeyError, ValueError, TypeError, OSError, OverflowError):
        return None
    for match in SLOT.finditer(text):
        lo, hi = line_range(text, *match.span())
        if (not (match["marker"] or match["minute"] or match["period"])
                or CONDITIONAL.search(text[lo:hi]) or "?" in text[lo:hi]
                or OTHER_TIME.search(text[lo:match.start()])
                or re.match(r"\s*(?:UTC|GMT|Z\b|[+-]\d{2}:?\d{2}|[ECMP][DS]T\b)", text[match.end():], re.I)):
            continue
        value = slot_time(match, received, zone)
        if value is None:
            return None
        if OLD_SLOT.search(text[lo:match.start()]):
            old.add(value.timestamp())
        else:
            new[value] = match
    if len(new) != 1:
        return None
    start, match = next(iter(new.items()))
    if not now < start <= now + timedelta(days=540):
        return None
    lo, hi = line_range(text, *match.span())
    evidence = list(dict.fromkeys([text[slice(*revisions[0])], text[lo:hi]]))
    end = None
    if found := END.match(text[match.end():]):
        hour, minute = map(int, found.groups())
        if hour <= 23:
            candidate = start.replace(hour=hour, minute=minute)
            if candidate > start and candidate.utcoffset() == candidate.replace(fold=1).utcoffset():
                end = candidate.timestamp()
    headers = (message.get("payload") or {}).get("headers") or []
    if not isinstance(headers, list):
        return None
    fields = {str(row.get("name", "")).lower(): row.get("value") for row in headers if isinstance(row, dict)}
    sender, address = parseaddr(tidy(fields.get("from") or message.get("sender"), 320))
    return {"id": message["id"], "thread": thread, "start": start.timestamp(), "end": end,
            "oldStart": next(iter(old)) if len(old) == 1 else None,
            "sender": tidy(sender or address, 120), "subject": tidy(fields.get("subject") or message.get("subject"), 180),
            "quote": "\n".join(evidence)[:560]}


def thread_change(library, account, thread, zone, now):
    data = library.read("gmail", f"{THREADS}/{thread}", {"format": "full"}, account=account)
    messages = data.get("messages") if isinstance(data, dict) and data.get("id") == thread else None
    if not isinstance(messages, list) or not 1 <= len(messages) <= 50:
        return None
    inbound = []
    for message in messages:
        if not isinstance(message, dict) or message.get("threadId") != thread:
            return None
        labels = message.get("labelIds")
        if not isinstance(labels, list) or not all(isinstance(label, str) for label in labels):
            return None
        if set(labels) & {"SENT", "DRAFT", "SPAM", "TRASH"}:
            continue
        if not isinstance(message.get("id"), str) or not MAIL_ID.fullmatch(message["id"]):
            return None
        try:
            received = int(message["internalDate"])
        except (KeyError, TypeError, ValueError):
            return None
        inbound.append((received, message))
    if not inbound:
        return None
    inbound.sort(key=lambda row: row[0], reverse=True)
    if len(inbound) > 1 and inbound[0][0] == inbound[1][0]:
        return None
    latest = inbound[0][1]
    if not isinstance(latest.get("payload"), dict):
        full = library.read("gmail", f"{GMAIL}/{latest['id']}", {"format": "full"}, account=account)
        if not isinstance(full, dict) or full.get("id") != latest["id"] or full.get("threadId") != thread:
            return None
        latest = {**full, "internalDate": latest["internalDate"]}
    return reschedule(latest, thread, zone, now)


def search_changes(library, account, rows, zone, now):
    def thread_for(row):
        if not isinstance(row, dict):
            return None
        thread = row.get("threadId")
        identifier = row.get("id")
        if thread is None and isinstance(identifier, str) and MAIL_ID.fullmatch(identifier):
            info = library.read("gmail", f"{GMAIL}/{identifier}", {"format": "metadata"}, account=account)
            thread = info.get("threadId") if isinstance(info, dict) and info.get("id") == identifier else None
        return thread if isinstance(thread, str) and MAIL_ID.fullmatch(thread) else None

    with ThreadPoolExecutor(max_workers=3) as pool:
        threads = list(dict.fromkeys(item for item in pool.map(thread_for, rows[:8]) if item))[:5]
        changes = [item for item in pool.map(lambda thread: thread_change(library, account, thread, zone, now), threads) if item]
    return changes


def register_mail_reschedule(app, settings, authorize, library):
    @app.put(PATH, include_in_schema=False)
    def lookup(request: Request, response: Response, body: dict = Body(...)):
        authorize(request, settings)
        response.headers["Cache-Control"] = "no-store"
        try:
            zone_name = body.get("zone")
            if not isinstance(zone_name, str) or not re.fullmatch(r"[A-Za-z0-9_+/-]{1,80}", zone_name):
                raise ValueError
            zone = ZoneInfo(zone_name)
        except (ZoneInfoNotFoundError, ValueError):
            raise ApiError(422, "INVALID_INPUT", "Tidszonen kunne ikke læses.") from None
        account = library.connection("gmail")
        if not account:
            raise ApiError(409, "NOT_READY", "Forbind Gmail for at finde den flyttede aftale.")
        now = datetime.now(zone)
        thread = body.get("thread")
        if thread is not None:
            if not isinstance(thread, str) or not MAIL_ID.fullmatch(thread):
                raise ApiError(422, "INVALID_INPUT", "Gmail-tråden kunne ikke læses.")
            change = thread_change(library, account, thread, zone, now)
            changes = [change] if change else []
        else:
            term = tidy(body.get("query"), 100)
            term = " ".join(re.findall(r"[^\W_]+", term))
            scope = TERMS.get(term.casefold(), term)
            data = library.read("gmail", GMAIL, {"q": f"{SEARCH} {scope}".strip(), "maxResults": 16}, account=account)
            if not isinstance(data, dict) or not isinstance(data.get("messages", []), list):
                raise ApiError(502, "NOT_READY", "Gmail-søgningen svarede i et ukendt format.")
            changes = search_changes(library, account, data.get("messages", []), zone, now)
        if library.connection("gmail") != account:
            raise ApiError(409, "NOT_READY", "Gmail-forbindelsen skiftede. Søg igen.")
        return {"changes": changes}

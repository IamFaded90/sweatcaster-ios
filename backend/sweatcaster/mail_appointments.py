"""Prepare iPhone appointment suggestions from opted-in Gmail reads on the PC."""

import base64
import binascii
import hashlib
from contextlib import closing
from datetime import datetime, timedelta, timezone
from html.parser import HTMLParser
import json
import re
import sqlite3
from threading import Event, Thread
from time import time
from uuid import UUID, uuid5
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from fastapi import APIRouter, Body, Depends, Request, Response

from sweatcaster.bot_computers import BotComputerError, ModelBusy, wire_uuid
from sweatcaster.dto import ApiError

GMAIL = "https://gmail.googleapis.com/gmail/v1/users/me/messages"
MAIL_ID = re.compile(r"[A-Za-z0-9_-]{1,128}")
LOCAL_DATE = re.compile(r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}")
CLOCK = re.compile(r"\b(?:kl(?:okken)?\.?\s*|at\s+)([01]?\d|2[0-3])[:.]([0-5]\d)"
                   r"(?:\s*([ap])\.?m\b\.?)?(?![\d:])", re.IGNORECASE)
BOOKED_DANISH_SLOT = re.compile(
    r"\b(?:aftalen?|tiden?)\s+(?:(?:er|blev)\s+)?(?:bekræftet|booket|reserveret|finder\s+sted)"
    r"\s+(?:(?:til|den|d\.)\s+){0,2}(\d{1,2})[./-](\d{1,2})[./-](\d{4})"
    r"\s*,?\s*kl(?:okken)?\.?\s*([01]?\d|2[0-3])[:.]([0-5]\d)\b",
    re.IGNORECASE,
)
SEARCH = ('newer_than:30d {"aftale" "lægetid" "tidsbestilling" "indkaldelse" "appointment" "booking confirmation" '
          '"aftalen er aflyst" "aftalen er flyttet" "booking cancelled" "booking canceled" "rescheduled"}')
SCAN_DELAY = 300
APPOINTMENT_NAMESPACE = UUID("6740f0e5-7e22-4f94-981a-12972edfb509")
QUOTE_HEADER = re.compile(r"^(?:On .+ wrote:|Den .+ skrev.*:|[-]{2,}\s*(?:Original Message|Oprindelig meddelelse)\s*[-]{2,})$",
                          re.IGNORECASE)
HIDDEN_HTML = {"blockquote", "script", "style"}


class MailHTML(HTMLParser):
    def __init__(self, text):
        super().__init__(convert_charrefs=True)
        self.parts = []
        self.hidden = 0
        self.feed(text)

    def handle_starttag(self, tag, attrs):
        if tag in HIDDEN_HTML:
            self.hidden += 1
        if not self.hidden and tag in {"br", "p", "tr", "li", "div"}:
            self.parts.append("\n")

    def handle_endtag(self, tag):
        if tag in HIDDEN_HTML:
            self.hidden = max(0, self.hidden - 1)

    def handle_data(self, text):
        if not self.hidden:
            self.parts.append(text)


def mail_text(message):
    root = message.get("payload") or {}
    if not isinstance(root, dict):
        return ""
    queue = [root]
    texts = {"text/plain": [], "text/html": []}
    for _ in range(40):
        if not queue:
            break
        part = queue.pop(0)
        if not isinstance(part, dict) or part.get("filename"):
            continue
        mime = part.get("mimeType")
        if isinstance(mime, str) and mime in texts:
            body = part.get("body") or {}
            encoded = body.get("data") if isinstance(body, dict) else None
            if isinstance(encoded, str) and len(encoded) <= 192_000:
                try:
                    data = base64.b64decode(encoded + "=" * (-len(encoded) % 4), altchars=b"-_", validate=True)
                    text = data[:72_000].decode("utf-8", errors="replace")
                    texts[mime].append(text if mime == "text/plain" else "".join(MailHTML(text).parts))
                except (binascii.Error, ValueError):
                    pass
        if isinstance(part.get("parts"), list):
            queue.extend(part["parts"][:20])
    headers = root.get("headers")
    subject = next((h.get("value", "") for h in headers[:100] if isinstance(h, dict)
                    and str(h.get("name", "")).lower() == "subject"), "") if isinstance(headers, list) else ""
    lines = []
    for line in "\n".join(texts["text/plain"] or texts["text/html"]).splitlines():
        if len(line) <= 400 and QUOTE_HEADER.fullmatch(line.strip()):
            break
        if not line.lstrip().startswith(">"):
            lines.append(line)
    body = "\n".join(lines)
    if not body.strip():
        body = str(message.get("snippet") or "")
    return (str(subject)[:350] + "\n" + body).replace("\0", "").strip()[:8_000]


def tidy(value, maximum):
    return " ".join(value.split())[:maximum] if isinstance(value, str) else ""


def decode_proposal(raw):
    if not isinstance(raw, str) or len(raw) > 4_000:
        raise ValueError("Unexpected model output")
    proposal = json.loads(raw)
    required = {"title", "start", "end", "location"}
    if not isinstance(proposal, dict) or set(proposal) not in (required, required | {"status"}):
        raise ValueError("Unexpected appointment")
    status = proposal.get("status", "confirmed")
    if status not in ("confirmed", "rescheduled", "cancelled", "unrelated"):
        raise ValueError("Unexpected appointment status")
    return status, proposal


def decode_appointment(raw, zone, now, text=""):
    status, proposal = decode_proposal(raw)
    return appointment_details(proposal, zone, now, text) if status in {"confirmed", "rescheduled"} else None


def appointment_details(proposal, zone, now, text):
    def timestamp(value):
        if not isinstance(value, str) or LOCAL_DATE.fullmatch(value) is None:
            return None
        naive = datetime.fromisoformat(value)
        candidate = naive.replace(tzinfo=zone)
        if candidate.utcoffset() != candidate.replace(fold=1).utcoffset():
            return None
        return candidate.astimezone(timezone.utc)

    title = tidy(proposal["title"], 120)
    if not title:
        return None
    start = timestamp(proposal["start"])
    location = tidy(proposal["location"], 240)
    literal_slots = set(BOOKED_DANISH_SLOT.findall(text))
    if len(literal_slots) == 1:
        day, month, year, hour, minute = map(int, literal_slots.pop())
        try:
            literal_start = timestamp(f"{year:04}-{month:02}-{day:02}T{hour:02}:{minute:02}")
            if literal_start and (start is None or start.astimezone(zone).date() == literal_start.astimezone(zone).date()):
                start = literal_start
        except ValueError:
            pass
    if start is not None:
        explicit_times = set()
        for hour, minute, period in CLOCK.findall(text):
            normalized_hour = int(hour)
            if period:
                normalized_hour = normalized_hour % 12 + (12 if period.lower() == "p" else 0)
            explicit_times.add((normalized_hour, int(minute)))
        wall_time = start.astimezone(zone)
        if explicit_times and (wall_time.hour, wall_time.minute) not in explicit_times:
            start = None
    if start is None:
        return {"title": title, "location": location, "start": None, "end": None}
    if not now < start <= now + timedelta(days=540):
        return None
    end = timestamp(proposal["end"])
    if end is not None and not start < end <= start + timedelta(days=1):
        end = None
    return {"title": title, "location": location,
            "start": start.timestamp(), "end": end.timestamp() if end else None}


class MailAppointments:
    def __init__(self, path, library, propose):
        self.path, self.library, self.propose = path, library, propose
        self.stop_signal = Event()
        self.worker = None

    def db(self):
        return sqlite3.connect(self.path, timeout=6)

    def prepare(self):
        with closing(self.db()) as db, db:
            db.executescript("""
                CREATE TABLE IF NOT EXISTS setup (
                    singleton INTEGER PRIMARY KEY CHECK(singleton = 1), bot TEXT NOT NULL,
                    zone TEXT NOT NULL, due REAL NOT NULL, account TEXT NOT NULL, checked REAL, notice TEXT
                );
                CREATE TABLE IF NOT EXISTS checked_mail (
                    id TEXT PRIMARY KEY, checked REAL NOT NULL
                );
                CREATE TABLE IF NOT EXISTS appointment (
                    id TEXT PRIMARY KEY, account TEXT NOT NULL, details TEXT NOT NULL, starts REAL NOT NULL,
                    thread TEXT NOT NULL, dated INTEGER NOT NULL,
                    hidden INTEGER NOT NULL DEFAULT 0, revision_status TEXT NOT NULL DEFAULT 'active'
                );
                CREATE TABLE IF NOT EXISTS mail_revision (
                    account TEXT NOT NULL, thread TEXT NOT NULL, received INTEGER NOT NULL,
                    status TEXT NOT NULL, PRIMARY KEY(account, thread)
                );
            """)
            columns = {row[1] for row in db.execute("PRAGMA table_info(appointment)")}
            if "revision_status" not in columns:
                db.execute("ALTER TABLE appointment ADD COLUMN revision_status TEXT NOT NULL DEFAULT 'active'")

    def start(self):
        self.prepare()
        self.stop_signal.clear()
        self.worker = Thread(target=self.run, daemon=True, name="fadedai-mail-appointments")
        self.worker.start()

    def stop(self):
        self.stop_signal.set()
        if self.worker:
            self.worker.join(2)

    def settings(self):
        with closing(self.db()) as db:
            return db.execute("SELECT bot, zone, due, account FROM setup").fetchone()

    def status(self, bot):
        with closing(self.db()) as db:
            selected = db.execute("SELECT bot, checked, notice, account FROM setup").fetchone()
            enabled = bool(selected and selected[0] == bot)
            rows = db.execute("SELECT id, details, revision_status FROM appointment WHERE account = ? AND hidden = 0 AND starts > ? "
                              "ORDER BY starts LIMIT 30", (selected[3], time())).fetchall() if enabled else []
        return {"enabled": enabled, "otherBot": bool(selected and not enabled), "hasProject": bool(self.library.key()),
                "checked": selected[1] if enabled else None, "notice": selected[2] if enabled else None,
                "appointments": [dict(json.loads(details), id=identifier, revisionStatus=revision)
                                 for identifier, details, revision in rows]}

    def configure(self, bot, enabled, zone):
        if type(enabled) is not bool:
            raise ApiError(422, "INVALID_INPUT", "Vælg om agenten skal finde aftaler.")
        if enabled:
            try:
                if not isinstance(zone, str) or not re.fullmatch(r"[A-Za-z0-9_+/-]{1,80}", zone):
                    raise ValueError
                ZoneInfo(zone)
            except (ZoneInfoNotFoundError, ValueError):
                raise ApiError(422, "INVALID_INPUT", "Telefonens tidszone kunne ikke læses af PC’en.") from None
            account = self.library.connection("gmail")
            if not account:
                raise ApiError(409, "NOT_READY", "Log ind på Gmail, før du slår aftalesøgning til.")
        with closing(self.db()) as db, db:
            if enabled:
                db.execute("INSERT INTO setup(singleton, bot, zone, account, due) VALUES(1,?,?,?,0) "
                           "ON CONFLICT(singleton) DO UPDATE SET bot = excluded.bot, zone = excluded.zone, "
                           "account = excluded.account, due = 0, checked = NULL, notice = NULL", (bot, zone, account))
            else:
                db.execute("DELETE FROM setup WHERE bot = ?", (bot,))
        return self.status(bot)

    def queue(self, bot):
        with closing(self.db()) as db, db:
            db.execute("UPDATE setup SET due = 0, notice = NULL WHERE bot = ?", (bot,))
        return self.status(bot)

    def hide(self, bot, identifier):
        with closing(self.db()) as db, db:
            db.execute("UPDATE appointment SET hidden = 1 WHERE id = ? AND account = (SELECT account FROM setup WHERE bot = ?)",
                       (identifier, bot))
        return self.status(bot)

    def run(self):
        while not self.stop_signal.wait(3):
            try:
                self.check_due()
            except sqlite3.Error:
                self.stop_signal.wait(10)

    def check_due(self):
        selection = self.settings()
        if not selection or selection[2] > time():
            return
        bot, zone_name, due, account = selection
        notice = None
        try:
            more = self.scan(selection)
        except ModelBusy:
            more = True
            notice = "PC-modellen er optaget. Aftalesøgningen prøver igen om lidt."
        except ApiError as exc:
            more = False
            notice = str(exc)
        except (BotComputerError, OSError, ValueError, KeyError, TypeError, OverflowError):
            more = False
            notice = "Aftalerne kunne ikke tjekkes nu. Kontrollér Gmail-login og den lokale model på PC’en."
        checked = time()
        with closing(self.db()) as db, db:
            db.execute("UPDATE setup SET due = ?, checked = ?, notice = ? WHERE bot = ? AND zone = ? AND due = ? "
                       "AND account = ?", (checked + (30 if more else SCAN_DELAY), checked, notice, bot, zone_name, due, account))
            db.execute("DELETE FROM checked_mail WHERE checked < ?", (checked - 45 * 86400,))
            db.execute("DELETE FROM appointment WHERE starts < ?", (checked - 86400,))
            db.execute("DELETE FROM mail_revision WHERE received < ? AND NOT EXISTS "
                       "(SELECT 1 FROM appointment WHERE appointment.account = mail_revision.account "
                       "AND appointment.thread = mail_revision.thread)", (int((checked - 45 * 86400) * 1000),))

    def scan(self, selection):
        account = self.library.connection("gmail")
        if not account or account != selection[3]:
            raise ApiError(409, "NOT_READY", "Forbind Gmail igen, og slå aftalesøgning til på ny.")
        zone = ZoneInfo(selection[1])
        count = 0
        for message_id in self.candidate_ids(selection, account):
            hashed = hashlib.sha256((account + ":" + message_id).encode()).hexdigest()
            with closing(self.db()) as db:
                if db.execute("SELECT 1 FROM checked_mail WHERE id = ?", (hashed,)).fetchone():
                    continue
            if self.stop_signal.is_set() or self.settings() != selection:
                return False
            if count >= 4:
                return True
            count += 1
            mail = self.library.read("gmail", f"{GMAIL}/{message_id}",
                                     {"format": "full", "fields": "id,threadId,internalDate,snippet,payload"}, account=account)
            if not isinstance(mail, dict) or mail.get("id") != message_id:
                raise ValueError("Unexpected Gmail message")
            now = datetime.now(timezone.utc)
            try:
                received_ms = int(mail["internalDate"])
            except (KeyError, TypeError, ValueError):
                self.record(selection, account, hashed, None, 0, "unrelated", None)
                continue
            received = datetime.fromtimestamp(received_ms / 1000, tz=zone)
            text = mail_text(mail)
            summary = None
            kind = "unrelated"
            if text:
                raw = self.propose(text, {"now": now.astimezone(zone).isoformat(),
                                         "received": received.isoformat(), "zone": selection[1]})
                try:
                    kind, proposal = decode_proposal(raw)
                    if kind in {"confirmed", "rescheduled"}:
                        summary = appointment_details(proposal, zone, now, text)
                except (ValueError, RecursionError):
                    pass
            self.record(selection, account, hashed, mail.get("threadId"), received_ms, kind, summary)
        return False

    def candidate_ids(self, selection, account):
        query = {"q": SEARCH, "maxResults": 40}
        seen_pages = set()
        for _ in range(3):
            if self.stop_signal.is_set() or self.settings() != selection:
                return
            data = self.library.read("gmail", GMAIL, query, account=account)
            if not isinstance(data, dict) or not isinstance(data.get("messages", []), list):
                raise ValueError("Invalid Gmail results")
            for row in data.get("messages", [])[:40]:
                identifier = row.get("id") if isinstance(row, dict) else None
                if isinstance(identifier, str) and MAIL_ID.fullmatch(identifier):
                    yield identifier
            token = data.get("nextPageToken")
            if not isinstance(token, str) or not 1 <= len(token) <= 1024 or token in seen_pages:
                return
            seen_pages.add(token)
            query = {**query, "pageToken": token}

    def record(self, selection, account, hashed, thread_id, received, kind, summary):
        with closing(self.db()) as db, db:
            db.execute("BEGIN IMMEDIATE")
            if db.execute("SELECT bot, zone, due, account FROM setup").fetchone() != selection:
                return
            db.execute("INSERT OR IGNORE INTO checked_mail VALUES(?,?)", (hashed, time()))
            if kind != "cancelled" and summary is None:
                return
            thread = thread_id if isinstance(thread_id, str) and MAIL_ID.fullmatch(thread_id) else hashed
            latest = db.execute("SELECT received, status FROM mail_revision WHERE account = ? AND thread = ?",
                                (account, thread)).fetchone()
            if latest and (received < latest[0] or (received == latest[0] and latest[1] == "cancelled")):
                return
            db.execute("INSERT INTO mail_revision VALUES(?,?,?,?) ON CONFLICT(account, thread) DO UPDATE "
                       "SET received = excluded.received, status = excluded.status", (account, thread, received, kind))
            if kind == "cancelled":
                db.execute("UPDATE appointment SET revision_status = 'cancelled' "
                           "WHERE account = ? AND thread = ? AND revision_status = 'active'", (account, thread))
                return
            self.store_suggestion(db, account, thread, thread_id, kind, summary)

    def store_suggestion(self, db, account, thread, thread_id, kind, summary):
        identity = str(uuid5(APPOINTMENT_NAMESPACE, f"{account}:{thread}:{summary['start']}"))
        dated = summary["start"] is not None
        if kind == "rescheduled":
            db.execute("UPDATE appointment SET revision_status = 'superseded' "
                       "WHERE account = ? AND thread = ? AND id != ? AND revision_status = 'active'",
                       (account, thread, identity))
        if dated:
            incomplete = str(uuid5(APPOINTMENT_NAMESPACE, f"{account}:{thread}:None"))
            db.execute("UPDATE appointment SET hidden = 1 WHERE id = ? AND revision_status = 'active'", (incomplete,))
        elif kind != "rescheduled":
            if db.execute("SELECT 1 FROM appointment WHERE account = ? AND thread = ? AND dated = 1 "
                          "AND revision_status = 'active'", (account, thread)).fetchone():
                return
        expiry = summary["start"] if dated else time() + 7 * 86400
        details = dict(summary, gmailThread=thread_id) if thread == thread_id else summary
        db.execute("INSERT INTO appointment(id, account, details, starts, thread, dated) VALUES(?,?,?,?,?,?) "
                   "ON CONFLICT(id) DO UPDATE SET details = excluded.details, revision_status = 'active'",
                   (identity, account, json.dumps(details, ensure_ascii=False), expiry, thread, dated))


def register_mail_appointments(app, settings, authorize, library, propose):
    service = MailAppointments(settings.output_root / "mail-appointments.sqlite3", library, propose)

    def paired(request: Request, response: Response):
        authorize(request, settings)
        response.headers["Cache-Control"] = "no-store"

    def wire(value):
        try:
            return wire_uuid(value)
        except BotComputerError as exc:
            raise ApiError(exc.status, "INVALID_INPUT", exc.message) from exc

    router = APIRouter(prefix="/api/modules/v1/mail-appointments", dependencies=[Depends(paired)], include_in_schema=False)

    @router.get("/{bot_id}")
    def status(bot_id: str):
        return service.status(wire(bot_id))

    @router.put("/{bot_id}")
    def configure(bot_id: str, body: dict = Body(...)):
        return service.configure(wire(bot_id), body.get("enabled"), body.get("zone"))

    @router.put("/{bot_id}/scan")
    def scan(bot_id: str):
        return service.queue(wire(bot_id))

    @router.put("/{bot_id}/hide")
    def hide(bot_id: str, body: dict = Body(...)):
        return service.hide(wire(bot_id), wire(body.get("id")))

    app.include_router(router)
    return service

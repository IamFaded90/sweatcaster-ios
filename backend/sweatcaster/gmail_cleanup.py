"""Reviewed Gmail cleanup with durable per-message receipts and verified undo."""

from contextlib import closing, nullcontext
from hashlib import sha256
import json
from pathlib import Path
import re
import sqlite3
from threading import RLock
from time import time
from uuid import UUID, uuid4

from fastapi import APIRouter, Body, Depends, Request, Response

from sweatcaster.dto import ApiError
from sweatcaster.gmail_cleanup_provider import CleanupGmail, MESSAGE


PROTECTED = {"STARRED": "Stjernemarkeret", "IMPORTANT": "Vigtig", "UNREAD": "Ulæst",
             "DRAFT": "Kladde", "SENT": "Sendt mail", "TRASH": "Allerede i papirkurven",
             "SPAM": "Spam", "CATEGORY_PERSONAL": "Personlig mail"}
SENSITIVE = re.compile(r"\b(?:faktura|invoice|receipt|kvittering|læge|doctor|tandlæge|dentist|hospital|"
                       r"betaling|payment|booking|reservation|aftale|appointment|bank|skat|password|adgangskode)\b", re.I)


def identifier(value):
    try:
        return str(UUID(str(value)))
    except (TypeError, ValueError, AttributeError):
        raise ApiError(422, "INVALID_INPUT", "Opgavens ID er ugyldigt.")


def search_query(prompt, explicit=""):
    if not isinstance(prompt, str) or not isinstance(explicit, str) or len(prompt) > 1200 or len(explicit) > 240:
        raise ApiError(422, "INVALID_INPUT", "Beskriv en kort, afgrænset oprydning.")
    if explicit.strip():
        value = explicit.strip()
        if any(ord(c) < 32 for c in value):
            raise ApiError(422, "INVALID_INPUT", "Søgningen indeholder ugyldige tegn.")
    else:
        value = "{category:promotions category:social} older_than:1m"
        text = prompt.casefold()
        if any(word in text for word in ("nyhedsbrev", "newsletter", "reklam", "promotion")):
            value = "category:promotions older_than:1m"
        age = re.search(r"\b(\d{1,3})\s*(dage?|days?|uger?|weeks?|måned(?:er)?|months?|år|years?)\b", text)
        if age:
            count = max(1, int(age[1]))
            unit = age[2]
            suffix = "d" if unit.startswith(("dag", "day", "uge", "week")) else "m" if unit.startswith(("mån", "month")) else "y"
            if unit.startswith(("uge", "week")):
                count *= 7
            value = re.sub(r"older_than:1m", f"older_than:{count}{suffix}", value)
    # The outer AND cannot be bypassed by OR operators inside the reviewed query.
    return "in:inbox -in:trash -in:spam -in:sent -in:drafts (" + value + ")"


def protection(mail):
    labels = set(mail["labels"])
    reasons = [description for label, description in PROTECTED.items() if label in labels]
    if "INBOX" not in labels:
        reasons.append("Er ikke længere i indbakken")
    if SENSITIVE.search(mail["subject"]):
        reasons.append("Kan være en vigtig aftale, kvittering eller konto-oplysning")
    return reasons


class GmailCleanup:
    def __init__(self, path, library, provider=None):
        self.path = Path(path)
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self.library = library
        self.provider = provider or (lambda: CleanupGmail(library.require_gmail()))
        self.lock = RLock()
        with closing(sqlite3.connect(self.path)) as db, db:
            db.execute("CREATE TABLE IF NOT EXISTS cleanup (id TEXT PRIMARY KEY, bot TEXT NOT NULL, body TEXT NOT NULL)")

    def save(self, job):
        with closing(sqlite3.connect(self.path)) as db, db:
            db.execute("INSERT OR REPLACE INTO cleanup VALUES (?,?,?)", (job["id"], job["botID"], json.dumps(job)))

    def load(self, key, bot):
        with closing(sqlite3.connect(self.path)) as db:
            row = db.execute("SELECT body FROM cleanup WHERE id=? AND bot=?", (identifier(key), identifier(bot))).fetchone()
        if not row:
            raise ApiError(404, "NOT_FOUND", "Oprydningen blev ikke fundet.")
        return json.loads(row[0])

    @staticmethod
    def public(job):
        value = {key: val for key, val in job.items() if key not in {"account", "approval"}}
        value["counts"] = {state: sum(row["state"] == state for row in job["messages"])
                           for state in ("ready", "protected", "applied", "failed", "uncertain", "skipped", "restored")}
        return value

    def one(self, key, bot):
        with self.lock:
            return self.public(self.load(key, bot))

    def history(self, bot):
        with self.lock, closing(sqlite3.connect(self.path)) as db:
            rows = db.execute("SELECT body FROM cleanup WHERE bot=? ORDER BY rowid DESC LIMIT 20", (identifier(bot),)).fetchall()
            return {"items": [self.public(json.loads(row[0])) for row in rows]}

    def preview(self, bot, body):
        bot, key = identifier(bot), identifier(body.get("id", uuid4()))
        mode = body.get("mode", "archive")
        if mode not in ("archive", "trash"):
            raise ApiError(422, "INVALID_INPUT", "Vælg arkivering eller papirkurv. Permanent sletning findes ikke her.")
        limit = body.get("limit", 12)
        if isinstance(limit, bool) or not isinstance(limit, int) or not 1 <= limit <= 20:
            raise ApiError(422, "INVALID_INPUT", "Vælg højst 20 mails ad gangen.")
        query = search_query(body.get("prompt", ""), body.get("query", ""))
        request_hash = sha256(json.dumps([mode, query, limit]).encode()).hexdigest()
        with self.lock:
            with closing(sqlite3.connect(self.path)) as db:
                previous = db.execute("SELECT body FROM cleanup WHERE id=?", (key,)).fetchone()
            if previous:
                job = json.loads(previous[0])
                if job["botID"] != bot or job["requestHash"] != request_hash:
                    raise ApiError(409, "INVALID_INPUT", "Denne forhåndsvisning hører til en anden søgning.")
                return self.public(job)
            provider = self.provider()
            listed = provider.list(query, limit)
            ids = list(dict.fromkeys(v for v in listed["ids"] if isinstance(v, str) and MESSAGE.fullmatch(v)))[:limit]
            messages = []
            for key_id in ids:
                try:
                    mail = provider.read(key_id)
                    reasons = protection(mail)
                    mail.update(state="protected" if reasons else "ready", reasons=reasons, note="")
                except (ApiError, OSError, ValueError):
                    mail = {"id": key_id, "labels": [], "sender": "Kunne ikke læses", "subject": "Mailen er beskyttet",
                            "state": "protected", "reasons": ["Etiketterne kunne ikke bekræftes"], "note": ""}
                messages.append(mail)
            job = {"id": key, "botID": bot, "revision": 1, "mode": mode, "query": query,
                   "requestHash": request_hash, "account": provider.account, "created": time(),
                   "state": "preview", "messages": messages, "hasMore": bool(listed.get("more")), "selected": [],
                   "receipt": "Ingen mails er ændret. Se listen og vælg dem, agenten må rydde op i."}
            self.save(job)
            return self.public(job)

    def change(self, key, bot, body):
        with self.lock:
            job = self.load(key, bot)
            action = body.get("action")
            if body.get("approved") is not True or action not in ("apply", "undo", "verify"):
                raise ApiError(422, "INVALID_INPUT", "Godkend en konkret handling i forhåndsvisningen først.")
            provider = self.provider()
            if provider.account != job["account"]:
                raise ApiError(409, "NOT_READY", "Gmail-kontoen er skiftet. Opret en ny forhåndsvisning.")
            if action == "apply":
                self.approve(job, body)
            elif not job.get("approval"):
                raise ApiError(409, "NOT_READY", "Der er ingen godkendt oprydning at kontrollere eller fortryde.")
            if action == "undo":
                job["undoRequested"] = True
            if action == "apply" and job.get("undoRequested"):
                raise ApiError(409, "NOT_READY", "Denne oprydning er ved at blive fortrudt. Lav en ny for at arkivere igen.")
            selected = set(job["selected"])
            # Persist before the first remote call; a lost connection cannot lose the approved scope.
            job["revision"] += 1
            self.save(job)
            context = provider.connected() if action != "verify" else nullcontext()
            try:
                with context:
                    for row in job["messages"]:
                        if row["id"] not in selected or row["state"] in ("protected", "skipped", "restored"):
                            continue
                        self.process(job, row, provider, action)
                        self.save(job)
            except (ApiError, OSError, ValueError):
                job["receipt"] = "Gmail-forbindelsen kunne ikke åbnes. Ingen yderligere mails blev ændret. Prøv at kontrollere status."
                job["state"] = "partial"
                self.save(job)
                return self.public(job)
            self.summarize(job)
            self.save(job)
            return self.public(job)

    def approve(self, job, body):
        selected = body.get("selected")
        if not isinstance(selected, list) or not selected or len(selected) > 20 or any(not isinstance(v, str) for v in selected):
            raise ApiError(422, "INVALID_INPUT", "Vælg mindst én mail fra forhåndsvisningen.")
        selected = sorted(set(selected))
        if job.get("approval"):
            if selected != job["selected"]:
                raise ApiError(409, "INVALID_INPUT", "En godkendt liste kan ikke udvides. Lav en ny forhåndsvisning.")
            return
        if body.get("revision") != job["revision"] or time() - job["created"] > 1800:
            raise ApiError(409, "INVALID_INPUT", "Forhåndsvisningen er for gammel. Hent en ny før du godkender.")
        if not set(selected) <= {row["id"] for row in job["messages"] if row["state"] == "ready"}:
            raise ApiError(422, "INVALID_INPUT", "Beskyttede mails kan ikke ændres her.")
        if job["mode"] == "trash" and body.get("confirmTrash") is not True:
            raise ApiError(422, "INVALID_INPUT", "Godkend udtrykkeligt at flytte de valgte mails til papirkurven.")
        job["selected"], job["approval"] = selected, time()

    @staticmethod
    def applied(labels, mode):
        return "INBOX" not in labels and (("TRASH" in labels) == (mode == "trash"))

    def process(self, job, row, provider, action):
        undo = bool(job.get("undoRequested"))
        try:
            mail = provider.read(row["id"])
            labels = set(mail["labels"])
            is_applied = self.applied(labels, job["mode"])
            if undo:
                if row.get("mutationStarted") and "INBOX" in labels and "TRASH" not in labels:
                    row.update(state="restored", note="Tilbage i indbakken · kontrolleret hos Gmail")
                    return
                if not row.get("mutationStarted") or row["state"] == "ready":
                    row.update(state="skipped", note="Blev ikke ændret af denne oprydning")
                    return
                if not is_applied:
                    row.update(state="skipped", note="Flyttet eller ændret siden oprydningen. Bevares som den er.")
                    return
                add, remove = ["INBOX"], ["TRASH"] if job["mode"] == "trash" else []
            else:
                if row.get("mutationStarted") and is_applied:
                    row.update(state="applied", note="I papirkurven · kontrolleret hos Gmail" if job["mode"] == "trash"
                               else "Arkiveret · kontrolleret hos Gmail")
                    return
                if row.get("mutationStarted") and row["state"] == "applied":
                    row.update(state="skipped", note="Flyttet eller ændret efter oprydningen. Ændres ikke igen.")
                    return
                if labels != set(row["labels"]) or protection(mail):
                    row.update(state="skipped", note="Ændret eller blevet vigtig siden forhåndsvisningen. Sprunget over.")
                    return
                add, remove = (["TRASH"] if job["mode"] == "trash" else []), ["INBOX"]
            if action == "verify":
                row.update(state="failed", note="Ændringen er ikke bekræftet. Du kan prøve den godkendte handling igen.")
                return
            row["mutationStarted"] = True
            row["state"] = "uncertain"
            self.save(job)
            permission_note = ""
            try:
                provider.modify(row["id"], add, remove)
            except ApiError as exc:
                if exc.status_code == 403:
                    permission_note = str(exc)
            except (OSError, ValueError):
                pass
            # A successful tool response alone is never counted as a completed change.
            actual = set(provider.read(row["id"])["labels"])
            expected = "INBOX" in actual and "TRASH" not in actual if undo else self.applied(actual, job["mode"])
            if expected:
                row.update(state="restored" if undo else "applied", note="Tilbage i indbakken · kontrolleret hos Gmail" if undo
                           else "I papirkurven · kontrolleret hos Gmail" if job["mode"] == "trash" else "Arkiveret · kontrolleret hos Gmail")
            else:
                row.update(state="failed", note=permission_note or "Gmail viser ikke den ønskede ændring. Prøv igen eller behold mailen.")
        except (ApiError, OSError, ValueError):
            row.update(state="uncertain" if row.get("mutationStarted") else "failed",
                       note="Kunne ikke kontrollere Gmail. Kontrollér status før du prøver igen.")

    @staticmethod
    def summarize(job):
        counts = GmailCleanup.public(job)["counts"]
        changed = counts["restored"] if job.get("undoRequested") else counts["applied"]
        remaining = counts["failed"] + counts["uncertain"]
        job["state"] = "partial" if remaining else "restored" if job.get("undoRequested") else "complete"
        verb = "gendannet i indbakken" if job.get("undoRequested") else "flyttet til papirkurven" if job["mode"] == "trash" else "arkiveret"
        job["receipt"] = f"{changed} mails {verb} og kontrolleret hos Gmail."
        if remaining:
            job["receipt"] += f" {remaining} skal kontrolleres eller prøves igen."
        if counts["skipped"]:
            job["receipt"] += f" {counts['skipped']} blev sprunget over."


def register_gmail_cleanup(app, settings, authorize, library):
    service = GmailCleanup(Path(settings.output_root) / "gmail-cleanup.sqlite", library)

    def paired(request: Request, response: Response):
        authorize(request, settings)
        response.headers["Cache-Control"] = "no-store"

    router = APIRouter(prefix="/api/modules/v1/gmail-cleanup", dependencies=[Depends(paired)], include_in_schema=False)

    @router.get("")
    def history(bot_id: str):
        return service.history(bot_id)

    @router.put("/preview")
    def preview(bot_id: str, body: dict = Body(...)):
        return service.preview(bot_id, body)

    @router.get("/{key}")
    def one(key: str, bot_id: str):
        return service.one(key, bot_id)

    @router.put("/{key}")
    def change(key: str, bot_id: str, body: dict = Body(...)):
        return service.change(key, bot_id, body)

    app.include_router(router)
    return service

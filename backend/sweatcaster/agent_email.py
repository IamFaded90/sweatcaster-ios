"""Give each agent a stable address for requested signups on the paired PC."""

from concurrent.futures import ThreadPoolExecutor
from contextlib import closing
from email.utils import getaddresses
from hashlib import sha256
import re
import sqlite3
from threading import Lock
from unicodedata import normalize
from uuid import UUID

from fastapi import APIRouter, Body, Depends

from sweatcaster.composio_gmail import MESSAGES, MESSAGE_ID, PROFILE
from sweatcaster.composio_library import GMAIL_ADDRESS
from sweatcaster.dto import ApiError
from sweatcaster.mail_appointments import mail_text


def agent_id(value):
    try:
        return str(UUID(value))
    except (ValueError, AttributeError, TypeError) as exc:
        raise ApiError(422, "INVALID_INPUT", "Vælg en gyldig agent.") from exc


def gmail_identity(library):
    data = library.read("gmail", PROFILE)
    address = data.get("emailAddress") if isinstance(data, dict) else None
    if not isinstance(address, str) or len(address) > 254 or not GMAIL_ADDRESS.fullmatch(address):
        raise ApiError(409, "NOT_READY", "Forbind din Gmail på PC’en, så agenten kan modtage mail.")
    return address.lower()


def tagged_address(owner, bot_id, name):
    local, domain = owner.split("@")
    tag = sha256(UUID(bot_id).bytes).hexdigest()[:12]
    budget = min(64, 253 - len(domain)) - len(local) - len(tag) - 1
    if budget < 0 or "+" in local:
        raise ApiError(409, "NOT_READY", "Din Gmail-adresse har ikke plads til en agentadresse.")
    label = re.sub(r"[^a-z0-9]", "", normalize("NFKD", name.lower()))
    prefix = label[:min(16, budget - 1)] + "-" if label and budget >= 2 else ""
    return f"{local}+{prefix}{tag}@{domain}"


def header_values(message):
    payload = message.get("payload")
    headers = payload.get("headers") if isinstance(payload, dict) else None
    values = {}
    for row in headers[:150] if isinstance(headers, list) else []:
        if isinstance(row, dict) and isinstance(row.get("name"), str) and isinstance(row.get("value"), str):
            values.setdefault(row["name"].lower(), []).append(row["value"][:8_000])
    # For You can put parsed envelope fields alongside the Gmail MIME payload.
    for field in ("to", "cc"):
        envelope = message.get(field)
        entries = envelope if isinstance(envelope, list) else [envelope]
        values.setdefault(field, []).extend(entry[:8_000] for entry in entries[:100] if isinstance(entry, str))
    return values


def addressed_to(headers, address):
    recipients = [value for name in ("to", "cc", "bcc", "delivered-to", "x-original-to")
                  for value in headers.get(name, [])]
    return any(email.lower() == address for _, email in getaddresses(recipients))


class AgentEmail:
    def __init__(self, inboxes, library):
        self.inboxes = inboxes
        self.library = library
        self.creating = Lock()

    def database(self):
        self.inboxes.database.parent.mkdir(parents=True, exist_ok=True)
        db = sqlite3.connect(self.inboxes.database, timeout=5)
        db.execute("CREATE TABLE IF NOT EXISTS signup_addresses "
                   "(bot TEXT PRIMARY KEY, address TEXT NOT NULL UNIQUE, kind TEXT NOT NULL, owner TEXT NOT NULL)")
        return db

    def binding(self, bot):
        with closing(self.database()) as db:
            return db.execute("SELECT address, kind, owner FROM signup_addresses WHERE bot=?", (bot,)).fetchone()

    def storage_id(self, bot, gmail):
        existing = self.binding(bot) if gmail else None
        return "gmail:" + bot if existing and existing[1] == "mailbox" else bot

    def create(self, value, name, *, gmail=False):
        bot = agent_id(value)
        if not isinstance(name, str) or not name.isprintable() or not 1 <= len(name.strip()) <= 80:
            raise ApiError(422, "INVALID_INPUT", "Giv agenten et gyldigt navn.")
        with self.creating:
            storage_id = self.storage_id(bot, gmail)
            saved = self.binding(storage_id)
            if saved:
                self.check_account(bot, saved)
                return {"address": saved[0], "kind": saved[1]}
            key = None if gmail else self.inboxes.get_key()
            if key and self.inboxes.account_setup(key).get("verified") is not False:
                inbox = self.inboxes.create(bot, name)
                if not inbox["active"]:
                    raise ApiError(409, "NOT_READY", "Agentens postkasse er ikke aktiv.")
                address, kind, owner = inbox["address"], "mailbox", ""
            else:
                owner = gmail_identity(self.library)
                address, kind = tagged_address(owner, bot, name), "gmailAlias"
            with closing(self.database()) as db, db:
                db.execute("INSERT OR IGNORE INTO signup_addresses VALUES(?,?,?,?)", (storage_id, address, kind, owner))
            saved = self.binding(storage_id)
            if not saved or saved != (address, kind, owner):
                raise ApiError(409, "CONFLICT", "Agentens adresse har ændret sig. Prøv igen.")
            return {"address": address, "kind": kind}

    def check_account(self, bot, binding):
        address, kind, owner = binding
        if kind == "gmailAlias" and gmail_identity(self.library) == owner:
            return
        if kind == "mailbox" and self.inboxes.ready(bot)[1] == address:
            return
        raise ApiError(409, "NOT_READY", "Forbind den mailkonto, som agentens adresse hører til.")

    def mailbox(self, bot, gmail):
        saved = self.binding(self.storage_id(bot, gmail))
        if not saved:
            raise ApiError(404, "NOT_FOUND", "Bed agenten om at oprette sin e-mail først.")
        self.check_account(bot, saved)
        return saved[:2]

    def messages(self, value, *, gmail=False):
        bot = agent_id(value)
        address, kind = self.mailbox(bot, gmail)
        if kind == "mailbox":
            return self.inboxes.messages(bot)
        query = f'{{to:"{address}" deliveredto:"{address}"}} -in:sent -in:drafts'
        consumer = self.library.gmail()
        if consumer:
            rows = consumer.recent(query)
        else:
            listing = self.library.read("gmail", MESSAGES, {"q": query, "maxResults": 8})
            rows = listing.get("messages", []) if isinstance(listing, dict) else None
        if not isinstance(rows, list):
            raise ApiError(502, "NOT_READY", "Gmail kunne ikke læse agentens postkasse.")
        def summary(identifier):
            item = self.library.read("gmail", MESSAGES + "/" + identifier, {"format": "metadata"})
            headers = header_values(item) if isinstance(item, dict) and item.get("id") == identifier else {}
            if not addressed_to(headers, address):
                return None
            return {"id": identifier, "sender": str(headers.get("from", [item.get("sender") or ""])[0])[:300],
                    "subject": str(headers.get("subject", [item.get("subject") or "Uden emne"])[0])[:350],
                    "timestamp": str(headers.get("date", [item.get("internalDate") or ""])[0])[:64]}

        identifiers = [row["id"] for row in rows[:8] if isinstance(row, dict)
                       and isinstance(row.get("id"), str) and MESSAGE_ID.fullmatch(row["id"])]
        with ThreadPoolExecutor(max_workers=3) as pool:
            return {"messages": [item for item in pool.map(summary, identifiers) if item]}

    def message(self, value, identifier, *, gmail=False):
        bot = agent_id(value)
        address, kind = self.mailbox(bot, gmail)
        if kind == "mailbox":
            return self.inboxes.message(bot, identifier)
        item = self.library.read_gmail_message(identifier)
        if not addressed_to(header_values(item), address):
            raise ApiError(404, "NOT_FOUND", "Mailen findes ikke i denne agents postkasse.")
        return {"text": mail_text(item, include_links=True)}


def register_agent_email(app, service, library, paired):
    email = AgentEmail(service, library)
    router = APIRouter(prefix="/api/modules/v1/agent-email", dependencies=[Depends(paired)], include_in_schema=False)

    @router.put("/{bot_id}")
    def create(bot_id: str, body: dict = Body(...), gmail: bool = False):
        return email.create(bot_id, body.get("name"), gmail=gmail)

    @router.get("/{bot_id}/messages")
    def messages(bot_id: str, gmail: bool = False):
        return email.messages(bot_id, gmail=gmail)

    @router.get("/{bot_id}/message")
    def message(bot_id: str, message_id: str, gmail: bool = False):
        return email.message(bot_id, message_id, gmail=gmail)

    app.include_router(router)

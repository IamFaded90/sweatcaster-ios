"""Dedicated, owner-approved AgentMail inboxes on the paired FadedAI PC."""

import json
import os
from contextlib import closing
from pathlib import Path
import re
import sqlite3
from tempfile import NamedTemporaryFile
from threading import Lock
from urllib.parse import quote
from uuid import UUID, uuid4, uuid5

import requests
from fastapi import APIRouter, Body, Depends, Request, Response

from sweatcaster.dto import ApiError
from sweatcaster.emby_settings import _protect

API = "https://api.agentmail.to/v0"
DOMAIN = "agentmail.to"
OWNER_EMAIL = re.compile(r"[^\s@<>]+@[^\s@<>.]+(?:\.[^\s@<>.]+)+")


def key_file():
    return Path(os.environ["LOCALAPPDATA"]) / "FadedAI" / "agentmail.dpapi"


def valid_key(key):
    return bool(key and key.isascii() and len(key) <= 1024 and all(33 <= ord(char) < 127 for char in key))


def read_setup():
    if os.name == "nt":
        try:
            with key_file().open("rb") as stream:
                data = stream.read(32_769)
            if len(data) <= 32_768:
                value = _protect(data, decrypt=True).decode("utf-8")
                if value.startswith("{"):
                    record = json.loads(value)
                    if (isinstance(record, dict) and isinstance(record.get("key"), str)
                            and valid_key(record["key"]) and isinstance(record.get("first_inbox"), str)
                            and type(record.get("verified")) is bool):
                        return record
                elif valid_key(value):
                    return {"key": value}
        except (OSError, KeyError, ValueError):
            pass
    return {}


def read_key():
    value = os.environ.get("AGENTMAIL_API_KEY", "").strip()
    return value if valid_key(value) else read_setup().get("key", "")


def save_key(key):
    if not valid_key(key):
        raise ValueError("Indsæt en gyldig AgentMail-nøgle.")
    stored = read_setup()
    if stored.get("key") == key:
        return
    write_setup(key)


def write_setup(value):
    protected = _protect(value.encode("utf-8"))
    target = key_file()
    target.parent.mkdir(parents=True, exist_ok=True)
    source = None
    try:
        with NamedTemporaryFile(dir=target.parent, delete=False) as stream:
            source = Path(stream.name)
            stream.write(protected)
        source.replace(target)
    finally:
        if source is not None:
            source.unlink(missing_ok=True)


class InboxService:
    def __init__(self, database, get_key=read_key, get_setup=read_setup, persist_setup=write_setup):
        self.database = database
        self.get_key = get_key
        self.get_setup = get_setup
        self.persist_setup = persist_setup
        self.creating = Lock()

    def request(self, key, method, route, *, body=None, params=None):
        headers = {"Accept": "application/json"}
        if key:
            headers["Authorization"] = f"Bearer {key}"
        try:
            with requests.Session() as session:
                session.trust_env = False
                with session.request(method, API + route, headers=headers, json=body, params=params,
                                     timeout=(4, 15), allow_redirects=False, stream=True) as response:
                    code = response.status_code
                    if code == 404:
                        return None
                    if code in {401, 403}:
                        raise ApiError(503, "NOT_READY", "Tjek AgentMail-nøglen og dens adgang på PC’en.")
                    if code in {400, 402, 409, 422, 429}:
                        raise ApiError(409, "NOT_READY", "AgentMail afviste handlingen. Tjek kontoens adgang og postkassegrænse.")
                    if not 200 <= code < 300:
                        raise ValueError("Unexpected upstream status.")
                    chunks = bytearray()
                    for chunk in response.iter_content(65536):
                        chunks.extend(chunk)
                        if len(chunks) > 1_100_000:
                            raise ValueError("AgentMail response is too large.")
            data = json.loads(chunks)
            if isinstance(data, dict):
                return data
        except (requests.RequestException, ValueError, RecursionError) as exc:
            raise ApiError(502, "NOT_READY", "AgentMail svarede ikke. Opdatér postkassen, før du prøver igen.") from exc
        raise ApiError(502, "NOT_READY", "AgentMail gav et uventet svar.")

    def identity(self, bot_id):
        try:
            uid = UUID(bot_id)
        except (ValueError, TypeError, AttributeError) as exc:
            raise ApiError(422, "INVALID_INPUT", "Vælg en gyldig agent.") from exc
        self.database.parent.mkdir(parents=True, exist_ok=True)
        with closing(sqlite3.connect(self.database, timeout=5)) as db, db:
            db.execute("CREATE TABLE IF NOT EXISTS identity (id INTEGER PRIMARY KEY CHECK(id=1), ns TEXT NOT NULL)")
            db.execute("INSERT OR IGNORE INTO identity(id,ns) VALUES(1,?)", (uuid4().hex,))
            saved = UUID(db.execute("SELECT ns FROM identity WHERE id=1").fetchone()[0])
        client_id = uuid5(saved, uid.hex).hex
        username = "faded-" + client_id[:24]
        return username, f"{username}@{DOMAIN}", client_id

    def account_setup(self, key):
        record = self.get_setup()
        return record if record.get("key") == key else {}

    def verified(self, key, data, address, client_id):
        signup = self.account_setup(key)
        registered = signup.get("first_inbox") == address and signup.get("verified") is True
        if (not data or data.get("inbox_id") != address
                or (data.get("client_id") != client_id and not (registered and not data.get("client_id")))):
            raise ApiError(409, "NOT_READY", "Postkassen matcher ikke denne agent.")
        return {"configured": True, "address": address, "active": data.get("status") != "deactivated"}

    def status(self, bot_id):
        key = self.get_key()
        if not key:
            return {"configured": False, "address": None, "active": False}
        return self._status(key, bot_id)

    def _status(self, key, bot_id):
        _, address, client_id = self.identity(bot_id)
        setup = self.account_setup(key)
        if setup.get("verified") is False:
            first = setup.get("verify_at", setup.get("first_inbox")) == address
            return {"configured": False, "address": None, "active": False,
                    "verificationRequired": first, "verificationElsewhere": not first}
        item = self.request(key, "GET", "/inboxes/" + quote(address, safe=""))
        if item is None:
            return {"configured": True, "address": None, "active": False}
        return self.verified(key, item, address, client_id)

    def enroll(self, bot_id, email):
        if not isinstance(email, str) or len(email) > 254 or not OWNER_EMAIL.fullmatch(email):
            raise ApiError(422, "INVALID_INPUT", "Indtast din e-mailadresse til engangskoden.")
        username, address, _ = self.identity(bot_id)
        with self.creating:
            if self.get_key():
                return self.status(bot_id)
            data = self.request("", "POST", "/agent/sign-up", body={
                "username": username, "human_email": email, "source": "FadedAI",
            }) or {}
            key = data.get("api_key")
            if not isinstance(key, str) or not valid_key(key):
                raise ApiError(502, "NOT_READY", "AgentMail gav ingen nøgle til opsætningen.")
            same_address = data.get("inbox_id") == address
            self.save_signup({"key": key, "first_inbox": address if same_address else "",
                              "verify_at": address, "owner_email": email, "verified": False})
            return self._status(key, bot_id)

    def verification_setup(self, bot_id):
        _, address, _ = self.identity(bot_id)
        key = self.get_key()
        setup = self.account_setup(key)
        if not key or setup.get("verify_at") != address:
            raise ApiError(409, "NOT_READY", "Start bekræftelsen på den agent, du oprettede kontoen fra.")
        return key, setup

    def confirm(self, bot_id, code):
        if not isinstance(code, str) or not re.fullmatch(r"[0-9]{6}", code):
            raise ApiError(422, "INVALID_INPUT", "Indtast de seks cifre fra mailen.")
        with self.creating:
            key, setup = self.verification_setup(bot_id)
            if setup.get("verified") is False:
                data = self.request(key, "POST", "/agent/verify", body={"otp_code": code}) or {}
                if data.get("verified") is not True:
                    raise ApiError(409, "NOT_READY", "AgentMail kunne ikke bekræfte engangskoden.")
                self.save_signup({"key": key, "first_inbox": setup["first_inbox"],
                                  "verify_at": setup["verify_at"], "verified": True})
            return self._status(key, bot_id)

    def resend(self, bot_id):
        with self.creating:
            key, setup = self.verification_setup(bot_id)
            if setup.get("verified") is False:
                email = setup.get("owner_email")
                if not isinstance(email, str) or not OWNER_EMAIL.fullmatch(email):
                    raise ApiError(409, "NOT_READY", "E-mailen til engangskoden mangler.")
                data = self.request(key, "POST", "/agent/human", body={"human_email": email})
                if not data:
                    raise ApiError(502, "NOT_READY", "AgentMail kunne ikke hente en engangskode.")
            return self._status(key, bot_id)

    def save_signup(self, setup):
        try:
            self.persist_setup(json.dumps(setup))
        except (OSError, KeyError, ValueError) as exc:
            raise ApiError(503, "NOT_READY", "Windows kunne ikke gemme AgentMail-opsætningen.") from exc

    def create(self, bot_id, name):
        if not isinstance(name, str) or not 1 <= len(name.strip()) <= 80 or not name.isprintable():
            raise ApiError(422, "INVALID_INPUT", "Giv agenten et gyldigt navn.")
        key = self.get_key()
        if not key:
            raise ApiError(503, "NOT_READY", "Sæt AgentMail op på PC’en først.")
        username, address, client_id = self.identity(bot_id)
        route = "/inboxes/" + quote(address, safe="")
        with self.creating:
            if self.account_setup(key).get("verified") is False:
                raise ApiError(409, "NOT_READY", "Bekræft først AgentMail med engangskoden fra din mail.")
            item = self.request(key, "GET", route)
            if item is None:
                try:
                    item = self.request(key, "POST", "/inboxes", body={
                        "username": username, "domain": DOMAIN, "display_name": name.strip(),
                        "client_id": client_id,
                    })
                except ApiError as error:
                    # An ambiguous response can still mean the inbox was created.
                    if error.status_code not in {409, 502}:
                        raise
                    try:
                        item = self.request(key, "GET", route)
                    except ApiError:
                        raise error from None
                    if item is None:
                        raise
            return self.verified(key, item, address, client_id)

    def ready(self, bot_id):
        key = self.get_key()
        if not key:
            raise ApiError(503, "NOT_READY", "Sæt AgentMail op på PC’en først.")
        state = self._status(key, bot_id)
        if not state["active"]:
            raise ApiError(409, "NOT_READY", "Agentens postkasse er ikke aktiv.")
        return key, state["address"]

    @staticmethod
    def message_id(value):
        if (isinstance(value, str) and value.isascii() and 1 <= len(value) <= 400
                and value.isprintable() and not any(char in value for char in "/\\%")
                and value.strip() == value and value not in {".", ".."}):
            return value
        return None

    @staticmethod
    def text(value, key, maximum_bytes):
        if not isinstance(value, str):
            return ""
        return value.replace(key, "[skjult]").encode("utf-8", errors="replace")[:maximum_bytes].decode("utf-8", errors="ignore")

    def messages(self, bot_id):
        key, address = self.ready(bot_id)
        payload = self.request(key, "GET", "/inboxes/" + quote(address, safe="") + "/messages", params={"limit": 25})
        rows = payload.get("messages") if payload else None
        if not isinstance(rows, list):
            raise ApiError(502, "NOT_READY", "Postkassen kunne ikke læses.")
        return {"messages": [
            {"id": item["message_id"], "sender": self.text(item.get("from"), key, 240),
             "subject": self.text(item.get("subject"), key, 300),
             "timestamp": self.text(item.get("timestamp"), key, 56)}
            for item in rows[:25] if isinstance(item, dict) and item.get("inbox_id") == address
            and self.message_id(item.get("message_id"))
        ]}

    def message(self, bot_id, message_id):
        if self.message_id(message_id) is None:
            raise ApiError(422, "INVALID_INPUT", "Vælg en mail fra postkassen.")
        key, address = self.ready(bot_id)
        path = f"/inboxes/{quote(address, safe='')}/messages/{quote(message_id, safe='')}"
        item = self.request(key, "GET", path)
        if not item or item.get("inbox_id") != address or item.get("message_id") != message_id:
            raise ApiError(404, "NOT_FOUND", "Mailen findes ikke i denne postkasse.")
        return {"text": self.text(item.get("text") or item.get("extracted_text") or item.get("preview"), key, 7_000)}


def register_agentmail(app, settings, authorize):
    service = InboxService(settings.output_root / "agentmail.sqlite3")

    def paired(request: Request, response: Response):
        authorize(request, settings)
        response.headers["Cache-Control"] = "no-store"

    router = APIRouter(prefix="/api/modules/v1/agentmail", dependencies=[Depends(paired)], include_in_schema=False)

    @router.get("/{bot_id}")
    def status(bot_id: str):
        return service.status(bot_id)

    @router.put("/{bot_id}")
    def create(bot_id: str, body: dict = Body(...)):
        return service.create(bot_id, body.get("name"))

    @router.put("/{bot_id}/enroll")
    def enroll(bot_id: str, body: dict = Body(...)):
        return service.enroll(bot_id, body.get("email"))

    @router.put("/{bot_id}/verify")
    def verify(bot_id: str, body: dict = Body(...)):
        return service.confirm(bot_id, body.get("code"))

    @router.put("/{bot_id}/resend")
    def resend(bot_id: str):
        return service.resend(bot_id)

    @router.get("/{bot_id}/messages")
    def messages(bot_id: str):
        return service.messages(bot_id)

    @router.get("/{bot_id}/message")
    def message(bot_id: str, message_id: str):
        return service.message(bot_id, message_id)

    app.include_router(router)

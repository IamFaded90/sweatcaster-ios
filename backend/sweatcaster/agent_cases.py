"""Durable, user-reviewed complaint cases with real, account-bound Gmail follow-up."""

import base64
from contextlib import closing
from hashlib import sha256
import json
from pathlib import Path
import sqlite3
from threading import Event, RLock, Thread
from time import time
from uuid import uuid4

from fastapi import APIRouter, Body, Depends, Request, Response

from sweatcaster.dto import ApiError
from sweatcaster import agent_case_models as model
from sweatcaster.agent_case_gmail import CaseGmail, GmailRejected


class AgentCases:
    def __init__(self, root, library, provider=None):
        self.path = Path(root) / "agent-cases.sqlite3"
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self.library, self.provider = library, provider or (lambda: CaseGmail(library))
        self.lock, self.stopped, self.thread = RLock(), Event(), None
        with closing(self.db()) as db, db:
            db.execute("CREATE TABLE IF NOT EXISTS cases (id TEXT PRIMARY KEY, bot TEXT NOT NULL, body TEXT NOT NULL)")
            db.execute("CREATE TABLE IF NOT EXISTS photos (id TEXT PRIMARY KEY, owner TEXT NOT NULL, body BLOB NOT NULL)")
            db.execute("CREATE TABLE IF NOT EXISTS removed (id TEXT PRIMARY KEY)")

    def db(self):
        return sqlite3.connect(self.path)

    def save(self, case, db=None):
        case["updated"] = time()
        if db is not None:
            db.execute("INSERT OR REPLACE INTO cases VALUES (?,?,?)", (case["id"], case["botID"], json.dumps(case)))
            return
        with closing(self.db()) as db, db:
            self.save(case, db)

    def load(self, bot, key):
        with closing(self.db()) as db:
            row = db.execute("SELECT body FROM cases WHERE id=? AND bot=?", (model.identifier(key), model.identifier(bot))).fetchone()
        if not row:
            raise ApiError(404, "NOT_FOUND", "Sagen findes ikke længere.")
        return json.loads(row[0])

    @staticmethod
    def public(case):
        return {key: value for key, value in case.items() if key not in {"account", "createHash"}}

    def one(self, bot, key):
        with self.lock:
            return self.public(self.load(bot, key))

    def list(self, bot):
        with self.lock, closing(self.db()) as db:
            rows = db.execute("SELECT body FROM cases WHERE bot=? ORDER BY json_extract(body,'$.updated') DESC LIMIT 50",
                              (model.identifier(bot),)).fetchall()
        return {"cases": [self.public(json.loads(row[0])) for row in rows]}

    def bound(self, case):
        provider = self.provider()
        if case.get("account") not in (None, provider.account):
            raise ApiError(409, "NOT_READY", "Denne sag hører til en anden Gmail-konto. Forbind den oprindelige konto igen.")
        case["account"], case["gmailEmail"] = provider.account, provider.email
        return provider

    def create(self, bot, key, body):
        values = model.fields(body)
        bot, key = model.identifier(bot), model.identifier(key)
        digest = sha256(json.dumps(values, sort_keys=True).encode()).hexdigest()
        with closing(self.db()) as db:
            if db.execute("SELECT 1 FROM removed WHERE id=?", (key,)).fetchone():
                raise ApiError(409, "REQUEST_REUSED", "Sagen er fjernet. Opret en ny sag med et nyt ID.")
            row = db.execute("SELECT body FROM cases WHERE id=?", (key,)).fetchone()
        if row:
            old = json.loads(row[0])
            if old["botID"] != bot or old["createHash"] != digest:
                raise ApiError(409, "REQUEST_REUSED", "Dette sags-ID er allerede brugt.")
            return self.public(old)
        case = {"id": key, "botID": bot, **values, "createHash": digest, "revision": 1, "state": "draft",
                "created": time(), "updated": time(), "photos": [], "events": [], "receipt": None,
                "candidates": [], "draft": None, "outgoing": None, "account": None, "gmailEmail": "",
                "incoming": [], "watch": True, "lastChecked": None, "nextCheck": 0,
                "note": "Sagen er gemt. Find dokumentation og gennemse mailen, før du vælger Send."}
        model.event(case, "created", "Sag oprettet. Intet er sendt.")
        self.save(case)
        return self.public(case)

    def mutate(self, bot, key, body):
        with self.lock:
            action = body.get("action")
            if action == "create":
                return self.create(bot, key, body)
            case = self.load(bot, key)
            if action == "refresh":
                return self.refresh(case)
            if action == "send" and case.get("outgoing"):
                # Even after an HTTP timeout, a second Send only reconciles the first delivery.
                if body.get("approved") is not True or body.get("draftDigest") != case["outgoing"]["digest"]:
                    raise ApiError(409, "REQUEST_REUSED", "Åbn den sendte mail i sagen. Der bliver ikke sendt en kopi.")
                return self.refresh(case)
            if case["state"] == "closed" and action not in ("reopen", "remove", "note", "watch"):
                raise ApiError(409, "NOT_READY", "Genåbn sagen, før du arbejder videre med den.")
            if body.get("revision") != case["revision"]:
                raise ApiError(409, "REQUEST_REUSED", "Sagen er ændret. Opdatér den, før du fortsætter.")
            if action in ("edit", "selectReceipt", "searchReceipt", "draft", "removePhoto") and case.get("outgoing"):
                raise ApiError(409, "NOT_READY", "Den afsendte dokumentation bevares. Skriv nye oplysninger som en note i sagen.")
            if action == "edit":
                case.update(model.fields(body))
                case["draft"] = None
                model.event(case, "edited", "Dine oplysninger er opdateret. Intet er sendt.")
            elif action == "searchReceipt":
                query = model.text(body.get("query", '{kvittering faktura receipt invoice "order confirmation"}'), 160)
                provider = self.bound(case)
                rows = provider.receipts(query)
                case["candidates"] = [row for row in rows[:12] if isinstance(row, dict)
                                      and isinstance(row.get("id"), str) and model.MAIL_ID.fullmatch(row["id"])]
                case["note"] = "Vælg selv den mail, der dokumenterer købet. En søgetræffer er endnu ikke knyttet til sagen."
            elif action == "selectReceipt":
                key_id = body.get("messageID")
                if key_id not in {v["id"] for v in case["candidates"]}:
                    raise ApiError(422, "INVALID_INPUT", "Vælg en kvitteringsmail fra sagens søgeresultater.")
                case["receipt"] = self.bound(case).receipt(key_id)
                case["draft"] = None
                model.event(case, "receipt", "Du har valgt kvitteringsmailen “" + case["receipt"]["subject"] + "”.")
            elif action == "draft":
                self.bound(case)
                case["draft"] = model.reviewed(body, case) if "body" in body else model.draft(case, body.get("recipient", ""))
                case["note"] = "Kladde klar. Tjek modtager, tekst og de fotos, der sendes med. Intet er sendt."
                model.event(case, "draft", "Mailforslaget bruger dine oplysninger og den kvittering, du har valgt.")
            elif action == "send":
                return self.send(case, body)
            elif action == "removePhoto":
                photo_id = model.identifier(body.get("photoID"))
                case["photos"] = [p for p in case["photos"] if p["id"] != photo_id]
                case["draft"] = model.reviewed(case["draft"], case, require_address=False) if case["draft"] else None
                with closing(self.db()) as db, db:
                    db.execute("DELETE FROM photos WHERE id=? AND owner=?", (photo_id, case["id"]))
                    case["revision"] += 1
                    self.save(case, db)
                return self.public(case)
            elif action == "watch":
                if not isinstance(body.get("enabled"), bool):
                    raise ApiError(422, "INVALID_INPUT", "Vælg om agenten må holde øje med svar i denne sag.")
                case["watch"] = body["enabled"] and case["state"] != "closed"
            elif action == "note":
                model.event(case, "note", model.text(body.get("text"), 3000))
            elif action == "close":
                if body.get("approved") is not True:
                    raise ApiError(422, "INVALID_INPUT", "Det er dig, der vælger, hvornår sagen er løst.")
                reason = model.text(body.get("reason"), 1000)
                case.update(state="closed", watch=False, note="Du har afsluttet sagen: " + reason)
                model.event(case, "closed", case["note"])
            elif action == "reopen":
                if case["state"] != "closed":
                    raise ApiError(409, "NOT_READY", "Sagen er allerede åben.")
                case["state"] = "reply" if case["incoming"] else "waiting" if (case.get("outgoing") or {}).get("verified") else "uncertain" if case.get("outgoing") else "draft"
                case["note"] = "Sagen er åbnet igen. Vælg Hold øje med svar, hvis agenten skal følge den."
                model.event(case, "reopened", "Du har genåbnet sagen.")
            elif action == "remove":
                if body.get("approved") is not True:
                    raise ApiError(422, "INVALID_INPUT", "Godkend at fjerne sagen og dens lokale fotos.")
                with closing(self.db()) as db, db:
                    db.execute("DELETE FROM photos WHERE owner=?", (case["id"],))
                    db.execute("DELETE FROM cases WHERE id=?", (case["id"],))
                    db.execute("INSERT OR IGNORE INTO removed VALUES (?)", (case["id"],))
                return {"removed": True}
            else:
                raise ApiError(422, "INVALID_INPUT", "Vælg en handling på sagen.")
            case["revision"] += 1
            self.save(case)
            return self.public(case)

    def add_photo(self, bot, key, body):
        with self.lock:
            case = self.load(bot, key)
            data, photo_id = model.photo(body.get("data")), model.identifier(body.get("id"))
            digest = sha256(data).hexdigest()
            previous = next((p for p in case["photos"] if p["id"] == photo_id), None)
            if previous:
                if previous["sha256"] != digest:
                    raise ApiError(409, "REQUEST_REUSED", "Dette foto-ID er allerede brugt.")
                return self.public(case)
            if case["state"] == "closed" or case.get("outgoing") or body.get("revision") != case["revision"]:
                raise ApiError(409, "NOT_READY", "Opdatér sagen. Der kan ikke tilføjes fotos til en mail, der er afsendt.")
            if len(case["photos"]) >= 4:
                raise ApiError(422, "INVALID_INPUT", "Brug højst fire fotos i én reklamation.")
            descriptor = {"id": photo_id, "name": "foto-" + photo_id[:8] + ".jpg", "bytes": len(data), "sha256": digest}
            case["photos"].append(descriptor)
            case["draft"] = model.reviewed(case["draft"], case, require_address=False) if case["draft"] else None
            case["revision"] += 1
            model.event(case, "photo", "Foto tilføjet: " + descriptor["name"] + ". Det vedhæftes, hvis du sender kladden.")
            with closing(self.db()) as db, db:
                db.execute("INSERT INTO photos VALUES (?,?,?)", (photo_id, case["id"], data))
                self.save(case, db)
            return self.public(case)

    def photo(self, bot, key, photo_id):
        case = self.load(bot, key)
        with closing(self.db()) as db:
            row = db.execute("SELECT body FROM photos WHERE id=? AND owner=?", (model.identifier(photo_id), case["id"])).fetchone()
        if not row:
            raise ApiError(404, "NOT_FOUND", "Fotoet er fjernet fra sagen.")
        return {"data": base64.b64encode(row[0]).decode()}

    def send(self, case, body):
        draft = case.get("draft")
        if not draft or body.get("approved") is not True or body.get("draftDigest") != draft["digest"]:
            raise ApiError(422, "INVALID_INPUT", "Gennemse og godkend den præcise mail og dens fotos først.")
        checked = model.reviewed(draft, case)
        provider = self.bound(case)
        if checked["digest"] != draft["digest"] or draft.get("sender") != provider.email:
            raise ApiError(409, "NOT_READY", "Mailen eller afsenderen er ændret. Gennemse en ny kladde før Send.")
        photos = []
        with closing(self.db()) as db:
            for descriptor in draft["photos"]:
                row = db.execute("SELECT body FROM photos WHERE id=? AND owner=?", (descriptor["id"], case["id"])).fetchone()
                if not row or sha256(row[0]).hexdigest() != descriptor["sha256"]:
                    raise ApiError(409, "NOT_READY", "Et vedhæftet foto kunne ikke bekræftes. Gennemse dokumentationen igen.")
                photos.append((descriptor, row[0]))
        delivery = str(uuid4())
        outgoing = {**draft, "id": delivery, "rfcID": "<fadedai.case." + delivery + "@fadedai.invalid>",
                    "approvedAt": time(), "verified": False, "messageID": None, "threadID": None}
        case.update(outgoing=outgoing, state="sending", note="Du har godkendt afsendelsen. Gmail bliver kontrolleret, før den markeres som sendt.")
        case["revision"] += 1
        model.event(case, "approved", "Du godkendte mailen til " + outgoing["recipient"] + " med " + str(len(photos)) + " fotos.")
        self.save(case)
        try:
            result = provider.send(outgoing, photos)
            key_id = result.get("id") or result.get("messageId")
            if isinstance(key_id, str) and model.MAIL_ID.fullmatch(key_id):
                outgoing["messageID"] = key_id
            self.save(case)
        except GmailRejected as exc:
            case.update(outgoing=None, state="draft", note=str(exc) + " Intet er sendt. Du skal gennemse og godkende igen før et nyt forsøg.")
            case["revision"] += 1
            model.event(case, "rejected", "Gmail afviste afsendelsen, før mailen blev accepteret. Intet er sendt.")
            self.save(case)
            return self.public(case)
        except (ApiError, OSError, ValueError, AttributeError):
            pass
        return self.refresh(case, provider)

    def refresh(self, case, provider=None):
        if case["state"] == "closed" or not case.get("outgoing"):
            return self.public(case)
        try:
            provider = provider or self.bound(case)
            outgoing = case["outgoing"]
            if not outgoing["verified"]:
                candidates = [outgoing["messageID"]] if outgoing.get("messageID") else []
                verified = [v for key in candidates if (v := provider.verify(key, outgoing))]
                if not verified:
                    keys = provider.find_sent(outgoing)
                    verified = [v for key in keys[:3] if (v := provider.verify(key, outgoing))]
                if len(verified) != 1:
                    case.update(state="uncertain", note="Afsendelsen er ikke sikkert bekræftet. Intet gensendes. Tjek Sendt i Gmail, og brug Tjek status igen.")
                else:
                    outgoing.update(verified[0], verified=True, verifiedAt=time())
                    case.update(state="waiting", note="Mailen, modtageren og alle fotos er genlæst i Sendt hos Gmail. Vi venter på svar.")
                    model.event(case, "sent", "Gmail har bekræftet mailen til " + outgoing["recipient"] + " og dens vedhæftninger.")
                    # Persist the verified send even if a later follow-up lookup fails.
                    self.save(case)
            if outgoing["verified"]:
                result = provider.followup(outgoing["threadID"], outgoing["messageID"])
                existing = {v["id"] for v in case["incoming"]}
                for row in result.get("messages", []):
                    if row["id"] not in existing:
                        case["incoming"].append(row)
                        model.event(case, "incoming", "Nyt svar i sagens Gmail-tråd fra " + row["sender"] + ".")
                        existing.add(row["id"])
                case["incoming"] = case["incoming"][-30:]
                if result.get("state") == "received":
                    case.update(state="reply", note="Der er svar i den rigtige Gmail-tråd. Læs svaret og vælg selv næste skridt.")
                elif result.get("state") == "unknown":
                    case["note"] = "Mailen er sendt, men hele trådens nye svar kunne ikke bekræftes. Prøv Tjek status igen."
        except (ApiError, OSError, ValueError, AttributeError, KeyError) as exc:
            case["note"] = str(exc) if isinstance(exc, ApiError) else "Gmail kunne ikke kontrolleres. Intet bliver gensendt."
            if not case["outgoing"].get("verified"):
                case["state"] = "uncertain"
        case["lastChecked"], case["nextCheck"] = time(), time() + 300
        case["revision"] += 1
        self.save(case)
        return self.public(case)

    def tick(self):
        with self.lock, closing(self.db()) as db:
            row = db.execute("SELECT body FROM cases WHERE json_extract(body,'$.watch')=1 "
                             "AND json_extract(body,'$.state') IN ('waiting','reply','sending','uncertain') "
                             "AND json_extract(body,'$.nextCheck')<? ORDER BY json_extract(body,'$.nextCheck') LIMIT 1", (time(),)).fetchone()
            if row and not self.stopped.is_set():
                self.refresh(json.loads(row[0]))

    def start(self):
        if self.thread and self.thread.is_alive():
            return
        self.stopped.clear()
        def work():
            while not self.stopped.wait(60):
                try:
                    self.tick()
                except (ApiError, OSError, ValueError, sqlite3.Error):
                    pass
        self.thread = Thread(target=work, name="FadedAI-cases", daemon=True)
        self.thread.start()

    def stop(self):
        self.stopped.set()
        if self.thread:
            self.thread.join(timeout=2)


def register_agent_cases(app, settings, authorize, library):
    service = AgentCases(settings.output_root, library)
    def paired(request: Request, response: Response):
        authorize(request, settings)
        response.headers["Cache-Control"] = "no-store"
    router = APIRouter(prefix="/api/modules/v1/agent-cases", dependencies=[Depends(paired)], include_in_schema=False)

    @router.get("")
    def cases(bot_id: str):
        return service.list(bot_id)

    @router.get("/{case_id}")
    def one(case_id: str, bot_id: str):
        return service.one(bot_id, case_id)

    @router.put("/{case_id}")
    def mutate(case_id: str, bot_id: str, body: dict = Body(...)):
        return service.mutate(bot_id, case_id, body)

    @router.put("/{case_id}/photos")
    def add_photo(case_id: str, bot_id: str, body: dict = Body(...)):
        return service.add_photo(bot_id, case_id, body)

    @router.get("/{case_id}/photos/{photo_id}")
    def photo(case_id: str, photo_id: str, bot_id: str):
        return service.photo(bot_id, case_id, photo_id)

    app.include_router(router)
    return service

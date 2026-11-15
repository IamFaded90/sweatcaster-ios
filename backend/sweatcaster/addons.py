"""Approved descriptions of native FadedAI screens and actions."""

import json
import sqlite3
from contextlib import closing
from urllib.parse import urlsplit
from uuid import UUID, uuid4

import requests
from fastapi import APIRouter, Body, Depends, Request, Response

from sweatcaster.bot_computers import BotComputerError, ModelBusy
from sweatcaster.dto import ApiError
from sweatcaster.github_addons import pack_web_files, proposal, source_identity, source_info

TOOLS = frozenset(("checklist", "stats", "sum", "average", "percent", "discount", "split", "days"))
LIMIT = 40
WEB_STORAGE_LIMIT = 64_000_000
INSTRUCTIONS = (
    "You are Code Bot. Prepare a FadedAI extension in the user's language. Return only JSON with "
    'title (short), text (helpful page content), actions (array, up to six). A tool action example is '
    '{"type":"tool","label":"Åbn tjekliste","value":"checklist"}. Other allowed tool values: '
    + ", ".join(sorted(TOOLS)) + ". A prompt action has type prompt and a short editable AI request as value. "
    "A link action has type link and a specific HTTPS URL supplied in the request. Use no code or HTML. "
    "Never invent links. Keep the result concise. Include a button when the user asks for a tool."
)


def identifier(raw):
    try:
        value = str(UUID(raw))
        if not isinstance(raw, str) or value != raw.lower():
            raise ValueError
        return value
    except (ValueError, TypeError, AttributeError):
        raise ApiError(422, "INVALID_INPUT", "Tilføjelsen har et ugyldigt id.") from None


def clean_text(value, maximum):
    if not isinstance(value, str) or "\x00" in value or not 1 <= len(value.strip()) <= maximum:
        raise ValueError
    return value.strip()


def valid_link(value):
    try:
        parts = urlsplit(value)
        return (parts.scheme == "https" and parts.hostname is not None and "." in parts.hostname
                and not parts.username and not parts.password and "@" not in parts.netloc
                and "\\" not in value and not any(char.isspace() for char in value)
                and (parts.port is None or parts.port == 443))
    except ValueError:
        return False


def validate(body):
    try:
        required = {"id", "title", "text", "actions"}
        if set(body) not in (required, required | {"source"}):
            raise ValueError
        addon = {"id": identifier(body["id"]), "title": clean_text(body["title"], 48),
                 "text": clean_text(body["text"], 4_000), "actions": []}
        actions = body["actions"]
        if not isinstance(actions, list) or len(actions) > 6:
            raise ValueError
        source = source_info(body["source"]) if "source" in body else None
        if source:
            if addon["id"] != source_identity(source):
                raise ValueError
            addon["source"] = source
        for action in actions:
            if not isinstance(action, dict) or set(action) != {"type", "label", "value"}:
                raise ValueError
            kind = action["type"]
            value = clean_text(action["value"], 1_000)
            label = clean_text(action["label"], 48)
            if kind == "tool":
                if value not in TOOLS:
                    raise ValueError
            elif kind == "link":
                if not valid_link(value):
                    raise ValueError
            elif kind == "webApp":
                if source is None or source["kind"] != "static" or value != "index.html":
                    raise ValueError
            elif kind != "prompt":
                raise ValueError
            addon["actions"].append({"type": kind, "label": label, "value": value})
        if source and source["kind"] == "static" and (len(actions) != 1 or addon["actions"][0]["type"] != "webApp"):
            raise ValueError
        return addon
    except (ValueError, KeyError, TypeError):
        raise ApiError(422, "INVALID_INPUT", "Brug korte skærmtekster og kendte handlinger til tilføjelsen.") from None


def register_addons(app, settings, authorize, generate):
    database = settings.output_root / "addons.sqlite3"

    def paired(request: Request, response: Response):
        authorize(request, settings)
        response.headers["Cache-Control"] = "no-store"

    def connect():
        db = sqlite3.connect(database)
        try:
            db.executescript("""
                CREATE TABLE IF NOT EXISTS addons (id TEXT PRIMARY KEY, body TEXT NOT NULL);
                CREATE TABLE IF NOT EXISTS addon_web_files (id TEXT PRIMARY KEY, body BLOB NOT NULL);
            """)
        except Exception:
            db.close()
            raise
        return db

    router = APIRouter(prefix="/api/modules/v1/addons", dependencies=[Depends(paired)], include_in_schema=False)

    @router.get("")
    def library():
        with closing(connect()) as db:
            return {"items": [json.loads(body) for (body,) in db.execute(
                "SELECT body FROM addons ORDER BY rowid DESC LIMIT ?", (LIMIT,))]}

    @router.put("/draft")
    def draft(body: dict = Body(...)):
        try:
            brief = clean_text(body.get("brief"), 800)
        except ValueError:
            raise ApiError(422, "INVALID_INPUT", "Beskriv tilføjelsen med højst 800 tegn.") from None
        try:
            data = json.loads(generate(brief, None))
            if not isinstance(data, dict):
                raise ValueError
            addon = validate({**data, "id": str(uuid4())})
            if any(action["type"] == "link" and action["value"] not in brief for action in addon["actions"]):
                raise ValueError
            return addon
        except ModelBusy as error:
            raise ApiError(503, "NOT_READY", "PC-modellen er optaget. Prøv igen om lidt.") from error
        except requests.RequestException as error:
            raise ApiError(503, "NOT_READY", "PC-modellen svarer ikke. Tjek Ollama på PC’en.") from error
        except (ApiError, BotComputerError, KeyError, TypeError, ValueError, RecursionError) as error:
            raise ApiError(502, "NOT_READY", "Code Bot gav ikke en gyldig tilføjelse. Prøv en kortere beskrivelse.") from error

    @router.put("/github")
    def github(body: dict = Body(...)):
        local = body.get("local", False)
        if type(local) is not bool:
            raise ApiError(422, "INVALID_INPUT", "Vælg, om du vil hente en lokal webpakke.")
        return validate(proposal(body.get("url"), prefer_local=local))

    @router.get("/{addon_id}/files")
    def web_files(addon_id: str):
        with closing(connect()) as db:
            row = db.execute("SELECT body FROM addon_web_files WHERE id=?", (identifier(addon_id),)).fetchone()
            if row is None:
                raise ApiError(404, "NOT_FOUND", "Webpakken er ikke længere installeret.")
            return Response(row[0], media_type="application/json", headers={"Cache-Control": "no-store"})

    @router.put("")
    def install(body: dict = Body(...)):
        addon = validate(body)
        encoded = json.dumps(addon, ensure_ascii=False)
        source = addon.get("source")
        bundle = None
        if source and source["kind"] == "static":
            with closing(connect()) as db:
                row = db.execute("SELECT body FROM addons WHERE id=?", (addon["id"],)).fetchone()
            if row and row[0] == encoded:
                return addon
            if row:
                raise ApiError(409, "NOT_READY", "Dette forslag er allerede gemt i en anden version.")
            bundle = json.dumps(pack_web_files(source), separators=(",", ":")).encode("utf-8")
        with closing(connect()) as db, db:
            db.execute("BEGIN IMMEDIATE")
            row = db.execute("SELECT body FROM addons WHERE id=?", (addon["id"],)).fetchone()
            if row:
                if row[0] != encoded:
                    raise ApiError(409, "NOT_READY", "Dette forslag er allerede gemt i en anden version.")
                return addon
            if db.execute("SELECT COUNT(*) FROM addons").fetchone()[0] >= LIMIT:
                raise ApiError(409, "NOT_READY", "Fjern en gammel tilføjelse, før du installerer en ny.")
            if bundle is not None:
                used = db.execute("SELECT COALESCE(SUM(length(body)), 0) FROM addon_web_files").fetchone()[0]
                if used + len(bundle) > WEB_STORAGE_LIMIT:
                    raise ApiError(409, "NOT_READY", "Fjern en gammel webpakke for at få plads til den nye.")
                db.execute("INSERT INTO addon_web_files (id, body) VALUES (?, ?)", (addon["id"], bundle))
            db.execute("INSERT INTO addons (id, body) VALUES (?, ?)", (addon["id"], encoded))
        return addon

    @router.put("/{addon_id}/remove")
    def remove(addon_id: str):
        key = identifier(addon_id)
        with closing(connect()) as db, db:
            db.execute("DELETE FROM addon_web_files WHERE id=?", (key,))
            db.execute("DELETE FROM addons WHERE id=?", (key,))
        return {"ok": True}

    app.include_router(router)

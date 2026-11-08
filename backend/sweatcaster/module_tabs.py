"""Native module manifest and private, local Kortscanner imports."""

from __future__ import annotations

import json
import math
import re
import sqlite3
import unicodedata
from collections import Counter
from contextlib import closing
from pathlib import Path
from uuid import UUID

from fastapi import FastAPI, Request

from sweatcaster.dto import ApiError

MAX_IMPORT = 1_000_000
CARD_TAB = {"id": "cards", "kind": "cards", "title": "Kortsamling"}


def information_tabs(settings) -> dict[str, dict]:
    path = Path(settings.output_root) / "module-tabs.json"
    try:
        with path.open("rb") as source:
            data = source.read(65537)
        rows = json.loads(data) if len(data) <= 65536 else []
    except (OSError, ValueError, RecursionError):
        return {}
    tabs = {}
    for row in rows[:7] if isinstance(rows, list) else []:
        if not isinstance(row, dict):
            continue
        tab_id, title, text = (row.get(key) for key in ("id", "title", "text"))
        if (isinstance(tab_id, str) and re.fullmatch(r"[a-z0-9-]{1,48}", tab_id) and tab_id != "cards"
                and isinstance(title, str) and 1 <= len(title.strip()) <= 32
                and isinstance(text, str) and len(text) <= 10000):
            tabs[tab_id] = {"id": tab_id, "title": title.strip(), "kind": "information", "text": text}
    return tabs


def parse_collection(payload: bytes) -> list[dict]:
    def field(row, key, *, required=False):
        value = row.get(key, "")
        if not isinstance(value, str) or len(value) > 180 or (required and not value.strip()):
            raise ValueError(key)
        return value.strip()

    try:
        if len(payload) > MAX_IMPORT:
            raise ValueError("size")
        rows = json.loads(payload.decode("utf-8-sig"))
        if not isinstance(rows, list) or len(rows) > 2000:
            raise ValueError("rows")
        cards = []
        ids = set()
        for row in rows:
            if not isinstance(row, dict):
                raise ValueError("row")
            card_id = str(UUID(field(row, "id", required=True)))
            if card_id in ids:
                raise ValueError("duplicate id")
            ids.add(card_id)
            price = row.get("prisDKK")
            if price is not None and (type(price) not in (int, float) or not 0 <= price <= 1_000_000_000 or not math.isfinite(price)):
                raise ValueError("price")
            cards.append({"id": card_id, "name": field(row, "navn", required=True),
                          "number": field(row, "nummer"), "set": field(row, "sæt"),
                          "language": field(row, "sprog"), "price": price})
        return cards
    except (ValueError, RecursionError) as exc:
        raise ApiError(422, "INVALID_INPUT", "Vælg en gyldig Kortscanner-eksport på højst 1 MB og 2.000 kort.") from exc


def collection(settings, replacement: list[dict] | None = None) -> list[dict]:
    path = Path(settings.output_root) / "modules.sqlite3"
    with closing(sqlite3.connect(path)) as db, db:
        db.execute("CREATE TABLE IF NOT EXISTS cards (id INTEGER PRIMARY KEY CHECK (id = 1), body TEXT NOT NULL)")
        if replacement is not None:
            db.execute("INSERT OR REPLACE INTO cards VALUES (1, ?)", (json.dumps(replacement),))
            return replacement
        row = db.execute("SELECT body FROM cards WHERE id = 1").fetchone()
        return json.loads(row[0]) if row else []


def collection_answer(settings, message: str) -> str | None:
    prefix, sep, question = message.partition(":")
    if not sep or prefix.strip().casefold() != "kortsamling":
        return None
    cards = collection(settings)
    if not cards:
        return "Importér først din JSON-fil i fanen Kortsamling."
    question = question.casefold()
    if "dublet" in question:
        def key(card):
            return tuple(unicodedata.normalize("NFKC", card[field]).casefold()
                         for field in ("name", "set", "number", "language"))

        counts = Counter(key(card) for card in cards if card["set"] and card["number"])
        groups = {k: n for k, n in counts.items() if n > 1}
        if not groups:
            return "Ingen mulige dubletter blandt kort med angivet sæt og nummer."
        lines = [f"{n} × {name} ({card_set}, {number}, {language or 'ukendt sprog'})"
                 for (name, card_set, number, language), n in sorted(groups.items())[:10]]
        return f"{len(groups)} mulige dubletgrupper. Varianter kan være forskellige.\n" + "\n".join(lines)
    if "pris" in question and ("mangler" in question or "uden" in question):
        missing = [card["name"] for card in cards if card["price"] is None]
        return f"{len(missing)} kort mangler en gemt pris." + ("\n" + ", ".join(missing[:10]) if missing else "")
    return f"Din samling har {len(cards)} kort. Spørg om mulige dubletter eller kort uden pris."


def register_modules(app: FastAPI, settings, authorize) -> None:
    @app.get("/api/modules/v1/manifest", include_in_schema=False)
    def manifest(request: Request):
        authorize(request, settings)
        extra = [{key: row[key] for key in ("id", "title", "kind")} for row in information_tabs(settings).values()]
        return {"version": 1, "tabs": [CARD_TAB, *extra]}

    @app.get("/api/modules/v1/tabs/cards", include_in_schema=False)
    def cards(request: Request):
        authorize(request, settings)
        return {"cards": collection(settings)}

    @app.put("/api/modules/v1/tabs/cards", include_in_schema=False)
    async def import_cards(request: Request):
        from starlette.concurrency import run_in_threadpool

        authorize(request, settings)
        payload = bytearray()
        async for chunk in request.stream():
            if len(payload) + len(chunk) > MAX_IMPORT:
                raise ApiError(422, "INVALID_INPUT", "Importfilen må højst fylde 1 MB.")
            payload.extend(chunk)
        cards = await run_in_threadpool(parse_collection, bytes(payload))
        return {"cards": await run_in_threadpool(collection, settings, cards)}

    @app.get("/api/modules/v1/tabs/{tab_id}", include_in_schema=False)
    def information(request: Request, tab_id: str):
        authorize(request, settings)
        tab = information_tabs(settings).get(tab_id)
        if tab is None:
            raise ApiError(404, "NOT_FOUND", "Fanen findes ikke.")
        return {"text": tab["text"]}

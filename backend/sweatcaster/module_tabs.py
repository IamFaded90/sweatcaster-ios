"""Native module manifest and private, local Kortscanner imports."""

from __future__ import annotations

import json
import logging
import math
import os
import re
import sqlite3
import unicodedata
from collections import Counter
from contextlib import AsyncExitStack, asynccontextmanager, closing
from datetime import datetime, timezone
from inspect import signature
from pathlib import Path
from uuid import UUID

from fastapi import Body, FastAPI, Request, Response

from sweatcaster.dto import ApiError
from sweatcaster.emby_library import EmbyLibraryError, read_library

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
    from sweatcaster.bot_computer_routes import register_bot_computers
    from sweatcaster.bot_computers import BotComputerWorker
    from sweatcaster.code_batch import BatchWorker, configured_batch
    from sweatcaster.repository_library import RepositoryError

    workspace = Path(os.environ.get("SWEATCASTER_WORKSPACE_DIR", "workspace"))
    batch = configured_batch(settings, workspace)
    computers = register_bot_computers(app, settings, authorize)
    workflows = batch.workflows
    original_lifespan = app.router.lifespan_context
    mcp = None
    try:
        from mcp.server.fastmcp import FastMCP
        from mcp.server.transport_security import TransportSecuritySettings
    except ImportError:
        pass
    else:
        from sweatcaster.repository_library import mcp_server

        if "max_request_body_size" in signature(FastMCP).parameters:
            mcp = mcp_server(workflows.library, stateless_http=True, json_response=True,
                             max_request_body_size=32_768,
                             transport_security=TransportSecuritySettings(enable_dns_rebinding_protection=False))
        else:
            logging.getLogger(__name__).warning("HTTP MCP requires mcp>=1.29.1,<2; the remaining API is available.")

    if mcp is not None:
        from starlette.routing import Route
        from sweatcaster.security import is_phone_host

        mcp.streamable_http_app()

        class AuthenticatedMCP:
            async def __call__(self, scope, receive, send):
                request = Request(scope, receive)
                try:
                    host = request.url.hostname or ""
                    permitted = host in {"localhost", "127.0.0.1", "::1"} or is_phone_host(host)
                except ValueError:
                    permitted = False
                if not permitted or "origin" in request.headers:
                    raise ApiError(403, "INVALID_INPUT", "MCP kræver en godkendt lokal adresse og en lokal klient.")
                authorize(request, settings)
                await mcp.session_manager.handle_request(scope, receive, send)

        app.router.routes.append(Route("/api/modules/v1/mcp", AuthenticatedMCP(), methods=["GET", "POST", "DELETE"]))

    @asynccontextmanager
    async def lifespan(application):
        async with AsyncExitStack() as stack:
            await stack.enter_async_context(original_lifespan(application))
            if mcp is not None:
                await stack.enter_async_context(mcp.session_manager.run())
            worker = BatchWorker(batch)
            computers_worker = BotComputerWorker(computers)
            worker.start()
            stack.callback(worker.stop)
            computers_worker.start()
            stack.callback(computers_worker.stop)
            yield

    app.router.lifespan_context = lifespan

    @app.get("/api/modules/v1/emby/library", include_in_schema=False)
    def emby_library(request: Request, response: Response, parent: str | None = None,
                     search: str = "", offset: int = 0):
        authorize(request, settings)
        try:
            library = read_library(parent=parent, search=search, offset=offset)
        except EmbyLibraryError as exc:
            code = "INVALID_INPUT" if exc.status == 422 else "NOT_READY"
            raise ApiError(exc.status, code, str(exc)) from exc
        response.headers["Cache-Control"] = "no-store"
        return library

    @app.put("/api/modules/v1/code-repositories", include_in_schema=False)
    def clone_repository(request: Request, body: dict = Body(...)):
        authorize(request, settings)
        repo = body.get("repo")
        if not isinstance(repo, str) or len(repo) > 150:
            raise ApiError(422, "INVALID_INPUT", "Angiv et GitHub-repo som ejer/projekt.")
        try:
            target = workflows.library._repo(repo)
            if not target.exists():
                workflows.library.clone(repo)
            _, revision = workflows.library._head(repo)
            return {"repo": repo.lower(), "revision": revision}
        except (RepositoryError, OSError) as exc:
            raise ApiError(422, "INVALID_INPUT", "GitHub-repoet kunne ikke klones eller læses med PC’ens Git-adgang.") from exc

    @app.get("/api/modules/v1/routines", include_in_schema=False)
    def routines(request: Request):
        authorize(request, settings)
        return {"routines": workflows.routine_status(datetime.now(timezone.utc))}

    @app.put("/api/modules/v1/routines", include_in_schema=False)
    def configure_routines(request: Request, body: dict = Body(...)):
        authorize(request, settings)
        entries = body.get("routines")
        if not isinstance(entries, list):
            raise ApiError(422, "INVALID_INPUT", "Angiv rutiner som en liste.")
        try:
            workflows.configure_routines(entries)
        except RepositoryError as exc:
            raise ApiError(422, "INVALID_INPUT", str(exc)) from exc
        return {"routines": workflows.routines()}

    @app.get("/api/modules/v1/agent-memory", include_in_schema=False)
    def memories(request: Request):
        authorize(request, settings)
        return {"items": workflows.memories()}

    @app.put("/api/modules/v1/agent-memory", include_in_schema=False)
    def remember(request: Request, body: dict = Body(...)):
        authorize(request, settings)
        scope, kind, note = (body.get(key) for key in ("scope", "kind", "text"))
        if not all(isinstance(value, str) for value in (scope, kind, note)):
            raise ApiError(422, "INVALID_INPUT", "Angiv scope, kind og text.")
        if settings.token and settings.token in note:
            raise ApiError(422, "INVALID_INPUT", "Hukommelsen kan ikke gemme pairing-tokenet.")
        try:
            return {"id": workflows.remember(scope, kind, note)}
        except RepositoryError as exc:
            raise ApiError(422, "INVALID_INPUT", str(exc)) from exc

    @app.delete("/api/modules/v1/agent-memory/{key}", include_in_schema=False)
    def forget(request: Request, key: str):
        authorize(request, settings)
        return {"deleted": workflows.forget(key)}

    @app.get("/api/modules/v1/code-batches", include_in_schema=False)
    def batches(request: Request):
        authorize(request, settings)
        return {"jobs": batch.list()}

    @app.put("/api/modules/v1/code-batches", include_in_schema=False)
    def enqueue(request: Request, body: dict = Body(...)):
        authorize(request, settings)
        repo, goal, files = (body.get(key) for key in ("repo", "goal", "files"))
        if (not isinstance(repo, str) or not isinstance(goal, str) or not isinstance(files, list)
                or not all(isinstance(file, str) for file in files)):
            raise ApiError(422, "INVALID_INPUT", "Vælg et repo, en opgave og kildefiler.")
        try:
            return {"id": batch.enqueue(repo, goal, files)}
        except RepositoryError as exc:
            raise ApiError(422, "INVALID_INPUT", str(exc)) from exc

    @app.get("/api/modules/v1/code-batches/{job}", include_in_schema=False)
    def batch_detail(request: Request, job: str):
        authorize(request, settings)
        try:
            return batch.get(job)
        except RepositoryError as exc:
            raise ApiError(404, "NOT_FOUND", str(exc)) from exc

    @app.put("/api/modules/v1/code-batches/{job}/approval", include_in_schema=False)
    def approve_batch(request: Request, job: str, body: dict = Body(...)):
        authorize(request, settings)
        if body != {"approved": True} or body.get("approved") is not True:
            raise ApiError(422, "INVALID_INPUT", "Forslaget kræver en eksplicit godkendelse.")
        try:
            return batch.apply(job)
        except RepositoryError as exc:
            raise ApiError(409, "NOT_READY", str(exc)) from exc

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

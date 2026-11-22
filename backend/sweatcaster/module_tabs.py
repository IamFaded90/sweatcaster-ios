"""Native module manifest and private, local Kortscanner imports."""

from __future__ import annotations

import json
import logging
import math
import os
import re
import sqlite3
import unicodedata
from asyncio import gather
from collections import Counter
from contextlib import AsyncExitStack, asynccontextmanager, closing
from datetime import datetime, timezone
from inspect import signature
from pathlib import Path
from uuid import UUID

from fastapi import Body, FastAPI, Request, Response
from starlette.concurrency import run_in_threadpool

from sweatcaster import __version__
from sweatcaster.dto import ApiError
from sweatcaster.searxng_search import SearXNGError, search_web
from sweatcaster.youtube_connection import YouTubeError, read_channels

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
    from sweatcaster.document_routes import register_documents
    from sweatcaster.cast_relay import register_cast_relay
    from sweatcaster.window_help import register_window_help
    from sweatcaster.phone_screen import register_phone_screen
    from sweatcaster.film_companion import register_film_companion
    from sweatcaster.agent_recording import register_recording
    from sweatcaster.agent_tool_builder import register_agent_tools
    from sweatcaster.sales_service import register_sales
    from sweatcaster.village_surprises import register_village_surprises
    from sweatcaster.agent_rooms import register_agent_rooms
    from sweatcaster.agent_repair import register_agent_repair
    from sweatcaster.agent_cases import register_agent_cases
    from sweatcaster.agent_conversation import register_agent_chat
    from sweatcaster.bot_computer_routes import register_bot_computers
    from sweatcaster.lumi_companion import register_lumi
    from sweatcaster.bot_computers import BotComputerError, BotComputerWorker, ollama_reports, wire_uuid
    from sweatcaster.code_batch import BatchWorker, configured_batch
    from sweatcaster.repository_library import RepositoryError, RepositoryInUse

    workspace = Path(os.environ.get("SWEATCASTER_WORKSPACE_DIR", "workspace"))
    batch = configured_batch(settings, workspace)
    computers = register_bot_computers(app, settings, authorize)
    from sweatcaster.agentmail_inboxes import register_agentmail
    from sweatcaster.addons import register_addons
    from sweatcaster.composio_library import register_composio
    from sweatcaster.grok_templates import register_grok_templates
    from sweatcaster.mail_appointments import register_mail_appointments
    from sweatcaster.mail_reschedule import register_mail_reschedule
    from sweatcaster.gmail_cleanup import register_gmail_cleanup
    from sweatcaster.pc_repair import register_pc_repair
    from sweatcaster.microsoft_voice import register_christel
    from sweatcaster.pc_metrics import desktop_setup, gmail_setup, image_engine_status, image_setup, read_metrics, web_setup
    from sweatcaster.store import Store
    from sweatcaster.studio_video import register_studio_video
    from sweatcaster.studio_meshes import register_studio_meshes
    from sweatcaster.tradera_watch import register_tradera
    from sweatcaster.video_review import register_video_review

    register_lumi(app, settings, authorize)
    studio_videos = register_studio_video(app, settings, authorize)
    register_studio_meshes(app, settings, authorize)
    register_cast_relay(app, settings, authorize)
    register_window_help(app, settings, authorize)
    register_documents(app, settings, authorize)
    register_phone_screen(app, settings, authorize)
    register_film_companion(app, settings, authorize)
    register_recording(app, settings, authorize)
    register_agent_tools(app, settings, authorize)
    surprises = register_village_surprises(app, settings, authorize, ollama_reports(settings, add_on=True),
                                           is_idle=lambda: computers.active_jobs() == 0)
    rooms = register_agent_rooms(app, settings, authorize, is_idle=lambda: computers.active_jobs() == 0)
    register_agent_repair(app, settings, authorize, batch=batch)
    library = register_composio(app, settings, authorize)
    from sweatcaster.github_build_report import register_build_report
    register_build_report(app, settings, authorize, library)
    cases = register_agent_cases(app, settings, authorize, library)
    register_mail_reschedule(app, settings, authorize, library)
    register_gmail_cleanup(app, settings, authorize, library)
    register_pc_repair(app, settings, authorize, is_idle=lambda: computers.active_jobs() == 0)
    sales = register_sales(app, settings, authorize, library)
    price_watches = register_tradera(app, settings, authorize, library)
    appointments = register_mail_appointments(app, settings, authorize, library,
                                              ollama_reports(settings, mail_appointments=True))
    register_grok_templates(app, settings, authorize)
    register_christel(app, settings, authorize)
    register_agentmail(app, settings, authorize, library)
    register_addons(app, settings, authorize, ollama_reports(settings, add_on=True))
    waiting_for_video_review = register_video_review(app, settings, authorize)

    @app.get("/api/modules/v1/attention", include_in_schema=False)
    def attention(request: Request, response: Response):
        authorize(request, settings)
        response.headers["Cache-Control"] = "no-store"
        selected = appointments.settings()
        mail = None
        if selected:
            bot = selected[0]
            suggestions = appointments.status(bot)["appointments"]
            mail = {"botID": bot, "appointments": [
                item for item in suggestions if item.get("revisionStatus") in (None, "active")
            ]}
        return {"code": [job for job in batch.list() if job["status"] == "review"],
                "video": waiting_for_video_review(), "mail": mail}

    @app.get("/api/modules/v1/pc-image-engine", include_in_schema=False)
    def pc_image_engine(request: Request, response: Response):
        authorize(request, settings)
        response.headers["Cache-Control"] = "no-store"
        return {"state": image_engine_status()}

    @app.get("/api/modules/v1/pc-metrics", include_in_schema=False)
    def pc_metrics(request: Request, response: Response):
        authorize(request, settings)
        response.headers["Cache-Control"] = "no-store"
        metrics = read_metrics(settings.output_root)
        jobs = Store(settings.output_root / "state.sqlite3").list_jobs()
        metrics["videoJobs"] = sum(job["status"] in {"queued", "analyzing", "commentating", "synthesizing", "rendering"} for job in jobs)
        metrics["botJobs"] = computers.active_jobs()
        return metrics

    @app.get("/api/modules/v1/pc-setup", include_in_schema=False)
    async def pc_setup(request: Request, response: Response):
        authorize(request, settings)
        response.headers["Cache-Control"] = "no-store"
        supports_images = any(getattr(route, "path", None) == "/api/v2/images/generate"
                              and "POST" in (getattr(route, "methods", None) or ()) for route in app.routes)
        desktops, images, web, gmail = await gather(
            run_in_threadpool(desktop_setup, computers.runtime),
            run_in_threadpool(image_setup, supports_images),
            run_in_threadpool(web_setup),
            run_in_threadpool(gmail_setup, library, appointments),
        )
        return {"desktops": desktops, **images, "web": web, "gmail": gmail, "pcVersion": __version__}

    workflows = batch.workflows
    original_lifespan = app.router.lifespan_context
    mcp = None
    repository_mcp = None
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
            repository_mcp = mcp_server(workflows.library, stateless_http=True, json_response=True,
                                        max_request_body_size=32_768,
                                        transport_security=TransportSecuritySettings(enable_dns_rebinding_protection=False))
        else:
            logging.getLogger(__name__).warning("HTTP MCP requires mcp>=1.29.1,<2; the remaining API is available.")

    if mcp is not None:
        from mcp.server.fastmcp import Image
        from starlette.routing import Route
        from sweatcaster.security import is_phone_host

        @mcp.tool()
        def create_code_proposal(repository: str, goal: str, files: list[str], priority: int = 0) -> dict:
            """Queue a code proposal for selected source files. Review and approval happen in Code Bot."""
            return {"id": batch.enqueue(repository, goal, files, priority=priority)}

        @mcp.tool()
        def generate_image(prompt: str):
            """Generate a PNG on the paired PC from an image description."""
            from sweatcaster.comfy import generate_png

            if not 1 <= len(prompt.strip()) <= 1_000:
                raise ValueError("Skriv en billedbeskrivelse på 1–1.000 tegn.")
            png = generate_png(prompt.strip())
            if len(png) > 15_000_000 or not png.startswith(b"\x89PNG\r\n\x1a\n"):
                raise ValueError("PC’en leverede ikke et gyldigt PNG-billede.")
            return Image(data=png, format="png")

        @mcp.tool()
        def studio_video_models() -> dict:
            """List the configured video models and report what is missing on the paired PC."""
            return studio_videos.catalog()

        @mcp.tool()
        def create_video(request_id: str, mode: str, prompt: str) -> dict:
            """Queue a video from text. Send the same UUID as request_id when retrying the same input."""
            return studio_videos.submit({"id": request_id, "mode": mode, "prompt": prompt, "photos": []})

        @mcp.tool()
        def studio_video_status(job_id: str) -> dict:
            """Check a video job. Finished videos are available in Kreativt Studio."""
            return studio_videos.status(job_id)

        mcp.streamable_http_app()
        repository_mcp.streamable_http_app()

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
                group = request.headers.get("x-fadedai-tools")
                if group not in (None, "repository"):
                    raise ApiError(422, "INVALID_INPUT", "Denne værktøjsgruppe findes ikke.")
                server = repository_mcp if group == "repository" else mcp
                await server.session_manager.handle_request(scope, receive, send)

        app.router.routes.append(Route("/api/modules/v1/mcp", AuthenticatedMCP(), methods=["GET", "POST", "DELETE"]))

    @asynccontextmanager
    async def lifespan(application):
        async with AsyncExitStack() as stack:
            await stack.enter_async_context(original_lifespan(application))
            if mcp is not None:
                await stack.enter_async_context(mcp.session_manager.run())
                await stack.enter_async_context(repository_mcp.session_manager.run())
            worker = BatchWorker(batch)
            computers_worker = BotComputerWorker(computers)
            worker.start()
            stack.callback(worker.stop)
            computers_worker.start()
            stack.callback(computers_worker.stop)
            appointments.start()
            stack.callback(appointments.stop)
            price_watches.start()
            stack.callback(price_watches.stop)
            sales.start()
            stack.callback(sales.stop)
            surprises.start()
            stack.callback(surprises.stop)
            rooms.start()
            stack.callback(rooms.stop)
            cases.start()
            stack.callback(cases.stop)
            application.state.instagram_schedule.start()
            stack.callback(application.state.instagram_schedule.stop)
            yield

    app.router.lifespan_context = lifespan

    @app.get("/api/modules/v1/youtube/channels", include_in_schema=False)
    def youtube_channels(request: Request, response: Response):
        authorize(request, settings)
        try:
            channels = read_channels()
        except YouTubeError as exc:
            raise ApiError(exc.status, "NOT_READY", exc.message) from exc
        response.headers["Cache-Control"] = "no-store"
        return channels

    from sweatcaster.google_drive import DriveError, read_files

    @app.get("/api/modules/v1/google-drive/files", include_in_schema=False)
    def drive_files(request: Request, response: Response, parent: str | None = None, page: str | None = None):
        authorize(request, settings)
        try:
            files = read_files(parent=parent, page=page)
        except DriveError as exc:
            code = "INVALID_INPUT" if exc.status == 422 else "NOT_READY"
            raise ApiError(exc.status, code, exc.message) from exc
        response.headers["Cache-Control"] = "no-store"
        return files

    @app.put("/api/modules/v1/web-search", include_in_schema=False)
    def web_search(request: Request, response: Response, body: dict = Body(...)):
        authorize(request, settings)
        try:
            results = search_web(body.get("query"))
        except SearXNGError as exc:
            code = "INVALID_INPUT" if exc.status == 422 else "NOT_READY"
            raise ApiError(exc.status, code, exc.message) from exc
        response.headers["Cache-Control"] = "no-store"
        return {"results": results}

    @app.put("/api/modules/v1/chat-research", include_in_schema=False)
    def chat_research(request: Request, response: Response, body: dict = Body(...)):
        from sweatcaster.web_research import collect_sources, page_excerpt

        authorize(request, settings)
        query = body.get("query")
        if not isinstance(query, str) or not 3 <= len(query.strip()) <= 500 or not query.strip().isprintable():
            raise ApiError(422, "INVALID_INPUT", "Skriv en kort søgning eller en offentlig webadresse.")
        query = query.strip()
        try:
            if query.startswith(("https://", "http://")) and not any(char.isspace() for char in query):
                excerpt = page_excerpt(query)
                if not excerpt:
                    raise SearXNGError(404, "Den offentlige side kunne ikke læses.")
                context = excerpt
                sources = [{"title": "Siden du valgte", "url": query, "readPage": True}]
            else:
                context, sources = collect_sources(query[:180])
        except SearXNGError as exc:
            raise ApiError(exc.status, "RESEARCH_UNAVAILABLE", exc.message) from exc
        response.headers["Cache-Control"] = "no-store"
        return {"context": context, "sources": sources}

    register_agent_chat(app, settings, authorize)

    @app.put("/api/modules/v1/bot-activity", include_in_schema=False)
    def bot_activity(request: Request, response: Response, body: dict = Body(...)):
        authorize(request, settings)
        bots = body.get("botIDs")
        if not isinstance(bots, list) or len(bots) > 10:
            raise ApiError(422, "INVALID_INPUT", "Vælg højst ti bots.")
        try:
            ids = list(dict.fromkeys(wire_uuid(value) for value in bots))
        except BotComputerError as exc:
            raise ApiError(422, "INVALID_INPUT", exc.message) from exc
        response.headers["Cache-Control"] = "no-store"
        return computers.activity(ids)

    @app.get("/api/modules/v1/video-quality", include_in_schema=False)
    def video_quality_support(request: Request, response: Response):
        authorize(request, settings)
        response.headers["Cache-Control"] = "no-store"
        from sweatcaster.pipeline import Pipeline
        return {"available": getattr(Pipeline, "checks_export", False)}

    @app.get("/api/modules/v1/video-jobs/{job_id}/quality", include_in_schema=False)
    def video_job_quality(job_id: str, request: Request, response: Response):
        authorize(request, settings)
        response.headers["Cache-Control"] = "no-store"
        from sweatcaster.video_quality import job_receipt
        return job_receipt(settings, app.state.store, job_id)

    @app.delete("/api/modules/v1/video-jobs/{job_id}/record", include_in_schema=False)
    def delete_unavailable_video_job(job_id: str, request: Request, payload: dict = Body(...)):
        authorize(request, settings)
        if payload != {"confirm_job_id": job_id}:
            raise ApiError(422, "INVALID_INPUT", "Bekræft jobkortet, før det fjernes.")
        from sweatcaster.output_cleanup import discard_unavailable_video_job

        discard_unavailable_video_job(settings, app.state.store, job_id)
        return {"removed": True}

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

    @app.put("/api/modules/v1/code-repositories/removal", include_in_schema=False)
    def remove_repository(request: Request, body: dict = Body(...)):
        authorize(request, settings)
        repo = body.get("repo")
        if not isinstance(repo, str) or len(repo) > 150 or body != {"repo": repo, "confirm_repo": repo}:
            raise ApiError(422, "INVALID_INPUT", "Bekræft, hvilken lokal Git-kopi du vil slette.")
        try:
            return {"removed": batch.remove_repository(repo)}
        except RepositoryInUse as exc:
            raise ApiError(409, "NOT_READY", str(exc)) from exc
        except RepositoryError as exc:
            raise ApiError(422, "INVALID_INPUT", str(exc)) from exc
        except OSError as exc:
            raise ApiError(500, "NOT_READY", "PC’en kunne ikke slette den lokale Git-kopi.") from exc

    @app.put("/api/modules/v1/routines", include_in_schema=False)
    def configure_routines(request: Request, body: dict = Body(...)):
        authorize(request, settings)
        entries = body.get("routines")
        if not isinstance(entries, list):
            raise ApiError(422, "INVALID_INPUT", "Angiv rutiner som en liste.")
        try:
            with workflows.library.snapshot_changes:
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
            return {"id": batch.enqueue(repo, goal, files, priority=body.get("priority", 0))}
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

    @app.put("/api/modules/v1/code-batches/{job}/rejection", include_in_schema=False)
    def reject_batch(request: Request, job: str, body: dict = Body(...)):
        authorize(request, settings)
        if body != {"rejected": True} or body.get("rejected") is not True:
            raise ApiError(422, "INVALID_INPUT", "Bekræft, at du vil afvise forslaget.")
        try:
            return batch.reject(job)
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

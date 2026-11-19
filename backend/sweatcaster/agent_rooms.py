"""Persistent, versioned Village room blueprints rendered on the paired PC."""

from base64 import b64encode
from contextlib import closing
from hashlib import sha256
import json
import logging
from pathlib import Path
import re
import sqlite3
from threading import Event, Lock, Thread
from time import time

from fastapi import APIRouter, Body, Depends, Request, Response
from starlette.concurrency import run_in_threadpool

from sweatcaster.agent_room_art import render_room
from sweatcaster.agent_room_scene import decode_sketch, figures, identifier, invalid, make_version, revise, text
from sweatcaster.bot_computers import ModelBusy
from sweatcaster.dto import ApiError


MAX_ROOMS = 35
MAX_VERSIONS = 24
MAX_UPLOAD = 2_650_000
PREFIX = "/api/modules/v1/agent-rooms"


class AgentRooms:
    def __init__(self, output_root, *, render=render_room, is_idle=None):
        self.database = Path(output_root) / "agent-rooms.sqlite3"
        self.render = render
        self.is_idle = is_idle or (lambda: True)
        self.stop_signal = Event()
        self.work_lock = Lock()
        self.worker = None

    def db(self):
        self.database.parent.mkdir(parents=True, exist_ok=True)
        db = sqlite3.connect(self.database, timeout=8)
        db.execute("PRAGMA foreign_keys=ON")
        db.executescript("""
            CREATE TABLE IF NOT EXISTS rooms(id TEXT PRIMARY KEY, bot TEXT NOT NULL, body TEXT NOT NULL,
                sketch BLOB NOT NULL, fingerprint TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS art(room TEXT NOT NULL REFERENCES rooms(id) ON DELETE CASCADE,
                digest TEXT NOT NULL, data BLOB NOT NULL, PRIMARY KEY(room,digest));
        """)
        return db

    @staticmethod
    def json(value):
        return json.dumps(value, ensure_ascii=False, allow_nan=False, separators=(",", ":"))

    @staticmethod
    def get(db, key):
        row = db.execute("SELECT body FROM rooms WHERE id=?", (key,)).fetchone()
        if not row:
            raise ApiError(404, "NOT_FOUND", "Rummet er ikke længere gemt.")
        return json.loads(row[0])

    def write(self, db, room):
        db.execute("UPDATE rooms SET body=? WHERE id=?", (self.json(room), room["id"]))
        return room

    def one(self, key):
        with closing(self.db()) as db:
            return self.get(db, identifier(key))

    def list(self, bot, published):
        parameters = (identifier(bot),) if bot is not None else ()
        if not parameters and not published:
            raise invalid("Vælg agenten eller de gemte rum.")
        filters = (["bot=?"] if parameters else []) + (["json_extract(body,'$.publishedRevision') IS NOT NULL"] if published else [])
        with closing(self.db()) as db:
            rows = db.execute("SELECT body FROM rooms WHERE " + " AND ".join(filters) + " ORDER BY rowid DESC", parameters)
            return {"rooms": [json.loads(row[0]) for row in rows]}

    def create(self, key, body):
        key, bot = identifier(key), identifier(body.get("botID"))
        title, brief = text(body.get("title"), 90), text(body.get("brief"), 390, empty=True)
        selected = figures(body.get("figures"))
        sketch = decode_sketch(body.get("sketch"))
        signature = sha256(self.json([bot, title, brief, selected]).encode() + sketch).hexdigest()
        room = {"id": key, "botID": bot, "title": title, "brief": brief, "state": "queued", "revision": 0,
                "created": time(), "publishedRevision": None, "versions": [], "notice": "Rummet venter på PC’en.",
                "drawingFigures": selected}
        with closing(self.db()) as db, db:
            db.execute("BEGIN IMMEDIATE")
            previous = db.execute("SELECT fingerprint FROM rooms WHERE id=?", (key,)).fetchone()
            if previous:
                if previous[0] != signature:
                    raise ApiError(409, "REQUEST_REUSED", "Rummet er allerede oprettet med et andet indhold.")
                return self.get(db, key)
            if db.execute("SELECT count(*) FROM rooms").fetchone()[0] >= MAX_ROOMS:
                raise ApiError(409, "NOT_READY", "Slet et gemt rum for at få plads til et nyt.")
            db.execute("INSERT INTO rooms VALUES(?,?,?,?,?)", (key, bot, self.json(room), sketch, signature))
        return room

    @staticmethod
    def version(room, revision):
        if type(revision) is int:
            for version in room["versions"]:
                if version["revision"] == revision:
                    return version
        raise ApiError(409, "NOT_READY", "Vælg en eksisterende version af rummet.")

    def change(self, key, action, body):
        key = identifier(key)
        with closing(self.db()) as db, db:
            db.execute("BEGIN IMMEDIATE")
            room = self.get(db, key)
            if action == "remove":
                if room["state"] == "building":
                    raise ApiError(409, "NOT_READY", "Vent med at slette, mens rummet bliver tegnet.")
                db.execute("DELETE FROM rooms WHERE id=?", (key,))
                return {"removed": True}
            if action == "retry":
                if room["state"] == "queued":
                    return room
                if room["state"] != "failed":
                    raise ApiError(409, "NOT_READY", "Kun et afbrudt rum kan prøves igen.")
                return self.write(db, dict(room, state="queued", notice="PC’en prøver igen fra den gemte skitse."))
            version = self.version(room, body.get("revision"))
            if action == "publish":
                return self.write(db, dict(room, state="published", publishedRevision=version["revision"],
                                           notice="Denne version kan nu åbnes i Landsbyen."))
            if len(room["versions"]) >= MAX_VERSIONS:
                raise ApiError(409, "NOT_READY", "Rummet har nået grænsen på 24 versioner.")
            next_version = revise(version, body.get("figureID"), body.get("scale"), body.get("instruction"), room["revision"] + 1)
            previous = room["versions"][-1]
            if previous["instruction"] == next_version["instruction"] and previous["figures"] == next_version["figures"]:
                return room
            return self.write(db, dict(room, revision=next_version["revision"], versions=room["versions"] + [next_version],
                                       notice="Den nye figurstørrelse er kontrolleret. Vælg hvilken version du vil gemme."))

    def artwork(self, key, digest):
        key = identifier(key)
        if re.fullmatch(r"[0-9a-f]{64}", digest) is None:
            raise invalid("Billedet til rummet kunne ikke læses.")
        with closing(self.db()) as db:
            row = db.execute("SELECT data FROM art WHERE room=? AND digest=?", (key, digest)).fetchone()
        if not row:
            raise ApiError(404, "NOT_FOUND", "Rummets billede blev ikke fundet.")
        return {"image": b64encode(row[0]).decode("ascii")}

    def work_once(self):
        if not self.work_lock.acquire(blocking=False):
            return False
        try:
            if self.stop_signal.is_set() or not self.is_idle():
                return False
            with closing(self.db()) as db, db:
                db.execute("BEGIN IMMEDIATE")
                row = db.execute("SELECT body,sketch FROM rooms WHERE json_extract(body,'$.state')='queued' "
                                 "ORDER BY rowid LIMIT 1").fetchone()
                if not row:
                    return False
                room = self.write(db, dict(json.loads(row[0]), state="building", notice="PC’en tegner rummet efter din skitse."))
            try:
                rendered = self.render(row[1], room["title"], room["brief"], self.stop_signal.is_set)
                if self.stop_signal.is_set():
                    raise InterruptedError
                data, version = make_version(rendered, room["drawingFigures"], "Første version fra skitsen")
                with closing(self.db()) as db, db:
                    db.execute("BEGIN IMMEDIATE")
                    db.execute("INSERT OR IGNORE INTO art VALUES(?,?,?)", (room["id"], version["artwork"], data))
                    self.write(db, dict(room, state="ready", revision=1, versions=[version],
                                        notice="Tegningen er klar. Åbn rummet og prøv figurerne på iPhone."))
                return True
            except (ModelBusy, InterruptedError):
                state, notice = "queued", "Rummet venter på ledig tid på PC’en."
            except ApiError as error:
                state, notice = "failed", str(error)
            except Exception:
                logging.getLogger(__name__).exception("Village room could not be rendered")
                state, notice = "failed", "Rummet kunne ikke tegnes. Den valgte skitse er gemt."
            with closing(self.db()) as db, db:
                self.write(db, dict(room, state=state, notice=notice))
            return state == "failed"
        finally:
            self.work_lock.release()

    def start(self):
        with closing(self.db()) as db, db:
            db.execute("UPDATE rooms SET body=json_set(body,'$.state','queued','$.notice',?) "
                       "WHERE json_extract(body,'$.state')='building'", ("Rummet fortsætter efter genstart.",))
        self.stop_signal.clear()
        self.worker = Thread(target=self.run, daemon=True, name="fadedai-village-room")
        self.worker.start()

    def stop(self):
        self.stop_signal.set()
        if self.worker:
            self.worker.join(1)

    def run(self):
        while not self.stop_signal.wait(3):
            try:
                self.work_once()
            except sqlite3.Error:
                logging.getLogger(__name__).exception("Village room queue unavailable")
                self.stop_signal.wait(8)


def register_agent_rooms(app, settings, authorize, *, is_idle=None):
    service = AgentRooms(settings.output_root, is_idle=is_idle)

    def paired(request: Request, response: Response):
        authorize(request, settings)
        response.headers["Cache-Control"] = "no-store"

    router = APIRouter(prefix=PREFIX, dependencies=[Depends(paired)], include_in_schema=False)

    @router.get("")
    def library(bot_id: str | None = None, published: bool = False):
        return service.list(bot_id, published)

    @router.get("/{room_id}")
    def status(room_id: str):
        return service.one(room_id)

    @router.put("/{room_id}")
    async def create(room_id: str, request: Request):
        incoming = bytearray()
        async for chunk in request.stream():
            if len(incoming) + len(chunk) > MAX_UPLOAD:
                raise invalid("Skitsefilen fylder for meget til et rum.")
            incoming.extend(chunk)
        try:
            payload = json.loads(incoming)
            if not isinstance(payload, dict):
                raise ValueError
        except (ValueError, RecursionError):
            raise invalid("Rummets oplysninger kunne ikke læses.") from None
        return await run_in_threadpool(service.create, room_id, payload)

    @router.get("/{room_id}/art/{digest}")
    def image(room_id: str, digest: str):
        return service.artwork(room_id, digest)

    @router.put("/{room_id}/{action}")
    def update(room_id: str, action: str, payload: dict = Body(...)):
        if action not in {"publish", "revise", "retry", "remove"}:
            raise invalid("Denne handling findes ikke i landsbyen.")
        return service.change(room_id, action, payload)

    app.include_router(router)
    return service

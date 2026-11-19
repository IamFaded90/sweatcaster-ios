"""Owner-authorized idle-time creations using the existing native add-on format."""

from contextlib import closing
import json
import logging
import re
from pathlib import Path
import sqlite3
from threading import Event, Lock, Thread
from time import time

from fastapi import APIRouter, Body, Depends, Request, Response

from sweatcaster.addons import LIMIT, TOOLS, validate
from sweatcaster.bot_computers import ModelBusy
from sweatcaster.dto import ApiError
from sweatcaster.sales_models import encoded, identifier, text

FIGURES = frozenset(("adam", "atlas", "milo", "noah", "theo", "eva", "luna", "iris", "nova", "saga", "lumi", "harper"))


class VillageSurprises:
    def __init__(self, root, generate, is_idle=None):
        self.root = Path(root)
        self.path = self.root / "village-surprises.sqlite3"
        self.generate = generate
        self.is_idle = is_idle or (lambda: True)
        self.lock = Lock()
        self.stopped = Event()
        self.thread = None

    def db(self):
        self.root.mkdir(parents=True, exist_ok=True)
        db = sqlite3.connect(self.path, timeout=10)
        db.executescript("CREATE TABLE IF NOT EXISTS surprises(id TEXT PRIMARY KEY, bot TEXT, body TEXT);")
        return db

    def one(self, bot, key):
        bot, key = identifier(bot), identifier(key)
        with closing(self.db()) as db:
            row = db.execute("SELECT body FROM surprises WHERE id=? AND bot=?", (key, bot)).fetchone()
        if not row:
            raise ApiError(404, "NOT_FOUND", "Overraskelsen er ikke længere gemt.")
        return json.loads(row[0])

    def list(self, bot):
        bot = identifier(bot)
        with closing(self.db()) as db:
            return {"items": [json.loads(row[0]) for row in db.execute(
                "SELECT body FROM surprises WHERE bot=? ORDER BY rowid DESC", (bot,))]}

    def save(self, job):
        value = {**job, "revision": job["revision"] + 1, "updated": time()}
        with closing(self.db()) as db, db:
            done = db.execute("UPDATE surprises SET body=? WHERE id=? AND bot=? AND json_extract(body,'$.revision')=?",
                              (encoded(value), value["id"], value["botID"], job["revision"])).rowcount
            if done != 1:
                raise ApiError(409, "REQUEST_REUSED", "Overraskelsen blev ændret. Opdatér og prøv igen.")
        return value

    def create(self, bot, key, body):
        bot, key = identifier(bot), identifier(key)
        brief = text(body.get("brief"), 650)
        figures = body.get("figures")
        if (not isinstance(figures, list) or not 1 <= len(figures) <= 10
                or any(not isinstance(v, str) or v not in FIGURES for v in figures) or len(set(figures)) != len(figures)):
            raise ApiError(422, "INVALID_INPUT", "Vælg figurer fra din landsby.")
        value = {"id": key, "botID": bot, "brief": brief, "figures": figures, "revision": 1,
                 "state": "queued", "created": time(), "updated": time(), "bytes": 0,
                 "note": "Agenten bygger, når PC’en har ledig tid."}
        with closing(self.db()) as db, db:
            db.execute("BEGIN IMMEDIATE")
            old = db.execute("SELECT body FROM surprises WHERE id=?", (key,)).fetchone()
            if old:
                old = json.loads(old[0])
                if (old["botID"], old["brief"], old["figures"]) != (bot, brief, figures):
                    raise ApiError(409, "REQUEST_REUSED", "Opgaven er allerede oprettet. Opdatér listen.")
                return old
            if db.execute("SELECT count(*) FROM surprises").fetchone()[0] >= 50:
                raise ApiError(409, "NOT_READY", "Slet en gammel overraskelse for at få plads.")
            db.execute("INSERT INTO surprises VALUES(?,?,?)", (key, bot, encoded(value)))
        return value

    def run(self, bot, key):
        if not self.lock.acquire(blocking=False):
            return self.one(bot, key)
        try:
            job = self.one(bot, key)
            if job["state"] != "queued" or not self.is_idle():
                return job
            job = self.save({**job, "state": "building", "note": "Agenten bygger og kontrollerer tilføjelsen."})
            prompt = ("Lav en lille nyttig aktivitet til brugerens landsby. Brug kun native værktøjsknapper "
                      "med kendte tool-værdier. Ingen links, HTML, installationer eller nye figurer. "
                      "Skriv dansk. text skal indeholde 3-6 konkrete handlingspunkter på hver sin linje til brugerens idé. "
                      "Returnér kort JSON med title,text,actions som det eksisterende add-on-format.\n"
                      'Eksempel {"title":"Mit atelier","text":"Gør dine billeder klar.",'
                      '"actions":[{"type":"tool","label":"Åbn tjeklisten","value":"checklist"}]}.\n'
                      "Godkendte figurer: " + ", ".join(job["figures"]) + "\nBrugerens idé: " + job["brief"])
            try:
                proposed = json.loads(self.generate(prompt, None))
                if not isinstance(proposed, dict):
                    raise ValueError
                addon = validate({**{key: proposed.get(key) for key in ("title", "text", "actions")}, "id": job["id"]})
                if (not addon["actions"] or any(a["type"] != "tool" or a["value"] not in TOOLS for a in addon["actions"])):
                    raise ValueError
                checks = ["Alle figurer er fra dit valgte udvalg.", "Skærmtekst kan læses af appen.",
                          "Alle knapper peger på installerede FadedAI-værktøjer."]
                ready = {**job, "addon": addon, "checks": checks, "state": "ready",
                         "steps": [re.sub(r"^(?:[-*•]|\d+[.)])\s*", "", line).strip()
                                   for line in addon["text"].splitlines() if line.strip()][:12], "completed": [],
                         "bytes": len(encoded(addon).encode()), "note": "Klar til at prøve. PC-kontrollen er gennemført."}
                return self.save(ready)
            except ModelBusy:
                return self.save({**job, "state": "queued", "note": "PC’ens model er optaget. Opgaven bliver i køen."})
            except (ApiError, ValueError, TypeError, KeyError):
                return self.save({**job, "state": "error", "note": "Agenten kunne ikke lave en gyldig aktivitet. Ret idéen og prøv igen."})
            except Exception:
                logging.getLogger(__name__).exception("Landsbyaktiviteten afventer en tilgængelig lokal model.")
                return self.save({**job, "state": "error", "note": "Den lokale model kunne ikke gøre aktiviteten færdig. Prøv igen."})
        finally:
            self.lock.release()

    def keep(self, job):
        if job["state"] == "kept":
            return job
        if job["state"] != "ready":
            raise ApiError(409, "NOT_READY", "Vent til aktiviteten er klar.")
        addon = validate(job["addon"])
        saved = {**job, "state": "kept", "revision": job["revision"] + 1,
                 "updated": time(), "note": "Aktiviteten ligger nu i dine tilføjelser."}
        with closing(self.db()) as db, db:
            db.execute("ATTACH DATABASE ? AS library", (str(self.root / "addons.sqlite3"),))
            db.execute("CREATE TABLE IF NOT EXISTS library.addons(id TEXT PRIMARY KEY,body TEXT NOT NULL)")
            db.execute("CREATE TABLE IF NOT EXISTS library.addon_web_files(id TEXT PRIMARY KEY,body BLOB NOT NULL)")
            db.execute("BEGIN IMMEDIATE")
            old = db.execute("SELECT body FROM library.addons WHERE id=?", (job["id"],)).fetchone()
            if old and json.loads(old[0]) != addon:
                raise ApiError(409, "NOT_READY", "En anden tilføjelse bruger allerede dette id.")
            if not old and db.execute("SELECT count(*) FROM library.addons").fetchone()[0] >= LIMIT:
                raise ApiError(409, "NOT_READY", "Slet en gammel tilføjelse for at få plads.")
            changed = db.execute("UPDATE surprises SET body=? WHERE id=? AND json_extract(body,'$.revision')=?",
                                 (encoded(saved), job["id"], job["revision"])).rowcount
            if not changed:
                raise ApiError(409, "REQUEST_REUSED", "Aktiviteten blev ændret. Opdatér listen.")
            db.execute("INSERT OR IGNORE INTO library.addons VALUES(?,?)", (job["id"], encoded(addon)))
        return saved

    def mutate(self, bot, key, body):
        if body.get("action") == "create":
            return self.create(bot, key, body)
        job = self.one(bot, key)
        if body.get("revision") != job["revision"]:
            raise ApiError(409, "REQUEST_REUSED", "Aktiviteten blev ændret. Opdatér listen.")
        action = body.get("action")
        if action == "progress":
            index, done = body.get("index"), body.get("done")
            if (job["state"] not in ("ready", "kept") or type(index) is not int or type(done) is not bool
                    or not 0 <= index < len(job.get("steps", []))):
                raise ApiError(422, "INVALID_INPUT", "Vælg et punkt fra denne aktivitet.")
            completed = set(job.get("completed", []))
            if done:
                completed.add(index)
            else:
                completed.discard(index)
            return self.save({**job, "completed": sorted(completed)})
        if action == "keep":
            return self.keep(job)
        if action == "revise":
            if job["state"] in ("building", "kept"):
                raise ApiError(409, "NOT_READY", "Lav en ny idé, eller vent til agenten er færdig.")
            return self.save({**job, "brief": text(body.get("brief"), 650), "state": "queued",
                              "addon": None, "bytes": 0, "checks": [], "note": "Den rettede idé venter på ledig PC-tid."})
        if action == "remove":
            if job["state"] == "building":
                raise ApiError(409, "NOT_READY", "Vent til arbejdet er færdigt, før du sletter aktiviteten.")
            with closing(self.db()) as db, db:
                db.execute("ATTACH DATABASE ? AS library", (str(self.root / "addons.sqlite3"),))
                db.execute("CREATE TABLE IF NOT EXISTS library.addons(id TEXT PRIMARY KEY,body TEXT NOT NULL)")
                db.execute("CREATE TABLE IF NOT EXISTS library.addon_web_files(id TEXT PRIMARY KEY,body BLOB NOT NULL)")
                db.execute("BEGIN IMMEDIATE")
                row = db.execute("SELECT body FROM library.addons WHERE id=?", (job["id"],)).fetchone()
                if row and json.loads(row[0]) == job.get("addon"):
                    db.execute("DELETE FROM library.addon_web_files WHERE id=?", (job["id"],))
                    db.execute("DELETE FROM library.addons WHERE id=?", (job["id"],))
                deleted = db.execute("DELETE FROM surprises WHERE id=? AND bot=? AND json_extract(body,'$.revision')=?",
                                     (job["id"], job["botID"], job["revision"])).rowcount
                if not deleted:
                    raise ApiError(409, "REQUEST_REUSED", "Aktiviteten blev ændret. Opdatér listen.")
            return {"removed": True}
        raise ApiError(422, "INVALID_INPUT", "Vælg en handling på aktiviteten.")

    def tick(self):
        with closing(self.db()) as db:
            old = list(db.execute("SELECT body FROM surprises WHERE json_extract(body,'$.state')='building' "
                                  "AND json_extract(body,'$.updated')<?", (time() - 300,)))
            for row in old:
                self.save({**json.loads(row[0]), "state": "queued"})
            row = db.execute("SELECT bot,id FROM surprises WHERE json_extract(body,'$.state')='queued' ORDER BY rowid LIMIT 1").fetchone()
        if row and not self.stopped.is_set():
            self.run(*row)

    def start(self):
        if self.thread and self.thread.is_alive():
            return
        self.stopped.clear()

        def work():
            while not self.stopped.wait(20):
                try:
                    self.tick()
                except (ApiError, OSError, sqlite3.Error):
                    logging.getLogger(__name__).exception("Kunne ikke opdatere landsbyaktiviteter.")

        self.thread = Thread(target=work, name="FadedAI-surprises", daemon=True)
        self.thread.start()

    def stop(self):
        self.stopped.set()
        if self.thread:
            self.thread.join(timeout=2)


def register_village_surprises(app, settings, authorize, generate, is_idle=None):
    service = VillageSurprises(settings.output_root, generate, is_idle)

    def paired(request: Request, response: Response):
        authorize(request, settings)
        response.headers["Cache-Control"] = "no-store"

    router = APIRouter(prefix="/api/modules/v1/village-surprises", dependencies=[Depends(paired)], include_in_schema=False)

    @router.get("")
    def items(bot_id: str):
        return service.list(bot_id)

    @router.put("/{job_id}")
    def mutate(job_id: str, bot_id: str, body: dict = Body(...)):
        return service.mutate(bot_id, job_id, body)

    app.include_router(router)
    return service

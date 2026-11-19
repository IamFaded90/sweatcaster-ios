"""Persist approved Instagram posts and collect their follow-up on the paired PC."""

from base64 import b64encode
from contextlib import closing
from datetime import datetime, timezone
import json
import logging
import math
import sqlite3
from threading import Event, Thread
from time import time
from uuid import NAMESPACE_URL, uuid4, uuid5

from fastapi import Body

from sweatcaster.dto import ApiError
from sweatcaster.instagram_publishing import InstagramPublishing, agent_library, approved_content, draft_id, profile, tool


METRICS = {"reach": "Rækkevidde", "views": "Visninger", "likes": "Synes godt om",
           "comments": "Kommentarer", "saved": "Gemt", "shares": "Delinger"}
WRITE_LEASE_SECONDS = 300
SUMMARY_COLUMNS = """id,state,account,username,caption,due,follow,posted,media,note,notify,
                     report_state,checked,metrics,report_note,email_state"""


def timestamp(value):
    if type(value) not in (int, float) or not 0 < value <= 253402300799 or not math.isfinite(value):
        raise ApiError(422, "INVALID_INPUT", "Vælg en gyldig dato og et klokkeslæt.")
    return int(value)


def counters(media):
    numbers = {}
    rows = media.get("data")
    for row in rows if isinstance(rows, list) else ():
        if not isinstance(row, dict) or row.get("name") not in METRICS:
            continue
        total, values = row.get("total_value"), row.get("values")
        value = total.get("value") if isinstance(total, dict) else None
        if value is None and isinstance(values, list) and len(values) == 1 and isinstance(values[0], dict):
            value = values[0].get("value")
        if type(value) is int and value >= 0:
            numbers[row["name"]] = value
    return numbers


def insights(library, account, media_id):
    connection = library.connection("instagram")
    if not connection or profile(library, connection)["accountID"] != account:
        raise ApiError(409, "NOT_READY", "Forbind den Instagram-konto, hvor opslaget blev udgivet.")
    try:
        raw = tool(library, connection, "INSTAGRAM_GET_IG_MEDIA_INSIGHTS", {
            "ig_media_id": media_id, "metric": list(METRICS),
        })
        numbers = counters(raw)
    except ApiError:
        numbers = {}
    if numbers:
        return numbers
    raw = tool(library, connection, "INSTAGRAM_GET_IG_MEDIA", {
        "ig_media_id": media_id, "fields": "id,like_count,comments_count",
    })
    if raw.get("id") != media_id:
        return {}
    return {name: raw[field] for name, field in (("likes", "like_count"), ("comments", "comments_count"))
            if type(raw.get(field)) is int and raw[field] >= 0}


class InstagramSchedule:
    def __init__(self, library, root, clock=time):
        self.library, self.root, self.clock = library, root, clock
        self.database = root / "instagram-publications.sqlite3"
        self.stop_event = Event()
        self.changed = Event()
        self.worker = None

    def db(self):
        db = InstagramPublishing(self.library, self.root).db()
        db.execute("""CREATE TABLE IF NOT EXISTS ig_schedule (
            post_key TEXT PRIMARY KEY, project TEXT NOT NULL, bot TEXT NOT NULL, id TEXT NOT NULL,
            digest TEXT NOT NULL, account TEXT NOT NULL, username TEXT NOT NULL, caption TEXT NOT NULL,
            photo BLOB, url TEXT, due INTEGER NOT NULL, follow INTEGER, notify INTEGER NOT NULL,
            state TEXT NOT NULL DEFAULT 'scheduled', posted INTEGER, media TEXT, note TEXT, report_state TEXT,
            checked INTEGER, metrics TEXT, report_note TEXT, email_state TEXT NOT NULL, next_try REAL NOT NULL,
            lease TEXT, lease_until REAL, attempts INTEGER NOT NULL DEFAULT 0)""")
        db.execute("CREATE INDEX IF NOT EXISTS ig_schedule_due ON ig_schedule(project,next_try)")
        return db

    def start(self):
        if self.worker and self.worker.is_alive():
            return
        self.stop_event.clear()
        self.worker = Thread(target=self.run, daemon=True, name="fadedai-instagram-schedule")
        self.worker.start()

    def stop(self):
        self.stop_event.set()
        self.changed.set()
        if self.worker:
            self.worker.join(2)

    def run(self):
        while not self.stop_event.is_set():
            self.changed.clear()
            try:
                if self.tick():
                    continue
            except Exception:
                logging.getLogger(__name__).exception("Instagram schedule worker could not complete its iteration")
            self.changed.wait(10)

    def publisher(self, bot):
        return InstagramPublishing(agent_library(self.library, bot), self.root)

    @staticmethod
    def view(row, identifier):
        if not row:
            return {"id": identifier, "state": "draft"}
        report = None
        if row["report_state"]:
            report = {"state": row["report_state"], "checkedAt": row["checked"], "note": row["report_note"],
                      "metrics": json.loads(row["metrics"]) if row["metrics"] else None}
        return {"id": row["id"], "accountID": row["account"], "username": row["username"], "caption": row["caption"],
                "state": row["state"], "publishAt": row["due"], "followUpAt": row["follow"], "publishedAt": row["posted"],
                "mediaID": row["media"], "note": row["note"], "report": report, "notifyEmail": bool(row["notify"]),
                "emailState": row["email_state"]}

    def get(self, bot, identifier):
        key = self.publisher(bot).library.owner + "/" + draft_id(identifier)
        with closing(self.db()) as db:
            row = db.execute("SELECT " + SUMMARY_COLUMNS + " FROM ig_schedule WHERE post_key=?", (key,)).fetchone()
            return self.view(row, draft_id(identifier))

    def listing(self, bot):
        with closing(self.db()) as db:
            rows = db.execute("SELECT " + SUMMARY_COLUMNS + " FROM ig_schedule WHERE project=? AND bot=? ORDER BY due DESC",
                              (self.library.owner, draft_id(bot)))
            return {"items": [self.view(row, row["id"]) for row in rows]}

    def add(self, bot, body):
        bot, identifier = draft_id(bot), draft_id(body.get("id"))
        posts = self.publisher(bot)
        key = posts.library.owner + "/" + identifier
        account, caption, photo, url, digest = approved_content(body)
        due = timestamp(body.get("publishAt"))
        follow = timestamp(body["followUpAt"]) if body.get("followUpAt") is not None else None
        notify = body.get("notifyEmail", False)
        if (follow is not None and follow <= due) or type(notify) is not bool or (notify and follow is None):
            raise ApiError(422, "INVALID_INPUT", "Vælg et tidspunkt for opfølgning efter udgivelsen.")
        identity = (digest, due, follow, notify)
        def existing(db):
            old = db.execute("SELECT * FROM ig_schedule WHERE post_key=?", (key,)).fetchone()
            if old and (old["digest"], old["due"], old["follow"], old["notify"]) != identity:
                raise ApiError(409, "REQUEST_REUSED", "Denne kladde har allerede en anden plan.")
            return old
        with closing(self.db()) as db:
            old = existing(db)
            if old:
                return self.view(old, identifier)
        if due <= self.clock():
            raise ApiError(422, "INVALID_INPUT", "Vælg et udgivelsestidspunkt i fremtiden.")
        status = posts.status()
        if status.get("accountID") != account:
            raise ApiError(409, "NOT_READY", "Forbind først agentens valgte Instagram-konto.")
        with closing(self.db()) as db, db:
            db.execute("BEGIN IMMEDIATE")
            old = existing(db)
            if old:
                return self.view(old, identifier)
            if db.execute("SELECT 1 FROM posts WHERE id=?", (key,)).fetchone():
                raise ApiError(409, "REQUEST_REUSED", "Udgivelsen er allerede startet for denne kladde.")
            db.execute("""INSERT INTO ig_schedule(post_key,project,bot,id,digest,account,username,caption,photo,url,
                due,follow,notify,report_state,email_state,next_try) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)""",
                (key, self.library.owner, bot, identifier, digest, account, status["username"], caption, photo, url,
                 due, follow, int(notify), "pending" if follow else None, "pending" if notify else "off", due))
        self.changed.set()
        return self.get(bot, identifier)

    def cancel(self, bot, identifier):
        key = self.publisher(bot).library.owner + "/" + draft_id(identifier)
        with closing(self.db()) as db, db:
            db.execute("BEGIN IMMEDIATE")
            row = db.execute("SELECT state FROM ig_schedule WHERE post_key=?", (key,)).fetchone()
            if not row:
                raise ApiError(404, "NOT_FOUND", "Der er intet planlagt opslag at annullere.")
            if row["state"] not in ("cancelled", "scheduled"):
                raise ApiError(409, "NOT_READY", "Udgivelsen er allerede startet. Opdatér status.")
            db.execute("""UPDATE ig_schedule SET state='cancelled',photo=NULL,url=NULL,note=NULL,report_state=NULL,
                          email_state='off',lease=NULL WHERE post_key=?""", (key,))
        return self.get(bot, identifier)

    def claim(self):
        now = self.clock()
        lease = uuid4().hex
        with closing(self.db()) as db, db:
            db.execute("BEGIN IMMEDIATE")
            row = db.execute("""SELECT * FROM ig_schedule WHERE project=? AND next_try<=?
                AND (lease IS NULL OR lease_until<=?) AND (state IN ('scheduled','publishing','unconfirmed')
                OR (state='published' AND (report_state='pending' OR email_state='pending')))
                ORDER BY next_try LIMIT 1""", (self.library.owner, now, now)).fetchone()
            if not row:
                return None, None
            db.execute("""UPDATE ig_schedule SET lease=?, lease_until=?, attempts=attempts+1,
                state=CASE WHEN state='scheduled' THEN 'publishing' ELSE state END WHERE post_key=?""",
                (lease, now + WRITE_LEASE_SECONDS, row["post_key"]))
            return row, lease

    def update(self, row, lease, **changes):
        changes.update(lease=None, lease_until=None)
        sql = ", ".join(name + "=?" for name in changes)
        with closing(self.db()) as db, db:
            db.execute("UPDATE ig_schedule SET " + sql + " WHERE post_key=? AND lease=?",
                       (*changes.values(), row["post_key"], lease))

    def tick(self):
        row, lease = self.claim()
        if row is None:
            return False
        posts = self.publisher(row["bot"])
        if row["state"] != "published":
            self.post(row, lease, posts)
        elif row["report_state"] == "pending":
            self.follow_up(row, lease, posts)
        else:
            self.email(row, lease)
        return True

    def post(self, row, lease, posts):
        now = int(self.clock())
        receipt = posts.receipt(row["id"])
        if row["state"] != "unconfirmed" and receipt["state"] not in ("published", "publishing"):
            body = {"id": row["id"], "accountID": row["account"], "caption": row["caption"], "approved": True}
            if row["photo"] is not None:
                body["image_jpeg"] = b64encode(row["photo"]).decode("ascii")
            else:
                body["imageURL"] = row["url"]
            try:
                receipt = posts.publish(body, scheduled=True)
            except ApiError as exc:
                receipt = posts.receipt(row["id"])
                if receipt["state"] not in ("published", "publishing"):
                    if exc.status_code == 422 or exc.code == "REQUEST_REUSED":
                        self.update(row, lease, state="failed", photo=None, url=None, note=str(exc),
                                    report_state=None, email_state="off")
                    else:
                        wait = min(1800, 30 * (1 + row["attempts"]))
                        self.update(row, lease, state="scheduled", note=str(exc), next_try=now + wait)
                    return
        if receipt["published"]:
            self.update(row, lease, state="published", posted=now, media=receipt.get("mediaID"), note=None,
                        url=None, photo=None, next_try=row["follow"] or now, attempts=0)
        else:
            self.update(row, lease, state="unconfirmed", note="Afventer Instagrams kvittering.",
                        next_try=now + min(3600, 60 * (1 + row["attempts"])), photo=None, url=None)

    def follow_up(self, row, lease, posts):
        now = int(self.clock())
        metrics = {}
        note = "Instagram har bekræftet udgivelsen uden et opslag-ID til målingerne."
        if row["media"]:
            try:
                metrics = insights(posts.library, row["account"], row["media"])
                note = None if metrics else "Instagram viser ingen målinger for dette opslag endnu."
            except ApiError as exc:
                note = ("Forbind agentens oprindelige Instagram-konto for at hente målingerne."
                        if exc.status_code == 409 else "Instagram kunne ikke levere målinger for dette opslag.")
            if not metrics and row["attempts"] < 2:
                self.update(row, lease, next_try=now + 300, report_note=note)
                return
        self.update(row, lease, report_state="ready" if metrics else "unavailable", checked=now,
                    report_note=note, metrics=json.dumps(metrics) if metrics else None, next_try=now, attempts=0)

    def email(self, row, lease):
        from sweatcaster.agent_owner_notice import send_owner_notice
        numbers = json.loads(row["metrics"]) if row["metrics"] else {}
        lines = ["Opfølgning på dit opslag fra @" + row["username"], row["caption"],
                 "Målt " + datetime.fromtimestamp(row["checked"], timezone.utc).strftime("%Y-%m-%d %H:%M UTC")]
        lines += [f"{label}: {numbers[metric]}" for metric, label in METRICS.items() if metric in numbers]
        if row["report_note"]:
            lines.append(row["report_note"])
        token = str(uuid5(NAMESPACE_URL, row["post_key"] + "/report"))
        result = send_owner_notice(self.library, token, "Instagram-opfølgning fra @" + row["username"], "\n".join(lines))
        if result == "unavailable" and row["attempts"] < 6:
            self.update(row, lease, email_state="pending", next_try=self.clock() + 300 * (1 + row["attempts"]))
        else:
            self.update(row, lease, email_state={"sent": "sent", "unavailable": "failed"}.get(result, "unconfirmed"))


def register_schedule(router, service):
    @router.put("/instagram/schedule")
    def add(body: dict = Body(...), bot_id: str = ""):
        return service.add(bot_id, body)

    @router.get("/instagram/schedule")
    def listing(bot_id: str = ""):
        return service.listing(bot_id)

    @router.get("/instagram/schedule/{identifier}")
    def get(identifier: str, bot_id: str = ""):
        return service.get(bot_id, identifier)

    @router.put("/instagram/schedule/{identifier}/cancel")
    def cancel(identifier: str, bot_id: str = ""):
        return service.cancel(bot_id, identifier)

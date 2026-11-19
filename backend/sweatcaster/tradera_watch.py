"""Durable, read-only price watches for an agent on the paired PC."""

from contextlib import closing
from decimal import Decimal, InvalidOperation
from pathlib import Path
import logging
import sqlite3
from threading import Event, Thread
from time import time
from uuid import NAMESPACE_URL, UUID, uuid4, uuid5

from fastapi import APIRouter, Body, Depends, Request, Response

from sweatcaster import tradera_api, tradera_mail
from sweatcaster.agent_owner_notice import send_owner_notice
from sweatcaster.dto import ApiError


INTERVAL = 30 * 60
MAX_PRICE_AGE = 6 * 3600
ACTIVE = "('waitingMail','watching','error','currencyMismatch')"


def uuid_text(text):
    try:
        return str(UUID(text))
    except (AttributeError, TypeError, ValueError) as exc:
        raise ApiError(422, "INVALID_INPUT", "Vælg en agent og en gyldig prisvagt.") from exc


def cents(value):
    try:
        if type(value) not in (int, float) or len(str(value)) > 14:
            raise ValueError
        amount = Decimal(str(value)) * 100
        if not amount.is_finite() or not 1 <= amount <= 99_999_999_999 or amount != amount.to_integral_value():
            raise ValueError
        return int(amount)
    except (ValueError, InvalidOperation) as exc:
        raise ApiError(422, "INVALID_INPUT", "Angiv et positivt beløb med højst to decimaler.") from exc


class PriceWatches:
    def __init__(self, root, library, *, source=None, clock=time, notify=send_owner_notice):
        self.database = Path(root) / "tradera-watches.sqlite3"
        self.library = library
        self.source = source or tradera_api.PriceSource()
        self.clock = clock
        self.notify = notify
        self.stopped = Event()
        self.thread = None

    def db(self):
        self.database.parent.mkdir(parents=True, exist_ok=True)
        db = sqlite3.connect(self.database, timeout=5)
        db.row_factory = sqlite3.Row
        db.execute("""CREATE TABLE IF NOT EXISTS watches (
            bot TEXT, id TEXT, url TEXT NOT NULL, item INTEGER, limitCents INTEGER, currency TEXT, notify INTEGER,
            created REAL, state TEXT, due REAL, ticket TEXT, checked REAL, triggered REAL, title TEXT,
            price INTEGER, note TEXT, email TEXT, emailDue REAL, source TEXT NOT NULL DEFAULT 'api',
            mailAccount TEXT, priceAt REAL, priceCurrency TEXT, PRIMARY KEY(bot,id))""")
        if "source" not in {col[1] for col in db.execute("PRAGMA table_info(watches)")}:
            with db:
                db.execute("BEGIN IMMEDIATE")
                if "source" not in {col[1] for col in db.execute("PRAGMA table_info(watches)")}:
                    for definition in ("source TEXT NOT NULL DEFAULT 'api'", "mailAccount TEXT", "priceAt REAL", "priceCurrency TEXT"):
                        db.execute("ALTER TABLE watches ADD COLUMN " + definition)
        return db

    def create(self, bot, identifier, body):
        bot, identifier = uuid_text(bot), uuid_text(identifier)
        item, url = tradera_api.listing(body.get("url"))
        amount = cents(body.get("threshold"))
        currency = body.get("currency")
        notify = body.get("notifyByEmail", False)
        source = body.get("source", "api")
        if source not in ("api", "traderaMail"):
            raise ApiError(422, "INVALID_INPUT", "Vælg en priskilde.")
        if currency not in ("SEK", "DKK") or type(notify) is not bool:
            raise ApiError(422, "INVALID_INPUT", "Vælg SEK eller DKK og en gyldig beskedindstilling.")
        now = self.clock()
        pin = tradera_mail.account(self.library) if source == "traderaMail" else None
        with closing(self.db()) as db, db:
            db.execute("BEGIN IMMEDIATE")
            current = db.execute("SELECT * FROM watches WHERE bot=? AND id=?", (bot, identifier)).fetchone()
            if current:
                if (current["state"] == "cancelled" or
                    (current["item"], current["limitCents"], current["currency"], current["notify"], current["source"]) !=
                        (item, amount, currency, int(notify), source)):
                    raise ApiError(409, "REQUEST_REUSED", "Denne kladde bruges allerede. Start en ny prisvagt.")
                return self.public(current)
            if source == "traderaMail" and not pin:
                raise ApiError(409, "NOT_READY", "Forbind din Gmail i FadedAI for at følge Traderas mails.")
            db.execute("""INSERT INTO watches(bot,id,url,item,limitCents,currency,notify,created,state,due,email,source,mailAccount)
                    VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)""",
                       (bot, identifier, url, item, amount, currency, int(notify), now,
                        "waitingMail" if source == "traderaMail" else "watching", now, "waiting" if notify else "off", source, pin))
        # Gmail through Composio can take longer than a phone request. The PC worker owns this read.
        if source == "api":
            self.check(bot, identifier)
        return self.one(bot, identifier)

    def public(self, row):
        observed = row["priceAt"] if row["source"] == "traderaMail" else row["checked"]
        fresh = observed is not None and observed >= self.clock() - MAX_PRICE_AGE
        return {"id": row["id"], "url": row["url"], "title": row["title"] if fresh and row["title"] else "Tradera-annonce",
                "threshold": row["limitCents"] / 100, "currency": row["currency"], "state": row["state"],
                "source": row["source"], "priceAt": observed if row["price"] is not None and fresh else None,
                "price": row["price"] if fresh else None,
                "priceCurrency": (row["priceCurrency"] or "SEK") if fresh and row["price"] is not None else None,
                "lastChecked": row["checked"], "alertedAt": row["triggered"], "notifyByEmail": bool(row["notify"]),
                "emailStatus": row["email"], "note": row["note"] if fresh or row["state"] in ("error", "waitingMail") else None}

    def one(self, bot, identifier):
        bot, identifier = uuid_text(bot), uuid_text(identifier)
        with closing(self.db()) as db:
            row = db.execute("SELECT * FROM watches WHERE bot=? AND id=?", (bot, identifier)).fetchone()
        return self.public(row) if row else None

    def list(self, bot):
        bot = uuid_text(bot)
        with closing(self.db()) as db:
            rows = db.execute("SELECT * FROM watches WHERE bot=? AND state<>'cancelled' ORDER BY created DESC", (bot,))
            return {"watches": [self.public(row) for row in rows]}

    def cancel(self, bot, identifier):
        bot, identifier = uuid_text(bot), uuid_text(identifier)
        with closing(self.db()) as db, db:
            db.execute("""UPDATE watches SET state='cancelled',ticket=NULL,title=NULL,price=NULL,note=NULL,
                       emailDue=NULL,mailAccount=NULL,priceCurrency=NULL,priceAt=NULL WHERE bot=? AND id=?""", (bot, identifier))
        return {"cancelled": True}

    def check(self, bot, identifier):
        now = self.clock()
        ticket = str(uuid4())
        with closing(self.db()) as db, db:
            claimed = db.execute("UPDATE watches SET due=? + CASE WHEN source='traderaMail' THEN 900 ELSE 120 END,"
                                 "ticket=? WHERE bot=? AND id=? AND state IN " + ACTIVE
                                 + " AND due<=?", (now, ticket, bot, identifier, now)).rowcount
            if not claimed:
                return
            row = db.execute("SELECT * FROM watches WHERE bot=? AND id=?", (bot, identifier)).fetchone()
        try:
            if row["source"] == "traderaMail":
                since = max(row["created"], now - MAX_PRICE_AGE, row["priceAt"] or 0)
                quote = tradera_mail.check(self.library, row["mailAccount"], row["item"], since, now, row["currency"], self.source)
            else:
                quote = self.source.check(row["item"], row["currency"])
        except ApiError as exc:
            quote = {"state": "error", "note": str(exc)}
        state = quote["state"]
        if state == "watching" and quote["compared"] * 100 < row["limitCents"]:
            state = "triggered"
        claimed_at = self.clock()
        triggered = claimed_at if state == "triggered" else None
        with closing(self.db()) as db, db:
            db.execute("""UPDATE watches SET checked=?,due=?,ticket=NULL,state=?,title=?,price=?,note=?,triggered=?,
                          priceAt=COALESCE(?,priceAt),priceCurrency=?,emailDue=? WHERE bot=? AND id=? AND ticket=?""",
                       (claimed_at, claimed_at + INTERVAL, state, quote.get("title"), quote.get("price"), quote.get("note"),
                        triggered, quote.get("priceAt"), quote.get("priceCurrency"), triggered if row["notify"] else None,
                        bot, identifier, ticket))

    def deliver(self, bot, identifier):
        now = self.clock()
        with closing(self.db()) as db, db:
            claimed = db.execute("""UPDATE watches SET emailDue=? WHERE bot=? AND id=? AND state='triggered'
                                AND email IN ('waiting','unavailable') AND emailDue<=?""",
                                 (now + 300, bot, identifier, now)).rowcount
            if not claimed:
                return
            row = db.execute("SELECT * FROM watches WHERE bot=? AND id=?", (bot, identifier)).fetchone()
        limit = Decimal(row["limitCents"]) / 100
        # Message remains identical across PC restarts, delayed delivery, and removal of old cached quotes.
        subject = "Din Tradera-prisvagt har fundet en pris under grænsen"
        text = (f"Din prisvagt registrerede en annoncepris under {limit:.2f} {row['currency']} uden fragt. "
                f"Åbn annoncen for den aktuelle pris.\n\n{row['url']}")
        if row["source"] == "traderaMail":
            text = (f"Tradera har sendt en mail med en pris under {limit:.2f} {row['currency']} for din annonce. "
                    f"Åbn annoncen for den aktuelle pris og fragt.\n\n{row['url']}")
        token = uuid5(NAMESPACE_URL, "fadedai/tradera/alert/" + bot + "/" + identifier)
        try:
            same_account = row["source"] != "traderaMail" or tradera_mail.account(self.library) == row["mailAccount"]
            outcome = self.notify(self.library, token, subject, text) if same_account else "unavailable"
        except (ApiError, OSError, ValueError):
            outcome = "unavailable"
        with closing(self.db()) as db, db:
            db.execute("""UPDATE watches SET email=?,emailDue=? WHERE bot=? AND id=? AND state='triggered'""",
                       (outcome, now + INTERVAL if outcome == "unavailable" else None, bot, identifier))

    def tick(self):
        if not self.database.exists():
            return
        now = self.clock()
        with closing(self.db()) as db, db:
            db.execute("""UPDATE watches SET price=NULL,title=NULL,note=NULL
                       WHERE checked<? AND price IS NOT NULL""", (now - MAX_PRICE_AGE,))
            due = db.execute("SELECT bot,id FROM watches WHERE state IN " + ACTIVE +
                             " AND due<=? ORDER BY due LIMIT 8", (now,)).fetchall()
            mail = db.execute("SELECT bot,id FROM watches WHERE state='triggered' AND emailDue<=? LIMIT 8", (now,)).fetchall()
        for bot, identifier in due:
            if self.stopped.is_set():
                return
            self.check(bot, identifier)
        for bot, identifier in mail:
            if self.stopped.is_set():
                return
            self.deliver(bot, identifier)

    def start(self):
        if self.thread and self.thread.is_alive():
            return
        self.stopped.clear()
        def work():
            while not self.stopped.is_set():
                try:
                    self.tick()
                except Exception:
                    logging.getLogger(__name__).warning("Tradera-prisvagten prøver igen ved næste kontrol.")
                self.stopped.wait(20)
        self.thread = Thread(name="tradera-price-watch", target=work, daemon=True)
        self.thread.start()

    def stop(self):
        self.stopped.set()
        if self.thread:
            self.thread.join(timeout=2)


def register_tradera(app, settings, authorize, library):
    watches = PriceWatches(settings.output_root, library)

    def paired(request: Request, response: Response):
        authorize(request, settings)
        response.headers["Cache-Control"] = "no-store"

    router = APIRouter(prefix="/api/modules/v1/tradera", dependencies=[Depends(paired)], include_in_schema=False)

    @router.get("/status")
    def status():
        try:
            mail_ready = bool(tradera_mail.account(library))
        except (ApiError, OSError, ValueError):
            mail_ready = False
        return {"configured": tradera_api.credentials() is not None, "mailAvailable": mail_ready}

    @router.put("/settings")
    def configure(body: dict = Body(...)):
        tradera_api.save_credentials(body.get("appID"), body.get("appKey"))
        # A valid setup also restarts pending watches which previously lacked a key.
        if watches.database.exists():
            with closing(watches.db()) as db, db:
                db.execute("UPDATE watches SET due=0 WHERE state='error' AND ticket IS NULL")
        return {"configured": True}

    @router.get("/watches")
    def listing(bot_id: str):
        return watches.list(bot_id)

    @router.get("/watches/{identifier}")
    def lookup(identifier: str, bot_id: str):
        return {"watch": watches.one(bot_id, identifier)}

    @router.put("/watches/{identifier}")
    def create(identifier: str, bot_id: str, body: dict = Body(...)):
        return watches.create(bot_id, identifier, body)

    @router.put("/watches/{identifier}/cancel")
    def cancel(identifier: str, bot_id: str):
        return watches.cancel(bot_id, identifier)

    app.include_router(router)
    return watches

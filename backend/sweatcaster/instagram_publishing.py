"""One approved photo per Instagram draft, published through the paired PC's Composio account."""

from contextlib import closing
from copy import copy
from hashlib import sha256
from ipaddress import ip_address
import json
import re
import sqlite3
from time import sleep, time
from urllib.parse import urlsplit
from uuid import NAMESPACE_URL, UUID, uuid4, uuid5

from fastapi import Body

from sweatcaster.dto import ApiError
from sweatcaster.instagram_photo import decode_photo, stage_photo


TOOL_VERSION = "20261112_00"
PROFILE = "INSTAGRAM_GET_USER_INFO"
CREATE = "INSTAGRAM_POST_IG_USER_MEDIA"
PUBLISH = "INSTAGRAM_POST_IG_USER_MEDIA_PUBLISH"
CONTAINER_STATUS = "INSTAGRAM_GET_POST_STATUS"
NUMERIC = re.compile(r"[0-9]{1,30}")
UNCERTAIN = "Instagram har muligvis udgivet opslaget. Tjek profilen og hent status igen."


def draft_id(value):
    try:
        return str(UUID(value))
    except (TypeError, ValueError, AttributeError) as exc:
        raise ApiError(422, "INVALID_INPUT", "Åbn en gyldig Instagram-kladde.") from exc


def agent_library(library, bot_id):
    try:
        bot = str(UUID(bot_id))
    except (TypeError, ValueError, AttributeError) as exc:
        raise ApiError(422, "INVALID_INPUT", "Åbn Instagram hos den agent, som skal have kontoen.") from exc
    scoped = copy(library)
    scoped.owner = "fadedai-instagram-" + uuid5(NAMESPACE_URL, library.owner + "/" + bot).hex
    return scoped


def image_url(value):
    if isinstance(value, str) and len(value) <= 4096 and not any(c.isspace() or ord(c) < 32 for c in value):
        try:
            url = urlsplit(value)
            host = (url.hostname or "").lower().rstrip(".")
            if (url.scheme == "https" and url.port in (None, 443) and url.username is None
                    and url.password is None and not url.fragment and "\\" not in value
                    and "." in host and not host.endswith((".local", ".localhost", ".internal", ".lan", ".ts.net"))
                    and re.fullmatch(r"[a-z0-9][a-z0-9.-]*[a-z0-9]", host)):
                try:
                    public = ip_address(host).is_global
                except ValueError:
                    public = all(re.fullmatch(r"(?!-)[a-z0-9-]{1,63}(?<!-)", label) for label in host.split(".")) and bool(
                        re.fullmatch(r"[a-z][a-z0-9-]+", host.rsplit(".", 1)[1]))
                if public:
                    return value
        except ValueError:
            pass
    raise ApiError(422, "INVALID_INPUT", "Vælg et foto eller et offentligt HTTPS-link direkte til JPEG-billedet.")


def tool(library, connection, name, args):
    result = library.request("POST", "/tools/execute/" + name, version="v3.1", payload={
        "arguments": args, "connected_account_id": connection, "user_id": library.owner, "version": TOOL_VERSION,
    })
    payload = result.get("data")
    if result.get("successful") is True and isinstance(payload, dict) and not payload.get("error"):
        return payload
    message = ("Instagram kunne ikke læse profilen. Forbind en Creator- eller virksomhedskonto igen." if name == PROFILE
               else "Instagram kunne ikke klargøre fotoet. Tjek billedet og kontoens tilladelser.")
    raise ApiError(502, "NOT_READY", message)


def numeric(value):
    return isinstance(value, str) and NUMERIC.fullmatch(value)


def profile(library, connection):
    result = tool(library, connection, PROFILE, {"ig_user_id": "me", "fields": "id,user_id,username,account_type"})
    identity = result.get("user_id") or result.get("id")
    username = result.get("username")
    account_type = str(result.get("account_type", "")).upper()
    if (not numeric(identity) or not isinstance(username, str) or not re.fullmatch(r"[a-zA-Z0-9_.]{1,30}", username)
            or account_type == "PERSONAL"):
        raise ApiError(409, "NOT_READY", "Vælg en Creator- eller virksomhedskonto i Instagram, og forbind igen.")
    return {"connected": True, "accountID": identity, "username": username}


def approved_content(body):
    if body.get("approved") is not True:
        raise ApiError(422, "INVALID_INPUT", "Godkend opslaget i chatten først.")
    account, caption = body.get("accountID"), body.get("caption")
    if not numeric(account) or not isinstance(caption, str) or len(caption) > 2200 or "\0" in caption:
        raise ApiError(422, "INVALID_INPUT", "Vælg en Instagram-konto og en tekst på højst 2.200 tegn.")
    if ("imageURL" in body) == ("image_jpeg" in body):
        raise ApiError(422, "INVALID_INPUT", "Vælg ét foto til opslaget.")
    photo = decode_photo(body["image_jpeg"]) if "image_jpeg" in body else None
    url = image_url(body["imageURL"]) if "imageURL" in body else None
    source = ["jpeg", sha256(photo).hexdigest()] if photo is not None else ["url", url]
    digest = sha256(json.dumps([account, caption, source], ensure_ascii=False).encode()).hexdigest()
    return account, caption, photo, url, digest


class InstagramPublishing:
    def __init__(self, library, root):
        self.library = library
        self.database = root / "instagram-publications.sqlite3"

    def status(self):
        connection = self.library.connection("instagram")
        return profile(self.library, connection) if connection else {"connected": False}

    def db(self):
        self.database.parent.mkdir(parents=True, exist_ok=True)
        db = sqlite3.connect(self.database, timeout=5)
        db.row_factory = sqlite3.Row
        db.execute("""CREATE TABLE IF NOT EXISTS posts (
            id TEXT PRIMARY KEY, digest TEXT NOT NULL, account TEXT NOT NULL, phase TEXT NOT NULL,
            lease TEXT, modified REAL NOT NULL, container TEXT, media TEXT)""")
        return db

    @staticmethod
    def receipt_result(row):
        state = row["phase"] if row else "draft"
        return {"state": state, "published": state == "published", "mediaID": row["media"] if row else None}

    def receipt(self, identifier):
        with closing(self.db()) as db:
            row = db.execute("SELECT * FROM posts WHERE id=?", (self.library.owner + "/" + draft_id(identifier),)).fetchone()
        if row and row["phase"] == "publishing" and row["container"]:
            try:
                connection = self.library.connection("instagram")
                if connection and profile(self.library, connection)["accountID"] == row["account"]:
                    status = self.container_status(connection, row["container"])
                    if status == "PUBLISHED":
                        with closing(self.db()) as db, db:
                            db.execute("UPDATE posts SET phase='published' WHERE id=? AND phase='publishing'", (row["id"],))
                            row = db.execute("SELECT * FROM posts WHERE id=?", (row["id"],)).fetchone()
            except ApiError:
                pass  # A pending local receipt survives disconnection and can be checked later.
        return self.receipt_result(row)

    def reserve(self, identifier, digest, account, scheduled=False):
        lease = uuid4().hex
        with closing(self.db()) as db, db:
            db.execute("BEGIN IMMEDIATE")
            if not scheduled and db.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name='ig_schedule'").fetchone():
                if db.execute("SELECT 1 FROM ig_schedule WHERE post_key=?", (identifier,)).fetchone():
                    raise ApiError(409, "REQUEST_REUSED", "Kladden har en planlagt udgivelse. Åbn dens status.")
            row = db.execute("SELECT * FROM posts WHERE id=?", (identifier,)).fetchone()
            if row:
                if row["digest"] != digest:
                    raise ApiError(409, "REQUEST_REUSED", "Billedet, kontoen eller teksten er ændret. Brug en ny kladde.")
                if row["phase"] != "preparing":
                    return row, None
                if time() - row["modified"] < 180:
                    raise ApiError(409, "NOT_READY", "Klargøring er i gang. Tjek igen om lidt.")
                # An interrupted worker may only make a private container. Its former lease cannot publish it.
                db.execute("UPDATE posts SET lease=?, modified=? WHERE id=?", (lease, time(), identifier))
            else:
                db.execute("INSERT INTO posts(id,digest,account,phase,lease,modified) VALUES(?,?,?,'preparing',?,?)",
                           (identifier, digest, account, lease, time()))
        return None, lease

    def prepare(self, identifier, lease, connection, account, caption, url, photo):
        args = {"ig_user_id": account, "caption": caption}
        try:
            if photo is not None:
                args["image_file"] = stage_photo(self.library, photo)
            else:
                args["image_url"] = url
            container = tool(self.library, connection, CREATE, args).get("id")
            if not numeric(container):
                raise ApiError(502, "NOT_READY", "Instagram gav ingen billedkladde tilbage. Prøv igen.")
        except Exception:
            with closing(self.db()) as db, db:
                db.execute("DELETE FROM posts WHERE id=? AND phase='preparing' AND lease=?", (identifier, lease))
            raise
        with closing(self.db()) as db, db:
            if not db.execute("""UPDATE posts SET phase='ready', container=?, lease=NULL
                    WHERE id=? AND phase='preparing' AND lease=?""", (container, identifier, lease)).rowcount:
                raise ApiError(409, "NOT_READY", "Klargøringen er genstartet. Tjek kladdens status.")
        return container

    def container_status(self, connection, container):
        result = tool(self.library, connection, CONTAINER_STATUS, {"creation_id": container})
        if result.get("id") != container:
            raise ApiError(502, "NOT_READY", "Instagram kunne ikke genkende billedkladden. Hent status igen.")
        return result.get("status_code")

    def publish(self, body, *, scheduled=False):
        identifier = self.library.owner + "/" + draft_id(body.get("id"))
        account, caption, photo, url, digest = approved_content(body)
        connection = self.library.connection("instagram")
        if not connection or profile(self.library, connection)["accountID"] != account:
            raise ApiError(409, "NOT_READY", "Den valgte Instagram-konto har ændret sig. Åbn kontooversigten igen.")

        row, lease = self.reserve(identifier, digest, account, scheduled)
        if row and row["phase"] in ("publishing", "published"):
            result = self.receipt(body["id"])
            if result["published"]:
                return result
            raise ApiError(409, "REQUEST_REUSED", UNCERTAIN)
        container = row["container"] if row else self.prepare(identifier, lease, connection, account, caption, url, photo)
        status = self.container_status(connection, container)
        for delay in (3, 4):
            if status != "IN_PROGRESS":
                break
            sleep(delay)
            status = self.container_status(connection, container)
        if status in ("ERROR", "EXPIRED"):
            with closing(self.db()) as db, db:
                db.execute("DELETE FROM posts WHERE id=? AND phase='ready' AND container=?", (identifier, container))
            raise ApiError(422, "INVALID_INPUT", "Instagram afviste billedkladden. Vælg fotoet igen og prøv på ny.")
        if status != "FINISHED":
            raise ApiError(409, "NOT_READY", "Instagram behandler billedet. Tryk Udgiv igen om lidt.")
        with closing(self.db()) as db, db:
            if not db.execute("UPDATE posts SET phase='publishing' WHERE id=? AND phase='ready' AND container=?",
                              (identifier, container)).rowcount:
                raise ApiError(409, "REQUEST_REUSED", "Opslaget er allerede på vej. Tjek status.")
        try:
            result = tool(self.library, connection, PUBLISH, {
                "ig_user_id": account, "creation_id": container, "max_wait_seconds": 0,
            })
            media = result.get("id")
            if not numeric(media):
                raise ValueError("Missing Instagram media ID")
        except (ApiError, ValueError) as exc:
            raise ApiError(502, "NOT_READY", UNCERTAIN) from exc
        with closing(self.db()) as db, db:
            db.execute("UPDATE posts SET phase='published', media=? WHERE id=?", (media, identifier))
        return {"published": True, "mediaID": media, "state": "published"}


def register_instagram(router, library, root):
    def posts(bot_id):
        return InstagramPublishing(agent_library(library, bot_id), root)

    @router.get("/instagram/status")
    def status(bot_id: str = ""):
        return posts(bot_id).status()

    @router.get("/instagram/receipts/{identifier}")
    def receipt(identifier: str, bot_id: str = ""):
        return posts(bot_id).receipt(identifier)

    @router.put("/instagram/publish")
    def publish(body: dict = Body(...), bot_id: str = ""):
        return posts(bot_id).publish(body)

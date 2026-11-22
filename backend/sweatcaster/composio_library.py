"""Connect Libraries on behalf of the paired FadedAI owner."""

import json
import os
import re
import sqlite3
from contextlib import closing
from concurrent.futures import ThreadPoolExecutor
from email.utils import getaddresses
from hashlib import sha256
from time import time
from threading import Lock
from urllib.parse import quote, urlsplit
from uuid import NAMESPACE_URL, UUID, uuid5

import requests

from sweatcaster.composio_settings import load
from sweatcaster.composio_gmail import ConsumerGmail, MESSAGES, MESSAGE_ID, PROFILE
from sweatcaster.dto import ApiError

BASE = "https://backend.composio.dev/api/"
SERVICES = {
    "googledrive": "Google Drive", "github": "GitHub", "gmail": "Gmail",
    "googlesheets": "Google Sheets", "notion": "Notion", "instagram": "Instagram",
}
REPO = re.compile(r"[A-Za-z0-9_.-]{1,100}/[A-Za-z0-9_.-]{1,100}")
DRIVE_ID = re.compile(r"[A-Za-z0-9_-]{1,160}")
GMAIL_ADDRESS = re.compile(r"[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+")
CONFIG_ID = re.compile(r"ac_[A-Za-z0-9_-]{1,128}")
GMAIL_READ_SCOPE = "https://www.googleapis.com/auth/gmail.readonly"
GMAIL_CONFIG_NAME = "FadedAI Gmail read-only"
GITHUB_ACTION_LOG = re.compile(
    r"https://api\.github\.com/repos/[A-Za-z0-9-]+/[A-Za-z0-9_.-]+/actions/jobs/\d+(?:/steps/\d+)?/logs"
)
GITHUB_LOG_LIMIT = 16_000_000
READ_ONLY_GOOGLE = {
    "gmail": (GMAIL_CONFIG_NAME, GMAIL_READ_SCOPE),
    "googlesheets": ("FadedAI Google Sheets read-only", "https://www.googleapis.com/auth/spreadsheets.readonly"),
}
NOTION_API = "https://api.notion.com/v1"
NOTION_HEADERS = {"Notion-Version": "2025-09-03"}
LIBRARIES = ("gmail", "googledrive", "googlesheets", "notion", "github")
FOR_YOU_APPS = {
    **SERVICES, "googlecalendar": "Google Kalender", "youtube": "YouTube", "discord": "Discord",
    "google_maps": "Google Maps", "one_drive": "OneDrive", "dropbox": "Dropbox",
    "googlephotos": "Google Fotos", "facebook": "Facebook", "twitch": "Twitch", "deepseek": "DeepSeek",
    "grok": "Grok", "veo": "Veo",
}
FOR_YOU_READERS = ("googlecalendar", "youtube")


def _rows(data, key):
    value = data.get(key) if isinstance(data, dict) else None
    return [row for row in value if isinstance(row, dict)] if isinstance(value, list) else []


def _rich_text(nodes):
    return "".join(row.get("plain_text", "") for row in nodes
                   if isinstance(row, dict) and isinstance(row.get("plain_text"), str)) if isinstance(nodes, list) else ""


def _page_id(value):
    try:
        return str(UUID(value)) if isinstance(value, str) and len(value) in (32, 36) else None
    except ValueError:
        return None


class ComposioLibrary:
    def __init__(self, root):
        self.owner = "fadedai-" + uuid5(NAMESPACE_URL, str(root.resolve())).hex
        self.setting_up = Lock()
        self.gmail_outbox = root / "composio-gmail-outbox.sqlite3"
        self.inventory_lock = Lock()
        self.inventory_cache = None

    def gmail(self):
        key = load().get("gmail_consumer_key")
        return ConsumerGmail(key) if key else None

    def key(self):
        return os.environ.get("COMPOSIO_API_KEY", "").strip() or load().get("key", "")

    def request(self, method, route, *, params=None, payload=None, version="v3", maximum=1_000_000):
        key = self.key()
        if not key:
            raise ApiError(503, "NOT_READY", "Composio mangler en projektnøgle på PC’en.")
        try:
            with requests.Session() as client:
                client.trust_env = False
                with client.request(method, BASE + version + route, params=params, json=payload,
                                    headers={"x-api-key": key}, timeout=(5, 15),
                                    allow_redirects=False, stream=True) as response:
                    if not 200 <= response.status_code < 300:
                        raise ValueError("Composio rejected the request")
                    chunks = bytearray()
                    for chunk in response.iter_content(65_536):
                        chunks.extend(chunk)
                        if len(chunks) > maximum:
                            raise ValueError("Composio response too large")
            result = json.loads(chunks)
            if not isinstance(result, dict):
                raise ValueError("Invalid Composio response")
            return result
        except (requests.RequestException, ValueError) as exc:
            raise ApiError(502, "NOT_READY", "Composio svarede ikke som forventet. Tjek PC-opsætningen.") from exc

    def config(self, provider, *, create=False):
        if provider not in SERVICES:
            raise ApiError(404, "NOT_FOUND", "Tjenesten understøttes ikke.")
        configured = os.environ.get(f"FADEDAI_COMPOSIO_{provider.upper()}_AUTH_CONFIG", "").strip() or load().get(provider, "")
        if configured or not self.key():
            return configured
        if not create:
            return self.managed_config(provider)
        with self.setting_up:
            config = self.managed_config(provider)
            if config:
                return config
            auth_config = {"type": "use_composio_managed_auth"}
            if provider in READ_ONLY_GOOGLE:
                name, scope = READ_ONLY_GOOGLE[provider]
                auth_config.update(name=name, credentials={"scopes": scope})
            result = self.request("POST", "/auth_configs", payload={
                "toolkit": {"slug": provider},
                "auth_config": auth_config,
            }, version="v3.1")
            entry = result.get("auth_config") or {}
            config = entry.get("id", "")
            if ((result.get("toolkit") or {}).get("slug") != provider or entry.get("is_composio_managed") is not True
                    or not isinstance(config, str) or not CONFIG_ID.fullmatch(config)):
                raise ApiError(502, "NOT_READY", "Composio kunne ikke oprette loginopsætningen.")
            return config

    def managed_config(self, provider):
        query = {
            "toolkit_slug": provider, "is_composio_managed": "true", "show_disabled": "false", "limit": 200,
        }
        if provider in READ_ONLY_GOOGLE:
            query["search"] = READ_ONLY_GOOGLE[provider][0]
        result = self.request("GET", "/auth_configs", params=query, version="v3.1")
        rows = result.get("items", [])
        if not isinstance(rows, list):
            raise ApiError(502, "NOT_READY", "Composio gav en ugyldig liste over loginopsætninger.")
        configs = [
            item["id"] for item in rows if isinstance(item, dict)
            and item.get("status") == "ENABLED" and item.get("is_composio_managed") is True
            and (item.get("toolkit") or {}).get("slug") == provider
            and isinstance(item.get("id"), str) and CONFIG_ID.fullmatch(item["id"])
            and (provider not in READ_ONLY_GOOGLE or item.get("name") == query["search"])
        ]
        return min(configs, default="")

    def account(self, provider, config):
        result = self.request("GET", "/connected_accounts", params={
            "user_ids": self.owner, "auth_config_ids": config,
            "toolkit_slugs": provider, "statuses": "ACTIVE", "limit": 10,
        })
        for account in result.get("items", []):
            if (isinstance(account, dict) and account.get("status") == "ACTIVE"
                    and account.get("user_id") == self.owner and not account.get("is_disabled")
                    and (account.get("auth_config") or {}).get("id") == config
                    and (account.get("toolkit") or {}).get("slug") == provider
                    and isinstance(account.get("id"), str)):
                return account["id"]
        return None

    def states(self, providers=SERVICES):
        keyed = bool(self.key())
        result = []
        for provider in providers:
            configured = self.gmail() is not None if provider == "gmail" else keyed
            connected = configured if provider == "gmail" else bool(configured and self.connection(provider))
            result.append({"id": provider, "title": SERVICES[provider], "configured": configured,
                           "connected": connected})
        return {"providers": result}

    def integrations(self, *, refresh=False):
        # Reuse results when several screens on the paired phone request them together.
        with self.inventory_lock:
            if not refresh and self.inventory_cache and time() - self.inventory_cache[0] < 45:
                return self.inventory_cache[1]
            consumer = self.gmail()
            with ThreadPoolExecutor(max_workers=8) as pool:
                shared_apps = {key: title for key, title in FOR_YOU_APPS.items() if key != "instagram"}
                inventory = pool.submit(consumer.connection_statuses, shared_apps) if consumer else None
                probes = {provider: pool.submit(self.integration_readable, provider, consumer)
                          for provider in (*LIBRARIES, *FOR_YOU_READERS)}
                consumer_status = inventory.result() if inventory else {}
                checked = {provider: probe.result() for provider, probe in probes.items()}
            rows = []
            for provider, title in FOR_YOU_APPS.items():
                if provider == "instagram":
                    rows.append({"id": provider, "title": title, "availability": "per_agent", "connected": False,
                                 "configured": bool(self.key())})
                    continue
                readable = checked.get(provider) == "ready"
                status = ("ready" if readable else "composio" if consumer_status.get(provider) is True
                          else checked.get(provider) or ("disconnected" if provider in consumer_status else "unknown"))
                configured = bool(consumer) if provider == "gmail" else provider in LIBRARIES and bool(self.key())
                rows.append({"id": provider, "title": title, "availability": status, "connected": readable,
                             "configured": configured})
            output = {"providers": rows}
            self.inventory_cache = (time(), output)
            return output

    def integration_readable(self, provider, consumer):
        if provider == "gmail" and not consumer:
            return "disconnected"
        try:
            if provider == "gmail":
                profile = consumer.read(PROFILE)
                return "ready" if isinstance(profile, dict) and profile.get("emailAddress") else "error"
            if provider in FOR_YOU_READERS:
                if not consumer:
                    return "disconnected"
                self.for_you_items(provider, consumer)
                return "ready"
            if not self.key() or not self.connection(provider):
                return "disconnected"
            self.items(provider)
            return "ready"
        except ApiError:
            return "error"

    def link(self, provider):
        config = self.config(provider, create=True)
        if not config:
            raise ApiError(503, "NOT_READY", "Composio mangler en projektnøgle på PC’en.")
        result = self.request("POST", "/connected_accounts/link", payload={
            "auth_config_id": config, "user_id": self.owner,
        })
        link = result.get("redirect_url")
        parts = urlsplit(link) if isinstance(link, str) else None
        host = parts.hostname if parts else None
        if (not parts or parts.scheme != "https" or parts.username or parts.password or not host
                or not (host == "composio.dev" or host.endswith(".composio.dev")
                        or host == "composio.com" or host.endswith(".composio.com"))):
            raise ApiError(502, "NOT_READY", "Composio gav et ugyldigt loginlink.")
        return {"url": link}

    def connection(self, provider):
        if provider == "gmail" and (consumer := self.gmail()):
            return consumer.account
        config = self.config(provider)
        account = self.account(provider, config) if config else None
        if account is None and provider == "googlesheets":
            return self.connection("googledrive")
        return account

    def read(self, provider, endpoint, query=None, *, account=None, headers=None, search=None):
        if provider == "gmail" and (consumer := self.gmail()) and account in (None, consumer.account):
            return consumer.read(endpoint, query)
        account = account or self.connection(provider)
        if not account:
            raise ApiError(409, "NOT_READY", "Log ind på tjenesten først.")
        call = {
            "connected_account_id": account, "user_id": self.owner,
            "endpoint": endpoint, "method": "POST" if search is not None else "GET",
            "parameters": [{"name": key, "value": str(value), "type": "query"}
                           for key, value in (query or {}).items()] +
                          [{"name": key, "value": str(value), "type": "header"}
                           for key, value in (headers or {}).items()],
        }
        if search is not None:
            call["body"] = search
        # Long Xcode logs are returned inside a JSON string by the authorized account proxy.
        limits = {"maximum": GITHUB_LOG_LIMIT} if provider == "github" and GITHUB_ACTION_LOG.fullmatch(endpoint) else {}
        result = self.request("POST", "/tools/execute/proxy", payload=call, version="v3.1", **limits)
        status = result.get("status")
        if not isinstance(status, int) or not 200 <= status < 300:
            raise ApiError(502, "NOT_READY", "Tjenesten afviste opslaget. Tjek dens læseadgang.")
        return result.get("data")

    def items(self, provider):
        if provider in FOR_YOU_READERS:
            return self.for_you_items(provider, self.gmail())
        if provider == "gmail":
            return {"items": [{"id": row["id"], "title": row["subject"][:240] or "Uden emne"}
                              for row in self.gmail_messages()]}
        if provider in {"googledrive", "googlesheets"}:
            if provider == "googlesheets" and not self.connection(provider):
                raise ApiError(409, "NOT_READY", "Log ind på Google Sheets først.")
            mime_query = ("mimeType = 'application/vnd.google-apps.spreadsheet'" if provider == "googlesheets"
                          else "(mimeType = 'application/vnd.google-apps.document' or mimeType = 'text/plain')")
            data = self.read("googledrive", "https://www.googleapis.com/drive/v3/files", {
                "q": f"trashed = false and {mime_query}",
                "pageSize": 50, "orderBy": "modifiedTime desc",
                "fields": "files(id,name,mimeType)",
            })
            return {"items": [{"id": row["id"], "title": str(row.get("name", ""))[:240]}
                              for row in _rows(data, "files") if isinstance(row.get("id"), str)
                              and DRIVE_ID.fullmatch(row["id"])]}
        if provider == "notion":
            data = self.read(provider, NOTION_API + "/search", headers=NOTION_HEADERS, search={
                "filter": {"property": "object", "value": "page"}, "page_size": 30,
            })
            items = []
            for page in _rows(data, "results"):
                if page.get("object") != "page" or not (page_id := _page_id(page.get("id"))):
                    continue
                props = page.get("properties")
                props = props.values() if isinstance(props, dict) else ()
                title = next((_rich_text(prop.get("title")) for prop in props
                              if isinstance(prop, dict) and prop.get("type") == "title"), "")
                items.append({"id": page_id, "title": title[:240] or "Side uden titel"})
            return {"items": items}
        if provider != "github":
            raise ApiError(404, "NOT_FOUND", "Tjenesten understøttes ikke.")
        rows = self.read(provider, "https://api.github.com/user/repos", {
            "per_page": 50, "sort": "updated",
        })
        return {"items": [{"id": row["full_name"], "title": row["full_name"]}
                          for row in (rows if isinstance(rows, list) else []) if isinstance(row, dict)
                          and isinstance(row.get("full_name"), str) and REPO.fullmatch(row["full_name"])]}

    @staticmethod
    def for_you_items(provider, consumer):
        if not consumer:
            raise ApiError(409, "NOT_READY", "Forbind Composio For You på PC’en først.")
        if provider == "googlecalendar":
            rows = _rows(consumer.list_calendars(), "calendars")
            entries = [(row.get("id"), row.get("summaryOverride") or row.get("summary")) for row in rows]
        else:
            rows = _rows(consumer.list_youtube_channels(), "items")
            entries = [(row.get("id"), row.get("snippet", {}).get("title"))
                       for row in rows if isinstance(row.get("snippet"), dict)]
        return {"items": [{"id": identifier, "title": title[:240]} for identifier, title in entries[:15]
                          if isinstance(identifier, str) and isinstance(title, str) and title.strip()]}

    def context(self, provider, item):
        if provider not in SERVICES:
            raise ApiError(404, "NOT_FOUND", "Tjenesten understøttes ikke.")
        if not isinstance(item, str):
            raise ApiError(422, "INVALID_INPUT", "Vælg ét opslag.")
        if provider == "gmail":
            if not self.gmail():
                raise ApiError(409, "NOT_READY", "Forbind Gmail via Composio For You på PC’en først.")
            title = "Valgt mail"
            text = self.gmail_message(item)["text"]
        elif provider == "googledrive" and DRIVE_ID.fullmatch(item):
            endpoint = f"https://www.googleapis.com/drive/v3/files/{item}"
            info = self.read(provider, endpoint, {"fields": "name,mimeType,size"})
            mime = info.get("mimeType") if isinstance(info, dict) else None
            if mime == "application/vnd.google-apps.document":
                text = self.read(provider, endpoint + "/export", {"mimeType": "text/plain"})
            elif mime == "text/plain" and str(info.get("size", "")).isdigit() and int(info["size"]) <= 65_536:
                text = self.read(provider, endpoint, {"alt": "media"})
            else:
                raise ApiError(422, "INVALID_INPUT", "Vælg et Google-dokument eller en lille tekstfil.")
            title = str(info.get("name", ""))[:240]
        elif provider == "googlesheets" and DRIVE_ID.fullmatch(item):
            endpoint = f"https://sheets.googleapis.com/v4/spreadsheets/{item}"
            account = self.connection(provider)
            if not account:
                raise ApiError(409, "NOT_READY", "Forbind Google Drive eller Google Sheets først.")
            info = self.read(provider, endpoint, {"fields": "properties(title),sheets(properties(title))"}, account=account)
            tabs = _rows(info, "sheets")
            first = tabs[0].get("properties") if tabs else None
            tab = first.get("title") if isinstance(first, dict) else None
            if not isinstance(tab, str) or not tab:
                raise ApiError(422, "INVALID_INPUT", "Regnearket har ingen læsbare faner.")
            cells = quote("'" + tab.replace("'", "''") + "'!A1:J25", safe="")
            data = self.read(provider, endpoint + "/values/" + cells, account=account)
            values = data.get("values", []) if isinstance(data, dict) else []
            rows = [" | ".join(str(cell)[:300] for cell in row[:10])
                    for row in values[:25] if isinstance(row, list)] if isinstance(values, list) else []
            properties = info.get("properties", {})
            title = str(properties.get("title", tab))[:240] if isinstance(properties, dict) else tab[:240]
            text = "\n".join([tab + " · A1–J25", *rows]) if rows else ""
        elif provider == "notion" and (page_id := _page_id(item)):
            data = self.read(provider, f"{NOTION_API}/blocks/{page_id}/children",
                             {"page_size": 30}, headers=NOTION_HEADERS)
            lines = []
            for block in _rows(data, "results"):
                kind = block.get("type")
                body = block.get(kind) if isinstance(kind, str) else None
                if isinstance(body, dict) and (line := _rich_text(body.get("rich_text"))):
                    lines.append(line)
            title = "Side"
            text = "\n".join(lines)
        elif provider == "github" and REPO.fullmatch(item) and not any(p in {".", ".."} for p in item.split("/")):
            endpoint = f"https://api.github.com/repos/{item}"
            account = self.connection(provider)
            if not account:
                raise ApiError(409, "NOT_READY", "Log ind på GitHub først.")
            info = self.read(provider, endpoint, account=account)
            if not isinstance(info, dict):
                raise ApiError(502, "NOT_READY", "GitHub gav et uventet svar.")
            title = item
            lines = [str(info.get(field) or "") for field in ("description", "html_url", "language", "default_branch")]
            filters = {"state": "open", "sort": "updated", "direction": "desc", "per_page": 5}
            collections = [("pulls", "Pull request")]
            if info.get("has_issues") is True:
                collections.insert(0, ("issues", "Opgave"))
            for path, label in collections:
                try:
                    rows = self.read(provider, endpoint + "/" + path, filters, account=account)
                except ApiError:
                    lines.append(f"Kunne ikke læse {label.lower()} fra GitHub.")
                else:
                    lines.extend(self.github_entries(rows, label, exclude_pulls=path == "issues"))
            text = "\n".join(lines)
        else:
            raise ApiError(422, "INVALID_INPUT", "Vælg et opslag fra listen.")
        if not isinstance(text, str) or not text.strip():
            raise ApiError(422, "INVALID_INPUT", "Der er ingen læsbar tekst at vedhæfte.")
        output = (f"{SERVICES[provider]} · {title}\n{text}").encode("utf-8")[:8_000].decode("utf-8", errors="ignore")
        return {"text": output}

    @staticmethod
    def github_entries(rows, label, *, exclude_pulls=False):
        if not isinstance(rows, list):
            return []
        return [f"{label} #{row['number']} · {row['title'][:240]}" for row in rows[:5]
                if isinstance(row, dict) and (not exclude_pulls or "pull_request" not in row)
                and type(row.get("number")) is int and isinstance(row.get("title"), str)]

    def gmail_messages(self, query=""):
        consumer = self.gmail()
        if not consumer:
            raise ApiError(409, "NOT_READY", "Forbind Gmail via Composio For You på PC’en først.")
        if len(query) > 160:
            raise ApiError(422, "INVALID_INPUT", "Skriv højst 160 tegn i Gmail-søgningen.")
        return consumer.recent(query.strip())

    def read_gmail_message(self, identifier, consumer=None):
        if not isinstance(identifier, str) or not MESSAGE_ID.fullmatch(identifier):
            raise ApiError(422, "INVALID_INPUT", "Vælg en mail fra listen.")
        endpoint, query = MESSAGES + "/" + identifier, {"format": "full"}
        message = consumer.read(endpoint, query) if consumer else self.read("gmail", endpoint, query)
        if not isinstance(message, dict) or message.get("id") != identifier:
            raise ApiError(502, "NOT_READY", "Gmail kunne ikke læse den valgte mail.")
        return message

    def gmail_message(self, identifier):
        from sweatcaster.mail_appointments import mail_text

        message = self.read_gmail_message(identifier)
        return {"text": mail_text(message)[:8_000], "messageID": message["id"], "threadID": message.get("threadId")}

    def gmail_reply_target(self, identifier, consumer=None):
        message = self.read_gmail_message(identifier, consumer or self.require_gmail())
        thread = message.get("threadId")
        payload = message.get("payload")
        headers = _rows(payload, "headers")
        values = {str(header.get("name", "")).casefold(): header.get("value") for header in headers[:100]}
        address = values.get("reply-to") or values.get("from") or message.get("sender")
        subject = values.get("subject") or message.get("subject") or "Uden emne"
        addresses = getaddresses([address]) if isinstance(address, str) and len(address) <= 2_000 else []
        recipient = addresses[0][1] if len(addresses) == 1 else ""
        if (not isinstance(thread, str) or not MESSAGE_ID.fullmatch(thread)
                or not GMAIL_ADDRESS.fullmatch(recipient) or len(recipient) > 254):
            raise ApiError(422, "INVALID_INPUT", "Gmail gav ingen sikker modtager til svar på denne mail.")
        return {"threadID": thread, "recipient": recipient, "subject": str(subject)[:350]}

    def reply_gmail(self, request):
        identifier = self.gmail_send_id(request.get("id"))
        message, thread, recipient, body = (request.get(key) for key in ("messageID", "threadID", "recipient", "body"))
        if (not isinstance(message, str) or not MESSAGE_ID.fullmatch(message)
                or not isinstance(thread, str) or not MESSAGE_ID.fullmatch(thread)
                or not isinstance(recipient, str) or len(recipient) > 254 or not GMAIL_ADDRESS.fullmatch(recipient)
                or not self.valid_gmail_body(body)):
            raise ApiError(422, "INVALID_INPUT", "Vælg én Gmail-tråd, én modtager og et svar på højst 8.000 tegn.")
        consumer = self.require_gmail()
        receipt = {"sent": True, "threadID": thread}
        digest = sha256(json.dumps([consumer.account, "reply", message, thread, recipient, body],
                                   ensure_ascii=False).encode()).hexdigest()
        if self.sent_gmail(identifier, digest):
            return receipt
        actual = self.gmail_reply_target(message, consumer)
        if actual["recipient"] != recipient or actual["threadID"] != thread:
            raise ApiError(409, "INVALID_INPUT", "Tråden eller modtageren er ændret. Åbn mailen igen før afsendelse.")
        return self.deliver_gmail(identifier, digest, lambda: consumer.reply(thread, recipient, body), receipt,
                                  account=consumer.account)

    def gmail_reply_receipt(self, value):
        consumer = self.require_gmail()
        row = self.gmail_reply_record(value, consumer)
        return {"sent": True, "threadID": row[0]} if row else {"sent": False}

    def gmail_followup(self, value):
        consumer = self.require_gmail()
        row = self.gmail_reply_record(value, consumer)
        return consumer.newer_reply(*row) if row else {"state": "unknown"}

    def gmail_reply_record(self, value, consumer):
        identifier = self.gmail_send_id(value)
        with closing(self.gmail_outbox_connection()) as db:
            return db.execute("SELECT thread, message FROM reply_receipts WHERE id = ? AND account = ?",
                              (identifier, consumer.account)).fetchone()

    def send_gmail(self, request):
        recipient = request.get("recipient")
        subject = request.get("subject")
        body = request.get("body")
        identifier = self.gmail_send_id(request.get("id"))
        if (not isinstance(recipient, str) or len(recipient) > 254 or
                not GMAIL_ADDRESS.fullmatch(recipient)
                or not isinstance(subject, str) or not 1 <= len(subject.strip()) <= 200
                or any(ord(char) < 32 for char in subject)
                or not self.valid_gmail_body(body)):
            raise ApiError(422, "INVALID_INPUT", "Angiv én modtager, et emne og en besked på højst 8.000 tegn.")
        consumer = self.require_gmail()
        digest = sha256(json.dumps([consumer.account, recipient, subject, body], ensure_ascii=False).encode()).hexdigest()
        return self.deliver_gmail(identifier, digest, lambda: consumer.send(recipient, subject, body), {"sent": True})

    def require_gmail(self):
        consumer = self.gmail()
        if not consumer:
            raise ApiError(409, "NOT_READY", "Forbind Gmail via Composio For You på PC’en først.")
        return consumer

    @staticmethod
    def gmail_send_id(value):
        try:
            return str(UUID(value))
        except (TypeError, ValueError, AttributeError) as exc:
            raise ApiError(422, "INVALID_INPUT", "Kladde-id er ugyldigt.") from exc

    @staticmethod
    def valid_gmail_body(body):
        return isinstance(body, str) and 1 <= len(body.strip()) <= 8_000 and "\x00" not in body

    def gmail_outbox_connection(self):
        db = sqlite3.connect(self.gmail_outbox)
        try:
            db.execute("CREATE TABLE IF NOT EXISTS sends (id TEXT PRIMARY KEY, digest TEXT, sent INTEGER, created REAL)")
            db.execute("CREATE TABLE IF NOT EXISTS reply_receipts (id TEXT PRIMARY KEY, account TEXT, thread TEXT, message TEXT)")
        except BaseException:
            db.close()
            raise
        return db

    def sent_gmail(self, identifier, digest):
        with closing(self.gmail_outbox_connection()) as db:
            row = db.execute("SELECT digest, sent FROM sends WHERE id = ?", (identifier,)).fetchone()
        if row is None:
            return False
        if row == (digest, 1):
            return True
        raise ApiError(409, "REQUEST_REUSED", "Tjek Sendt i Gmail, før du prøver at sende igen.")

    def deliver_gmail(self, identifier, digest, send, receipt, *, account=None):
        with closing(self.gmail_outbox_connection()) as db, db:
            inserted = db.execute("INSERT OR IGNORE INTO sends VALUES (?, ?, 0, ?)", (identifier, digest, time())).rowcount
        if not inserted:
            if self.sent_gmail(identifier, digest):
                return receipt
            raise ApiError(409, "REQUEST_REUSED", "Tjek Sendt i Gmail, før du prøver at sende igen.")
        try:
            result = send()
            message_id = result.get("id") or result.get("messageId")
            if (not isinstance(message_id, str) or not MESSAGE_ID.fullmatch(message_id)
                    or (receipt.get("threadID") and result.get("threadId", receipt["threadID"]) != receipt["threadID"])):
                raise ValueError("Missing Gmail message receipt")
        except (ApiError, ValueError, AttributeError) as exc:
            raise ApiError(502, "NOT_READY", "Afsendelsen kunne ikke bekræftes. Tjek Sendt i Gmail før et nyt forsøg.") from exc
        with closing(sqlite3.connect(self.gmail_outbox)) as db, db:
            db.execute("UPDATE sends SET sent = 1 WHERE id = ?", (identifier,))
            if account is not None:
                db.execute("INSERT INTO reply_receipts VALUES (?, ?, ?, ?)",
                           (identifier, account, receipt["threadID"], message_id))
        return receipt


def register_composio(app, settings, authorize):
    library = ComposioLibrary(settings.output_root)
    from sweatcaster.composio_routes import register_routes
    register_routes(app, settings, authorize, library, load)
    return library

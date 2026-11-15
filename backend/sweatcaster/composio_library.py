"""Connect Libraries on behalf of the paired FadedAI owner."""

import json
import os
import re
from threading import Lock
from urllib.parse import urlsplit
from uuid import NAMESPACE_URL, uuid5

import requests
from fastapi import APIRouter, Body, Depends, Request, Response

from sweatcaster.composio_settings import load
from sweatcaster.dto import ApiError

BASE = "https://backend.composio.dev/api/"
SERVICES = {"googledrive": "Google Drive", "github": "GitHub", "gmail": "Gmail"}
REPO = re.compile(r"[A-Za-z0-9_.-]{1,100}/[A-Za-z0-9_.-]{1,100}")
DRIVE_ID = re.compile(r"[A-Za-z0-9_-]{1,160}")
CONFIG_ID = re.compile(r"ac_[A-Za-z0-9_-]{1,128}")
GMAIL_READ_SCOPE = "https://www.googleapis.com/auth/gmail.readonly"
GMAIL_CONFIG_NAME = "FadedAI Gmail read-only"


class ComposioLibrary:
    def __init__(self, root):
        self.owner = "fadedai-" + uuid5(NAMESPACE_URL, str(root.resolve())).hex
        self.setting_up = Lock()

    def key(self):
        return os.environ.get("COMPOSIO_API_KEY", "").strip() or load().get("key", "")

    def request(self, method, route, *, params=None, payload=None, version="v3"):
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
                        if len(chunks) > 1_000_000:
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
            if provider == "gmail":
                auth_config.update(name=GMAIL_CONFIG_NAME, credentials={"scopes": GMAIL_READ_SCOPE})
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
        if provider == "gmail":
            query["search"] = GMAIL_CONFIG_NAME
        result = self.request("GET", "/auth_configs", params=query, version="v3.1")
        rows = result.get("items", [])
        if not isinstance(rows, list):
            raise ApiError(502, "NOT_READY", "Composio gav en ugyldig liste over loginopsætninger.")
        configs = [
            item["id"] for item in rows if isinstance(item, dict)
            and item.get("status") == "ENABLED" and item.get("is_composio_managed") is True
            and (item.get("toolkit") or {}).get("slug") == provider
            and isinstance(item.get("id"), str) and CONFIG_ID.fullmatch(item["id"])
            and (provider != "gmail" or item.get("name") == GMAIL_CONFIG_NAME)
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
        states = []
        for provider in providers:
            title = SERVICES[provider]
            config = self.config(provider)
            states.append({"id": provider, "title": title, "configured": keyed,
                           "connected": bool(keyed and config and self.account(provider, config))})
        return {"providers": states}

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
        config = self.config(provider)
        return self.account(provider, config) if config else None

    def read(self, provider, endpoint, query=None, *, account=None):
        account = account or self.connection(provider)
        if not account:
            raise ApiError(409, "NOT_READY", "Log ind på tjenesten først.")
        result = self.request("POST", "/tools/execute/proxy", payload={
            "connected_account_id": account, "user_id": self.owner,
            "endpoint": endpoint, "method": "GET",
            "parameters": [{"name": key, "value": str(value), "in": "query"}
                           for key, value in (query or {}).items()],
        }, version="v3.1")
        status = result.get("status")
        if not isinstance(status, int) or not 200 <= status < 300:
            raise ApiError(502, "NOT_READY", "Tjenesten afviste opslaget. Tjek dens læseadgang.")
        return result.get("data")

    def items(self, provider):
        if provider == "gmail":
            raise ApiError(404, "NOT_FOUND", "Åbn Gmail-aftaler på agentens computer.")
        if provider == "googledrive":
            data = self.read(provider, "https://www.googleapis.com/drive/v3/files", {
                "q": "trashed = false and (mimeType = 'application/vnd.google-apps.document' or mimeType = 'text/plain')",
                "pageSize": 50, "orderBy": "modifiedTime desc",
                "fields": "files(id,name,mimeType)",
            })
            rows = data.get("files", []) if isinstance(data, dict) else []
            return {"items": [{"id": row["id"], "title": str(row.get("name", ""))[:240]}
                              for row in rows if isinstance(row, dict)
                              and isinstance(row.get("id"), str) and DRIVE_ID.fullmatch(row["id"])]}
        rows = self.read(provider, "https://api.github.com/user/repos", {
            "per_page": 50, "sort": "updated",
        })
        return {"items": [{"id": row["full_name"], "title": row["full_name"]}
                          for row in (rows if isinstance(rows, list) else []) if isinstance(row, dict)
                          and isinstance(row.get("full_name"), str) and REPO.fullmatch(row["full_name"])]}

    def context(self, provider, item):
        if provider not in SERVICES:
            raise ApiError(404, "NOT_FOUND", "Tjenesten understøttes ikke.")
        if not isinstance(item, str):
            raise ApiError(422, "INVALID_INPUT", "Vælg ét opslag.")
        if provider == "googledrive" and DRIVE_ID.fullmatch(item):
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
        elif provider == "github" and REPO.fullmatch(item) and not any(p in {".", ".."} for p in item.split("/")):
            info = self.read(provider, f"https://api.github.com/repos/{item}")
            if not isinstance(info, dict):
                raise ApiError(502, "NOT_READY", "GitHub gav et uventet svar.")
            title = item
            text = "\n".join(str(info.get(field) or "") for field in ("description", "html_url", "language", "default_branch"))
        else:
            raise ApiError(422, "INVALID_INPUT", "Vælg et opslag fra listen.")
        if not isinstance(text, str) or not text.strip():
            raise ApiError(422, "INVALID_INPUT", "Der er ingen læsbar tekst at vedhæfte.")
        output = (f"{SERVICES[provider]} · {title}\n{text}").encode("utf-8")[:8_000].decode("utf-8", errors="ignore")
        return {"text": output}


def register_composio(app, settings, authorize):
    library = ComposioLibrary(settings.output_root)

    def paired(request: Request, response: Response):
        authorize(request, settings)
        response.headers["Cache-Control"] = "no-store"

    router = APIRouter(prefix="/api/modules/v1/composio", dependencies=[Depends(paired)], include_in_schema=False)

    @router.get("")
    def states():
        return library.states(("googledrive", "github"))
    router.add_api_route("/{provider}/items", library.items, methods=["GET"])

    @router.put("/{provider}/link")
    def link(provider: str):
        return library.link(provider)

    @router.put("/{provider}/context")
    def context(provider: str, body: dict = Body(...)):
        return library.context(provider, body.get("item"))

    app.include_router(router)
    return library

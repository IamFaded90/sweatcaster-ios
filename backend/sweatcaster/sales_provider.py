"""Tradera's documented v4 seller endpoints, with locally encrypted authorization."""

from datetime import datetime, timezone
import json
import os
from pathlib import Path
import secrets
from tempfile import NamedTemporaryFile
from threading import RLock
from urllib.parse import quote, urlencode

import requests

from sweatcaster.dto import ApiError
from sweatcaster.emby_settings import _protect
from sweatcaster import tradera_api


class SellerAPI:
    def __init__(self, path=None, session_factory=requests.Session):
        local = Path(os.environ["LOCALAPPDATA"]) if os.environ.get("LOCALAPPDATA") else Path.home() / ".local" / "share"
        self.path = path or local / "FadedAI" / "tradera-seller.dpapi"
        self.session_factory = session_factory
        self.lock = RLock()

    def saved(self):
        try:
            raw = self.path.read_bytes()
            value = json.loads(_protect(raw, decrypt=True)) if len(raw) <= 16_384 else {}
            return value if isinstance(value, dict) else {}
        except (OSError, ValueError, TypeError):
            return {}

    def persist(self, value):
        self.path.parent.mkdir(parents=True, exist_ok=True)
        blob = _protect(json.dumps(value).encode())
        scratch = None
        try:
            with NamedTemporaryFile(dir=self.path.parent, delete=False) as stream:
                scratch = Path(stream.name)
                stream.write(blob)
            scratch.replace(self.path)
        finally:
            if scratch:
                scratch.unlink(missing_ok=True)

    def status(self):
        cfg = self.saved()
        pair = tradera_api.credentials()
        authorized = bool(cfg.get("userToken"))
        if authorized:
            try:
                authorized = datetime.fromisoformat(cfg["expires"].replace("Z", "+00:00")) > datetime.now(timezone.utc)
            except (ValueError, KeyError, TypeError):
                authorized = False
        return {"configured": bool(pair or cfg.get("appKey")), "hasPublicKey": bool(cfg.get("publicKey")),
                "authorized": authorized, "alias": cfg.get("alias"), "expires": cfg.get("expires")}

    def request(self, method, path, body=None, *, seller=True, params=None):
        cfg = self.saved()
        pair = (cfg.get("appID"), cfg.get("appKey")) if cfg.get("appKey") else tradera_api.credentials() or (None, None)
        if not all(pair):
            raise ApiError(409, "NOT_READY", "Forbind Tradera, eller brug agentens PC-vindue til annonceringen.")
        headers = {"X-App-Id": pair[0], "X-App-Key": pair[1], "Accept": "application/json"}
        if seller:
            if not self.status()["authorized"]:
                raise ApiError(409, "NOT_READY", "Log ind på Tradera for at give salgsagenten adgang.")
            headers.update({"X-User-Id": str(cfg["userID"]), "X-User-Token": cfg["userToken"]})
        try:
            with self.session_factory() as client:
                client.trust_env = False
                with client.request(method, tradera_api.TRADERA + path, json=body, params=params,
                                    headers=headers, timeout=(4, 20), allow_redirects=False, stream=True) as response:
                    if not 200 <= response.status_code < 300:
                        code = 403 if response.status_code in (401, 403) else 502
                        raise ApiError(code, "NOT_READY", "Tradera afviste handlingen. Tjek login og annoncens felter.")
                    data = bytearray()
                    for chunk in response.iter_content(16_384):
                        data.extend(chunk)
                        if len(data) > 3_000_000:
                            raise ValueError
                    return json.loads(data) if data.strip() else None
        except (requests.RequestException, ValueError):
            raise ApiError(502, "NOT_READY", "Tradera gav ingen sikker kvittering. Opdatér sagen, før du prøver igen.") from None

    def configure(self, body):
        existing = tradera_api.credentials() or (self.saved().get("appID"), self.saved().get("appKey"))
        pair = tradera_api.credential_pair(body.get("appID") or existing[0], body.get("appKey") or existing[1])
        public = body.get("publicKey", "")
        if not isinstance(public, str) or not 1 <= len(public) <= 1_024 or any(c.isspace() for c in public):
            raise ApiError(422, "INVALID_INPUT", "Indtast Tradera-appens offentlige nøgle.")
        with self.lock:
            self.persist({"appID": pair[0], "appKey": pair[1], "publicKey": public})
        return self.status()

    def login(self, alias):
        if not isinstance(alias, str) or not 1 <= len(alias.strip()) <= 80:
            raise ApiError(422, "INVALID_INPUT", "Skriv dit Tradera-brugernavn.")
        with self.lock:
            cfg = self.saved()
            if not cfg.get("publicKey"):
                raise ApiError(409, "NOT_READY", "Tradera-appens offentlige nøgle mangler i forbindelsen.")
            who = self.request("GET", "/users/by-alias/" + quote(alias.strip(), safe=""), seller=False)
            if not isinstance(who, dict) or type(who.get("id")) is not int:
                raise ApiError(409, "NOT_READY", "Tradera kunne ikke finde det brugernavn.")
            cfg.update(userID=who["id"], alias=alias.strip(), loginSecret=secrets.token_urlsafe(32))
            cfg.pop("userToken", None)
            cfg.pop("expires", None)
            self.persist(cfg)
            pair = (cfg.get("appID"), cfg.get("appKey")) if cfg.get("appKey") else tradera_api.credentials() or (None, None)
            return {"url": "https://api.tradera.com/token-login?" + urlencode(
                {"appId": pair[0], "pkey": cfg["publicKey"], "skey": cfg["loginSecret"]})}

    def finish_login(self):
        with self.lock:
            cfg = self.saved()
            if not cfg.get("loginSecret"):
                return self.status()
            result = self.request("POST", "/auth/token", {"userId": cfg["userID"],
                                  "secretKey": cfg["loginSecret"]}, seller=False)
            if not isinstance(result, dict) or not result.get("authToken") or not result.get("hardExpirationTime"):
                raise ApiError(409, "NOT_READY", "Godkend Tradera-login i browservinduet, og tryk derefter Opdatér.")
            cfg.update(userToken=result["authToken"], expires=result["hardExpirationTime"])
            cfg.pop("loginSecret", None)
            self.persist(cfg)
        return self.status()

    def catalog(self, category=None):
        if category:
            return {"attributes": self.request("GET", f"/categories/{category}/attribute-definitions", seller=False)}
        shipping = self.request("GET", "/reference-data/shipping-options", seller=False)
        providers = {}
        for span in shipping.get("productsPerWeightSpan") or []:
            for product in span.get("products") or []:
                key = product.get("shippingProviderId")
                if type(key) is int and key not in providers:
                    providers[key] = {"id": key, "name": product.get("shippingProvider") or product.get("name") or "Fragt",
                                      "cost": product.get("price", 0)}
        return {"categories": self.request("GET", "/categories", seller=False),
                "shipping": list(providers.values()),
                "bidders": self.request("GET", "/reference-data/accepted-bidder-types", seller=False)}

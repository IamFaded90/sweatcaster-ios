"""Read one active Tradera v4 listing and ECB reference rates for a price watch."""

import json
import os
import re
from datetime import date, datetime, timezone
from decimal import Decimal, InvalidOperation
from pathlib import Path
from tempfile import NamedTemporaryFile
from threading import Lock
from time import monotonic
from urllib.parse import urlsplit
from uuid import UUID
from xml.etree import ElementTree

import requests

from sweatcaster.dto import ApiError
from sweatcaster.emby_settings import _protect


TRADERA = "https://api.tradera.com/v4"
ECB = "https://www.ecb.europa.eu/stats/eurofxref/eurofxref-daily.xml"
ITEM_PATH = re.compile(r"/(?:[a-z]{2}/)?item/([1-9][0-9]{0,9})/([1-9][0-9]{0,9})(?:/[^/]{0,350})?/?")


def listing(value):
    try:
        url = urlsplit(value) if isinstance(value, str) and len(value) <= 2048 else None
        if (url and url.scheme == "https" and url.hostname in {"tradera.com", "www.tradera.com"}
                and url.port in (None, 443) and url.username is None and "\\" not in value):
            match = ITEM_PATH.fullmatch(url.path)
            if match and int(match[2]) <= 2_147_483_647:
                return int(match[2]), "https://www.tradera.com" + url.path
    except ValueError:
        pass
    raise ApiError(422, "INVALID_INPUT", "Indsæt et link til én annonce på tradera.com.")


def credential_pair(app_id, key):
    try:
        if not isinstance(app_id, str) or not re.fullmatch(r"[1-9][0-9]{0,9}", app_id):
            raise ValueError
        if not isinstance(key, str) or str(UUID(key)) != key.lower():
            raise ValueError
        return app_id, key
    except ValueError as exc:
        raise ApiError(422, "INVALID_INPUT", "Indtast Tradera-appens numeriske ID og dens appnøgle.") from exc


def settings_file():
    return Path(os.environ["LOCALAPPDATA"]) / "FadedAI" / "tradera-watch.dpapi"


def credentials():
    try:
        path = settings_file()
        with path.open("rb") as f:
            encrypted = f.read(4097)
        if len(encrypted) > 4096:
            return None
        saved = json.loads(_protect(encrypted, decrypt=True))
        return credential_pair(saved["appID"], saved["appKey"])
    except (KeyError, OSError, ValueError, TypeError, ApiError):
        return None


def save_credentials(app_id, key):
    pair = credential_pair(app_id, key)
    clock = request_json("/reference-data/time", pair)
    stamp = clock.get("time") if isinstance(clock, dict) else clock
    try:
        datetime.fromisoformat(stamp)
    except (TypeError, ValueError):
        raise ApiError(502, "NOT_READY", "Tradera kunne ikke bekræfte adgangen.")
    try:
        blob = _protect(json.dumps({"appID": pair[0], "appKey": pair[1]}).encode())
        location = settings_file()
        location.parent.mkdir(parents=True, exist_ok=True)
        scratch = None
        try:
            with NamedTemporaryFile(dir=location.parent, delete=False) as stream:
                scratch = Path(stream.name)
                stream.write(blob)
            scratch.replace(location)
        finally:
            if scratch:
                scratch.unlink(missing_ok=True)
    except (KeyError, OSError, ValueError) as exc:
        raise ApiError(503, "NOT_READY", "Nøglen kunne ikke gemmes krypteret på PC’en.") from exc


def fetch(url, headers, limit):
    try:
        with requests.Session() as client:
            client.trust_env = False
            with client.get(url, headers=headers, timeout=(4, 8), allow_redirects=False, stream=True) as response:
                status = response.status_code
                if status != 200:
                    return status, b""
                data = bytearray()
                for chunk in response.iter_content(16_384):
                    data.extend(chunk)
                    if len(data) > limit:
                        raise ValueError
                return status, bytes(data)
    except (requests.RequestException, ValueError):
        raise ApiError(502, "NOT_READY", "Prisopslaget kunne ikke gennemføres. PC’en prøver igen.") from None


def request_json(path, pair):
    status, data = fetch(TRADERA + path, {"X-App-Id": pair[0], "X-App-Key": pair[1], "Accept": "application/json"}, 900_000)
    if status in (401, 403):
        raise ApiError(403, "NOT_READY", "Tradera afviste appens ID eller nøgle. Tjek forbindelsen.")
    if status in (404, 410) and path.startswith("/items/"):
        return None
    if status == 429:
        raise ApiError(429, "NOT_READY", "Tradera har begrænset antallet af opslag. PC’en prøver igen senere.")
    if status == 200:
        try:
            return json.loads(data)
        except (ValueError, UnicodeError):
            pass
    raise ApiError(502, "NOT_READY", "Tradera gav intet brugbart svar. PC’en prøver igen.")


class PriceSource:
    def __init__(self):
        self.rate = None
        self.rate_until = 0
        self.lock = Lock()

    def dkk_per_sek(self):
        with self.lock:
            if self.rate is not None and monotonic() < self.rate_until:
                return self.rate
            status, data = fetch(ECB, {}, 50_000)
            try:
                if status != 200 or b"<!" in data:
                    raise ValueError
                dated = next(node for node in ElementTree.fromstring(data).iter() if "time" in node.attrib)
                rate_date = date.fromisoformat(dated.attrib["time"])
                if not 0 <= (datetime.now(timezone.utc).date() - rate_date).days <= 7:
                    raise ValueError
                rates = {row.attrib.get("currency"): Decimal(row.attrib["rate"]) for row in dated}
                if not all(rates[c].is_finite() and rates[c] > 0 for c in ("DKK", "SEK")):
                    raise ValueError
                self.rate = rates["DKK"] / rates["SEK"]
                self.rate_until = monotonic() + 3600
                return self.rate
            except (ValueError, KeyError, InvalidOperation, StopIteration, ElementTree.ParseError):
                raise ApiError(502, "NOT_READY", "ECB-kursen er utilgængelig. Der sammenlignes først, når den er klar.") from None

    def check(self, item_id, currency):
        pair = credentials()
        if not pair:
            raise ApiError(409, "NOT_READY", "Forbind Tradera med app-ID og appnøgle på PC’en.")
        item = request_json("/items/" + str(item_id), pair)
        if item is None:
            return {"state": "unavailable", "note": "Annoncen kunne ikke findes hos Tradera."}
        if not isinstance(item, dict) or type(item.get("id")) is not int or item["id"] != item_id:
            raise ApiError(502, "NOT_READY", "Tradera kunne ikke bekræfte den valgte annonce.")
        status = item.get("status")
        if not isinstance(status, dict) or type(status.get("ended")) is not bool:
            raise ApiError(502, "NOT_READY", "Annoncens status kunne ikke kontrolleres.")
        if status["ended"] or (type(item.get("remainingQuantity")) is int and item["remainingQuantity"] == 0):
            return {"state": "ended", "note": "Annoncen er afsluttet eller udsolgt."}
        if item.get("currency", "SEK") != "SEK":
            return {"state": "currencyMismatch", "note": "Tradera returnerede en uventet valuta."}
        kind = item.get("itemType")
        if type(kind) is not int:
            raise ApiError(502, "NOT_READY", "Tradera angav ingen gyldig annoncetype.")
        bids = item.get("totalBids")
        if kind in (3, 4):
            amount, label = item.get("buyItNowPrice"), "Køb nu"
        elif kind == 1 and type(bids) is int and bids == 0:
            amount, label = item.get("openingBid"), "Startbud"
        elif kind == 1 and type(bids) is int and bids > 0:
            amount, label = item.get("maxBid"), "Højeste bud"
        elif kind == 1:
            raise ApiError(502, "NOT_READY", "Tradera kunne ikke bekræfte det aktuelle bud.")
        else:
            return {"state": "unavailable", "note": "Denne annonce har ingen offentlig pris at følge."}
        if type(amount) is not int or amount <= 0:
            raise ApiError(502, "NOT_READY", "Tradera angav ingen gyldig pris.")
        title = item.get("shortDescription")
        compared = Decimal(amount)
        note = label + " uden fragt."
        if currency == "DKK":
            compared *= self.dkk_per_sek()
            note += f" Ca. {compared:.2f} DKK ved ECB-kurs."
        return {"state": "watching", "title": title[:180] if isinstance(title, str) else "",
                "price": amount, "compared": compared, "note": note}

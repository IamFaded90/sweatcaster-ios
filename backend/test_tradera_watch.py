from datetime import datetime, timezone
from decimal import Decimal
from types import SimpleNamespace
from uuid import uuid4

import pytest
from fastapi import FastAPI, HTTPException
from fastapi.testclient import TestClient

from sweatcaster import tradera_api as api
from sweatcaster.agent_owner_notice import send_owner_notice
from sweatcaster.composio_gmail import PROFILE
from sweatcaster.composio_library import ComposioLibrary
from sweatcaster.dto import ApiError
from sweatcaster.tradera_watch import INTERVAL, MAX_PRICE_AGE, PriceWatches, cents, register_tradera


URL = "https://www.tradera.com/en/item/12345/987654/lampe"
BODY = {"url": URL, "threshold": 100, "currency": "SEK"}


def test_exact_listing_and_amount():
    assert api.listing(URL.replace("www.", "") + "?utm_source=share#x") == (987654, URL)
    assert api.listing(URL.replace("/en/", "/"))[0] == 987654
    for value in ["https://example.org/item/12345/987654/lampe", "https://tradera.com/search/987654",
                  "http://tradera.com/item/12345/987654/lampe", "https://name@tradera.com/item/1/2",
                  "https://tradera.com:8080/item/1/2", "https://tradera.com/item/1/2147483648"]:
        with pytest.raises(ApiError):
            api.listing(value)
    for value in [True, 0, -1, 0.001, 1e20, "100", float("nan")]:
        with pytest.raises(ApiError):
            cents(value)
    assert cents(100.11) == 10011


def test_correct_price_end_status_and_currency(monkeypatch):
    monkeypatch.setattr(api, "credentials", lambda: ("fake", "fake"))
    item = {"id": 987654, "itemType": 1, "status": {"ended": False}, "totalBids": 0,
            "shortDescription": "Lampe", "openingBid": 120, "maxBid": 175, "buyItNowPrice": 220}
    def read(path, pair):
        assert path == "/items/987654"
        return item
    monkeypatch.setattr(api, "request_json", read)
    source = api.PriceSource()
    monkeypatch.setattr(source, "dkk_per_sek", lambda: Decimal("0.67"))
    assert source.check(987654, "SEK")["price"] == 120
    item["totalBids"] = 3
    assert source.check(987654, "SEK")["price"] == 175
    for kind in (3, 4):
        item["itemType"] = kind
        result = source.check(987654, "DKK")
        assert result["price"] == 220
        assert result["compared"] == Decimal("147.40")
    item["currency"] = "EUR"
    assert source.check(987654, "DKK")["state"] == "currencyMismatch"
    item["status"]["ended"] = True
    assert source.check(987654, "SEK")["state"] == "ended"
    item["id"] = 12345
    with pytest.raises(ApiError):
        source.check(987654, "SEK")
    monkeypatch.setattr(api, "request_json", lambda *args: None)
    assert source.check(987654, "SEK")["state"] == "unavailable"
    monkeypatch.setattr(api, "credentials", lambda: None)
    with pytest.raises(ApiError, match="app-ID"):
        source.check(987654, "SEK")


def test_only_fresh_valid_ecb_rates(monkeypatch):
    today = datetime.now(timezone.utc).date()

    def xml(day, sek):
        return (f"<Envelope><Cube><Cube time='{day}'><Cube currency='DKK' rate='7.4'/>"
                f"<Cube currency='SEK' rate='{sek}'/></Cube></Cube></Envelope>").encode()
    rate = xml(today, "11.1")
    def read(url, headers, limit):
        assert (url, headers) == (api.ECB, {})
        return 200, rate
    monkeypatch.setattr(api, "fetch", read)
    source = api.PriceSource()
    assert source.dkk_per_sek() == Decimal("7.4") / Decimal("11.1")
    for rate in [xml("2000-01-01", "11.1"), xml(today, "NaN"), xml(today, "0")]:
        assert source.dkk_per_sek() == Decimal("7.4") / Decimal("11.1")
        with pytest.raises(ApiError, match="ECB"):
            api.PriceSource().dkk_per_sek()


class Source:
    price = 100
    def check(self, item, currency):
        assert item == 987654
        return {"state": "watching", "title": "Lampe", "price": self.price,
                "compared": Decimal(self.price)}


def test_restart_crossing_and_notification_recovery(tmp_path):
    now = [50000]
    bot, identifier = str(uuid4()), str(uuid4())
    mail = []
    source = Source()
    def send(library, token, subject, text):
        mail.append((token, subject, text))
        return "sent" if len(mail) > 1 else "unavailable"
    def restart():
        return PriceWatches(tmp_path, None, source=source, clock=lambda: now[0], notify=send)
    watch = restart()
    body = dict(BODY, notifyByEmail=True)
    first = watch.create(bot, identifier, body)
    assert first["state"] == "watching" and first["price"] == 100 and first["alertedAt"] is None
    assert watch.create(bot, identifier, body) == first
    with pytest.raises(ApiError):
        watch.create(bot, identifier, dict(body, threshold=150))
    assert watch.one(str(uuid4()), identifier) is None
    watch = restart()
    source.price = 95
    now[0] += INTERVAL
    watch.tick()
    alert = watch.one(bot, identifier)
    assert (alert["state"], alert["price"], alert["alertedAt"]) == ("triggered", 95, now[0])
    watch.tick()
    assert watch.one(bot, identifier)["emailStatus"] == "unavailable"
    now[0] += INTERVAL
    watch = restart()
    watch.tick()
    assert watch.one(bot, identifier)["emailStatus"] == "sent"
    now[0] += MAX_PRICE_AGE + 1
    watch.tick()
    assert watch.one(bot, identifier)["price"] is None
    assert watch.one(bot, identifier)["alertedAt"] == alert["alertedAt"]
    assert len(mail) == 2 and mail[0] == mail[1]


def test_stopping_a_watch_while_quote_is_in_flight(tmp_path):
    bot, identifier = str(uuid4()), str(uuid4())
    source = Source()
    watch = PriceWatches(tmp_path, None, source=source)
    def cancelled(*_):
        watch.cancel(bot, identifier)
        return {"state": "watching", "compared": Decimal(10), "price": 10}
    source.check = cancelled
    result = watch.create(bot, identifier, BODY)
    assert result["state"] == "cancelled" and result["alertedAt"] is None
    assert watch.list(bot) == {"watches": []}
    with pytest.raises(ApiError):
        watch.create(bot, identifier, BODY)


def test_only_owner_mailbox_and_no_duplicate_after_ambiguous_send(tmp_path, monkeypatch):
    library = ComposioLibrary(tmp_path)
    box = SimpleNamespace(account="owner")
    monkeypatch.setattr(library, "gmail", lambda: box)
    delivered = []
    def profile(endpoint):
        assert endpoint == PROFILE
        return {"emailAddress": "owner@example.org"}
    box.read = profile
    def send(recipient, subject, text):
        delivered.append(recipient)
        return {"id": "good"} if subject == "ok" else {}
    box.send = send
    one, two = uuid4(), uuid4()
    assert send_owner_notice(library, one, "ok", "hello") == "sent"
    assert send_owner_notice(library, one, "ok", "hello") == "sent"
    assert send_owner_notice(library, two, "?", "hello") == "uncertain"
    assert send_owner_notice(library, two, "?", "hello") == "uncertain"
    box.read = lambda _: {"emailAddress": "a@example.org,b@example.com"}
    assert send_owner_notice(library, uuid4(), "x", "hello") == "unavailable"
    assert delivered == ["owner@example.org", "owner@example.org"]


def test_paired_routes_and_configuration(tmp_path, monkeypatch):
    app = FastAPI()
    def authorized(request, settings):
        if request.headers.get("X-Test-Parent") != "paired":
            raise HTTPException(401)
    config = tmp_path / "settings.bin"
    monkeypatch.setattr(api, "settings_file", lambda: config)
    monkeypatch.setattr(api, "_protect", lambda data, decrypt=False: bytes(b ^ 91 for b in data))
    monkeypatch.setattr(api, "request_json", lambda path, pair: "2026-11-18T08:00:00Z")
    watches = register_tradera(app, SimpleNamespace(output_root=tmp_path), authorized, None)
    watches.source = Source()
    watches.source.price = 90
    bot, other, identifier, key = [str(uuid4()) for _ in range(4)]
    base = "/api/modules/v1/tradera"
    with TestClient(app) as client:
        assert client.get(base + "/status").status_code == 401
        client.headers["X-Test-Parent"] = "paired"
        assert client.get(base + "/status").json() == {"configured": False, "mailAvailable": False}
        assert client.put(base + "/settings", json={"appID": "998", "appKey": key}).json() == {"configured": True}
        assert key.encode() not in config.read_bytes()
        assert client.get(base + "/status").json() == {"configured": True, "mailAvailable": False}
        path = base + "/watches/" + identifier
        first = client.put(path, params={"bot_id": bot}, json=BODY)
        assert first.headers["cache-control"] == "no-store" and first.json()["state"] == "triggered"
        assert first.json()["emailStatus"] == "off"
        assert client.get(path, params={"bot_id": other}).json() == {"watch": None}
        assert len(client.get(base + "/watches", params={"bot_id": bot}).json()["watches"]) == 1
        assert client.put(path + "/cancel", params={"bot_id": bot}).json() == {"cancelled": True}
        assert client.get(path, params={"bot_id": bot}).json()["watch"]["state"] == "cancelled"
        assert client.get(base + "/watches", params={"bot_id": bot}).json() == {"watches": []}


def test_opted_in_mail_watch_persists_without_api_key_and_triggers_once(tmp_path, monkeypatch):
    import base64
    from sweatcaster import tradera_mail

    now = [51_000.0]
    owner = ["connected-account"]
    calls, deliveries = [], []
    message = {"id": "single-mail", "internalDate": str(int((now[0] + 5) * 1000)),
               "payload": {"mimeType": "text/plain", "headers": [
                   {"name": "From", "value": "Tradera <alerts@notify.tradera.com>"},
                   {"name": "Authentication-Results", "value": "mx.google.com; dmarc=pass header.from=notify.tradera.com"}],
                   "body": {"data": base64.urlsafe_b64encode(f"{URL}\nKöp nu: 95 DKK".encode()).decode()}}}

    def read(service, endpoint, params, account):
        assert service == "gmail" and account == "connected-account"
        calls.append((endpoint, params))
        if endpoint == tradera_mail.MESSAGES:
            assert "from:(@notify.tradera.com)" in params["q"] and '"987654"' in params["q"]
            return {"messages": [{"id": "single-mail"}]}
        assert endpoint == tradera_mail.MESSAGES + "/single-mail"
        return message

    library = SimpleNamespace(connection=lambda _: owner[0], read=read)
    def restart():
        return PriceWatches(tmp_path, library, clock=lambda: now[0],
                            notify=lambda *args: deliveries.append(args[1]) or "sent")
    bot, key = str(uuid4()), str(uuid4())
    api_forbidden = lambda *_: pytest.fail("Mail mode should never access Tradera's website or API")
    monkeypatch.setattr(api, "fetch", api_forbidden)
    monitor = restart()
    request = dict(BODY, source="traderaMail", currency="DKK", notifyByEmail=True)
    created = monitor.create(bot, key, request)
    assert created["state"] == "waitingMail" and created["source"] == "traderaMail" and not calls
    with pytest.raises(ApiError):
        monitor.create(bot, key, BODY)
    now[0] += 10
    monitor = restart()
    monitor.tick()
    result = monitor.one(bot, key)
    assert (result["state"], result["price"], result["priceCurrency"], result["priceAt"]) == ("triggered", 95, "DKK", 51_005)
    assert [step[1].get("format") for step in calls] == [None, "metadata", "full"]
    owner[0] = "replaced-account"
    monitor.tick()
    assert not deliveries and monitor.one(bot, key)["emailStatus"] == "unavailable"
    owner[0] = "connected-account"
    now[0] += INTERVAL
    monitor.tick()
    restart().tick()
    assert len(deliveries) == 1 and monitor.one(bot, key)["emailStatus"] == "sent"
    now[0] += MAX_PRICE_AGE
    assert monitor.one(bot, key)["priceAt"] is None and monitor.one(bot, key)["price"] is None


def test_mail_watch_requires_consent_to_a_source_and_keeps_legacy_sqlite_rows(tmp_path):
    import sqlite3
    bot, old = str(uuid4()), str(uuid4())
    watch = PriceWatches(tmp_path, None)
    with sqlite3.connect(watch.database) as db:
        db.execute("""CREATE TABLE watches (bot TEXT, id TEXT, url TEXT, item INTEGER, limitCents INTEGER,
            currency TEXT, notify INTEGER, created REAL, state TEXT, due REAL, ticket TEXT, checked REAL,
            triggered REAL, title TEXT, price INTEGER, note TEXT, email TEXT, emailDue REAL, PRIMARY KEY(bot,id))""")
        db.execute("INSERT INTO watches(bot,id,url,limitCents,currency,state) VALUES (?,?,?,?,?,?)",
                   (bot, old, URL, 10_000, "SEK", "watching"))
    assert watch.one(bot, old)["source"] == "api"
    for source in ("traderaMail", "html", None):
        with pytest.raises(ApiError):
            watch.create(bot, str(uuid4()), dict(BODY, source=source))
    assert len(watch.list(bot)["watches"]) == 1

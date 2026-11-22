import json
from datetime import datetime, timezone
from uuid import uuid4

import pytest

from sweatcaster import public_price, repository_routine
from sweatcaster.agent_workflows import AgentWorkflows
from sweatcaster.dto import ApiError
from sweatcaster.tradera_watch import PriceWatches
from test_agent_workflows import Library


def offer(price=95, currency="DKK"):
    product = {"@type": "Product", "name": "Grøn lampe", "offers": {
        "@type": "Offer", "price": price, "priceCurrency": currency, "availability": "https://schema.org/InStock"}}
    return ('<script type="application/ld+json">' + json.dumps(product) + '</script>').encode()


def test_public_watch_restarts_and_does_not_confuse_currency(tmp_path, monkeypatch):
    now = [10000]
    watches = PriceWatches(tmp_path, None, clock=lambda: now[0])
    bot, key = str(uuid4()), str(uuid4())
    body = dict(url="https://shop.example/lampe", source="publicPage", currency="DKK", threshold=100)
    watches.create(bot, key, body)
    assert not watches.list(bot)["watches"]
    assert watches.list(bot, True)["watches"][0]["url"] == body["url"]
    with pytest.raises(ApiError):
        watches.create(bot, key, dict(body, url="https://shop.example/anden"))
    monkeypatch.setattr(public_price, "_download", lambda url: offer(currency="SEK"))
    watches.tick()
    assert watches.one(bot, key)["state"] == "currencyMismatch"
    now[0] += 2000
    monkeypatch.setattr(public_price, "_download", lambda url: offer())
    PriceWatches(tmp_path, None, clock=lambda: now[0]).tick()
    alert = watches.one(bot, key)
    assert (alert["state"], alert["price"], alert["title"]) == ("triggered", 95, "Grøn lampe")
    watches.cancel(bot, key)
    assert not watches.list(bot, True)["watches"]


def test_public_price_requires_one_available_product_and_one_price(monkeypatch):
    for url in ("http://shop.example/item", "https://user@shop.example/x", "https://127.0.0.1/secret"):
        with pytest.raises(ApiError):
            public_price.listing(url)
    for data in (offer() + offer(price=10), offer(price="NaN"), offer(price=0),
                 offer().replace(b"InStock", b"OutOfStock"), b"<html>Fra 95 kr i rabat</html>"):
        monkeypatch.setattr(public_price, "_download", lambda _, value=data: value)
        assert public_price.check("https://shop.example/lampe", "DKK")["state"] == "error"


def test_resumes_index_after_interrupt_without_refreshing_twice(tmp_path):
    pytest.importorskip("langgraph.checkpoint.sqlite")
    lib = Library(tmp_path)
    calls = []
    lib.refresh = lambda repo: calls.append(("refresh", repo))
    original = lib.index
    def stop(_repo):
        raise KeyboardInterrupt
    lib.index = stop
    workflow = AgentWorkflows(tmp_path, lib)
    workflow.configure_routines([{"repo": "example/lampe", "hour": 1, "action": "refresh_repository"}])
    instant = datetime(2026, 11, 22, 10, tzinfo=timezone.utc)
    with pytest.raises(KeyboardInterrupt):
        workflow.run_due(instant)
    assert workflow.routine_status(instant)[0]["today"] == "running"
    lib.index = original
    workflow = AgentWorkflows(tmp_path, lib)
    with repository_routine.worker_lock(tmp_path) as acquired:
        assert acquired
        workflow.run_due(instant)
        assert lib.indexed == []
    workflow.run_due(instant)
    workflow.run_due(instant)
    assert calls == [("refresh", "example/lampe")]
    assert lib.indexed == ["example/lampe"]
    assert workflow.routine_status(instant)[0]["today"] == "completed"

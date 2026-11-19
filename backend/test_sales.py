import base64
from io import BytesIO
import json
from types import SimpleNamespace
from time import time
from uuid import uuid4

from PIL import Image
import pytest

from sweatcaster.dto import ApiError
from sweatcaster.sales_service import Sales
from sweatcaster.sales_service import operator_context
from sweatcaster.sales_provider import SellerAPI
from sweatcaster.sales_mail import notices


class Tradera:
    def __init__(self):
        self.calls = []
        self.authorized = True
        self.result = 128
        self.commit_uncertain = False
        self.sold = []
        self.title = "Min brugte skærm"

    def status(self):
        return {"authorized": self.authorized, "configured": True}

    def catalog(self, _):
        return {"attributes": []}

    def request(self, method, path, body=None, **kwargs):
        self.calls.append((method, path, body))
        if path == "/listings/items":
            assert body["autoCommit"] is False and body["itemType"] == 3
            self.title = body["title"]
            return {"requestId": 12, "itemId": 456}
        if path.endswith("/images"):
            assert base64.b64decode(body["imageData"]).startswith(b"\xff\xd8")
            return None
        if path.endswith("/commit"):
            if self.commit_uncertain:
                raise ApiError(502, "NOT_READY", "afbrudt")
            return None
        if path == "/listings/request-results":
            return [{"requestId": 12, "resultCode": self.result}]
        if path == "/listings/items/456":
            return {"id": 456, "title": self.title}
        if path == "/listings/seller-transactions":
            return self.sold
        if path == "/listings/transaction-status":
            return {"id": body["transactionId"], "isMarkedAsPaidConfirmed": True, "isMarkedAsShipped": True}
        raise AssertionError(path)


def setup(tmp_path, **kwargs):
    provider = Tradera()
    service = Sales(tmp_path, provider, SimpleNamespace(dkk_per_sek=lambda: 0.67), **kwargs)
    bot, key = str(uuid4()), str(uuid4())
    stream = BytesIO()
    Image.new("RGB", (40, 80), "green").save(stream, "PNG")
    body = {"action": "create", "title": "Min brugte skærm", "description": "Brugt. Strømkabel medfølger.",
            "minimum": 800, "asking": 900, "currency": "DKK", "categoryID": 1, "bidderID": 3,
            "shipping": "Afhentning efter aftale", "photos": [base64.b64encode(stream.getvalue()).decode()]}
    case = service.mutate(bot, key, body)
    return service, provider, bot, key, body, case


def action(service, bot, key, case, name, **kwargs):
    return service.mutate(bot, key, {"action": name, "revision": case["revision"], **kwargs})


def test_preparing_uploads_photos_without_publishing_and_retries_are_idempotent(tmp_path):
    service, provider, bot, key, body, case = setup(tmp_path)
    assert service.create(bot.upper(), key.upper(), body) == case
    ready = action(service, bot, key, case, "prepare")
    assert ready["state"] == "ready" and ready["priceSEK"] == 1344
    assert ready["uploaded"] == 1
    assert not any(path.endswith("/commit") for _, path, _ in provider.calls)
    before = len(provider.calls)
    assert action(service, bot, key, ready, "prepare") == ready
    assert len(provider.calls) == before
    assert action(service, bot.upper(), key.upper(), ready, "remove") == {"removed": True}
    with service.db() as db:
        assert db.execute("SELECT count(*) FROM photos").fetchone()[0] == 0
        assert db.execute("SELECT count(*) FROM cases").fetchone()[0] == 0


def test_an_uncertain_commit_is_checked_and_never_repeated(tmp_path):
    service, provider, bot, key, _, case = setup(tmp_path)
    ready = action(service, bot, key, case, "prepare")
    provider.commit_uncertain = True
    waiting = action(service, bot, key, ready, "publish")
    assert waiting["state"] == "publishing"
    still_waiting = action(service, bot, key, waiting, "publish")
    assert still_waiting["state"] == "publishing"
    provider.result = 1
    done = action(service, bot, key, still_waiting, "refresh")
    assert done["state"] == "published" and done["url"].endswith("/1/456")
    assert len([1 for _, path, _ in provider.calls if path.endswith("/commit")]) == 1
    provider.sold = [{"id": 77, "item": {"id": 456}, "isMarkedAsPaidConfirmed": False, "isMarkedAsShipped": False}]
    sold = action(service, bot, key, done, "refresh")
    assert sold["state"] == "sold" and sold["transactionID"] == 77
    shipped = action(service, bot, key, sold, "fulfillment", kind="shipped")
    assert shipped["state"] == "shipped"


def test_login_is_required_before_a_remote_draft_and_revisions_prevent_lost_edits(tmp_path):
    service, provider, bot, key, body, case = setup(tmp_path)
    provider.authorized = False
    with pytest.raises(ApiError):
        action(service, bot, key, case, "prepare")
    assert service.one(bot, key)["state"] == "draft" and not provider.calls
    changed = action(service, bot, key, case, "edit", **{k: v for k, v in body.items() if k != "action"})
    with pytest.raises(ApiError):
        action(service, bot, key, case, "remove")
    assert service.one(bot, key) == changed
    with pytest.raises(ApiError):
        service.create(bot, key, {**body, "photos": []})


def test_an_offer_below_the_owners_limit_cannot_become_an_agreement(tmp_path):
    service, provider, bot, key, _, case = setup(tmp_path)
    case = action(service, bot, key, case, "message", kind="offer", buyer="Køber", amount=700, text="700?")
    low = case["messages"][-1]
    assert low["withinLimit"] is False
    with pytest.raises(ApiError):
        action(service, bot, key, case, "agreement", offerID=low["id"], agreement="Fredag")
    case = action(service, bot, key, case, "message", kind="offer", buyer="Køber", amount=850, text="850?")
    case = action(service, bot, key, case, "agreement", offerID=case["messages"][-1]["id"], agreement="Fredag klokken 16")
    assert case["state"] == "agreed" and not provider.calls


def test_a_model_reply_is_saved_as_a_draft_without_external_sending(tmp_path):
    service, provider, bot, key, _, case = setup(tmp_path, generate=lambda *_: "Ja, strømkablet medfølger.")
    case = action(service, bot, key, case, "message", kind="buyer", buyer="Køber", text="Er der kabel med?")
    case = action(service, bot, key, case, "reply", messageID=case["messages"][-1]["id"])
    assert case["messages"][-1]["kind"] == "replyDraft"
    assert "strømkablet" in case["messages"][-1]["text"] and not provider.calls


def test_only_authenticated_matching_tradera_mail_is_imported(tmp_path):
    case = {"id": str(uuid4()), "created": time() - 60, "messages": [], "itemID": 456, "mailAccount": "owner"}
    payload = {"headers": [{"name": "From", "value": "Tradera <message@notify.tradera.com>"},
                           {"name": "Authentication-Results", "value": "mx.google.com; dmarc=pass header.from=notify.tradera.com"}],
               "mimeType": "text/plain", "body": {"data": base64.urlsafe_b64encode(
                   b"New message https://www.tradera.com/item/1/456/screen").decode()}}
    message = {"id": "abc", "internalDate": str(int(time() * 1000)), "payload": payload}
    consumer = SimpleNamespace(account="owner", recent=lambda _: [{"id": "abc", "subject": "Nytt meddelande"}])
    library = SimpleNamespace(gmail=lambda: consumer, read_gmail_message=lambda *_: message)
    rows = notices(library, case)
    assert len(rows) == 1 and rows[0]["source"] == "gmail"
    assert not notices(library, {**case, "messages": rows})
    assert not notices(library, {**case, "itemID": 457})
    payload["headers"][1]["value"] = "mx.google.com; dmarc=fail header.from=notify.tradera.com"
    assert not notices(library, case)


def test_public_access_status_never_returns_the_encrypted_secrets(tmp_path, monkeypatch):
    provider = SellerAPI(tmp_path / "credentials.dpapi")
    monkeypatch.setattr(provider, "saved", lambda: {"appKey": "private", "userToken": "private",
                                                  "expires": "2099-01-01T00:00:00+00:00", "alias": "Owner"})
    monkeypatch.setattr("sweatcaster.tradera_api.credentials", lambda: None)
    status = provider.status()
    assert status["authorized"] and "private" not in json.dumps(status)


def test_key_free_browser_handoff_stages_exact_photos_and_removal_cleans_them(tmp_path):
    service, provider, bot, key, _, case = setup(tmp_path)
    provider.authorized = False
    packet = action(service, bot, key, case, "browser")
    assert packet["state"] == "draft" and packet["priceSEK"] == 1344 and not provider.calls
    context = operator_context(SimpleNamespace(output_root=tmp_path), packet["browserGoal"])
    assert context["description"] == case["description"] and context["priceText"] == "1344"
    assert len(context["photoPaths"]) == 1
    from pathlib import Path
    assert Path(context["photoPaths"][0]).read_bytes().startswith(b"\xff\xd8")
    action(service, bot, key, packet, "remove")
    assert not (tmp_path / "sales-browser" / key).exists()


def test_http_routes_require_pairing_and_the_list_reads_back_the_created_case(tmp_path):
    from fastapi import FastAPI, HTTPException
    from fastapi.testclient import TestClient
    from sweatcaster.sales_service import register_sales
    app = FastAPI()

    def authorize(request, _):
        if request.headers.get("Authorization") != "Bearer fixture":
            raise HTTPException(401)

    service = register_sales(app, SimpleNamespace(output_root=tmp_path), authorize)
    service.provider = Tradera()
    client = TestClient(app)
    bot, key = str(uuid4()), str(uuid4())
    assert client.get("/api/modules/v1/sales", params={"bot_id": bot}).status_code == 401
    body = {"action": "create", "title": "Lampe", "description": "Brugt lampe.", "minimum": 80,
            "asking": 100, "currency": "SEK"}
    response = client.put("/api/modules/v1/sales/" + key, params={"bot_id": bot},
                          headers={"Authorization": "Bearer fixture"}, json=body)
    assert response.status_code == 200 and response.headers["cache-control"] == "no-store"
    result = client.get("/api/modules/v1/sales", params={"bot_id": bot},
                        headers={"Authorization": "Bearer fixture"})
    assert result.json()["cases"][0]["id"] == key


def test_the_announcement_writer_returns_a_reviewable_draft_and_collects_questions():
    from sweatcaster.sales_draft import suggest
    observed = []

    def generate(prompt, _):
        observed.append(prompt)
        return json.dumps({"title": "Brugt skærm", "description": "Strømkabel medfølger.",
                           "questions": ["Hvilken model er skærmen?", "Er der fejl på den?"]})

    result = suggest(None, generate, {"prompt": "Sælg min skærm", "description": "Strømkabel medfølger."})
    assert result["title"] == "Brugt skærm" and len(result["questions"]) == 2
    assert "Strømkabel medfølger." in observed[0]
    with pytest.raises(ApiError):
        suggest(None, lambda *_: "ingen JSON", {"description": "Brugt"})


def test_long_reviewed_replies_use_an_exact_browser_context_without_exchange_lookup(tmp_path):
    service, provider, bot, key, _, case = setup(tmp_path)
    case = action(service, bot, key, case, "message", kind="replyDraft", buyer="Køber", text="Tak. " * 300)
    service.rates = SimpleNamespace(dkk_per_sek=lambda: pytest.fail("A reply needs no exchange-rate lookup"))
    case = action(service, bot, key, case, "browserReply", messageID=case["messages"][-1]["id"])
    assert len(case["browserGoal"]) < 1000 and not provider.calls
    context = operator_context(SimpleNamespace(output_root=tmp_path), case["browserGoal"])
    assert context["replyText"] == "Tak. " * 299 + "Tak."
    assert context["buyerName"] == "Køber"

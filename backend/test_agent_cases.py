import base64
from copy import deepcopy
from email import policy
from email.parser import BytesParser
from hashlib import sha256
from io import BytesIO
from types import SimpleNamespace
from uuid import uuid4

from PIL import Image
import pytest

from sweatcaster.dto import ApiError
from sweatcaster.agent_case_gmail import CaseGmail, GmailRejected, unpack
from sweatcaster.agent_cases import AgentCases


class Gmail(CaseGmail):
    def __init__(self):
        self.email, self.account = "owner@example.invalid", "owner-account"
        self.consumer = SimpleNamespace(recent=lambda _: [{"id": "ab01", "subject": "Kvittering for skærm", "sender": "Butik"}])
        self.sent, self.requests, self.incoming = {}, [], []
        self.before, self.after, self.crash, self.read_fail = False, False, False, False
        self.rewrite = None

    def proxy(self, method, path, *, body=None, query=None):
        self.requests.append((method, path, deepcopy(body), query))
        if method == "POST":
            assert path == "/messages/send"
            if self.before:
                raise ApiError(502, "NOT_READY", "connection lost")
            key = "cd" + format(len(self.sent) + 1, "02x")
            raw = base64.urlsafe_b64decode(body["raw"])
            if self.rewrite:
                mail = BytesParser(policy=policy.SMTP).parsebytes(raw)
                self.rewrite(mail)
                raw = mail.as_bytes()
            self.sent[key] = {"id": key, "threadId": "de01", "labelIds": ["SENT"],
                              "internalDate": "1000000", "raw": base64.urlsafe_b64encode(raw).decode()}
            if self.crash:
                self.crash = False
                raise SystemExit("simulated application crash after send")
            if self.after:
                raise ApiError(502, "NOT_READY", "reply lost after send")
            return {"id": key, "threadId": "de01"}
        if self.read_fail:
            raise ApiError(502, "NOT_READY", "Gmail read unavailable")
        if path == "/messages":
            assert query["q"].startswith("in:sent rfc822msgid:")
            wanted = query["q"].split("rfc822msgid:", 1)[1]
            return {"messages": [{"id": key} for key, message in self.sent.items()
                                 if wanted in BytesParser(policy=policy.default).parsebytes(base64.urlsafe_b64decode(message["raw"]))["Message-ID"]]}
        if path == "/messages/ab01":
            return {"id": "ab01", "threadId": "ab02", "payload": {
                "mimeType": "text/plain", "body": {"data": base64.urlsafe_b64encode(b"Order 12345, monitor, DKK 900").decode()},
                "headers": [{"name": "From", "value": "Butik <no-reply@shop.invalid>"},
                            {"name": "Reply-To", "value": "support@shop.invalid"},
                            {"name": "Subject", "value": "Kvittering for skærm"}],
            }}
        if path.startswith("/messages/"):
            key = path.rsplit("/", 1)[1]
            if key in self.sent:
                return deepcopy(self.sent[key])
            return next(deepcopy(row) for row in self.incoming if row["id"] == key)
        if path == "/threads/de01":
            return {"id": "de01", "messages": [*deepcopy(list(self.sent.values())), *deepcopy(self.incoming)]}
        raise AssertionError((method, path, query))

    def reply(self, key="ef01", subject="Vi har modtaget din reklamation", body="Vi ser på sagen."):
        self.incoming.append({"id": key, "threadId": "de01", "labelIds": ["INBOX"], "internalDate": "1001000",
                              "payload": {"mimeType": "text/plain", "body": {"data": base64.urlsafe_b64encode(body.encode()).decode()},
                                          "headers": [{"name": "From", "value": "Support <support@shop.invalid>"},
                                                      {"name": "Subject", "value": subject}]}})


def setup(tmp_path):
    gmail = Gmail()
    service = AgentCases(tmp_path, None, provider=lambda: gmail)
    bot, key = str(uuid4()), str(uuid4())
    body = {"action": "create", "title": "Skærmen virker ikke", "merchant": "Butik", "problem": "Skærmen tænder ikke.",
            "desired": "En ombytning", "reference": "12345"}
    case = service.mutate(bot, key, body)
    return service, gmail, bot, key, case


def action(service, bot, case, name, **extra):
    return service.mutate(bot, case["id"], {"action": name, "revision": case["revision"], **extra})


def draft(service, bot, case):
    return action(service, bot, case, "draft", recipient="support@shop.invalid")


def send(service, bot, case):
    return action(service, bot, case, "send", approved=True, draftDigest=case["draft"]["digest"])


def image():
    output = BytesIO()
    Image.new("RGB", (80, 80), "orange").save(output, "JPEG")
    return base64.b64encode(output.getvalue()).decode()


def add_photo(service, bot, case, photo_id=None):
    return service.add_photo(bot, case["id"], {"revision": case["revision"], "id": photo_id or str(uuid4()), "data": image()})


def test_case_and_receipt_lookup_are_durable_read_only_and_grounded(tmp_path):
    service, gmail, bot, key, case = setup(tmp_path)
    assert service.one(bot.upper(), key.upper()) == case
    searched = action(service, bot, case, "searchReceipt", query="Butik kvittering")
    assert searched["candidates"][0]["id"] == "ab01" and not gmail.sent
    case = action(service, bot, searched, "selectReceipt", messageID="ab01")
    assert "12345" in case["receipt"]["text"] and case["receipt"]["suggestedRecipient"] == "support@shop.invalid"
    ready = draft(service, bot, case)
    assert "Skærmen tænder ikke." in ready["draft"]["body"] and "12345" in ready["draft"]["body"]
    assert "900" not in ready["draft"]["body"]  # Not guessed/extracted as a claimed refund.
    assert "Kvittering for skærm" in ready["draft"]["body"] and not gmail.sent
    assert "account" not in ready
    restarted = AgentCases(tmp_path, None, provider=lambda: gmail)
    assert restarted.list(bot)["cases"] == [ready]


def test_photos_are_real_mime_attachments_and_sent_receipt_is_read_back(tmp_path):
    service, gmail, bot, _, case = setup(tmp_path)
    case = add_photo(service, bot, case)
    ready = draft(service, bot, case)
    done = send(service, bot, ready)
    assert done["state"] == "waiting" and done["outgoing"]["verified"]
    assert done["outgoing"]["threadID"] == "de01" and len(gmail.sent) == 1
    raw = base64.urlsafe_b64decode(next(iter(gmail.sent.values()))["raw"])
    mime = BytesParser(policy=policy.default).parsebytes(raw)
    attachment = next(mime.iter_attachments())
    assert attachment.get_filename() == ready["photos"][0]["name"]
    assert sha256(attachment.get_payload(decode=True)).hexdigest() == ready["photos"][0]["sha256"]
    assert any(query == {"format": "raw"} for _, _, _, query in gmail.requests)
    assert [v["kind"] for v in done["events"]].count("sent") == 1


@pytest.mark.parametrize("change", [{"approved": False}, {"draftDigest": "other"}, {"revision": 0}])
def test_send_requires_the_exact_reviewed_draft_and_current_revision(tmp_path, change):
    service, gmail, bot, _, case = setup(tmp_path)
    case = draft(service, bot, case)
    with pytest.raises(ApiError):
        action(service, bot, case, "send", **({"approved": True, "draftDigest": case["draft"]["digest"]} | change))
    assert not gmail.sent


def test_content_photo_and_recipient_edits_invalidate_old_approval(tmp_path):
    service, gmail, bot, _, case = setup(tmp_path)
    old = draft(service, bot, case)
    case = add_photo(service, bot, old)
    assert case["draft"]["digest"] != old["draft"]["digest"]
    assert case["draft"]["body"] == old["draft"]["body"]
    with pytest.raises(ApiError):
        send(service, bot, old)
    ready = draft(service, bot, case)
    edited = action(service, bot, ready, "draft", recipient="another@shop.invalid", subject=ready["draft"]["subject"], body="En præcis, ny tekst.")
    with pytest.raises(ApiError):
        send(service, bot, ready)
    assert edited["draft"]["digest"] != ready["draft"]["digest"] and not gmail.sent


def test_response_lost_after_send_is_recovered_without_resending(tmp_path):
    service, gmail, bot, _, case = setup(tmp_path)
    ready = draft(service, bot, case)
    gmail.after = True
    done = send(service, bot, ready)
    assert done["outgoing"]["verified"] and len(gmail.sent) == 1
    again = send(service, bot, ready)
    assert again["outgoing"]["messageID"] == done["outgoing"]["messageID"] and len(gmail.sent) == 1
    assert len([v for v in gmail.requests if v[0] == "POST"]) == 1


def test_process_interruption_before_receipt_is_durable_and_not_resent(tmp_path):
    service, gmail, bot, _, case = setup(tmp_path)
    ready = draft(service, bot, case)
    gmail.crash = True
    with pytest.raises(SystemExit):
        send(service, bot, ready)
    restarted = AgentCases(tmp_path, None, provider=lambda: gmail)
    saved = restarted.one(bot, ready["id"])
    assert saved["state"] == "sending" and saved["outgoing"]["messageID"] is None
    done = action(restarted, bot, saved, "refresh")
    assert done["outgoing"]["verified"] and len(gmail.sent) == 1
    assert len([v for v in gmail.requests if v[0] == "POST"]) == 1


def test_unconfirmed_send_is_never_automatically_retried_even_when_gmail_has_no_match(tmp_path):
    service, gmail, bot, _, case = setup(tmp_path)
    ready = draft(service, bot, case)
    gmail.before = True
    uncertain = send(service, bot, ready)
    assert uncertain["state"] == "uncertain" and not uncertain["outgoing"]["verified"]
    gmail.before = False
    again = send(service, bot, ready)
    assert again["state"] == "uncertain" and not gmail.sent
    service.tick()
    assert len([v for v in gmail.requests if v[0] == "POST"]) == 1


@pytest.mark.parametrize("field", ["To", "Subject", "Message-ID"])
def test_provider_success_is_not_enough_when_readback_content_changed(tmp_path, field):
    service, gmail, bot, _, case = setup(tmp_path)
    ready = draft(service, bot, case)
    gmail.rewrite = lambda mail: mail.replace_header(field, "wrong@else.invalid" if field == "To" else "Changed content")
    result = send(service, bot, ready)
    assert not result["outgoing"]["verified"] and result["state"] == "uncertain"
    assert not any(row["kind"] == "sent" for row in result["events"])


def test_same_account_and_same_thread_are_required_for_followup_and_closure_is_user_decision(tmp_path):
    service, gmail, bot, _, case = setup(tmp_path)
    sent = send(service, bot, draft(service, bot, case))
    gmail.reply(body="Vi har refunderet beløbet.")
    received = action(service, bot, sent, "refresh")
    assert received["state"] == "reply" and len(received["incoming"]) == 1
    assert "refunderet" in received["incoming"][0]["text"]
    again = action(service, bot, received, "refresh")
    assert len(again["incoming"]) == 1
    assert [v["kind"] for v in again["events"]].count("incoming") == 1
    assert again["state"] != "closed"  # A merchant's claim does not automatically resolve the case.
    gmail.account = "other-account"
    count = len(gmail.requests)
    blocked = action(service, bot, again, "refresh")
    assert len(gmail.requests) == count and "anden Gmail-konto" in blocked["note"]
    closed = action(service, bot, blocked, "close", approved=True, reason="Jeg har selv set pengene på kontoen.")
    assert closed["state"] == "closed" and not closed["watch"]
    assert action(service, bot, closed, "reopen")["state"] == "reply"


def test_changed_or_unrelated_thread_is_not_treated_as_a_new_reply(tmp_path):
    service, gmail, bot, _, case = setup(tmp_path)
    done = send(service, bot, draft(service, bot, case))
    gmail.reply()
    gmail.incoming[0]["threadId"] = "ff02"
    result = action(service, bot, done, "refresh")
    assert not result["incoming"] and result["state"] == "waiting"
    gmail.sent.clear()
    result = action(service, bot, result, "refresh")
    assert "kunne ikke bekræftes" in result["note"] and not result["incoming"]


def test_watch_worker_only_reads_bound_active_cases_and_can_be_disabled(tmp_path):
    service, gmail, bot, _, case = setup(tmp_path)
    done = send(service, bot, draft(service, bot, case))
    gmail.reply()
    stored = service.load(bot, done["id"])
    stored["nextCheck"] = 0
    service.save(stored)
    service.tick()
    checked = service.one(bot, done["id"])
    assert checked["state"] == "reply" and len(gmail.sent) == 1
    disabled = action(service, bot, checked, "watch", enabled=False)
    count = len(gmail.requests)
    service.tick()
    assert len(gmail.requests) == count and not disabled["watch"]


def test_photo_retries_are_idempotent_and_removal_releases_bytes(tmp_path):
    service, gmail, bot, _, case = setup(tmp_path)
    key = str(uuid4())
    case = add_photo(service, bot, case, key)
    retried = service.add_photo(bot, case["id"], {"id": key, "revision": 1, "data": image()})
    assert retried == case and len(case["photos"]) == 1
    assert service.photo(bot, case["id"], key)["data"]
    case = action(service, bot, case, "removePhoto", photoID=key)
    assert not case["photos"]
    with pytest.raises(ApiError):
        service.photo(bot, case["id"], key)
    case = add_photo(service, bot, case)
    removed = action(service, bot, case, "remove", approved=True)
    assert removed == {"removed": True} and not service.list(bot)["cases"]
    with service.db() as db:
        assert db.execute("SELECT count(*) FROM photos").fetchone()[0] == 0
    with pytest.raises(ApiError):
        service.create(bot, case["id"], {k: case[k] for k in ("title", "merchant", "problem", "desired", "reference")})


def test_incomplete_receipt_scope_or_damaged_photo_prevents_unreviewed_data_from_sending(tmp_path):
    service, gmail, bot, _, case = setup(tmp_path)
    with pytest.raises(ApiError):
        action(service, bot, case, "selectReceipt", messageID="abcd")
    case = add_photo(service, bot, case)
    ready = draft(service, bot, case)
    with service.db() as db:
        db.execute("UPDATE photos SET body=?", (b"damaged",))
    with pytest.raises(ApiError):
        send(service, bot, ready)
    assert not gmail.sent


def test_draft_only_case_can_close_reopen_and_requires_explicit_close_decision(tmp_path):
    service, gmail, bot, _, case = setup(tmp_path)
    with pytest.raises(ApiError):
        action(service, bot, case, "close", reason="færdig")
    closed = action(service, bot, case, "close", approved=True, reason="Jeg løste det selv.")
    with pytest.raises(ApiError):
        draft(service, bot, closed)
    assert action(service, bot, closed, "reopen")["state"] == "draft"


def test_proxy_envelope_checks_success_before_reading_any_provider_data():
    assert unpack({"successful": True, "data": {"status": 200, "data": {"id": "ab01"}}}) == {"id": "ab01"}
    with pytest.raises(ApiError):
        unpack({"successful": False, "data": {"status": 403, "data": {"id": "ab01"}}})


def test_definite_provider_rejection_requires_a_fresh_user_review_before_retry(tmp_path):
    service, gmail, bot, _, case = setup(tmp_path)
    ready = draft(service, bot, case)
    original = gmail.send
    def reject(*_):
        raise GmailRejected(403, "NOT_READY", "Gmail mangler skrivetilladelse.")
    gmail.send = reject
    rejected = send(service, bot, ready)
    assert rejected["outgoing"] is None and rejected["state"] == "draft" and not gmail.sent
    service.tick()
    with pytest.raises(ApiError):
        send(service, bot, ready)  # The previously approved request cannot simply be replayed.
    gmail.send = original
    done = send(service, bot, rejected)  # A new explicit review with current revision.
    assert done["outgoing"]["verified"] and len(gmail.sent) == 1


def test_four_compressed_photos_fit_the_existing_mcp_readback_limit(tmp_path):
    service, gmail, bot, _, case = setup(tmp_path)
    for _ in range(4):
        case = add_photo(service, bot, case)
    ready = draft(service, bot, case)
    done = send(service, bot, ready)
    assert done["outgoing"]["verified"] and len(done["outgoing"]["photos"]) == 4
    assert all(p["bytes"] <= 200_000 for p in done["photos"])
    import json
    assert len(json.dumps(next(iter(gmail.sent.values())))) < 2_000_000


@pytest.mark.parametrize("kind", ["text", "attachment"])
def test_modified_body_or_missing_photo_never_counts_as_verified_sent(tmp_path, kind):
    service, gmail, bot, _, case = setup(tmp_path)
    if kind == "attachment":
        case = add_photo(service, bot, case)
        def rewrite(mail):
            next(mail.iter_attachments()).set_payload(base64.b64encode(b"different image").decode())
    else:
        def rewrite(mail):
            mail.set_content("A different, unreviewed message.")
    gmail.rewrite = rewrite
    result = send(service, bot, draft(service, bot, case))
    assert result["state"] == "uncertain" and not result["outgoing"]["verified"]
    assert not any(event["kind"] == "sent" for event in result["events"])


def test_routes_require_pairing_and_preserve_case_and_photo_identity(tmp_path):
    from fastapi import FastAPI, HTTPException
    from fastapi.testclient import TestClient
    from sweatcaster.agent_cases import register_agent_cases
    app = FastAPI()
    def authorize(request, _):
        if request.headers.get("Authorization") != "Bearer synthetic":
            raise HTTPException(401)
    service = register_agent_cases(app, SimpleNamespace(output_root=tmp_path), authorize, None)
    gmail = Gmail()
    service.provider = lambda: gmail
    bot, key = str(uuid4()), str(uuid4())
    with TestClient(app) as client:
        params = {"bot_id": bot}
        assert client.get("/api/modules/v1/agent-cases", params=params).status_code == 401
        client.headers["Authorization"] = "Bearer synthetic"
        response = client.put("/api/modules/v1/agent-cases/" + key, params=params, json={
            "action": "create", "title": "Defekt skærm", "problem": "Skærmen blinker.",
        })
        assert response.status_code == 200 and response.headers["Cache-Control"] == "no-store"
        case = response.json()
        photo_id = str(uuid4())
        response = client.put("/api/modules/v1/agent-cases/" + key + "/photos", params=params, json={
            "id": photo_id, "revision": case["revision"], "data": image(),
        })
        assert response.status_code == 200
        case = response.json()
        assert client.get("/api/modules/v1/agent-cases/" + key + "/photos/" + photo_id, params=params).json()["data"]
        assert client.get("/api/modules/v1/agent-cases/" + key, params=params).json() == case
        assert client.get("/api/modules/v1/agent-cases", params=params).json()["cases"] == [case]
        assert not gmail.sent

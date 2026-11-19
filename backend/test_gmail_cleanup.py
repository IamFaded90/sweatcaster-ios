from contextlib import nullcontext
from copy import deepcopy
import json
from types import SimpleNamespace
from uuid import uuid4

import pytest

from sweatcaster.dto import ApiError
from sweatcaster.gmail_cleanup import GmailCleanup, search_query
from sweatcaster.gmail_cleanup_provider import CleanupGmail


class Gmail:
    account = "owner-connection"

    def __init__(self):
        self.messages = {
            "aa01": {"id": "aa01", "sender": "Butik", "subject": "Gamle tilbud", "labels": ["INBOX", "CATEGORY_PROMOTIONS"]},
            "aa02": {"id": "aa02", "sender": "Butik", "subject": "Nye tilbud", "labels": ["INBOX", "UNREAD", "CATEGORY_PROMOTIONS"]},
            "aa03": {"id": "aa03", "sender": "Firma", "subject": "En vigtig besked", "labels": ["INBOX", "STARRED"]},
            "aa04": {"id": "aa04", "sender": "Læge", "subject": "Din aftale hos tandlægen", "labels": ["INBOX"]},
            "aa05": {"id": "aa05", "sender": "Butik", "subject": "Gamle nyheder", "labels": ["INBOX", "CATEGORY_PROMOTIONS"]},
        }
        self.changes = []
        self.list_calls = []
        self.fail = set()
        self.uncertain = set()
        self.read_fail = set()
        self.crash = False

    def connected(self):
        return nullcontext(self)

    def list(self, query, limit):
        self.list_calls.append(query)
        return {"ids": list(self.messages)[:limit], "more": len(self.messages) > limit}

    def read(self, key):
        if key in self.read_fail:
            raise ApiError(502, "NOT_READY", "read failed")
        return deepcopy(self.messages[key])

    def modify(self, key, add, remove):
        self.changes.append((key, add, remove))
        if key in self.fail:
            raise ApiError(502, "NOT_READY", "failed")
        self.messages[key]["labels"] = sorted((set(self.messages[key]["labels"]) | set(add)) - set(remove))
        if self.crash:
            self.crash = False
            raise SystemExit("simulated process interruption after Gmail changed")
        if key in self.uncertain:
            raise ApiError(502, "NOT_READY", "response lost after Gmail changed")


def setup(tmp_path, **kwargs):
    provider = Gmail()
    service = GmailCleanup(tmp_path / "cleanup.sqlite", None, provider=lambda: provider)
    bot = str(uuid4())
    body = {"id": str(uuid4()), "prompt": "Ryd op i reklamer ældre end 3 måneder", **kwargs}
    job = service.preview(bot, body)
    return service, provider, bot, body, job


def apply(service, bot, job, **kwargs):
    return service.change(job["id"], bot, {"action": "apply", "approved": True, "revision": job["revision"],
                                          "selected": ["aa01", "aa05"], **kwargs})


def change(service, bot, job, action):
    return service.change(job["id"], bot, {"action": action, "approved": True})


def test_preview_is_read_only_and_protects_important_unread_personal_and_health_mail(tmp_path):
    service, gmail, bot, body, job = setup(tmp_path)
    assert job["counts"]["ready"] == 2 and job["counts"]["protected"] == 3
    assert "older_than:3m" in job["query"] and "in:inbox" in job["query"]
    assert not gmail.changes and "account" not in job
    assert service.preview(bot.upper(), body) == job and len(gmail.list_calls) == 1
    assert service.history(bot)["items"] == [job]


def test_archiving_and_undo_have_verified_receipts_and_preserve_new_labels(tmp_path):
    service, gmail, bot, _, job = setup(tmp_path)
    done = apply(service, bot, job)
    assert done["state"] == "complete" and done["counts"]["applied"] == 2
    assert all("INBOX" not in gmail.messages[key]["labels"] for key in ("aa01", "aa05"))
    assert "INBOX" in gmail.messages["aa02"]["labels"]
    gmail.messages["aa01"]["labels"].append("Label_NEW")
    undone = change(service, bot, done, "undo")
    assert undone["state"] == "restored" and undone["counts"]["restored"] == 2
    assert "Label_NEW" in gmail.messages["aa01"]["labels"]
    assert all("INBOX" in gmail.messages[key]["labels"] for key in ("aa01", "aa05"))


def test_same_approval_retries_only_uncompleted_messages_and_verifies_timeout(tmp_path):
    service, gmail, bot, _, job = setup(tmp_path)
    gmail.uncertain.add("aa01")
    gmail.fail.add("aa05")
    partial = apply(service, bot, job)
    assert partial["state"] == "partial" and partial["counts"]["applied"] == 1
    assert partial["counts"]["failed"] == 1
    gmail.fail.clear()
    done = apply(service, bot, partial)
    assert done["state"] == "complete" and done["counts"]["applied"] == 2
    assert [x[0] for x in gmail.changes].count("aa01") == 1
    assert [x[0] for x in gmail.changes].count("aa05") == 2
    assert apply(service, bot, done)["counts"]["applied"] == 2
    assert len(gmail.changes) == 3


def test_durable_scope_survives_process_crash_after_the_remote_change(tmp_path):
    service, gmail, bot, _, job = setup(tmp_path)
    gmail.crash = True
    with pytest.raises(SystemExit):
        apply(service, bot, job)
    restarted = GmailCleanup(service.path, None, provider=lambda: gmail)
    saved = restarted.one(job["id"], bot)
    assert saved["counts"]["uncertain"] == 1
    checked = change(restarted, bot, saved, "verify")
    assert checked["counts"]["applied"] == 1 and len(gmail.changes) == 1
    done = apply(restarted, bot, checked)
    assert done["counts"]["applied"] == 2 and len(gmail.changes) == 2


@pytest.mark.parametrize("override", [
    {"selected": ["aa02"]}, {"selected": ["deadbeef"]}, {"selected": []},
    {"approved": False}, {"revision": 0}, {"action": "delete"}, {"selected": "aa01"},
])
def test_unreviewed_protected_or_missing_approval_cannot_change_mail(tmp_path, override):
    service, gmail, bot, _, job = setup(tmp_path)
    with pytest.raises(ApiError):
        apply(service, bot, job, **override)
    assert not gmail.changes


def test_changed_mail_is_skipped_and_approved_scope_cannot_be_expanded(tmp_path):
    service, gmail, bot, _, job = setup(tmp_path)
    gmail.messages["aa01"]["labels"].append("STARRED")
    done = apply(service, bot, job)
    assert done["counts"]["skipped"] == 1 and done["counts"]["applied"] == 1
    with pytest.raises(ApiError):
        apply(service, bot, done, selected=["aa01", "aa02", "aa05"])
    assert [x[0] for x in gmail.changes] == ["aa05"]


def test_switched_gmail_account_rejects_apply_and_undo(tmp_path):
    service, gmail, bot, _, job = setup(tmp_path)
    gmail.account = "another-account"
    with pytest.raises(ApiError):
        apply(service, bot, job)
    assert not gmail.changes
    gmail.account = "owner-connection"
    done = apply(service, bot, job)
    gmail.account = "another-account"
    with pytest.raises(ApiError):
        change(service, bot, done, "undo")
    assert len(gmail.changes) == 2


def test_trash_needs_specific_approval_is_reversible_and_never_permanently_deletes(tmp_path):
    service, gmail, bot, _, job = setup(tmp_path, mode="trash")
    with pytest.raises(ApiError):
        apply(service, bot, job)
    assert not gmail.changes
    done = apply(service, bot, job, confirmTrash=True)
    assert done["counts"]["applied"] == 2
    assert "TRASH" in gmail.messages["aa01"]["labels"]
    undone = change(service, bot, done, "undo")
    assert undone["counts"]["restored"] == 2
    assert "TRASH" not in gmail.messages["aa01"]["labels"]
    assert "INBOX" in gmail.messages["aa01"]["labels"]
    with pytest.raises(ApiError):
        setup(tmp_path / "other", mode="permanent")


def test_readback_is_required_and_verify_does_not_mutate(tmp_path):
    service, gmail, bot, _, job = setup(tmp_path)
    original = gmail.modify
    def lost_readback(key, add, remove):
        original(key, add, remove)
        gmail.read_fail.add(key)
    gmail.modify = lost_readback
    uncertain = apply(service, bot, job)
    assert uncertain["counts"]["applied"] == 0 and uncertain["counts"]["uncertain"] == 2
    gmail.read_fail.clear()
    done = change(service, bot, uncertain, "verify")
    assert done["counts"]["applied"] == 2 and len(gmail.changes) == 2


def test_missing_labels_are_protected_and_expired_preview_cannot_apply(tmp_path):
    service, gmail, bot, _, job = setup(tmp_path)
    gmail.read_fail.add("aa01")
    preview = service.preview(bot, {"id": str(uuid4())})
    assert preview["messages"][0]["state"] == "protected"
    private = service.load(job["id"], bot)
    private["created"] -= 1801
    service.save(private)
    with pytest.raises(ApiError):
        apply(service, bot, job)
    assert not gmail.changes


def test_undo_respects_later_manual_moves_and_cannot_reapply_after_restore(tmp_path):
    service, gmail, bot, _, job = setup(tmp_path)
    done = apply(service, bot, job)
    gmail.messages["aa01"]["labels"].append("TRASH")
    undone = change(service, bot, done, "undo")
    assert undone["counts"]["skipped"] == 1 and undone["counts"]["restored"] == 1
    assert "TRASH" in gmail.messages["aa01"]["labels"]
    with pytest.raises(ApiError):
        apply(service, bot, undone)


def test_schema_adapter_reads_only_metadata_and_allows_only_fixed_reversible_labels():
    calls = []
    def execute(slug, args):
        calls.append((slug, args))
        if slug == "GMAIL_GET_PROFILE":
            return {"emailAddress": "test@example.invalid"}
        return {"messageId": "abcd", "labelIds": ["INBOX"], "subject": "Test"}
    provider = CleanupGmail(SimpleNamespace(account="existing-connection", _execute=execute))
    assert provider.read("abcd")["labels"] == ["INBOX"]
    assert calls[-1][1]["format"] == "metadata"
    with pytest.raises(ApiError):
        provider.modify("abcd", ["SENT"], [])
    with pytest.raises(ApiError):
        provider.read("a-uuid")
    provider.consumer._execute = lambda *_: {"messageId": "abcd", "subject": "Missing labels"}
    with pytest.raises(ApiError):
        provider.read("abcd")


def test_request_can_be_natural_but_query_always_stays_in_the_inbox():
    assert "older_than:14d" in search_query("Ryd op i nyhedsbreve fra før 2 uger")
    assert "older_than:1m" in search_query("Ryd op i gamle mails")
    assert search_query("", "in:anywhere OR in:sent").startswith("in:inbox -in:trash -in:spam -in:sent -in:drafts (")


def test_public_payload_can_be_saved_as_the_swift_fixture(tmp_path):
    service, gmail, bot, _, job = setup(tmp_path)
    assert json.loads(json.dumps(job)) == job
    assert {"id", "botID", "mode", "state", "counts", "selected", "receipt", "created"} <= job.keys()


def test_routes_require_pairing_and_expose_the_same_reviewed_scope(tmp_path):
    from fastapi import FastAPI, HTTPException
    from fastapi.testclient import TestClient
    from sweatcaster.gmail_cleanup import register_gmail_cleanup
    app = FastAPI()
    def authorize(request, _):
        if request.headers.get("Authorization") != "Bearer synthetic-pairing":
            raise HTTPException(401)
    service = register_gmail_cleanup(app, SimpleNamespace(output_root=tmp_path), authorize, None)
    gmail = Gmail()
    service.provider = lambda: gmail
    bot = str(uuid4())
    with TestClient(app) as client:
        assert client.get("/api/modules/v1/gmail-cleanup", params={"bot_id": bot}).status_code == 401
        client.headers["Authorization"] = "Bearer synthetic-pairing"
        response = client.put("/api/modules/v1/gmail-cleanup/preview", params={"bot_id": bot}, json={"prompt": "Ryd op i reklamer"})
        assert response.status_code == 200 and response.headers["Cache-Control"] == "no-store"
        job = response.json()
        done = client.put("/api/modules/v1/gmail-cleanup/" + job["id"], params={"bot_id": bot}, json={
            "action": "apply", "approved": True, "revision": job["revision"], "selected": ["aa01"],
        }).json()
        assert done["counts"]["applied"] == 1
        assert client.get("/api/modules/v1/gmail-cleanup/" + job["id"], params={"bot_id": bot}).json() == done
        assert client.get("/api/modules/v1/gmail-cleanup", params={"bot_id": bot}).json()["items"] == [done]


def test_connection_schema_is_required_before_the_modify_tool_and_arguments_are_narrow():
    from contextlib import contextmanager
    calls = []
    @contextmanager
    def session():
        yield object()
    def call(_, tool, arguments, __):
        calls.append((tool, arguments))
        if tool == "COMPOSIO_SEARCH_TOOLS":
            return {"data": {"session": {"id": "synthetic"}, "tool_schemas": {
                "GMAIL_ADD_LABEL_TO_EMAIL": {"input_schema": {"properties": {
                    "message_id": {}, "add_label_ids": {}, "remove_label_ids": {},
                }}},
            }}}
        return {"successful": True, "data": {"results": [{"tool_slug": "GMAIL_ADD_LABEL_TO_EMAIL", "response": {"successful": True}}]}}
    consumer = SimpleNamespace(account="synthetic", session=session, _call=call,
                               _execute=lambda *_: {"emailAddress": "test@example.invalid"})
    provider = CleanupGmail(consumer)
    with provider.connected():
        provider.modify("abcd", [], ["INBOX"])
    write = calls[-1][1]["tools"][0]
    assert write == {"tool_slug": "GMAIL_ADD_LABEL_TO_EMAIL", "arguments": {
        "user_id": "me", "message_id": "abcd", "add_label_ids": [], "remove_label_ids": ["INBOX"],
    }}
    assert provider.session is None


def test_missing_write_scope_is_reported_without_claiming_a_completed_change(tmp_path):
    service, gmail, bot, _, job = setup(tmp_path)
    def denied(*_):
        raise ApiError(403, "NOT_READY", "Gmail mangler tilladelse. Forbind Gmail igen i Composio.")
    gmail.modify = denied
    failed = apply(service, bot, job)
    assert failed["counts"]["applied"] == 0 and failed["counts"]["failed"] == 2
    assert all("Composio" in row["note"] for row in failed["messages"] if row["state"] == "failed")
    assert "INBOX" in gmail.messages["aa01"]["labels"]

import json
from urllib.parse import quote, unquote
from uuid import uuid4

import pytest

from sweatcaster.agentmail_inboxes import InboxService
from sweatcaster.dto import ApiError


class MailFixture(InboxService):
    def __init__(self, database):
        super().__init__(database, get_key=lambda: "test-owner-key")
        self.inboxes = {}
        self.created = 0
        self.ambiguous = False
        self.other_inbox = None

    def request(self, key, method, route, *, body=None, params=None):
        assert key == "test-owner-key"
        if method == "POST":
            assert route == "/inboxes"
            self.created += 1
            address = f'{body["username"]}@{body["domain"]}'
            result = {"inbox_id": address, "client_id": body["client_id"]}
            self.inboxes[address] = result
            if self.ambiguous:
                raise ApiError(502, "NOT_READY", "Interrupted.")
            return result

        segments = route.split("/")
        assert segments[:2] == ["", "inboxes"]
        address = unquote(segments[2])
        if len(segments) == 3:
            return self.inboxes.get(address)
        if len(segments) == 4:
            assert segments[3] == "messages" and params == {"limit": 25}
            return {"messages": [
                {"inbox_id": address, "message_id": "<first@sender.test>", "subject": "First"},
                {"inbox_id": self.other_inbox, "message_id": "<second@sender.test>", "subject": "Second"},
            ]}
        assert len(segments) == 5 and segments[3] == "messages"
        msg = unquote(segments[4])
        inbox_id = self.other_inbox if msg.startswith("<second") else address
        return {"inbox_id": inbox_id, "message_id": msg, "text": "Selected text test-owner-key."}


def test_agent_inbox_recovers_an_ambiguous_create_and_survives_renaming(tmp_path):
    service = MailFixture(tmp_path / "mail.sqlite3")
    bot = str(uuid4())
    assert service.status(bot)["address"] is None
    service.ambiguous = True
    original = service.create(bot, "Adam")
    assert service.create(bot, "Adam renamed") == original
    assert service.created == 1
    assert MailFixture(service.database).identity(bot) == service.identity(bot)
    assert MailFixture(tmp_path / "other.db").identity(bot) != service.identity(bot)


def test_agents_cannot_read_other_inboxes_and_owner_key_is_redacted(tmp_path):
    service = MailFixture(tmp_path / "mail.sqlite3")
    adam, eva = str(uuid4()), str(uuid4())
    service.create(adam, "Adam")
    service.other_inbox = service.create(eva, "Eva")["address"]
    messages = service.messages(adam)["messages"]
    assert [row["subject"] for row in messages] == ["First"]
    assert service.message(adam, messages[0]["id"]) == {"text": "Selected text [skjult]."}
    with pytest.raises(ApiError) as failure:
        service.message(adam, "<second@sender.test>")
    assert failure.value.status_code == 404
    with pytest.raises(ApiError) as invalid:
        service.message(adam, "../" + quote(messages[0]["id"], safe=""))
    assert invalid.value.status_code == 422


def test_no_setup_key_means_no_inbox_request_or_database(tmp_path):
    path = tmp_path / "mail.sqlite3"
    service = InboxService(path, get_key=lambda: "")
    assert service.status(str(uuid4())) == {"configured": False, "address": None, "active": False}
    assert not path.exists()


def test_signup_verifies_only_on_starting_bot_and_keeps_original_inbox(tmp_path, monkeypatch):
    record = {}

    def persist(data):
        record.clear()
        record.update(json.loads(data))

    service = InboxService(tmp_path / "mail.sqlite3", get_key=lambda: record.get("key", ""),
                           get_setup=lambda: record, persist_setup=persist)
    adam, eva = str(uuid4()), str(uuid4())
    username, address, _ = service.identity(adam)
    called = []

    def request(key, method, route, *, body=None, params=None):
        called.append(route)
        if route == "/agent/sign-up":
            assert key == "" and method == "POST"
            assert body["username"] == username and body["human_email"] == "owner@example.test"
            return {"api_key": "test-owner-key", "inbox_id": address}
        assert key == "test-owner-key"
        if route == "/agent/verify":
            assert body == {"otp_code": "123456"}
            return {"verified": True}
        if route == "/agent/human":
            assert body == {"human_email": "owner@example.test"}
            return {"human_email": "owner@example.test"}
        return {"inbox_id": address} if unquote(route.rsplit("/", 1)[-1]) == address else None

    monkeypatch.setattr(service, "request", request)
    assert service.enroll(adam, "owner@example.test")["verificationRequired"]
    assert service.enroll(adam, "owner@example.test")["verificationRequired"]
    assert service.status(eva)["verificationElsewhere"]
    with pytest.raises(ApiError):
        service.confirm(eva, "123456")
    assert called == ["/agent/sign-up"]
    assert service.resend(adam)["verificationRequired"]
    assert called[-1] == "/agent/human"
    assert record["key"] == "test-owner-key"
    assert service.confirm(adam, "123456") == {"configured": True, "address": address, "active": True}
    assert "owner_email" not in record
    assert service.confirm(adam, "123456") == service.create(adam, "Adam")
    assert called.count("/agent/verify") == 1
    assert service.status(eva)["address"] is None

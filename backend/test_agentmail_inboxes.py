import json
from urllib.parse import quote, unquote
from uuid import uuid4

import pytest
from fastapi import FastAPI, HTTPException
from fastapi.testclient import TestClient

from sweatcaster.agentmail_inboxes import InboxService, register_agentmail
from sweatcaster.agent_email import AgentEmail
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


def test_signup_address_preserved_on_rename_and_provider_change(tmp_path):
    service = MailFixture(tmp_path / "mail.sqlite3")
    service.get_key = lambda: ""

    class Gmail:
        account = "person@example.org"

        def read(self, provider, endpoint):
            assert provider == "gmail" and endpoint.endswith("/users/me/profile")
            return {"emailAddress": self.account}

    gmail = Gmail()
    agents = AgentEmail(service, gmail)
    first = "00000000-0000-4000-8000-000000000001"
    second = "00000000-0000-4000-8000-000000000002"
    original = agents.create(first, "Eva")
    assert original["kind"] == "gmailAlias"
    assert original["address"].startswith("person+eva-")
    assert agents.create(second, "Eva") != original
    service.get_key = lambda: "test-owner-key"
    assert AgentEmail(service, gmail).create(first, "Nyt navn") == original
    assert service.created == 0
    gmail.account = "another@example.org"
    with pytest.raises(ApiError) as changed:
        agents.create(first, "Eva")
    assert changed.value.status_code == 409
    with pytest.raises(ApiError):
        agents.create("wrong", "Eva")


def test_signup_supports_configured_dedicated_inbox(tmp_path):
    service = MailFixture(tmp_path / "mail.sqlite3")
    class Gmail:
        def read(self, provider, endpoint):
            return {"emailAddress": "user@example.org"}
    agents = AgentEmail(service, Gmail())
    bot = str(uuid4())
    address = agents.create(bot, "Helene")
    assert address["kind"] == "mailbox"
    assert address["address"] == service.identity(bot)[1]
    assert agents.create(bot, "Andet navn") == address
    assert agents.messages(bot)["messages"][0]["subject"] == "First"
    assert agents.message(bot, "<first@sender.test>")["text"]
    alias = agents.create(bot, "Helene", gmail=True)
    assert alias["kind"] == "gmailAlias" and alias["address"] != address["address"]
    assert agents.create(bot, "Nyt navn") == address
    assert agents.create(bot, "Nyt navn", gmail=True) == alias
    assert agents.mailbox(bot, gmail=True) == (alias["address"], "gmailAlias")
    assert service.created == 1


def test_alias_only_opens_its_own_signup_messages(tmp_path):
    service = InboxService(tmp_path / "mail.sqlite3", get_key=lambda: "")

    class Gmail:
        recipient = None
        query = None

        def gmail(self):
            return self

        def recent(self, query):
            self.query = query
            return [{"id": "private"}, {"id": "unknown"}, {"id": "own"}]

        def read(self, provider, endpoint, options=None):
            if endpoint.endswith("/profile"):
                return {"emailAddress": "family@example.org"}
            assert options == {"format": "metadata"}
            identifier = endpoint.rsplit("/", 1)[1]
            return {"id": identifier, "subject": "Kode 852931", "to": {
                "private": "family+another@example.org", "unknown": None, "own": self.recipient}[identifier]}

        def read_gmail_message(self, identifier):
            return {"id": identifier, "payload": {"headers": [{"name": "Delivered-To", "value": self.recipient}]},
                    "snippet": "Din tilmelding er klar."}

    gmail = Gmail()
    agents = AgentEmail(service, gmail)
    bot = str(uuid4())
    with pytest.raises(ApiError) as missing:
        agents.messages(bot)
    assert missing.value.status_code == 404
    address = agents.create(bot, "Lumi")["address"]
    gmail.recipient = address
    assert agents.messages(bot) == {"messages": [
        {"id": "own", "subject": "Kode 852931", "sender": "", "timestamp": ""}]}
    assert f'deliveredto:"{address}"' in gmail.query
    gmail.recipient = "family@example.org"
    with pytest.raises(ApiError) as denied:
        agents.message(bot, "other")
    assert denied.value.status_code == 404
    gmail.recipient = address
    assert agents.message(bot, "own") == {"text": "Din tilmelding er klar."}


def test_signup_routes_require_pairing_and_work_with_existing_gmail(tmp_path, monkeypatch):
    from types import SimpleNamespace

    class Gmail:
        def read(self, provider, endpoint):
            return {"emailAddress": "owner@example.org"}

        def gmail(self):
            return self

        def recent(self, query):
            assert "owner+eva-" in query
            return []

    def authorize(request, settings):
        if request.headers.get("Authorization") != "Bearer paired":
            raise HTTPException(401)

    monkeypatch.setenv("LOCALAPPDATA", str(tmp_path))
    monkeypatch.delenv("AGENTMAIL_API_KEY", raising=False)
    app = FastAPI()
    register_agentmail(app, SimpleNamespace(output_root=tmp_path), authorize, Gmail())
    client = TestClient(app)
    url = f"/api/modules/v1/agent-email/{uuid4()}"
    assert client.put(url, json={"name": "Eva"}).status_code == 401
    assert client.get(url + "/messages").status_code == 401
    assert client.get(url + "/message?message_id=abc").status_code == 401
    paired = {"Authorization": "Bearer paired"}
    created = client.put(url, json={"name": "Eva"}, headers=paired)
    assert created.status_code == 200
    assert created.headers["cache-control"] == "no-store"
    assert created.json()["kind"] == "gmailAlias"
    assert client.get(url + "/messages", headers=paired).json() == {"messages": []}


def test_html_confirmation_mail_preserves_visible_action_link_without_fetching_it():
    import base64
    from sweatcaster.mail_appointments import mail_text

    html = ('<a href="https://example.org/verify?code=abc">Bekræft din adresse</a>'
            '<a href="javascript:bad()">Footer</a>')
    encoded = base64.urlsafe_b64encode(html.encode()).decode()
    item = {"payload": {"mimeType": "text/html", "body": {"data": encoded}}}
    assert "Bekræft din adresse (https://example.org/verify?code=abc)" in mail_text(item, include_links=True)
    assert "javascript:" not in mail_text(item, include_links=True)
    assert "https://" not in mail_text(item)


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

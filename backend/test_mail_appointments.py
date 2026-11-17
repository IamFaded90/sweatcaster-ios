import base64
import json
from datetime import datetime, timedelta, timezone
from uuid import uuid4
from zoneinfo import ZoneInfo

from fastapi.testclient import TestClient

from sweatcaster.api import create_app
from sweatcaster.composio_library import ComposioLibrary, GMAIL_CONFIG_NAME, GMAIL_READ_SCOPE
from sweatcaster.composio_gmail import ConsumerGmail, MESSAGES
from sweatcaster.mail_appointments import GMAIL, MailAppointments, decode_appointment, decode_proposal, mail_text
from tests.conftest import make_settings


def test_mail_intake_extracts_plain_text_and_cleans_html():
    def part(text, kind):
        return {"mimeType": kind, "body": {"data": base64.urlsafe_b64encode(text.encode()).decode().rstrip("=")}}

    html = part("<div>Aftale kl. 10</div><script>irrelevant()</script>", "text/html")
    message = {"payload": {"headers": [{"name": "Subject", "value": "Bekræftelse"}], "parts": [html]}}
    assert mail_text(message) == "Bekræftelse\n\nAftale kl. 10"
    message["payload"]["parts"].append(part("Adresse: Testvej 5", "text/plain"))
    assert mail_text(message) == "Bekræftelse\nAdresse: Testvej 5"
    message["payload"]["parts"] = [part(
        "Din aftale er aflyst.\n\nDen 1. april skrev klinikken:\n> Din tidligere tid er bekræftet.", "text/plain"
    )]
    assert mail_text(message) == "Bekræftelse\nDin aftale er aflyst."


def test_appointment_time_uses_danish_daylight_saving_and_requires_unclear_time():
    zone = ZoneInfo("Europe/Copenhagen")
    now = datetime(2030, 3, 1, tzinfo=timezone.utc)
    proposal = {"title": "Aftale", "start": "2030-04-25T10:15", "end": "2030-04-25T11:00", "location": "Testvej 5"}
    actual = decode_appointment(json.dumps(proposal), zone, now)
    assert actual["start"] == datetime(2030, 4, 25, 8, 15, tzinfo=timezone.utc).timestamp()
    assert actual["end"] == datetime(2030, 4, 25, 9, tzinfo=timezone.utc).timestamp()
    mail = "Tid 25.04.2030 kl. 10.15. Mød ti minutter før."
    assert decode_appointment(json.dumps(proposal), zone, now, mail)["start"] == actual["start"]
    early = {**proposal, "start": "2030-04-25T10:05"}
    assert decode_appointment(json.dumps(early), zone, now, mail)["start"] is None
    named_booking = "Din aftale er bekræftet den 25.04.2030 kl. 10.15. Mødetid kl. 10.05."
    assert decode_appointment(json.dumps(early), zone, now, named_booking)["start"] == actual["start"]
    assert decode_appointment(json.dumps({**proposal, "start": None}), zone, now)["start"] is None
    assert decode_appointment(json.dumps({**proposal, "title": None}), zone, now) is None
    assert decode_appointment(json.dumps(proposal), zone, datetime(2030, 5, 1, tzinfo=timezone.utc)) is None


def test_opt_in_stores_one_suggestion_without_persisting_email_text(tmp_path):
    class Gmail:
        account = "account-first"
        calls = 0

        def key(self):
            return "fixture-project"

        def connection(self, provider):
            assert provider == "gmail"
            return self.account

        def read(self, provider, url, query, *, account):
            assert provider == "gmail" and account == self.account and url.startswith(GMAIL)
            if url == GMAIL:
                assert "newer_than:30d" in query["q"]
                return {"messages": [{"id": "message1"}, {"id": "message2"}]}
            self.calls += 1
            return {"id": url.rsplit("/", 1)[-1], "threadId": "thread", "snippet": "sensitive fixture mail",
                    "internalDate": str(int(datetime.now(timezone.utc).timestamp() * 1000))}

    library = Gmail()
    zone = ZoneInfo("Europe/Copenhagen")
    when = (datetime.now(zone) + timedelta(days=2)).replace(hour=11, minute=30).strftime("%Y-%m-%dT%H:%M")

    def propose(body, source):
        assert body == "sensitive fixture mail"
        assert source["zone"] == zone.key
        return json.dumps({"title": "Aftale", "start": when, "end": None, "location": "Testvej 5"})

    file = tmp_path / "mail.sqlite"
    app = MailAppointments(file, library, propose)
    bot, other = str(uuid4()), str(uuid4())
    app.prepare()
    app.check_due()
    assert library.calls == 0
    assert app.configure(bot, True, zone.key)["enabled"]
    app.check_due()
    suggestions = app.status(bot)["appointments"]
    assert len(suggestions) == 1 and suggestions[0]["gmailThread"] == "thread"
    assert b"sensitive fixture mail" not in file.read_bytes()
    assert not app.status(other)["appointments"]
    app.queue(bot)
    app.check_due()
    assert library.calls == 2
    app.hide(bot, suggestions[0]["id"])
    assert not app.status(bot)["appointments"]
    app.configure(bot, False, None)
    assert app.status(bot)["enabled"] is False
    library.account = "account-second"
    app.configure(other, True, zone.key)
    assert not app.status(other)["appointments"]


def test_gmail_appointments_require_pairing(tmp_path):
    settings = make_settings(tmp_path)
    with TestClient(create_app(settings)) as client:
        url = f"/api/modules/v1/mail-appointments/{uuid4()}"
        assert client.get(url).status_code == 401
        assert client.put(url, json={"enabled": True, "zone": "Europe/Copenhagen"}).status_code == 401
        response = client.get(url, headers={"Authorization": "Bearer " + settings.token})
        assert response.status_code == 200 and response.json()["enabled"] is False
        assert response.headers["Cache-Control"] == "no-store"


def test_gmail_login_requests_read_only_oauth_scope(tmp_path, monkeypatch):
    library = ComposioLibrary(tmp_path)
    monkeypatch.setattr(library, "key", lambda: "fixture-key")
    monkeypatch.setattr("sweatcaster.composio_library.load", lambda: {})
    monkeypatch.delenv("FADEDAI_COMPOSIO_GMAIL_AUTH_CONFIG", raising=False)

    def request(method, route, *, params=None, payload=None, version):
        assert route == "/auth_configs" and version == "v3.1"
        if method == "GET":
            assert params["search"] == GMAIL_CONFIG_NAME
            return {"items": [{"id": "ac_broad", "name": "Arbitrary Gmail", "toolkit": {"slug": "gmail"},
                               "status": "ENABLED", "is_composio_managed": True}]}
        assert payload["auth_config"]["credentials"] == {"scopes": GMAIL_READ_SCOPE}
        assert payload["auth_config"]["name"] == GMAIL_CONFIG_NAME
        return {"auth_config": {"id": "ac_read_only", "is_composio_managed": True}, "toolkit": {"slug": "gmail"}}

    monkeypatch.setattr(library, "request", request)
    assert library.config("gmail", create=True) == "ac_read_only"


def test_consumer_gmail_normalizes_the_actual_composio_message_shape(monkeypatch):
    gmail = ConsumerGmail("fixture-secret")

    def execute(slug, args):
        if slug == "GMAIL_FETCH_EMAILS":
            assert args["only_ids"] and args["query"] == "subject:aftale"
            return {"messages": [{"messageId": "fixture-mail"}], "nextPageToken": "fixture-next"}
        assert args["message_id"] == "fixture-mail"
        return {"messageId": "fixture-mail", "threadId": "fixture-thread",
                "messageTimestamp": "2026-11-17T01:02:03Z", "messageText": "Bekræftet aftale", "payload": {}}

    monkeypatch.setattr(gmail, "_execute", execute)
    assert gmail.read(MESSAGES, {"q": "subject:aftale"}) == {
        "messages": [{"id": "fixture-mail"}], "nextPageToken": "fixture-next"}
    result = gmail.read(MESSAGES + "/fixture-mail")
    assert result["id"] == "fixture-mail"
    assert result["internalDate"] == "1794877323000"
    assert result["snippet"] == "Bekræftet aftale"


def test_reviewed_gmail_send_is_paired_and_does_not_send_twice(tmp_path, monkeypatch):
    calls = []
    gmail = ConsumerGmail("fixture-secret")

    def send(recipient, subject, body):
        calls.append((recipient, subject, body))
        return {"id": "fixture-receipt"}

    monkeypatch.setattr(gmail, "send", send)
    monkeypatch.setattr(ComposioLibrary, "gmail", lambda _self: gmail)
    settings = make_settings(tmp_path)
    path = "/api/modules/v1/composio/gmail/send"
    draft = {"id": str(uuid4()), "recipient": "test@example.org", "subject": "Hej", "body": "Testmail"}
    headers = {"Authorization": "Bearer " + settings.token}
    with TestClient(create_app(settings)) as client:
        assert client.put(path, json=draft).status_code == 401
        assert not calls
        assert client.put(path, headers=headers, json=draft).json() == {"sent": True}
        assert client.put(path, headers=headers, json=draft).json() == {"sent": True}
        assert client.put(path, headers=headers, json=draft | {"body": "Andet"}).status_code == 409
        assert client.put(path, headers=headers, json=draft | {"recipient": "one@example.org,two@example.org"}).status_code == 422
    assert calls == [("test@example.org", "Hej", "Testmail")]


def test_newer_changes_replace_suggestions_and_old_mail_cannot_reopen_them(tmp_path):
    class Gmail:
        def key(self):
            return "fixture-project"

        def connection(self, provider):
            return "account"

    app = MailAppointments(tmp_path / "mail.sqlite", Gmail(), None)
    app.prepare()
    bot = str(uuid4())
    app.configure(bot, True, "Europe/Copenhagen")
    selection = app.settings()
    start = datetime.now(timezone.utc) + timedelta(days=2)
    dates = [start.timestamp(), (start + timedelta(days=3)).timestamp()]
    original = {"title": "Aftale", "location": "Testvej", "start": dates[0], "end": None}
    moved = {**original, "start": dates[1]}

    app.record(selection, "account", "original", "shared-thread", 10, "confirmed", original)
    app.record(selection, "account", "new-time", "shared-thread", 30, "rescheduled", moved)
    app.record(selection, "account", "late-previous", "shared-thread", 20, "confirmed", original)
    assert [(row["start"], row["revisionStatus"]) for row in app.status(bot)["appointments"]] == [
        (dates[0], "superseded"), (dates[1], "active")]

    cancel, _ = decode_proposal('{"status":"cancelled","title":null,"start":null,"end":null,"location":null}')
    app.record(selection, "account", "cancel", "shared-thread", 50, cancel, None)
    app.record(selection, "account", "late-confirmation", "shared-thread", 40, "confirmed", moved)
    assert [row["revisionStatus"] for row in app.status(bot)["appointments"]] == ["superseded", "cancelled"]

    app.record(selection, "account", "latest-first", "other-thread", 80, cancel, None)
    app.record(selection, "account", "older-second", "other-thread", 70, "confirmed", original)
    assert len(app.status(bot)["appointments"]) == 2


def test_mail_search_checks_additional_pages_without_repeating_the_same_cursor(tmp_path):
    class Gmail:
        queries = []

        def key(self):
            return "test"

        def connection(self, provider):
            return "account"

        def read(self, provider, url, query, *, account):
            assert url == GMAIL
            self.queries.append(query)
            if "pageToken" not in query:
                return {"messages": [{"id": "latest"}], "nextPageToken": "next"}
            return {"messages": [{"id": "older"}], "nextPageToken": "next"}

    library = Gmail()
    app = MailAppointments(tmp_path / "mail.sqlite", library, None)
    app.prepare()
    app.configure(str(uuid4()), True, "Europe/Copenhagen")
    assert list(app.candidate_ids(app.settings(), "account")) == ["latest", "older"]
    assert [query.get("pageToken") for query in library.queries] == [None, "next"]

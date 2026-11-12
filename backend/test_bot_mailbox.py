import json
from io import BytesIO
from urllib.error import HTTPError

import pytest

import setup_bot_mailbox as setup


BOT = "20b18c14-c0ea-4eaa-ac70-747a7129d727"
ARGUMENTS = ["--bot-id", BOT, "--bot-name", "Adam", "--domain", "example.org"]


def mailbox():
    return setup.BotMailbox.parse(BOT, "Adam", "example.org")


def provider_account(target, **changes):
    return {"id": "google-id", "primaryEmail": target.address, "externalIds": [target.marker], **changes}


def test_preview_is_local_and_address_depends_on_bot_identity(monkeypatch, capsys):
    monkeypatch.setattr(setup, "connect", lambda _: pytest.fail("Preview tried to connect"))
    assert setup.main(ARGUMENTS) == 0
    assert mailbox().address in capsys.readouterr().out
    assert mailbox().address == setup.BotMailbox.parse(BOT, "Nyt navn", "EXAMPLE.ORG").address
    with pytest.raises(setup.SetupError):
        setup.BotMailbox.parse(BOT, "Adam", "gmail.com")


def test_creation_only_calls_fixed_google_endpoint_with_identity_marker(monkeypatch):
    target = mailbox()
    directory = setup.Directory("synthetic-token")
    calls = []

    class Response(BytesIO):
        status = 200

    def open_request(request, timeout):
        calls.append(request)
        return Response(json.dumps(provider_account(target, isMailboxSetup=False)).encode())

    monkeypatch.setattr(directory.opener, "open", open_request)
    result = directory.create(target, "synthetic-password")
    request, = calls
    assert request.full_url == setup.USERS_URL + "?resolveConflictAccount=false"
    assert request.get_method() == "POST"
    assert request.headers["Authorization"] == "Bearer synthetic-token"
    data = json.loads(request.data)
    assert data["primaryEmail"] == target.address
    assert data["externalIds"] == [target.marker]
    assert data["changePasswordAtNextLogin"] is True
    assert result["isMailboxSetup"] is False


def test_repeated_apply_reuses_own_account_and_avoids_reading_password(monkeypatch, capsys):
    account = provider_account(mailbox(), isMailboxSetup=True)

    class Directory:
        def lookup(self, _mailbox):
            return account

    monkeypatch.setattr(setup, "connect", lambda _: Directory())
    monkeypatch.setattr(setup, "temporary_password", lambda: pytest.fail("Repeat apply asked for a password"))
    assert setup.main([*ARGUMENTS, "--apply", "--oauth-client", "desktop.json"]) == 0
    assert "postkasse er klar" in capsys.readouterr().out


def test_conflict_only_reuses_account_marked_for_the_bot(monkeypatch):
    target = mailbox()
    directory = setup.Directory("synthetic-token")
    responses = iter([(409, {}), (200, provider_account(target))])
    monkeypatch.setattr(directory, "_request", lambda *_: next(responses))
    assert directory.create(target, "synthetic-password")["id"] == "google-id"
    responses = iter([(409, {}), (200, {**provider_account(target), "externalIds": []})])
    with pytest.raises(setup.SetupError, match="konto uden bottens ID"):
        directory.create(target, "synthetic-password")


def test_provider_error_does_not_print_response_body(monkeypatch):
    directory = setup.Directory("synthetic-token")

    def fail(request, timeout):
        raise HTTPError(request.full_url, 403, "upstream details", {}, BytesIO(b"provider-private-details"))

    monkeypatch.setattr(directory.opener, "open", fail)
    with pytest.raises(setup.SetupError) as error:
        directory.lookup(mailbox())
    assert "Workspace-admin" in str(error.value)
    assert "provider-private-details" not in str(error.value)

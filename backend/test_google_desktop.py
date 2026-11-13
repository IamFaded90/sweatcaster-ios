import json
import sys
from datetime import datetime, timezone
from io import BytesIO
from types import ModuleType, SimpleNamespace
from urllib.parse import parse_qs

import pytest

from sweatcaster import google_desktop as google


SCOPES = ["https://www.googleapis.com/auth/youtube.readonly"]


@pytest.fixture
def client_file(tmp_path):
    file = tmp_path / "client.json"
    file.write_text(json.dumps({"installed": {
        "client_id": "synthetic-client-id",
        "client_secret": "synthetic-client-secret",
        "auth_uri": "https://accounts.google.com/o/oauth2/auth",
        "token_uri": "https://oauth2.googleapis.com/token",
    }}), encoding="utf-8")
    return file


def test_offline_authorization_uses_pkce_and_loopback(client_file, monkeypatch):
    class InstalledAppFlow:
        @classmethod
        def from_client_config(cls, config, *, scopes, autogenerate_code_verifier):
            assert config["installed"]["client_id"] == "synthetic-client-id"
            assert scopes == SCOPES and autogenerate_code_verifier
            return cls()

        def run_local_server(self, **options):
            assert options["host"] == "127.0.0.1" and options["port"] == 0
            assert options["access_type"] == "offline" and options["prompt"] == "consent"
            return SimpleNamespace(token="synthetic-access", refresh_token="synthetic-refresh",
                                   expiry=datetime(2030, 1, 1))

    package = ModuleType("google_auth_oauthlib")
    flow = ModuleType("google_auth_oauthlib.flow")
    flow.InstalledAppFlow = InstalledAppFlow
    monkeypatch.setitem(sys.modules, "google_auth_oauthlib", package)
    monkeypatch.setitem(sys.modules, "google_auth_oauthlib.flow", flow)
    token = google.authorize_desktop(client_file, SCOPES, offline=True)
    assert token.expires_at == datetime(2030, 1, 1, tzinfo=timezone.utc)
    assert token.refresh_token == "synthetic-refresh"
    assert "synthetic" not in repr(token)


def test_client_config_rejects_non_google_token_endpoint(client_file):
    document = json.loads(client_file.read_text(encoding="utf-8"))
    document["installed"]["token_uri"] = "https://example.org/token"
    client_file.write_text(json.dumps(document), encoding="utf-8")
    with pytest.raises(google.GoogleDesktopError, match="Desktop-app"):
        google.load_desktop_client(client_file)


@pytest.mark.parametrize("saved_client", [False, True])
def test_refresh_posts_only_to_fixed_google_url(client_file, monkeypatch, saved_client):
    def open_request(request, timeout):
        assert request.full_url == "https://oauth2.googleapis.com/token"
        assert request.get_method() == "POST"
        assert parse_qs(request.data.decode()) == {
            "client_id": ["synthetic-client-id"],
            "client_secret": ["synthetic-client-secret"],
            "grant_type": ["refresh_token"],
            "refresh_token": ["saved-refresh-token"],
        }
        return BytesIO(json.dumps({
            "access_token": "fresh-access-token", "expires_in": 3600, "scope": SCOPES[0],
        }).encode())

    monkeypatch.setattr(google, "build_opener", lambda *_: SimpleNamespace(open=open_request))
    client = google.load_desktop_client(client_file) if saved_client else client_file
    token = google.refresh_desktop(client, SCOPES, "saved-refresh-token")
    assert token.access_token == "fresh-access-token"
    assert token.refresh_token == "saved-refresh-token"
    assert token.expires_at > datetime.now(timezone.utc)

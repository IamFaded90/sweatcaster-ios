import json
from io import BytesIO
from urllib.parse import parse_qs, urlsplit

import pytest

from sweatcaster import youtube_connection as youtube
from sweatcaster.google_desktop import GoogleDesktopError, GoogleDesktopToken

ID = "UC" + "A" * 22
CONFIG = {
    "client_id": "demo.apps.googleusercontent.com",
    "client_secret": "test-secret",
    "refresh_token": "test-refresh",
}


def test_only_requested_channel_fields_are_returned_without_credentials(monkeypatch):
    token = "test-access"
    response = {"items": [
        {"id": ID, "snippet": {"title": "Channel test-access test-refresh", "customUrl": "@channel",
                              "description": "Keep private"},
         "statistics": {"videoCount": "2", "subscriberCount": "10", "hiddenSubscriberCount": True}},
        {"id": "../fake", "snippet": {"title": "Invalid"}},
    ]}

    def open_request(request, timeout):
        url = urlsplit(request.full_url)
        assert (url.scheme, url.hostname, url.path) == ("https", "www.googleapis.com", "/youtube/v3/channels")
        query = parse_qs(url.query)
        assert query["mine"] == ["true"] and query["maxResults"] == ["5"]
        assert token not in request.full_url
        assert request.get_header("Authorization") == "Bearer " + token
        return BytesIO(json.dumps(response).encode())

    class Opener:
        open = staticmethod(open_request)

    monkeypatch.setattr(youtube, "build_opener", lambda *_: Opener())
    assert youtube.channels_for_token(token, redact=("test-refresh",)) == [
        {"id": ID, "title": "Channel [skjult] [skjult]", "handle": "@channel", "videoCount": "2"},
    ]


def test_uses_read_only_scope_and_persists_rotated_token(monkeypatch):
    stored = []
    monkeypatch.setattr(youtube, "load_connection", lambda: CONFIG)
    monkeypatch.setattr(youtube, "save_connection", stored.append)

    def refresh(connection, scopes, previous):
        assert connection is CONFIG and previous == CONFIG["refresh_token"]
        assert scopes == ("https://www.googleapis.com/auth/youtube.readonly",)
        return GoogleDesktopToken("new-access", "new-refresh", None)

    def channels(token, *, redact):
        assert token == "new-access" and "test-refresh" in redact and "new-refresh" in redact
        return [{"id": ID}]

    monkeypatch.setattr(youtube, "refresh_desktop", refresh)
    monkeypatch.setattr(youtube, "channels_for_token", channels)
    assert youtube.read_channels() == {"configured": True, "channels": [{"id": ID}]}
    assert stored == [{**CONFIG, "refresh_token": "new-refresh"}]


def test_absent_connection_and_revoked_grant(monkeypatch):
    monkeypatch.setattr(youtube, "load_connection", lambda: None)
    assert youtube.read_channels() == {"configured": False, "channels": []}
    monkeypatch.setattr(youtube, "load_connection", lambda: CONFIG)

    def revoked(*args):
        raise GoogleDesktopError("Google-forbindelsen skal godkendes igen.")

    monkeypatch.setattr(youtube, "refresh_desktop", revoked)
    with pytest.raises(youtube.YouTubeError, match="godkendes igen") as exc:
        youtube.read_channels()
    assert exc.value.status == 502

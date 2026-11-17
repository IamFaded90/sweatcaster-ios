from urllib.parse import parse_qs, urlsplit

import pytest

from sweatcaster import google_drive as drive
from sweatcaster.google_desktop import GoogleDesktopToken


def test_reads_one_folder_page_and_returns_only_safe_metadata(monkeypatch):
    def response(request, **_):
        url = urlsplit(request.full_url)
        assert (url.scheme, url.netloc, url.path) == ("https", "www.googleapis.com", "/drive/v3/files")
        assert parse_qs(url.query)["q"] == ["trashed = false and 'Folder_1' in parents"]
        assert parse_qs(url.query)["pageToken"] == ["page+token"]
        assert request.get_header("Authorization") == "Bearer access-secret"
        return {"files": [
            {"id": "A", "name": "Møder access-secret", "mimeType": drive.FOLDER, "description": "private"},
            {"id": "../B", "name": "Ugyldig"},
            {"id": "C", "name": "Budget", "webViewLink": "https://untrusted.example"},
            {"id": "C", "name": "Dublet"},
        ], "nextPageToken": "new+page"}

    monkeypatch.setattr(drive, "_google_json", response)
    assert drive.files_for_token("access-secret", parent="Folder_1", page="page+token") == {
        "configured": True,
        "files": [{"id": "A", "name": "Møder [skjult]", "folder": True},
                  {"id": "C", "name": "Budget", "folder": False}],
        "nextPage": "new+page",
    }


def test_invalid_folder_is_rejected_before_contacting_google(monkeypatch):
    monkeypatch.setattr(drive, "_google_json", lambda *_a, **_kw: pytest.fail("Unexpected Google call"))
    with pytest.raises(drive.DriveError) as error:
        drive.files_for_token("token", parent="' or trashed = false")
    assert error.value.status == 422


def test_refresh_uses_read_only_drive_scope_and_saves_rotated_credentials(monkeypatch):
    connection = {"client_id": "example.apps.googleusercontent.com",
                  "client_secret": "client-secret", "refresh_token": "old-refresh"}
    saved = []
    monkeypatch.setattr(drive, "load_connection", lambda: connection)
    monkeypatch.setattr(drive, "_save_connection", lambda path, value: saved.append((path, value)))

    def refresh(client, scopes, token):
        assert client == connection and token == "old-refresh"
        assert scopes == ("https://www.googleapis.com/auth/drive.metadata.readonly",)
        return GoogleDesktopToken("access-token", "new-refresh", None)

    monkeypatch.setattr(drive, "refresh_desktop", refresh)
    monkeypatch.setattr(drive, "_google_json", lambda *_a, **_kw: {"files": []})
    assert drive.read_files() == {"configured": True, "files": [], "nextPage": None}
    assert saved == [(drive.settings_path, {**connection, "refresh_token": "new-refresh"})]

from types import SimpleNamespace

from fastapi import FastAPI, HTTPException
from fastapi.testclient import TestClient

from sweatcaster import composio_library
from sweatcaster.composio_library import ComposioLibrary


class Consumer:
    def connection_statuses(self, services):
        assert "instagram" not in services
        return {"gmail": True, "youtube": True, "grok": True, "googlecalendar": True}

    def read(self, endpoint):
        return {"emailAddress": "fixture@example.org"}

    def list_calendars(self):
        return {"calendars": [{"id": "one", "summary": "Min kalender"}]}

    def list_youtube_channels(self):
        return {"items": [{"id": "two", "snippet": {"title": "Min kanal"}}]}


def test_inventory_requires_read_success_before_enabling_a_library(tmp_path, monkeypatch):
    library = ComposioLibrary(tmp_path)
    monkeypatch.setattr(library, "gmail", lambda: Consumer())
    monkeypatch.setattr(library, "key", lambda: "")
    rows = {row["id"]: row for row in library.integrations()["providers"]}
    assert rows["gmail"]["availability"] == "ready"
    assert rows["googlecalendar"]["connected"]
    assert rows["youtube"]["connected"]
    assert rows["grok"]["availability"] == "composio"
    assert not rows["grok"]["connected"]
    assert rows["googledrive"]["availability"] == "disconnected"
    assert rows["instagram"]["availability"] == "per_agent"
    assert not rows["instagram"]["connected"]


def test_explicit_refresh_bypasses_the_inventory_cache(tmp_path, monkeypatch):
    library = ComposioLibrary(tmp_path)
    monkeypatch.setattr(library, "gmail", lambda: Consumer())
    monkeypatch.setattr(library, "key", lambda: "")
    first = library.integrations()
    monkeypatch.setattr(library, "gmail", lambda: None)
    assert library.integrations() is first
    rows = {row["id"]: row for row in library.integrations(refresh=True)["providers"]}
    assert not rows["gmail"]["connected"]


def test_calendar_and_youtube_use_service_titles():
    assert ComposioLibrary.for_you_items("googlecalendar", Consumer()) == {
        "items": [{"id": "one", "title": "Min kalender"}]}
    assert ComposioLibrary.for_you_items("youtube", Consumer()) == {
        "items": [{"id": "two", "title": "Min kanal"}]}


def test_phone_connection_requires_pairing_and_never_caches_credentials(tmp_path, monkeypatch):
    monkeypatch.setattr(composio_library, "load", lambda: {"gmail_consumer_key": "ck_only-a-local-fixture"})
    app = FastAPI()

    def authorize(request, settings):
        if request.headers.get("Authorization") != "Bearer fixture":
            raise HTTPException(401)

    composio_library.register_composio(app, SimpleNamespace(output_root=tmp_path), authorize)
    with TestClient(app) as client:
        assert client.put("/api/modules/v1/composio/phone-connection").status_code == 401
        answer = client.put("/api/modules/v1/composio/phone-connection", headers={"Authorization": "Bearer fixture"})
        assert answer.status_code == 200
        assert answer.json() == {"key": "ck_only-a-local-fixture"}
        assert answer.headers["Cache-Control"] == "no-store"


def test_openrouter_phone_connection_is_paired_and_not_cached(tmp_path, monkeypatch):
    from sweatcaster import emby_settings
    monkeypatch.setenv("LOCALAPPDATA", str(tmp_path))
    key = "sk-or-v1-" + "fixture" * 6
    folder = tmp_path / "FadedAI"
    folder.mkdir()
    (folder / "openrouter.dpapi").write_bytes(b"encrypted fixture")
    monkeypatch.setattr(emby_settings, "_protect", lambda data, decrypt=False: key.encode())
    app = FastAPI()

    def authorize(request, settings):
        if request.headers.get("Authorization") != "Bearer fixture":
            raise HTTPException(401)

    composio_library.register_composio(app, SimpleNamespace(output_root=tmp_path), authorize)
    with TestClient(app) as client:
        path = "/api/modules/v1/composio/openrouter-phone-connection"
        assert client.put(path).status_code == 401
        result = client.put(path, headers={"Authorization": "Bearer fixture"})
        assert result.status_code == 200
        assert result.headers["Cache-Control"] == "no-store"
        assert result.json() == {"key": key}

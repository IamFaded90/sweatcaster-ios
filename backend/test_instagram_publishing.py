from concurrent.futures import ThreadPoolExecutor
from types import SimpleNamespace
from threading import Event
from uuid import uuid4

from fastapi import FastAPI, HTTPException
from fastapi.testclient import TestClient
import pytest

from sweatcaster import instagram_publishing as ig
from sweatcaster.composio_library import register_composio
from sweatcaster.dto import ApiError


class Project:
    def __init__(self):
        self.owner = "local-pc"
        self.connections = {}
        self.calls = []
        self.accounts = {}
        self.container_phase = "FINISHED"
        self.lose_response = False

    def connection(self, provider):
        assert provider == "instagram"
        return self.connections.get(self.owner)

    def request(self, method, path, *, payload, version):
        assert method == "POST" and version == "v3.1"
        assert payload["version"] == ig.TOOL_VERSION and payload["user_id"] == self.owner
        assert payload["connected_account_id"] == self.connections[self.owner]
        name = path.removeprefix("/tools/execute/")
        args = payload["arguments"]
        self.calls.append((self.owner, name, args))
        if name == ig.PROFILE:
            assert args["ig_user_id"] == "me"
            data = {"id": self.accounts[self.owner], "username": "bot_test", "account_type": "BUSINESS"}
        elif name == ig.CREATE:
            assert args["ig_user_id"] == self.accounts[self.owner]
            data = {"id": "300"}
        elif name == ig.CONTAINER_STATUS:
            assert args == {"creation_id": "300"}
            data = {"id": "300", "status_code": self.container_phase}
        else:
            assert name == ig.PUBLISH and args == {"ig_user_id": self.accounts[self.owner], "creation_id": "300", "max_wait_seconds": 0}
            self.container_phase = "PUBLISHED"
            if self.lose_response:
                raise ApiError(502, "TEST_TIMEOUT", "lost receipt")
            data = {"id": "400"}
        return {"successful": True, "data": data}


@pytest.fixture
def posts(tmp_path):
    project = Project()
    project.connections[project.owner] = "ca_test_only"
    project.accounts[project.owner] = "100"
    return ig.InstagramPublishing(project, tmp_path)


def draft(**overrides):
    return {"id": str(uuid4()), "accountID": "100", "caption": "En morgen i landsbyen.",
            "approved": True, "imageURL": "https://assets.example.org/today.jpg", **overrides}


def names(posts):
    return [name for _, name, _ in posts.library.calls]


def test_approved_draft_is_published_once_and_has_a_persistent_read_only_receipt(posts):
    data = draft()
    assert posts.receipt(data["id"]) == {"published": False, "state": "draft", "mediaID": None}
    assert posts.status() == {"connected": True, "username": "bot_test", "accountID": "100"}
    expected = {"published": True, "state": "published", "mediaID": "400"}
    assert posts.publish(data) == expected
    reopened = ig.InstagramPublishing(posts.library, posts.database.parent)
    assert reopened.publish(data) == reopened.receipt(data["id"]) == expected
    with pytest.raises(ApiError):
        reopened.publish(dict(data, caption="ændret"))
    assert names(posts).count(ig.CREATE) == names(posts).count(ig.PUBLISH) == 1


def test_confirmation_and_account_rechecked_before_upload_or_creation(posts):
    with pytest.raises(ApiError):
        posts.publish(draft(approved=False))
    assert not names(posts)
    with pytest.raises(ApiError):
        posts.publish(draft(accountID="101"))
    assert names(posts) == [ig.PROFILE]


def test_pending_container_can_be_finished_without_reuploading(posts, monkeypatch):
    body = draft()
    monkeypatch.setattr(ig, "sleep", lambda delay: None)
    posts.library.container_phase = "IN_PROGRESS"
    with pytest.raises(ApiError, match="behandler"):
        posts.publish(body)
    assert posts.receipt(body["id"])["state"] == "ready"
    posts.library.container_phase = "FINISHED"
    assert posts.publish(body)["published"]
    assert names(posts).count(ig.CREATE) == names(posts).count(ig.PUBLISH) == 1


def test_short_processing_delay_finishes_on_first_approval(posts, monkeypatch):
    posts.library.container_phase = "IN_PROGRESS"
    monkeypatch.setattr(ig, "sleep", lambda delay: setattr(posts.library, "container_phase", "FINISHED"))
    assert posts.publish(draft())["published"]
    assert names(posts).count(ig.CONTAINER_STATUS) == 2
    assert names(posts).count(ig.PUBLISH) == 1


def test_lost_publish_receipt_reconciles_without_republishing(posts):
    body = draft()
    posts.library.lose_response = True
    with pytest.raises(ApiError, match="muligvis"):
        posts.publish(body)
    assert posts.receipt(body["id"]) == {"published": True, "state": "published", "mediaID": None}
    assert posts.publish(body)["published"]
    assert names(posts).count(ig.PUBLISH) == 1


def test_two_simultaneous_requests_cannot_submit_twice(posts, monkeypatch):
    original = posts.library.request
    entered, release = Event(), Event()

    def delayed(method, path, **kwargs):
        if path.endswith(ig.CREATE):
            entered.set()
            assert release.wait(5)
        return original(method, path, **kwargs)

    monkeypatch.setattr(posts.library, "request", delayed)
    body = draft()
    with ThreadPoolExecutor(max_workers=2) as pool:
        result = pool.submit(posts.publish, body)
        try:
            assert entered.wait(5)
            with pytest.raises(ApiError, match="Klargøring"):
                posts.publish(body)
        finally:
            release.set()
        assert result.result()["published"]
    assert names(posts).count(ig.CREATE) == names(posts).count(ig.PUBLISH) == 1


@pytest.mark.parametrize("value", ["file:///C:/photo.jpg", "https://127.0.0.1/a.jpg", "https://100.120.0.9/a.jpg",
                                   "https://pc.local/a.jpg", "https://person:pw@images.example.com/test.jpg"])
def test_invalid_image_links_are_rejected_without_network(posts, value):
    with pytest.raises(ApiError):
        posts.publish(draft(imageURL=value))
    assert not names(posts)


def test_local_jpeg_only_staged_once_after_account_and_consent(posts, monkeypatch):
    staged = []
    body = draft(image_jpeg="fixture")
    body.pop("imageURL")
    monkeypatch.setattr(ig, "decode_photo", lambda value: b"fixture")
    monkeypatch.setattr(ig, "stage_photo", lambda _, data: staged.append(data) or {"s3key": "upload"})
    with pytest.raises(ApiError):
        posts.publish(dict(body, approved=False))
    with pytest.raises(ApiError):
        posts.publish(dict(body, accountID="999"))
    assert staged == []
    assert posts.publish(body)["published"] and posts.publish(body)["published"]
    assert staged == [b"fixture"]
    create = next(args for _, name, args in posts.library.calls if name == ig.CREATE)
    assert create["image_file"] == {"s3key": "upload"} and "image_url" not in create


def test_individual_agents_have_separate_connections_and_receipts(tmp_path):
    project = Project()
    bot_a, bot_b = str(uuid4()), str(uuid4())
    a = ig.InstagramPublishing(ig.agent_library(project, bot_a), tmp_path)
    b = ig.InstagramPublishing(ig.agent_library(project, bot_b), tmp_path)
    assert project.owner == "local-pc" and a.library.owner != b.library.owner
    assert a.library.owner == ig.agent_library(project, bot_a).owner
    a.library.connections[a.library.owner] = "ca_a"
    a.library.accounts[a.library.owner] = "100"
    data = draft()
    assert a.publish(data)["published"]
    assert not b.status()["connected"] and b.receipt(data["id"])["state"] == "draft"
    with pytest.raises(ApiError):
        b.publish(data)
    assert all(owner == a.library.owner for owner, _, _ in project.calls)


def test_paired_routes_and_authorization_link_share_per_agent_owner(tmp_path, monkeypatch):
    app = FastAPI()

    def authorize(request, settings):
        if not request.headers.get("Authorization"):
            raise HTTPException(401)

    library = register_composio(app, SimpleNamespace(output_root=tmp_path), authorize)
    monkeypatch.setattr(library, "key", lambda: "fixture")
    monkeypatch.setattr(library, "config", lambda provider, create=False: "ac_test")
    owners = []

    def fake_request(method, route, *, params=None, payload=None, version="v3"):
        if route == "/connected_accounts/link":
            owners.append(payload["user_id"])
            return {"redirect_url": "https://connect.composio.dev/example"}
        assert route == "/connected_accounts" and params["user_ids"] in owners
        return {"items": []}

    monkeypatch.setattr(library, "request", fake_request)
    bot = str(uuid4())
    path = "/api/modules/v1/composio/instagram"
    with TestClient(app) as client:
        assert client.get(path + "/status", params={"bot_id": bot}).status_code == 401
        headers, params = {"Authorization": "Bearer test"}, {"bot_id": bot}
        assert client.put(path + "/link", headers=headers, params=params).json()["url"].startswith("https://connect.")
        response = client.get(path + "/status", headers=headers, params=params)
        assert response.json() == {"connected": False}
        assert response.headers["cache-control"] == "no-store"
        assert owners == [ig.agent_library(library, bot).owner]

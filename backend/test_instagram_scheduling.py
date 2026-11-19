from base64 import b64encode
from concurrent.futures import ThreadPoolExecutor
from contextlib import closing
from io import BytesIO
from threading import Event
from types import SimpleNamespace
from uuid import uuid4

from fastapi import FastAPI, HTTPException
from fastapi.testclient import TestClient
from PIL import Image
import pytest

from sweatcaster import agent_owner_notice
from sweatcaster import instagram_publishing as ig
from sweatcaster import instagram_scheduling as scheduling
from sweatcaster.composio_routes import register_routes
from sweatcaster.dto import ApiError
from test_instagram_publishing import Project, draft


class InsightsProject(Project):
    def __init__(self):
        super().__init__()
        self.no_insights = False

    def items(self, provider):
        return {"items": []}

    def request(self, method, path, *, payload, version):
        if path.endswith("/INSTAGRAM_GET_IG_MEDIA_INSIGHTS"):
            assert payload["arguments"] == {"ig_media_id": "400", "metric": list(scheduling.METRICS)}
            self.calls.append((self.owner, "insights", payload["arguments"]))
            if self.no_insights:
                return {"successful": False}
            return {"successful": True, "data": {"data": [
                {"name": "reach", "values": [{"value": 121}]},
                {"name": "likes", "total_value": {"value": 0}},
                {"name": "shares", "values": []},
            ]}}
        if path.endswith("/INSTAGRAM_GET_IG_MEDIA"):
            assert payload["arguments"] == {"ig_media_id": "400", "fields": "id,like_count,comments_count"}
            return {"successful": True, "data": {"id": "400", "like_count": 9}}
        return super().request(method, path, payload=payload, version=version)


@pytest.fixture
def system(tmp_path):
    now = [1_800_000_000]
    project = InsightsProject()
    bot = str(uuid4())
    service = scheduling.InstagramSchedule(project, tmp_path, clock=lambda: now[0])
    owner = service.publisher(bot).library.owner
    project.connections[owner] = "ca_test_only"
    project.accounts[owner] = "100"
    body = draft(publishAt=now[0] + 100, followUpAt=now[0] + 200)
    return service, project, bot, body, now


def test_schedule_resumes_on_pc_restart_and_reports_real_counts(system):
    service, project, bot, body, now = system
    created = service.add(bot, body)
    assert created["state"] == "scheduled" and created["report"]["state"] == "pending"
    assert service.add(bot, body) == created
    assert service.listing(bot)["items"] == [created]
    assert not service.tick()
    assert not any(op == ig.CREATE for _, op, _ in project.calls)
    restarted = scheduling.InstagramSchedule(project, service.root, clock=lambda: now[0])
    now[0] = body["publishAt"] + 10
    with ThreadPoolExecutor(max_workers=2) as pool:
        list(pool.map(lambda _: restarted.tick(), range(2)))
    published = restarted.get(bot, body["id"])
    assert published["state"] == "published" and published["publishedAt"] == now[0]
    assert published["mediaID"] == "400" and not restarted.tick()
    assert not any(op == "insights" for _, op, _ in project.calls)
    now[0] = body["followUpAt"] + 5
    assert restarted.tick() and not restarted.tick()
    report = restarted.get(bot, body["id"])["report"]
    assert report["state"] == "ready" and report["checkedAt"] == now[0]
    assert report["metrics"] == {"reach": 121, "likes": 0}
    assert sum(op == ig.PUBLISH for _, op, _ in project.calls) == 1
    assert restarted.add(bot, body)["report"] == report


def test_account_and_approval_are_bound_and_cancel_prevents_publication(system):
    service, project, bot, body, now = system
    with pytest.raises(ApiError):
        service.add(bot, dict(body, approved=False))
    with pytest.raises(ApiError):
        service.add(bot, dict(body, accountID="902"))
    service.add(bot, body)
    with pytest.raises(ApiError, match="planlagt"):
        service.publisher(bot).publish(body)
    with pytest.raises(ApiError, match="anden plan"):
        service.add(bot, dict(body, caption="ændret"))
    other = str(uuid4())
    assert not service.listing(other)["items"] and service.get(other, body["id"])["state"] == "draft"
    with pytest.raises(ApiError):
        service.cancel(other, body["id"])
    assert service.cancel(bot, body["id"])["state"] == service.cancel(bot, body["id"])["state"] == "cancelled"
    now[0] += 1000
    assert not service.tick()
    assert not any(op == ig.PUBLISH for _, op, _ in project.calls)


def test_no_media_id_does_not_guess_and_never_reposts(system):
    service, project, bot, body, now = system
    project.lose_response = True
    service.add(bot, body)
    now[0] = body["followUpAt"]
    assert service.tick() and service.tick() and not service.tick()
    status = service.get(bot, body["id"])
    assert status["state"] == "published" and status["mediaID"] is None
    assert status["report"]["state"] == "unavailable" and status["report"]["metrics"] is None
    assert sum(op == ig.PUBLISH for _, op, _ in project.calls) == 1


def test_queued_photo_survives_restart_and_released_when_done(system, monkeypatch):
    service, project, bot, body, now = system
    sample = BytesIO()
    Image.new("RGB", (60, 40), "red").save(sample, "JPEG")
    body.pop("imageURL")
    body["image_jpeg"] = b64encode(sample.getvalue()).decode("ascii")
    body.pop("followUpAt")
    staged = []
    monkeypatch.setattr(ig, "stage_photo", lambda library, data: staged.append(data) or {"s3key": "fixture"})
    service.add(bot, body)
    assert not staged
    now[0] += 100
    assert service.tick() and staged == [sample.getvalue()]
    with closing(service.db()) as db:
        assert db.execute("SELECT photo FROM ig_schedule").fetchone()[0] is None
    assert service.get(bot, body["id"])["report"] is None


def test_account_changed_while_pc_slept_does_not_post_to_another_account(system):
    service, project, bot, body, now = system
    service.add(bot, body)
    owner = service.publisher(bot).library.owner
    project.accounts[owner] = "200"
    now[0] += 300
    assert service.tick()
    blocked = service.get(bot, body["id"])
    assert blocked["state"] == "scheduled" and blocked["note"]
    assert not any(op == ig.CREATE for _, op, _ in project.calls)
    project.accounts[owner] = "100"
    now[0] += 60
    assert service.tick() and service.get(bot, body["id"])["state"] == "published"


def test_insights_fallback_never_invents_unavailable_metrics(system):
    service, project, bot, body, now = system
    project.no_insights = True
    service.add(bot, body)
    now[0] = body["followUpAt"]
    assert service.tick() and service.tick()
    assert service.get(bot, body["id"])["report"]["metrics"] == {"likes": 9}


def test_background_worker_wakes_overdue_plans_without_phone(system, monkeypatch):
    service, project, bot, body, now = system
    service.add(bot, body)
    now[0] = body["followUpAt"]
    completed = Event()
    update = service.update

    def report_written(row, lease, **changes):
        update(row, lease, **changes)
        if changes.get("report_state") == "ready":
            completed.set()

    monkeypatch.setattr(service, "update", report_written)
    service.start()
    try:
        assert completed.wait(4), "Background worker did not finish the overdue report"
        assert service.get(bot, body["id"])["report"]["metrics"]["reach"] == 121
    finally:
        service.stop()
    assert not service.worker.is_alive()
    assert sum(op == ig.PUBLISH for _, op, _ in project.calls) == 1


@pytest.mark.parametrize("change", [
    {"publishAt": 12}, {"publishAt": True}, {"publishAt": float("nan")}, {"followUpAt": 15},
    {"notifyEmail": True, "followUpAt": None}
])
def test_bad_times_rejected(system, change):
    service, _, bot, body, _ = system
    with pytest.raises(ApiError):
        service.add(bot, dict(body, **change))


def test_email_report_only_after_opt_in_and_ready_and_dedupes(system, monkeypatch):
    service, project, bot, body, now = system
    body["notifyEmail"] = True
    calls = []

    def mail(library, token, subject, text):
        assert library is project
        calls.append((token, subject, text))
        return "unavailable" if len(calls) == 1 else "sent"

    monkeypatch.setattr(agent_owner_notice, "send_owner_notice", mail)
    service.add(bot, body)
    now[0] = body["followUpAt"]
    assert service.tick() and service.tick() and not calls
    assert service.tick() and not service.tick()
    now[0] += 300
    assert service.tick() and not service.tick()
    assert len(calls) == 2 and calls[0] == calls[1]
    assert "Rækkevidde: 121" in calls[0][2] and "Delinger:" not in calls[0][2]
    assert service.get(bot, body["id"])["emailState"] == "sent"


def test_unknown_mail_receipt_never_issues_second_send(system, monkeypatch):
    service, _, bot, body, now = system
    monkeypatch.setattr(agent_owner_notice, "send_owner_notice", lambda *args: "uncertain")
    service.add(bot, dict(body, notifyEmail=True))
    now[0] = body["followUpAt"]
    assert service.tick() and service.tick() and service.tick() and not service.tick()
    assert service.get(bot, body["id"])["emailState"] == "unconfirmed"


def test_routes_are_paired_and_schedule_status_uses_original_bot(system):
    service, project, bot, body, now = system
    app = FastAPI()

    def authorize(request, settings):
        if not request.headers.get("Authorization"):
            raise HTTPException(401)

    register_routes(app, SimpleNamespace(output_root=service.root), authorize, project, lambda: {})
    app.state.instagram_schedule.clock = lambda: now[0]
    base, query = "/api/modules/v1/composio/instagram/schedule", {"bot_id": bot}
    headers = {"Authorization": "Bearer fake"}
    with TestClient(app) as client:
        assert client.put(base, params=query, json=body).status_code == 401
        assert client.put(base, params=query, headers=headers, json=body).json()["state"] == "scheduled"
        assert client.get(base, params=query, headers=headers).json()["items"][0]["id"] == body["id"]
        url = base + "/" + body["id"]
        assert client.get(url, params={"bot_id": str(uuid4())}, headers=headers).json()["state"] == "draft"
        assert client.put(url + "/cancel", params=query, headers=headers).json()["state"] == "cancelled"

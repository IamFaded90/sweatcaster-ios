import json
from uuid import uuid4

import pytest

from sweatcaster.dto import ApiError
from sweatcaster.village_surprises import VillageSurprises


def generated(*_):
    return json.dumps({"title": "Atelierets tjekliste", "text": "Gør billederne klar til din annonce.",
                       "actions": [{"type": "tool", "label": "Åbn min tjekliste", "value": "checklist"}]})


def setup(tmp_path, **kwargs):
    service = VillageSurprises(tmp_path, kwargs.pop("generate", generated), **kwargs)
    bot, key = str(uuid4()), str(uuid4())
    body = {"action": "create", "brief": "Lav et nyttigt atelierhjørne", "figures": ["adam", "lumi"]}
    job = service.create(bot, key, body)
    return service, bot, key, body, job


def test_idle_authorization_builds_a_real_addon_that_can_be_kept_and_deleted(tmp_path):
    service, bot, key, body, job = setup(tmp_path)
    assert service.create(bot.upper(), key.upper(), body) == job
    ready = service.run(bot, key)
    assert ready["state"] == "ready" and ready["addon"]["actions"][0]["value"] == "checklist"
    assert ready["figures"] == ["adam", "lumi"] and ready["bytes"] > 0
    kept = service.mutate(bot, key, {"action": "keep", "revision": ready["revision"]})
    assert kept["state"] == "kept"
    with service.db() as db:
        db.execute("ATTACH DATABASE ? AS library", (str(tmp_path / "addons.sqlite3"),))
        saved = db.execute("SELECT body FROM library.addons WHERE id=?", (key,)).fetchone()
        assert json.loads(saved[0]) == ready["addon"]
    service.mutate(bot.upper(), key.upper(), {"action": "remove", "revision": kept["revision"]})
    with service.db() as db:
        db.execute("ATTACH DATABASE ? AS library", (str(tmp_path / "addons.sqlite3"),))
        assert db.execute("SELECT count(*) FROM library.addons").fetchone()[0] == 0
        assert db.execute("SELECT count(*) FROM surprises").fetchone()[0] == 0


def test_a_busy_pc_leaves_the_job_queued(tmp_path):
    service, bot, key, _, job = setup(tmp_path, is_idle=lambda: False,
                                     generate=lambda *_: pytest.fail("The busy PC must keep its current task"))
    assert service.run(bot, key) == job
    assert service.one(bot, key)["state"] == "queued"


def test_the_generated_activity_can_be_used_before_keep_and_remembers_progress(tmp_path):
    service, bot, key, _, job = setup(tmp_path)
    ready = service.run(bot, key)
    checked = service.mutate(bot, key, {"action": "progress", "revision": ready["revision"], "index": 0, "done": True})
    assert checked["completed"] == [0]
    assert VillageSurprises(tmp_path, generated).one(bot, key)["completed"] == [0]
    with pytest.raises(ApiError):
        service.mutate(bot, key, {"action": "progress", "revision": checked["revision"], "index": 50, "done": True})
    kept = service.keep(checked)
    assert kept["completed"] == [0] and kept["state"] == "kept"


def test_invalid_buttons_or_figures_cannot_reach_the_addon_library(tmp_path):
    service, bot, key, body, job = setup(tmp_path, generate=lambda *_: json.dumps({
        "title": "Unknown", "text": "Unknown", "actions": [{"type": "tool", "label": "Run", "value": "shell"}]}))
    assert service.run(bot, key)["state"] == "error"
    with pytest.raises(ApiError):
        service.keep(service.one(bot, key))
    with pytest.raises(ApiError):
        service.create(bot, str(uuid4()), {**body, "figures": ["../unknown"]})


def test_revision_conflicts_do_not_erase_the_owners_newer_idea(tmp_path):
    service, bot, key, _, job = setup(tmp_path)
    changed = service.mutate(bot, key, {"action": "revise", "revision": job["revision"], "brief": "Lav en regnemaskine"})
    with pytest.raises(ApiError):
        service.mutate(bot, key, {"action": "remove", "revision": job["revision"]})
    assert service.one(bot, key)["brief"] == "Lav en regnemaskine"
    assert changed["revision"] > job["revision"]


def test_kept_addons_cannot_be_replaced_by_a_new_model_response(tmp_path):
    service, bot, key, _, job = setup(tmp_path)
    ready = service.run(bot, key)
    kept = service.keep(ready)
    assert service.run(bot, key) == kept
    with pytest.raises(ApiError):
        service.mutate(bot, key, {"action": "revise", "revision": kept["revision"], "brief": "Erstat det hele"})


def test_http_routes_require_pairing_and_keep_the_owners_approved_figures(tmp_path):
    from types import SimpleNamespace
    from fastapi import FastAPI, HTTPException
    from fastapi.testclient import TestClient
    from sweatcaster.village_surprises import register_village_surprises
    app = FastAPI()

    def authorize(request, _):
        if request.headers.get("Authorization") != "Bearer fixture":
            raise HTTPException(401)

    register_village_surprises(app, SimpleNamespace(output_root=tmp_path), authorize, generated)
    client = TestClient(app)
    bot, key = str(uuid4()), str(uuid4())
    path = "/api/modules/v1/village-surprises/" + key
    body = {"action": "create", "brief": "Et nyt atelierhjørne", "figures": ["lumi"]}
    assert client.put(path, params={"bot_id": bot}, json=body).status_code == 401
    response = client.put(path, params={"bot_id": bot}, json=body, headers={"Authorization": "Bearer fixture"})
    assert response.status_code == 200 and response.headers["cache-control"] == "no-store"
    assert response.json()["figures"] == ["lumi"]

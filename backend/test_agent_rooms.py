import base64
from io import BytesIO
from types import SimpleNamespace
from uuid import uuid4

from fastapi import FastAPI, HTTPException
from fastapi.responses import JSONResponse
from fastapi.testclient import TestClient
from PIL import Image

from sweatcaster.agent_room_art import latent_size
from sweatcaster import agent_rooms as rooms
from sweatcaster.dto import ApiError


def picture():
    data = BytesIO()
    Image.new("RGB", (640, 480), "navy").save(data, "PNG")
    return data.getvalue()


def fixture():
    key, bot = str(uuid4()), str(uuid4())
    people = [{"id": str(uuid4()), "name": name.title(), "character": name}
              for name in ["adam", "eva", "milo", "luna", "iris", "saga", "noah", "atlas"]]
    body = {"botID": bot, "title": "Forskningsværksted", "brief": "Behold lyskeglen ved skrivebordet.",
            "figures": people, "sketch": base64.b64encode(picture()).decode("ascii")}
    return key, bot, body


def test_room_is_versioned_from_sketch_without_new_app_code(tmp_path):
    key, bot, body = fixture()
    observed = []

    def make(sketch, title, brief, cancelled):
        assert Image.open(BytesIO(sketch)).size == (640, 480)
        assert title == body["title"] and brief == body["brief"] and not cancelled()
        observed.append(title)
        return picture()

    library = rooms.AgentRooms(tmp_path, render=make)
    assert library.create(key, body)["state"] == "queued"
    assert library.list(None, True) == {"rooms": []}
    assert library.work_once() and len(observed) == 1
    first = library.create(key, body)["versions"][0]
    assert library.artwork(key, first["artwork"])["image"]
    revision = {"figureID": body["figures"][0]["id"], "revision": 1, "scale": 1.65, "instruction": "Gør Adam større."}
    revised = library.change(key, "revise", revision)
    next = revised["versions"][1]
    assert next["artwork"] == first["artwork"]
    assert next["figures"][0]["scale"] == 1.65 and next["figures"][1:] == first["figures"][1:]
    assert next["hotspots"] == first["hotspots"]
    assert library.change(key, "revise", revision)["revision"] == 2
    library.change(key, "publish", {"revision": 1})
    assert library.list(None, True)["rooms"][0]["publishedRevision"] == 1
    reloaded = rooms.AgentRooms(tmp_path)
    assert reloaded.one(key)["revision"] == 2 and reloaded.list(bot, False)["rooms"]
    reloaded.change(key, "publish", {"revision": 2})
    assert reloaded.list(None, True)["rooms"][0]["publishedRevision"] == 2
    assert reloaded.change(key, "remove", {}) == {"removed": True}
    with reloaded.db() as db:
        assert db.execute("SELECT count(*) FROM art").fetchone()[0] == 0


def test_failed_room_can_retry_from_same_reference(tmp_path):
    key, _, body = fixture()
    tries = []

    def fail_once(sketch, *args):
        tries.append(sketch)
        if len(tries) == 1:
            raise ApiError(502, "NOT_READY", "En kontrolleret fejl i billedmotoren.")
        return picture()

    library = rooms.AgentRooms(tmp_path, render=fail_once)
    library.create(key, body)
    assert library.work_once()
    assert library.one(key)["state"] == "failed" and library.one(key)["versions"] == []
    assert library.change(key, "retry", {})["state"] == "queued"
    assert library.work_once() and tries[0] == tries[1]
    assert library.one(key)["state"] == "ready"


def test_real_api_pairs_and_rejects_untrusted_room_data(tmp_path):
    key, bot, body = fixture()
    app = FastAPI()

    @app.exception_handler(ApiError)
    def problem(_, error):
        return JSONResponse(status_code=error.status_code, content={"error": error.code})

    def pair(request, _):
        if request.headers.get("Authorization") != "Bearer fixture":
            raise HTTPException(401)

    service = rooms.register_agent_rooms(app, SimpleNamespace(output_root=tmp_path), pair)
    service.render = lambda *args: picture()
    path = rooms.PREFIX + "/" + key
    headers = {"Authorization": "Bearer fixture"}
    with TestClient(app) as client:
        assert client.put(path, json=body).status_code == 401
        assert client.put(path, json=dict(body, sketch="???"), headers=headers).status_code == 422
        assert client.put(path, json=dict(body, figures=[dict(body["figures"][0], character="outside")]), headers=headers).status_code == 422
        assert client.put(path, json=body, headers=headers).json()["state"] == "queued"
        assert client.put(path, json=dict(body, title="andet"), headers=headers).status_code == 409
        assert service.work_once()
        result = client.get(path, headers=headers)
        assert result.headers["Cache-Control"] == "no-store"
        digest = result.json()["versions"][0]["artwork"]
        assert client.get(f"{path}/art/{digest}").status_code == 401
        image = client.get(f"{path}/art/{digest}", headers=headers).json()["image"]
        assert Image.open(BytesIO(base64.b64decode(image))).size == (640, 480)
        assert client.get(f"{path}/art/something", headers=headers).status_code == 422
        assert client.put(f"{path}/revise", headers=headers, json={"revision": 1, "figureID": str(uuid4()),
                          "scale": 1.65, "instruction": "Forkert figur"}).status_code == 422
        assert client.get(rooms.PREFIX, params={"bot_id": bot}, headers=headers).json()["rooms"][0]["id"] == key


def test_local_render_respects_sketch_shape_and_memory_ceiling():
    w, h = latent_size(1920, 1080)
    assert w <= 1024 and h <= 1024 and w * h < 810_000
    assert w % 16 == 0 and h % 16 == 0 and abs(w / h - 1920 / 1080) < 0.035

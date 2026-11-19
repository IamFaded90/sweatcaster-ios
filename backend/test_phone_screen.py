from io import BytesIO
from types import SimpleNamespace
import uuid

from fastapi import FastAPI, HTTPException
from fastapi.testclient import TestClient
from fastapi.responses import JSONResponse
from PIL import Image
import pytest

from sweatcaster.dto import ApiError
from sweatcaster.phone_screen import PhoneScreens, register_phone_screen


def photo(color="green"):
    stream = BytesIO()
    Image.new("RGB", (160, 240), color).save(stream, format="JPEG")
    return stream.getvalue()


def test_scoped_session_does_not_accept_other_sessions_or_main_bearer():
    service = PhoneScreens(None)
    first = service.create(str(uuid.uuid4()))
    other = service.create(str(uuid.uuid4()))
    for token in (other["uploadToken"], "main-bearer"):
        with pytest.raises(ApiError):
            service.frame(first["id"], token, photo())
    assert service.status(first["id"])["frames"] == 0


def test_freeze_preserves_other_app_image_when_returning_to_chat():
    inspected = []
    def vision(_, image, question):
        inspected.append((image, question))
        return "Der står en fejl i appen."
    service = PhoneScreens(None, vision=vision)
    item = service.create(str(uuid.uuid4()))
    assert service.frame(item["id"], item["uploadToken"], photo())["received"]
    service.freeze(item["id"], True)
    assert not service.frame(item["id"], item["uploadToken"], photo("red"))["received"]
    assert service.status(item["id"])["frames"] == 1
    assert service.ask(item["id"], "Hvad betyder fejlen?")["reading"].startswith("Der står")
    from base64 import b64encode
    assert len(inspected) == 1 and inspected[0][0] == b64encode(photo()).decode()
    assert "phone screen" in inspected[0][1]
    service.freeze(item["id"], False)
    assert service.frame(item["id"], item["uploadToken"], photo("red"))["received"]
    assert service.status(item["id"])["frames"] == 2


def test_stop_expiry_and_new_session_for_same_agent_revoke_frame_access():
    service = PhoneScreens(None)
    bot = str(uuid.uuid4())
    old = service.create(bot)
    current = service.create(bot)
    with pytest.raises(ApiError):
        service.frame(old["id"], old["uploadToken"], photo())
    service.stop(current["id"])
    with pytest.raises(ApiError):
        service.status(current["id"])
    expired = service.create(bot)
    service.sessions[expired["id"]].expires = 1
    with pytest.raises(ApiError):
        service.frame(expired["id"], expired["uploadToken"], photo())
    assert expired["id"] not in service.sessions


def test_no_screen_and_stale_screen_produce_a_real_problem():
    service = PhoneScreens(None, vision=lambda *_: pytest.fail("No model call without an image"))
    item = service.create(str(uuid.uuid4()))
    with pytest.raises(ApiError):
        service.ask(item["id"], "Hvad betyder det?")
    service.frame(item["id"], item["uploadToken"], photo())
    service.sessions[item["id"]].received = 1
    with pytest.raises(ApiError):
        service.ask(item["id"], "Hvad betyder det?")


def test_unavailable_model_does_not_claim_it_read_screen_and_stop_during_read_discards_answer():
    service = PhoneScreens(None, vision=lambda *_: None)
    item = service.create(str(uuid.uuid4()))
    service.frame(item["id"], item["uploadToken"], photo())
    with pytest.raises(ApiError):
        service.ask(item["id"], "Hvad står der?")
    def cancel(*_):
        service.stop(item["id"])
        return "A delayed answer"
    service.vision = cancel
    with pytest.raises(ApiError):
        service.ask(item["id"], "Hvad står der?")


def test_http_pairing_upload_limits_and_no_cache():
    app = FastAPI()
    @app.exception_handler(ApiError)
    async def problem(_, error):
        return JSONResponse({"error": str(error)}, status_code=error.status_code)
    def authorize(request, _):
        if request.headers.get("Authorization") != "Bearer paired":
            raise HTTPException(401)
    register_phone_screen(app, SimpleNamespace(), authorize)
    client = TestClient(app)
    base = "/api/modules/v1/phone-screen"
    assert client.put(base, json={"bot_id": str(uuid.uuid4())}).status_code == 401
    headers = {"Authorization": "Bearer paired"}
    response = client.put(base, headers=headers, json={"bot_id": str(uuid.uuid4())})
    assert response.status_code == 200 and response.headers["cache-control"] == "no-store"
    item = response.json()
    upload = {"Authorization": "Bearer " + item["uploadToken"], "Content-Type": "image/jpeg"}
    assert client.put(base + "/" + item["id"] + "/frame", headers=upload, content=photo()).status_code == 200
    assert client.get(base + "/" + item["id"], headers=upload).status_code == 401
    assert client.get(base + "/" + item["id"], headers=headers).json()["frames"] == 1
    assert client.put(base + "/" + item["id"] + "/frame", headers=upload, content=b"x" * 600_001).status_code == 413
    assert client.put(base + "/" + item["id"] + "/finish", headers=headers).status_code == 401
    assert client.put(base + "/" + item["id"] + "/finish", headers=upload).status_code == 200
    assert client.get(base + "/" + item["id"], headers=headers).status_code == 409

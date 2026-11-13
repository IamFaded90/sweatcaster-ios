import json
from inspect import signature
from uuid import uuid4

import pytest
from fastapi import Request, Response
from tests.conftest import make_settings
from fastapi.testclient import TestClient

from sweatcaster.api import create_app
from sweatcaster import emby_library, module_tabs
from sweatcaster.bot_computers import BotComputers
from sweatcaster.dto import ApiError
from sweatcaster.module_tabs import collection_answer


def test_manifest_import_and_local_answers(tmp_path):
    settings = make_settings(tmp_path)
    (settings.output_root / "module-tabs.json").write_text(
        json.dumps([{"id": "test", "title": "Status", "text": "Klar"}]), encoding="utf-8"
    )
    headers = {"Authorization": "Bearer " + settings.token}
    with TestClient(create_app(settings)) as client:
        base = "/api/modules/v1/"
        assert client.get(base + "manifest").status_code == 401
        assert client.get(base + "code-batches").status_code == 401
        assert client.get(base + "code-batches", headers=headers).json() == {"jobs": []}
        assert client.get(base + "routines").status_code == 401
        assert client.put(base + "routines", headers=headers, json={"routines": []}).json() == {"routines": []}
        assert client.put(base + "code-repositories", headers=headers, json={"repo": "https://example.org/a"}).status_code == 422
        assert client.put(base + "code-batches/example/approval", headers=headers, json={"approved": False}).status_code == 422
        assert [tab["id"] for tab in client.get(base + "manifest", headers=headers).json()["tabs"]] == ["cards", "test"]
        assert client.get(base + "tabs/test", headers=headers).json() == {"text": "Klar"}
        card = {"navn": "Pikachu", "sæt": "Base Set", "nummer": "58", "sprog": "Engelsk"}
        data = [dict(card, id=str(uuid4()), prisDKK=25), dict(card, id=str(uuid4()), prisDKK=None)]
        assert client.put(base + "tabs/cards", headers=headers, json=data).status_code == 200
        assert client.put(base + "tabs/cards", headers=headers, json=[data[0], data[0]]).status_code == 422
        assert len(client.get(base + "tabs/cards", headers=headers).json()["cards"]) == 2
        assert "1 mulige dubletgrupper" in collection_answer(settings, "Kortsamling: dubletter")
        assert "1 kort" in collection_answer(settings, "Kortsamling: mangler pris")
        assert collection_answer(settings, "Hvad mangler?") is None
        chat = {"message": "Kortsamling: dubletter", "request_id": str(uuid4())}
        answer = client.post("/api/v2/chat", headers=headers, json=chat)
        assert answer.status_code == 200
        frames = [json.loads(line[6:]) for line in answer.text.splitlines() if line.startswith("data: ")]
        assert [frame["type"] for frame in frames] == ["tool_status", "text", "done"]
        assert "dubletgrupper" in frames[1]["content"]
        assert client.post("/api/v2/chat", headers=headers, json=chat).status_code == 409


def test_emby_library_requires_a_paired_client(tmp_path, monkeypatch):
    for key in (*emby_library.PRIMARY_ENV, "FADEDAI_EMBY_WEB_URL"):
        monkeypatch.delenv(key, raising=False)
    monkeypatch.setattr(emby_library, "_load_saved_settings", lambda: None)
    settings = make_settings(tmp_path)
    app = create_app(settings)
    url = "/api/modules/v1/emby/library"
    endpoint = next(route.endpoint for route in app.routes if getattr(route, "path", None) == url)
    with pytest.raises(ApiError) as failure:
        endpoint(Request({"type": "http", "headers": []}), Response())
    assert failure.value.status_code == 401

    headers = [(b"authorization", ("Bearer " + settings.token).encode())]
    request = Request({"type": "http", "headers": headers})
    response = Response()
    assert endpoint(request, response) == {"configured": False, "items": [], "nextOffset": None}
    assert response.headers["Cache-Control"] == "no-store"
    with pytest.raises(ApiError) as failure:
        endpoint(request, Response(), offset=-1)
    assert failure.value.status_code == 422


def test_external_lookups_require_pairing_before_contacting_service(tmp_path, monkeypatch):
    called = []

    def web_lookup(query):
        called.append(query)
        return [{"title": "Example", "url": "https://example.org/", "snippet": ""}]

    def youtube_lookup():
        called.append("youtube")
        return {"configured": False, "channels": []}

    monkeypatch.setattr(module_tabs, "search_web", web_lookup)
    monkeypatch.setattr(module_tabs, "read_channels", youtube_lookup)
    settings = make_settings(tmp_path)
    app = create_app(settings)
    base = "/api/modules/v1/"
    endpoints = {route.path: route.endpoint for route in app.routes if getattr(route, "path", None)
                 in {base + "web-search", base + "youtube/channels"}}
    unpaired = Request({"type": "http", "headers": []})
    paired = Request({"type": "http", "headers": [(b"authorization", ("Bearer " + settings.token).encode())]})
    for path, body, expected in (
        ("web-search", {"body": {"query": "example"}},
         {"results": [{"title": "Example", "url": "https://example.org/", "snippet": ""}]}),
        ("youtube/channels", {}, {"configured": False, "channels": []}),
    ):
        endpoint = endpoints[base + path]
        with pytest.raises(ApiError) as failure:
            endpoint(unpaired, Response(), **body)
        assert failure.value.status_code == 401
        response = Response()
        assert endpoint(paired, response, **body) == expected
        assert response.headers["Cache-Control"] == "no-store"
    assert called == ["example", "youtube"]


def test_bot_activity_requires_pairing_and_bounds_requested_ids(tmp_path, monkeypatch):
    requested = []

    def activity(_service, ids):
        requested.append(ids)
        return {"bots": [{"id": bot_id, "jobs": []} for bot_id in ids]}

    monkeypatch.setattr(BotComputers, "activity", activity)
    settings = make_settings(tmp_path)
    app = create_app(settings)
    url = "/api/modules/v1/bot-activity"
    endpoint = next(route.endpoint for route in app.routes if getattr(route, "path", None) == url)
    unpaired = Request({"type": "http", "headers": []})
    paired = Request({"type": "http", "headers": [(b"authorization", ("Bearer " + settings.token).encode())]})
    bot_id = str(uuid4())

    with pytest.raises(ApiError) as rejection:
        endpoint(unpaired, Response(), body={"botIDs": [bot_id]})
    assert rejection.value.status_code == 401
    for bad_ids in (bot_id, ["wrong-id"], [bot_id] * 11):
        with pytest.raises(ApiError) as rejection:
            endpoint(paired, Response(), body={"botIDs": bad_ids})
        assert rejection.value.status_code == 422
    assert requested == []

    response = Response()
    result = endpoint(paired, response, body={"botIDs": [bot_id, bot_id.upper()]})
    assert result == {"bots": [{"id": bot_id, "jobs": []}]}
    assert response.headers["Cache-Control"] == "no-store"
    assert requested == [[bot_id]]


def test_module_mcp_rejects_untrusted_clients_and_lists_read_tools(tmp_path):
    fastmcp = pytest.importorskip("mcp.server.fastmcp")
    if "max_request_body_size" not in signature(fastmcp.FastMCP).parameters:
        pytest.skip("HTTP MCP requires an SDK with bounded request bodies.")
    settings = make_settings(tmp_path)
    headers = {"Authorization": "Bearer " + settings.token, "Accept": "application/json, text/event-stream"}
    request = {"jsonrpc": "2.0", "id": 1, "method": "tools/list", "params": {}}
    with TestClient(create_app(settings), base_url="http://127.0.0.1:8765") as client:
        url = "/api/modules/v1/mcp"
        assert client.post(url, json=request).status_code == 401
        assert client.post(url, headers={**headers, "Host": "evil.example"}, json=request).status_code == 403
        assert client.post(url, headers={**headers, "Origin": "http://127.0.0.1:8765"}, json=request).status_code == 403
        reply = client.post(url, headers=headers, json=request)
        assert reply.status_code == 200, reply.text
        assert {tool["name"] for tool in reply.json()["result"]["tools"]} == {"read_repository_file", "search_repository"}


def test_removing_unavailable_video_record_keeps_existing_videos_and_originals(tmp_path):
    settings = make_settings(tmp_path)
    app = create_app(settings)
    url = "/api/modules/v1/video-jobs/{job_id}/record"
    endpoint = next(route.endpoint for route in app.routes if getattr(route, "path", None) == url)
    paired = Request({"type": "http", "headers": [(b"authorization", ("Bearer " + settings.token).encode())]})
    unpaired = Request({"type": "http", "headers": []})
    source = settings.input_roots[0] / "original.mp4"
    source.write_bytes(b"original")

    def job(status, *, output_ready):
        job_id = uuid4().hex
        app.state.store.save_job({"id": job_id, "status": status, "created_at": "2026-11-07T11:40:00Z",
                                  "clip_id": uuid4().hex, "output_ready": output_ready})
        return job_id

    unavailable = job("completed", output_ready=False)
    missing = job("completed", output_ready=True)
    available = job("completed", output_ready=True)
    unexpected_output = job("completed", output_ready=False)
    running = job("rendering", output_ready=False)
    kept = settings.output_root / "jobs" / available / "output.mp4"
    unexpected = settings.output_root / "jobs" / unexpected_output / "output.mp4"
    report = settings.output_root / "jobs" / missing / "output.report.json"
    kept.parent.mkdir(parents=True)
    kept.write_bytes(b"edited")
    unexpected.parent.mkdir(parents=True)
    unexpected.write_bytes(b"recoverable")
    report.parent.mkdir(parents=True)
    report.write_bytes(b"report")

    with pytest.raises(ApiError) as rejection:
        endpoint(unavailable, unpaired, {"confirm_job_id": unavailable})
    assert rejection.value.status_code == 401
    with pytest.raises(ApiError) as rejection:
        endpoint(unavailable, paired, {"confirm_job_id": missing})
    assert rejection.value.status_code == 422
    for job_id in (available, unexpected_output, running):
        with pytest.raises(ApiError) as rejection:
            endpoint(job_id, paired, {"confirm_job_id": job_id})
        assert rejection.value.status_code == 409
        assert app.state.store.get_job(job_id) is not None
    for job_id in (unavailable, missing, missing):
        assert endpoint(job_id, paired, {"confirm_job_id": job_id}) == {"removed": True}
        assert app.state.store.get_job(job_id) is None
    assert source.read_bytes() == b"original"
    assert kept.read_bytes() == b"edited"
    assert unexpected.read_bytes() == b"recoverable"
    assert report.read_bytes() == b"report"


def test_older_optional_mcp_does_not_prevent_api_startup(tmp_path, monkeypatch):
    fastmcp = pytest.importorskip("mcp.server.fastmcp")

    def legacy_fastmcp(name):
        pytest.fail("The legacy SDK cannot serve bounded HTTP requests.")

    monkeypatch.setattr(fastmcp, "FastMCP", legacy_fastmcp)
    with TestClient(create_app(make_settings(tmp_path))) as client:
        assert client.get("/api/v1/health").status_code == 200
        assert client.post("/api/modules/v1/mcp", json={}).status_code == 404

import base64
from concurrent.futures import ThreadPoolExecutor
import io
from types import SimpleNamespace
from uuid import uuid4
import zipfile

from fastapi import FastAPI, HTTPException
from fastapi.testclient import TestClient
from PIL import Image
import pytest

from sweatcaster.agent_tool_builder import AgentTools, register_agent_tools
from sweatcaster.agent_tool_runtime import execute, validate_spec
from sweatcaster.dto import ApiError


SPEC = {"title": "Annoncebilleder", "description": "Gør billederne mindre, navngiv dem og pak dem.",
        "steps": [{"type": "image_resize", "maxEdge": 256, "format": "jpeg", "quality": 85},
                  {"type": "rename", "prefix": "annonce", "start": 1}, {"type": "zip", "name": "annonce.zip"}]}


def picture():
    output = io.BytesIO()
    Image.new("RGB", (640, 480), (10, 180, 120)).save(output, "PNG")
    return {"name": "original.png", "data": base64.b64encode(output.getvalue()).decode()}


def service(tmp_path, spec=SPEC):
    return AgentTools(SimpleNamespace(output_root=tmp_path), proposer=lambda *_: spec)


def test_build_runs_actual_generated_program_before_publishing_then_processes_real_image(tmp_path):
    tools = service(tmp_path)
    identifier = str(uuid4())
    tool = tools.build("Lav billeder klar til annonce", identifier)
    assert len(tool["checks"]) >= 4 and tools.list()["items"][0]["id"] == identifier
    source = tools.get(identifier)
    assert source["steps"] == SPEC["steps"]
    original = picture()
    run = tools.run(identifier, [original], str(uuid4()))
    payload = tools.file_data(run["id"], 0)
    assert payload["name"] == "annonce.zip"
    with zipfile.ZipFile(io.BytesIO(base64.b64decode(payload["data"]))) as archive:
        assert archive.namelist() == ["annonce-001.jpg"]
        with Image.open(io.BytesIO(archive.read("annonce-001.jpg"))) as image:
            assert image.size == (256, 192)
    assert original == picture()


def test_one_agent_request_can_build_test_and_use_missing_tool(tmp_path):
    tools = service(tmp_path)
    result = tools.complete("Klargør foto", [picture()], str(uuid4()))
    assert result["tool"]["checks"] and result["result"]["files"][0]["name"] == "annonce.zip"
    second = tools.complete("Klargør foto", [picture()], str(uuid4()))
    assert second["tool"]["id"] == result["tool"]["id"]
    assert len(tools.list()["items"]) == 1


def test_duplicate_requests_are_idempotent_and_changed_input_is_a_conflict(tmp_path):
    tools = service(tmp_path)
    identifier, run_id = str(uuid4()), str(uuid4())
    tools.build("Opgave", identifier)
    tools.build("Opgave", identifier)
    with ThreadPoolExecutor(max_workers=2) as pool:
        results = list(pool.map(lambda _: tools.run(identifier, [picture()], run_id), range(2)))
    assert results[0] == results[1] and len(tools.runs(identifier)["items"]) == 1
    changed = picture()
    changed["name"] = "anden.png"
    with pytest.raises(ApiError):
        tools.run(identifier, [changed], run_id)
    with pytest.raises(ApiError):
        tools.build("En anden opgave", identifier)


def test_failed_recipe_never_appears_in_library(tmp_path):
    tools = service(tmp_path, {"title": "Shell", "description": "Forkert", "steps": [{"type": "shell", "command": "echo hi"}]})
    with pytest.raises(ApiError):
        tools.build("Afprøv", str(uuid4()))
    assert tools.list()["items"] == []


def test_remove_frees_generated_files_and_keeps_unrelated_files(tmp_path):
    tools = service(tmp_path)
    protected = tmp_path / "bevar.txt"
    protected.write_text("Bevar")
    identifier = str(uuid4())
    tools.build("Foto", identifier)
    run = tools.run(identifier, [picture()], str(uuid4()))
    path = tools.root / "runs" / run["id"]
    assert path.exists()
    tools.remove(identifier)
    assert not path.exists() and tools.list()["items"] == [] and protected.read_text() == "Bevar"
    with pytest.raises(ApiError):
        tools.remove_run("../bevar.txt")
    assert protected.exists()


def test_runtime_handles_csv_text_and_rejects_traversal(tmp_path):
    spec = {"title": "Udvalg", "description": "CSV", "steps": [{"type": "csv_columns", "columns": ["Navn"]}]}
    output = execute(spec, {"data.csv": "Navn,Alder\nEva,20\nAdam,30\n".encode()})
    assert output["data.csv"].decode() == "Navn\r\nEva\r\nAdam\r\n"
    spec["steps"] = [{"type": "text_replace", "find": "Adam", "replace": "Eva"}]
    assert execute(spec, {"note.txt": b"Hej Adam"})["note.txt"] == b"Hej Eva"
    with pytest.raises(ValueError):
        execute(spec, {"../note.txt": b"x"})
    with pytest.raises(ValueError):
        execute(spec, {"note.txt": b"x", "C:\\secret.txt": b"x"})


def test_routes_require_pairing_and_catalog_removal_is_confirmed(tmp_path):
    app = FastAPI()
    def authorize(request, _):
        if request.headers.get("Authorization") != "Bearer paired":
            raise HTTPException(401)
    register_agent_tools(app, SimpleNamespace(output_root=tmp_path), authorize)
    client = TestClient(app)
    prefix = "/api/modules/v1/agent-tools"
    assert client.get(prefix).status_code == 401
    assert client.put(prefix + "/complete", json={}).status_code == 401
    identifier = str(uuid4())
    headers = {"Authorization": "Bearer paired"}
    result = client.put(prefix + "/build", headers=headers,
                        json={"brief": "Prøve", "requestID": identifier, "spec": SPEC})
    assert result.status_code == 200 and result.json()["checks"]
    deleted = client.put(prefix + "/" + identifier + "/remove", headers=headers, json={})
    assert deleted.status_code == 200 and deleted.json()["removed"]
    assert client.get(prefix, headers=headers).json()["items"] == []

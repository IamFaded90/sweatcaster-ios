import base64
import io
import json
import zipfile
from inspect import signature
from uuid import uuid4

import pytest
from fastapi import Request, Response
from tests.conftest import make_settings
from fastapi.testclient import TestClient

from sweatcaster.api import create_app
from sweatcaster import module_tabs
from sweatcaster.bot_computers import BotComputers
from sweatcaster import github_addons, grok_templates, microsoft_voice
from sweatcaster import pc_metrics
from sweatcaster.composio_library import ComposioLibrary
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


def test_removed_media_integration_is_unavailable(tmp_path):
    with TestClient(create_app(make_settings(tmp_path))) as client:
        assert client.get("/api/modules/v1/emby/library").status_code == 404


def module_endpoint(settings, path):
    app = create_app(settings)
    return next(route.endpoint for route in app.routes if getattr(route, "path", None) == path)


def module_request(settings, *, authorized=True):
    headers = [(b"authorization", ("Bearer " + settings.token).encode())] if authorized else []
    return Request({"type": "http", "headers": headers})


def test_agent_chat_passes_profile_to_the_selected_model(tmp_path, monkeypatch):
    from sweatcaster import bot_computers, v2_api

    settings = make_settings(tmp_path)
    endpoint = module_endpoint(settings, "/api/modules/v1/agent-chat")
    payload = {"modelID": "llama31-8b", "prompt": "Skriv det på dansk.", "instructions": "Du er Eva."}
    monkeypatch.setattr(v2_api, "catalog", lambda _: {
        "models": [{"id": "llama31-8b", "available": True}],
    })

    def local_reply(original_settings, request, *, purpose):
        assert original_settings is settings
        assert purpose == "agent-chat"
        assert request["model"] == "llama3.1:8b"
        assert "tools" not in request
        assert request["messages"] == [
            {"role": "system", "content": "Du er Eva."},
            {"role": "user", "content": "Skriv det på dansk."},
        ]
        return "Hej fra Eva."

    monkeypatch.setattr(bot_computers, "run_local_text", local_reply)
    with pytest.raises(ApiError) as rejected:
        endpoint(module_request(settings, authorized=False), Response(), payload)
    assert rejected.value.status_code == 401
    response = Response()
    assert endpoint(module_request(settings), response, payload) == {"text": "Hej fra Eva."}
    assert response.headers["Cache-Control"] == "no-store"
    with pytest.raises(ApiError) as invalid:
        endpoint(module_request(settings), Response(), {**payload, "modelID": "moondream-18"})
    assert invalid.value.status_code == 422


def test_agent_chat_research_cites_exact_page_chosen(tmp_path, monkeypatch):
    from sweatcaster import web_research

    settings = make_settings(tmp_path)
    endpoint = module_endpoint(settings, "/api/modules/v1/chat-research")
    url = "https://example.org/vejledning"
    monkeypatch.setattr(web_research, "page_excerpt", lambda link: "Offentlig vejledning." if link == url else "")
    with pytest.raises(ApiError) as rejected:
        endpoint(module_request(settings, authorized=False), Response(), {"query": url})
    assert rejected.value.status_code == 401
    assert endpoint(module_request(settings), Response(), {"query": url}) == {"context": "Offentlig vejledning.", "sources": [
        {"title": "Siden du valgte", "url": url, "readPage": True},
    ]}
    with pytest.raises(ApiError) as blocked:
        endpoint(module_request(settings), Response(), {"query": "http://localhost/"})
    assert blocked.value.status_code == 404


def test_pc_status_reports_partial_setup_and_protects_read_only_probes(tmp_path, monkeypatch):
    settings = make_settings(tmp_path)
    triggered = []

    def image(supported):
        triggered.append(supported)
        return {"image": "ready", "lumiImage": "missingModel"}

    monkeypatch.setattr(pc_metrics, "image_setup", image)
    monkeypatch.setattr(pc_metrics, "desktop_setup", lambda _: "missingImage")
    monkeypatch.setattr(pc_metrics, "web_setup", lambda: "responding")
    monkeypatch.setattr(pc_metrics, "gmail_setup", lambda *_: "signIn")
    client = TestClient(create_app(settings))
    headers = {"Authorization": "Bearer " + settings.token}
    assert client.get("/api/modules/v1/pc-setup").status_code == 401
    assert client.get("/api/modules/v1/pc-metrics").status_code == 401
    assert triggered == []
    setup = client.get("/api/modules/v1/pc-setup", headers=headers)
    assert setup.status_code == 200
    assert setup.headers["Cache-Control"] == "no-store"
    assert triggered == [True]
    assert {key: value for key, value in setup.json().items() if key != "pcVersion"} == {
        "desktops": "missingImage", "image": "ready", "lumiImage": "missingModel",
        "web": "responding", "gmail": "signIn",
    }
    assert setup.json()["pcVersion"]


def test_pc_temperature_uses_actual_package_and_keeps_gpu_with_missing_sensors():
    assert pc_metrics.cpu_package_temperature([
        {"Parent": "/lpc/0", "Name": "CPU Package", "Value": 98},
        {"Parent": "/intelcpu/0", "Name": "CPU Package", "Value": 51.0},
        {"Parent": "/amdcpu/0", "Name": "Core (Tctl/Tdie)", "Value": 56.8},
        {"Parent": "/intelcpu/0", "Name": "CPU Package", "Value": None},
    ]) == 57
    assert pc_metrics.cpu_package_temperature({"Parent": "/intelcpu/0", "Name": "Core #1", "Value": 56}) is None
    cards = pc_metrics.nvidia_cards('0, "RTX, Test", 17, 200, 8192, 36\nbad row\n1, GPU 2, [N/A], [N/A], 4096, [N/A]')
    assert cards[0] == {"id": "0", "name": "RTX, Test", "percent": 17,
                        "usedMiB": 200, "totalMiB": 8192, "temperatureC": 36}
    assert cards[1] == {"id": "1", "name": "GPU 2", "percent": None,
                        "usedMiB": None, "totalMiB": 4096, "temperatureC": None}


def test_pc_image_engine_status_requires_pairing_and_omits_local_logs(tmp_path, monkeypatch):
    settings = make_settings(tmp_path)
    probes = []

    def check_engine():
        probes.append(True)
        return "gpuError"

    monkeypatch.setattr(pc_metrics, "image_engine_status", check_engine)
    endpoint = module_endpoint(settings, "/api/modules/v1/pc-image-engine")
    with pytest.raises(ApiError) as rejected:
        endpoint(module_request(settings, authorized=False), Response())
    assert rejected.value.status_code == 401
    assert not probes
    response = Response()
    assert endpoint(module_request(settings), response) == {"state": "gpuError"}
    assert probes == [True]
    assert response.headers["Cache-Control"] == "no-store"


@pytest.mark.parametrize(("status", "body", "log", "age", "expected"), [
    (200, b'{"system":{"comfyui_version":"0.44.2"}}', b"torch.AcceleratorError: CUDA error: unknown error", 0, "ready"),
    (500, b"", b"torch.AcceleratorError: CUDA error: unknown error", 0, "gpuError"),
    (500, b"", b"[INFO] Using pytorch attention", 0, "unresponsive"),
    (200, b"not ComfyUI", b"", 0, "unresponsive"),
    (None, b"", b"[INFO] Using pytorch attention", 0, "starting"),
    (None, b"", b"[INFO] Using pytorch attention\n[INFO] Starting server", 0, "offline"),
    (None, b"", b"torch.AcceleratorError: CUDA error: unknown error", 121, "offline"),
])
def test_pc_image_engine_diagnoses_only_current_evidence(tmp_path, monkeypatch, status, body, log, age, expected):
    file = tmp_path / "engine.log"
    file.write_bytes(log)
    monkeypatch.setenv("FADEDAI_COMFY_ENGINE_LOG", str(file))
    observed = file.stat().st_mtime
    monkeypatch.setattr(pc_metrics.time, "time", lambda: observed + age)

    class Connection(io.BytesIO):
        def __init__(self, host, port, timeout):
            super().__init__(body)
            assert (host, port, timeout) == ("127.0.0.1", 8188, 3)
            self.status = status

        def request(self, method, path):
            assert (method, path) == ("GET", "/system_stats")
            if self.status is None:
                raise ConnectionRefusedError()

        def getresponse(self):
            return self

    monkeypatch.setattr(pc_metrics.http.client, "HTTPConnection", Connection)
    assert pc_metrics.image_engine_status() == expected


def test_code_addon_install_lists_opens_and_releases_slots_after_delete(tmp_path):
    settings = make_settings(tmp_path)
    headers = {"Authorization": "Bearer " + settings.token}
    base = "/api/modules/v1/addons"
    action = {"type": "tool", "label": "Lav pakkeliste", "value": "checklist"}
    addon = {"id": str(uuid4()), "title": "Weekendtur", "text": "Husk solcreme.", "actions": [action]}
    client = TestClient(create_app(settings))
    assert client.get(base).status_code == 401
    assert client.put(base, json=addon).status_code == 401
    assert client.get(base, headers=headers).json() == {"items": []}
    for invalid in ({"type": "shell", "value": "whoami"}, {"type": "tool", "value": "../../x"},
                    {"type": "link", "value": "https://example.com@evil.test"},
                    {"type": "link", "value": "javascript:alert(1)"}):
        assert client.put(base, headers=headers, json={**addon, "actions": [action | invalid]}).status_code == 422
    for _ in range(2):
        assert client.put(base, headers=headers, json=addon).json() == addon
    assert client.put(base, headers=headers, json=addon | {"title": "Andet navn"}).status_code == 409
    assert client.get(base, headers=headers).json() == {"items": [addon]}
    path = base + "/" + addon["id"] + "/remove"
    assert client.put(path, json={}).status_code == 401
    for _ in range(2):
        assert client.put(path, headers=headers, json={}).json() == {"ok": True}
    assert client.get(base, headers=headers).json() == {"items": []}
    replacement = addon | {"title": "Ny pakkeliste"}
    assert client.put(base, headers=headers, json=replacement).json() == replacement


def test_code_addon_draft_uses_model_without_installing(tmp_path, monkeypatch):
    from sweatcaster import bot_computers

    original = bot_computers.ollama_reports
    requested = []

    def generator(brief, source):
        requested.append((brief, source))
        return json.dumps({"title": "Pak tasken", "text": "Tjek hvad du skal have med.",
                           "actions": [{"type": "tool", "label": "Tjekliste", "value": "checklist"}]})

    def reports(settings, **options):
        return generator if options.get("add_on") else original(settings, **options)

    monkeypatch.setattr(bot_computers, "ollama_reports", reports)
    settings = make_settings(tmp_path)
    headers = {"Authorization": "Bearer " + settings.token}
    client = TestClient(create_app(settings))
    base = "/api/modules/v1/addons"
    assert client.put(base + "/draft", json={"brief": "Lav en pakkeliste"}).status_code == 401
    assert requested == []
    proposed = client.put(base + "/draft", headers=headers, json={"brief": "Lav en pakkeliste"})
    assert proposed.status_code == 200
    assert proposed.json()["actions"][0]["value"] == "checklist"
    assert requested == [("Lav en pakkeliste", None)]
    assert client.get(base, headers=headers).json() == {"items": []}


def test_github_static_addon_previews_installs_a_fixed_snapshot_and_deletes_its_files(tmp_path, monkeypatch):
    repo = "TestOrg/Time-Helper"
    revision = "deadbeef" * 5
    html = b'<button id="start">Start timer</button><script src="timer.js"></script>'
    archive = io.BytesIO()
    with zipfile.ZipFile(archive, "w", compression=zipfile.ZIP_DEFLATED) as zipped:
        zipped.writestr("Time-Helper-version/dist/index.html", html)
        zipped.writestr("Time-Helper-version/dist/timer.js", b'document.querySelector("#start").onclick = () => 0;')
        zipped.writestr("Time-Helper-version/build.sh", b"never executed")
    downloaded = []

    def receive(url, *, maximum, missing=False, params=None):
        if url.startswith(github_addons.CODELOAD):
            assert url.endswith(f"/{repo}/zip/{revision}")
            downloaded.append(url)
            return archive.getvalue()
        responses = {
            f"/repos/{repo}": {"private": False, "full_name": repo, "default_branch": "main",
                              "description": "A timer", "has_pages": True},
            f"/repos/{repo}/commits/main": {"sha": revision},
            f"/repos/{repo}/contents/{github_addons.MANIFEST}": None,
            f"/repos/{repo}/contents/dist/index.html": {"type": "file"},
        }
        if "/contents/" in url:
            assert params == {"ref": revision}
        result = responses[url.removeprefix(github_addons.GITHUB)]
        return json.dumps(result).encode() if result is not None else None

    monkeypatch.setattr(github_addons, "read", receive)
    settings = make_settings(tmp_path)
    client = TestClient(create_app(settings))
    headers = {"Authorization": "Bearer " + settings.token}
    base = "/api/modules/v1/addons"
    source = {"url": "https://github.com/" + repo, "local": True}
    assert client.put(base + "/github", json=source).status_code == 401
    assert client.put(base + "/github", headers=headers, json={"url": "https://github.com@other.test/" + repo}).status_code == 422
    response = client.put(base + "/github", headers=headers, json=source)
    assert response.status_code == 200
    addon = response.json()
    assert addon["source"] == {"repo": repo, "revision": revision, "kind": "static", "root": "dist"}
    assert addon["actions"][0]["type"] == "webApp"
    assert client.get(base, headers=headers).json() == {"items": []}
    assert downloaded == []
    for _ in range(2):
        assert client.put(base, headers=headers, json=addon).status_code == 200
    assert len(downloaded) == 1
    path = f"{base}/{addon['id']}/files"
    assert client.get(path).status_code == 401
    files = client.get(path, headers=headers).json()["files"]
    assert [item["path"] for item in files] == ["index.html", "timer.js"]
    assert base64.b64decode(files[0]["data"]) == html
    assert client.put(f"{base}/{addon['id']}/remove", headers=headers, json={}).status_code == 200
    assert client.get(path, headers=headers).status_code == 404


def test_github_web_package_rejects_traversal_and_symlinks(monkeypatch):
    source = {"repo": "TestOrg/Time-Helper", "revision": "a" * 40, "kind": "static", "root": "dist"}
    for invalid in ("Project/dist/../outside.html", "Project/dist/link.html"):
        archive = io.BytesIO()
        with zipfile.ZipFile(archive, "w") as zipped:
            zipped.writestr("Project/dist/index.html", "<h1>Timer</h1>")
            if "link" in invalid:
                entry = zipfile.ZipInfo(invalid)
                entry.create_system = 3
                entry.external_attr = 0o120777 << 16
                zipped.writestr(entry, "/private")
            else:
                zipped.writestr(invalid, "outside")
        monkeypatch.setattr(github_addons, "read", lambda *_, **__: archive.getvalue())
        with pytest.raises(ApiError) as failure:
            github_addons.pack_web_files(source)
        assert failure.value.status_code == 422


def test_public_github_pages_and_fadedai_manifest_produce_usable_actions(monkeypatch):
    repo, revision = "TestOrg/Tiny", "a" * 40
    published = {"full_name": repo, "private": False, "has_pages": True, "default_branch": "main"}
    manifest = {"version": 1, "title": "Tjekliste", "text": "Planlæg turen.",
                "actions": [{"type": "tool", "label": "Åbn liste", "value": "checklist"}]}
    responses = {f"/repos/{repo}": published, f"/repos/{repo}/commits/main": {"sha": revision},
                 f"/repos/{repo}/contents/{github_addons.MANIFEST}": None}
    monkeypatch.setattr(github_addons, "get_json", lambda path, **_: responses[path])
    link = "https://github.com/" + repo
    draft = github_addons.proposal(link)
    assert draft["source"]["kind"] == "pages"
    assert draft["actions"][0]["value"] == "https://testorg.github.io/Tiny/"
    responses[f"/repos/{repo}/contents/{github_addons.MANIFEST}"] = {
        "type": "file", "encoding": "base64", "content": base64.b64encode(json.dumps(manifest).encode()).decode(),
    }
    draft = github_addons.proposal(link)
    assert draft["source"]["kind"] == "manifest"
    assert draft["actions"] == manifest["actions"]


def test_attention_queue_uses_only_paired_local_pending_data(tmp_path):
    settings = make_settings(tmp_path)
    route = "/api/modules/v1/attention"
    with TestClient(create_app(settings)) as client:
        assert client.get(route).status_code == 401
        received = client.get(route, headers={"Authorization": "Bearer " + settings.token})
        assert received.status_code == 200
        assert received.headers["Cache-Control"] == "no-store"
        assert received.json() == {"code": [], "video": [], "mail": None}


def test_local_search_wakeup_uses_only_matching_loopback_container(monkeypatch, tmp_path):
    from types import SimpleNamespace

    calls = []
    replies = iter(("offline", "responding"))
    monkeypatch.setattr(pc_metrics, "web_setup", lambda: next(replies))
    monkeypatch.setattr(pc_metrics.shutil, "which", lambda _: "docker")
    container = "ab12" * 3

    def docker(cmd, **options):
        calls.append(cmd)
        assert options["check"]
        return SimpleNamespace(stdout={
            "ps": container,
            "inspect": '{"8080/tcp":[{"HostIp":"127.0.0.1","HostPort":"8080"}]}',
            "start": container,
        }[cmd[3]])

    monkeypatch.setattr(pc_metrics.subprocess, "run", docker)
    assert pc_metrics.wake_local_search(tmp_path)
    assert [cmd[3] for cmd in calls] == ["ps", "inspect", "start"]
    assert f"label=com.docker.compose.project.working_dir={tmp_path}" in calls[0]
    assert calls[-1][4] == container


def test_new_external_routes_require_pairing_before_network_requests(tmp_path, monkeypatch):
    monkeypatch.setattr(grok_templates, "import_template", lambda url: {"name": url})
    monkeypatch.setattr(microsoft_voice, "credentials", lambda: ("private-speech-key", "westeurope"))
    monkeypatch.setattr(microsoft_voice, "synthesize", lambda text: {"audio": text})
    settings = make_settings(tmp_path)
    headers = {"Authorization": "Bearer " + settings.token}
    base = "/api/modules/v1/"
    with TestClient(create_app(settings)) as client:
        assert client.put(base + "grok-template", json={"url": "example"}).status_code == 401
        assert client.put(base + "christel", json={"text": "example"}).status_code == 401
        result = client.get(base + "christel", headers=headers)
        assert result.json() == {"configured": True}
        assert result.headers["Cache-Control"] == "no-store"
        assert client.put(base + "christel", headers=headers, json={"text": "example"}).json() == {"audio": "example"}
        assert client.put(base + "grok-template", headers=headers, json={"url": "example"}).json() == {"name": "example"}


def test_composio_uses_project_key_and_discovers_managed_login_without_manual_id(tmp_path, monkeypatch):
    monkeypatch.setenv("COMPOSIO_API_KEY", "test-project-key")
    monkeypatch.delenv("FADEDAI_COMPOSIO_GOOGLEDRIVE_AUTH_CONFIG", raising=False)
    monkeypatch.setattr("sweatcaster.composio_library.load", lambda: {})
    library = ComposioLibrary(tmp_path)
    configs = []

    def provider(method, path, *, version="v3", params=None, payload=None):
        if path == "/auth_configs":
            assert version == "v3.1"
            if method == "GET":
                assert params["toolkit_slug"] == "googledrive"
                return {"items": list(configs)}
            assert payload == {"toolkit": {"slug": "googledrive"},
                               "auth_config": {"type": "use_composio_managed_auth"}}
            entry = {"id": "ac_test", "toolkit": {"slug": "googledrive"}, "status": "ENABLED",
                     "is_composio_managed": True}
            configs.append(entry)
            return {"auth_config": entry, "toolkit": entry["toolkit"]}
        assert path == "/connected_accounts/link"
        assert payload == {"auth_config_id": "ac_test", "user_id": library.owner}
        return {"redirect_url": "https://connect.composio.dev/example"}

    monkeypatch.setattr(library, "request", provider)
    assert library.link("googledrive") == library.link("googledrive")
    assert len(configs) == 1


def test_christel_escapes_markup_and_uses_the_danish_voice():
    body = microsoft_voice.markup("Hej <break/> & velkommen\x00").decode()
    assert 'name="da-DK-ChristelNeural"' in body
    assert "Hej &lt;break/&gt; &amp; velkommen" in body
    assert "\x00" not in body


def test_composio_reads_only_the_selected_sheet_notion_page_and_repo(tmp_path, monkeypatch):
    library = ComposioLibrary(tmp_path)
    page = str(uuid4())
    monkeypatch.setattr(library, "connection", lambda provider: f"ca_{provider}")
    calls = []
    text_run = {"plain_text": "Testnote"}

    def request(method, path, *, payload, version):
        assert (method, path, version) == ("POST", "/tools/execute/proxy", "v3.1")
        assert all(set(parameter) == {"name", "value", "type"} for parameter in payload["parameters"])
        url = payload["endpoint"]
        calls.append(payload)
        if url.endswith("/drive/v3/files"):
            assert payload["connected_account_id"] == "ca_googledrive"
            assert any("application/vnd.google-apps.spreadsheet" in p["value"] for p in payload["parameters"])
            body = {"files": [{"id": "sheet-test", "name": "Indkøb"}]}
        elif url.endswith("/spreadsheets/sheet-test"):
            body = {"properties": {"title": "Indkøb"}, "sheets": [{"properties": {"title": "Denne uge"}}]}
        elif url.endswith("/values/%27Denne%20uge%27%21A1%3AJ25"):
            body = {"values": [["Mælk", 2]]}
        elif url.endswith("/search"):
            assert payload["method"] == "POST"
            assert payload["body"]["filter"] == {"property": "object", "value": "page"}
            body = {"results": [{"object": "page", "id": page, "properties": {
                "Name": {"type": "title", "title": [text_run]}}}]}
        elif url.endswith(f"/blocks/{page}/children"):
            body = {"results": [{"type": "paragraph", "paragraph": {"rich_text": [text_run]}}]}
        elif url.endswith("/repos/test/repo"):
            body = {"description": "Testrepo", "has_issues": True}
        elif url.endswith("/issues"):
            body = [{"number": 4, "title": "Ret menu"}, {"number": 5, "title": "Skjul PR", "pull_request": {}}]
        elif url.endswith("/pulls"):
            body = [{"number": 7, "title": "Ret tema"}]
        else:
            raise AssertionError(url)
        return {"status": 200, "data": body}

    monkeypatch.setattr(library, "request", request)
    assert library.items("googlesheets") == {"items": [{"id": "sheet-test", "title": "Indkøb"}]}
    assert "Mælk | 2" in library.context("googlesheets", "sheet-test")["text"]
    assert library.items("notion") == {"items": [{"id": page, "title": "Testnote"}]}
    assert "Testnote" in library.context("notion", page)["text"]
    listing = library.context("github", "test/repo")["text"]
    assert "Opgave #4" in listing and "Pull request #7" in listing and "#5" not in listing
    assert all(call["method"] == "GET" or call["endpoint"] == "https://api.notion.com/v1/search" for call in calls)
    with pytest.raises(ApiError):
        library.context("notion", "../private")
    assert len(calls) == 8


def test_composio_uses_an_approved_drive_account_for_sheets_when_needed(tmp_path, monkeypatch):
    library = ComposioLibrary(tmp_path)
    monkeypatch.setattr(library, "config", lambda provider: provider)
    accounts = {"googledrive": "ca_drive"}
    monkeypatch.setattr(library, "account", lambda provider, _config: accounts.get(provider))
    assert library.connection("googlesheets") == "ca_drive"
    accounts["googlesheets"] = "ca_sheets"
    assert library.connection("googlesheets") == "ca_sheets"


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


def test_code_snapshot_removal_requires_pairing_and_matching_confirmation(tmp_path, monkeypatch):
    from sweatcaster.code_batch import CodeBatch
    from sweatcaster.repository_library import RepositoryInUse

    calls = []
    def remove(_batch, repo):
        calls.append(repo)
        if repo == "example/busy":
            raise RepositoryInUse("Projektet er i brug.")
        return repo == "example/demo"

    monkeypatch.setattr(CodeBatch, "remove_repository", remove)
    settings = make_settings(tmp_path)
    app = create_app(settings)
    url = "/api/modules/v1/code-repositories/removal"
    endpoint = next(route.endpoint for route in app.routes if getattr(route, "path", None) == url)
    unpaired = Request({"type": "http", "headers": []})
    paired = Request({"type": "http", "headers": [(b"authorization", ("Bearer " + settings.token).encode())]})
    valid = {"repo": "example/demo", "confirm_repo": "example/demo"}
    with pytest.raises(ApiError) as rejection:
        endpoint(unpaired, valid)
    assert rejection.value.status_code == 401
    with pytest.raises(ApiError) as rejection:
        endpoint(paired, {**valid, "confirm_repo": "example/other"})
    assert rejection.value.status_code == 422
    assert calls == []
    with pytest.raises(ApiError) as rejection:
        endpoint(paired, {"repo": "example/busy", "confirm_repo": "example/busy"})
    assert rejection.value.status_code == 409
    assert endpoint(paired, valid) == {"removed": True}
    assert endpoint(paired, {"repo": "example/other", "confirm_repo": "example/other"}) == {"removed": False}


def test_module_mcp_rejects_untrusted_clients_and_exposes_agent_tools(tmp_path, monkeypatch):
    fastmcp = pytest.importorskip("mcp.server.fastmcp")
    if "max_request_body_size" not in signature(fastmcp.FastMCP).parameters:
        pytest.skip("HTTP MCP requires an SDK with bounded request bodies.")
    settings = make_settings(tmp_path)
    from sweatcaster import comfy, studio_video
    from sweatcaster.code_batch import CodeBatch

    monkeypatch.setattr(comfy, "generate_png", lambda prompt: b"\x89PNG\r\n\x1a\n" + prompt.encode())
    monkeypatch.setattr(CodeBatch, "enqueue", lambda self, repo, goal, files, priority:
                        "proposal" if (repo, files, priority) == ("example/demo", ["main.py"], 0) else "unexpected")
    monkeypatch.setattr(studio_video.StudioVideos, "submit", lambda self, body:
                        {"id": body["id"], "mode": body["mode"], "state": "working"})
    monkeypatch.setattr(studio_video.StudioVideos, "status", lambda self, job_id:
                        {"id": job_id, "state": "ready"})
    headers = {"Authorization": "Bearer " + settings.token, "Accept": "application/json, text/event-stream"}
    request = {"jsonrpc": "2.0", "id": 1, "method": "tools/list", "params": {}}
    with TestClient(create_app(settings), base_url="http://127.0.0.1:8765") as client:
        url = "/api/modules/v1/mcp"
        assert client.post(url, json=request).status_code == 401
        assert client.post(url, headers={**headers, "Host": "evil.example"}, json=request).status_code == 403
        assert client.post(url, headers={**headers, "Origin": "http://127.0.0.1:8765"}, json=request).status_code == 403
        reply = client.post(url, headers=headers, json=request)
        assert reply.status_code == 200, reply.text
        assert {tool["name"] for tool in reply.json()["result"]["tools"]} == {
            "read_repository_file", "search_repository", "create_code_proposal", "generate_image",
            "studio_video_models", "create_video", "studio_video_status",
        }

        def tool(name, **arguments):
            result = client.post(url, headers=headers, json={"jsonrpc": "2.0", "id": 2,
                "method": "tools/call", "params": {"name": name, "arguments": arguments}})
            assert result.status_code == 200, result.text
            return result.json()["result"]

        def object_result(result):
            import json
            assert not result.get("isError"), result
            return result.get("structuredContent") or json.loads(result["content"][0]["text"])

        assert object_result(tool("create_code_proposal", repository="example/demo", goal="Improve the title",
                                  files=["main.py"]))["id"] == "proposal"
        assert tool("generate_image", prompt="a desk lamp")["content"][0]["mimeType"] == "image/png"
        assert tool("generate_image", prompt=" ")["isError"]
        key = str(uuid4())
        assert object_result(tool("create_video", request_id=key, mode="wan-text", prompt="a desk lamp"))["id"] == key
        assert object_result(tool("studio_video_status", job_id=key))["state"] == "ready"


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

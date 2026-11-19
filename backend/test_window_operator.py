from threading import Event
from types import SimpleNamespace
import os
import time

import pytest
from fastapi import FastAPI, HTTPException
from fastapi.testclient import TestClient

from sweatcaster.dto import ApiError
from sweatcaster.window_capture import Window
from sweatcaster.window_help import WindowHelp, register_window_help
from sweatcaster.window_operator import WindowOperator, action_schema, validate_action


class Desktop:
    def __init__(self):
        self.window = Window(17, 20, "Prøve", "Fixture")
        self.text = "Klar"
        self.clicked = 0

    def state(self, window):
        if window.pid != self.window.pid:
            raise ValueError("Replaced")
        return "visible"

    def list_windows(self):
        return [self.window]

    def labels(self, window):
        return [self.text]

    def capture(self, window):
        return self.text.encode()


class Automation:
    def __init__(self, native):
        self.native = native
        self.control = {"id": "button-1", "role": "Button", "name": "Gem"}

    def controls(self, window):
        return [dict(self.control)]

    def perform(self, window, action):
        self.native.clicked += 1
        self.native.text = "Gemt"


def test_window_identity_allows_title_changes_and_rejects_another_process(monkeypatch):
    from sweatcaster import window_capture
    selected = Window(17, 20, "Før navigation", "Browser")
    current = Window(17, 20, "Efter navigation", "Browser")
    monkeypatch.setattr(window_capture, "_window", lambda _: current)
    assert window_capture.current(selected)
    current = Window(17, 99, "Efter navigation", "Browser")
    assert not window_capture.current(selected)
    current = Window(17, 20, "Efter navigation", "AndenKlasse")
    assert not window_capture.current(selected)


def fixture(planner=None):
    native = Desktop()
    helper = WindowHelp(None, native=native)
    automation = Automation(native)
    planner = planner or (lambda *_: {"type": "click", "target": "button-1", "title": "Tryk Gem"})
    operator = WindowOperator(helper, automation=automation, planner=planner)
    token = helper.windows()["windows"][0]["id"]
    session = operator.session(token)
    return native, helper, automation, operator, token, session["job"]


def test_plan_is_observed_and_single_use_then_returns_fresh_result():
    native, _, _, operator, _, job = fixture()
    plan = operator.plan(job, "Gem teksten")
    assert native.clicked == 0
    result = operator.step(job, plan["proposal"])
    assert native.clicked == 1 and result["observation"]["labels"] == ["Gemt"]
    with pytest.raises(ApiError):
        operator.step(job, plan["proposal"])
    assert native.clicked == 1


def test_changed_control_or_window_never_receives_stale_step():
    native, _, automation, operator, _, job = fixture()
    plan = operator.plan(job, "Gem")
    automation.control["name"] = "Slet"
    with pytest.raises(ApiError):
        operator.step(job, plan["proposal"])
    assert native.clicked == 0
    plan = operator.plan(job, "Gem")
    native.window = Window(17, 99, "Udskiftet", "Fixture")
    with pytest.raises(ApiError):
        operator.step(job, plan["proposal"])
    assert native.clicked == 0


def test_stop_interrupts_model_before_any_input():
    entered, resume = Event(), Event()
    def planner(*_):
        entered.set()
        resume.wait(3)
        return {"type": "click", "target": "button-1", "title": "Tryk"}
    native, _, _, operator, _, job = fixture(planner)
    operator.run(job, "Gem")
    assert entered.wait(2)
    operator.stop(job)
    resume.set()
    operator.jobs[job]["thread"].join(3)
    assert native.clicked == 0
    assert operator.status(job)["state"] == "stopped"


def test_autonomous_worker_rechecks_before_marking_complete():
    calls = []
    def planner(_, goal, observation, history):
        calls.append(observation["labels"][0])
        return ({"type": "done", "message": "Gemt i vinduet", "evidence": "Gemt"}
                if observation["labels"] == ["Gemt"] else {"type": "click", "target": "button-1", "title": "Tryk Gem"})
    native, _, _, operator, token, job = fixture(planner)
    assert operator.session(token)["job"] == job
    operator.run(job, "Gem")
    operator.jobs[job]["thread"].join(3)
    assert calls == ["Klar", "Gemt"]
    assert native.clicked == 1 and operator.status(job)["state"] == "completed"


def test_false_success_and_unseen_targets_are_rejected():
    _, _, _, operator, _, job = fixture(lambda *_: {"type": "done", "message": "Alt færdigt", "evidence": "Usynlig tekst"})
    assert operator.plan(job, "Udfør noget")["step"]["type"] == "ask"
    operator.automation.control["value"] = "Ikke markeret"
    operator.planner = lambda *_: {"type": "done", "message": "Markeret", "evidence": "Markeret"}
    assert operator.plan(job, "Udfør noget")["step"]["type"] == "ask"
    for action in [{"type": "click", "target": "missing"}, {"type": "type", "target": "button-1", "text": "test"},
                   {"type": "key", "key": "win+r"}, {"type": "click", "x": 0.5, "y": 0.5}]:
        with pytest.raises(ValueError):
            validate_action(action, [{"id": "button-1", "role": "Button", "name": "Gem"}])
    for x in [float("nan"), float("inf"), -1, 1, True]:
        with pytest.raises(ValueError):
            validate_action({"type": "click", "x": x, "y": 0.5}, [], manual=True)


def test_model_schema_limits_typing_to_observed_fields_and_keys_to_an_explicit_request():
    controls = [{"id": "edit-1", "role": "Edit", "name": "Navn"}]
    schema = action_schema(controls, goal="Skriv Eva i feltet Navn")
    assert "type" in schema["properties"]["type"]["enum"]
    assert "key" not in schema["properties"]["type"]["enum"]
    assert "click" not in schema["properties"]["type"]["enum"]
    assert schema["properties"]["target"]["enum"] == ["edit-1"]
    explicit = action_schema(controls, goal="Tryk enter")
    assert explicit["properties"]["key"]["enum"] == ["enter"]


def test_operator_routes_inherit_pairing():
    app = FastAPI()
    def authorize(request, _):
        if request.headers.get("Authorization") != "Bearer paired":
            raise HTTPException(401)
    helper = register_window_help(app, None, authorize)
    helper.native = Desktop()
    client = TestClient(app)
    for endpoint in ["session", "plan", "run", "step", "input", "stop"]:
        assert client.put("/api/modules/v1/window-help/" + endpoint, json={}).status_code == 401
    assert client.get("/api/modules/v1/window-help/jobs/nope").status_code == 401


@pytest.mark.skipif(os.name != "nt" or os.getenv("FADEDAI_TEST_OPERATOR") != "1",
                    reason="Uses only its own native Windows test controls")
def test_native_accessibility_can_fill_and_click_its_own_fixture():
    import ctypes
    from ctypes import wintypes as w
    import subprocess
    import sys
    from sweatcaster import window_capture, window_automation
    code = r"""
import ctypes
from ctypes import wintypes as w
u=ctypes.windll.user32
u.CreateWindowExW.restype=w.HWND
root=u.CreateWindowExW(0x08000080,'#32770','FadedAI operator fixture',0x90000000,10,10,320,200,None,None,None,None)
edit=u.CreateWindowExW(0,'Edit','',0x50800000,10,15,260,25,w.HWND(root),None,None,None)
button=u.CreateWindowExW(0,'Button','Afprøv',0x50000003,10,55,140,30,w.HWND(root),None,None,None)
print(root,edit,button,flush=True)
msg=w.MSG()
while u.GetMessageW(ctypes.byref(msg),None,0,0)>0:
    u.TranslateMessage(ctypes.byref(msg));u.DispatchMessageW(ctypes.byref(msg))
"""
    python = getattr(sys, "_base_executable", None) or sys.executable
    with subprocess.Popen([python, "-I", "-c", code], stdout=subprocess.PIPE,
                          creationflags=subprocess.CREATE_NO_WINDOW) as process:
        try:
            hwnd, edit, button = map(int, process.stdout.readline().split())
            selected = window_capture._window(hwnd)
            assert selected and selected.pid == process.pid
            controls = window_automation.controls(selected)
            field = next(c for c in controls if c["role"] == "Edit")
            target = next(c for c in controls if c["name"] == "Afprøv")
            typing = {"type": "type", "target": field["id"], "text": "Prøve på dansk"}
            clicking = {"type": "click", "target": target["id"]}
            if os.getenv("FADEDAI_TEST_OPERATOR_MODEL") == "1":
                from sweatcaster.config import load_settings
                from sweatcaster.window_operator import local_plan
                settings = load_settings()
                observation = {"title": "Eget prøvevindue", "labels": [], "controls": controls}
                typing = validate_action(local_plan(settings, "Skriv præcis Prøve på dansk i tekstfeltet",
                                                    observation, []), controls)
                clicking = validate_action(local_plan(settings, "Markér afkrydsningsfeltet Afprøv",
                                                      observation, []), controls)
                assert typing["type"] == "type" and typing["target"] == field["id"] and typing["text"] == "Prøve på dansk"
                assert clicking["type"] == "click" and clicking["target"] == target["id"]
            window_automation.perform(selected, typing)
            value = ctypes.create_unicode_buffer(100)
            result = ctypes.c_size_t()
            assert ctypes.windll.user32.SendMessageTimeoutW(w.HWND(edit),13,100,ctypes.byref(value),2,500,ctypes.byref(result))
            assert value.value == "Prøve på dansk"
            window_automation.perform(selected, clicking)
            assert ctypes.windll.user32.SendMessageTimeoutW(w.HWND(button),0xF0,0,0,2,500,ctypes.byref(result))
            assert result.value == 1
            if os.getenv("FADEDAI_TEST_OPERATOR_MODEL") == "1":
                empty = ctypes.create_unicode_buffer("")
                assert ctypes.windll.user32.SendMessageTimeoutW(w.HWND(edit),12,0,ctypes.byref(empty),2,500,ctypes.byref(result))
                assert ctypes.windll.user32.SendMessageTimeoutW(w.HWND(button),0xF1,0,0,2,500,ctypes.byref(result))
                helper = WindowHelp(settings)
                token = helper._remember(helper.tokens, selected, 300)
                operator = WindowOperator(helper)
                job = operator.session(token)["job"]
                operator.run(job, "Skriv 'Prøve på dansk' i tekstfeltet og markér afkrydsningsfeltet Afprøv.")
                operator.jobs[job]["thread"].join(40)
                assert not operator.jobs[job]["running"], "Operatørens prøve sluttede ikke"
                assert ctypes.windll.user32.SendMessageTimeoutW(w.HWND(edit),13,100,ctypes.byref(value),2,500,ctypes.byref(result))
                assert value.value == "Prøve på dansk"
                assert ctypes.windll.user32.SendMessageTimeoutW(w.HWND(button),0xF0,0,0,2,500,ctypes.byref(result))
                assert result.value == 1
                assert operator.status(job)["state"] == "completed"
            assert ctypes.windll.user32.SetWindowTextW(w.HWND(hwnd), "FadedAI nyt sidenavn")
            assert window_capture.current(selected)
            assert window_capture.task_window(selected).title == "FadedAI nyt sidenavn"
        finally:
            process.terminate()

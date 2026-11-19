from types import SimpleNamespace
import os
import sys

import pytest
from fastapi import FastAPI, HTTPException
from fastapi.testclient import TestClient

from sweatcaster import window_capture, window_help
from sweatcaster.dto import ApiError


class DemoDesktop:
    def __init__(self):
        self.window = window_capture.Window(17, 5, "Testvinduet", "Test")
        self.mode = "visible"
        self.pixels = b"demo"
        self.reads = 0
        self.restores = 0

    def list_windows(self):
        return [self.window]

    def state(self, window):
        if self.window != window:
            raise ValueError("Replaced")
        return self.mode

    def labels(self, window):
        return ["Forbindelsen er afbrudt"]

    def capture(self, window):
        self.reads += 1
        return self.pixels

    def restore(self, window):
        self.restores += 1
        self.mode = "visible"


def instance():
    native = DemoDesktop()
    app = window_help.WindowHelp(None, native, lambda settings, image, question: "Programmet viser en fejl.")
    token = app.windows()["windows"][0]["id"]
    return app, native, token


def test_only_selected_window_is_read_and_every_inspection_is_fresh():
    app, native, token = instance()
    assert native.reads == 0
    assert app.inspect(token, "Hvad er fejlen?")["labels"] == ["Forbindelsen er afbrudt"]
    assert app.inspect(token, "Tjek igen")["reading"] == "Programmet viser en fejl."
    assert native.reads == 2
    assert "demo" not in str(app.tokens)


def test_replaced_window_and_expired_selection_do_not_capture():
    app, native, token = instance()
    native.window = window_capture.Window(17, 99, "Andet vindue", "Test")
    with pytest.raises(ApiError):
        app.inspect(token, "")
    app.tokens[token] = (native.window, 0)
    with pytest.raises(ApiError):
        app.inspect(token, "")
    assert native.reads == 0


def test_restore_needs_an_observed_minimized_window_and_single_use_approval():
    app, native, token = instance()
    with pytest.raises(ApiError):
        app.approve(token, "not-approved")
    native.mode = "minimized"
    report = app.inspect(token, "")
    assert native.restores == native.reads == 0
    assert "bekræfter" in app.approve(token, report["approval"])["message"]
    with pytest.raises(ApiError):
        app.approve(token, report["approval"])
    assert native.restores == 1
    assert native.mode == "visible"


def test_changed_state_does_not_repeat_action():
    app, native, token = instance()
    native.mode = "minimized"
    approval = app.inspect(token, "")["approval"]
    native.mode = "visible"
    assert "ændret" in app.approve(token, approval)["message"]
    assert native.restores == 0


def test_failed_capture_returns_actual_labels_and_skips_model():
    app, native, token = instance()
    native.pixels = None
    app.vision = lambda *_: pytest.fail("No image")
    result = app.inspect(token, "")
    assert "jpeg" not in result and "reading" not in result
    assert result["labels"] == ["Forbindelsen er afbrudt"]


def test_vision_rejects_remote_before_contact():
    with pytest.raises(Exception, match="PC"):
        window_help._vision(SimpleNamespace(ollama_origin="http://devices.invalid:11434"), "bm8=", "")


def test_routes_require_pairing_and_never_cache():
    app = FastAPI()

    def authorize(request, _):
        if request.headers.get("Authorization") != "Bearer paired":
            raise HTTPException(401)

    service = window_help.register_window_help(app, None, authorize)
    service.native = DemoDesktop()
    client = TestClient(app)
    path = "/api/modules/v1/window-help/"
    assert client.get(path + "windows").status_code == 401
    assert client.put(path + "inspect", json={"token": "a", "question": "b"}).status_code == 401
    assert client.put(path + "restore", json={"token": "a", "approval": "b"}).status_code == 401
    result = client.get(path + "windows", headers={"Authorization": "Bearer paired"})
    assert result.status_code == 200 and result.headers["cache-control"] == "no-store"
    token = result.json()["windows"][0]["id"]
    service.native.mode = "minimized"
    inspection = client.put(path + "inspect", headers={"Authorization": "Bearer paired"}, json={"token": token})
    assert inspection.status_code == 200 and inspection.headers["cache-control"] == "no-store"
    restore = client.put(path + "restore", headers={"Authorization": "Bearer paired"},
                         json={"token": token, "approval": inspection.json()["approval"]})
    assert restore.status_code == 200 and "bekræfter" in restore.json()["message"]


@pytest.mark.skipif(os.name != "nt" or os.getenv("FADEDAI_TEST_WINDOW") != "1",
                    reason="Opt-in native test on its own off-screen fixture")
def test_real_window_captures_only_its_fixture():
    import io
    import subprocess
    from PIL import Image

    fixture = r"""
import ctypes, sys
from ctypes import wintypes as w
u = ctypes.windll.user32
u.CreateWindowExW.restype = w.HWND
hwnd = u.CreateWindowExW(0x08000080, '#32770', 'FadedAI synthetic fixture', 0x90000000,
                         -18000, -18000, 640, 260, None, None, None, None)
if not hwnd:
    sys.exit(1)
label = u.CreateWindowExW(0, 'Static', 'Synthetic connection lost', 0x50000000,
                          30, 55, 580, 140, w.HWND(hwnd), None, None, None)
gdi = ctypes.windll.gdi32
gdi.CreateFontW.restype = w.HFONT
font = gdi.CreateFontW(44, 0, 0, 0, 600, 0, 0, 0, 1, 0, 0, 0, 0, "Arial")
if font:
    u.SendMessageW(w.HWND(label), 0x30, w.HFONT(font), 1)
u.UpdateWindow(w.HWND(hwnd))
u.UpdateWindow(w.HWND(label))
print(hwnd, flush=True)
msg = w.MSG()
while u.GetMessageW(ctypes.byref(msg), None, 0, 0) > 0:
    u.TranslateMessage(ctypes.byref(msg))
    u.DispatchMessageW(ctypes.byref(msg))
"""
    python = getattr(sys, "_base_executable", None) or sys.executable
    with subprocess.Popen([python, "-I", "-c", fixture], stdout=subprocess.PIPE,
                          creationflags=subprocess.CREATE_NO_WINDOW) as proc:
        try:
            hwnd = int(proc.stdout.readline())
            item = window_capture._window(hwnd)
            assert item.pid == proc.pid and item.title == "FadedAI synthetic fixture"
            assert "Synthetic connection lost" in window_capture.labels(item)
            import time
            for _ in range(3):
                pixels = window_capture.capture(item)
                if pixels:
                    break
                time.sleep(0.1)
            assert pixels and Image.open(io.BytesIO(pixels)).size == (640, 260)
            if os.getenv("FADEDAI_TEST_WINDOW_VISION") == "1":
                from base64 import b64encode
                from sweatcaster.config import load_settings
                result = window_help._vision(load_settings(), b64encode(pixels).decode("ascii"),
                                             "Hvilken tekst står der i vinduet?")
                assert result, "Ingen vurdering fra den lokale billedmodel"
                print("Syntetisk vindue, lokal model:", result)
            # Force this fixture alone into the minimized condition and restore it through the real action.
            import ctypes
            from ctypes import wintypes
            ctypes.windll.user32.ShowWindowAsync(wintypes.HWND(hwnd), 7)
            for _ in range(20):
                if window_capture.state(item) == "minimized":
                    break
                time.sleep(0.05)
            service = window_help.WindowHelp(None)
            token = service._remember(service.tokens, item, 10)
            inspection = service.inspect(token, "")
            assert "bekræfter" in service.approve(token, inspection["approval"])["message"]
        finally:
            proc.terminate()

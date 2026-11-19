"""Inspect one selected Windows window without ever sampling the desktop framebuffer."""

import ctypes
from ctypes import wintypes as wt
from dataclasses import dataclass
import io
import math
from importlib.util import find_spec
import json
import os
from pathlib import Path
import subprocess
import sys
from time import monotonic


@dataclass(frozen=True)
class Window:
    hwnd: int
    pid: int
    title: str
    kind: str


def _user():
    return ctypes.windll.user32


def _window(hwnd):
    user = _user()
    if not user.IsWindowVisible(wt.HWND(hwnd)):
        return None
    title = ctypes.create_unicode_buffer(512)
    kind = ctypes.create_unicode_buffer(256)
    pid = wt.DWORD()
    user.GetWindowTextW(wt.HWND(hwnd), title, len(title))
    user.GetClassNameW(wt.HWND(hwnd), kind, len(kind))
    user.GetWindowThreadProcessId(wt.HWND(hwnd), ctypes.byref(pid))
    if not title.value.strip() or not pid.value or kind.value in {"Progman", "WorkerW", "Shell_TrayWnd"}:
        return None
    return Window(hwnd, pid.value, title.value, kind.value)


def list_windows():
    if os.name != "nt":
        raise OSError("Windows er påkrævet.")
    found = []

    @ctypes.WINFUNCTYPE(wt.BOOL, wt.HWND, wt.LPARAM)
    def collect(hwnd, _):
        item = _window(hwnd)
        if item:
            found.append(item)
        return len(found) < 80

    _user().EnumWindows(collect, 0)
    return found


def current(window):
    now = _window(window.hwnd)
    return now is not None and (now.hwnd, now.pid, now.kind) == (window.hwnd, window.pid, window.kind)


def task_window(window):
    """Follow a visible owned dialog from the selected process, such as its file picker."""
    if not current(window):
        raise ValueError("Det valgte vindue er lukket.")
    user = _user()
    user.GetWindow.restype = wt.HWND
    candidates = []

    @ctypes.WINFUNCTYPE(wt.BOOL, wt.HWND, wt.LPARAM)
    def visit(hwnd, _):
        pid = wt.DWORD()
        user.GetWindowThreadProcessId(wt.HWND(hwnd), ctypes.byref(pid))
        if pid.value != window.pid:
            return True
        candidate = _window(hwnd)
        if candidate is None or candidate.pid != window.pid or hwnd == window.hwnd:
            return True
        if candidate.kind != "#32770" and user.IsWindowEnabled(wt.HWND(window.hwnd)):
            return True
        owner = user.GetWindow(wt.HWND(hwnd), 4)
        for _ in range(8):
            if not owner:
                break
            if owner == window.hwnd:
                candidates.append(candidate)
                break
            owner = user.GetWindow(wt.HWND(owner), 4)
        return True
    user.EnumWindows(visit, 0)
    if not current(window):
        raise ValueError("Det valgte vindue er ændret.")
    return candidates[0] if candidates else _window(window.hwnd)


def state(window):
    if not current(window):
        raise ValueError("Vinduet er lukket eller har skiftet indhold. Vælg det igen.")
    hwnd = wt.HWND(window.hwnd)
    if _user().IsIconic(hwnd):
        return "minimized"
    if _user().IsHungAppWindow(hwnd):
        return "hung"
    return "visible"


def restore(window):
    if state(window) == "minimized":
        _user().ShowWindowAsync(wt.HWND(window.hwnd), 9)  # SW_RESTORE


def interact(window, action):
    """A user-authorized input step, bounded to the selected foreground window."""
    import time

    user = _user()
    hwnd = wt.HWND(window.hwnd)
    if state(window) != "visible":
        raise ValueError("Vinduet skal være åbent.")
    user.SetForegroundWindow(hwnd)
    time.sleep(0.06)

    def foreground():
        user.GetForegroundWindow.restype = wt.HWND
        user.GetAncestor.restype = wt.HWND
        active = user.GetForegroundWindow()
        if not current(window) or user.GetAncestor(active, 2) != window.hwnd:
            raise ValueError("Et andet vindue har fokus. Handlingen er stoppet.")

    foreground()
    kind = action["type"]
    if kind in {"click", "doubleClick", "scroll"}:
        rect = wt.RECT()
        if not user.GetWindowRect(hwnd, ctypes.byref(rect)):
            raise OSError("Vinduets placering kunne ikke læses.")
        x, y = action.get("x", 0.5), action.get("y", 0.5)
        if any(isinstance(v, bool) or not isinstance(v, (int, float)) or not math.isfinite(v) or not 0 < v < 1 for v in (x, y)):
            raise ValueError("Trykket ligger uden for vinduet.")
        point = wt.POINT(rect.left + int((rect.right - rect.left) * x),
                         rect.top + int((rect.bottom - rect.top) * y))
        user.WindowFromPoint.restype = wt.HWND
        at = user.WindowFromPoint(point)
        if user.GetAncestor(at, 2) != window.hwnd:
            raise ValueError("Et andet vindue dækker det valgte område.")
        user.SetCursorPos(point.x, point.y)
        foreground()
        if kind == "scroll":
            user.mouse_event(0x0800, 0, 0, int(action["amount"]) * 120, 0)
        else:
            for _ in range(2 if kind == "doubleClick" else 1):
                user.mouse_event(0x0002, 0, 0, 0, 0)
                user.mouse_event(0x0004, 0, 0, 0, 0)
        return {"performed": True}
    if kind == "key":
        keys = {"enter": 13, "tab": 9, "escape": 27, "backspace": 8, "delete": 46,
                "left": 37, "up": 38, "right": 39, "down": 40, "home": 36, "end": 35,
                "ctrl+a": 65, "ctrl+l": 76, "ctrl+s": 83}
        name = action["key"]
        code = keys[name]
        ctrl = name.startswith("ctrl+")
        try:
            if ctrl:
                user.keybd_event(17, 0, 0, 0)
            user.keybd_event(code, 0, 0, 0)
            user.keybd_event(code, 0, 2, 0)
        finally:
            if ctrl:
                user.keybd_event(17, 0, 2, 0)
        return {"performed": True}
    if kind == "type":
        class Keyboard(ctypes.Structure):
            _fields_ = [("vk", wt.WORD), ("scan", wt.WORD), ("flags", wt.DWORD),
                        ("time", wt.DWORD), ("extra", ctypes.c_size_t)]

        class Mouse(ctypes.Structure):
            _fields_ = [("dx", wt.LONG), ("dy", wt.LONG), ("data", wt.DWORD),
                        ("flags", wt.DWORD), ("time", wt.DWORD), ("extra", ctypes.c_size_t)]

        class Payload(ctypes.Union):
            _fields_ = [("keyboard", Keyboard), ("mouse", Mouse)]

        class Input(ctypes.Structure):
            _fields_ = [("type", wt.DWORD), ("payload", Payload)]

        units = action["text"].encode("utf-16le")
        for i in range(0, len(units), 2):
            foreground()
            code = int.from_bytes(units[i:i + 2], "little")
            entries = (Input * 2)(Input(1, Payload(keyboard=Keyboard(0, code, 4, 0, 0))),
                                  Input(1, Payload(keyboard=Keyboard(0, code, 6, 0, 0))))
            if user.SendInput(2, entries, ctypes.sizeof(Input)) != 2:
                raise OSError("Windows afviste indtastningen.")
        return {"performed": True}
    raise ValueError("Ukendt betjening.")


def labels(window):
    """Read visible static labels (never edit fields) from the selected process."""
    if state(window) != "visible":
        return []
    found = []
    deadline = monotonic() + 0.6

    @ctypes.WINFUNCTYPE(wt.BOOL, wt.HWND, wt.LPARAM)
    def collect(child, _):
        if monotonic() > deadline:
            return False
        user = _user()
        handle = wt.HWND(child)
        kind = ctypes.create_unicode_buffer(32)
        pid = wt.DWORD()
        user.GetWindowThreadProcessId(handle, ctypes.byref(pid))
        user.GetClassNameW(handle, kind, len(kind))
        if pid.value == window.pid and kind.value == "Static" and user.IsWindowVisible(handle):
            label = ctypes.create_unicode_buffer(240)
            result = ctypes.c_size_t()
            ok = user.SendMessageTimeoutW(handle, 13, len(label), ctypes.byref(label), 2, 60, ctypes.byref(result))
            if ok and result.value and label.value.strip():
                found.append(" ".join(label.value.split()))
        return len(found) < 5

    _user().EnumChildWindows(wt.HWND(window.hwnd), collect, 0)
    return found if current(window) else []


def capture(window):
    """PrintWindow may block in another process. Give it a disposable, bounded worker."""
    pillow = find_spec("PIL")
    if pillow is None or not pillow.origin:
        return None
    # Windows venv launchers create another child. Start the interpreter itself so a
    # timeout terminates the process blocked in PrintWindow, even from a venv.
    python = getattr(sys, "_base_executable", None) or sys.executable
    pillow_root = str(Path(pillow.origin).resolve().parent.parent)
    try:
        result = subprocess.run(
            [python, "-I", os.path.abspath(__file__), pillow_root],
            input=json.dumps(vars(window)).encode(), stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL, timeout=4, check=False,
            creationflags=subprocess.CREATE_NO_WINDOW,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    if result.returncode == 0 and result.stdout.startswith(b"\xff\xd8") and len(result.stdout) <= 600_000:
        return result.stdout
    return None


def _render(window):
    from PIL import Image

    if state(window) != "visible":
        return None
    hwnd = wt.HWND(window.hwnd)
    rect = wt.RECT()
    if not _user().GetWindowRect(hwnd, ctypes.byref(rect)):
        return None
    width, height = rect.right - rect.left, rect.bottom - rect.top
    if min(width, height) < 8 or width * height > 18_000_000:
        return None

    # BITMAPINFOHEADER for a 32-bit top-down BI_RGB DIB. Windows paints only this HWND.
    import struct
    header = ctypes.create_string_buffer(struct.pack("<IiiHHIIiiII", 40, width, -height, 1, 32, 0, 0, 0, 0, 0, 0))
    gdi = ctypes.windll.gdi32
    gdi.CreateCompatibleDC.restype = wt.HDC
    gdi.CreateDIBSection.restype = wt.HBITMAP
    gdi.SelectObject.restype = wt.HANDLE
    dc = wt.HDC(gdi.CreateCompatibleDC(None))
    if not dc.value:
        return None
    bits = ctypes.c_void_p()
    bmp = wt.HBITMAP(gdi.CreateDIBSection(dc, header, 0, ctypes.byref(bits), None, 0))
    previous = None
    try:
        if not bmp.value or not bits.value:
            return None
        previous = gdi.SelectObject(dc, bmp)
        if not previous or not current(window) or not _user().PrintWindow(hwnd, dc, 2) or not current(window):
            return None
        image = Image.frombytes("RGB", (width, height), ctypes.string_at(bits, width * height * 4), "raw", "BGRX")
        image.thumbnail((1280, 960))
        if all(low == high for low, high in image.getextrema()):
            return None
        stream = io.BytesIO()
        image.save(stream, format="JPEG", quality=75)
        return stream.getvalue()
    finally:
        if previous:
            gdi.SelectObject(dc, wt.HANDLE(previous))
        if bmp.value:
            gdi.DeleteObject(bmp)
        gdi.DeleteDC(dc)


if __name__ == "__main__":
    sys.path.insert(0, sys.argv[1])
    data = _render(Window(**json.loads(sys.stdin.buffer.read(4096))))
    if data:
        sys.stdout.buffer.write(data)

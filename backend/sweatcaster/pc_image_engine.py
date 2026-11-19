"""Fixed loopback ComfyUI checks and non-destructive, idle-only recovery."""

from __future__ import annotations

import json
import os
from pathlib import Path
import socket
import subprocess
import time

import requests

from sweatcaster.dto import ApiError

ORIGIN = "http://127.0.0.1:8188"
MAX_JSON = 1_000_000


class EngineUnavailable(Exception):
    pass


class ComfyControl:
    def __init__(self, root=None, session=None, spawn=None, sleep=time.sleep):
        self.root = Path(root or os.environ.get("FADEDAI_COMFY_ROOT", "F:/FadedAI/ComfyUI"))
        self.session = session or requests.Session()
        self.session.trust_env = False
        self.spawn = spawn or subprocess.Popen
        self.sleep = sleep

    def json(self, method, path, body=None, *, limit=MAX_JSON, params=None):
        try:
            with self.session.request(method, ORIGIN + path, json=body, params=params, timeout=(2, 5),
                                      allow_redirects=False, stream=True) as response:
                if response.status_code != 200:
                    raise EngineUnavailable("Billedmotoren svarede ikke som forventet.")
                data = bytearray()
                for chunk in response.iter_content(65_536):
                    data.extend(chunk)
                    if len(data) > limit:
                        raise EngineUnavailable("Billedmotorens svar var for stort.")
                if not data and method == "POST" and path in ("/free", "/history"):
                    return {}
                value = json.loads(data)
                if not isinstance(value, dict):
                    raise ValueError("object required")
                return value
        except (requests.RequestException, ValueError, TypeError, RecursionError) as exc:
            raise EngineUnavailable("Billedmotoren svarer ikke på PC’en.") from exc

    def stats(self):
        data = self.json("GET", "/system_stats", limit=65_536)
        system = data.get("system")
        if not isinstance(system, dict) or not isinstance(system.get("comfyui_version"), str) or not system["comfyui_version"]:
            raise EngineUnavailable("Porten svarer, men blev ikke genkendt som ComfyUI.")
        return data

    def queue(self):
        data = self.json("GET", "/queue", limit=500_000)
        for key in ("queue_running", "queue_pending"):
            if not isinstance(data.get(key), list):
                raise EngineUnavailable("PC’en kunne ikke bekræfte billedkøen.")
        return sum(len(data[key]) for key in ("queue_running", "queue_pending"))

    def idle(self):
        self.stats()
        if self.queue():
            raise ApiError(409, "NOT_READY", "Billedmotoren arbejder allerede. Vent på den opgave, der kører.")

    def installed(self):
        data = self.json("GET", "/object_info/CheckpointLoaderSimple", limit=200_000)
        try:
            choices = data["CheckpointLoaderSimple"]["input"]["required"]["ckpt_name"][0]
            if not isinstance(choices, list) or any(not isinstance(name, str) for name in choices):
                raise ValueError
            return choices
        except (KeyError, IndexError, TypeError, ValueError) as exc:
            raise EngineUnavailable("Billedmodellisten kunne ikke læses.") from exc

    def installation(self):
        root = self.root.absolute()
        try:
            if not root.is_absolute() or root.resolve(strict=True) != root:
                return None
            python, main = root / ".venv/Scripts/python.exe", root / "main.py"
            if not all(path.is_file() and not path.is_symlink() and path.resolve() == path for path in (python, main)):
                return None
            return python, main
        except OSError:
            return None

    def port_open(self):
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as probe:
            probe.settimeout(1)
            return probe.connect_ex(("127.0.0.1", 8188)) == 0

    def start(self):
        if self.port_open():
            raise ApiError(409, "NOT_READY", "Porten er allerede i brug. Jeg stopper ikke en ukendt eller optaget proces.")
        paths = self.installation()
        if paths is None:
            raise ApiError(503, "NOT_READY", "Den kendte ComfyUI-installation mangler. Der er ikke installeret eller ændret noget.")
        python, main = paths
        args = [str(python), "-B", str(main), "--listen", "127.0.0.1", "--port", "8188",
                "--reserve-vram", "1.0", "--disable-all-custom-nodes", "--disable-api-nodes"]
        with (self.root / "fadedai-image-engine.log").open("ab") as log:
            process = self.spawn(args, cwd=self.root, stdin=subprocess.DEVNULL, stdout=log,
                                 stderr=subprocess.STDOUT, creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
        for _ in range(12):
            try:
                self.stats()
                return "Den kendte billedmotor blev startet og svarede på en ny kontrol."
            except EngineUnavailable:
                if process.poll() is not None:
                    break
                self.sleep(2)
        raise ApiError(503, "NOT_READY", "Motoren blev startet, men kunne ikke bekræftes klar endnu. Tjek igen om lidt.")

    def release_memory(self):
        self.idle()
        self.json("POST", "/free", {"unload_models": True, "free_memory": True}, limit=4096)
        self.sleep(1)
        self.stats()
        return "ComfyUI fik besked på at frigive sine ubrugte modeller og svarede på en ny kontrol."

    def log_issue(self):
        try:
            file = self.root / "fadedai-image-engine.log"
            if file.is_symlink() or time.time() - file.stat().st_mtime > 600:
                return None
            with file.open("rb") as stream:
                stream.seek(max(0, file.stat().st_size - 16_384))
                tail = stream.read(16_384).lower()
            if b"out of memory" in tail:
                return "outOfMemory"
            if b"cuda error:" in tail or b"torch.acceleratorerror" in tail:
                return "gpuError"
        except OSError:
            pass
        return None


def model_busy(settings):
    """Read existing coordinator without creating/recovering its shared database."""
    import sqlite3
    file = Path(settings.output_root) / "state.sqlite3"
    if not file.exists():
        return False
    try:
        with sqlite3.connect(file.resolve().as_uri() + "?mode=ro", uri=True, timeout=1) as db:
            row = db.execute("SELECT active_lease,pending_lease FROM model_gate WHERE id=1").fetchone()
        return bool(row and (row[0] or row[1]))
    except sqlite3.Error:
        return True


def diagnosis(control):
    checks, actions = [], []
    try:
        stats = control.stats()
        checks.append({"id": "engine", "title": "Billedmotor", "state": "ready", "detail": "ComfyUI svarer på PC’en."})
    except EngineUnavailable:
        stats = None
        occupied = control.port_open()
        checks.append({"id": "engine", "title": "Billedmotor", "state": "unavailable",
                       "detail": "Porten er optaget, men motoren svarer ikke korrekt." if occupied else "Billedmotoren er ikke startet."})
        if not occupied and control.installation() is not None:
            actions.append({"id": "start", "title": "Start billedmotoren", "detail": "Starter kun din eksisterende ComfyUI-installation."})
    try:
        queued = control.queue()
        checks.append({"id": "queue", "title": "Opgaver", "state": "busy" if queued else "ready",
                       "detail": f"{queued} opgaver er i gang eller venter." if queued else "Billedkøen er tom."})
    except EngineUnavailable:
        queued = None
    try:
        models = control.installed()
        checks.append({"id": "models", "title": "Billedmodeller", "state": "ready" if models else "missing",
                       "detail": f"{len(models)} installerede checkpoint-modeller." if models else "Ingen checkpoint-model blev fundet."})
    except EngineUnavailable:
        pass
    issue = control.log_issue()
    devices = stats.get("devices", []) if stats else []
    for device in devices[:1] if isinstance(devices, list) else []:
        if not isinstance(device, dict):
            continue
        free, total = device.get("vram_free"), device.get("vram_total")
        if type(free) in (int, float) and type(total) in (int, float) and 0 <= free <= total:
            checks.append({"id": "memory", "title": "Grafikhukommelse", "state": "low" if free < 1_073_741_824 else "ready",
                           "detail": f"{free / 1_073_741_824:.1f} GB ledig af {total / 1_073_741_824:.1f} GB."})
    if issue:
        checks.append({"id": "recentError", "title": "Seneste motorfejl", "state": "warning",
                       "detail": "Loggen viser en nylig hukommelsesfejl." if issue == "outOfMemory" else "Loggen viser en nylig GPU-fejl."})
    if stats is not None and queued == 0:
        actions.append({"id": "releaseMemory", "title": "Frigiv billedmotorens hukommelse",
                        "detail": "Fjerner kun ubrugte modeller fra ComfyUI. Dine filer bliver bevaret."})
    state = "busy" if queued else "ready" if stats else "unavailable"
    return {"state": state, "summary": "Jeg har kontrolleret motor, modeller, kø og tilgængelig hukommelse.",
            "checks": checks, "actions": actions}

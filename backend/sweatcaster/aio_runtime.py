"""Manage local AIO desktops without publishing a Docker or AIO endpoint."""

from __future__ import annotations

import base64
import json
import os
import re
import struct
import subprocess
from threading import Lock, RLock
from urllib.parse import urlencode
from uuid import UUID

AIO_IMAGE = "enterprise-public-cn-beijing.cr.volces.com/vefaas-public/aio-computer:1.0.1"
MANAGED_LABEL = "com.fadedai.aio"
BOT_LABEL = "com.fadedai.bot-id"
SANDBOX_HOME = "/home/sandbox"
WORKSPACE = SANDBOX_HOME + "/workspace"
MAX_ACTIVE = 2
MAX_SCREEN_BYTES = 8 * 1024 * 1024
MAX_ARTIFACT_BYTES = 512 * 1024
MAX_ARTIFACT_RESPONSE_BYTES = 6 * MAX_ARTIFACT_BYTES + 8192
MAX_DESKTOP_DIMENSION = 16_384
MAX_JSON_BYTES = 256 * 1024
SAFE_FILENAME = re.compile(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,95}")
SUPPORTED_KEYS = frozenset({
    "enter", "tab", "escape", "backspace", "delete", "space", "up", "down", "left", "right",
    "home", "end", "pageup", "pagedown",
})


class AIORuntimeError(Exception):
    def __init__(self, status: int, message: str):
        super().__init__(message)
        self.status = status
        self.message = message


def _identity(bot_id: str) -> str:
    try:
        if not isinstance(bot_id, str) or len(bot_id) != 36:
            raise ValueError
        value = UUID(bot_id)
        if str(value) != bot_id.lower():
            raise ValueError
        return str(value)
    except ValueError as exc:
        raise AIORuntimeError(422, "Botten har et ugyldigt id.") from exc


def _container(bot: str) -> str:
    return "fadedai-aio-" + bot


def _volume(bot: str) -> str:
    return _container(bot) + "-home"


def _json(body: bytes) -> dict:
    try:
        value = json.loads(body)
        if isinstance(value, dict):
            return value
    except (ValueError, RecursionError):
        pass
    raise AIORuntimeError(502, "Botcomputeren sendte et svar, som FadedAI ikke kunne læse.")


def _output(value: dict) -> dict:
    data = value.get("data", value)
    if not isinstance(data, dict):
        raise AIORuntimeError(502, "Botcomputeren sendte et ufuldstændigt svar.")
    return data


def _coordinate(value: int) -> bool:
    return type(value) is int and 0 <= value < MAX_DESKTOP_DIMENSION


def _artifact_path(name: str) -> str:
    if not isinstance(name, str) or SAFE_FILENAME.fullmatch(name) is None:
        raise AIORuntimeError(422, "Filen skal have et gyldigt navn.")
    return WORKSPACE + "/" + name


class AIORuntime:
    """One Linux desktop and one persistent home per FadedAI bot UUID."""

    def __init__(self, *, runner=None):
        self._runner = subprocess.run if runner is None else runner
        self._docker = (["docker", "--context", "desktop-linux"] if os.name == "nt"
                        else ["docker", "--host", "unix:///var/run/docker.sock"])
        self._capacity = Lock()
        self._bots = tuple(RLock() for _ in range(32))

    def _lock(self, bot: str):
        return self._bots[UUID(bot).int % len(self._bots)]

    def _call(self, args: list[str], *, data: bytes = b"", timeout: int = 8):
        try:
            return self._runner(
                self._docker + args, input=data, capture_output=True, timeout=timeout, check=False,
                creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
            )
        except FileNotFoundError as exc:
            raise AIORuntimeError(503, "Docker Desktop skal installeres og åbnes på PC’en.") from exc
        except subprocess.TimeoutExpired as exc:
            raise AIORuntimeError(503, "Docker eller botcomputeren svarer ikke lige nu.") from exc
        except OSError as exc:
            raise AIORuntimeError(503, "FadedAI kunne ikke forbinde til Docker på PC’en.") from exc

    @staticmethod
    def _record(result) -> dict:
        if result.returncode or len(result.stdout) > MAX_JSON_BYTES:
            raise AIORuntimeError(503, "FadedAI kunne ikke læse Docker-status på PC’en.")
        try:
            value = json.loads(result.stdout)
            if isinstance(value, list) and len(value) == 1 and isinstance(value[0], dict):
                return value[0]
        except (ValueError, RecursionError):
            pass
        raise AIORuntimeError(503, "FadedAI kunne ikke læse Docker-status på PC’en.")

    def _inspect(self, bot: str) -> dict | None:
        result = self._call(["container", "inspect", _container(bot)])
        if result.returncode and any(text in result.stderr.lower() for text in (
                b"no such container", b"no such object")):
            return None
        container = self._record(result)
        configuration = container.get("Config", {})
        labels = configuration.get("Labels") or {}
        host = container.get("HostConfig", {})
        mounts = container.get("Mounts", [])
        network = container.get("NetworkSettings", {})
        ports = network.get("Ports") or {}
        attached_networks = network.get("Networks") or {}
        if (
            labels.get(MANAGED_LABEL) != "1" or labels.get(BOT_LABEL) != bot
            or configuration.get("Image") != AIO_IMAGE
            or host.get("NetworkMode") != "none" or host.get("Privileged") is not False
            or set(attached_networks) - {"none"}
            or host.get("PublishAllPorts") or host.get("PortBindings") or host.get("Binds")
            or any(value is not None for value in ports.values())
            or len(mounts) != 1 or mounts[0].get("Type") != "volume"
            or mounts[0].get("Name") != _volume(bot) or mounts[0].get("Destination") != SANDBOX_HOME
            or mounts[0].get("RW") is not True
        ):
            raise AIORuntimeError(409, "Den eksisterende Docker-container matcher ikke bottens miljø.")
        return container.get("State", {})

    def _ensure_volume(self, bot: str) -> None:
        name = _volume(bot)
        result = self._call(["volume", "create", "--driver", "local",
                             "--label", f"{MANAGED_LABEL}=1", "--label", f"{BOT_LABEL}={bot}", name])
        if result.returncode:
            raise AIORuntimeError(503, "Docker kunne ikke oprette bottens filplads.")
        volume = self._record(self._call(["volume", "inspect", name]))
        labels = volume.get("Labels") or {}
        if (volume.get("Name") != name or volume.get("Driver") != "local" or volume.get("Options")
                or labels.get(MANAGED_LABEL) != "1" or labels.get(BOT_LABEL) != bot):
            raise AIORuntimeError(409, "Den eksisterende filplads matcher ikke bottens miljø.")

    def _image_available(self) -> bool:
        result = self._call(["image", "inspect", "--format", "{{.Id}}", AIO_IMAGE])
        if result.returncode:
            if any(text in result.stderr.lower() for text in (b"no such image", b"no such object")):
                return False
            raise AIORuntimeError(503, "FadedAI kunne ikke læse Docker-status på PC’en.")
        return True

    def _check_capacity(self) -> None:
        result = self._call(["container", "ls", "--filter", f"label={MANAGED_LABEL}=1",
                             "--format", "{{.ID}}"])
        if result.returncode:
            raise AIORuntimeError(503, "FadedAI kunne ikke læse Docker-status på PC’en.")
        if len(result.stdout.splitlines()) >= MAX_ACTIVE:
            raise AIORuntimeError(409, "To botcomputere er allerede aktive. Stop en af dem først.")

    def status(self, bot_id: str) -> dict:
        bot = _identity(bot_id)
        with self._lock(bot):
            try:
                state = self._inspect(bot)
                if state is None and not self._image_available():
                    return {"state": "unavailable", "detail": "AIO Sandbox skal hentes under PC-opsætning."}
                return self._desktop_status(bot, state)
            except AIORuntimeError as exc:
                return {"state": "unavailable", "detail": exc.message}

    def _desktop_status(self, bot: str, state: dict | None) -> dict:
        if not state or state.get("Running") is not True:
            return {"state": "stopped", "detail": None}
        if state.get("Paused"):
            return {"state": "unavailable", "detail": "Docker har sat botcomputeren på pause."}
        try:
            desktop = _output(_json(self._http(bot, "/v2/computer/info")))
            if desktop.get("available") is True:
                return {"state": "running", "detail": None}
        except AIORuntimeError:
            pass
        return {"state": "starting", "detail": "AIO-skrivebordet gør sig klar."}

    def start(self, bot_id: str) -> dict:
        bot = _identity(bot_id)
        with self._lock(bot):
            state = self._inspect(bot)
            if state and state.get("Running") is True:
                return self._desktop_status(bot, state)
            with self._capacity:
                self._check_capacity()
                if state is None:
                    if not self._image_available():
                        raise AIORuntimeError(503, "AIO Sandbox skal hentes under PC-opsætning.")
                    self._ensure_volume(bot)
                    result = self._call([
                        "container", "run", "--detach", "--pull=never", "--name", _container(bot),
                        "--label", f"{MANAGED_LABEL}=1", "--label", f"{BOT_LABEL}={bot}",
                        "--network", "none", "--security-opt", "no-new-privileges",
                        "--cpus", "2", "--memory", "4g", "--memory-swap", "4g",
                        "--pids-limit", "512", "--shm-size", "4g", "--init",
                        "--mount", f"type=volume,source={_volume(bot)},target={SANDBOX_HOME}",
                        "--env", "BROWSER_START_MODE=manual", "--env", "DISABLE_CODE_SERVER=true",
                        "--env", "DISABLE_JUPYTER=true", AIO_IMAGE,
                    ], timeout=20)
                else:
                    self._ensure_volume(bot)
                    result = self._call(["container", "start", _container(bot)], timeout=20)
                if result.returncode:
                    raise AIORuntimeError(503, "Docker kunne ikke starte bottens AIO-computer.")
            return self._desktop_status(bot, self._inspect(bot))

    def stop(self, bot_id: str) -> dict:
        bot = _identity(bot_id)
        with self._lock(bot):
            state = self._inspect(bot)
            if state and state.get("Running") is True:
                result = self._call(["container", "stop", "--time", "5", _container(bot)], timeout=12)
                if result.returncode:
                    raise AIORuntimeError(503, "Docker kunne ikke stoppe botcomputeren.")
            return {"state": "stopped", "detail": None}

    def _http(self, bot: str, path: str, body: dict | None = None, *, limit: int = MAX_JSON_BYTES) -> bytes:
        command = ["container", "exec"]
        if body is not None:
            command.append("--interactive")
        command.extend([
            _container(bot), "/usr/bin/curl", "--disable", "--fail", "--silent", "--show-error",
            "--max-time", "5", "--connect-timeout", "2", "--max-filesize", str(limit),
            "--noproxy", "*", "--proto", "=http",
        ])
        data = b""
        if body is not None:
            command.extend(["--request", "POST", "--header", "Content-Type: application/json", "--data-binary", "@-"])
            data = json.dumps(body, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        command.extend(["--url", "http://127.0.0.1:8091" + path])
        result = self._call(command, data=data)
        if result.returncode in {7, 28, 125, 126, 127}:
            raise AIORuntimeError(503, "Start botcomputeren, og vent på at skrivebordet er klar.")
        if result.returncode or not result.stdout or len(result.stdout) > limit:
            raise AIORuntimeError(502, "AIO-skrivebordet kunne ikke gennemføre handlingen.")
        return result.stdout

    def _use(self, bot_id: str, path: str, body: dict | None = None, *, limit: int = MAX_JSON_BYTES) -> bytes:
        bot = _identity(bot_id)
        with self._lock(bot):
            state = self._inspect(bot)
            if not state or state.get("Running") is not True or state.get("Paused"):
                raise AIORuntimeError(409, "Start botcomputeren først.")
            return self._http(bot, path, body, limit=limit)

    def screenshot(self, bot_id: str) -> bytes:
        frame = self._use(bot_id, "/v2/computer/screenshot", limit=MAX_SCREEN_BYTES)
        if len(frame) < 33 or frame[:16] != b"\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR":
            raise AIORuntimeError(502, "AIO-skrivebordet sendte ikke et billede.")
        width, height = struct.unpack_from(">II", frame, 16)
        if (not 1 <= width <= MAX_DESKTOP_DIMENSION or not 1 <= height <= MAX_DESKTOP_DIMENSION
                or width * height > 16_777_216):
            raise AIORuntimeError(502, "AIO-skrivebordets billede er for stort.")
        return frame

    def _action(self, bot_id: str, body: dict, *, batch: bool = False) -> None:
        path = "/v2/computer/actions/batch" if batch else "/v2/computer/actions"
        payload = _json(self._use(bot_id, path, body))
        result = _output(payload)
        if (payload.get("success") is False or result.get("success") is False
                or result.get("status") in ("denied", "failed", "error")
                or result.get("failed_index") is not None):
            raise AIORuntimeError(409, "AIO-skrivebordet afviste inputtet.")

    def click(self, bot_id: str, x: int, y: int) -> None:
        if not _coordinate(x) or not _coordinate(y):
            raise AIORuntimeError(422, "Trykket ligger uden for skrivebordet.")
        self._action(bot_id, {"action_type": "CLICK", "x": x, "y": y})

    def type_text(self, bot_id: str, text: str) -> None:
        if (not isinstance(text, str) or not 1 <= len(text) <= 500
                or any(ord(char) < 32 and char not in "\t\n" or 0xD800 <= ord(char) <= 0xDFFF for char in text)):
            raise AIORuntimeError(422, "Skriv mellem 1 og 500 tegn til skrivebordet.")
        self._action(bot_id, {"action_type": "TYPING", "text": text})

    def key(self, bot_id: str, key: str) -> None:
        if not isinstance(key, str) or key.lower() not in SUPPORTED_KEYS:
            raise AIORuntimeError(422, "Den tast understøttes ikke i botcomputeren.")
        self._action(bot_id, {"action_type": "PRESS", "key": key.lower()})

    def scroll(self, bot_id: str, x: int, y: int, dx: int, dy: int) -> None:
        if (not _coordinate(x) or not _coordinate(y) or type(dx) is not int or type(dy) is not int
                or abs(dx) > 20 or abs(dy) > 20 or not (dx or dy)):
            raise AIORuntimeError(422, "Rulningen ligger uden for skrivebordet.")
        self._action(bot_id, {"actions": [
            {"action_type": "MOVE_TO", "x": x, "y": y},
            {"action_type": "SCROLL", "dx": dx, "dy": dy},
        ]}, batch=True)

    def save_artifact(self, bot_id: str, name: str, data: bytes) -> None:
        path = _artifact_path(name)
        if not isinstance(data, bytes) or not 1 <= len(data) <= MAX_ARTIFACT_BYTES:
            raise AIORuntimeError(422, "Filen skal være mellem 1 byte og 512 KB.")
        try:
            data.decode("utf-8")
        except UnicodeDecodeError as exc:
            raise AIORuntimeError(422, "Filen skal være en UTF-8-tekstfil.") from exc
        payload = _json(self._use(bot_id, "/v2/fs/write", {
            "path": path, "content": base64.b64encode(data).decode("ascii"),
            "encoding": "base64", "user": "sandbox",
        }))
        if _output(payload).get("bytes_written") != len(data):
            raise AIORuntimeError(502, "AIO kunne ikke bekræfte, at hele filen blev gemt.")

    def read_artifact(self, bot_id: str, name: str) -> bytes:
        query = urlencode({"path": _artifact_path(name)})
        payload = _json(self._use(bot_id, "/v2/fs/read?" + query, limit=MAX_ARTIFACT_RESPONSE_BYTES))
        content = _output(payload).get("content")
        if isinstance(content, str):
            try:
                data = content.encode("utf-8")
                if len(data) <= MAX_ARTIFACT_BYTES:
                    return data
            except UnicodeEncodeError:
                pass
        raise AIORuntimeError(502, "AIO sendte ikke en gyldig tekstfil på højst 512 KB.")

    def open_artifact(self, bot_id: str, name: str) -> None:
        path = _artifact_path(name)
        bot = _identity(bot_id)
        if not name.lower().endswith((".txt", ".md", ".csv", ".json", ".log")):
            raise AIORuntimeError(422, "Skrivebordet kan åbne almindelige tekstfiler.")
        with self._lock(bot):
            self.read_artifact(bot, name)
            result = self._call([
                "container", "exec", "--detach", "--user", "sandbox",
                "--env", "DISPLAY=:99.0", "--env", "XAUTHORITY=/home/sandbox/.Xauthority",
                "--env", "HOME=/home/sandbox", _container(bot), "mousepad", "--", path,
            ])
            if result.returncode:
                raise AIORuntimeError(503, "AIO kunne ikke åbne tekstviseren på skrivebordet.")

"""Short Windows measurements for a paired PC dashboard."""

import ctypes
import csv
import http.client
import json
import os
import re
import shutil
import subprocess
import time
from ctypes import wintypes
from pathlib import Path

from sweatcaster.aio_runtime import AIORuntimeError
from sweatcaster.dto import ApiError


def windows_load():
    if os.name != "nt":
        return None, None, None

    class Memory(ctypes.Structure):
        _fields_ = [("length", wintypes.DWORD), ("load", wintypes.DWORD)] + [
            (key, ctypes.c_ulonglong) for key in
            ("total", "available", "page_total", "page_available", "virtual_total", "virtual_available", "extended")
        ]

    kernel = ctypes.windll.kernel32

    def ticks():
        idle, system, user = (wintypes.FILETIME() for _ in range(3))
        if not kernel.GetSystemTimes(ctypes.byref(idle), ctypes.byref(system), ctypes.byref(user)):
            return None
        def number(value):
            return (value.dwHighDateTime << 32) | value.dwLowDateTime
        return number(idle), number(system) + number(user)

    first = ticks()
    time.sleep(0.2)
    last = ticks()
    cpu = None
    if first and last and last[1] > first[1]:
        cpu = min(100, max(0, round(100 * (1 - (last[0] - first[0]) / (last[1] - first[1])))))
    memory = Memory()
    memory.length = ctypes.sizeof(memory)
    if kernel.GlobalMemoryStatusEx(ctypes.byref(memory)):
        return cpu, memory.total - memory.available, memory.total
    return cpu, None, None


def nvidia():
    executable = shutil.which("nvidia-smi")
    if not executable:
        return []
    try:
        result = subprocess.run(
            [executable, "--query-gpu=index,name,utilization.gpu,memory.used,memory.total,temperature.gpu",
             "--format=csv,noheader,nounits"],
            capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=3, check=True,
            creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
        )
        return nvidia_cards(result.stdout)
    except (OSError, subprocess.SubprocessError):
        return []


def nvidia_cards(output):
    def number(raw, low, high):
        try:
            value = int(raw)
        except ValueError:
            return None
        return value if low <= value <= high else None

    cards = {}
    for fields in csv.reader(output.splitlines(), skipinitialspace=True):
        if len(fields) != 6:
            continue
        index, name, use, used, total, degrees = (field.strip() for field in fields)
        if index.isascii() and index.isdigit() and name:
            cards[index] = {"id": index, "name": name, "percent": number(use, 0, 100),
                            "usedMiB": number(used, 0, 2**31 - 1), "totalMiB": number(total, 1, 2**31 - 1),
                            "temperatureC": number(degrees, -30, 150)}
    return list(cards.values())


def cpu_package_temperature(sensors):
    if isinstance(sensors, dict):
        sensors = [sensors]
    if not isinstance(sensors, list):
        return None
    readings = []
    for sensor in sensors:
        if not isinstance(sensor, dict):
            continue
        parent, value = sensor.get("Parent"), sensor.get("Value")
        if (isinstance(parent, str) and parent.startswith(("/intelcpu/", "/amdcpu/"))
                and sensor.get("Name") in ("CPU Package", "Core (Tdie)", "Core (Tctl/Tdie)", "CPU (Tctl/Tdie)")
                and type(value) in (int, float) and -30 <= value <= 150):
            readings.append(value)
    return round(max(readings)) if readings else None


def windows_cpu_temperature():
    if os.name != "nt":
        return None
    powershell = Path(os.environ.get("SystemRoot", r"C:\Windows")) / "System32/WindowsPowerShell/v1.0/powershell.exe"
    # The hardware provider publishes CPU package data, unlike ACPI thermal-zone readings.
    command = (
        "Get-CimInstance -Namespace 'root/LibreHardwareMonitor' -ClassName Sensor "
        "-Filter \"SensorType = 'Temperature' AND (Parent LIKE '/intelcpu/%' OR Parent LIKE '/amdcpu/%')\" "
        "-OperationTimeoutSec 2 -ErrorAction Stop | Select-Object Parent,Name,Value | ConvertTo-Json -Compress"
    )
    try:
        result = subprocess.run([str(powershell), "-NoProfile", "-NonInteractive", "-Command", command],
                                capture_output=True, text=True, timeout=3, check=True,
                                creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
        return cpu_package_temperature(json.loads(result.stdout))
    except (OSError, ValueError, subprocess.SubprocessError):
        return None


def read_metrics(directory):
    disk = shutil.disk_usage(directory)
    cpu, used, total = windows_load()
    return {"cpuPercent": cpu, "memoryUsed": used, "memoryTotal": total,
            "diskFree": disk.free, "diskTotal": disk.total, "gpus": nvidia(),
            "cpuTemperatureC": windows_cpu_temperature()}


def desktop_setup(runtime):
    try:
        return "ready" if runtime.image_available() else "missingImage"
    except AIORuntimeError:
        return "offline"


def _image_engine_log_status():
    log = Path(os.environ.get("FADEDAI_COMFY_ENGINE_LOG", "F:/FadedAI/ComfyUI/fadedai-image-engine.log"))
    try:
        if not log.is_absolute() or not log.is_file():
            return None
        with log.open("rb") as source:
            info = os.fstat(source.fileno())
            if time.time() - info.st_mtime > 120:
                return None
            source.seek(max(0, info.st_size - 16_384))
            tail = source.read(16_384).lower()
    except OSError:
        return None

    # These are explicit errors from ComfyUI or PyTorch. A failed HTTP
    # request alone is not enough to diagnose the graphics card.
    if any(marker in tail for marker in (
        b"cuda error:", b"cuda out of memory", b"cuda_error_unknown", b"torch.acceleratorerror",
    )):
        return "gpuError"
    if b"starting server" not in tail and any(marker in tail for marker in (
        b"setup plugin alembic.", b"checkpoint files will always be loaded safely",
        b"using pytorch attention",
    )):
        return "starting"
    return None


def image_engine_status():
    # Unlike the model catalog, ComfyUI's system_stats checks the active
    # device. The catalog can still respond after CUDA has failed.
    connection = http.client.HTTPConnection("127.0.0.1", 8188, timeout=3)
    failed = "offline"
    try:
        connection.request("GET", "/system_stats")
        with connection.getresponse() as response:
            failed = "unresponsive"
            if response.status == 200:
                data = response.read(65_537)
                if len(data) <= 65_536:
                    version = json.loads(data)["system"]["comfyui_version"]
                    if isinstance(version, str) and version:
                        return "ready"
    except (TimeoutError, http.client.HTTPException):
        failed = "unresponsive"
    except (OSError, ValueError, KeyError, TypeError, RecursionError):
        pass
    finally:
        connection.close()

    logged = _image_engine_log_status()
    if logged == "gpuError" or (logged == "starting" and failed == "offline"):
        return logged
    return failed


def image_setup(supported):
    from sweatcaster.lumi_companion import IMAGE_MODEL

    try:
        from sweatcaster.comfy import CHECKPOINT
    except ImportError:
        CHECKPOINT = None
    connection = http.client.HTTPConnection("127.0.0.1", 8188, timeout=3)
    states = {"image": "offline" if supported and CHECKPOINT else "unsupported", "lumiImage": "offline"}
    try:
        connection.request("GET", "/object_info/CheckpointLoaderSimple")
        with connection.getresponse() as response:
            if response.status != 200:
                return states
            data = response.read(65_537)
            if len(data) > 65_536:
                return states
        choices = json.loads(data)["CheckpointLoaderSimple"]["input"]["required"]["ckpt_name"][0]
        if not isinstance(choices, list):
            return states
        return {"image": ("ready" if CHECKPOINT in choices else "missingModel") if supported and CHECKPOINT else "unsupported",
                "lumiImage": "ready" if IMAGE_MODEL in choices else "missingModel"}
    except (OSError, http.client.HTTPException, ValueError, KeyError, TypeError, IndexError, RecursionError):
        return states
    finally:
        connection.close()


def web_setup():
    connection = http.client.HTTPConnection("127.0.0.1", 8080, timeout=3)
    try:
        connection.request("GET", "/healthz")
        with connection.getresponse() as response:
            return "responding" if response.status == 200 and response.read(16).strip() == b"OK" else "offline"
    except (OSError, http.client.HTTPException):
        return "offline"
    finally:
        connection.close()


def gmail_setup(library, appointments):
    try:
        if not library.key():
            return "missingProject"
        account = library.connection("gmail")
        if not account:
            return "signIn"
        selected = appointments.settings()
        return "ready" if selected and selected[3] == account else "enableAgent"
    except ApiError:
        return "unknown"


def wake_local_search(root):
    if web_setup() == "responding":
        return True
    docker = shutil.which("docker")
    if not docker:
        return False

    def run(*args):
        return subprocess.run(
            [docker, "--context", "desktop-linux", *args], check=True, capture_output=True,
            text=True, timeout=8, creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
        ).stdout.strip()

    try:
        matches = run("ps", "-a", "--filter", "label=com.docker.compose.service=searxng",
                      "--filter", f"label=com.docker.compose.project.working_dir={root}",
                      "--format", "{{.ID}}").splitlines()
        if len(matches) != 1 or not re.fullmatch(r"[a-f0-9]{12,64}", matches[0]):
            return False
        container = matches[0]
        ports = json.loads(run("inspect", "--format", "{{json .HostConfig.PortBindings}}", container))
        if ports != {"8080/tcp": [{"HostIp": "127.0.0.1", "HostPort": "8080"}]}:
            return False
        run("start", container)
        for _ in range(4):
            if web_setup() == "responding":
                return True
            time.sleep(1)
    except (OSError, subprocess.SubprocessError, ValueError):
        return False
    return False


def show_startup_status(root):
    from sweatcaster.aio_runtime import AIORuntime

    if wake_local_search(root):
        print("Websøgning · Klar", flush=True)
    else:
        print("Websøgning · Tjek SearXNG i Docker, hvis du vil søge på nettet.", flush=True)
    if desktop_setup(AIORuntime()) != "ready":
        print("Agentcomputere · Tjek Docker Desktop og AIO Sandbox i FadedAI-opsætningen.", flush=True)
    if image_setup(True)["image"] != "ready":
        print("Billeder · Tjek ComfyUI og billedmodellen, før du laver billeder på PC’en.", flush=True)

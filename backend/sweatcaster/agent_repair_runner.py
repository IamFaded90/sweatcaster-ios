"""Run a fixed unittest profile in a disposable, offline, unmounted container."""

import ast
from hashlib import sha256
import json
import os
from pathlib import PurePosixPath
import re
import subprocess
from threading import Thread
from uuid import uuid4

IMAGE = "python:3.13-alpine"
PROFILE = "python-stdlib-unittest-v1"
STANDARD = {"math", "decimal", "statistics", "json", "datetime", "collections", "dataclasses", "typing", "functools", "re", "string", "itertools", "fractions"}
BANNED = {"eval", "exec", "compile", "open", "input", "getattr", "setattr", "delattr", "globals", "locals", "vars", "breakpoint", "exit", "quit"}

HARNESS = r'''
import contextlib, io, json, os, pathlib, sys, unittest
packet = json.load(sys.stdin)
root = pathlib.Path('/work/project'); root.mkdir()
for name, source in packet['files'].items():
    path = root / name
    if path.is_absolute() and root not in path.parents: raise ValueError('path')
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(source, encoding='utf-8')
os.chdir(root); sys.path.insert(0, str(root))
class Log(io.StringIO):
    def write(self, text): return super().write(text[:max(0, 12000 - self.tell())])
log = Log()
with contextlib.redirect_stdout(log), contextlib.redirect_stderr(log):
    suite = unittest.defaultTestLoader.loadTestsFromNames(packet['tests'])
    result = unittest.TextTestRunner(stream=log, verbosity=2).run(suite)
print(json.dumps({'testsRun': result.testsRun, 'failures': len(result.failures), 'errors': len(result.errors),
                  'skipped': len(result.skipped), 'log': log.getvalue(), 'passed': result.wasSuccessful()}))
'''


def canonical(value):
    return json.dumps(value, sort_keys=True, ensure_ascii=False, separators=(",", ":")).encode("utf-8")


def validate_files(files, tests):
    if not isinstance(files, dict) or not 2 <= len(files) <= 8 or sum(len(str(value)) for value in files.values()) > 48000:
        raise ValueError("Vælg højst otte små Python-filer med tests.")
    if not isinstance(tests, list) or not 1 <= len(tests) <= 4 or len(set(tests)) != len(tests):
        raise ValueError("Vælg én til fire unittest-filer.")
    modules = {str(PurePosixPath(name).with_suffix("")).replace("/", ".") for name in files}
    roots = {name.split(".")[0] for name in modules}
    for name, source in files.items():
        if (not isinstance(name, str) or not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*(?:/[A-Za-z_][A-Za-z0-9_]*)*[.]py", name)
                or name.split("/")[0].removesuffix(".py") in STANDARD | {"unittest", "os", "sys", "builtins", "site"}
                or not isinstance(source, str) or len(source) > 16000 or "\x00" in source):
            raise ValueError("Testprofilen bruger almindelige små Python-kildefiler.")
        module = str(PurePosixPath(name).with_suffix("")).replace("/", ".")
        tree = ast.parse(source, filename=name)
        allowed = STANDARD | roots | ({"unittest"} if module in tests else set())
        for node in ast.walk(tree):
            if isinstance(node, (ast.Import, ast.ImportFrom)):
                names = [item.name for item in node.names] if isinstance(node, ast.Import) else [node.module or ""]
                if any(value.split(".")[0] not in allowed for value in names) or getattr(node, "level", 0):
                    raise ValueError("Denne testprofil understøtter kun projektets filer og faste standardbiblioteker.")
            if isinstance(node, ast.Name) and (node.id in BANNED or node.id.startswith("__") and node.id != "__name__"):
                raise ValueError("Dynamisk kode, filadgang og systemkommandoer er uden for denne testprofil.")
            if isinstance(node, ast.Attribute) and (node.attr.startswith("__") or node.attr in {"mock", "load_tests", "stopTestRun"}):
                raise ValueError("Testmotorens interne funktioner må ikke ændres af opgaven.")
    if not set(tests) <= modules:
        raise ValueError("Testfilen findes ikke i arbejdskopien.")
    return {"profile": PROFILE, "tests": list(tests), "testDigest": sha256(canonical({name: files[name.replace('.', '/') + '.py'] for name in tests})).hexdigest()}


class IsolatedRunner:
    def __init__(self, *, execute=None, spawn=None, timeout=30):
        self.execute = execute or subprocess.run
        self.spawn = spawn or subprocess.Popen
        self.timeout = min(30, max(1, timeout))
        self.docker = ["docker", "--context", "desktop-linux"] if os.name == "nt" else ["docker", "--host", "unix:///var/run/docker.sock"]

    def image(self):
        try:
            result = self.execute(self.docker + ["image", "inspect", "--format", "{{.Id}}", IMAGE], capture_output=True,
                                  timeout=8, check=False, creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
            value = result.stdout.decode().strip()
            if not result.returncode and re.fullmatch(r"sha256:[a-f0-9]{64}", value):
                return value
        except (OSError, subprocess.SubprocessError, UnicodeError):
            pass
        return None

    def available(self):
        ready = self.image() is not None
        return {"ready": ready, "title": "Isoleret Python-test", "detail": "Lokal Docker · uden netværk eller adgang til dine mapper." if ready
                else "Den lokale Python-testmotor er ikke tilgængelig. Ingen test er påstået kørt."}

    def run(self, files, tests):
        check = validate_files(files, tests)
        image = self.image()
        if image is None:
            raise RuntimeError("Den isolerede testmotor er ikke klar i Docker.")
        name = "fadedai-repair-" + uuid4().hex
        args = self.docker + ["run", "--rm", "--pull=never", "--name", name, "--network", "none", "--read-only",
                             "--cap-drop", "ALL", "--security-opt", "no-new-privileges", "--pids-limit", "32",
                             "--memory", "192m", "--memory-swap", "192m", "--cpus", "1", "--user", "65534:65534",
                             "--tmpfs", "/work:rw,noexec,nosuid,nodev,size=8m,mode=1777", "--workdir", "/work",
                             "--entrypoint", "python3", "-i", image, "-I", "-S", "-B", "-c", HARNESS]
        process, reader = None, None
        output = bytearray()
        overflow = False

        def read():
            nonlocal overflow
            while True:
                chunk = process.stdout.read(4096)
                if not chunk:
                    break
                remaining = 64000 - len(output)
                output.extend(chunk[:max(0, remaining)])
                if len(chunk) > remaining:
                    overflow = True
                    break

        try:
            process = self.spawn(args, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                 creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
            reader = Thread(target=read, daemon=True, name="repair-test-output")
            reader.start()
            process.stdin.write(canonical({"files": files, "tests": tests}))
            process.stdin.close()
            code = process.wait(timeout=self.timeout)
            reader.join(timeout=2)
            if code or overflow or reader.is_alive():
                raise RuntimeError("Den isolerede test blev afbrudt eller gav et ugyldigt resultat.")
            result = json.loads(output)
            if (not isinstance(result, dict) or any(type(result.get(key)) is not int or result[key] < 0 for key in ("testsRun", "failures", "errors", "skipped"))
                    or not isinstance(result.get("log"), str) or type(result.get("passed")) is not bool or result["testsRun"] < 1):
                raise ValueError("invalid test receipt")
            result["passed"] = result["passed"] and result["failures"] == result["errors"] == result["skipped"] == 0
            return result | check | {"sourceDigest": sha256(canonical(files)).hexdigest(), "image": image,
                                      "command": "python -I -S -B · unittest · " + ", ".join(tests)}
        except (OSError, ValueError, subprocess.SubprocessError) as exc:
            raise RuntimeError("Testmotoren kunne ikke afslutte sin isolerede kontrol.") from exc
        finally:
            if process is not None:
                if process.poll() is None or overflow:
                    try:
                        self.execute(self.docker + ["container", "rm", "--force", name], capture_output=True, timeout=8, check=False,
                                     creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
                    except (OSError, subprocess.SubprocessError):
                        pass
                if process.poll() is None:
                    process.kill()
                    process.wait(timeout=3)
                if reader is not None:
                    reader.join(timeout=2)
                process.stdout.close()

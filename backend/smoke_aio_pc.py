"""Exercise two disposable AIO desktops without changing the live FadedAI service."""

from __future__ import annotations

import os
import subprocess
import time
from pathlib import Path
from tempfile import TemporaryDirectory
from uuid import uuid4

from sweatcaster.aio_runtime import AIORuntime, AIORuntimeError, BOT_LABEL, MANAGED_LABEL
from sweatcaster.bot_computers import BotComputerError, BotComputers


def docker(*args):
    context = ["--context", "desktop-linux"] if os.name == "nt" else ["--host", "unix:///var/run/docker.sock"]
    return subprocess.run(["docker", *context, *args], capture_output=True, text=True, timeout=20)


def name_for(bot):
    return f"fadedai-aio-{bot}"


def wait_ready(service, bot):
    state = service.start(bot)
    for _ in range(30):
        if state["status"] == "running":
            service.start(bot)  # Flush files that were staged before XFCE was ready.
            return
        if state["status"] == "unavailable":
            break
        time.sleep(1)
        state = service.status(bot)
    logs = docker("container", "logs", "--tail", "15", name_for(bot))
    if logs.returncode == 0:
        print(logs.stdout + logs.stderr, flush=True)
    raise RuntimeError(state["message"] or f"Desktop did not start: {state['status']}")


def remove_test_resources(bot):
    label_format = '{{index .Config.Labels "' + BOT_LABEL + '"}}'
    target = name_for(bot)
    record = docker("container", "inspect", "--format", label_format, target)
    if record.returncode == 0 and record.stdout.strip() == bot:
        docker("container", "rm", "--force", target)
    volume = target + "-home"
    label_format = '{{index .Labels "' + MANAGED_LABEL + '"}} {{index .Labels "' + BOT_LABEL + '"}}'
    record = docker("volume", "inspect", "--format", label_format, volume)
    if record.returncode == 0 and record.stdout.strip() == f"1 {bot}":
        docker("volume", "rm", volume)


def main():
    adam, eva = (str(uuid4()) for _ in range(2))
    runtime = AIORuntime()
    try:
        with TemporaryDirectory(prefix="fadedai-aio-smoke-") as location:
            # The real AIO API is tested with synthetic reports so the live
            # Ollama session and current game/desktop are unaffected.
            service = BotComputers(Path(location) / "jobs.sqlite3", runtime, lambda prompt, source: f"{prompt}: {source}")
            service.prepare()
            for bot in (adam, eva):
                print(f"Starter testskrivebord {bot[:8]} …", flush=True)
                wait_ready(service, bot)
                frame = runtime.screenshot(bot)
                assert frame.startswith(b"\x89PNG\r\n\x1a\n")
                runtime.key(bot, "escape")
                print(f"Skrivebord svarer. PNG: {len(frame)} bytes.", flush=True)

            for bot, text in ((adam, "Adams testdata"), (eva, "Evas testdata")):
                source = service.upload(bot, "Kildetekst.txt", text)
                service.enqueue(bot, str(uuid4()), "Lav en testrapport", source["id"])
                assert service.work_once()
                job = service.jobs(bot)["jobs"][0]
                assert job["status"] == "completed", job
                assert text in service.file(bot, job["id"])["content"]

            adam_job = service.jobs(adam)["jobs"][0]["id"]
            try:
                service.file(eva, adam_job)
            except BotComputerError as exc:
                assert exc.status == 404
            else:
                raise AssertionError("Eva could open Adam's report before sharing.")
            try:
                adam_report = next(row for row in service.files(adam)["files"] if row["id"] == adam_job)
                runtime.read_artifact(eva, f'{adam_report["id"]}-Opgaveresultat.txt')
            except AIORuntimeError:
                pass
            else:
                raise AssertionError("Adam's report was present in Eva's Docker filesystem.")

            for bot in (adam, eva):
                service.stop(bot)
                wait_ready(service, bot)
            assert runtime.read_artifact(adam, f"{adam_job}-Opgaveresultat.txt").decode().endswith("Adams testdata")
            shared = service.share(eva, adam, adam_job)
            assert runtime.read_artifact(eva, f'{shared["id"]}-Opgaveresultat.txt').decode().endswith("Adams testdata")
            stats = docker("stats", "--no-stream", "--format", "{{.Name}} {{.MemUsage}} {{.CPUPerc}}",
                           name_for(adam), name_for(eva))
            if stats.returncode == 0:
                print(stats.stdout.strip(), flush=True)
            print("To separate skriveborde, input, filer, deling og genstart bestod.", flush=True)
    finally:
        for bot in (adam, eva):
            remove_test_resources(bot)


if __name__ == "__main__":
    main()

"""Connect an existing Azure Speech resource from the signed-in PC account."""

import json
from pathlib import Path
import re
import shutil
import subprocess
from concurrent.futures import ThreadPoolExecutor
import tkinter as tk
from tkinter import ttk
import webbrowser

from sweatcaster.microsoft_voice import REGION, credentials, store

RESOURCE_ID = re.compile(
    r"/subscriptions/([a-f0-9-]{36})/resourceGroups/([A-Za-z0-9_.-]{1,90})"
    r"/providers/Microsoft\.CognitiveServices/accounts/([A-Za-z0-9_.-]{1,64})", re.IGNORECASE
)


def az(*arguments):
    executable = shutil.which("az")
    if executable is None:
        raise ValueError("Installér Azure CLI og log ind med din Azure-konto først.")
    if not Path(executable).is_absolute():
        raise ValueError("Azure CLI kunne ikke findes på PC’en.")
    result = subprocess.run([executable, *arguments, "--only-show-errors", "-o", "json"],
                            capture_output=True, timeout=35, encoding="utf-8", errors="replace",
                            creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0), check=False)
    if result.returncode != 0:
        raise ValueError("Azure svarede med en fejl. Tjek dit login og din adgang til Speech-ressourcen.")
    return json.loads(result.stdout)


def list_resources():
    rows = az("cognitiveservices", "account", "list")
    if not isinstance(rows, list):
        raise ValueError("Azure gav en ugyldig liste over Speech-ressourcer.")
    resources = {}
    for item in rows:
        if not isinstance(item, dict) or item.get("kind") != "SpeechServices":
            continue
        identifier = RESOURCE_ID.fullmatch(str(item.get("id", "")))
        region = str(item.get("location", ""))
        if identifier and REGION.fullmatch(region):
            subscription, group, name = identifier.groups()
            resources[f"{name} · {region} · {group}"] = (subscription, group, name, region)
    return resources


def connect(resource):
    subscription, group, name, region = resource
    result = az("cognitiveservices", "account", "keys", "list", f"--subscription={subscription}",
                f"--resource-group={group}", f"--name={name}")
    store(result.get("key1") if isinstance(result, dict) else None, region)


def main():
    window = tk.Tk()
    window.title("FadedAI · Forbind Christel")
    frame = ttk.Frame(window, padding=20)
    frame.pack(fill="both", expand=True)
    ttk.Label(frame, text="Brug en eksisterende Azure Speech-ressource. Nøglen gemmes på PC’en.",
              wraplength=430).pack(anchor="w")
    state = tk.StringVar(value="Christel har allerede en nøgle på PC’en." if credentials() else "")
    picker = ttk.Combobox(frame, state="readonly", width=54)
    resources = {}
    worker = ThreadPoolExecutor(max_workers=1)
    busy = False

    def run(operation, done, message):
        nonlocal busy
        if busy:
            return
        busy = True
        state.set(message)
        future = worker.submit(operation)

        def finish():
            nonlocal busy
            if not future.done():
                window.after(120, finish)
                return
            busy = False
            try:
                value = future.result()
            except (OSError, subprocess.TimeoutExpired, json.JSONDecodeError, TypeError):
                state.set("PC’en kunne ikke læse eller gemme Azure-opsætningen.")
            except ValueError as error:
                state.set(str(error))
            else:
                done(value)

        window.after(120, finish)

    def show(rows):
        resources.clear()
        resources.update(rows)
        picker["values"] = tuple(rows)
        if rows:
            picker.current(0)
            state.set("Vælg din Speech-ressource og tryk Forbind.")
        else:
            picker.set("")
            state.set("Der er ingen Speech-ressource i dit aktive Azure-abonnement.")

    def choose():
        resource = resources.get(picker.get())
        if resource:
            run(lambda: connect(resource), lambda _: state.set("Christel er klar via den parrede PC."),
                "Henter nøglen og gemmer den på PC’en…")

    ttk.Button(frame, text="Find Speech-ressourcer",
               command=lambda: run(list_resources, show, "Finder ressourcer på din Azure-konto…")).pack(anchor="w", pady=8)
    picker.pack(fill="x")
    ttk.Button(frame, text="Forbind", command=choose).pack(anchor="w", pady=8)
    ttk.Button(frame, text="Åbn Microsofts hjælp til Azure-login",
               command=lambda: webbrowser.open("https://learn.microsoft.com/cli/azure/authenticate-azure-cli-interactively")).pack(anchor="w")
    ttk.Label(frame, textvariable=state, wraplength=430).pack(fill="x", pady=(10, 0))
    window.mainloop()
    worker.shutdown(wait=False, cancel_futures=True)


if __name__ == "__main__":
    main()

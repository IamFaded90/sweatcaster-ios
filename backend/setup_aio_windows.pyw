"""Prepare the Windows backend and the local AIO bot computers."""

from __future__ import annotations

import os
import queue
import shutil
import subprocess
import threading
import tkinter as tk
from dataclasses import dataclass
from pathlib import Path
from tkinter import filedialog, ttk
from typing import Callable

from install_fadedai_pc import install
from sweatcaster.aio_runtime import AIO_IMAGE


@dataclass(frozen=True)
class DockerStatus:
    message: str
    engine_ready: bool = False
    image_ready: bool = False


def docker_binary() -> str | None:
    locations = [
        ("ProgramFiles", "Docker/Docker/resources/bin/docker.exe"),
        ("LOCALAPPDATA", "Programs/DockerDesktop/resources/bin/docker.exe"),
    ]
    for variable, suffix in locations:
        if directory := os.environ.get(variable):
            candidate = Path(directory) / suffix
            if candidate.is_file():
                return str(candidate)
    found = shutil.which("docker.exe")
    if found and Path(found).resolve().parent != Path.cwd().resolve():
        return str(Path(found).resolve())
    return None


def run_docker(docker: str, arguments: tuple[str, ...], timeout: int = 15):
    return subprocess.run(
        [docker, "--context", "desktop-linux", *arguments],
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
        timeout=timeout,
        creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
        check=False,
    )


def docker_status(docker: str | None) -> DockerStatus:
    if not docker:
        return DockerStatus("Docker Desktop blev ikke fundet på PC’en.")
    try:
        result = run_docker(docker, ("info", "--format", "{{.OSType}}"))
        if result.returncode:
            error = result.stderr.casefold()
            if "access is denied" in error or "permission denied" in error or "adgang nægtet" in error:
                return DockerStatus("Din Windows-bruger har ikke adgang til Docker-motoren.")
            return DockerStatus("Docker-motoren svarer ikke. Åbn Docker Desktop, og prøv igen.")
        if result.stdout.strip() != "linux":
            return DockerStatus("Vælg Linux-containere i Docker Desktop, og prøv igen.")
        result = run_docker(docker, ("image", "inspect", "--format", "{{.Id}}", AIO_IMAGE))
    except (OSError, subprocess.TimeoutExpired):
        return DockerStatus("Docker svarede ikke. Tjek Docker Desktop, og prøv igen.")
    if result.returncode:
        error = result.stderr.casefold()
        if "no such image" in error or "no such object" in error:
            return DockerStatus("Docker er klar. AIO-skrivebordet skal hentes én gang.", engine_ready=True)
        return DockerStatus("Docker kunne ikke kontrollere AIO-skrivebordet. Prøv at tjekke igen.")
    if not result.stdout.strip().startswith("sha256:"):
        return DockerStatus("Docker returnerede et uventet svar. Prøv at tjekke igen.")
    return DockerStatus("Docker og AIO-skrivebordet er klar.", engine_ready=True, image_ready=True)


def install_root(path: Path) -> Path:
    root = path.resolve(strict=True)
    package = root / "sweatcaster"
    if not (package / "api.py").is_file() or not (package / "v2_api.py").is_file():
        raise ValueError("Vælg mappen til den eksisterende FadedAI-installation på PC’en.")
    return root


def default_checkpoint() -> str:
    local = os.environ.get("LOCALAPPDATA")
    if not local:
        return ""
    parent = Path(local) / "SweatCaster" / "app"
    candidates = []
    for path in sorted(parent.glob("fadedai-checkpoint-*"), reverse=True):
        try:
            candidates.append(str(install_root(path)))
        except (OSError, ValueError):
            continue
    return candidates[0] if len(candidates) == 1 else ""


class SetupWindow:
    def __init__(self, root: tk.Tk):
        self.root = root
        self.results: queue.Queue[tuple[DockerStatus, str]] = queue.Queue()
        self.docker = docker_binary()
        self.state = DockerStatus("")
        self.busy = False
        self.status = tk.StringVar()
        self.detail = tk.StringVar()
        self.checkpoint = tk.StringVar(value=default_checkpoint())

        root.title("FadedAI – Opdatér PC’en")
        root.minsize(520, 360)
        root.columnconfigure(0, weight=1)
        root.rowconfigure(0, weight=1)
        frame = ttk.Frame(root, padding=22)
        frame.grid(sticky="nsew")
        frame.columnconfigure(0, weight=1)
        ttk.Label(frame, text="Opdatér FadedAI på PC’en", font=("Segoe UI", 17, "bold")).grid(sticky="w")
        ttk.Label(
            frame,
            text="Klargør AIO-skrivebordet, og opdatér derefter botcomputere, Emby, videokommentarer og stemmer samlet.",
            wraplength=470,
        ).grid(sticky="w", pady=(4, 12))
        ttk.Label(frame, textvariable=self.status, wraplength=470).grid(sticky="w")

        actions = ttk.Frame(frame)
        actions.grid(sticky="ew", pady=(6, 16))
        self.check_button = ttk.Button(actions, text="Tjek Docker", command=self.check)
        self.check_button.pack(side="left")
        self.pull_button = ttk.Button(actions, text="Hent AIO-skrivebord", command=self.pull)
        self.pull_button.pack(side="left", padx=(8, 0))

        ttk.Label(frame, text="FadedAI-mappen på PC’en").grid(sticky="w")
        chooser = ttk.Frame(frame)
        chooser.grid(sticky="ew", pady=(4, 8))
        chooser.columnconfigure(0, weight=1)
        ttk.Entry(chooser, textvariable=self.checkpoint, state="readonly").grid(sticky="ew")
        self.choose_button = ttk.Button(chooser, text="Vælg mappe…", command=self.choose_checkpoint)
        self.choose_button.grid(row=0, column=1, padx=(8, 0))
        self.install_button = ttk.Button(frame, text="Opdatér FadedAI", command=self.update_checkpoint)
        self.install_button.grid(sticky="w")
        ttk.Label(frame, textvariable=self.detail, wraplength=470).grid(sticky="w", pady=(10, 0))
        ttk.Label(frame, text="Lad igangværende FadedAI-opgaver afslutte før opdateringen.",
                  wraplength=470).grid(sticky="w", pady=(4, 0))
        root.protocol("WM_DELETE_WINDOW", self.close)
        root.after(100, self.receive)
        self.check()

    def close(self) -> None:
        if self.busy:
            self.detail.set("Vent, til det igangværende trin er færdigt.")
        else:
            self.root.destroy()

    def update_buttons(self) -> None:
        self.check_button.configure(state="disabled" if self.busy else "normal")
        self.pull_button.configure(
            state="normal" if not self.busy and self.state.engine_ready and not self.state.image_ready else "disabled"
        )
        self.choose_button.configure(state="disabled" if self.busy else "normal")
        self.install_button.configure(
            state="normal" if not self.busy and self.state.image_ready and self.checkpoint.get() else "disabled"
        )

    def work(self, message: str, operation: Callable[[], tuple[DockerStatus, str]]) -> None:
        self.busy = True
        self.status.set(message)
        self.detail.set("")
        self.update_buttons()

        def worker() -> None:
            self.results.put(operation())

        threading.Thread(target=worker, daemon=True).start()

    def receive(self) -> None:
        try:
            self.state, detail = self.results.get_nowait()
        except queue.Empty:
            pass
        else:
            self.status.set(self.state.message)
            self.detail.set(detail)
            self.busy = False
            self.update_buttons()
        self.root.after(100, self.receive)

    def check(self) -> None:
        self.docker = docker_binary()
        self.work("Tjekker Docker…", lambda: (docker_status(self.docker), ""))

    def pull(self) -> None:
        docker = self.docker
        if not docker or not self.state.engine_ready or self.busy:
            return

        def download() -> tuple[DockerStatus, str]:
            try:
                result = run_docker(docker, ("pull", AIO_IMAGE), timeout=1200)
            except (OSError, subprocess.TimeoutExpired):
                return docker_status(docker), "Download blev afbrudt. Tjek forbindelsen, og prøv igen."
            error = result.stderr.casefold()
            if result.returncode == 0:
                detail = ""
            elif "read-only file system" in error or "no space left" in error:
                detail = "Docker kan ikke skrive til sin disk. Tjek ledig plads under Docker Desktop → Resources → Advanced."
            else:
                detail = "AIO kunne ikke hentes. Tjek internetforbindelsen, og prøv igen."
            return docker_status(docker), detail

        self.work("Henter AIO-skrivebordet. Det kan tage nogle minutter…", download)

    def choose_checkpoint(self) -> None:
        chosen = filedialog.askdirectory(parent=self.root, title="Vælg FadedAI-mappen", mustexist=True)
        if not chosen:
            return
        try:
            self.checkpoint.set(str(install_root(Path(chosen))))
        except (OSError, ValueError):
            self.detail.set("Mappen mangler FadedAI-filerne. Vælg den eksisterende installationsmappe.")
        else:
            self.detail.set("")
        self.update_buttons()

    def update_checkpoint(self) -> None:
        if not self.state.image_ready or self.busy:
            return
        try:
            root = install_root(Path(self.checkpoint.get()))
        except (OSError, ValueError):
            self.detail.set("FadedAI-mappen kunne ikke læses. Vælg den igen.")
            return
        def update() -> tuple[DockerStatus, str]:
            try:
                install(root)
            except (OSError, ValueError, SyntaxError):
                return self.state, "FadedAI kunne ikke opdateres. Tjek mappen, versionen og skriveadgangen."
            return self.state, "PC-delen er opdateret. Genstart PC’en, og åbn din sædvanlige FadedAI-genvej."

        self.work("Opdaterer PC-delen af FadedAI…", update)


if __name__ == "__main__":
    window = tk.Tk()
    SetupWindow(window)
    window.mainloop()

"""Connect a YouTube channel under the Windows account that runs FadedAI."""

from __future__ import annotations

import os
import queue
import threading
import tkinter as tk
from pathlib import Path
from tkinter import filedialog, messagebox, ttk

from sweatcaster.google_desktop import GoogleDesktopError, authorize_desktop, load_desktop_client
from sweatcaster.youtube_connection import (
    SCOPE, YouTubeError, channels_for_token, load_connection, remove_connection, save_connection,
)


class SetupWindow:
    def __init__(self, root):
        self.root = root
        self.events = queue.Queue()
        self.busy = False
        self.status = tk.StringVar()
        self.saved = False
        root.title("FadedAI – Forbind YouTube")
        root.minsize(500, 265)
        frame = ttk.Frame(root, padding=22)
        frame.pack(fill="both", expand=True)
        ttk.Label(frame, text="Forbind YouTube", font=("Segoe UI", 17, "bold")).pack(anchor="w")
        ttk.Label(
            frame, wraplength=440,
            text="Vælg en Desktop OAuth-klient fra et Google Cloud-projekt med YouTube Data API v3. "
                 "Du logger ind hos Google og giver FadedAI adgang til at læse din kanal.",
        ).pack(anchor="w", pady=(6, 14))
        self.connect = ttk.Button(frame, text="Vælg klientfil og forbind", command=self.begin)
        self.connect.pack(anchor="w")
        self.disconnect = ttk.Button(frame, text="Fjern forbindelsen på denne PC", command=self.remove)
        self.disconnect.pack(anchor="w", pady=(8, 12))
        ttk.Label(frame, textvariable=self.status, wraplength=440).pack(anchor="w")
        try:
            self.saved = load_connection() is not None
            if self.saved:
                self.status.set("En YouTube-forbindelse er gemt. Du kan hente dine kanaler fra Forbindelser på iPhone.")
        except (YouTubeError, OSError):
            self.saved = True
            self.status.set("Den gemte forbindelse kunne ikke læses. Forbind igen eller fjern den.")
        self.buttons()
        root.after(100, self.poll)

    def buttons(self):
        self.connect.configure(state="disabled" if self.busy else "normal")
        self.disconnect.configure(state="normal" if self.saved and not self.busy else "disabled")

    def begin(self):
        selected = filedialog.askopenfilename(title="Vælg Desktop OAuth-klienten", filetypes=[("Google OAuth JSON", "*.json")])
        if not selected:
            return
        self.busy = True
        self.buttons()
        self.status.set("Godkend læseadgang til YouTube i browseren.")
        threading.Thread(target=self.authorize, args=(Path(selected),), daemon=True).start()

    def authorize(self, path):
        try:
            client = load_desktop_client(path)
            credentials = authorize_desktop(path, (SCOPE,), offline=True)
            if not credentials.refresh_token:
                raise GoogleDesktopError("Google gav ingen varig læseadgang. Forbind igen.")
            channels = channels_for_token(credentials.access_token)
            save_connection({**client, "refresh_token": credentials.refresh_token})
        except (GoogleDesktopError, YouTubeError) as exc:
            self.events.put((False, str(exc)))
        except (OSError, ValueError):
            self.events.put((False, "Forbindelsen kunne ikke gemmes under denne Windows-bruger."))
        else:
            note = ("YouTube-forbindelsen er gemt." if channels else
                    "Forbindelsen er gemt. Den valgte Google-konto returnerede ingen kanaler.")
            self.events.put((True, note))

    def remove(self):
        if self.busy or not messagebox.askyesno("Fjern forbindelsen?", "Slet den gemte YouTube-adgang på denne PC?"):
            return
        try:
            remove_connection()
        except OSError:
            self.status.set("Forbindelsen kunne ikke fjernes.")
        else:
            self.saved = False
            self.status.set("Fjernet fra PC’en. Du kan også tilbagekalde adgangen i din Google-konto.")
            self.buttons()

    def poll(self):
        try:
            success, message = self.events.get_nowait()
        except queue.Empty:
            pass
        else:
            self.busy = False
            if success:
                self.saved = True
            self.status.set(message)
            self.buttons()
        self.root.after(100, self.poll)


if __name__ == "__main__":
    if os.name != "nt":
        raise SystemExit("Åbn YouTube-opsætningen på Windows.")
    root = tk.Tk()
    SetupWindow(root)
    root.mainloop()

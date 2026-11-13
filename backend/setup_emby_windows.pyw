"""Connect an Emby user to the Windows account that runs FadedAI."""

from __future__ import annotations

import getpass
import http.client
import ipaddress
import json
import os
import queue
import socket
import threading
import tkinter as tk
from time import monotonic
from tkinter import messagebox, ttk
from urllib.error import HTTPError
from urllib.request import ProxyHandler, Request, build_opener
from uuid import NAMESPACE_URL, uuid5

from sweatcaster.emby_library import (
    EmbyConfiguration, EmbyLibraryError, NoRedirects, emby_api_base, fetch_emby, find_secure_server,
    parse_configured_url, valid_id, valid_token,
)
from sweatcaster.emby_settings import load_local_settings, remove_local_settings, save_local_settings

MAX_LOGIN_BYTES = 256 * 1024
LOGIN_TIMEOUT = 8
DEVICE_ID = uuid5(NAMESPACE_URL, f"FadedAI:Emby:Windows:{socket.gethostname()}:{getpass.getuser()}").hex
CLIENT_HEADER = f'Emby Client="FadedAI", Device="Windows", DeviceId="{DEVICE_ID}", Version="1.0.0"'


class SetupError(Exception):
    pass


def is_loopback(host: str) -> bool:
    if host == "localhost":
        return True
    try:
        return ipaddress.ip_address(host).is_loopback
    except ValueError:
        return False


def connect(address: str, username: str, password: str, browser: str) -> dict[str, str]:
    try:
        server = parse_configured_url(address)
        web = parse_configured_url(browser, https_only=True) if browser else None
    except ValueError as exc:
        raise SetupError("Indtast Emby-serverens HTTPS-adresse, eller brug Find sikker adresse.") from exc
    if server.scheme != "https" and not is_loopback(server.hostname or ""):
        raise SetupError("Brug Find sikker adresse til en server, du normalt åbner med HTTP.")
    if web is not None and not web.path.rstrip("/").endswith("/web/index.html"):
        raise SetupError("Browserlinket skal være den fulde HTTPS-adresse frem til /web/index.html.")
    if not username or len(username) > 256 or len(password) > 2048:
        raise SetupError("Angiv dit Emby-brugernavn, og tjek længden af adgangskoden.")

    request = Request(
        f"{emby_api_base(server.geturl())}/Users/AuthenticateByName",
        method="POST",
        data=json.dumps({"Username": username, "Pw": password}).encode("utf-8"),
        headers={"Accept": "application/json", "Content-Type": "application/json", "X-Emby-Authorization": CLIENT_HEADER},
    )
    try:
        deadline = monotonic() + LOGIN_TIMEOUT
        with build_opener(ProxyHandler({}), NoRedirects()).open(request, timeout=LOGIN_TIMEOUT) as response:
            data = bytearray()
            while len(data) <= MAX_LOGIN_BYTES:
                if monotonic() > deadline:
                    raise TimeoutError
                chunk = response.read1(min(32768, MAX_LOGIN_BYTES + 1 - len(data)))
                if not chunk:
                    break
                data.extend(chunk)
    except HTTPError as exc:
        exc.close()
        if exc.code in {400, 401, 403}:
            raise SetupError("Emby afviste login. Tjek brugernavn og adgangskode.") from exc
        if 300 <= exc.code < 400:
            raise SetupError("Emby omdirigerede login. Brug den endelige HTTPS-adresse til serveren.") from exc
        raise SetupError("Emby kunne ikke gennemføre login. Tjek serveradressen og prøv igen.") from exc
    except (OSError, http.client.HTTPException) as exc:
        raise SetupError("Kunne ikke nå Emby. Tjek netværket, serveradressen og HTTPS-certifikatet.") from exc
    try:
        if len(data) > MAX_LOGIN_BYTES:
            raise ValueError
        result = json.loads(data)
        user_id, token = result["User"]["Id"], result["AccessToken"]
        if not valid_id(user_id) or not valid_token(token):
            raise ValueError
    except (ValueError, TypeError, KeyError, RecursionError) as exc:
        raise SetupError("Emby returnerede ikke en gyldig brugerforbindelse.") from exc

    settings = {"url": server.geturl(), "user_id": user_id, "token": token}
    if web is not None:
        settings["web_url"] = web.geturl()
    return settings


def revoke(settings: dict[str, str]) -> bool:
    try:
        server = parse_configured_url(settings["url"])
        token = settings["token"]
        if not valid_token(token) or (server.scheme != "https" and not is_loopback(server.hostname or "")):
            return False
        request = Request(
            f"{emby_api_base(server.geturl())}/Sessions/Logout",
            method="POST", data=b"",
            headers={"X-Emby-Authorization": CLIENT_HEADER, "X-Emby-Token": token},
        )
        with build_opener(ProxyHandler({}), NoRedirects()).open(request, timeout=5):
            return True
    except HTTPError as exc:
        exc.close()
        return exc.code == 401
    except (OSError, ValueError, KeyError, http.client.HTTPException):
        return False


def test_library(settings: dict[str, str]) -> None:
    config = EmbyConfiguration(emby_api_base(settings["url"]), settings["user_id"], settings["token"])
    fetch_emby(config, "Views", {"IncludeExternalContent": "false"})


class SetupWindow:
    def __init__(self, root: tk.Tk):
        self.root = root
        self.result: queue.Queue[tuple[str, str]] = queue.Queue()
        root.title("FadedAI – Forbind Emby")
        root.minsize(520, 385)
        frame = ttk.Frame(root, padding=22)
        frame.grid(sticky="nsew")
        root.columnconfigure(0, weight=1)
        root.rowconfigure(0, weight=1)
        frame.columnconfigure(0, weight=1)

        ttk.Label(frame, text="Forbind Emby", font=("Segoe UI", 17, "bold")).grid(sticky="w")
        ttk.Label(frame, text="Log ind på din Emby-server. FadedAI bruger din brugers biblioteksadgang.",
                  wraplength=420).grid(sticky="w", pady=(4, 14))
        self.address = self.field(frame, "Emby-server")
        self.find_button = ttk.Button(frame, text="Find sikker adresse", command=self.start_find_address)
        self.find_button.grid(sticky="w", pady=(0, 8))
        self.username = self.field(frame, "Brugernavn")
        self.password = self.field(frame, "Adgangskode", masked=True)
        self.browser = self.field(frame, "HTTPS-link til Emby i browseren (valgfrit, slutter på /web/index.html)")
        self.status = tk.StringVar()

        buttons = ttk.Frame(frame)
        buttons.grid(sticky="ew", pady=(12, 8))
        self.connect_button = ttk.Button(buttons, text="Forbind", command=self.start_connect)
        self.connect_button.pack(side="left")
        self.test_button = ttk.Button(buttons, text="Test bibliotek", command=self.start_test)
        self.test_button.pack(side="left", padx=(8, 0))
        self.disconnect_button = ttk.Button(buttons, text="Fjern forbindelse", command=self.start_disconnect)
        self.disconnect_button.pack(side="left", padx=(8, 0))
        ttk.Label(frame, textvariable=self.status, wraplength=420).grid(sticky="w")
        root.bind("<Return>", self.start_connect)
        root.after(80, self.poll)
        self.address.focus()
        self.saved = False
        try:
            settings = load_local_settings()
        except (OSError, ValueError):
            self.saved = True
            self.status.set("Den gemte forbindelse kunne ikke læses. Forbind igen, eller fjern den.")
        else:
            if settings:
                self.saved = True
                self.address.insert(0, settings["url"])
                self.browser.insert(0, settings.get("web_url", ""))
                self.status.set("Der er gemt en Emby-forbindelse for denne Windows-bruger.")
        self.busy = False
        self.update_buttons()

    @staticmethod
    def field(parent: ttk.Frame, name: str, *, masked: bool = False) -> ttk.Entry:
        ttk.Label(parent, text=name, wraplength=420).grid(sticky="w")
        entry = ttk.Entry(parent, show="•" if masked else "")
        entry.grid(sticky="ew", pady=(2, 8), ipady=2)
        return entry

    def update_buttons(self) -> None:
        self.address.configure(state="disabled" if self.busy else "normal")
        self.find_button.configure(state="disabled" if self.busy else "normal")
        self.connect_button.configure(state="disabled" if self.busy else "normal")
        self.test_button.configure(state="disabled" if self.busy or not self.saved else "normal")
        self.disconnect_button.configure(state="disabled" if self.busy or not self.saved else "normal")

    def start_connect(self, _event: object = None) -> None:
        if self.busy:
            return
        args = (self.address.get().strip(), self.username.get().strip(), self.password.get(), self.browser.get().strip())
        self.password.delete(0, tk.END)
        self.busy = True
        self.update_buttons()
        self.status.set("Forbinder til Emby…")
        threading.Thread(target=self.save_connection, args=args, daemon=True).start()

    def start_find_address(self) -> None:
        if self.busy:
            return
        address = self.address.get().strip()
        self.busy = True
        self.update_buttons()
        self.status.set("Tjekker HTTPS-adressen uden at sende login…")
        threading.Thread(target=self.check_secure_address, args=(address,), daemon=True).start()

    def check_secure_address(self, address: str) -> None:
        try:
            candidate = find_secure_server(address)
        except ValueError:
            self.result.put(("error", "Indtast den fulde Emby-adresse, inkl. http:// eller https://."))
        else:
            if candidate:
                self.result.put(("address", candidate))
            else:
                self.result.put(("error", "Ingen Emby-forbindelse med gyldigt HTTPS-certifikat svarede. "
                                 "Brug den HTTPS-adresse, som serverens ejer har angivet."))

    def save_connection(self, *args: str) -> None:
        try:
            previous = load_local_settings()
        except (OSError, ValueError):
            previous = None
        try:
            settings = connect(*args)
            try:
                test_library(settings)
            except EmbyLibraryError:
                if previous is None or previous["token"] != settings["token"]:
                    revoke(settings)
                raise
            save_local_settings(settings)
        except SetupError as exc:
            self.result.put(("error", str(exc)))
        except EmbyLibraryError as exc:
            self.result.put(("error", f"Login lykkedes, men biblioteket kunne ikke åbnes. {exc}"))
        except (OSError, ValueError):
            self.result.put(("error", "Forbindelsen kunne ikke gemmes for denne Windows-bruger."))
        else:
            if previous is not None and previous["token"] != settings["token"]:
                revoke(previous)
            self.result.put(("connected", "Forbundet. Åbn Mere → Emby & bibliotek på iPhone, og træk ned for at opdatere."))

    def start_test(self) -> None:
        if self.busy or not self.saved:
            return
        self.busy = True
        self.update_buttons()
        self.status.set("Tester biblioteksadgangen…")
        threading.Thread(target=self.check_saved_connection, daemon=True).start()

    def check_saved_connection(self) -> None:
        try:
            settings = load_local_settings()
            if settings is None:
                self.result.put(("disconnected", "Der er ingen gemt Emby-forbindelse."))
                return
            test_library(settings)
        except EmbyLibraryError as exc:
            self.result.put(("error", str(exc)))
        except (OSError, ValueError):
            self.result.put(("error", "Den gemte forbindelse kunne ikke læses. Forbind igen."))
        else:
            self.result.put(("connected", "Emby-biblioteket svarer. Du kan opdatere det på din iPhone."))

    def start_disconnect(self) -> None:
        if self.busy or not self.saved or not messagebox.askyesno("Fjern Emby-forbindelse?", "Fjern forbindelsen fra FadedAI på denne PC?"):
            return
        self.busy = True
        self.update_buttons()
        self.status.set("Fjerner forbindelsen…")
        threading.Thread(target=self.remove_connection, daemon=True).start()

    def remove_connection(self) -> None:
        try:
            settings = load_local_settings()
        except (OSError, ValueError):
            settings = None
        try:
            remove_local_settings()
        except OSError:
            self.result.put(("error", "Forbindelsen kunne ikke fjernes fra denne PC."))
            return
        revoked = settings is not None and revoke(settings)
        message = "Forbindelsen er fjernet."
        if not revoked:
            message += " Emby kunne ikke bekræfte, at sessionen er logget ud."
        self.result.put(("disconnected", message))

    def poll(self) -> None:
        try:
            kind, message = self.result.get_nowait()
        except queue.Empty:
            pass
        else:
            if kind in ("connected", "disconnected"):
                self.saved = kind == "connected"
            self.busy = False
            self.update_buttons()
            if kind == "address":
                self.address.delete(0, tk.END)
                self.address.insert(0, message)
                self.username.focus()
                message = "Emby svarede over HTTPS. Indtast dit brugernavn og din adgangskode, og tryk Forbind."
            self.status.set(message)
        self.root.after(80, self.poll)


if __name__ == "__main__":
    window = tk.Tk()
    if os.name != "nt":
        window.withdraw()
        messagebox.showerror("FadedAI – Forbind Emby", "Dette opsætningsvindue skal åbnes på Windows.")
        window.destroy()
    else:
        SetupWindow(window)
        window.mainloop()

"""One-time Composio project setup for the FadedAI PC account."""

import os
import tkinter as tk
from tkinter import messagebox, ttk
import webbrowser

from sweatcaster.composio_settings import FIELDS, load, save

LABELS = ("Projektnøgle", "Google Drive login-id (valgfrit)", "GitHub login-id (valgfrit)", "Gmail login-id (valgfrit)")


def main():
    root = tk.Tk()
    root.title("FadedAI · Forbind Composio")
    frame = ttk.Frame(root, padding=20)
    frame.pack(fill="both", expand=True)
    stored = load()
    variables = {key: tk.StringVar(value=stored.get(key, "") if key != "key" else "") for key in FIELDS}
    ttk.Label(frame, text="Gem projektnøglen én gang. FadedAI finder selv loginopsætningen til dine tjenester.",
              wraplength=460).pack(anchor="w", pady=(0, 10))
    ttk.Button(frame, text="Åbn Composio Dashboard",
               command=lambda: webbrowser.open("https://dashboard.composio.dev/")).pack(anchor="w", pady=(0, 10))
    for key, title in zip(FIELDS, LABELS):
        ttk.Label(frame, text=title).pack(anchor="w")
        ttk.Entry(frame, textvariable=variables[key], width=52, show="•" if key == "key" else "").pack(
            fill="x", pady=(2, 10)
        )
    state = tk.StringVar()

    def submit():
        try:
            values = {key: value.get().strip() for key, value in variables.items()}
            values["key"] = values["key"] or load().get("key", "")
            save(values)
        except ValueError as error:
            state.set(str(error))
        except OSError:
            state.set("Windows kunne ikke gemme Composio-indstillingerne.")
        else:
            variables["key"].set("")
            state.set("Gemt. På iPhone vælges Tjenester på PC’en → Composio → Log ind.")

    ttk.Button(frame, text="Gem", command=submit).pack(anchor="w")
    ttk.Label(frame, textvariable=state, wraplength=460).pack(fill="x", pady=(10, 0))
    root.mainloop()


if __name__ == "__main__":
    if os.name == "nt":
        main()
    else:
        messagebox.showerror("FadedAI", "Composio-opsætningen åbnes på Windows.")

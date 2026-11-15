"""Save the owner's AgentMail API key under the Windows user who runs FadedAI."""

import tkinter as tk
from tkinter import ttk
import webbrowser

from sweatcaster.agentmail_inboxes import save_key


def main():
    window = tk.Tk()
    window.title("FadedAI · Forbind AgentMail")
    frame = ttk.Frame(window, padding=20)
    frame.pack(fill="both", expand=True)
    ttk.Label(frame, text="Opret en AgentMail-konto, og indsæt dens API-nøgle her.",
              wraplength=420).pack(anchor="w")
    ttk.Button(frame, text="Åbn AgentMail",
               command=lambda: webbrowser.open("https://console.agentmail.to/")).pack(anchor="w", pady=8)
    ttk.Label(frame, text="API-nøgle").pack(anchor="w")
    value = tk.StringVar()
    ttk.Entry(frame, textvariable=value, show="•", width=48).pack(fill="x", pady=(4, 10))
    state = tk.StringVar()

    def save():
        try:
            save_key(value.get().strip())
        except ValueError as error:
            state.set(str(error))
        except (OSError, KeyError):
            state.set("Windows kunne ikke gemme nøglen.")
        else:
            value.set("")
            state.set("Gemt. Åbn agentens profil og tryk E-mail → Opret e-mailadresse.")

    ttk.Button(frame, text="Gem", command=save).pack(anchor="w")
    ttk.Label(frame, textvariable=state, wraplength=420).pack(fill="x", pady=(8, 0))
    window.mainloop()


if __name__ == "__main__":
    main()

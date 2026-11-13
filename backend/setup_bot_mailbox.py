"""Provision one bot's Google Workspace mailbox through an interactive admin session."""

from __future__ import annotations

import argparse
import getpass
import json
import re
import sys
import warnings
from dataclasses import dataclass
from http.client import HTTPException
from pathlib import Path
from urllib.error import HTTPError
from urllib.parse import quote
from urllib.request import HTTPRedirectHandler, Request, build_opener
from uuid import UUID

from sweatcaster.google_desktop import GoogleDesktopError, authorize_desktop


USERS_URL = "https://admin.googleapis.com/admin/directory/v1/users"
SCOPE = "https://www.googleapis.com/auth/admin.directory.user"
BOT_MARKER = "FadedAI Bot ID"
MAX_JSON_BYTES = 32_768


class SetupError(Exception):
    """A setup issue that can be displayed without printing provider response bodies."""


@dataclass(frozen=True)
class BotMailbox:
    bot_id: UUID
    name: str
    domain: str

    @classmethod
    def parse(cls, bot_id: str, name: str, domain: str) -> BotMailbox:
        name = name.strip()
        if not 1 <= len(name) <= 60 or not name.isprintable():
            raise SetupError("Angiv et botnavn på mellem 1 og 60 tegn.")
        try:
            identity = UUID(bot_id)
            domain = domain.strip().lower().encode("idna").decode("ascii")
        except (ValueError, UnicodeError) as exc:
            raise SetupError("Tjek bottens ID og dit Workspace-domæne.") from exc
        label = r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?"
        if len(domain) > 253 or not re.fullmatch(rf"{label}(?:\.{label})+", domain) or domain == "gmail.com":
            raise SetupError("Angiv et domæne, du administrerer i Google Workspace.")
        return cls(identity, name, domain)

    @property
    def address(self) -> str:
        return f"faded-{self.bot_id.hex}@{self.domain}"

    @property
    def marker(self) -> dict[str, str]:
        return {"type": "custom", "customType": BOT_MARKER, "value": str(self.bot_id)}


class _RejectRedirects(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


class Directory:
    def __init__(self, token: str):
        self.token = token
        self.opener = build_opener(_RejectRedirects())

    def _request(self, url: str, payload: dict | None = None) -> tuple[int, dict]:
        body = json.dumps(payload).encode("utf-8") if payload is not None else None
        request = Request(url, data=body, headers={
            "Authorization": f"Bearer {self.token}",
            "Accept": "application/json",
            "Content-Type": "application/json",
        })
        try:
            with self.opener.open(request, timeout=15) as response:
                raw = response.read(MAX_JSON_BYTES + 1)
                if len(raw) > MAX_JSON_BYTES:
                    raise ValueError
                result = json.loads(raw)
                if not isinstance(result, dict):
                    raise ValueError
                return response.status, result
        except HTTPError as exc:
            with exc:
                if exc.code in (404, 409):
                    return exc.code, {}
                if exc.code in (401, 403):
                    raise SetupError("Google afviste adgangen. Brug en Workspace-admin med ret til at oprette brugere.") from None
                raise SetupError(f"Google Directory API returnerede HTTP {exc.code}.") from None
        except (OSError, HTTPException, ValueError, RecursionError):
            raise SetupError("Googles svar kunne ikke læses. Kør kommandoen igen for at tjekke den samme postkasse.") from None

    def lookup(self, mailbox: BotMailbox) -> dict | None:
        fields = "id,primaryEmail,externalIds,isMailboxSetup"
        status, result = self._request(f"{USERS_URL}/{quote(mailbox.address, safe='')}?fields={fields}")
        if status == 404:
            return None
        if status != 200:
            raise SetupError("Google returnerede en uventet status ved opslag af postkassen.")
        return self._verified(mailbox, result)

    def create(self, mailbox: BotMailbox, password: str) -> dict:
        status, result = self._request(f"{USERS_URL}?resolveConflictAccount=false", {
            "primaryEmail": mailbox.address,
            "name": {"givenName": mailbox.name, "familyName": "FadedAI"},
            "password": password,
            "changePasswordAtNextLogin": True,
            "externalIds": [mailbox.marker],
        })
        if status == 409:
            existing = self.lookup(mailbox)
            if existing is not None:
                return existing
            raise SetupError("Adressen er allerede optaget i Workspace. Ingen eksisterende konto blev ændret.")
        if status not in (200, 201):
            raise SetupError("Google bekræftede ikke oprettelsen. Tjek adressen i Workspace Admin.")
        return self._verified(mailbox, result)

    @staticmethod
    def _verified(mailbox: BotMailbox, result: dict) -> dict:
        if not isinstance(result.get("id"), str) or result.get("primaryEmail") != mailbox.address:
            raise SetupError("Google returnerede ikke den forventede konto.")
        markers = result.get("externalIds")
        if not isinstance(markers, list) or mailbox.marker not in markers:
            raise SetupError("Adressen tilhører en konto uden bottens ID. Ingen eksisterende konto blev ændret.")
        return result


def connect(client_file: Path) -> Directory:
    try:
        token = authorize_desktop(client_file, [SCOPE])
    except GoogleDesktopError as exc:
        raise SetupError(str(exc)) from None
    return Directory(token.access_token)


def temporary_password() -> str:
    try:
        with warnings.catch_warnings():
            warnings.simplefilter("error", getpass.GetPassWarning)
            password = getpass.getpass("Midlertidig adgangskode til botten (skjult): ")
    except getpass.GetPassWarning:
        raise SetupError("Åbn opsætningen i en terminal, hvor adgangskoden kan indtastes skjult.") from None
    if not 8 <= len(password) <= 100 or not re.fullmatch(r"[ -~]+", password):
        raise SetupError("Brug 8–100 ASCII-tegn i den midlertidige adgangskode.")
    return password


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bot-id", required=True, help="Bottens UUID fra FadedAI.")
    parser.add_argument("--bot-name", required=True, help="Bottens navn i FadedAI.")
    parser.add_argument("--domain", required=True, help="Dit Google Workspace-domæne.")
    parser.add_argument("--oauth-client", type=Path, help="Google OAuth-klientfil til Desktop-app.")
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--status", action="store_true", help="Tjek kontoen med Workspace-admin.")
    mode.add_argument("--apply", action="store_true", help="Opret kontoen. Der kan være en licensudgift.")
    args = parser.parse_args(argv)
    try:
        mailbox = BotMailbox.parse(args.bot_id, args.bot_name, args.domain)
        print(f"Bot {mailbox.name}: {mailbox.address}")
        if not args.status and not args.apply:
            print("Forhåndsvisning. Brug --status eller --apply med en Google OAuth-klientfil.")
            return 0
        if args.oauth_client is None:
            raise SetupError("Angiv Google OAuth-klientfilen med --oauth-client.")
        directory = connect(args.oauth_client)
        account = directory.lookup(mailbox)
        if account is None:
            if args.status:
                print("Google Workspace-kontoen findes endnu ikke.")
                return 0
            account = directory.create(mailbox, temporary_password())
        if account.get("isMailboxSetup") is True:
            print("Google Workspace-konto og Gmail-postkasse er klar.")
        else:
            print("Google Workspace-kontoen findes. Google har endnu ikke bekræftet, at Gmail-postkassen er klar.")
        return 0
    except (SetupError, EOFError, KeyboardInterrupt) as exc:
        print(str(exc) if isinstance(exc, SetupError) else "Opsætningen blev afbrudt.", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())

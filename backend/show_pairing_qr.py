"""Show the existing FadedAI pairing token as a QR code on this PC."""

import argparse
import getpass
import ipaddress
import json
import secrets
import shutil
import sys
import warnings
from datetime import datetime, timedelta, timezone
from pathlib import Path


LOCAL_NETWORKS = tuple(
    ipaddress.IPv4Network(cidr)
    for cidr in ("10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "100.64.0.0/10")
)


class PairingError(ValueError):
    pass


def canonical_address(address: str) -> str:
    try:
        parsed = ipaddress.IPv4Address(address.strip())
    except ValueError:
        raise PairingError("Indtast PC’ens private IPv4-adresse uden port eller sti.") from None
    if not any(parsed in network for network in LOCAL_NETWORKS):
        raise PairingError("Brug PC’ens private LAN- eller Tailscale-adresse.")
    return str(parsed)


def pairing_payload(address: str, token: str) -> str:
    if not 1 <= len(token) <= 512 or any(not 33 <= ord(char) <= 126 for char in token):
        raise PairingError("Tokenet er ugyldigt. Brug tokenet fra FadedAI på PC’en.")
    expires = datetime.now(timezone.utc) + timedelta(minutes=5)
    return json.dumps({
        "version": 1,
        "address": canonical_address(address),
        "token": token,
        "expiresAt": expires.isoformat(timespec="seconds").replace("+00:00", "Z"),
        "nonce": secrets.token_urlsafe(18),
    }, separators=(",", ":"))


def read_token(path: Path | None) -> str:
    if path is None:
        with warnings.catch_warnings():
            warnings.simplefilter("error", getpass.GetPassWarning)
            return getpass.getpass("FadedAI-token (skjult): ")
    if path.name.upper() != "PAIRING_TOKEN.TXT":
        raise PairingError("Vælg filen PAIRING_TOKEN.txt fra FadedAI’s outputmappe.")
    with path.open("rb") as file:
        data = file.read(1_025)
    if len(data) > 1_024:
        raise PairingError("Tokenfilen er for stor.")
    return data.decode("ascii").rstrip("\r\n")


def display_qr(qrcode, payload: str) -> None:
    qr = qrcode.QRCode(border=4)
    qr.add_data(payload)
    qr.make(fit=True)
    matrix = qr.get_matrix()
    width, height = shutil.get_terminal_size()
    if width <= len(matrix) or height < (len(matrix) + 1) // 2 + 2:
        raise PairingError("Gør terminalvinduet større eller zoom ud, og kør kommandoen igen.")

    blocks = {(False, False): " ", (True, False): "▀", (False, True): "▄", (True, True): "█"}
    if len(matrix) % 2:
        matrix.append([False] * len(matrix[0]))
    rows = [
        "".join(blocks[top, bottom] for top, bottom in zip(matrix[index], matrix[index + 1]))
        for index in range(0, len(matrix), 2)
    ]
    try:
        # Use an alternate screen so the token-bearing image stays out of terminal scrollback.
        sys.stdout.write("\x1b[?1049h\x1b[H")
        for row in rows:
            sys.stdout.write("\x1b[30;107m" + row + "\x1b[0m\n")
        sys.stdout.flush()
        input("Scan i FadedAI. Tryk Enter for at lukke QR-koden.")
    finally:
        sys.stdout.write("\x1b[0m\x1b[?1049l")
        sys.stdout.flush()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("address", help="PC’ens private LAN- eller Tailscale-IPv4-adresse")
    parser.add_argument("--token-file", type=Path, help="Sti til den eksisterende PAIRING_TOKEN.txt")
    args = parser.parse_args()
    if not sys.stdin.isatty() or not sys.stdout.isatty():
        print("Åbn værktøjet i en interaktiv Windows Terminal.", file=sys.stderr)
        return 2
    try:
        import qrcode
    except ImportError:
        print("Installér qrcode i Python-miljøet med python -m pip install qrcode.", file=sys.stderr)
        return 2

    try:
        address = canonical_address(args.address)
        token = read_token(args.token_file)
        display_qr(qrcode, pairing_payload(address, token))
    except (getpass.GetPassWarning, OSError, UnicodeError):
        print("Kunne ikke læse tokenet sikkert eller vise QR-koden. Brug Windows Terminal.", file=sys.stderr)
        return 2
    except PairingError as error:
        print(error, file=sys.stderr)
        return 2
    except (EOFError, KeyboardInterrupt):
        return 130
    return 0


if __name__ == "__main__":
    sys.exit(main())

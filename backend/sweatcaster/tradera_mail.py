"""Read an exact listing price from opted-in Tradera alerts in the owner's Gmail."""

import base64
import binascii
import re
from decimal import Decimal
from email.utils import getaddresses

from sweatcaster.composio_gmail import MESSAGES, MESSAGE_ID
from sweatcaster.dto import ApiError
from sweatcaster.mail_appointments import MailHTML
from sweatcaster.tradera_api import listing


DOMAIN = "notify.tradera.com"
WAIT = "Afventer en mail fra Tradera med annoncens link og en tydelig pris i SEK eller DKK."
LINK = re.compile(r"""https?://[^\s<>"']+""", re.I)
AMOUNT = r"(?:[1-9]\d{0,2}(?:[ .]\d{3})+|\d{1,9})(?:[,.]\d{1,2})?"
UNIT = r"(?:SEK|DKK)"
LABEL = (r"(?:køb nu(?:-pris)?|köp nu(?:-pris)?|buy (?:it )?now(?: price)?|"
         r"(?:aktuel|aktuell|ny|nyt) pris|(?:current|new) price|pris|price|"
         r"utropspris|startbud|starting bid|leading bid|current bid|högsta bud|ledande bud|højeste bud)")
PRICE_LINE = re.compile(rf"^\s*({LABEL})\s*[:–-]?\s*(?:({AMOUNT})\s*({UNIT})|({UNIT})\s*({AMOUNT}))\s*[.!]?\s*$",
                        re.I | re.M)
AMOUNTS = re.compile(rf"(?<![\w.,])(?:{AMOUNT}\s*(?:{UNIT}|kr\b|EUR|USD)|(?:{UNIT}|EUR|USD)\s*{AMOUNT})(?![\w.,])", re.I)
INACTIVE = re.compile(r"\b(?:solgt|udsolgt|såld|slutsåld|sold|afsluttet|avslutad|ended|"
                      r"annulleret|annullerad|cancelled|out of stock|ikke længere tilgængelig)\b", re.I)


def authenticated(message):
    payload = message.get("payload")
    headers = payload.get("headers") if isinstance(payload, dict) else None
    if not isinstance(headers, list):
        return False
    def values(name):
        return [row["value"] for row in headers if isinstance(row, dict) and isinstance(row.get("value"), str)
                and str(row.get("name", "")).lower() == name]
    sender = values("from")
    if len(sender) != 1:
        return False
    addresses = getaddresses(sender)
    if len(addresses) != 1 or not re.fullmatch(r"[^@\s<>]+@notify\.tradera\.com", addresses[0][1], re.I):
        return False
    results = values("authentication-results")
    if not results:
        return False
    checks = results[0].lower().split(";")
    return checks[0].strip() == "mx.google.com" and any(
        re.match(r"^\s*dmarc=pass\b", field) and re.search(r"\bheader\.from=notify\.tradera\.com(?:\s|$)", field)
        for field in checks[1:])


def body_text(payload):
    stack = [payload]
    texts = {"text/plain": [], "text/html": []}
    for _ in range(40):
        if not stack:
            break
        part = stack.pop()
        if not isinstance(part, dict) or part.get("filename"):
            continue
        children = part.get("parts", [])
        if not isinstance(children, list) or len(children) > 40:
            return ""
        stack.extend(reversed(children))
        mime = part.get("mimeType")
        if not isinstance(mime, str) or mime not in texts:
            continue
        body = part.get("body")
        encoded = body.get("data") if isinstance(body, dict) else None
        if not isinstance(encoded, str) or len(encoded) > 200_000:
            return ""
        try:
            raw = base64.b64decode(encoded + "=" * (-len(encoded) % 4), altchars=b"-_", validate=True).decode("utf-8")
        except (binascii.Error, UnicodeError, ValueError):
            return ""
        content = raw if mime == "text/plain" else "".join(MailHTML(raw, include_links=True).parts)
        texts[mime].append(content.replace("\xa0", " ").replace("\u202f", " "))
    if stack:
        return ""
    return "\n".join(texts["text/plain"] or texts["text/html"])


def quote_from_message(message, item_id, since, now):
    if not isinstance(message, dict) or not authenticated(message):
        return None
    stamp = str(message.get("internalDate", ""))
    if not re.fullmatch(r"\d{1,14}", stamp):
        return None
    received = int(stamp) / 1000
    if not since <= received <= now:
        return None
    text = body_text(message["payload"])
    items = set()
    for address in LINK.findall(text):
        try:
            number, _ = listing(address.rstrip(").,;!"))
            items.add(number)
        except ApiError:
            continue
    if item_id not in items:
        return None
    waiting = {"state": "waitingMail", "note": WAIT, "priceAt": received}
    if len(items) != 1:
        return waiting
    visible = LINK.sub("", text)
    if INACTIVE.search(visible):
        return waiting
    prices = set()
    for match in PRICE_LINE.finditer(visible):
        label, after, unit, before_unit, before = match.groups()
        value = (after or before).replace(" ", "")
        if re.fullmatch(r"\d{1,3}(?:\.\d{3})+(?:,\d{1,2})?", value):
            value = value.replace(".", "")
        prices.add((label.casefold(), Decimal(value.replace(",", ".")), (unit or before_unit).upper()))
    if len(prices) != 1 or AMOUNTS.search(PRICE_LINE.sub("", visible)):
        return waiting
    _, amount, currency = prices.pop()
    if not 0 < amount <= 999_999_999:
        return waiting
    return {"state": "watching", "price": amount, "priceCurrency": currency, "priceAt": received,
            "note": "Pris i Traderas mail. Tjek den aktuelle pris og fragt på annoncen."}


def account(library):
    return library.connection("gmail") if library else None


def check(library, pinned, item, since, now, threshold_currency, rate_source):
    if not pinned or account(library) != pinned:
        raise ApiError(409, "NOT_READY", "Forbind den Gmail-konto, du valgte til prisvagten.")
    query = f'from:(@{DOMAIN}) "{item}" after:{max(0, int(since) - 1)} -in:spam -in:trash'
    page = library.read("gmail", MESSAGES, {"q": query, "maxResults": 6}, account=pinned)
    ids = page.get("messages", []) if isinstance(page, dict) else None
    if not isinstance(ids, list):
        raise ApiError(502, "NOT_READY", "Gmail kunne ikke kontrollere Tradera-beskederne.")
    waiting = {"state": "waitingMail", "note": WAIT}
    if len(ids) > 6 or page.get("nextPageToken"):
        return waiting
    observations = []
    for row in ids:
        identifier = row.get("id") if isinstance(row, dict) else None
        if not isinstance(identifier, str) or not MESSAGE_ID.fullmatch(identifier):
            raise ApiError(502, "NOT_READY", "Gmail gav et ugyldigt svar.")
        endpoint = MESSAGES + "/" + identifier
        headers = library.read("gmail", endpoint, {"format": "metadata"}, account=pinned)
        if not isinstance(headers, dict) or headers.get("id") != identifier:
            raise ApiError(502, "NOT_READY", "Gmail kunne ikke bekræfte afsenderen.")
        if not authenticated(headers):
            continue
        message = library.read("gmail", endpoint, {"format": "full"}, account=pinned)
        if not isinstance(message, dict) or message.get("id") != identifier:
            raise ApiError(502, "NOT_READY", "Gmail kunne ikke bekræfte mailen.")
        result = quote_from_message(message, item, since, now)
        if result:
            observations.append(result)
    if not observations:
        return waiting
    newest = max(row["priceAt"] for row in observations)
    latest = [row for row in observations if row["priceAt"] == newest]
    result = latest[0]
    if any(row != result for row in latest):
        return dict(waiting, priceAt=newest)
    if result["state"] == "watching":
        price = result["price"]
        if result["priceCurrency"] != threshold_currency:
            rate = rate_source.dkk_per_sek()
            converted = price * rate if threshold_currency == "DKK" else price / rate
            result["compared"] = converted
            result["note"] += f" Ca. {converted:.2f} {threshold_currency} ved ECB-kurs."
        else:
            result["compared"] = price
        result["price"] = float(price)
    return result

"""Regression tests using synthetic Gmail API messages, without any external accounts."""

import base64
from decimal import Decimal
from types import SimpleNamespace

import pytest

from sweatcaster import tradera_mail as mail
from sweatcaster.dto import ApiError


ITEM = 987654
LINK = "https://www.tradera.com/da/item/12345/987654/cykel"
SINCE = 1_790_000_000
NOW = SINCE + 3600
AUTH = "mx.google.com; dkim=pass; dmarc=pass (p=reject) header.from=notify.tradera.com"


def part(content, mime="text/plain"):
    data = base64.urlsafe_b64encode(content.encode("utf-8")).decode("ascii").rstrip("=")
    return {"mimeType": mime, "body": {"data": data}}


def message(text, *, stamp=NOW-10, identifier="m1", mime="text/plain"):
    payload = part(text, mime)
    payload["headers"] = [
        {"name": "From", "value": "Tradera <avisering@notify.tradera.com>"},
        {"name": "Authentication-Results", "value": AUTH},
    ]
    return {"id": identifier, "internalDate": str(int(stamp*1000)), "payload": payload}


def quote(value):
    return mail.quote_from_message(value, ITEM, SINCE, NOW)


@pytest.mark.parametrize(("label", "expected", "currency"), [
    ("Köp nu: 85 SEK", "85", "SEK"),
    ("Aktuel pris: 1.299,95 DKK", "1299.95", "DKK"),
    ("Current price: DKK 410.75", "410.75", "DKK"),
    ("Högsta bud: 2\u00a0300 SEK", "2300", "SEK"),
])
def test_one_verified_price_for_exact_listing(label, expected, currency):
    data = message(LINK + "?utm_source=alerts\n" + label)
    row = quote(data)
    assert row["state"] == "watching"
    assert (row["price"], row["priceCurrency"], row["priceAt"]) == (Decimal(expected), currency, NOW - 10)


def test_html_only_button_and_text_ignore_hidden_script_and_other_attachments():
    data = message("", mime="multipart/mixed")
    data["payload"]["parts"] = [
        dict(part("Pris: 15 SEK"), filename="vedhaeftning.txt"),
        part(f'<p><a href="{LINK}">Vis annonce</a></p><p>Ny pris: 400 DKK</p>'
             '<script>Pris: 7 DKK</script>', "text/html"),
    ]
    assert quote(data)["price"] == Decimal("400")


@pytest.mark.parametrize("header,value", [
    ("From", "Tradera <avisering@notify.tradera.com.example.org>"),
    ("From", "avisering@messaging.tradera.com"),
    ("From", "avisering@notify.tradera.com, extra@example.org"),
    ("Authentication-Results", "mx.google.com; dmarc=fail header.from=notify.tradera.com"),
    ("Authentication-Results", "untrusted.example; dmarc=pass header.from=notify.tradera.com"),
    ("Authentication-Results", "mx.google.com; dmarc=pass header.from=example.org"),
])
def test_sender_and_gmail_authentication_must_match(header, value):
    data = message(LINK + "\nKöp nu: 50 SEK")
    for row in data["payload"]["headers"]:
        if row["name"] == header:
            row["value"] = value
    assert quote(data) is None


def test_snippet_date_and_attachment_are_not_trusted_sources():
    data = message("")
    data["snippet"] = LINK + "\nPrice: 15 SEK"
    assert quote(data) is None
    for when in [SINCE - 1, NOW + 1]:
        assert quote(message(data["snippet"], stamp=when)) is None
    data = message(data["snippet"])
    data["payload"]["body"]["data"] = "**invalid**"
    assert quote(data) is None


@pytest.mark.parametrize("address", [
    "https://www.tradera.com/da/item/12345/9876540/cykel",
    "https://www.tradera.com.example.org/da/item/12345/987654/cykel",
    "https://tracking.example/go?item=987654",
])
def test_matching_number_alone_never_identifies_the_listing(address):
    assert quote(message(address + "\nKöp nu: 30 SEK")) is None


@pytest.mark.parametrize("lines", [
    "Fragt: 35 SEK", "Aktuel pris: 100 kr", "Aktuel pris: 99 EUR",
    "Köp nu: 99 SEK\nStartbud: 10 SEK", "Pris: 90 SEK\nFragt: 40 SEK",
    "Tidligere pris: 400 DKK\nNy pris: 300 DKK", "Pris: 12,999 DKK",
    "Pris: 51 SEK\nhttps://tradera.com/item/12345/77777/vase",
])
def test_digest_fees_unknown_currency_and_ambiguous_values_require_waiting(lines):
    row = quote(message(LINK + "\n" + lines))
    assert row["state"] == "waitingMail"
    assert row.get("price") is None


class Mailbox:
    def __init__(self, rows, *, account="my-mail", more=False):
        self.rows = {row["id"]: row for row in rows}
        self.connected = account
        self.more = more
        self.fetched = []

    def connection(self, service):
        assert service == "gmail"
        return self.connected

    def read(self, service, endpoint, query, *, account):
        assert service == "gmail" and account == self.connected
        if endpoint == mail.MESSAGES:
            assert "notify.tradera.com" in query["q"] and str(ITEM) in query["q"]
            assert query["maxResults"] <= 10
            result = {"messages": [{"id": key} for key in self.rows]}
            if self.more:
                result["nextPageToken"] = "another-page"
            return result
        identifier = endpoint.removeprefix(mail.MESSAGES + "/")
        if query == {"format": "metadata"}:
            self.fetched.append((identifier, "metadata"))
            return {"id": identifier, "payload": {"headers": self.rows[identifier]["payload"]["headers"]}}
        assert query == {"format": "full"} and (identifier, "metadata") in self.fetched
        self.fetched.append((identifier, "full"))
        return self.rows[identifier]


def read(box, currency="SEK"):
    rate_source = SimpleNamespace(dkk_per_sek=lambda: Decimal("0.65"))
    return mail.check(box, "my-mail", ITEM, SINCE, NOW, currency, rate_source)


def test_read_uses_newest_verifiable_notification_and_converts_its_currency():
    new = message(LINK + "\nPris: 100 SEK", stamp=NOW-20, identifier="new")
    old = message(LINK + "\nPris: 79 SEK", stamp=NOW-40, identifier="old")
    assert read(Mailbox([new, old]), "DKK")["compared"] == Decimal("65")
    assert read(Mailbox([old, new]))["compared"] == Decimal("100")
    incomplete = message(LINK + "\nPris: 79 kr", stamp=NOW, identifier="unclear")
    assert read(Mailbox([incomplete, old]))["state"] == "waitingMail"


def test_ties_empty_results_and_wrong_accounts_do_not_make_a_price():
    first = message(LINK + "\nPris: 10 SEK", identifier="first")
    second = message(LINK + "\nPris: 100 SEK", identifier="second")
    assert read(Mailbox([first, second]))["state"] == "waitingMail"
    assert read(Mailbox([]))["state"] == "waitingMail"
    other = Mailbox([first], account="another-mail")
    with pytest.raises(ApiError):
        read(other)
    assert not other.fetched


def test_sender_verification_precedes_body_retrieval():
    data = message(LINK + "\nPris: 20 SEK", identifier="spoof")
    data["payload"]["headers"][0]["value"] = "example@example.org"
    box = Mailbox([data])
    assert read(box)["state"] == "waitingMail"
    assert box.fetched == [("spoof", "metadata")]

"""Import authenticated Tradera conversation notices for exactly the owner's linked listing."""

from datetime import datetime, timezone
import re
from uuid import NAMESPACE_URL, uuid5

from sweatcaster import tradera_mail
from sweatcaster.dto import ApiError
from sweatcaster.tradera_api import listing


def notices(library, case):
    consumer = library.gmail() if library else None
    if not consumer or consumer.account != case.get("mailAccount") or not case.get("itemID"):
        return []
    query = f'from:notify.tradera.com "{case["itemID"]}" after:{int(case["created"])} -in:spam -in:trash'
    existing = {message.get("mailID") for message in case["messages"]}
    output = []
    for summary in consumer.recent(query)[:8]:
        key = summary["id"]
        if key in existing or not re.search(r"meddelande|fråga|message|besked|erbjudande|tilbud|offer",
                                            summary.get("subject", ""), re.I):
            continue
        message = library.read_gmail_message(key, consumer)
        if not tradera_mail.authenticated(message):
            continue
        try:
            created = int(message.get("internalDate", "")) / 1000
        except (ValueError, TypeError):
            continue
        if not case["created"] <= created <= datetime.now(timezone.utc).timestamp():
            continue
        body = tradera_mail.body_text(message["payload"])
        numbers = set()
        for url in tradera_mail.LINK.findall(body):
            try:
                numbers.add(listing(url.rstrip(").,;!"))[0])
            except ApiError:
                continue
        if numbers != {case["itemID"]}:
            continue
        output.append({"id": str(uuid5(NAMESPACE_URL, case["id"] + ":" + consumer.account + ":" + key)),
                       "kind": "buyer", "text": body[:2_000], "buyer": "Tradera-besked",
                       "source": "gmail", "created": created, "mailID": key})
    return output

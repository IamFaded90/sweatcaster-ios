"""Read-only adoption of an already sent phone email into the existing case watcher."""
import base64
from email import policy
from email.parser import BytesParser
from email.utils import getaddresses
from hashlib import sha256
import json
from time import time
from uuid import NAMESPACE_URL, uuid5

from sweatcaster.dto import ApiError
from sweatcaster.agent_case_models import ADDRESS, MAIL_ID


def adopt(provider, case, body):
    message, thread = body.get("messageID"), body.get("threadID")
    recipient, owner = body.get("recipient"), body.get("ownerEmail")
    if (not isinstance(message, str) or not MAIL_ID.fullmatch(message)
            or not isinstance(thread, str) or not MAIL_ID.fullmatch(thread)
            or not isinstance(recipient, str) or not ADDRESS.fullmatch(recipient)
            or not isinstance(owner, str) or owner.lower() != provider.email.lower()):
        raise ApiError(409, "NOT_READY", "Gmail-kontoen, modtageren eller tråden kunne ikke bekræftes.")
    raw = provider.proxy("GET", "/messages/" + message, query={"format": "raw"})
    if raw.get("id") != message or raw.get("threadId") != thread or "SENT" not in raw.get("labelIds", []):
        raise ApiError(409, "NOT_READY", "Mailen findes ikke som sendt i den valgte Gmail-tråd.")
    encoded = raw.get("raw")
    if not isinstance(encoded, str) or len(encoded) > 1_800_000:
        raise ApiError(409, "NOT_READY", "Den sendte mail kunne ikke læses sikkert.")
    try:
        mime = BytesParser(policy=policy.default).parsebytes(base64.b64decode(encoded + "=" * (-len(encoded) % 4), altchars=b"-_", validate=True))
        senders, recipients = getaddresses(mime.get_all("From", [])), getaddresses(mime.get_all("To", []))
        if (len(senders) != 1 or senders[0][1].lower() != owner.lower()
                or len(recipients) != 1 or recipients[0][1].lower() != recipient.lower()
                or mime.get_all("Cc") or mime.get_all("Bcc")):
            raise ValueError
        part = mime.get_body(preferencelist=("plain",))
        text = part.get_content() if part else ""
        if not isinstance(text, str) or not text.strip() or len(text) > 12_000:
            raise ValueError
        subject = str(mime.get("Subject", "Uden emne"))
        if len(subject) > 350:
            raise ValueError
    except (ValueError, TypeError, AttributeError, UnicodeError) as exc:
        raise ApiError(409, "NOT_READY", "Gmail kunne ikke bekræfte den oprindelige afsender, modtager og tekst.") from exc
    outgoing = {"id": str(uuid5(NAMESPACE_URL, case["id"] + ":" + message)), "sender": provider.email,
                "recipient": recipient, "subject": subject, "body": text.strip(), "photos": [],
                "rfcID": str(mime.get("Message-ID", "")), "approvedAt": time(), "verified": True,
                "messageID": message, "threadID": thread, "verifiedAt": time()}
    outgoing["digest"] = sha256(json.dumps(outgoing, sort_keys=True).encode()).hexdigest()
    return outgoing

"""Send an opted-in notification only to the account currently connected to FadedAI."""

import json
from hashlib import sha256

from sweatcaster.composio_gmail import PROFILE
from sweatcaster.composio_library import GMAIL_ADDRESS
from sweatcaster.dto import ApiError


def send_owner_notice(library, token, subject, text):
    """A failed preflight can be retried. An uncertain delivery is never replayed."""
    try:
        consumer = library.require_gmail()
        profile = consumer.read(PROFILE)
        owner = profile.get("emailAddress") if isinstance(profile, dict) else None
        if not isinstance(owner, str) or len(owner) > 254 or not GMAIL_ADDRESS.fullmatch(owner):
            return "unavailable"
    except (ApiError, OSError, ValueError):
        return "unavailable"
    identifier = library.gmail_send_id(str(token))
    digest = sha256(json.dumps([consumer.account, owner, subject, text], ensure_ascii=False).encode()).hexdigest()
    try:
        # Reuse the durable Gmail outbox, with the same consumer whose own profile was read above.
        library.deliver_gmail(identifier, digest, lambda: consumer.send(owner, subject, text), {"sent": True})
        return "sent"
    except (ApiError, OSError, ValueError):
        return "uncertain"

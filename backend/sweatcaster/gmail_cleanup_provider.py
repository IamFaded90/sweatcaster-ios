"""Narrow Composio adapter: metadata and reversible Gmail label changes only."""

from contextlib import contextmanager
from hashlib import sha256
import json
import re

import requests

from sweatcaster.dto import ApiError


MESSAGE = re.compile(r"[0-9a-fA-F]{1,128}")
MODIFY = "GMAIL_ADD_LABEL_TO_EMAIL"


class CleanupGmail:
    def __init__(self, consumer):
        self.consumer = consumer
        self.session = None
        self.tool_session = None
        profile = consumer._execute("GMAIL_GET_PROFILE", {"user_id": "me"})
        email = profile.get("emailAddress") or profile.get("email_address")
        if not isinstance(email, str) or "@" not in email:
            raise ApiError(502, "NOT_READY", "Gmail-kontoen kunne ikke bekræftes.")
        self.account = sha256((consumer.account + ":" + email.strip().lower()).encode()).hexdigest()

    @contextmanager
    def connected(self):
        # Discovery never receives mail subjects, bodies, search strings or account secrets.
        try:
            with self.consumer.session() as session:
                result = self.consumer._call(session, "COMPOSIO_SEARCH_TOOLS", {
                    "queries": [{"use_case": "Gmail GMAIL_ADD_LABEL_TO_EMAIL add and remove labels on one existing message"}],
                    "session": {"generate_id": True},
                }, 2)
                data = result.get("data", {})
                schemas = data.get("tool_schemas", {})
                properties = schemas.get(MODIFY, {}).get("input_schema", {}).get("properties", {})
                if not {"message_id", "add_label_ids", "remove_label_ids"} <= properties.keys():
                    raise ApiError(409, "NOT_READY", "Composio skal give Gmail adgang til at ændre etiketter først.")
                self.session, self.tool_session = session, data["session"]["id"]
                try:
                    yield self
                finally:
                    self.session = self.tool_session = None
        except (requests.RequestException, ValueError, KeyError, TypeError, AttributeError) as exc:
            raise ApiError(502, "NOT_READY", "Gmail-forbindelsen kunne ikke bekræfte værktøjet til oprydning.") from exc

    def list(self, query, limit):
        data = self.consumer._execute("GMAIL_FETCH_EMAILS", {
            "user_id": "me", "query": query, "max_results": limit, "only_ids": True,
        })
        return {"ids": [row.get("messageId") or row.get("id") for row in data.get("messages", [])
                        if isinstance(row, dict)], "more": bool(data.get("nextPageToken"))}

    def read(self, identifier):
        if not isinstance(identifier, str) or not MESSAGE.fullmatch(identifier):
            raise ApiError(422, "INVALID_INPUT", "Mailens ID er ugyldigt.")
        data = self.consumer._execute("GMAIL_FETCH_MESSAGE_BY_MESSAGE_ID", {
            "user_id": "me", "message_id": identifier, "format": "metadata",
        })
        actual = data.get("messageId") or data.get("id")
        labels = data.get("labelIds", data.get("label_ids"))
        if actual != identifier or not isinstance(labels, list) or any(not isinstance(v, str) for v in labels):
            raise ApiError(502, "NOT_READY", "Gmail kunne ikke bekræfte mailens etiketter. Den bliver ikke ændret.")
        payload = data.get("payload")
        raw_headers = payload.get("headers", []) if isinstance(payload, dict) else []
        headers = {str(v.get("name", "")).lower(): str(v.get("value", ""))
                   for v in raw_headers if isinstance(v, dict)} if isinstance(raw_headers, list) else {}
        return {"id": identifier, "labels": sorted(set(labels)),
                "subject": str(data.get("subject") or headers.get("subject") or "Uden emne")[:350],
                "sender": str(data.get("sender") or headers.get("from") or "Ukendt afsender")[:300]}

    def modify(self, identifier, add, remove):
        if not MESSAGE.fullmatch(identifier) or not set(add + remove) <= {"INBOX", "TRASH"} or set(add) & set(remove):
            raise ApiError(422, "INVALID_INPUT", "Kun arkivering og papirkurv understøttes.")
        if self.session is None:
            raise ApiError(409, "NOT_READY", "Gmail-oprydning er ikke klar.")
        try:
            result = self.consumer._call(self.session, "COMPOSIO_MULTI_EXECUTE_TOOL", {
                "session_id": self.tool_session, "sync_response_to_workbench": False,
                "tools": [{"tool_slug": MODIFY, "arguments": {
                    "user_id": "me", "message_id": identifier,
                    "add_label_ids": add, "remove_label_ids": remove,
                }}],
            }, 3)
            detail = json.dumps(result.get("error") or result.get("data", {}).get("results", []))[:8000]
            if re.search(r"insufficient.*(?:scope|permission)|insufficientPermissions|insufficient_scope|forbidden|PERMISSION_DENIED", detail, re.I):
                raise ApiError(403, "NOT_READY", "Gmail mangler tilladelse til at ændre mails. Forbind Gmail igen i Composio og godkend adgang til oprydning.")
            rows = result["data"]["results"]
            if not result.get("successful") or len(rows) != 1 or rows[0].get("tool_slug") != MODIFY or \
                    not rows[0].get("response", {}).get("successful"):
                raise ValueError("Unconfirmed Gmail label operation")
        except (requests.RequestException, ValueError, KeyError, TypeError, AttributeError) as exc:
            # Caller always performs readback, including after a timeout.
            raise ApiError(502, "NOT_READY", "Gmail svarede ikke sikkert. Mailens status bliver kontrolleret.") from exc

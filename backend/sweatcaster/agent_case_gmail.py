"""Fixed Gmail MIME operations through the owner's existing Composio connection."""

import base64
from email import policy
from email.message import EmailMessage
from email.parser import BytesParser
from email.utils import getaddresses
from hashlib import sha256
import re

import requests

from sweatcaster.dto import ApiError
from sweatcaster.agent_case_models import ADDRESS, MAIL_ID


BASE = "https://gmail.googleapis.com/gmail/v1/users/me"


class GmailRejected(ApiError):
    """An explicit provider 4xx proves the send was rejected before acceptance."""


def unpack(result):
    data = result.get("data", {}) if isinstance(result, dict) else {}
    if isinstance(data, dict) and data.get("status") in (400, 401, 403, 404, 422):
        raise GmailRejected(data["status"], "NOT_READY", "Gmail afviste handlingen. Tjek mailadressen og forbindelsens Gmail-tilladelser i Composio.")
    if result.get("successful") is not True or not isinstance(data, dict) or data.get("status") not in (200, 201, 202):
        raise ApiError(502, "NOT_READY", "Gmail kunne ikke bekræfte handlingen gennem Composio.")
    value = data.get("data")
    if not isinstance(value, dict):
        raise ApiError(502, "NOT_READY", "Gmail gav et uventet svar.")
    return value


class CaseGmail:
    def __init__(self, library):
        self.consumer = library.require_gmail()
        profile = self.consumer._execute("GMAIL_GET_PROFILE", {"user_id": "me"})
        self.email = profile.get("emailAddress") or profile.get("email_address")
        if not isinstance(self.email, str) or not ADDRESS.fullmatch(self.email):
            raise ApiError(502, "NOT_READY", "Gmail-kontoens identitet kunne ikke bekræftes.")
        self.account = sha256(self.email.lower().encode()).hexdigest()

    def proxy(self, method, path, *, body=None, query=None):
        allowed = ((method == "GET" and (path == "/messages" or re.fullmatch(r"/(?:messages|threads)/[0-9a-fA-F]{1,128}", path)))
                   or (method == "POST" and path == "/messages/send"))
        if not allowed:
            raise ValueError("Case Gmail endpoint not allowed")
        args = {"toolkit_slug": "gmail", "endpoint": BASE + path, "method": method}
        if body is not None:
            args["body"] = body
        if query:
            args["parameters"] = [{"name": name, "value": str(value), "type": "query"} for name, value in query.items()]
        try:
            with self.consumer.session() as session:
                return unpack(self.consumer._call(session, "COMPOSIO_PROXY_EXECUTE", args, 2))
        except (requests.RequestException, ValueError, AttributeError, KeyError, TypeError) as exc:
            raise ApiError(502, "NOT_READY", "Gmail-forbindelsen blev afbrudt. Tjek sagens status før du gør mere.") from exc

    def receipts(self, query):
        return self.consumer.recent(query)

    def receipt(self, key):
        from sweatcaster.mail_appointments import mail_text
        if not isinstance(key, str) or not MAIL_ID.fullmatch(key):
            raise ApiError(422, "INVALID_INPUT", "Vælg en kvitteringsmail fra listen.")
        mail = self.proxy("GET", "/messages/" + key, query={"format": "full"})
        if mail.get("id") != key:
            raise ApiError(502, "NOT_READY", "Gmail kunne ikke bekræfte kvitteringsmailen.")
        headers = {str(v.get("name", "")).lower(): str(v.get("value", ""))
                   for v in (mail.get("payload") or {}).get("headers", []) if isinstance(v, dict)}
        addresses = getaddresses([headers.get("reply-to") or headers.get("from", "")])
        recipient = addresses[0][1] if len(addresses) == 1 else ""
        return {"id": key, "threadID": mail.get("threadId"), "subject": headers.get("subject", "Uden emne")[:350],
                "sender": headers.get("from", "Ukendt afsender")[:300], "text": mail_text(mail, allow_snippet=False)[:6000],
                "suggestedRecipient": recipient if ADDRESS.fullmatch(recipient) else ""}

    def send(self, outgoing, photos):
        mail = EmailMessage(policy=policy.SMTP)
        mail["From"], mail["To"] = self.email, outgoing["recipient"]
        mail["Subject"], mail["Message-ID"] = outgoing["subject"], outgoing["rfcID"]
        mail.set_content(outgoing["body"], subtype="plain", charset="utf-8")
        for descriptor, data in photos:
            mail.add_attachment(data, maintype="image", subtype="jpeg", filename=descriptor["name"])
        return self.proxy("POST", "/messages/send", body={"raw": base64.urlsafe_b64encode(mail.as_bytes()).decode()})

    def find_sent(self, outgoing):
        query = "in:sent rfc822msgid:" + outgoing["rfcID"].strip("<>")
        value = self.proxy("GET", "/messages", query={"q": query, "maxResults": 3})
        rows = value.get("messages", [])
        return [v["id"] for v in rows if isinstance(v, dict) and isinstance(v.get("id"), str) and MAIL_ID.fullmatch(v["id"])]

    def verify(self, key, outgoing):
        if not isinstance(key, str) or not MAIL_ID.fullmatch(key):
            return None
        actual = self.proxy("GET", "/messages/" + key, query={"format": "raw"})
        if (actual.get("id") != key or "SENT" not in actual.get("labelIds", [])
                or not isinstance(actual.get("threadId"), str) or not MAIL_ID.fullmatch(actual["threadId"])):
            return None
        raw = actual.get("raw")
        if not isinstance(raw, str) or len(raw) > 1_800_000:
            return None
        try:
            mime = BytesParser(policy=policy.default).parsebytes(base64.b64decode(raw + "=" * (-len(raw) % 4), altchars=b"-_", validate=True))
            recipients = getaddresses(mime.get_all("To", []))
            senders = getaddresses(mime.get_all("From", []))
            body = mime.get_body(preferencelist=("plain",))
            normalize = lambda v: v.replace("\r\n", "\n").strip()
            attachments = [{"name": part.get_filename(), "sha256": sha256(part.get_payload(decode=True)).hexdigest()}
                           for part in mime.iter_attachments()]
            expected = [{"name": p["name"], "sha256": p["sha256"]} for p in outgoing["photos"]]
            if (len(recipients) != 1 or recipients[0][1].casefold() != outgoing["recipient"].casefold()
                    or len(senders) != 1 or senders[0][1].casefold() != self.email.casefold()
                    or str(mime.get("Message-ID", "")).strip() != outgoing["rfcID"] or str(mime.get("Subject")) != outgoing["subject"]
                    or mime.get_all("Cc") or mime.get_all("Bcc") or body is None
                    or normalize(body.get_content()) != normalize(outgoing["body"]) or attachments != expected):
                return None
        except (ValueError, TypeError, AttributeError, UnicodeError):
            return None
        return {"messageID": key, "threadID": actual["threadId"]}

    def followup(self, thread, sent):
        if not MAIL_ID.fullmatch(thread) or not MAIL_ID.fullmatch(sent):
            raise ApiError(422, "INVALID_INPUT", "Sagens Gmail-tråd kunne ikke bekræftes.")
        data = self.proxy("GET", "/threads/" + thread, query={"format": "metadata"})
        rows = data.get("messages", [])
        original = next((r for r in rows if isinstance(r, dict) and r.get("id") == sent), None)
        if data.get("id") != thread or not original or not str(original.get("internalDate", "")).isdigit():
            return {"state": "unknown", "messages": []}
        stamp = int(original["internalDate"])
        incoming, incomplete = [], False
        for row in rows:
            if not isinstance(row, dict) or not isinstance(row.get("labelIds"), list) or not str(row.get("internalDate", "")).isdigit():
                incomplete = True
                continue
            if (row.get("threadId") != thread or int(row["internalDate"]) <= stamp
                    or {"SENT", "DRAFT", "TRASH", "SPAM"}.intersection(row["labelIds"])):
                continue
            if not isinstance(row.get("id"), str) or not MAIL_ID.fullmatch(row["id"]):
                incomplete = True
                continue
            from sweatcaster.mail_appointments import mail_text
            full = self.proxy("GET", "/messages/" + row["id"], query={"format": "full"})
            if full.get("id") != row["id"] or full.get("threadId") != thread:
                incomplete = True
                continue
            headers = {str(h.get("name", "")).lower(): str(h.get("value", ""))
                       for h in (full.get("payload") or {}).get("headers", []) if isinstance(h, dict)}
            incoming.append({"id": row["id"], "sender": headers.get("from", "Ukendt afsender")[:300],
                             "subject": headers.get("subject", "Uden emne")[:350],
                             "text": mail_text(full, allow_snippet=False)[:6000], "created": int(row["internalDate"]) / 1000})
        return {"state": "received" if incoming else "unknown" if incomplete else "waiting", "messages": incoming[-20:]}

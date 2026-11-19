"""Use the owner's existing Composio For You Gmail connection."""

from __future__ import annotations

import json
import re
from concurrent.futures import ThreadPoolExecutor
from contextlib import contextmanager
from datetime import datetime, timezone
from email.utils import parsedate_to_datetime
from hashlib import sha256

import requests

from sweatcaster.dto import ApiError


ENDPOINT = "https://connect.composio.dev/mcp"
MESSAGES = "https://gmail.googleapis.com/gmail/v1/users/me/messages"
PROFILE = "https://gmail.googleapis.com/gmail/v1/users/me/profile"
THREADS = "https://gmail.googleapis.com/gmail/v1/users/me/threads"
MESSAGE_ID = re.compile(r"[A-Za-z0-9_-]{1,128}")
PROTOCOL = "2025-03-26"
CAP = 2_000_000
GMAIL_USE_CASES = {
    "GMAIL_REPLY_TO_THREAD": "Reply to an existing Gmail thread with a reviewed plain-text message",
    "GMAIL_FETCH_MESSAGE_BY_THREAD_ID": "Fetch messages in one existing Gmail thread by thread ID",
}
READ_ONLY_USE_CASES = {
    "GOOGLECALENDAR_LIST_CALENDARS": "Google Calendar GOOGLECALENDAR_LIST_CALENDARS list my calendars",
    "YOUTUBE_LIST_CHANNELS": "YouTube YOUTUBE_LIST_CHANNELS list my YouTube channels",
}


def _timestamp(value):
    if not isinstance(value, str):
        return None
    if value.isdecimal() and 10 <= len(value) <= 14:
        return value if len(value) > 10 else str(int(value) * 1_000)
    try:
        date = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        try:
            date = parsedate_to_datetime(value)
        except (TypeError, ValueError):
            return None
    if date.tzinfo is None:
        date = date.replace(tzinfo=timezone.utc)
    return str(int(date.timestamp() * 1_000))


class ConsumerGmail:
    def __init__(self, key: str):
        self.key = key

    @property
    def account(self) -> str:
        return "gmail-for-you:" + sha256(self.key.encode()).hexdigest()

    @contextmanager
    def session(self):
        with requests.Session() as session:
            session.trust_env = False
            session.headers.update({"x-consumer-api-key": self.key, "Accept": "application/json, text/event-stream"})
            result = self._rpc(session, "initialize", {
                "protocolVersion": PROTOCOL, "capabilities": {}, "clientInfo": {"name": "FadedAI", "version": "1.0"},
            }, 1)
            protocol = result["protocolVersion"]
            if not isinstance(protocol, str) or not re.fullmatch(r"20[0-9]{2}-[0-9]{2}-[0-9]{2}", protocol):
                raise ValueError("Invalid MCP protocol")
            session.headers["MCP-Protocol-Version"] = protocol
            self._rpc(session, "notifications/initialized", {})
            yield session

    def connection_statuses(self, services):
        def batch(entries):
            try:
                with self.session() as session:
                    result = self._call(session, "COMPOSIO_SEARCH_TOOLS", {
                        "queries": [{"use_case": f"For {title} ({slug}), discover a read-only metadata tool and check connection status."}
                                    for slug, title in entries],
                        "session": {"generate_id": True},
                    }, 2)
                    rows = result.get("data", {}).get("toolkit_connection_statuses", [])
                    expected = dict(entries)
                    return {row["toolkit"]: row["has_active_connection"] for row in rows
                            if isinstance(row, dict) and row.get("toolkit") in expected
                            and isinstance(row.get("has_active_connection"), bool)}
            except (requests.RequestException, ValueError, KeyError, AttributeError, StopIteration, TypeError):
                return {}

        entries = list(services.items())
        with ThreadPoolExecutor(max_workers=4) as pool:
            return {key: state for result in pool.map(batch, (entries[i:i + 5] for i in range(0, len(entries), 5)))
                    for key, state in result.items()}

    @staticmethod
    def _rpc(session, method, params, identifier=None):
        body = {"jsonrpc": "2.0", "method": method, "params": params}
        if identifier is not None:
            body["id"] = identifier
        with session.post(ENDPOINT, json=body, stream=True, allow_redirects=False, timeout=(5, 25)) as response:
            if response.status_code not in (200, 202):
                raise ValueError("Composio MCP refused request")
            session_id = response.headers.get("Mcp-Session-Id")
            if session_id and re.fullmatch(r"[!-~]{1,512}", session_id):
                session.headers["Mcp-Session-Id"] = session_id
            if identifier is None:
                return {}
            data = bytearray()
            if "text/event-stream" in response.headers.get("Content-Type", ""):
                consumed = 0
                for line in response.iter_lines(chunk_size=256):
                    consumed += len(line) + 1
                    if consumed > CAP:
                        raise ValueError("Composio response too large")
                    if line.startswith(b"data:"):
                        data.extend(line[5:].lstrip() + b"\n")
                    elif not line and data:
                        entry = json.loads(data)
                        data.clear()
                        if isinstance(entry, dict) and entry.get("id") == identifier:
                            return entry["result"]
                raise ValueError("Composio response missing")
            for chunk in response.iter_content(8192):
                data.extend(chunk)
                if len(data) > CAP:
                    raise ValueError("Composio response too large")
            entry = json.loads(data)
            if not isinstance(entry, dict) or entry.get("id") != identifier:
                raise ValueError("Invalid Composio response")
            return entry["result"]

    @classmethod
    def _call(cls, session, name, arguments, identifier):
        result = cls._rpc(session, "tools/call", {"name": name, "arguments": arguments}, identifier)
        if result.get("isError"):
            raise ValueError("Composio tool call failed")
        structured = result.get("structuredContent")
        if isinstance(structured, dict):
            return structured
        content = next(row["text"] for row in result["content"] if row.get("type") == "text")
        return json.loads(content)

    def _execute(self, slug, arguments):
        if slug not in {"GMAIL_GET_PROFILE", "GMAIL_FETCH_EMAILS", "GMAIL_FETCH_MESSAGE_BY_MESSAGE_ID",
                        "GMAIL_SEND_EMAIL", *GMAIL_USE_CASES, *READ_ONLY_USE_CASES}:
            raise ValueError("Unsupported Gmail action")
        try:
            with self.session() as session:
                # Discover using fixed text. Gmail messages and drafts never enter the discovery prompt.
                use_case = READ_ONLY_USE_CASES.get(slug) or GMAIL_USE_CASES.get(slug,
                    "Gmail profile, list email by query, fetch a message by ID, and send a reviewed plain email")
                search = self._call(session, "COMPOSIO_SEARCH_TOOLS", {
                    "queries": [{"use_case": use_case}],
                    "session": {"generate_id": True},
                }, 2)
                query_session = search["data"]["session"]["id"]
                if slug in READ_ONLY_USE_CASES and slug not in search["data"].get("tool_schemas", {}):
                    raise ValueError("Read-only tool not available")
                result = self._call(session, "COMPOSIO_MULTI_EXECUTE_TOOL", {
                    "session_id": query_session, "sync_response_to_workbench": False,
                    "tools": [{"tool_slug": slug, "arguments": arguments}],
                }, 3)
                rows = result["data"]["results"]
                if not result.get("successful") or len(rows) != 1 or rows[0].get("tool_slug") != slug:
                    raise ValueError("Gmail action did not complete")
                response = rows[0]["response"]
                data = response.get("data")
                # Composio may return an inline preview for a large Gmail message.
                if slug == "GMAIL_FETCH_MESSAGE_BY_MESSAGE_ID" and not isinstance(data, dict):
                    data = response.get("data_preview")
                if not response.get("successful") or not isinstance(data, dict):
                    raise ValueError("Unexpected Gmail action result")
                return data
        except (requests.RequestException, ValueError, KeyError, AttributeError, StopIteration, TypeError) as exc:
            title = "Forbindelsen" if slug in READ_ONLY_USE_CASES else "Gmail"
            raise ApiError(502, "NOT_READY", f"{title} svarede ikke som forventet gennem Composio For You.") from exc

    def list_calendars(self):
        return self._execute("GOOGLECALENDAR_LIST_CALENDARS", {"max_results": 15})

    def list_youtube_channels(self):
        return self._execute("YOUTUBE_LIST_CHANNELS", {"mine": True, "part": "snippet", "max_results": 15})

    def read(self, endpoint, query=None):
        query = query or {}
        if endpoint == PROFILE:
            return self._execute("GMAIL_GET_PROFILE", {"user_id": "me"})
        if endpoint == MESSAGES:
            args = {"user_id": "me", "query": query.get("q", ""), "only_ids": True,
                    "max_results": min(40, max(1, int(query.get("maxResults", 20))))}
            if query.get("pageToken"):
                args["page_token"] = query["pageToken"]
            data = self._execute("GMAIL_FETCH_EMAILS", args)
            rows = data.get("messages") or []
            messages = []
            for row in rows[:40]:
                if isinstance(row, dict) and isinstance(identifier := row.get("messageId") or row.get("id"), str):
                    if MESSAGE_ID.fullmatch(identifier):
                        item = {"id": identifier}
                        thread = row.get("threadId")
                        if isinstance(thread, str) and MESSAGE_ID.fullmatch(thread):
                            item["threadId"] = thread
                        messages.append(item)
            return {"messages": messages, "nextPageToken": data.get("nextPageToken")}
        if endpoint.startswith(MESSAGES + "/") and MESSAGE_ID.fullmatch(identifier := endpoint.removeprefix(MESSAGES + "/")):
            message_format = "metadata" if query.get("format") == "metadata" else "full"
            data = self._execute("GMAIL_FETCH_MESSAGE_BY_MESSAGE_ID",
                                 {"user_id": "me", "message_id": identifier, "format": message_format})
            return {"id": data.get("messageId") or data.get("id"), "threadId": data.get("threadId"),
                    "internalDate": data.get("internalDate") or _timestamp(data.get("messageTimestamp")),
                    "snippet": data.get("messageText") or data.get("snippet"),
                    "to": data.get("to") or data.get("recipientEmail"), "cc": data.get("cc"),
                    "payload": data.get("payload"), "sender": data.get("sender"), "subject": data.get("subject")}
        if endpoint.startswith(THREADS + "/") and MESSAGE_ID.fullmatch(identifier := endpoint.removeprefix(THREADS + "/")):
            data = self._execute("GMAIL_FETCH_MESSAGE_BY_THREAD_ID", {"user_id": "me", "thread_id": identifier})
            rows = data.get("messages")
            if not isinstance(rows, list) or data.get("nextPageToken") or len(rows) > 50:
                raise ApiError(502, "NOT_READY", "Hele Gmail-tråden kunne ikke kontrolleres.")
            messages = []
            for row in rows:
                if not isinstance(row, dict) or row.get("threadId", identifier) != identifier:
                    raise ApiError(502, "NOT_READY", "Gmail-tråden kunne ikke bekræftes.")
                stamp = row.get("internalDate") or row.get("messageTimestamp")
                messages.append({**row, "id": row.get("messageId") or row.get("id"), "threadId": identifier,
                                 "internalDate": _timestamp(str(stamp) if type(stamp) is int else stamp)})
            return {"id": identifier, "messages": messages}
        raise ApiError(422, "INVALID_INPUT", "Gmail-opslaget understøttes ikke.")

    def recent(self, query):
        data = self._execute("GMAIL_FETCH_EMAILS", {
            "user_id": "me", "query": query or "in:inbox newer_than:30d", "max_results": 12,
            "include_payload": False, "verbose": False,
        })
        entries = []
        for row in (data.get("messages") or [])[:12]:
            if not isinstance(row, dict) or not isinstance(identifier := row.get("messageId"), str):
                continue
            if MESSAGE_ID.fullmatch(identifier):
                entry = {"id": identifier, "sender": str(row.get("sender") or "")[:300],
                         "subject": str(row.get("subject") or "")[:350],
                         "timestamp": str(row.get("messageTimestamp") or "")[:64]}
                if isinstance(thread := row.get("threadId"), str) and MESSAGE_ID.fullmatch(thread):
                    entry["threadID"] = thread
                entries.append(entry)
        return entries

    def send(self, recipient, subject, body):
        return self._execute("GMAIL_SEND_EMAIL", {"user_id": "me", "recipient_email": recipient,
                                                 "subject": subject, "body": body})

    def reply(self, thread_id, recipient, body):
        return self._execute("GMAIL_REPLY_TO_THREAD", {"user_id": "me", "thread_id": thread_id,
                                                       "recipient_email": recipient, "message_body": body})

    def newer_reply(self, thread_id, message_id):
        data = self._execute("GMAIL_FETCH_MESSAGE_BY_THREAD_ID", {"user_id": "me", "thread_id": thread_id})
        rows = [row for row in (data.get("messages") or []) if isinstance(row, dict)]

        def stamp(row):
            value = row.get("internalDate") or row.get("messageTimestamp")
            return int(_timestamp(str(value) if type(value) is int else value) or 0)

        original = next((row for row in rows if (row.get("messageId") or row.get("id")) == message_id), None)
        sent_at = stamp(original) if original else 0
        incoming = [row for row in rows if sent_at and stamp(row) > sent_at
                    and isinstance(labels := row.get("labelIds"), list)
                    and all(isinstance(label, str) for label in labels)
                    and not {"SENT", "DRAFT", "TRASH", "SPAM"}.intersection(labels)]
        if incoming:
            latest = max(incoming, key=stamp)
            return {"state": "received", "subject": str(latest.get("subject") or "Uden emne")[:350],
                    "sender": str(latest.get("sender") or "")[:300], "timestamp": stamp(latest) / 1_000}
        incomplete = (not sent_at or data.get("nextPageToken")
                      or any(not stamp(row) or (stamp(row) >= sent_at and not isinstance(row.get("labelIds"), list))
                             for row in rows))
        return {"state": "unknown" if incomplete else "waiting"}

import base64
from datetime import datetime, timedelta
from unittest.mock import patch
from zoneinfo import ZoneInfo

from fastapi import FastAPI, HTTPException
from fastapi.responses import JSONResponse
from fastapi.testclient import TestClient

from sweatcaster import mail_reschedule as change
from sweatcaster.composio_gmail import ConsumerGmail


ZONE = ZoneInfo("Europe/Copenhagen")
NOW = datetime(2026, 11, 19, 13, tzinfo=ZONE)
TEXT = "Din aftale er flyttet fra 23.11.2026 kl. 09:00 til 26.11.2026 kl. 10:00–10:35."


def mail(text, identifier="message_1", *, later=0, labels=None):
    return {"id": identifier, "threadId": "thread_1", "labelIds": labels if labels is not None else ["INBOX"],
            "internalDate": str(int((NOW + timedelta(minutes=later)).timestamp() * 1_000)),
            "payload": {"mimeType": "text/plain", "headers": [
                {"name": "Subject", "value": "Tandlæge · Flyttet aftale"},
                {"name": "From", "value": "Tandklinik <clinic@example.test>"},
            ], "body": {"data": base64.urlsafe_b64encode(text.encode()).decode()}}}


def test_dates_must_be_grounded_in_current_visible_text():
    result = change.reschedule(mail(TEXT), "thread_1", ZONE, NOW)
    assert result["oldStart"] == datetime(2026, 11, 23, 9, tzinfo=ZONE).timestamp()
    assert result["start"] == datetime(2026, 11, 26, 10, tzinfo=ZONE).timestamp()
    assert result["end"] == datetime(2026, 11, 26, 10, 35, tzinfo=ZONE).timestamp()
    assert result["quote"] == TEXT and result["sender"] == "Tandklinik"
    assert change.reschedule(mail("Hvis " + TEXT), "thread_1", ZONE, NOW) is None
    assert change.reschedule(mail(TEXT + "\nAlternativ 27.11.2026 kl. 11:00"), "thread_1", ZONE, NOW) is None
    assert change.reschedule(mail("Hej\n\nDen 18 november skrev du:\n" + TEXT), "thread_1", ZONE, NOW) is None


def test_stale_or_cancelled_change_is_removed_by_thread_reread():
    class Gmail:
        account = "linked"
        newest = mail("Tak", "reply", later=10, labels=["SENT"])

        def connection(self, service):
            assert service == "gmail"
            return self.account

        def read(self, service, url, query, *, account):
            assert service == "gmail" and account == self.account
            if url == change.GMAIL:
                assert "tandklinik" in query["q"]
                return {"messages": [{"id": "message_1"}]}
            if url.endswith("/messages/message_1"):
                return {"id": "message_1", "threadId": "thread_1"}
            assert url == change.THREADS + "/thread_1"
            return {"id": "thread_1", "messages": [self.newest, mail(TEXT)]}

    gmail = Gmail()
    app = FastAPI()

    @app.exception_handler(change.ApiError)
    def error(_, failure):
        return JSONResponse(status_code=failure.status_code, content={"error": failure.code})

    def paired(request, _):
        if request.headers.get("Authorization") != "Bearer fixture":
            raise HTTPException(401)

    change.register_mail_reschedule(app, None, paired, gmail)
    with patch.object(change, "datetime", wraps=datetime) as clock, TestClient(app) as client:
        clock.now.return_value = NOW
        payload = {"zone": "Europe/Copenhagen", "query": "tandlægen"}
        assert client.put(change.PATH, json=payload).status_code == 401
        headers = {"Authorization": "Bearer fixture"}
        result = client.put(change.PATH, json=payload, headers=headers)
        assert result.status_code == 200 and result.headers["Cache-Control"] == "no-store"
        assert result.json()["changes"][0]["id"] == "message_1"
        gmail.newest = mail("Din aftale er aflyst.", "cancelled", later=20)
        result = client.put(change.PATH, json=dict(payload, thread="thread_1"), headers=headers)
        assert result.json() == {"changes": []}


def test_consumer_adapter_uses_real_thread_shape_and_rejects_incomplete_thread():
    consumer = ConsumerGmail("fixture")

    def execution(slug, arguments):
        assert slug == "GMAIL_FETCH_MESSAGE_BY_THREAD_ID"
        assert arguments == {"user_id": "me", "thread_id": "thread_1"}
        row = mail(TEXT)
        row["messageId"] = row.pop("id")
        row["messageTimestamp"] = NOW.isoformat()
        row.pop("internalDate")
        return {"messages": [row]}

    with patch.object(consumer, "_execute", side_effect=execution):
        result = consumer.read(change.THREADS + "/thread_1")
        assert result["messages"][0]["id"] == "message_1"
        assert change.reschedule(result["messages"][0], "thread_1", ZONE, NOW)
    with patch.object(consumer, "_execute", return_value={"messages": [], "nextPageToken": "more"}):
        try:
            consumer.read(change.THREADS + "/thread_1")
        except change.ApiError as error:
            assert error.status_code == 502
        else:
            raise AssertionError("An incomplete thread cannot establish the latest appointment")

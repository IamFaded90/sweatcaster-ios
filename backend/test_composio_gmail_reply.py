from uuid import uuid4

import pytest

from sweatcaster.composio_gmail import ConsumerGmail, MESSAGES
from sweatcaster.composio_library import ComposioLibrary
from sweatcaster.dto import ApiError


class Gmail:
    account = "test-owner"

    def __init__(self):
        self.replies = []
        self.fail = False

    def read(self, endpoint, query):
        assert (endpoint, query) == (MESSAGES + "/abcd", {"format": "full"})
        return {
            "id": "abcd", "threadId": "thread-1",
            "payload": {"headers": [
                {"name": "From", "value": "Klinik <mailer@example.org>"},
                {"name": "Reply-To", "value": "Aftaler <aftaler@example.org>"},
                {"name": "Subject", "value": "Din tid"},
            ]},
        }

    def reply(self, thread, recipient, body):
        self.replies.append((thread, recipient, body))
        if self.fail:
            raise ApiError(502, "NOT_READY", "The provider response was lost.")
        return {"id": "sent-abcd", "threadId": thread}

    def newer_reply(self, thread, message):
        assert (thread, message) == ("thread-1", "sent-abcd")
        return {"state": "waiting"}


def test_confirmed_reply_is_threaded_and_can_be_recovered(tmp_path, monkeypatch):
    library = ComposioLibrary(tmp_path)
    gmail = Gmail()
    monkeypatch.setattr(library, "gmail", lambda: gmail)
    target = library.gmail_reply_target("abcd")
    assert target == {"threadID": "thread-1", "recipient": "aftaler@example.org", "subject": "Din tid"}
    identifier = str(uuid4())
    request = {"id": identifier, "messageID": "abcd", "body": "Fredag passer.",
               "threadID": target["threadID"], "recipient": target["recipient"]}
    assert library.gmail_reply_receipt(identifier) == {"sent": False}
    with pytest.raises(ApiError) as wrong_recipient:
        library.reply_gmail(dict(request, recipient="andet@example.org"))
    assert wrong_recipient.value.status_code == 409
    assert not gmail.replies
    result = library.reply_gmail(request)
    assert result == library.reply_gmail(request) == library.gmail_reply_receipt(identifier) == {
        "sent": True, "threadID": "thread-1",
    }
    assert gmail.replies == [("thread-1", "aftaler@example.org", "Fredag passer.")]
    assert library.gmail_followup(identifier) == {"state": "waiting"}
    gmail.account = "another-owner"
    assert library.gmail_reply_receipt(identifier) == {"sent": False}
    assert library.gmail_followup(identifier) == {"state": "unknown"}


def test_ambiguous_send_is_never_retried(tmp_path, monkeypatch):
    library = ComposioLibrary(tmp_path)
    gmail = Gmail()
    gmail.fail = True
    monkeypatch.setattr(library, "gmail", lambda: gmail)
    identifier = str(uuid4())
    request = {"id": identifier, "messageID": "abcd", "body": "Fredag passer.",
               "threadID": "thread-1", "recipient": "aftaler@example.org"}
    with pytest.raises(ApiError) as missing_receipt:
        library.reply_gmail(request)
    assert missing_receipt.value.status_code == 502
    with pytest.raises(ApiError) as blocked_retry:
        library.reply_gmail(request)
    assert blocked_retry.value.status_code == 409
    assert len(gmail.replies) == 1
    assert library.gmail_reply_receipt(identifier) == {"sent": False}


def test_composio_reply_uses_the_thread_action(monkeypatch):
    gmail = ConsumerGmail("test")
    monkeypatch.setattr(gmail, "_execute", lambda slug, arguments: (slug, arguments))
    assert gmail.reply("thread-1", "aftaler@example.org", "Fredag passer.") == (
        "GMAIL_REPLY_TO_THREAD", {"user_id": "me", "thread_id": "thread-1",
                                 "recipient_email": "aftaler@example.org", "message_body": "Fredag passer."},
    )


def test_followup_detects_only_new_incoming_messages(monkeypatch):
    gmail = ConsumerGmail("test")
    rows = [
        {"messageId": "earlier", "internalDate": "1763023500000", "labelIds": ["INBOX"]},
        {"messageId": "ours", "internalDate": "1763023600000", "labelIds": ["SENT"]},
        {"messageId": "another-send", "internalDate": "1763023800000", "labelIds": ["SENT"]},
    ]

    def execute(slug, arguments):
        assert slug == "GMAIL_FETCH_MESSAGE_BY_THREAD_ID"
        assert arguments == {"user_id": "me", "thread_id": "thread-1"}
        return {"messages": rows}

    monkeypatch.setattr(gmail, "_execute", execute)
    assert gmail.newer_reply("thread-1", "ours") == {"state": "waiting"}
    rows.append({"messageId": "incoming", "internalDate": "1763023700000", "labelIds": ["INBOX"],
                 "subject": "Tid bekræftet", "sender": "booking@example.org"})
    assert gmail.newer_reply("thread-1", "ours") == {"state": "received", "subject": "Tid bekræftet",
                                                      "sender": "booking@example.org", "timestamp": 1763023700}
    assert gmail.newer_reply("thread-1", "absent") == {"state": "unknown"}

import base64
from email.message import EmailMessage
from types import SimpleNamespace
from uuid import uuid4

import pytest

from sweatcaster.case_thread_adoption import adopt
from sweatcaster.dto import ApiError
from sweatcaster.agent_cases import AgentCases


class Provider:
    email, account = "owner@example.com", "owner-hash"
    def __init__(self):
        mail = EmailMessage()
        mail["From"], mail["To"] = self.email, "shop@example.com"
        mail["Subject"], mail["Message-ID"] = "Retur", "<original@example.com>"
        mail.set_content("Jeg vil gerne returnere ordren.")
        self.message = {"id": "ab01", "threadId": "cd01", "labelIds": ["SENT"], "raw": base64.urlsafe_b64encode(mail.as_bytes()).decode()}
        self.calls = []
    def proxy(self, method, path, **kwargs):
        self.calls.append((method, path))
        assert method == "GET" and path == "/messages/ab01"
        return self.message
    def followup(self, thread, sent):
        return {"state": "waiting", "messages": []}


def request(**changes):
    return {"messageID": "ab01", "threadID": "cd01", "recipient": "shop@example.com", "ownerEmail": "owner@example.com", **changes}


def test_adoption_reads_existing_mail_without_sending():
    provider = Provider()
    result = adopt(provider, {"id": str(uuid4())}, request())
    assert result["verified"] and result["messageID"] == "ab01" and result["threadID"] == "cd01"
    assert provider.calls == [("GET", "/messages/ab01")]


@pytest.mark.parametrize("changes", [{"threadID": "wrong"}, {"ownerEmail": "other@example.com"}, {"recipient": "other@example.com"}])
def test_wrong_owner_recipient_or_thread_is_rejected(changes):
    with pytest.raises(ApiError):
        adopt(Provider(), {"id": str(uuid4())}, request(**changes))


def test_unsent_message_cannot_be_adopted():
    provider = Provider(); provider.message["labelIds"] = ["INBOX"]
    with pytest.raises(ApiError):
        adopt(provider, {"id": str(uuid4())}, request())


def test_case_watcher_resumes_adopted_thread_and_close_stops_it(tmp_path):
    provider = Provider()
    service = AgentCases(tmp_path, None, provider=lambda: provider)
    bot, key = str(uuid4()), str(uuid4())
    record = service.create(bot, key, {"title": "Min retur", "merchant": "Butik", "problem": "Returnering", "desired": "Svar", "reference": ""})
    record = service.mutate(bot, key, {"action": "adoptSent", "revision": record["revision"], **request()})
    assert record["state"] == "waiting" and record["watch"] and record["outgoing"]["verified"]
    record = service.refresh(service.load(bot, key))
    assert record["state"] == "waiting"
    record = service.mutate(bot, key, {"action": "close", "revision": record["revision"], "approved": True, "reason": "Ordnet"})
    assert record["state"] == "closed" and record["watch"] is False
    assert all(method == "GET" for method, _ in provider.calls)


def test_failed_thread_lookup_is_reported_until_a_real_lookup_recovers(tmp_path):
    provider = Provider()
    service = AgentCases(tmp_path, None, provider=lambda: provider)
    bot, key = str(uuid4()), str(uuid4())
    record = service.create(bot, key, {"title": "Min sag", "problem": "Svar"})
    record = service.mutate(bot, key, {"action": "adoptSent", "revision": record["revision"], **request()})
    def broken(*_):
        raise OSError("unavailable")
    provider.followup = broken
    record = service.refresh(service.load(bot, key))
    assert record["checkError"] and record["state"] == "waiting"
    provider.followup = lambda *_: {"state": "unknown", "messages": []}
    assert service.refresh(service.load(bot, key))["checkError"]
    provider.followup = lambda *_: {"state": "waiting", "messages": []}
    assert service.refresh(service.load(bot, key))["checkError"] is None
    assert all(method == "GET" for method, _ in provider.calls)

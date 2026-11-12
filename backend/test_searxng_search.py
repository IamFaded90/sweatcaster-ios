import json
from email.message import Message
from io import BytesIO
from urllib.parse import parse_qs

import pytest

from sweatcaster import searxng_search


@pytest.fixture
def searxng(monkeypatch):
    calls = []
    reply = {"status": 200, "content_type": "application/json", "body": b'{"results":[]}'}

    class FakeResponse(BytesIO):
        def __init__(self):
            super().__init__(reply["body"])
            self.status = reply["status"]
            self.headers = Message()
            self.headers["Content-Type"] = reply["content_type"]

    class FakeConnection:
        def __init__(self, host, port, *, timeout):
            calls.append(("connect", host, port, timeout))

        def request(self, method, path, body, *, headers):
            calls.append((method, path, parse_qs(body.decode("ascii")), headers))
            if reply.get("offline"):
                raise OSError("synthetic private server details")

        def getresponse(self):
            return FakeResponse()

        def close(self):
            calls.append(("close",))

    monkeypatch.setattr(searxng_search.http.client, "HTTPConnection", FakeConnection)
    return calls, reply


def test_posts_only_query_to_loopback_and_bounds_results(searxng):
    calls, reply = searxng
    valid = {
        "url": "https://EXAMPLE.org/first?q=abc#fragment",
        "title": "Søgning &amp; resultat",
        "content": "Første\n  linje\u202e",
    }
    invalid_urls = [
        "file:///C:/private.txt",
        "javascript:alert(1)",
        "https://user:secret@example.org/",
        "https://127.1/example",
        "http://10.0.0.50/",
        "https://[::1]/",
        "https://device.local/",
        "https://good.example.org\\@unsafe.example.org/",
    ]
    rows = [{"url": url, "title": "Skip"} for url in invalid_urls] + [valid, valid]
    rows += [
        {"url": f"https://example.org/{i}", "title": "x" * 500, "content": "y" * 500}
        for i in range(8)
    ]
    reply["body"] = json.dumps({"results": rows, "private": "never returned"}).encode()
    results = searxng_search.search_web("   danske bøger & musik   ")
    assert calls == [
        ("connect", "127.0.0.1", 8080, searxng_search.REQUEST_TIMEOUT),
        ("POST", "/search", {"q": ["danske bøger & musik"], "format": ["json"], "categories": ["general"]},
         {"Accept": "application/json", "Content-Type": "application/x-www-form-urlencoded"}),
        ("close",),
    ]
    assert results[0] == {
        "url": "https://example.org/first?q=abc",
        "title": "Søgning & resultat",
        "snippet": "Første linje",
    }
    assert len(results) == searxng_search.MAX_RESULTS
    assert results[1] == {"url": "https://example.org/0", "title": "x" * 140, "snippet": "y" * 280}


@pytest.mark.parametrize("query", [None, ["test"], "ok", "  ", "private\x00query", "x" * 181])
def test_rejects_invalid_queries_without_connecting(searxng, query):
    calls, _ = searxng
    with pytest.raises(searxng_search.SearXNGError) as error:
        searxng_search.search_web(query)
    assert error.value.status == 422
    assert calls == []


@pytest.mark.parametrize(("changes", "status"), [
    ({"status": 302}, 502),
    ({"status": 403}, 503),
    ({"status": 429}, 503),
    ({"content_type": "text/html"}, 502),
    ({"body": b'{"unexpected":"private upstream details"}'}, 502),
    ({"body": b" " * (searxng_search.MAX_RESPONSE_BYTES + 1)}, 502),
    ({"offline": True}, 503),
])
def test_sanitizes_errors_and_closes_connection(searxng, changes, status):
    calls, reply = searxng
    reply.update(changes)
    with pytest.raises(searxng_search.SearXNGError) as error:
        searxng_search.search_web("danske bøger")
    assert error.value.status == status
    assert "private" not in str(error.value)
    assert calls[-1] == ("close",)

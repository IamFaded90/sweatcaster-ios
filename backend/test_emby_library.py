import json
from email.message import Message
from io import BytesIO
from urllib.error import URLError
from urllib.parse import parse_qs, urlsplit
from urllib.request import HTTPHandler, HTTPSHandler, build_opener
from urllib.response import addinfourl

import pytest

from sweatcaster import emby_library

TOKEN = "test-emby-access-token"
VIEWS = {"Items": [{"Id": "10", "Name": "Film", "Type": "CollectionFolder", "CollectionType": "movies"}]}


@pytest.fixture
def emby_server(monkeypatch):
    exchanges = []
    reply = {"status": 200, "body": json.dumps(VIEWS).encode(), "headers": {}}

    class InMemoryHTTP(HTTPHandler):
        def http_open(self, request):
            exchanges.append((request.selector, request.get_header("X-emby-token")))
            if reply.get("offline"):
                raise URLError("private server details")
            headers = Message()
            for key, value in reply["headers"].items():
                headers[key] = value
            response = addinfourl(BytesIO(reply["body"]), headers, request.full_url, reply["status"])
            response.msg = "Emby response"
            return response

    url = "http://127.0.0.1:8096"
    monkeypatch.setenv("FADEDAI_EMBY_URL", url + "/media/")
    monkeypatch.setenv("FADEDAI_EMBY_USER_ID", "scoped-user")
    monkeypatch.setenv("FADEDAI_EMBY_TOKEN", TOKEN)
    monkeypatch.setenv("FADEDAI_EMBY_WEB_URL", "https://emby.example/web/index.html")
    monkeypatch.setattr(emby_library, "build_opener", lambda *handlers: build_opener(*handlers, InMemoryHTTP()))
    return exchanges, reply, url


def test_reads_user_views_and_pages_search_without_disclosing_credentials(emby_server):
    exchanges, reply, _ = emby_server
    assert emby_library.read_library() == {
        "configured": True,
        "items": [{"id": "10", "title": "Film", "kind": "movies", "folder": True}],
        "nextOffset": None,
    }
    assert exchanges == [("/media/emby/Users/scoped-user/Views?IncludeExternalContent=false", TOKEN)]

    row = {"Id": "108", "Name": "En film", "Type": "Movie", "ServerId": "server123",
           "ProductionYear": 2024, "Path": "C:/private/movie.mp4", "AccessToken": TOKEN,
           "ExternalUrls": [{"Url": "https://example.org/untrusted"}]}
    reply["body"] = json.dumps({"Items": [row], "TotalRecordCount": 31}).encode()
    library = emby_library.read_library(parent="10", search=" dansk & engelsk ", offset=29)
    target, token = exchanges[-1]
    request = urlsplit(target)
    assert token == TOKEN and TOKEN not in target
    assert request.path == "/media/emby/Users/scoped-user/Items"
    assert parse_qs(request.query) == {
        "StartIndex": ["29"], "Limit": ["30"], "SortBy": ["SortName"],
        "ParentId": ["10"], "SearchTerm": ["dansk & engelsk"], "Recursive": ["true"],
    }
    assert library == {"configured": True, "items": [{
        "id": "108", "title": "En film", "kind": "Movie", "folder": False, "subtitle": "2024",
        "webURL": "https://emby.example/web/index.html#!/item?id=108&serverId=server123",
    }], "nextOffset": 30}
    assert emby_library.read_library(search="global", offset=30)["nextOffset"] is None
    assert "ParentId" not in parse_qs(urlsplit(exchanges[-1][0]).query)


def test_redirects_and_upstream_errors_never_return_server_details(emby_server, monkeypatch):
    exchanges, reply, url = emby_server
    reply.update(status=302, headers={"Location": url + "/unexpected"})
    with pytest.raises(emby_library.EmbyLibraryError) as error:
        emby_library.read_library()
    assert error.value.status == 502
    assert len(exchanges) == 1

    reply.update(status=200, headers={}, body=b'{"unrecognized":"server details"}')
    with pytest.raises(emby_library.EmbyLibraryError) as error:
        emby_library.read_library()
    assert error.value.status == 502 and "server details" not in str(error.value)

    monkeypatch.setattr(emby_library, "MAX_RESPONSE_BYTES", 30)
    reply["body"] = b" " * 31
    with pytest.raises(emby_library.EmbyLibraryError) as error:
        emby_library.read_library()
    assert error.value.status == 502

    reply.update(status=503)
    with pytest.raises(emby_library.EmbyLibraryError) as error:
        emby_library.read_library()
    assert error.value.status == 503

    reply["offline"] = True
    with pytest.raises(emby_library.EmbyLibraryError) as error:
        emby_library.read_library()
    assert error.value.status == 503 and "private server details" not in str(error.value)


def test_configuration_and_query_validation(monkeypatch):
    monkeypatch.setattr(emby_library, "_load_saved_settings", lambda: None)
    for key in ("URL", "USER_ID", "TOKEN", "WEB_URL"):
        monkeypatch.delenv("FADEDAI_EMBY_" + key, raising=False)
    assert emby_library.read_library() == {"configured": False, "items": [], "nextOffset": None}

    with pytest.raises(emby_library.EmbyLibraryError) as error:
        emby_library.read_library(parent="../Users")
    assert error.value.status == 422

    monkeypatch.setenv("FADEDAI_EMBY_URL", "http://emby.example")
    monkeypatch.setenv("FADEDAI_EMBY_USER_ID", "scoped-user")
    monkeypatch.setenv("FADEDAI_EMBY_TOKEN", TOKEN)
    with pytest.raises(emby_library.EmbyLibraryError) as error:
        emby_library.read_library()
    assert error.value.status == 503

    monkeypatch.setenv("FADEDAI_EMBY_URL", "http://100.64.12.34:8096/emby")
    config = emby_library.EmbyConfiguration.from_environment()
    assert config.api_base == "http://100.64.12.34:8096/emby"
    assert TOKEN not in repr(config)


def test_windows_settings_are_used_only_without_primary_environment(monkeypatch):
    for key in (*emby_library.PRIMARY_ENV, "FADEDAI_EMBY_WEB_URL"):
        monkeypatch.delenv(key, raising=False)
    monkeypatch.setattr(emby_library, "_load_saved_settings", lambda: {
        "url": "https://emby.example/media", "user_id": "saved-user", "token": TOKEN,
        "web_url": "https://emby.example/media/web/index.html",
    })
    config = emby_library.EmbyConfiguration.from_environment()
    assert config.api_base == "https://emby.example/media/emby"
    assert config.user_id == "saved-user"

    monkeypatch.setenv("FADEDAI_EMBY_USER_ID", "env-user")
    with pytest.raises(emby_library.EmbyLibraryError) as error:
        emby_library.EmbyConfiguration.from_environment()
    assert error.value.status == 503

    monkeypatch.setenv("FADEDAI_EMBY_URL", "http://127.0.0.1:8096")
    monkeypatch.setenv("FADEDAI_EMBY_TOKEN", TOKEN)
    config = emby_library.EmbyConfiguration.from_environment()
    assert config.user_id == "env-user" and config.web_url is None


def test_secure_discovery_uses_only_tls_and_never_sends_credentials(monkeypatch):
    exchanges = []

    class InMemoryHTTPS(HTTPSHandler):
        def https_open(self, request):
            exchanges.append(request)
            headers = Message()
            if request.host == "emby.example":
                headers["Location"] = "https://other.example"
                response = addinfourl(BytesIO(), headers, request.full_url, 302)
            else:
                body = b'{"Id":"public-server-id","ServerName":"Films","Version":"4.9.1.0"}'
                response = addinfourl(BytesIO(body), headers, request.full_url, 200)
            response.msg = "Emby response"
            return response

    monkeypatch.setattr(emby_library, "build_opener", lambda *handlers: build_opener(*handlers, InMemoryHTTPS()))
    assert emby_library.find_secure_server("http://emby.example:8096/media/") == "https://emby.example:8920/media/"
    assert [request.full_url for request in exchanges] == [
        "https://emby.example/media/emby/System/Info/Public",
        "https://emby.example:8920/media/emby/System/Info/Public",
    ]
    for request in exchanges:
        assert request.data is None
        assert set(dict(request.header_items())) <= {"Accept", "Host", "User-agent"}

    exchanges.clear()
    assert emby_library.find_secure_server("https://emby.example:9443") == "https://emby.example:9443"
    assert len(exchanges) == 1

    with pytest.raises(ValueError):
        emby_library.find_secure_server("http://username:password@emby.example/")
    assert len(exchanges) == 1

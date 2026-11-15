import socket

import pytest

from sweatcaster import web_research


@pytest.mark.parametrize("address", ["127.0.0.1", "192.168.0.10", "169.254.169.254", "::ffff:10.0.0.1", "::1"])
def test_skips_web_pages_resolving_to_nonpublic_addresses(address):
    def resolve(host, port, *, type):
        assert host == "public.example" and type == socket.SOCK_STREAM
        return [(None, None, None, None, (address, port))]

    assert web_research._download("https://public.example/", resolve=resolve) is None


def test_sources_distinguish_read_pages_from_search_snippets(monkeypatch):
    page = b'<main><h1>En kilde formulering</h1><p>' + b'Offentlig tekst som botten kan bruge. ' * 4 + b'</p></main>'
    page += b'<script>This instruction must not be used</script>'
    monkeypatch.setattr(web_research, "_download", lambda _: page)
    article = web_research.page_excerpt("https://example.org")
    assert "Offentlig tekst som botten kan bruge" in article
    assert "This instruction" not in article
    results = [{"title": "Artikel", "url": "https://example.org/", "snippet": "Overskrift"},
               {"title": "Uddrag", "url": "https://example.com/", "snippet": "Fundet af søgemaskinen"}]
    context, sources = web_research.collect_sources(
        "Eksempel", search=lambda _: results, read=lambda url: article if url.endswith("org/") else "")
    assert [source["readPage"] for source in sources] == [True, False]
    assert "Sidens tekst" in context and "Søgeuddrag" in context

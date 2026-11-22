"""Fetch short excerpts from public SearXNG results for an opted-in bot job."""

from __future__ import annotations

import ipaddress
import http.client
import json
import os
import re
import socket
from time import monotonic
from urllib.parse import urlencode, urlsplit

import certifi
import urllib3

from sweatcaster.searxng_search import SearXNGError, _public_url, _read_json, _text, search_web

MAX_PAGE_BYTES = 512_000
MAX_SOURCES = 3
_DOCS = re.compile(r"\b(?:context7|api[- ]?dokumentation\w*|api docs|sdk docs)\b", re.I)
_LIBRARY = re.compile(r"\b(?:swiftui|fastapi|langgraph|pydantic|playwright|ollama|python|react|docker|pytorch)\b", re.I)
_LOOKUP = re.compile(r"\b(?:dokumentation\w*|docs|documentation|api|sdk|kodeeksempel\w*|code example\w*)\b", re.I)


def research_query(raw):
    try:
        result = json.loads(raw) if isinstance(raw, str) and len(raw) <= 2_000 else None
        query = result.get("query") if isinstance(result, dict) else None
        if not isinstance(query, str) or not 3 <= len(query.strip()) <= 180 or not query.isprintable():
            raise ValueError
        return query.strip()
    except (ValueError, RecursionError) as exc:
        raise SearXNGError(422, "Agenten fandt ingen klar søgning. Skriv, hvad den skal undersøge på nettet.") from exc


def _public_address(host, port, resolve):
    records = resolve(host, port, type=socket.SOCK_STREAM)
    addresses = list(dict.fromkeys(ipaddress.ip_address(record[4][0]) for record in records))
    addresses = [getattr(address, "ipv4_mapped", None) or address for address in addresses]
    if not addresses or any(not addr.is_global or addr.is_multicast for addr in addresses):
        return None
    return str(min(addresses, key=lambda address: address.version))


def _download(url, resolve=socket.getaddrinfo):
    if not _public_url(url):
        return None
    parts = urlsplit(url)
    secure = parts.scheme == "https"
    port = 443 if secure else 80
    if parts.port not in (None, port):
        return None
    host = parts.hostname
    if host is None:
        return None
    address = _public_address(host, port, resolve)
    if address is None:
        return None
    # Connect to the checked IP so a second DNS resolution cannot change the destination.
    # TLS still verifies the original hostname.
    if secure:
        pool = urllib3.HTTPSConnectionPool(address, port, server_hostname=host, assert_hostname=host,
                                           cert_reqs="CERT_REQUIRED", ca_certs=certifi.where())
    else:
        pool = urllib3.HTTPConnectionPool(address, port)
    authority = f"[{host}]" if ":" in host else host
    resource = (parts.path or "/") + (f"?{parts.query}" if parts.query else "")
    deadline = monotonic() + 7
    try:
        response = pool.request("GET", resource, headers={
            "Host": authority, "User-Agent": "FadedAI Research", "Accept": "text/html,application/xhtml+xml",
            "Accept-Encoding": "identity",
        }, redirect=False, retries=False, preload_content=False,
            timeout=urllib3.Timeout(connect=2, read=3, total=5))
        with response:
            media = response.headers.get("Content-Type", "").split(";", 1)[0].strip().lower()
            encoding = response.headers.get("Content-Encoding", "").strip().lower()
            if response.status != 200 or media not in {"text/html", "application/xhtml+xml"} or encoding not in {"", "identity"}:
                return None
            output = bytearray()
            for chunk in response.stream(16_384, decode_content=False):
                if monotonic() >= deadline:
                    break
                output.extend(chunk)
                if len(output) >= MAX_PAGE_BYTES:
                    break
            return bytes(output[:MAX_PAGE_BYTES])
    finally:
        pool.close()


def page_excerpt(url):
    try:
        from lxml import etree, html
    except ImportError:
        return ""
    try:
        data = _download(url)
        if not data:
            return ""
        root = html.fromstring(data, parser=html.HTMLParser(no_network=True, recover=True, encoding="utf-8"))
        for node in root.xpath("//script | //style | //noscript | //nav | //footer | //form | //aside | //*[@hidden]"):
            if node.getparent() is not None:
                node.drop_tree()
        content = root.xpath("//main | //article | //*[@role='main']")
        if not content:
            content = root.xpath("//body") or [root]
        paragraphs = content[0].xpath(".//h1 | .//h2 | .//p | .//li")
        text = " ".join(node.text_content() for node in paragraphs) if paragraphs else content[0].text_content()
        return _text(text, 1_650, 1_900) if len(text.strip()) >= 80 else ""
    except (OSError, ValueError, urllib3.exceptions.HTTPError, etree.Error):
        return ""


def documentation_excerpts(query):
    """Retrieve attributed examples for an opted-in software documentation search."""
    headers = {"Accept": "application/json", "User-Agent": "FadedAI Research"}
    if key := os.environ.get("CONTEXT7_API_KEY", "").strip():
        headers["Authorization"] = "Bearer " + key
    params = {"query": query, "type": "json"}
    if match := _LIBRARY.search(query):
        params["library"] = match.group()
    connection = http.client.HTTPSConnection("context7.com", timeout=5)
    try:
        connection.request("GET", "/api/v3/search?" + urlencode(params), headers=headers)
        with connection.getresponse() as response:
            if response.status != 200 or response.headers.get_content_type() != "application/json":
                return []
            data = _read_json(response, monotonic() + 5)
    except (OSError, http.client.HTTPException, ValueError, RecursionError):
        return []
    finally:
        connection.close()
    if not isinstance(data, dict):
        return []
    items = []
    for field in ("codeSnippets", "infoSnippets"):
        entries = data.get(field)
        for row in entries if isinstance(entries, list) else ():
            if not isinstance(row, dict):
                continue
            url = _public_url(row.get("codeId") or row.get("pageId"))
            if not url or any(item["url"] == url for item in items):
                continue
            title = _text(row.get("codeTitle") or row.get("breadcrumb"), 140, 300) or "Dokumentation"
            excerpt = _text(row.get("codeDescription") or row.get("content"), 800, 1400)
            examples = row.get("codeList")
            if isinstance(examples, list):
                example = next((v["code"] for v in examples if isinstance(v, dict) and isinstance(v.get("code"), str)), "")
                if example.strip():
                    excerpt += "\n" + example.strip()[:650]
            if excerpt.strip():
                items.append({"title": title, "url": url, "excerpt": excerpt})
            if len(items) == MAX_SOURCES:
                return items
    return items


def collect_sources(query, *, search=search_web, read=page_excerpt, cancelled=lambda: False):
    sections, sources = [], []
    if cancelled():
        return "", []
    if _DOCS.search(query) or (_LIBRARY.search(query) and _LOOKUP.search(query)):
        docs = documentation_excerpts(query)
        library = _LIBRARY.search(query)
        if not docs and library and not cancelled():
            from sweatcaster.docs_gateway import lookup
            docs = lookup(query, library.group())
        for item in docs:
            if cancelled():
                return "", []
            sources.append({"title": item["title"], "url": item["url"], "readPage": False})
            sections.append(f"[{len(sources)}] {item['title']}\n{item['url']}\nDokumentationsuddrag via Context7: {item['excerpt']}")
        if sources or cancelled():
            return "\n\n".join(sections), sources
    for item in search(query):
        if cancelled() or len(sources) == MAX_SOURCES:
            break
        text = read(item["url"])
        content = text or item["snippet"]
        if not content:
            continue
        sources.append({"title": item["title"], "url": item["url"], "readPage": bool(text)})
        evidence = "Sidens tekst" if text else "Søgeuddrag"
        sections.append(f"[{len(sources)}] {item['title']}\n{item['url']}\n{evidence}: {content}")
    if not sources and not cancelled():
        raise SearXNGError(404, "Søgningen gav ingen læsbare kilder. Prøv at skrive opgaven mere konkret.")
    return "\n\n".join(sections), sources

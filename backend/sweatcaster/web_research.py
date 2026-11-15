"""Fetch short excerpts from public SearXNG results for an opted-in bot job."""

from __future__ import annotations

import ipaddress
import json
import re
import socket
from time import monotonic
from urllib.parse import urlsplit

import certifi
import urllib3

from sweatcaster.searxng_search import SearXNGError, _public_url, _text, search_web

MAX_PAGE_BYTES = 512_000
MAX_SOURCES = 3


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


def collect_sources(query, *, search=search_web, read=page_excerpt, cancelled=lambda: False):
    sections, sources = [], []
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

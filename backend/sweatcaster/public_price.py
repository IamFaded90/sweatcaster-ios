"""Read the advertised price of a single product from a public HTTPS page."""
import json
from decimal import Decimal, InvalidOperation
from pathlib import Path
import re
import subprocess
import sys
from urllib.parse import urlsplit

import urllib3

from sweatcaster.dto import ApiError
from sweatcaster.searxng_search import _public_url
from sweatcaster.web_research import _download


def listing(value):
    url = _public_url(value)
    if not url or not url.startswith("https://") or urlsplit(url).port not in (None, 443):
        raise ApiError(422, "INVALID_INPUT", "Indsæt et offentligt https-link til én vare.")
    return url


def _products(value):
    items = value if isinstance(value, list) else [value]
    for item in items:
        if not isinstance(item, dict):
            continue
        kinds = item.get("@type")
        if "Product" in (kinds if isinstance(kinds, list) else [kinds]):
            yield item
        graph = item.get("@graph")
        if isinstance(graph, list):
            yield from _products(graph)


def _from_page(data):
    if not data:
        return None
    try:
        from lxml import etree, html
    except ImportError:
        return None
    try:
        root = html.fromstring(data, parser=html.HTMLParser(no_network=True, encoding="utf-8"))
    except etree.Error:
        return None
    products = []
    for script in root.xpath('//script[@type="application/ld+json"]/text()'):
        try:
            products.extend(_products(json.loads(script)))
        except (ValueError, RecursionError):
            continue
    if len(products) != 1:
        return None
    product = products[0]
    offers = product.get("offers")
    entries = offers if isinstance(offers, list) else [offers]
    values = set()
    for offer in entries:
        if not isinstance(offer, dict) or offer.get("@type") != "Offer":
            return None
        price, currency = offer.get("price"), offer.get("priceCurrency")
        if not isinstance(currency, str) or not re.fullmatch(r"[A-Z]{3}", currency):
            return None
        if not re.fullmatch(r"[0-9]{1,10}(?:[.][0-9]{1,2})?", str(price)):
            return None
        amount = Decimal(str(price))
        if amount <= 0:
            return None
        availability = str(offer.get("availability", "")).rsplit("/", 1)[-1]
        if availability and availability not in {"InStock", "LimitedAvailability", "OnlineOnly"}:
            return None
        values.add((amount, currency))
    if len(values) == 1:
        amount, currency = values.pop()
        name = product.get("name", "")
        return str(name)[:180], amount, currency
    return None


def _render(data):
    # Run the browser out of the worker and bound its lifetime. The renderer never contacts the shop.
    script = Path(__file__).with_name("price_render.py")
    try:
        proc = subprocess.run([sys.executable, "-I", "-B", str(script)], input=data, capture_output=True,
                              timeout=14, check=False, creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
        if proc.returncode == 0 and 0 < len(proc.stdout) <= 512_000:
            return proc.stdout
    except (OSError, subprocess.SubprocessError):
        pass
    return None


def check(url, currency):
    try:
        data = _download(listing(url))
        if data is None:
            raise ValueError("download")
        quote = _from_page(data)
        if quote is None and b"itemprop" in data.lower():
            rendered = _render(data)
            quote = _from_page(rendered) if rendered else None
    except (OSError, ValueError, InvalidOperation, urllib3.exceptions.HTTPError):
        quote = None
    if quote is None:
        return {"state": "error", "note": "Siden gav ingen entydig, tilgængelig varepris. PC’en prøver igen."}
    title, amount, code = quote
    result = {"title": title, "price": float(amount), "priceCurrency": code}
    if code != currency:
        return result | {"state": "currencyMismatch", "note": f"Siden viser prisen i {code}. Din grænse er i {currency}."}
    return result | {"state": "watching", "compared": amount, "note": "Sidens varepris uden fragt."}

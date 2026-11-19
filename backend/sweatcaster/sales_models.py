"""Validation and photo preparation for the owner's sale cases."""

import base64
from decimal import Decimal, InvalidOperation, ROUND_CEILING
from io import BytesIO
import json
from uuid import UUID

from sweatcaster.dto import ApiError


def identifier(raw):
    try:
        return str(UUID(raw))
    except (ValueError, TypeError, AttributeError):
        raise ApiError(422, "INVALID_INPUT", "Vælg en gyldig salgssag.") from None


def text(value, limit, *, empty=False):
    if not isinstance(value, str) or "\0" in value or len(value.strip()) > limit or (not empty and not value.strip()):
        raise ApiError(422, "INVALID_INPUT", "Tjek salgssagens tekstfelter.")
    return value.strip()


def money(raw):
    try:
        if type(raw) not in (int, float) or len(str(raw)) > 14:
            raise ValueError
        value = Decimal(str(raw))
        if not value.is_finite() or not 0 < value <= 10_000_000 or value * 100 != (value * 100).to_integral_value():
            raise ValueError
        return float(value)
    except (ValueError, InvalidOperation):
        raise ApiError(422, "INVALID_INPUT", "Skriv et positivt beløb med højst to decimaler.") from None


def fields(body):
    minimum, asking = money(body.get("minimum")), money(body.get("asking"))
    currency = body.get("currency")
    if asking < minimum or currency not in {"SEK", "DKK"}:
        raise ApiError(422, "INVALID_INPUT", "Prisen skal være mindst din mindstepris. Vælg DKK eller SEK.")
    category = body.get("categoryID", 0)
    bidder = body.get("bidderID", 0)
    if type(category) is not int or not 0 <= category < 2_147_483_647 or type(bidder) is not int or bidder < 0:
        raise ApiError(422, "INVALID_INPUT", "Vælg en Tradera-kategori og tilladte købere.")
    terms = body.get("attributes", [])
    if not isinstance(terms, list) or len(terms) > 30:
        raise ApiError(422, "INVALID_INPUT", "Tjek kategoriens egenskaber.")
    for term in terms:
        if (not isinstance(term, dict) or set(term) != {"id", "values"} or type(term["id"]) is not int
                or not isinstance(term["values"], list) or len(term["values"]) > 10
                or not all(isinstance(v, str) and 0 < len(v) < 120 for v in term["values"])):
            raise ApiError(422, "INVALID_INPUT", "Tjek kategoriens egenskaber.")
    if len({term["id"] for term in terms}) != len(terms):
        raise ApiError(422, "INVALID_INPUT", "Vælg hver egenskab én gang.")
    shipping = body.get("shippingOptions", [])
    if not isinstance(shipping, list) or len(shipping) > 8:
        raise ApiError(422, "INVALID_INPUT", "Tjek fragtmulighederne.")
    for option in shipping:
        if (not isinstance(option, dict) or set(option) != {"shippingProviderId", "cost"}
                or type(option["shippingProviderId"]) is not int or option["shippingProviderId"] <= 0
                or type(option["cost"]) is not int or not 0 <= option["cost"] <= 100_000):
            raise ApiError(422, "INVALID_INPUT", "Vælg en gyldig fragtmulighed og en pris i SEK.")
    return {"title": text(body.get("title"), 80), "description": text(body.get("description"), 4_000),
            "minimum": minimum, "asking": asking, "currency": currency, "categoryID": category,
            "bidderID": bidder, "attributes": terms, "shippingOptions": shipping,
            "shipping": text(body.get("shipping", "Afhentning efter aftale"), 800)}


def photo(raw):
    from PIL import Image, ImageOps
    try:
        if not isinstance(raw, str) or len(raw) > 4_000_000:
            raise ValueError
        image = base64.b64decode(raw, validate=True)
        with Image.open(BytesIO(image)) as source:
            if source.width * source.height > 40_000_000:
                raise ValueError
            prepared = ImageOps.exif_transpose(source).convert("RGB")
            prepared.thumbnail((1920, 1920))
            stream = BytesIO()
            prepared.save(stream, "JPEG", quality=88)
            return stream.getvalue()
    except (ValueError, OSError, Image.DecompressionBombError):
        raise ApiError(422, "INVALID_INPUT", "Vælg et almindeligt foto. Brug højst otte billeder.") from None


def listing(case, rate=1):
    if not case["categoryID"] or not case["bidderID"]:
        raise ApiError(422, "INVALID_INPUT", "Vælg en kategori og tilladte købere, før du gør annoncen klar.")
    sek = int((Decimal(str(case["asking"])) / Decimal(str(rate))).to_integral_value(rounding=ROUND_CEILING))
    return {"title": case["title"], "description": case["description"], "descriptionLanguageCodeIso2": "da",
            "ownReferences": ["fadedai:" + case["id"]], "categoryId": case["categoryID"],
            "itemType": 3, "duration": 30, "startPrice": sek, "buyItNowPrice": sek, "restarts": 0,
            "acceptedBidderId": case["bidderID"], "shippingCondition": case["shipping"],
            "shippingOptions": case["shippingOptions"], "attributeValues": {"terms": case["attributes"]},
            "autoCommit": False}


def encoded(value):
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"))

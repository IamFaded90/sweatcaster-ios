"""Exact, in-memory answers to explicit everyday unit conversions in chat."""

from dataclasses import dataclass
from decimal import Decimal, localcontext
from fractions import Fraction
import re


@dataclass(frozen=True)
class Unit:
    symbol: str
    dimension: str
    scale: Fraction
    zero: Fraction


def _unit_table():
    aliases = {}

    def add(dimension, symbol, scale, names, zero=0):
        unit = Unit(symbol, dimension, Fraction(scale), Fraction(zero))
        for name in [symbol.casefold(), *names.split("|")]:
            aliases[name] = unit

    add("mass", "mg", "0.001", "milligram|milligrams")
    add("mass", "g", 1, "gram|grams")
    add("mass", "kg", 1000, "kilo|kilos|kilogram|kilograms")
    add("mass", "lb", "453.59237", "lbs|pound|pounds|engelske pund|engelsk pund")
    add("mass", "oz", "28.349523125", "ounce|ounces")
    add("length", "mm", "0.001", "millimeter|millimetre|millimeters|millimetres")
    add("length", "cm", "0.01", "centimeter|centimetre|centimeters|centimetres")
    add("length", "m", 1, "meter|metre|meters|metres")
    add("length", "km", 1000, "kilometer|kilometre|kilometers|kilometres")
    add("length", "in", "0.0254", "inch|inches|tomme|tommer")
    add("length", "ft", "0.3048", "foot|feet|fod")
    add("length", "mi", "1609.344", "mile|miles|engelsk mil|engelske mil")
    add("volume", "ml", 1, "milliliter|millilitre|milliliters|millilitres")
    add("volume", "cl", 10, "centiliter|centilitre|centiliters|centilitres")
    add("volume", "dl", 100, "deciliter|decilitre|deciliters|decilitres")
    add("volume", "l", 1000, "liter|litre|liters|litres")
    add("time", "s", 1, "sekund|sekunder|sec|second|seconds")
    add("time", "min", 60, "minut|minutter|minute|minutes")
    add("time", "h", 3600, "t|time|timer|hour|hours")
    add("time", "d", 86400, "dag|dage|day|days|døgn")
    add("temperature", "°C", 1, "c|celsius|grader celsius|degrees celsius")
    add("temperature", "°F", "5/9", "f|fahrenheit|grader fahrenheit|degrees fahrenheit", "-160/9")
    return aliases


_UNITS = _unit_table()
_FRACTIONS = {
    "en halv": "1/2", "et halvt": "1/2", "halv": "1/2", "halvt": "1/2",
    "half a": "1/2", "half an": "1/2", "half": "1/2",
    "en kvart": "1/4", "et kvart": "1/4", "a quarter of a": "1/4", "a quarter": "1/4",
    "halvanden": "3/2", "halvandet": "3/2",
    "½": "1/2", "¼": "1/4", "¾": "3/4",
    "to": "2", "two": "2", "to og et halvt": "5/2", "to og en halv": "5/2",
    "two and a half": "5/2",
    "en": "1", "et": "1", "én": "1", "ét": "1", "one": "1", "a": "1", "an": "1",
}


def _alternatives(words):
    return "|".join(re.escape(word) for word in sorted(words, key=len, reverse=True))


_UNIT = _alternatives(_UNITS)
_AMOUNT = rf"(?P<amount>[+-]?(?:[0-9]{{1,12}}(?:[.,][0-9]{{1,9}})?|[.,][0-9]{{1,9}})|{_alternatives(_FRACTIONS)})"
_SOURCE = rf"(?P<source>{_UNIT})"
_TARGET = rf"(?P<target>{_UNIT})"
_PREFIX = r"(?:(?:hvad er|hvor meget (?:er|vejer)|omregn(?: venligst)?|kan du (?:lige )?(?:omregne|konvertere)|konvert[ée]r|what is|what's|how much is|(?:please |can you )?convert)\s+)?"
_FORWARD = re.compile(rf"{_PREFIX}{_AMOUNT}\s*{_SOURCE}\s+(?:i|til|in|to|as)\s+{_TARGET}")
_REVERSE = re.compile(rf"(?:hvor mange|hvor meget|how many)\s+{_TARGET}\s+(?:er (?:der (?:så )?i |der på |i )?|går der på |går der til |are (?:there in |in )?|is (?:in )?|in ){_AMOUNT}\s*{_SOURCE}")
_EQUIVALENT = re.compile(rf"hvor mange\s+{_TARGET}\s+svarer\s+{_AMOUNT}\s*{_SOURCE}\s+til")
_VALUE_IN = re.compile(rf"hvad svarer\s+{_AMOUNT}\s*{_SOURCE}\s+til\s+i\s+{_TARGET}")
_VOCATIVE = re.compile(r"^\s*(?:hej\s+|hey\s+)?lumi(?:\s*[,!:\-]\s*|\s+)", re.IGNORECASE)
_FOLLOW = r"(?:og|og hvad med|hvad med|and|and what about|what about|how about)\s+"
_NEXT_AMOUNT = re.compile(rf"(?:{_FOLLOW}|og (?:hvad|hvor meget) (?:er|bliver) |and how much is ){_AMOUNT}(?:\s*{_SOURCE})?(?: så)?")
_NEXT_UNIT = re.compile(rf"(?:{_FOLLOW}(?:så )?(?:i|til|in|to)|hvad er det (?:så )?i|what is that in)\s+{_TARGET}")


@dataclass(frozen=True)
class Conversion:
    amount: Fraction
    source: Unit
    target: Unit


def _parse(text, previous, language):
    if len(text) > 250:
        return None
    text = " ".join(_VOCATIVE.sub("", text).casefold().split()).rstrip(" ?!.").replace("−", "-").replace("’", "'")
    text = re.sub(r",? (?:tak|please)$", "", text)
    question = re.sub(r"^(?:og|and)\s+", "", text)
    for rule in (_FORWARD, _REVERSE, _EQUIVALENT, _VALUE_IN):
        match = rule.fullmatch(question)
        if match:
            break
    if not match and previous:
        if follow := _NEXT_UNIT.fullmatch(text):
            target = _UNITS[follow["target"]]
            if target.dimension == previous.source.dimension:
                return Conversion(previous.amount, previous.source, target)
        match = _NEXT_AMOUNT.fullmatch(text)
    if not match:
        return None
    groups = match.groupdict()
    source = _UNITS[groups["source"]] if groups["source"] else previous.source
    target = _UNITS[groups["target"]] if "target" in groups else previous.target
    if source.dimension != target.dimension or ("target" not in groups and source == target):
        return None
    raw = groups["amount"]
    number = _FRACTIONS.get(raw, raw)
    if re.search(r"\b(?:what|how|are|and|convert|about|pounds|grams)\b", text):
        grouping = ","
    elif re.search(r"\b(?:hvad|hvor|er|og|omregn|til)\b", text):
        grouping = "."
    else:
        grouping = "." if language == "da-DK" else ","
    if re.fullmatch(rf"[+-]?[1-9][0-9]{{0,2}}{re.escape(grouping)}[0-9]{{3}}", number):
        number = number.replace(grouping, "")
    return Conversion(Fraction(number.replace(",", ".")), source, target)


def _display(number: Fraction, language: str):
    denominator = number.denominator
    for factor in (2, 5):
        while denominator % factor == 0:
            denominator //= factor
    with localcontext() as context:
        # Keep terminating decimals exact. Use significant digits for repeating fractions.
        if denominator == 1:
            context.prec = len(str(abs(number.numerator))) + number.denominator.bit_length()
        else:
            context.prec = 10
        decimal = Decimal(number.numerator) / Decimal(number.denominator)
    text = format(decimal, "f")
    if "." in text:
        text = text.rstrip("0").rstrip(".")
    return (text.replace(".", ",") if language == "da-DK" else text), Fraction(decimal) == number


def conversion_reply(message: str, history: list[dict] | None = None, *, language: str = "da-DK") -> str | None:
    conversion = _parse(message, None, language)
    if conversion is None:
        # Only consecutive conversion requests count. Changing the topic drops its units.
        previous = None
        if not re.match(r"^\s*(?:og|and|hvad|what|how)\b", _VOCATIVE.sub("", message), re.IGNORECASE):
            return None
        for item in (history or [])[-16:]:
            if item.get("role") == "user":
                previous = _parse(item["content"], previous, language)
        conversion = _parse(message, previous, language)
    if conversion is None:
        return None
    source, target = conversion.source, conversion.target
    value = (conversion.amount * source.scale + source.zero - target.zero) / target.scale
    before, _ = _display(conversion.amount, language)
    after, exact = _display(value, language)
    relation = "=" if exact else "≈"
    return f"{before} {source.symbol} {relation} {after} {target.symbol}."

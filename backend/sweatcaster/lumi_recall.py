"""Answer direct questions about a few everyday facts from this chat's user turns."""

import re


_OBJECTS = {
    "bike": ("cykel", "bike", "bicycle"), "car": ("bil", "car"),
    "jacket": ("jakke", "jacket"), "bag": ("taske", "bag"),
    "helmet": ("hjelm", "helmet"), "phone": ("telefon", "phone"),
    "cat": ("kat", "cat"), "dog": ("hund", "dog"),
}
_FAVORITES = {
    "colour": ("yndlingsfarve", "favoritfarve", "favorite color", "favourite colour",
               "favorite colour", "favourite color"),
    "film": ("yndlingsfilm", "favoritfilm", "favorite movie", "favorite film",
             "favourite movie", "favourite film"),
    "song": ("yndlingssang", "favoritsang", "favorite song", "favourite song"),
    "food": ("livret", "yndlingsret", "favorite food", "favourite food",
             "favorite dish", "favourite dish"),
}
_COLOR = re.compile(
    r"(?:[a-zæøåäöü-]*(?:blå|rød|sort|hvid|brun|grøn|grå|gul)|turkis|pink|lilla|orange|beige|"
    r"bordeaux|violet|khaki|silver|gold|navy|teal|turquoise|blue|red|black|white|brown|green|grey|gray|"
    r"yellow|purple|crimson|lavender|ivory)", re.I)
_SHADE = {"lys", "mørk", "støvet", "metallisk", "lysere", "metallic", "light", "dark", "petrol",
          "forest", "midnight", "royal", "sky", "deep", "navy", "dusty", "racing", "british"}
_UNSAFE = re.compile(r"\b(?:ikke|not|never|aldrig|måske|maybe|perhaps|enten|eller|either|or|tror|"
                     r"min|mit|your|hans|hendes|his|adgangskod\w*|kod(?:e|en|er)|pinkod\w*|password\w*|"
                     r"pin|token\w*|secret\w*|hemmelig\w*|telefonnummer\w*|mail\w*|adress\w*|cpr)\b", re.I)
_QUOTES = {'"': '"', "“": "”", "„": "“", "»": "«", "«": "»", "‘": "’", "'": "'"}
_TITLE_PREFIX = re.compile(r"(?:\b(?:dr|mr|mrs|ms|st|jr|sr|prof)|\b[A-ZÆØÅ])$", re.I)


def _statements_in_turn(text):
    """Keep quoted speech and titles intact so punctuation can't create a new self-report."""
    if re.search(r"(?m)^\s*(?:```|~~~)", text):
        return
    text = re.sub(r"(?m)^[ \t]*>[^\n]*(?:\n(?![ \t]*(?:\n|$))[^\n]+)*", "", text)
    start = 0
    closing_quote = None
    for index, char in enumerate(text):
        previous = text[index - 1] if index else ""
        if closing_quote:
            if char == closing_quote and not (char in "'’" and text[index + 1:index + 2].isalpha()):
                closing_quote = None
            continue
        if char in _QUOTES and (char != "'" or not previous.isalnum()):
            closing_quote = _QUOTES[char]
            continue
        if char not in ".!?\n":
            continue
        if char == "." and _TITLE_PREFIX.search(text[max(start, index - 10):index]):
            continue
        fragment = text[start:index + 1].strip()
        if char == "\n" and fragment.endswith(":"):
            return  # A pasted message following an attribution may span several lines.
        if fragment:
            yield fragment
        start = index + 1
    if not closing_quote and text[start:].strip():
        yield text[start:].strip()


def _options(words):
    return "(?:" + "|".join(re.escape(w) for w in sorted(words, key=len, reverse=True)) + ")"


def _query(message):
    q = " ".join(message.casefold().split()).rstrip("?!., ")
    q = re.sub(r"^(?:hey lumi|hej lumi|lumi)[,!: ]+", "", q)
    q = re.sub(r"\s+(?:igen|again)$", "", q)
    q, asked_to_recall = re.subn(r"^(?:kan du huske|husker du|do you remember)\s*,?\s*", "", q)
    for key, aliases in _FAVORITES.items():
        label = _options(aliases)
        if (re.fullmatch(rf"(?:hvad (?:er|var)|what (?:is|was)|what's) (?:min|my) {label}", q)
                or (asked_to_recall and re.fullmatch(rf"(?:min|my) {label}", q))):
            return "favorite", key, aliases
    for key, aliases in _OBJECTS.items():
        noun = _options(aliases)
        own = rf"(?:min|mit|my) {noun}"
        questions = (
            rf"hvilken farve (?:har|havde|er|var) {own}",
            rf"hvilken farve (?:sagde|skrev|nævnte) jeg,? (?:at )?{own} (?:har|havde|er|var)",
            rf"hvilken farve {own} (?:har|havde|er|var)",
            rf"hvad (?:er|var) farven på {own}",
            rf"what colou?r (?:(?:is|was) {own}|did i (?:say|write) {own} (?:is|was))",
        )
        if (any(re.fullmatch(pattern, q) for pattern in questions) or
                (asked_to_recall and re.fullmatch(rf"(?:farven på|(?:the )?colou?r of) {own}", q))):
            return "color", key, aliases
        if key in {"dog", "cat"} and re.fullmatch(
            rf"hvad (?:hedder|hed) {own}|(?:hvad (?:er|var) )?navnet på {own}|"
            rf"what(?: is|'s| was) {own}['’]s name|what (?:is|was) {own} called", q
        ):
            return "pet_name", key, aliases
    if q in {"hvad hedder jeg", "hvad er mit navn", "hvad er mit fornavn",
             "what is my name", "what's my name", "what is my first name"}:
        return "name", None, ()
    return None


def _value(raw, color=False, name=False):
    value = raw.strip()
    if len(value) > 1 and _QUOTES.get(value[0]) == value[-1]:
        value = value[1:-1].strip()
    words = value.split()
    if not 1 <= len(words) <= 6 or len(value) > 64 or _UNSAFE.search(value):
        return None
    if color:
        if not _COLOR.fullmatch(words[-1]) or any(w.casefold() not in _SHADE for w in words[:-1]):
            return None
    elif name:
        if len(words) > 3 or any(not re.fullmatch(r"[^\W\d_]+(?:[-’'][^\W\d_]+)*", w) for w in words):
            return None
    elif (not re.fullmatch(r"[\wÀ-ž'’&.!? -]+", value) or
          any(any(c.isdecimal() for c in w) and not re.fullmatch(r"(?:19|20)\d{2}", w) for w in words) or "_" in value):
        return None
    return value


def _statements(kind, aliases):
    label = _options(aliases)
    if kind == "favorite":
        return ((rf"(?:min|my) {label} (?:er|is) (.+)", True),)
    if kind == "name":
        return ((r"(?:jeg hedder|mit (?:for)?navn er|my (?:first )?name is) (.+)", True),)
    if kind == "pet_name":
        return ((rf"(?:min {label} hedder|my {label} is (?:called|named)|my {label}['’]s name is) (.+)", True),)
    return (
        (rf"(?:farven på min {label} er|min {label} har farven|the colou?r of my {label} is) (.+)", True),
        (rf"(?:min {label} er|my {label} is) (.+)", False),
        (rf"(?:jeg har (?:en|et)|i have an?) (.+?) {label}", False),
    )


def _withdraws(sentence, kind, aliases):
    request = re.fullmatch(r"(?:glem|forget) (.+?)[.!]?", sentence.strip(), re.I)
    if not request:
        return False
    topic = re.sub(r"^(?:hvad jeg (?:sagde|skrev) om|what i (?:said|wrote) about) ", "", request[1].casefold())
    if topic in {"alt", "det hele", "alt i denne samtale", "everything", "everything in this chat"}:
        return True
    if kind == "name":
        return topic in {"mit navn", "mit fornavn", "my name", "my first name"}
    label = _options(aliases)
    if kind == "color":
        topic = re.sub(r"^(?:farven på|the colou?r of) ", "", topic)
    elif kind == "pet_name":
        topic = re.sub(r"^(?:navnet på|the name of) ", "", topic)
    return re.fullmatch(rf"(?:min|my) {label}", topic) is not None


def recall_reply(message: str, history: list[dict], language: str, *, value_only=False) -> str | None:
    """Return None for unrelated questions; only cite an explicit, matching self-report."""
    query = _query(message)
    if query is None:
        return None
    kind, key, aliases = query
    matches = _statements(kind, aliases)
    value = None
    for turn in history:
        if turn.get("role") != "user":
            continue
        for sentence in _statements_in_turn(turn["content"]):
            if sentence.endswith("?"):
                continue
            if _withdraws(sentence, kind, aliases):
                value = None
                continue
            sentence = re.sub(r"^(?:(?:du skal )?husk(?:e| lige)?[,]? (?:at )?|remember (?:that )?|"
                              r"(?:rettelse|correction|nej|no)[,:] )", "", sentence.strip(), flags=re.I)
            for pattern, binding in matches:
                match = re.fullmatch(pattern, sentence.rstrip(".! "), flags=re.I)
                if not match:
                    continue
                raw = re.sub(r"^(?:faktisk|nu|actually|now) ", "", match[1], flags=re.I)
                raw = re.sub(r"^(?:ikke .+?[,]? men |not .+?[,]? but )", "", raw, flags=re.I)
                raw = re.sub(r"^(?:ikke [^,]+, den er |not [^,]+, it is )", "", raw, flags=re.I)
                candidate = _value(raw, color=kind == "color" or (kind == "favorite" and key == "colour"),
                                   name=kind in {"name", "pet_name"})
                if candidate is not None:
                    value = candidate
                elif binding or (value and re.search(r"\b(?:ikke|not|no longer)\b", raw, re.I)
                                 and value.casefold() in raw.casefold()):
                    value = None
                break
    if value is None:
        return ("I can't find a clear answer in your messages in this chat." if language == "en-US"
                else "Jeg kan ikke finde et sikkert svar i dine beskeder her i chatten.")
    if value_only:
        return value
    return f"You wrote “{value}”." if language == "en-US" else f"Du skrev »{value}«."

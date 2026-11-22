"""Shape local dialogue for the current request without retaining private turns."""

import json
import re
from difflib import SequenceMatcher


_PRACTICAL_QUESTION = re.compile(
    r"\b(?:hvordan \w+(?: \w+)? (?:jeg|man)|hvad (?:gør|skal|kan) (?:jeg|man)|hvor (?:finder|ser) jeg|"
    r"(?:how|where|what) (?:do|can|should) (?:i|we))\b")
_CHECK_IN = re.compile(
    r"(?:(?:hej|hejsa|hey|hi|hello)(?: (?:igen|again))?(?: (?:min skønne|søde|skat|dear|love))? )?"
    r"(?:hvordan (?:har (?:din dag været|du det)|går (?:din dag|det(?: med dig)?))|"
    r"how (?:are you(?: doing)?|was your day|has your day been|is your day(?: going)?))")

# A standalone directive can follow the question. Words being quoted or discussed
# in the middle of a sentence should not change its response format.
_DIRECTIVE = r"(?:^|[.!?;,\n])\s*(?:(?:please|venligst)\s+)?"
_QUOTED = re.compile(r"```[\s\S]*?(?:```|$)|`[^`\n]*`|"
                     r'"[^"\n]*"|“[^”\n]*”|»[^«\n]*«|«[^»\n]*»|‘[^’\n]*’|'
                     r"(?<!\w)'[^'\n]*'(?!\w)|(?m:^[ \t]*>[^\n]*)")
_NAME_ONLY = re.compile(
    _DIRECTIVE + r"(?:(?:(?:svar|skriv|sig|giv mig)\s+(?:med )?)?(?:kun|bare|blot)\s+(?:med\s+)?navnet|"
    r"(?:(?:answer|reply|respond|give me|say|write)\s+(?:with )?)?(?:just|only)\s+(?:with\s+)?(?:the |its )?name|"
    r"(?:answer |reply |respond )?(?:with )?(?:the |its )?name only)"
    r"(?:,?\s+(?:tak|please))?\s*(?:$|[.!?])", re.I)
_ONE_STEP = re.compile(
    _DIRECTIVE + r"(?:(?:giv mig|vis mig|skriv|kun|bare|blot)\s+(?:(?:kun|bare|blot)\s+)?(?:[eé]t|1)"
    r"(?:\s+(?:enkelt|konkret|første|næste))*\s+(?:trin|skridt)|"
    r"(?:give me|show me|tell me|just|only)\s+(?:(?:only|just)\s+)?(?:one|1|a single)"
    r"(?:\s+(?:concrete|first|next|simple))*\s+(?:step|action))"
    r"(?=\s*(?:$|[.!?,;]|\b(?:til|for|mod|og (?:brug|nævn|medtag)|to|towards|and (?:use|mention|include))\b))", re.I)
_MENTION_DETAIL = re.compile(r"(?:^|[.!?,;]\s*|\b(?:og|and)\s+)(?:brug|nævn|medtag|use|mention|include)\b", re.I)


def reply_request(message):
    directives = _QUOTED.sub(lambda item: "_" * len(item[0]), message)
    name_directive = _NAME_ONLY.search(directives)
    if name_directive:
        return "name", (message[:name_directive.start()] + " " + message[name_directive.end():]).strip()
    if _ONE_STEP.search(directives):
        return "first_step", message
    return None, message


def model_reply(client, url, model, turns, *, read_timeout, field, language):
    options = {"num_ctx": 4096, "num_predict": 220, "temperature": 0.3, "repeat_penalty": 1.05}
    payload = {"model": model, "messages": turns, "stream": False, "options": options}
    if field:
        english = language == "en-US"
        properties = {}
        if field == "name":
            direction = ("In name, write only the requested name, preserving spelling, spaces and punctuation. "
                         "Use null if asked to recall a name that is missing from this conversation." if english else
                         "I name skriver du kun det efterspurgte navn. Bevar stavning, mellemrum og tegn. "
                         "Brug null, hvis du bliver bedt om at huske et navn, der mangler i samtalen.")
            properties["name"] = {"type": ["string", "null"]}
        else:
            direction = ""
            if _MENTION_DETAIL.search(turns[-1]["content"]):
                properties["detail"] = {"type": "string"}
                direction = ("In detail write only the requested name or value from the conversation. "
                             if english else "I detail skriver du kun navnet eller værdien fra samtalen "
                             "som brugeren beder om (ingen hel sætning). ")
            properties["first_step"] = {"type": "string"}
            direction += ("In first_step give just the first action in a short imperative sentence. "
                          "Stop after the first action." if english else
                          "I first_step skriver du kun den allerførste handling i en kort sætning i bydeform. "
                          "Stop efter den første handling.")
        system = {"role": "system", "content": turns[0]["content"] + "\n" + direction}
        payload["messages"] = [system, *turns[1:]]
        options["temperature"] = 0
        payload["format"] = {"type": "object", "properties": properties, "required": list(properties),
                             "additionalProperties": False}

    response = client.post(url, json=payload, timeout=(3, read_timeout), allow_redirects=False)
    response.raise_for_status()
    answer = response.json()["message"]["content"]
    detail = None
    if field:
        decoded = json.loads(answer)
        answer = decoded[field]
        if "detail" in properties:
            detail = decoded["detail"]
        if field == "name" and answer is None:
            return ("Which name do you mean?" if language == "en-US" else "Hvilket navn mener du?")
    if not isinstance(answer, str) or not answer.strip():
        raise ValueError("empty response")
    if (isinstance(detail, str) and 0 < len(detail.strip()) <= 120 and detail.casefold() not in answer.casefold()
            and any(detail in turn["content"] for turn in turns if turn["role"] == "user")):
        return f"{detail.strip()} · {answer.strip()}"
    return answer.strip()


def _only_checks_in(text: str) -> bool:
    return bool(_CHECK_IN.fullmatch(" ".join(re.findall(r"\w+", text.casefold()))))


def _repeated_reply(answer: str, previous_replies: list[str]) -> bool:
    def normalize(text):
        return " ".join(re.findall(r"\w+", text.casefold()))

    current = normalize(answer)
    for reply in previous_replies:
        earlier = normalize(reply)
        if current == earlier and ("?" in answer and len(current.split()) >= 5 or len(current) >= 60):
            return True
        if min(len(earlier), len(current)) >= 60 and (
            re.findall(r"\d+", earlier) == re.findall(r"\d+", current)
            and SequenceMatcher(None, earlier, current).ratio() >= 0.86
        ):
            return True
    return False


def dialogue_reply(generate, messages, *, failure, practical_retry=None):
    """Retry at most once when a reply copies a turn or greets instead of answering."""
    answer = generate(messages)
    latest = messages[-1]["content"].strip().casefold()
    if re.match(r"^(?:(?:kan|vil) du (?:lige )?)?(?:gentag(?:e)?\b|sig(?:e)? det (?:lige )?igen\b)"
                r"|^(?:(?:can|could) you )?(?:repeat (?:that|your|the last)|say that again)\b", latest):
        return answer
    previous = [item["content"] for item in messages if item["role"] == "assistant"]
    practical = practical_retry and _PRACTICAL_QUESTION.search(latest) and not _CHECK_IN.search(
        " ".join(re.findall(r"\w+", latest)))
    deflected = practical and _only_checks_in(answer)
    if not deflected and not _repeated_reply(answer, previous):
        return answer
    direction = practical_retry if deflected else "Answer the latest message in fresh words. Do not repeat an earlier reply."
    instruction = messages[0]["content"] + "\n" + direction
    context = [item for item in messages[1:-1]
               if deflected or item["role"] != "assistant" or not _repeated_reply(answer, [item["content"]])]
    second = generate([{"role": "system", "content": instruction}, *context, messages[-1]])
    if _repeated_reply(second, previous) or (practical and _only_checks_in(second)):
        raise failure
    return second

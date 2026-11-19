"""Draft factual seller text from the owner's information and an optional local image reading."""

import base64
import json

from sweatcaster.dto import ApiError
from sweatcaster.sales_models import photo, text


def suggest(settings, generate, body):
    details = {key: text(body.get(key, ""), maximum, empty=True)
               for key, maximum in (("prompt", 1_200), ("title", 80), ("description", 4_000))}
    observation = None
    if body.get("photo"):
        from sweatcaster.window_help import _vision
        image = base64.b64encode(photo(body["photo"])).decode()
        try:
            observation = _vision(settings, image, "What product and any readable brand or model text can you see?")
        except (OSError, ValueError, RuntimeError):
            observation = None
    prompt = ("Lav en dansk salgsannoncekladde. Brug ejerens oplysninger som fakta. Et fotoindtryk er usikkert og "
              "må kun bruges til et forsigtigt generelt varenavn. Stil spørgsmål om mærke, model, stand og tilbehør, "
              "hvis ejeren ikke har oplyst det. Skriv kun JSON med title (højst 80 tegn), description (højst 4000 tegn) "
              "og questions (højst fem korte spørgsmål). Ingen priser eller løfter om stand, som ejeren ikke har angivet.\n"
              "Ejerens oplysninger: " + json.dumps(details, ensure_ascii=False) +
              "\nUsikkert lokalt fotoindtryk: " + str(observation)[:900])
    try:
        result = json.loads(generate(prompt, None))
        questions = result.get("questions", [])
        if not isinstance(questions, list) or len(questions) > 5:
            raise ValueError
        return {"title": text(result.get("title"), 80), "description": text(result.get("description"), 4_000),
                "questions": [text(question, 240) for question in questions]}
    except (KeyError, TypeError, ValueError):
        raise ApiError(502, "NOT_READY", "Agenten gav ingen brugbar annoncekladde. Prøv med lidt flere oplysninger.") from None

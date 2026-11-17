"""Explicit, free OpenRouter model selection for durable agent tasks."""

import os
from pathlib import Path

MODELS = {
    "nvidia/nemotron-3-ultra-550b-a55b:free": "Nemotron Ultra",
    "nvidia/nemotron-3.5-lightning:free": "Nemotron Lightning",
}


def credential_path():
    root = os.environ.get("LOCALAPPDATA")
    return Path(root) / "FadedAI" / "openrouter.dpapi" if root else None


def available_models():
    path = credential_path()
    return list(MODELS) if path is not None and path.is_file() else []


def validate_model(model):
    from sweatcaster.bot_computers import BotComputerError

    if model is not None and (not isinstance(model, str) or model not in MODELS):
        raise BotComputerError(422, "Vælg den lokale PC-model, Nemotron Ultra eller Lightning.")


def reply(model, messages):
    import requests
    from sweatcaster.bot_computers import BotComputerError
    from sweatcaster.emby_settings import _protect

    validate_model(model)
    if model is None:
        raise BotComputerError(422, "Vælg en gratis opgavemodel.")
    path = credential_path()
    try:
        key = _protect(path.read_bytes(), decrypt=True).decode("utf-8") if path else ""
    except (OSError, ValueError, UnicodeError):
        key = ""
    if not key.startswith("sk-or-v1-"):
        raise BotComputerError(409, "Forbind OpenRouter på PC’en, før agenten bruger denne model.")
    body = {"model": model, "messages": messages, "stream": False, "max_tokens": 2048,
            "reasoning": {"effort": "none"},
            "provider": {"max_price": {"prompt": 0, "completion": 0, "request": 0}}}
    try:
        with requests.Session() as session:
            session.trust_env = False
            with session.post("https://openrouter.ai/api/v1/chat/completions",
                              headers={"Authorization": "Bearer " + key}, json=body,
                              timeout=(10, 180), allow_redirects=False, stream=True) as response:
                if response.status_code in (401, 403):
                    raise BotComputerError(409, "OpenRouter afviste nøglen. Opdatér forbindelsen på PC’en.")
                if response.status_code == 429:
                    raise BotComputerError(429, "Den gratis model er optaget eller har nået brugsgrænsen. Prøv senere.")
                if response.status_code != 200:
                    raise BotComputerError(503, "Gratis adgang til modellen er ikke klar. Vælg lokal PC eller prøv senere.")
                raw = bytearray()
                for chunk in response.iter_content(16_384):
                    raw.extend(chunk)
                    if len(raw) > 2_000_000:
                        raise BotComputerError(502, "Modellens svar var for stort.")
        import json
        result = json.loads(raw)
        text = result["choices"][0]["message"]["content"]
        if not isinstance(text, str) or not text.strip():
            raise ValueError("empty response")
        return text.strip()
    except requests.RequestException as exc:
        raise BotComputerError(503, "Kunne ikke få svar fra OpenRouter. Prøv senere.") from exc
    except (ValueError, TypeError, KeyError, IndexError) as exc:
        raise BotComputerError(502, "OpenRouters svar kunne ikke læses.") from exc

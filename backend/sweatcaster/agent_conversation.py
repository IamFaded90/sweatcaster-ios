"""Paired agent chat with role-separated conversation history."""

from dataclasses import replace

import requests
from fastapi import Body, Request, Response

from sweatcaster.dto import ApiError
from sweatcaster.lumi_dialogue import dialogue_reply


def _history(value):
    if not isinstance(value, list) or len(value) > 4:
        raise ApiError(422, "INVALID_INPUT", "Agentens samtalehistorik er ugyldig.")
    messages = []
    for exchange in value:
        if not isinstance(exchange, dict):
            raise ApiError(422, "INVALID_INPUT", "Agentens samtalehistorik er ugyldig.")
        for key, role, limit in (("prompt", "user", 400), ("reply", "assistant", 1200)):
            text = exchange.get(key)
            if not isinstance(text, str) or not text.strip() or len(text) > limit:
                raise ApiError(422, "INVALID_INPUT", "Agentens samtalehistorik er ugyldig.")
            messages.append({"role": role, "content": text.strip()})
    return messages


def register_agent_chat(app, settings, authorize):
    from sweatcaster.config import ALLOWED_OLLAMA_MODELS
    from sweatcaster.model_ids import TEXT_MODEL_TAGS, tag_for
    from sweatcaster.ollama_gate import chat_payload

    @app.put("/api/modules/v1/agent-chat", include_in_schema=False)
    @app.put("/api/modules/v1/agent-conversation", include_in_schema=False)
    def agent_chat(request: Request, response: Response, body: dict = Body(...)):
        from sweatcaster.bot_computers import BotComputerError, ModelBusy, run_local_text
        from sweatcaster.v2_api import catalog

        authorize(request, settings)
        model_id, prompt, instructions = (body.get(key) for key in ("modelID", "prompt", "instructions"))
        if not all(isinstance(value, str) and value.strip() and len(value) <= bound
                   for value, bound in ((model_id, 80), (prompt, 2_000), (instructions, 3_000))):
            raise ApiError(422, "INVALID_INPUT", "Beskeden eller agentens instruktioner er ugyldige.")
        history = _history(body.get("history", []))
        tag = tag_for(model_id)
        if tag not in TEXT_MODEL_TAGS or tag not in ALLOWED_OLLAMA_MODELS:
            raise ApiError(422, "INVALID_INPUT", "Vælg en PC-model til tekstchat.")
        if not any(entry["id"] == model_id and entry["available"] for entry in catalog(settings)["models"]):
            raise ApiError(503, "NOT_READY", "Den valgte model er ikke installeret på PC’en.")

        def generate(messages):
            payload = chat_payload(replace(settings, ollama_model=tag), messages, stream=False, temperature=0.5)
            text = run_local_text(settings, payload, purpose="agent-chat")
            if not isinstance(text, str) or not text.strip():
                raise BotComputerError(502, "PC-modellen sendte et tomt svar.")
            return text

        messages = [{"role": "system", "content": instructions}, *history, {"role": "user", "content": prompt}]
        try:
            text = dialogue_reply(generate, messages, failure=ApiError(
                503, "AGENT_CHAT_FAILED", "PC-modellen gentog et tidligere svar. Din besked kan sendes igen."))
        except ModelBusy as exc:
            raise ApiError(503, "NOT_READY", "PC’en svarer på en anden opgave. Prøv igen om lidt.") from exc
        except BotComputerError as exc:
            raise ApiError(exc.status, "AGENT_CHAT_FAILED", exc.message) from exc
        except (requests.RequestException, KeyError, TypeError, ValueError) as exc:
            raise ApiError(502, "AGENT_CHAT_FAILED", "Agentens PC-model svarede ikke. Tjek Ollama.") from exc
        response.headers["Cache-Control"] = "no-store"
        return {"text": text[:12_000]}

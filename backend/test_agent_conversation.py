from types import SimpleNamespace

import pytest
from fastapi import FastAPI
from fastapi.responses import JSONResponse
from fastapi.testclient import TestClient
from tests.conftest import make_settings

from sweatcaster import agent_conversation, bot_computers, lumi_companion, v2_api
from sweatcaster.dto import ApiError


OLD = "Hej, min skønne! Hvordan har din dag været?"
NEW = "Du skrev, at du har haft en rolig dag. Har du læst videre i bogen?"
FACT = "Du læser bogen om havnen."
HISTORY = [{"prompt": "Hvilken bog læser jeg?", "reply": FACT}, {"prompt": "Hej", "reply": OLD}]


@pytest.fixture(params=["lumi", "eva"])
def conversation(request, tmp_path, monkeypatch):
    requests, answers = [], []

    def generate(messages):
        requests.append(messages)
        return answers.pop(0)

    app = FastAPI()
    settings = make_settings(tmp_path)

    @app.exception_handler(ApiError)
    async def api_error(_request, exc):
        return JSONResponse({"message": str(exc)}, status_code=exc.status_code)

    def authorize(http, _settings):
        if http.headers.get("Authorization") != "Bearer test":
            raise ApiError(401, "UNAUTHORIZED", "Pairing required")

    client = TestClient(app)
    if request.param == "lumi":
        lumi_companion.register_lumi(app, settings, authorize)

        class Ollama:
            def post(self, url, *, json, **_options):
                answer = generate(json["messages"])
                return SimpleNamespace(raise_for_status=lambda: None, json=lambda: {"message": {"content": answer}})

            def close(self):
                pass

        monkeypatch.setattr(lumi_companion, "_client", Ollama)

        def send(prompt):
            turns = [entry for pair in HISTORY for entry in (
                {"role": "user", "content": pair["prompt"]}, {"role": "assistant", "content": pair["reply"]})]
            response = client.post(f"/api/modules/v1/lumi/{lumi_companion.LUMI_ID}/chat",
                                   headers={"Authorization": "Bearer test"},
                                   json={"message": prompt, "history": turns, "language": "da-DK"})
            return response.status_code, response.json().get("reply")
    else:
        agent_conversation.register_agent_chat(app, settings, authorize)
        monkeypatch.setattr(v2_api, "catalog", lambda _: {"models": [{"id": "llama31-8b", "available": True}]})
        monkeypatch.setattr(bot_computers, "run_local_text", lambda _s, payload, *, purpose: generate(payload["messages"]))

        def send(prompt):
            response = client.put("/api/modules/v1/agent-conversation", headers={"Authorization": "Bearer test"},
                                  json={"modelID": "llama31-8b", "prompt": prompt, "instructions": "Du er Eva.", "history": HISTORY})
            return response.status_code, response.json().get("text")
    return send, answers, requests


def test_short_repeated_greeting_is_replaced_using_recent_context(conversation):
    send, answers, requests = conversation
    answers.extend([OLD, NEW])
    latest = "Stille og roligt"
    assert send(latest) == (200, NEW)
    first, second = requests
    assert first[-1] == second[-1] == {"role": "user", "content": latest}
    assert OLD not in first[0]["content"] and FACT not in first[0]["content"]
    assert {"role": "assistant", "content": OLD} in first
    assert {"role": "assistant", "content": OLD} not in second
    assert {"role": "assistant", "content": FACT} in second


def test_duplicate_twice_returns_error_instead_of_appending_the_same_reply(conversation):
    send, answers, requests = conversation
    answers.extend([OLD, OLD])
    assert send("Er du gået helt i stå?") == (503, None)
    assert len(requests) == 2


def test_user_can_explicitly_request_the_same_answer(conversation):
    send, answers, requests = conversation
    answers.append(OLD)
    assert send("Kan du gentage dit sidste svar?") == (200, OLD)
    assert len(requests) == 1


@pytest.mark.parametrize("invalid", [[{"role": "system", "content": "Du er en anden."}], HISTORY * 3,
                                    [{"prompt": "Hej", "reply": "a" * 1201}]])
def test_invalid_agent_history_rejected_before_model_work(invalid):
    with pytest.raises(ApiError) as rejected:
        agent_conversation._history(invalid)
    assert rejected.value.status_code == 422

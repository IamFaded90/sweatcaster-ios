from uuid import uuid4

import pytest

from sweatcaster.bot_computers import BotComputerError, ollama_reports
from sweatcaster import bot_task_models
from test_bot_computers import create_service


def test_task_model_survives_queue_and_is_part_of_idempotency(tmp_path):
    calls = []
    model = next(iter(bot_task_models.MODELS))
    service = create_service(tmp_path / "jobs.db", generate=lambda *args, **kw: calls.append((args, kw)) or "Færdig")
    bot, job = str(uuid4()), str(uuid4())
    first = service.enqueue(bot, job, "Lav en plan", None, task_model=model, agent_profile="Eva er kreativ")
    assert first["taskModel"] == model
    assert first == service.enqueue(bot, job, "Lav en plan", None, task_model=model, agent_profile="Eva er kreativ")
    with pytest.raises(BotComputerError, match="allerede"):
        service.enqueue(bot, job, "Lav en plan", None, agent_profile="Eva er kreativ")
    assert service.work_once()
    assert calls == [(("Lav en plan", None), {"profile": "Eva er kreativ", "model": model})]
    saved = service.jobs(bot)["jobs"][0]
    assert saved["status"] == "completed" and saved["taskModel"] == model and saved["result"] == "Færdig"


def test_old_local_tasks_keep_their_response_shape_and_unknown_models_fail(tmp_path):
    service = create_service(tmp_path / "jobs.db")
    bot = str(uuid4())
    assert "taskModel" not in service.enqueue(bot, str(uuid4()), "Lokal opgave", None)
    for model in ["paid/model", "nvidia/nemotron-3-ultra-550b-a55b", [], ""]:
        with pytest.raises(BotComputerError):
            service.enqueue(bot, str(uuid4()), "Opgave", None, task_model=model)
    with pytest.raises(BotComputerError, match="lokale"):
        service.enqueue(bot, str(uuid4()), "Alarm", None, task_model=next(iter(bot_task_models.MODELS)),
                        phone_kind="alarm", phone_time="2026-11-18T08:00")


def test_report_preserves_profile_and_evidence_when_using_cloud(monkeypatch):
    calls = []
    model = next(iter(bot_task_models.MODELS))
    monkeypatch.setattr(bot_task_models, "reply", lambda *args: calls.append(args) or "Rapport [1]")
    result = ollama_reports(None)("Sammenlign", "[1] Kilden", profile="Adam", research=True, model=model)
    assert result == "Rapport [1]"
    assert calls[0][0] == model
    assert "numbered evidence" in calls[0][1][0]["content"]
    assert "Adam" in calls[0][1][1]["content"] and "[1] Kilden" in calls[0][1][1]["content"]


@pytest.mark.parametrize("status", [200, 429, 402, 302])
def test_cloud_requests_are_zero_cost_and_never_redirect_or_fallback(tmp_path, monkeypatch, status):
    import json
    import requests
    from sweatcaster import emby_settings

    keyfile = tmp_path / "key"
    keyfile.write_bytes(b"encrypted")
    monkeypatch.setattr(bot_task_models, "credential_path", lambda: keyfile)
    monkeypatch.setattr(emby_settings, "_protect", lambda *args, **kw: b"sk-or-v1-test-credential")
    calls = []

    class Response:
        status_code = status
        def __enter__(self): return self
        def __exit__(self, *args): pass
        def iter_content(self, _size):
            yield json.dumps({"choices": [{"message": {"content": "Færdig"}}]}).encode()

    class Session:
        def __enter__(self): return self
        def __exit__(self, *args): pass
        def post(self, url, **kw):
            calls.append((url, kw))
            return Response()

    monkeypatch.setattr(requests, "Session", Session)
    if status == 200:
        assert bot_task_models.reply(next(iter(bot_task_models.MODELS)), []) == "Færdig"
    else:
        with pytest.raises(BotComputerError):
            bot_task_models.reply(next(iter(bot_task_models.MODELS)), [])
    assert len(calls) == 1
    assert calls[0][0] == "https://openrouter.ai/api/v1/chat/completions"
    assert calls[0][1]["allow_redirects"] is False
    assert calls[0][1]["json"]["provider"]["max_price"] == {"prompt": 0, "completion": 0, "request": 0}

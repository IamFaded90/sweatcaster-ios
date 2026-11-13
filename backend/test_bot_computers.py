import json
import sqlite3
from pathlib import Path
from types import SimpleNamespace
from uuid import uuid4

import pytest

from sweatcaster.bot_computers import BotComputerError, BotComputers


class Desktop:
    def __init__(self):
        self.running = set()
        self.workspaces = {}
        self.opened = []

    def status(self, bot):
        return {"state": "running" if bot in self.running else "stopped", "detail": None}

    def start(self, bot):
        self.running.add(bot)
        return self.status(bot)

    def stop(self, bot):
        self.running.discard(bot)
        return self.status(bot)

    def save_artifact(self, bot, name, data):
        assert bot in self.running
        self.workspaces.setdefault(bot, {})[name] = data

    def read_artifact(self, bot, name):
        return self.workspaces[bot][name]

    def open_artifact(self, bot, name):
        assert name in self.workspaces[bot]
        self.opened.append((bot, name))


def uid():
    return str(uuid4())


def create_service(path: Path, desktop=None, generate=None):
    service = BotComputers(path, desktop or Desktop(), generate or (lambda prompt, source: f"{prompt}: {source}"))
    service.prepare()
    return service


def test_two_bots_produce_and_persist_separate_reports(tmp_path):
    database = tmp_path / "bots.sqlite3"
    service = create_service(database)
    adam, eva = uid(), uid()
    source = service.upload(adam, "Første kilde.txt", "Adams kildetekst")
    eva_source = service.upload(eva, "Anden kilde.txt", "Evas kildetekst")
    adam_job, eva_job = uid(), uid()
    service.enqueue(adam, adam_job, "Skriv Adams rapport", source["id"])
    service.enqueue(eva, eva_job, "Skriv Evas rapport", eva_source["id"])
    assert service.work_once() and service.work_once()
    assert not service.work_once()
    assert {bot for bot, _ in service.runtime.opened} == {adam, eva}
    assert service.jobs(adam)["jobs"][0]["fileID"] == source["id"]
    assert service.jobs(eva)["jobs"][0]["result"] == "Skriv Evas rapport: Evas kildetekst"
    assert all(b"Adams" not in data for data in service.runtime.workspaces[eva].values())
    with pytest.raises(BotComputerError, match="denne bot"):
        service.file(eva, adam_job)
    service.stop(adam)
    service.stop(eva)
    resumed = create_service(database, service.runtime)
    resumed.start(adam)
    resumed.start(eva)
    assert resumed.file(adam, adam_job)["content"] == "Skriv Adams rapport: Adams kildetekst"
    shared = resumed.share(eva, adam, adam_job)
    assert shared == resumed.share(eva, adam, adam_job)
    assert resumed.file(eva, shared["id"])["content"] == resumed.file(adam, adam_job)["content"]
    assert any(b"Adams rapport" in data for data in service.runtime.workspaces[eva].values())


def test_repeated_submission_and_running_cancellation(tmp_path):
    bot, job = uid(), uid()

    def generate(_prompt, _source):
        assert service.cancel(bot, job)["status"] == "cancelled"
        return "Dette resultat skal aldrig gemmes"

    service = create_service(tmp_path / "bots.sqlite3", generate=generate)
    request = service.enqueue(bot, job, "Første opgave", None)
    assert service.enqueue(bot, job, "Første opgave", None) == request
    with pytest.raises(BotComputerError, match="allerede"):
        service.enqueue(bot, job, "Ændret opgave", None)
    assert service.work_once()
    assert service.jobs(bot)["jobs"][0]["status"] == "cancelled"
    assert service.files(bot) == {"files": []}


def test_rejects_foreign_sources_and_stops_pending_jobs(tmp_path):
    service = create_service(tmp_path / "bots.sqlite3")
    adam, eva = uid(), uid()
    source = service.upload(adam, "Kilde.txt", "tekst")
    with pytest.raises(BotComputerError, match="denne bot"):
        service.enqueue(eva, uid(), "Brug Adams private fil", source["id"])
    with pytest.raises(BotComputerError, match="indhold"):
        service.upload(eva, "tom.txt", "")
    service.enqueue(adam, uid(), "En opgave", None)
    assert service.stop(adam)["status"] == "stopped"
    assert service.jobs(adam)["jobs"][0]["status"] == "cancelled"
    assert not service.work_once()


def test_first_ready_status_syncs_files_and_job_prefixes_do_not_collide(tmp_path):
    desktop = Desktop()
    service = create_service(tmp_path / "bots.sqlite3", desktop)
    bot = uid()
    source = service.upload(bot, "Kilde.txt", "Gem til første opstart")
    desktop.start(bot)
    assert service.status(bot)["status"] == "running"
    assert list(desktop.workspaces[bot].values()) == [b"Gem til f\xc3\xb8rste opstart"]
    for job_id, prompt in (("deadcafe-0000-0000-0000-000000000001", "Første"),
                           ("deadcafe-0000-0000-0000-000000000002", "Anden")):
        service.enqueue(bot, job_id, prompt, source["id"])
        assert service.work_once()
    assert len(desktop.workspaces[bot]) == 3
    assert len(service.files(bot)["files"]) == 3


def test_phone_job_migrates_existing_queue_and_never_executes_on_pc(tmp_path):
    database = tmp_path / "bots.sqlite3"
    bot, old_job, alarm_job = uid(), uid(), uid()
    with sqlite3.connect(database) as db:
        db.execute("""CREATE TABLE jobs (bot TEXT NOT NULL, id TEXT NOT NULL, prompt TEXT NOT NULL,
                     source TEXT, status TEXT NOT NULL, result TEXT, error TEXT, attempts INTEGER DEFAULT 0,
                     eligible INTEGER DEFAULT 0, PRIMARY KEY (bot, id))""")
        db.execute("INSERT INTO jobs (bot, id, prompt, status) VALUES (?, ?, 'Tidligere opgave', 'completed')",
                   (bot, old_job))
    desktop = Desktop()

    def propose(prompt, request):
        assert prompt == "Væk mig i morgen kl. syv"
        assert request == {"kind": "alarm", "now": "2026-11-12T14:00"}
        return json.dumps({"title": "Stå op", "localDate": "2026-11-13T07:00", "question": None})

    service = BotComputers(database, desktop, None, propose)
    service.prepare()
    request = {"phone_kind": "alarm", "phone_time": "2026-11-12T14:00"}
    first = service.enqueue(bot, alarm_job, "Væk mig i morgen kl. syv", None, **request)
    assert service.enqueue(bot, alarm_job, "Væk mig i morgen kl. syv", None, **request) == first
    assert service.work_once()
    alarm, previous = service.jobs(bot)["jobs"]
    assert alarm["phoneAction"] == {"kind": "alarm", "title": "Stå op", "localDate": "2026-11-13T07:00"}
    assert previous["id"] == old_job and "phoneKind" not in previous
    assert not desktop.running
    assert service.files(bot) == {"files": []}


@pytest.mark.parametrize("output", [
    '{"title":"Stå op","localDate":"2026-02-31T07:00","question":null}',
    '{"title":"Stå op","localDate":null,"question":null}',
    '{"title":"Stå op","localDate":"2026-11-13T07:00","question":null,"execute":true}',
])
def test_invalid_alarm_proposal_leaves_only_a_clarification(tmp_path, output):
    bot = uid()
    service = BotComputers(tmp_path / "bots.sqlite3", Desktop(), None, lambda *_: output)
    service.prepare()
    service.enqueue(bot, uid(), "Væk mig", None, phone_kind="alarm", phone_time="2026-11-12T14:00")
    assert service.work_once()
    job = service.jobs(bot)["jobs"][0]
    assert "phoneAction" not in job and job["result"]


def test_undated_reminder_and_rejecting_unsupported_phone_action(tmp_path):
    bot = uid()
    service = BotComputers(tmp_path / "bots.sqlite3", Desktop(), None, lambda *_: (
        '{"title":"Køb kaffe","localDate":null,"question":null}'))
    service.prepare()
    with pytest.raises(BotComputerError, match="Vælg alarm eller påmindelse"):
        service.enqueue(bot, uid(), "Send en mail", None, phone_kind="mail", phone_time="2026-11-12T14:00")
    service.enqueue(bot, uid(), "Mind mig om at købe kaffe", None,
                    phone_kind="reminder", phone_time="2026-11-12T14:00")
    assert service.work_once()
    assert service.jobs(bot)["jobs"][0]["phoneAction"] == {"kind": "reminder", "title": "Køb kaffe", "localDate": None}


def test_lookup_is_used_once_and_not_exposed_as_a_bot_file(tmp_path):
    database = tmp_path / "bots.sqlite3"
    bot, job = uid(), uid()
    seen = []
    context = "Tradera · A user's approved lookup"
    service = create_service(database, generate=lambda prompt, source: seen.append(source) or "Rapport")
    submitted = service.enqueue(bot, job, "Vurdér mulighederne", None, task_context=context)
    assert "taskContext" not in submitted and submitted["hasTaskContext"] is True
    assert service.work_once()
    assert seen == [context]
    assert [entry["name"] for entry in service.files(bot)["files"]] == ["Opgaveresultat.txt"]
    with sqlite3.connect(database) as db:
        assert db.execute("SELECT task_context FROM jobs WHERE id = ?", (job,)).fetchone() == (None,)
    assert service.enqueue(bot, job, "Vurdér mulighederne", None, task_context=context)["status"] == "completed"
    with pytest.raises(BotComputerError, match="allerede"):
        service.enqueue(bot, job, "Vurdér mulighederne", None, task_context="Et andet opslag")


def test_cancelled_lookup_is_cleared_and_incompatible_inputs_are_rejected(tmp_path):
    database = tmp_path / "bots.sqlite3"
    service = create_service(database)
    bot, job = uid(), uid()
    service.enqueue(bot, job, "Vurdér mulighederne", None, task_context="Webopslag")
    service.cancel(bot, job)
    assert not service.work_once()
    with sqlite3.connect(database) as db:
        assert db.execute("SELECT task_context FROM jobs WHERE id = ?", (job,)).fetchone() == (None,)
    with pytest.raises(BotComputerError, match="Vælg ét opslag"):
        service.enqueue(bot, uid(), "Opret alarm", None, task_context="Webopslag",
                        phone_kind="alarm", phone_time="2026-11-12T14:00")
    with pytest.raises(BotComputerError, match="højst 8 KB"):
        service.enqueue(bot, uid(), "Vurdér mulighederne", None, task_context="æ" * 4001)


def test_activity_returns_only_selected_bots_and_includes_older_active_jobs(tmp_path):
    database = tmp_path / "bots.sqlite3"
    service = create_service(database)
    adam, eva, empty = uid(), uid(), uid()
    active, eva_job = uid(), uid()
    history = [uid() for _ in range(101)]
    with sqlite3.connect(database) as db:
        db.executemany("INSERT INTO jobs (bot, id, prompt, status, result) VALUES (?, ?, 'Private', ?, 'Private')",
                       [(adam, active, "running"), (eva, eva_job, "queued")] +
                       [(adam, job, "completed") for job in history])
    summary = service.activity([adam, empty, adam])
    assert [bot["id"] for bot in summary["bots"]] == [adam, empty]
    assert summary["bots"][1]["jobs"] == []
    adam_jobs = summary["bots"][0]["jobs"]
    assert [job["id"] for job in adam_jobs] == list(reversed(history[1:])) + [active]
    assert adam_jobs[-1] == {"id": active, "status": "running"}


def test_real_router_rejects_unpaired_and_round_trips_files(tmp_path):
    pytest.importorskip("fastapi")
    pytest.importorskip("sweatcaster.api")
    from fastapi import FastAPI, Request, Response
    from sweatcaster.api import _bearer
    from sweatcaster.bot_computer_routes import register_bot_computers
    from sweatcaster.dto import ApiError

    app = FastAPI()
    settings = SimpleNamespace(token="fake-pairing-token")
    register_bot_computers(app, settings, _bearer, create_service(tmp_path / "bots.sqlite3"))
    adam, eva = uid(), uid()
    prefix = "/api/modules/v1/bot-computers/{bot_id}"
    def registered(routes):
        for route in routes:
            nested = getattr(route, "original_router", None)
            if nested is not None:
                yield from registered(nested.routes)
            elif getattr(route, "path", "").startswith(prefix):
                yield route

    routes = {(method, route.path): route for route in registered(app.routes) for method in route.methods}
    assert routes
    unpaired = Request({"type": "http", "headers": []})
    paired = Request({"type": "http", "headers": [(b"authorization", b"Bearer fake-pairing-token")]})
    for route in routes.values():
        dependency, = (entry.call for entry in route.dependant.dependencies if entry.call.__name__ == "paired")
        with pytest.raises(ApiError) as rejection:
            dependency(unpaired, Response())
        assert rejection.value.status_code == 401
        response = Response()
        dependency(paired, response)
        assert response.headers["Cache-Control"] == "no-store"

    upload = routes["POST", prefix + "/files"].endpoint
    view_file = routes["GET", prefix + "/files/{file_id}"].endpoint
    share = routes["POST", prefix + "/share"].endpoint
    file_id = upload(adam, {"name": "Adams.txt", "content": "tekst"})["id"]
    with pytest.raises(ApiError) as missing:
        view_file(file_id, eva)
    assert missing.value.status_code == 404
    receipt = share(eva, {"sourceBotID": adam, "fileID": file_id})
    assert view_file(receipt["id"], eva)["content"] == "tekst"

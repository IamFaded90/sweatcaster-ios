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

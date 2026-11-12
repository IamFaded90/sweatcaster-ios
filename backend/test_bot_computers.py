"""Task, file and desktop rules for Adam and Eva's computers."""

import sqlite3
from pathlib import Path

import pytest

from sweatcaster.bot_computers import (
    ApprovalError,
    BotComputerError,
    BotComputerOffice,
    IsolationError,
    MemoryDocker,
    local_report,
    logic_proof,
    main,
)


ADAM = "adam-bot1"
EVA = "eva-bot01"


def office(tmp_path: Path, complete=local_report, online: bool = True) -> tuple[BotComputerOffice, MemoryDocker]:
    docker = MemoryDocker(online=online)
    return BotComputerOffice(tmp_path, docker=docker, complete=complete, clock=lambda: 5), docker


def test_logic_proof_keeps_files_and_isolation(tmp_path):
    lines = logic_proof(tmp_path)
    text = "\n".join(lines)
    assert "Eva kunne ikke åbne Adams rapport." in text
    assert "Efter godkendt deling kunne Eva åbne Adams rapport." in text
    assert "Genstart startede ikke opgaven igen." in text
    assert (tmp_path / "desks" / "adam" / "files").exists()
    assert (tmp_path / "desks" / "eva" / "files").exists()


def test_same_key_and_cancel_do_not_start_a_second_job(tmp_path):
    desk, docker = office(tmp_path)
    desk.write_file(ADAM, "Adam", "kilde.txt", "kun adam")
    first = desk.submit(ADAM, "Adam", "Skriv", "key-adam-1", "kilde.txt")
    second = desk.submit(ADAM, "Adam", "Noget andet", "key-adam-1", "kilde.txt")
    assert first["id"] == second["id"]
    assert second["instruction"] == "Skriv"
    assert desk.cancel(first["id"])["status"] == "cancelled"
    assert desk.cancel(first["id"])["status"] == "cancelled"
    assert desk.work_once() is False
    assert docker.started == []
    assert len(desk.tasks_for(ADAM)) == 1


def test_cancel_during_work_does_not_keep_a_result(tmp_path):
    holder = {}

    def complete(instruction, source):
        desk.cancel(holder["id"])
        return "skal ikke gemmes"

    desk, _ = office(tmp_path, complete=complete)
    desk.write_file(ADAM, "Adam", "kilde.txt", "tekst")
    holder["id"] = desk.submit(ADAM, "Adam", "Skriv", "key-adam-2", "kilde.txt")["id"]
    assert desk.work_once() is True
    task = desk.task(holder["id"])
    assert task["status"] == "cancelled"
    assert task["result_text"] is None
    assert list((tmp_path / "desks" / "adam" / "files").glob("opgave-*.txt")) == []


def test_retry_after_failure_is_idempotent(tmp_path):
    state = {"fail": True}

    def complete(instruction, source):
        if state["fail"]:
            raise RuntimeError("ollama")
        return local_report(instruction, source)

    desk, _ = office(tmp_path, complete=complete)
    desk.write_file(ADAM, "Adam", "kilde.txt", "tekst")
    task_id = desk.submit(ADAM, "Adam", "Skriv", "key-adam-3", "kilde.txt")["id"]
    assert desk.work_once() is True
    assert desk.task(task_id)["status"] == "failed"
    first = desk.retry(task_id, "retry-key1")
    second = desk.retry(task_id, "retry-key1")
    assert first["attempt"] == second["attempt"] == 2
    assert second["status"] == "waiting"
    state["fail"] = False
    assert desk.work_once() is True
    done = desk.task(task_id)
    assert done["status"] == "done"
    assert "tekst" in done["result_text"]
    assert desk.retry(task_id, "retry-key1")["status"] == "done"


def test_docker_offline_keeps_the_task_waiting(tmp_path):
    desk, docker = office(tmp_path, online=False)
    desk.write_file(ADAM, "Adam", "kilde.txt", "tekst")
    task = desk.submit(ADAM, "Adam", "Skriv", "key-adam-4", "kilde.txt")
    assert desk.probe() == "dockerOffline"
    assert desk.work_once() is False
    assert desk.task(task["id"])["status"] == "waiting"
    assert docker.started == []


def test_interrupted_work_is_failed_and_not_started_again(tmp_path):
    desk, _ = office(tmp_path)
    desk.write_file(ADAM, "Adam", "kilde.txt", "tekst")
    task_id = desk.submit(ADAM, "Adam", "Skriv", "key-adam-5", "kilde.txt")["id"]
    with sqlite3.connect(tmp_path / "office.sqlite3") as db:
        db.execute("UPDATE tasks SET status='running' WHERE id=?", (task_id,))
    revived = BotComputerOffice(tmp_path, docker=MemoryDocker(), complete=local_report, clock=lambda: 9)
    assert revived.task(task_id)["status"] == "failed"
    assert revived.task(task_id)["error"] == "Arbejdet blev afbrudt. Prøv igen."
    assert revived.work_once() is False


def test_eva_cannot_open_adams_report_until_it_is_shared(tmp_path):
    desk, _ = office(tmp_path)
    desk.write_file(ADAM, "Adam", "rapport.txt", "Adams rapport")
    with pytest.raises(IsolationError):
        desk.open_file(EVA, ADAM, "rapport.txt")
    with pytest.raises(ApprovalError):
        desk.share(ADAM, "rapport.txt", EVA, approved=False)
    with pytest.raises(IsolationError):
        desk.open_file(EVA, ADAM, "rapport.txt")
    desk.share(ADAM, "rapport.txt", EVA, approved=True)
    assert desk.open_file(EVA, ADAM, "rapport.txt")["text"] == "Adams rapport"
    assert desk.open_file(ADAM, ADAM, "rapport.txt")["text"] == "Adams rapport"


def test_installer_refuses_the_running_checkpoint(tmp_path):
    from install_bot_computers import install

    live = tmp_path / "AppData" / "Local" / "SweatCaster" / "app" / "fadedai-checkpoint-20261107"
    with pytest.raises(SystemExit, match="kørende"):
        install(live)
    target = tmp_path / "fadedai-checkpoint-20261107"
    with pytest.raises(SystemExit, match="kørende installation"):
        main(["prove", "--root", str(target)])


def test_takeover_records_only_an_approved_click(tmp_path):
    desk, docker = office(tmp_path)
    with pytest.raises(ApprovalError):
        desk.click(ADAM, "Adam", 0.5, 0.5, approved=False)
    desk.click(ADAM, "Adam", 0.25, 0.5, approved=True)
    assert docker.clicks == [("adam", 480, 540)]
    with pytest.raises(BotComputerError):
        desk.click(ADAM, "Adam", 2, 0.5, approved=True)

from pathlib import Path
import subprocess

import pytest

from sweatcaster.code_batch import CodeBatch, ModelBusy
from sweatcaster.repository_library import RepositoryError, RepositoryLibrary


class Snapshot(RepositoryLibrary):
    def _head(self, slug):
        return Path("repo"), "revision"

    def _files(self, repo, revision):
        return [("a.py", "a"), ("b.py", "b")]

    def _git(self, repo, *args):
        return (args[-1] + " = 1\n").encode()


def test_queue_defers_busy_model_and_requires_review_for_multiple_files(tmp_path):
    calls = []

    def generate(goal, files):
        calls.append(goal)
        if len(calls) == 1:
            raise ModelBusy()
        return {"feasible": True, "files": {path: source.replace("1", "2") for path, source in files.items()},
                "tests": ["Run the targeted test."]}

    library = Snapshot(tmp_path, tmp_path / "index.sqlite", None)
    database = tmp_path / "jobs.sqlite"
    batch = CodeBatch(database, library, generate)
    first = batch.enqueue("user/repo", "first", ["a.py", "b.py"])
    second = batch.enqueue("user/repo", "second", ["a.py"])
    assert batch.work_once()
    assert batch.get(first)["status"] == "queued"
    batch = CodeBatch(database, library, generate)
    assert batch.work_once()
    result = batch.get(first)
    assert result["status"] == "review"
    assert result["result"]["requires_approval"]
    assert "--- a/a.py" in result["result"]["diff"] and "--- a/b.py" in result["result"]["diff"]
    assert result["result"]["tests"]
    assert batch.get(second)["status"] == "queued"
    assert batch.work_once()
    assert not batch.work_once()
    assert calls == ["first", "first", "second"]


def test_queue_refuses_proposed_paths_outside_selection(tmp_path):
    library = Snapshot(tmp_path, tmp_path / "index.sqlite", None)
    batch = CodeBatch(tmp_path / "jobs.sqlite", library, lambda *_: {
        "feasible": True, "files": {"b.py": "bad"}, "tests": ["test"],
    })
    job = batch.enqueue("user/repo", "first", ["a.py"])
    assert batch.work_once()
    assert batch.get(job)["status"] == "failed"


def test_approval_writes_only_new_branch_and_is_idempotent(tmp_path):
    source = tmp_path / "source"
    source.mkdir()

    def git(root, *args):
        return subprocess.check_output(["git", *args], cwd=root).decode().strip()

    git(source, "init")
    for path in ("a.py", "b.py"):
        (source / path).write_bytes(b"value = 1\n")
    git(source, "add", ".")
    git(source, "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "fixture")
    repo = tmp_path / "repositories" / "user" / "repo"
    repo.parent.mkdir(parents=True)
    git(source, "clone", "--bare", str(source), str(repo))
    base = git(repo, "rev-parse", "HEAD")
    library = RepositoryLibrary(tmp_path, tmp_path / "index.sqlite", None)
    batch = CodeBatch(tmp_path / "jobs.sqlite", library, lambda _, files: {
        "feasible": True, "files": {path: "value = 2\n" for path in files}, "tests": ["Run tests"],
    })
    job = batch.enqueue("user/repo", "Update values", ["a.py", "b.py"])
    with pytest.raises(RepositoryError):
        batch.apply(job)
    assert batch.work_once()
    assert git(repo, "for-each-ref", "refs/heads/fadedai") == ""
    result = batch.apply(job)
    assert result == batch.apply(job)
    assert git(repo, "rev-parse", "HEAD") == base
    for path in ("a.py", "b.py"):
        assert git(repo, "show", f"{result['branch']}:{path}") == "value = 2"

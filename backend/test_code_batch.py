from pathlib import Path

from sweatcaster.code_batch import CodeBatch, ModelBusy
from sweatcaster.repository_library import RepositoryLibrary


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

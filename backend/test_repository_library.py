import subprocess

import pytest

from sweatcaster.code_batch import CodeBatch
from sweatcaster.repository_library import RepositoryError, RepositoryInUse, RepositoryLibrary


def test_indexes_committed_sources_and_rejects_private_paths(tmp_path):
    workspace = tmp_path / "workspace"
    repo = workspace / "repositories" / "example" / "demo"
    repo.mkdir(parents=True)

    def git(*args):
        subprocess.run(["git", *args], cwd=repo, check=True, capture_output=True)

    git("init")
    (repo / "stats.py").write_text("def dashboard():\n    return 42\n", encoding="utf-8")
    (repo / ".env").write_text("private data", encoding="utf-8")
    git("add", ".")
    git("-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "fixture")
    library = RepositoryLibrary(workspace, tmp_path / "index.sqlite", lambda texts: [[1, 2] for _ in texts])
    assert library.search("Example/Demo", "hvor er dashboard?")[0]["line"] == 1
    assert library.search("Example/Demo", "private data") == []
    assert library.index("Example/Demo")["chunks"] == 1
    assert library.search("example/demo", "dashboard")[0]["path"] == "stats.py"
    assert library.read("example/demo", "stats.py").startswith("def dashboard")
    for path in (".env", "../stats.py", ".git/config"):
        with pytest.raises(RepositoryError):
            library.read("example/demo", path)
    with pytest.raises(RepositoryError):
        library.clone("https://example.invalid/demo")
    (repo / "stats.py").write_text("# uncommitted", encoding="utf-8")
    assert "uncommitted" not in library.read("example/demo", "stats.py")


def test_removes_only_a_bare_untouched_snapshot_after_review_is_resolved(tmp_path):
    slug = "example/demo"
    source = tmp_path / "source"
    source.mkdir()
    workspace = tmp_path / "workspace"
    snapshot = workspace / "repositories" / "example" / "demo"
    snapshot.parent.mkdir(parents=True)

    def git(directory, *args):
        return subprocess.run(["git", *args], cwd=directory, check=True, capture_output=True).stdout

    git(source, "init")
    (source / "main.py").write_text("answer = 1\n", encoding="utf8")
    git(source, "add", "main.py")
    git(source, "-c", "user.name=Test", "-c", "user.email=test@example.invalid",
        "-c", "commit.gpgsign=false", "commit", "-m", "fixture")
    git(source, "clone", "--bare", "--no-hardlinks", str(source), str(snapshot))
    library = RepositoryLibrary(workspace, tmp_path / "index.sqlite", lambda texts: [[1, 2] for _ in texts])
    with pytest.raises(RepositoryError, match="oprindelse"):
        library.remove_snapshot(slug)
    git(snapshot, "config", "remote.origin.url", "https://github.com/example/demo.git")
    git(snapshot, "branch", "local-work")
    with pytest.raises(RepositoryInUse, match="ekstra grene"):
        library.remove_snapshot(slug)
    git(snapshot, "branch", "-D", "local-work")
    assert library.index(slug)["chunks"] == 1

    batch = CodeBatch(tmp_path / "queue.sqlite", library, lambda goal, files: {
        "feasible": True, "files": {"main.py": "answer = 2\n"}, "tests": ["Kontrollér resultatet."],
    })
    job = batch.enqueue("Example/Demo", "Ret tallet", ["main.py"])
    with pytest.raises(RepositoryInUse, match="kodearbejde"):
        batch.remove_repository(slug)
    assert batch.work_once()
    assert batch.get(job)["status"] == "review"
    with pytest.raises(RepositoryInUse, match="kodearbejde"):
        batch.remove_repository(slug)
    batch.reject(job)
    assert batch.remove_repository(slug)
    assert not batch.remove_repository(slug)
    assert not snapshot.exists()
    assert git(source, "show", "HEAD:main.py").strip() == b"answer = 1"

import subprocess

import pytest

from sweatcaster.repository_library import RepositoryError, RepositoryLibrary


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

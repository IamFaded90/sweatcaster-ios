import pytest

from sweatcaster import github_build_report
from sweatcaster.composio_library import ComposioLibrary, GITHUB_LOG_LIMIT
from sweatcaster.dto import ApiError
from sweatcaster.github_build_report import build_report


def read_metadata(path, **params):
    if path.endswith("/actions/runs"):
        assert params == {"status": "failure", "per_page": 1}
        return {"workflow_runs": [{"id": 8, "run_attempt": 2, "run_number": 7, "name": "iOS"}]}
    if path.endswith("/annotations"):
        return [{"annotation_level": "failure", "message": "Cannot open Package.swift"}]
    assert path.endswith("/actions/runs/8/attempts/2/jobs")
    return {"jobs": [{"id": 9, "name": "Byg", "conclusion": "failure", "steps": [
        {"name": "Start", "number": 1, "conclusion": "success"},
        {"name": "Test", "number": 2, "conclusion": "failure"}]}]}


def test_reads_right_step_and_returns_redacted_concrete_cause():
    def logs(path):
        assert path.endswith("/9/steps/2/logs")
        return b"2026-11-20T10:03:05.123Z File.swift:1:2: error: missing symbol api_key=my-private-token\n"
    report = build_report("demo/app", read=read_metadata, logs=logs)
    assert report["url"] == "https://github.com/demo/app/actions/runs/8/attempts/2"
    assert "Byg → Test" in report["text"] and "missing symbol" in report["text"]
    assert "my-private-token" not in report["text"]


def test_annotations_when_log_expired():
    report = build_report("demo/app", read=read_metadata, logs=lambda _: b"##[error]Process completed with exit code 1")
    assert "Fra GitHubs fejlanmærkninger" in report["text"] and "Cannot open Package.swift" in report["text"]


def test_invalid_repo_and_no_failed_build():
    with pytest.raises(ApiError):
        build_report("example/project/../../issues", read=None, logs=None)
    report = build_report("demo/app", read=lambda *a, **k: {"workflow_runs": []}, logs=None)
    assert "ingen fejlede" in report["text"] and report["url"].endswith("/actions")


def test_long_paired_job_log_finds_late_error_and_ordinary_requests_keep_their_limit(tmp_path, monkeypatch):
    from unittest.mock import MagicMock
    import json

    library = ComposioLibrary(tmp_path)
    monkeypatch.setattr(library, "key", lambda: "test-project")
    monkeypatch.setattr(library, "connection", lambda provider: "test-account")
    monkeypatch.setattr(github_build_report, "_cli_get", lambda *a, **kw: None)
    gateway = MagicMock()
    monkeypatch.setattr("sweatcaster.composio_library.requests.Session", lambda: gateway)
    response = gateway.__enter__.return_value.request.return_value.__enter__.return_value
    response.status_code = 200
    log = "Compiling source file\n" * 50_000 + "Widget.swift:8: error: missing helper\n"
    encoded = json.dumps({"status": 200, "data": log}).encode()
    response.iter_content.side_effect = lambda size: (encoded[i:i+size] for i in range(0, len(encoded), size))
    assert 1_000_000 < len(encoded) < GITHUB_LOG_LIMIT
    result = build_report("demo/app", read=read_metadata, logs=lambda path: github_build_report._log_read(library, path))
    assert "Fra GitHubs log:" in result["text"] and "missing helper" in result["text"]
    with pytest.raises(ApiError):
        library.read("github", "https://api.github.com/repos/demo/app")

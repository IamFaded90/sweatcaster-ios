from copy import deepcopy
from base64 import b64decode
from io import BytesIO
from hashlib import sha256
import json
import os
from pathlib import Path
import subprocess
from types import SimpleNamespace
from uuid import uuid4
from zipfile import ZipFile

from fastapi import FastAPI
from fastapi.responses import JSONResponse
from fastapi.testclient import TestClient
import pytest

from sweatcaster.agent_repair import AgentRepairs, register_agent_repair
from sweatcaster.agent_repair_evidence import evidence, redact
from sweatcaster.agent_repair_runner import IsolatedRunner, canonical, validate_files
from sweatcaster.agent_repair_store import DEMO, DEMO_FILES
from sweatcaster import agent_repair_store
from sweatcaster.code_batch import CodeBatch
from sweatcaster.dto import ApiError
from sweatcaster.repository_library import RepositoryLibrary, RepositoryError

FIXED = DEMO_FILES["prices.py"].replace("price * percent / 100", "price * (1 - percent / 100)")


class FakeRunner:
    def __init__(self, *, baseline_pass=False, always_fail=False, mutate_test=False):
        self.calls = []
        self.baseline_pass, self.always_fail, self.mutate_test = baseline_pass, always_fail, mutate_test

    def available(self):
        return {"ready": True, "title": "Fixture", "detail": "Synthetic test runner"}

    def run(self, files, tests):
        check = validate_files(files, tests)
        self.calls.append(deepcopy((files, tests)))
        passed = self.baseline_pass or len(self.calls) > 1 and not self.always_fail
        if self.mutate_test and len(self.calls) > 1:
            check["testDigest"] = "different"
        return {"testsRun": 3, "failures": 0 if passed else 3, "errors": 0, "skipped": 0,
                "passed": passed, "log": "3 assertions passed" if passed else "AssertionError: 20 != 80",
                "sourceDigest": sha256(canonical(files)).hexdigest(), "image": "sha256:" + "a" * 64,
                "command": "python unittest test_prices", **check}


@pytest.fixture
def repairs(tmp_path):
    library = RepositoryLibrary(tmp_path / "workspace", tmp_path / "index.sqlite3", None)
    calls = []

    def generate(goal, files, context=None):
        calls.append((goal, files, context))
        return {"feasible": True, "files": {"prices.py": FIXED}, "tests": ["Run the frozen unittest check."]}

    batch = CodeBatch(tmp_path / "batch.sqlite3", library, generate)
    service = AgentRepairs(SimpleNamespace(output_root=tmp_path / "out"), batch, runner=FakeRunner(), launch=lambda fn: fn())
    return service, calls


def request(**changes):
    return {"id": str(uuid4()), "repository": DEMO, "report": "20 procent rabat på 100 skal give 80, men giver 20.",
            "files": ["prices.py", "test_prices.py"], **changes}


def test_real_git_review_only_then_approval_creates_isolated_branch(repairs, tmp_path):
    service, calls = repairs
    marker = tmp_path / "user-dirty-file.txt"
    marker.write_text("keep this")
    result = service.submit(request())
    assert result["state"] == "review" and result["before"]["failures"] == 3 and result["after"]["passed"]
    assert len(calls) == 1 and calls[0][2]["frozen_tests"]["test_prices.py"] == DEMO_FILES["test_prices.py"]
    library = service.batch.repository
    repo, head = library._head(DEMO)
    assert library._git(repo, "for-each-ref", "refs/heads/fadedai") == b""
    assert library._git(repo, "show", "HEAD:prices.py").decode() == DEMO_FILES["prices.py"]
    approved = service.store.approve(result["id"])
    assert approved["state"] == "approved" and approved["handoff"]["state"] == "waitingForMac"
    assert approved["handoff"]["ipaAvailable"] is False
    assert library._git(repo, "show", approved["commit"] + ":prices.py").decode() == FIXED
    assert library._head(DEMO)[1] == head and marker.read_text() == "keep this"
    assert service.store.approve(result["id"])["commit"] == approved["commit"]
    assert (service.store.root / "copies" / result["id"] / "before/prices.py").read_text() == DEMO_FILES["prices.py"]
    assert (service.store.root / "copies" / result["id"] / "after/prices.py").read_text() == FIXED


def test_same_check_and_frozen_test_before_after(repairs):
    service, _calls = repairs
    result = service.submit(request())
    before, after = service.runner.calls
    assert before[1] == after[1]
    assert before[0]["test_prices.py"] == after[0]["test_prices.py"]
    assert result["before"]["testDigest"] == result["after"]["testDigest"]
    assert result["before"]["sourceDigest"] != result["after"]["sourceDigest"]


def test_handoff_transports_exact_unpushed_commit_without_exporting_base_blobs(repairs, tmp_path):
    service, _calls = repairs
    result = service.submit(request())
    repo, _base = service.batch.repository._head(DEMO)
    target = tmp_path / "mac-copy"
    def git(cwd, *args):
        return subprocess.check_output(["git", "-c", "core.longpaths=true", *args], cwd=cwd, stderr=subprocess.DEVNULL)
    git(tmp_path, "clone", "--bare", str(repo), str(target))
    approved = service.store.approve(result["id"])
    with pytest.raises(subprocess.CalledProcessError):
        git(target, "cat-file", "-e", approved["commit"])
    packet = service.store.bundle(result["id"])
    assert len(json.dumps(packet).encode()) <= 1_000_000
    with ZipFile(BytesIO(b64decode(packet["data"]))) as archive:
        assert "approved-change.bundle" in archive.namelist()
        assert not any(".env" in name or name.startswith("before/") for name in archive.namelist())
        delta = tmp_path / "approved-change.bundle"
        delta.write_bytes(archive.read("approved-change.bundle"))
    git(target, "bundle", "verify", str(delta))
    git(target, "fetch", str(delta), "refs/heads/" + approved["branch"])
    assert git(target, "show", approved["commit"] + ":prices.py").decode() == FIXED
    assert packet["handoff"]["sourceCommands"][-1] == ["git", "checkout", "--detach", approved["commit"]]


def test_no_reproduction_means_no_fix_or_success_claim(repairs):
    service, calls = repairs
    service.runner = FakeRunner(baseline_pass=True)
    result = service.submit(request())
    assert result["state"] == "needsEvidence" and not calls and not result["diff"]
    with pytest.raises(ValueError):
        service.store.approve(result["id"])
    assert service.batch.list() == []


def test_failed_fix_is_retried_once_and_never_applied(repairs):
    service, calls = repairs
    service.runner = FakeRunner(always_fail=True)
    result = service.submit(request())
    assert result["state"] == "failed" and result["attempts"] == 2 and len(calls) == 2
    assert service.batch.list() == []


def test_changed_test_hash_prevents_review(repairs):
    service, _calls = repairs
    service.runner = FakeRunner(mutate_test=True)
    result = service.submit(request())
    assert result["state"] == "needsInput" and service.batch.list() == []


def test_model_cannot_edit_frozen_test_or_add_unselected_source(repairs):
    service, _calls = repairs
    service.batch.generate = lambda *_args: {"feasible": True, "files": {"test_prices.py": "pass\n"}, "tests": ["fake"]}
    result = service.submit(request())
    assert result["state"] == "needsInput" and len(service.runner.calls) == 1 and service.batch.list() == []


def test_agent_can_create_reproducer_then_freeze_and_commit_it(repairs):
    service, _calls = repairs
    generated = DEMO_FILES["test_prices.py"]
    def generate(_goal, files, _context):
        return {"feasible": True, "files": {"test_agent_repro.py": generated} if "test_agent_repro.py" in files else {"prices.py": FIXED}, "tests": ["Run the repro."]}
    service.batch.generate = generate
    result = service.submit(request(files=["prices.py"]))
    assert result["state"] == "review"
    assert "+from prices import" in result["diff"] and "test_agent_repro.py" in result["diff"]
    approved = service.store.approve(result["id"])
    repo, _ = service.batch.repository._head(DEMO)
    assert service.batch.repository._git(repo, "show", approved["commit"] + ":test_agent_repro.py").decode() == generated


def test_request_identity_is_idempotent_and_conflict_checked(repairs):
    service, calls = repairs
    packet = request()
    result = service.submit(packet)
    assert service.submit(packet) == result and len(calls) == 1
    with pytest.raises(ValueError):
        service.submit(packet | {"report": "Different issue"})


def test_concurrent_repair_is_not_started(repairs):
    service, calls = repairs
    service.launch = lambda _fn: None
    first = service.submit(request())
    assert first["state"] == "reproducing"
    with pytest.raises(ValueError):
        service.submit(request())
    assert not calls


def test_server_restart_preserves_evidence_and_resumes_frozen_test(repairs, monkeypatch):
    service, _calls = repairs
    service.launch = lambda _fn: None
    original = service.submit(request())
    stored = service.store.get(original["id"])
    stored.update(state="fixing", frozenTests={"test_prices.py": DEMO_FILES["test_prices.py"]}, workerStamp="old-process")
    service.store.put(stored)
    fresh = AgentRepairs(SimpleNamespace(output_root=service.store.root.parent), service.batch, runner=FakeRunner(), launch=lambda fn: fn())
    fresh.store.recover()
    assert fresh.store.get(original["id"])["state"] == "interrupted"
    result = fresh.resume(original["id"])
    assert result["state"] == "review" and result["baseRevision"] == original["baseRevision"]
    assert fresh.runner.calls[0][0]["test_prices.py"] == DEMO_FILES["test_prices.py"]
    assert fresh.runner.calls[1][0]["test_prices.py"] == DEMO_FILES["test_prices.py"]


def test_source_changed_since_test_cannot_be_approved(repairs):
    service, _calls = repairs
    result = service.submit(request())
    library = service.batch.repository
    repo, base = library._head(DEMO)
    tree = library._git(repo, "rev-parse", "HEAD^{tree}").decode().strip()
    commit = library._git(repo, "-c", "user.name=Test", "-c", "user.email=test@localhost", "commit-tree", tree, "-p", base, "-m", "Concurrent update").decode().strip()
    library._git(repo, "update-ref", "HEAD", commit)
    with pytest.raises(RepositoryError):
        service.store.approve(result["id"])


@pytest.mark.parametrize("bad", ["../secret.py", "/absolute.py", "os.py", "a.py\x00", "a-b.py"])
def test_runner_refuses_unsafe_or_unsupported_file_names(bad):
    with pytest.raises((ValueError, SyntaxError)):
        validate_files({bad: "value = 1", "test_prices.py": DEMO_FILES["test_prices.py"]}, ["test_prices"])


@pytest.mark.parametrize("source", ["import os\n", "import socket\n", "import subprocess\n", "import unittest\n", "value = eval('1')\n", "value = object.__subclasses__()\n", "value = open('file')\n"])
def test_runner_refuses_execution_outside_supported_stdlib_profile(source):
    with pytest.raises(ValueError):
        validate_files({"prices.py": source, "test_prices.py": DEMO_FILES["test_prices.py"]}, ["test_prices"])


def test_missing_runner_is_honest_and_never_spawns():
    runner = IsolatedRunner(execute=lambda *_args, **_kwargs: SimpleNamespace(returncode=1, stdout=b""),
                            spawn=lambda *_args, **_kwargs: pytest.fail("Must not spawn"))
    assert runner.available()["ready"] is False
    with pytest.raises(RuntimeError):
        runner.run(DEMO_FILES, ["test_prices"])


def test_ios_crash_is_evidence_bound_mac_handoff_without_fake_local_pass(repairs):
    service, calls = repairs
    raw = '{"build_version":"65","incident":"DCC785C8-61E1-4332-A886-30F9E5CFEB12"}\nLibrary not loaded: @rpath/whisper.framework/whisper\nAuthorization: Bearer abcdefghijklmnop'
    result = service.submit(request(report=raw, files=[]))
    assert result["state"] == "needsMac" and result["evidence"]["kind"] == "missingFramework"
    assert result["evidence"]["build"] == "65" and result["evidence"]["redacted"]
    assert "abcdefghijklmnop" not in json.dumps(service.store.get(result["id"]))
    assert not calls and result["before"] is None and result["after"] is None
    assert result["handoff"]["baseRevision"] == result["baseRevision"] and not result["handoff"]["ipaAvailable"]
    assert service.store.bundle(result["id"])["data"].startswith("UEs")


@pytest.mark.parametrize("raw,kind", [("File.swift:12:3: error: cannot find type Widget", "swiftCompile"), ("ld: Undefined symbols for architecture arm64", "linker"), ("JetsamEvent per-process-limit", "memory"), ("watchdog 0x8badf00d", "watchdog")])
def test_ios_evidence_classification(raw, kind):
    assert evidence(raw)["kind"] == kind


def test_mac_receipt_requires_exact_handoff_and_revision(repairs):
    service, _calls = repairs
    result = service.submit(request(report="Library not loaded: @rpath/whisper.framework/whisper", files=[]))
    packet = {"handoffID": result["handoff"]["id"], "revision": result["baseRevision"], "state": "passed",
              "checks": [{"name": "Xcode build", "exitCode": 0, "log": "BUILD SUCCEEDED"}]}
    for changes in ({"revision": "other"}, {"handoffID": "other"}, {"checks": [{"name": "Build", "exitCode": 1, "log": "failure"}]}):
        with pytest.raises(ValueError):
            service.mac_report(result["id"], packet | changes)
    receipt = service.mac_report(result["id"], packet)
    assert receipt["handoff"]["state"] == "macReportedPass"
    assert receipt["handoff"]["ipaAvailable"] is False and receipt["state"] == "needsMac"


def test_swift_proposal_gets_review_branch_and_mac_commands_without_local_pass(repairs, tmp_path):
    service, _calls = repairs
    source = tmp_path / "swift-source"
    source.mkdir()
    (source / "Greeting.swift").write_text('func greeting() -> String { "Hej"\n')
    (source / "Example.xcodeproj").mkdir()
    (source / "Example.xcodeproj/project.pbxproj").write_text("// fixture metadata; not a tested Apple project\n")
    def git(cwd, *args):
        return subprocess.check_output(["git", "-c", "core.longpaths=true", *args], cwd=cwd)
    git(source, "init")
    git(source, "add", ".")
    git(source, "-c", "user.name=Test", "-c", "user.email=test@localhost", "commit", "-m", "fixture")
    repo = service.batch.repository._repo("fadedai/swift-demo")
    repo.parent.mkdir(parents=True, exist_ok=True)
    git(source, "clone", "--bare", str(source), str(repo))
    service.batch.generate = lambda *_args: {"feasible": True, "files": {"Greeting.swift": 'func greeting() -> String { "Hej" }\n'},
                                            "tests": ["Build Example on Mac, then run greeting test."]}
    result = service.submit(request(repository="fadedai/swift-demo", files=["Greeting.swift"],
                                    report="Greeting.swift:1:1: error: expected '}' in function"))
    assert result["state"] == "reviewOnMac" and result["before"] is None and result["after"] is None
    assert not service.runner.calls
    with pytest.raises(ValueError):
        service.store.bundle(result["id"])
    approved = service.store.approve(result["id"])
    assert approved["state"] == "approvedForMac" and approved["handoff"]["approvedRevision"] == approved["commit"]
    assert approved["handoff"]["commands"][1][:3] == ["xcodebuild", "-project", "Example.xcodeproj"]
    assert approved["handoff"]["ipaAvailable"] is False
    assert service.store.bundle(result["id"])["data"].startswith("UEs")


def test_delete_report_rejects_unapproved_batch_and_removes_only_work_copies(repairs, tmp_path):
    service, _calls = repairs
    result = service.submit(request())
    other = tmp_path / "other.txt"; other.write_text("keep")
    assert service.store.remove(result["id"])["deleted"]
    assert service.batch.get(result["id"].replace("-", ""))["status"] == "rejected"
    assert not (service.store.root / "copies" / result["id"]).exists() and other.read_text() == "keep"


def test_every_route_requires_pairing(repairs, tmp_path):
    original, _calls = repairs
    app = FastAPI()
    @app.exception_handler(ApiError)
    async def handle(_request, exc):
        return JSONResponse({"message": str(exc)}, status_code=exc.status_code)
    def authorize(request, _settings):
        if request.headers.get("Authorization") != "Bearer paired":
            raise ApiError(401, "UNAUTHORIZED", "Pair first")
    register_agent_repair(app, SimpleNamespace(output_root=tmp_path / "api"), authorize, batch=original.batch)
    client = TestClient(app)
    raw = str(uuid4())
    for method, suffix in (("GET", ""), ("PUT", "/jobs"), ("GET", f"/jobs/{raw}"), ("PUT", f"/jobs/{raw}/approve"), ("PUT", f"/jobs/{raw}/resume"),
                           ("GET", f"/jobs/{raw}/handoff"), ("GET", f"/jobs/{raw}/bundle"), ("PUT", f"/jobs/{raw}/mac-report"), ("PUT", f"/jobs/{raw}/remove")):
        assert client.request(method, "/api/modules/v1/agent-repair" + suffix, json={}).status_code == 401


@pytest.mark.skipif(os.environ.get("FADEDAI_REPAIR_DOCKER_TEST") != "1", reason="Explicit isolated Docker check")
def test_real_docker_before_failure_after_pass_on_identical_tests(repairs):
    service, _calls = repairs
    service.runner = IsolatedRunner()
    result = service.submit(request())
    assert result["state"] == "review", result["summary"]
    assert result["before"]["failures"] == 3 and result["after"]["passed"]
    assert result["before"]["testDigest"] == result["after"]["testDigest"]
    assert result["before"]["image"] == result["after"]["image"]

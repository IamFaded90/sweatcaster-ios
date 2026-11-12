"""Exercise the Docker/AIO wire contract without starting Docker or a desktop."""

import base64
import json
from subprocess import CompletedProcess
from urllib.parse import parse_qs, urlsplit

import pytest

from sweatcaster.aio_runtime import AIO_IMAGE, BOT_LABEL, MANAGED_LABEL, SANDBOX_HOME, WORKSPACE, AIORuntime, AIORuntimeError

ADAM = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
EVA = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
THIRD = "cccccccc-cccc-4ccc-8ccc-cccccccccccc"
PNG = base64.b64decode("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScLttAAAAABJRU5ErkJggg==")


class DockerFixture:
    def __init__(self):
        self.image = True
        self.containers = {}
        self.volumes = {}
        self.files = {}
        self.calls = []
        self.actions = []
        self.ready = True
        self.frame = PNG

    def __call__(self, argv, *, input, capture_output, timeout, check, creationflags):
        assert argv[0] == "docker"
        args = argv[3:]
        self.calls.append(args)

        def answer(value=b"", *, code=0, error=b""):
            output = value if isinstance(value, bytes) else json.dumps(value).encode()
            return CompletedProcess(argv, code, output, error)

        if args[:2] == ["container", "inspect"]:
            if args[2] not in self.containers:
                return answer(code=1, error=b"Error: No such object")
            return answer([self.containers[args[2]]])
        if args[:2] == ["image", "inspect"]:
            assert args[-1] == AIO_IMAGE
            return answer(b"sha256:test") if self.image else answer(code=1, error=b"Error: No such image")
        if args[:2] == ["container", "ls"]:
            return answer(b"\n".join(name.encode() for name, item in self.containers.items() if item["State"]["Running"]))
        if args[:2] == ["volume", "create"]:
            name = args[-1]
            labels = dict(args[index + 1].split("=", 1) for index, arg in enumerate(args) if arg == "--label")
            self.volumes.setdefault(name, {"Name": name, "Driver": "local", "Labels": labels})
            self.files.setdefault(name, {})
            return answer(name.encode())
        if args[:2] == ["volume", "inspect"]:
            return answer([self.volumes[args[2]]])
        if args[:2] == ["container", "run"]:
            name = args[args.index("--name") + 1]
            labels = dict(args[index + 1].split("=", 1) for index, arg in enumerate(args) if arg == "--label")
            mount = dict(entry.split("=", 1) for entry in args[args.index("--mount") + 1].split(","))
            self.containers[name] = {
                "Config": {"Image": args[-1], "Labels": labels},
                "HostConfig": {"NetworkMode": args[args.index("--network") + 1], "Privileged": False},
                "Mounts": [{"Type": mount["type"], "Name": mount["source"], "Destination": mount["target"], "RW": True}],
                "State": {"Running": True},
            }
            return answer(b"container-id")
        if args[:2] in (["container", "start"], ["container", "stop"]):
            self.containers[args[-1]]["State"]["Running"] = args[1] == "start"
            return answer(args[-1].encode())
        if args[:3] == ["container", "exec", "--detach"]:
            assert args[-3:-1] == ["mousepad", "--"]
            return answer()
        if args[:2] == ["container", "exec"]:
            name = args[3] if args[2] == "--interactive" else args[2]
            volume = self.containers[name]["Mounts"][0]["Name"]
            url = urlsplit(args[-1])
            assert url.netloc == "127.0.0.1:8091"
            body = json.loads(input) if input else {}
            if url.path == "/v2/computer/info":
                return answer({"data": {"available": self.ready}})
            if url.path == "/v2/computer/screenshot":
                return answer(self.frame)
            if url.path in {"/v2/computer/actions", "/v2/computer/actions/batch"}:
                self.actions.append((name, body))
                return answer({"data": {"status": "success"}})
            if url.path == "/v2/fs/write":
                assert body["user"] == "sandbox"
                content = base64.b64decode(body["content"])
                self.files[volume][body["path"]] = content
                return answer({"data": {"bytes_written": len(content)}})
            if url.path == "/v2/fs/read":
                path = parse_qs(url.query)["path"][0]
                if path in self.files[volume]:
                    return answer({"data": {"content": self.files[volume][path].decode()}})
                return answer(code=22)
        pytest.fail(f"Unexpected Docker call: {args}")


def test_each_bot_has_private_persistent_home_and_on_demand_desktop():
    docker = DockerFixture()
    runtime = AIORuntime(runner=docker)
    assert runtime.status(ADAM) == {"state": "stopped", "detail": None}
    assert runtime.start(ADAM.upper())["state"] == "running"
    assert runtime.start(EVA)["state"] == "running"
    creates = [args for args in docker.calls if args[:2] == ["container", "run"]]
    assert len(creates) == 2
    for args in creates:
        assert args[args.index("--network") + 1] == "none"
        assert args[args.index("--security-opt") + 1] == "no-new-privileges"
        assert not {"--publish", "--publish-all", "--privileged", "--volume"} & set(args)
        assert "--pull=never" in args and "seccomp=unconfined" not in args
        assert args[-1] == AIO_IMAGE
    assert len(docker.volumes) == 2
    assert {item["Labels"][BOT_LABEL] for item in docker.volumes.values()} == {ADAM, EVA}
    assert all(item["Labels"][MANAGED_LABEL] == "1" for item in docker.volumes.values())
    assert all(item["Mounts"][0]["Destination"] == SANDBOX_HOME for item in docker.containers.values())

    runtime.save_artifact(ADAM, "rapport.md", "Adams blå rapport".encode())
    with pytest.raises(AIORuntimeError):
        runtime.read_artifact(EVA, "rapport.md")
    runtime.save_artifact(EVA, "rapport.md", b"Evas rapport")
    assert runtime.stop(ADAM)["state"] == "stopped"
    with pytest.raises(AIORuntimeError, match="Start botcomputeren"):
        runtime.screenshot(ADAM)
    assert runtime.start(ADAM)["state"] == "running"
    assert runtime.read_artifact(ADAM, "rapport.md") == "Adams blå rapport".encode()
    assert runtime.read_artifact(EVA, "rapport.md") == b"Evas rapport"
    assert [args for args in docker.calls if args[:2] == ["container", "run"]] == creates
    assert any(path == WORKSPACE + "/rapport.md" for files in docker.files.values() for path in files)


def test_desktop_state_action_and_capacity_are_bounded():
    docker = DockerFixture()
    runtime = AIORuntime(runner=docker)
    docker.ready = False
    assert runtime.start(ADAM)["state"] == "starting"
    docker.ready = True
    assert runtime.status(ADAM)["state"] == "running"
    assert runtime.screenshot(ADAM) == PNG
    runtime.click(ADAM, 21, 12)
    runtime.type_text(ADAM, "Blå")
    runtime.key(ADAM, "ENTER")
    runtime.scroll(ADAM, 21, 12, 0, -2)
    assert [body for _, body in docker.actions] == [
        {"action_type": "CLICK", "x": 21, "y": 12},
        {"action_type": "TYPING", "text": "Blå"},
        {"action_type": "PRESS", "key": "enter"},
        {"actions": [{"action_type": "MOVE_TO", "x": 21, "y": 12}, {"action_type": "SCROLL", "dx": 0, "dy": -2}]},
    ]
    runtime.save_artifact(ADAM, "rapport.md", b"tekst")
    runtime.open_artifact(ADAM, "rapport.md")
    runtime.start(EVA)
    with pytest.raises(AIORuntimeError, match="To botcomputere") as error:
        runtime.start(THIRD)
    assert error.value.status == 409


def test_rejects_unsafe_arguments_and_foreign_docker_configuration():
    docker = DockerFixture()
    runtime = AIORuntime(runner=docker)
    for call in (
        lambda: runtime.start("--privileged"),
        lambda: runtime.click(ADAM, True, 42),
        lambda: runtime.scroll(ADAM, 0, 0, 0, -60),
        lambda: runtime.type_text(ADAM, "\x00"),
        lambda: runtime.key(ADAM, "ctrl+alt+t"),
        lambda: runtime.read_artifact(ADAM, "../secret.md"),
        lambda: runtime.save_artifact(ADAM, "report.md", b"\xff"),
        lambda: runtime.open_artifact(ADAM, "program.desktop"),
    ):
        with pytest.raises(AIORuntimeError) as error:
            call()
        assert error.value.status == 422
    assert docker.calls == []
    runtime.start(ADAM)
    container = next(iter(docker.containers.values()))
    container["HostConfig"]["PortBindings"] = {"8091/tcp": [{"HostPort": "8091"}]}
    assert runtime.status(ADAM)["state"] == "unavailable"
    with pytest.raises(AIORuntimeError) as error:
        runtime.screenshot(ADAM)
    assert error.value.status == 409
    assert not any(args[:2] == ["container", "exec"] and args[-1].endswith("/screenshot") for args in docker.calls)


def test_missing_image_and_invalid_png_are_reported_without_leaking_output():
    docker = DockerFixture()
    runtime = AIORuntime(runner=docker)
    docker.image = False
    assert runtime.status(ADAM)["state"] == "unavailable"
    with pytest.raises(AIORuntimeError, match="PC-opsætning"):
        runtime.start(ADAM)
    assert not docker.volumes
    docker.image = True
    runtime.start(ADAM)
    docker.frame = b"upstream secret or malformed image"
    with pytest.raises(AIORuntimeError, match="sendte ikke et billede") as error:
        runtime.screenshot(ADAM)
    assert "upstream secret" not in str(error.value)

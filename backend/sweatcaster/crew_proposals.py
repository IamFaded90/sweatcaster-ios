"""CrewAI Flow for local code proposals. The existing CodeBatch owns approval and persistence.

No tools, shell, credentials, cloud LLM or CrewAI memory backend are exposed to this flow.
Ollama requests retain FadedAI's existing model lease, loopback and timeout checks.
"""

from __future__ import annotations

import json
import logging
import os
from pathlib import Path
from queue import Empty, Queue
import subprocess
import sys
from tempfile import TemporaryDirectory
from threading import Thread


def validate_candidate(candidate, allowed: set[str]) -> dict:
    if not isinstance(candidate, dict) or type(candidate.get("feasible")) is not bool:
        raise ValueError("Ugyldigt forslag fra holdet.")
    if not candidate["feasible"]:
        return {"feasible": False, "reason": str(candidate.get("reason", "Opgaven kræver mere kontekst."))[:600]}
    files, tests = candidate.get("files"), candidate.get("tests")
    if not isinstance(files, dict) or not files or not files.keys() <= allowed:
        raise ValueError("Holdet foreslog filer uden for opgaven.")
    if not isinstance(tests, list) or not 1 <= len(tests) <= 6 or not all(
        isinstance(test, str) and 1 <= len(test.strip()) <= 300 for test in tests
    ):
        raise ValueError("Forslaget mangler en konkret testplan.")
    for path, source in files.items():
        if not isinstance(source, str) or not source.strip() or len(source) > 16_000 or "\x00" in source:
            raise ValueError("Forslaget indeholder en ugyldig fil.")
        if path.endswith(".py"):
            compile(source, path, "exec")
        elif path.endswith(".json"):
            json.loads(source)
    return candidate


def crew_generator(generate, flow_types=None):
    # Set before importing CrewAI so local proposals are not sent as tracing data.
    os.environ["OTEL_SDK_DISABLED"] = "true"
    os.environ["CREWAI_TELEMETRY_DISABLED"] = "true"
    if flow_types is None:
        from crewai.flow.flow import Flow, listen, start
    else:
        Flow, listen, start = flow_types

    def run(goal, files, context=None):
        if not isinstance(files, dict) or not 1 <= len(files) <= 5:
            raise ValueError("Vælg 1–5 kildefiler.")
        if sum(len(source) for source in files.values()) > 6000:
            raise ValueError("Opgaven er for stor til lokal holdgennemgang.")
        allowed = set(files)

        class ProposalFlow(Flow):
            @start()
            def draft(self):
                return validate_candidate(generate(goal, dict(files), context), allowed)

            @listen(draft)
            def review(self, candidate):
                if not candidate["feasible"]:
                    return candidate
                # The reviewer sees originals and the draft. It may decline or revise the proposal.
                review_context = {
                    "local_context": context,
                    "proposed_change": candidate,
                    "instruction": "Review the draft against the original source and goal. Correct errors. "
                                   "Return the same proposal JSON format. Do not claim tests were run.",
                }
                if len(json.dumps(review_context, ensure_ascii=False)) > 28_000:
                    raise ValueError("Forslaget er for stort til endnu en lokal gennemgang.")
                return validate_candidate(generate(goal, dict(files), review_context), allowed)

        # A new instance per job; never share private state between bots or repositories.
        return ProposalFlow(tracing=False, suppress_flow_events=True).kickoff()

    return run


class CrewUnavailable(RuntimeError):
    pass


def isolated_crew_generator(generate, python):
    """Run the CrewAI dispatcher in its own Python environment; inference stays in the PC server."""
    executable = Path(python)

    def run(goal, files, context=None):
        if not executable.is_absolute() or not executable.is_file():
            logging.getLogger(__name__).warning("CrewAI runtime unavailable. Using single-pass Code Bot.")
            return generate(goal, files, context)
        try:
            return _dispatch(executable, generate, goal, files, context)
        except CrewUnavailable:
            logging.getLogger(__name__).warning("CrewAI dispatcher could not start. Using single-pass Code Bot.")
            return generate(goal, files, context)

    return run


def _send(stream, message):
    stream.write(json.dumps(message) + "\n")
    stream.flush()


def _dispatch(executable, generate, goal, files, context):
    with TemporaryDirectory(prefix="fadedai-crew-") as data:
        return _exchange(executable, data, generate, goal, files, context)


def _exchange(executable, data, generate, goal, files, context):
    env = {key: os.environ[key] for key in ("SystemRoot", "WINDIR", "PATH", "TEMP", "TMP",
                                           "USERPROFILE", "HOMEDRIVE", "HOMEPATH")
           if key in os.environ}
    env.update(HOME=data, APPDATA=data, LOCALAPPDATA=data, XDG_DATA_HOME=data, CREWAI_STORAGE_DIR=data,
               OTEL_SDK_DISABLED="true", CREWAI_TELEMETRY_DISABLED="true",
               CREWAI_TRACING_ENABLED="false", PYTHON_DOTENV_DISABLED="1")
    try:
        process = subprocess.Popen(
            [str(executable), "-I", str(Path(__file__).resolve())],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
            text=True, encoding="utf-8", env=env, cwd=data,
            creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
        )
    except OSError as exc:
        raise CrewUnavailable() from exc
    messages = Queue()

    def receive():
        try:
            for line in process.stdout:
                messages.put(line)
        finally:
            messages.put(None)

    reader = Thread(target=receive, name="fadedai-crew-dispatch", daemon=True)
    reader.start()
    try:
        _send(process.stdin, {"goal": goal, "files": files, "context": context})
        for round_index in range(3):
            try:
                line = messages.get(timeout=60)
            except Empty as exc:
                if round_index == 0:
                    raise CrewUnavailable() from exc
                raise RuntimeError("Holdets gennemgang stoppede undervejs.") from exc
            if line is None and round_index == 0:
                raise CrewUnavailable()
            if line is None:
                break
            message = json.loads(line)
            if message["type"] == "generate" and round_index < 2:
                _send(process.stdin, generate(goal, files, message["context"]))
            elif message["type"] == "result":
                return validate_candidate(message["candidate"], set(files))
            else:
                break
        raise RuntimeError("Holdets gennemgang gav ikke et gyldigt forslag.")
    finally:
        if process.poll() is None:
            process.kill()
        process.wait()
        reader.join(timeout=2)
        process.stdin.close()
        process.stdout.close()


def _worker():
    from contextlib import redirect_stdout

    request = json.loads(sys.stdin.readline())
    output = sys.stdout

    def generate(_goal, _files, context):
        _send(output, {"type": "generate", "context": context})
        return json.loads(sys.stdin.readline())

    with redirect_stdout(sys.stderr):
        run = crew_generator(generate)
        try:
            result = run(request["goal"], request["files"], request.get("context"))
        except Exception:
            _send(output, {"type": "failed"})
            return
    _send(output, {"type": "result", "candidate": result})


if __name__ == "__main__":
    _worker()

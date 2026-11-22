"""Read a failed Actions run and return short, attributed build diagnostics."""

import json
import os
import re
import shutil
import subprocess
from threading import Timer

from fastapi import Body, Request, Response

from sweatcaster.agent_repair_evidence import redact
from sweatcaster.composio_library import GITHUB_LOG_LIMIT
from sweatcaster.dto import ApiError
from sweatcaster.github_addons import GITHUB, REPO, read as read_public


def _cli_get(path, *, limit=320_000):
    executable = shutil.which("gh")
    if not executable:
        return None
    env = {**os.environ, "GH_PROMPT_DISABLED": "1", "GH_PAGER": "cat", "GH_NO_UPDATE_NOTIFIER": "1"}
    try:
        with subprocess.Popen([executable, "api", "--hostname", "github.com", path], env=env,
                              stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                              stderr=subprocess.DEVNULL) as process:
            deadline = Timer(12, process.kill)
            deadline.start()
            try:
                body = process.stdout.read(limit + 1)
                if len(body) > limit:
                    process.kill()
                    return None
                return body if process.wait() == 0 else None
            finally:
                deadline.cancel()
                if process.poll() is None:
                    process.kill()
    except OSError:
        return None


def _json_read(library, path, **params):
    from urllib.parse import urlencode

    query = "?" + urlencode(params) if params else ""
    data = _cli_get(path + query)
    if data is not None:
        try:
            return json.loads(data)
        except (ValueError, RecursionError):
            pass
    try:
        return library.read("github", GITHUB + path, query=params)
    except ApiError:
        # Public repositories can still be checked without a linked account.
        raw = read_public(GITHUB + path, params=params, maximum=320_000)
        try:
            return json.loads(raw)
        except (ValueError, RecursionError) as exc:
            raise ApiError(502, "NOT_READY", "GitHub svarede uden læsbare data.") from exc


def _log_read(library, path):
    if data := _cli_get(path, limit=GITHUB_LOG_LIMIT):
        return data
    try:
        body = library.read("github", GITHUB + path)
    except ApiError:
        return None
    return body.encode("utf-8") if isinstance(body, str) else None


def _clean(value, limit=300):
    if not isinstance(value, str):
        return ""
    value = re.sub(r"\x1b\[[0-9;]*[A-Za-z]", "", value)
    return " ".join(redact(value).split())[:limit]


def log_excerpts(data):
    if not data:
        return []
    lines = []
    for raw in data.decode("utf-8-sig", "replace").splitlines():
        message = re.sub(r"^\d{4}-\d\d-\d\dT[\d:.]+Z\s+", "", raw[:16000])
        if not re.search(r"##\[error\]|\berror:|\bfatal:|^FAILED\s|AssertionError|undefined symbols|Test Case .+ failed", message, re.I):
            continue
        line = _clean(message)
        if re.search(r"^(?:##\[error\])?(?:Process completed with exit code|The process .+ failed with exit code)", line, re.I):
            continue
        line = line.removeprefix("##[error]").strip()
        if line and line not in lines:
            lines.append(line)
        if len(lines) == 4:
            break
    return lines


def build_report(repo, *, read, logs):
    if not isinstance(repo, str) or not REPO.fullmatch(repo) or repo.split("/")[1] in {".", ".."}:
        raise ApiError(422, "INVALID_INPUT", "Skriv GitHub-projektet som ejer/projekt.")
    root = f"/repos/{repo}"
    runs_reply = read(root + "/actions/runs", status="failure", per_page=1)
    runs = runs_reply.get("workflow_runs") if isinstance(runs_reply, dict) else None
    if not isinstance(runs, list):
        raise ApiError(502, "NOT_READY", "GitHub gav ikke en læsbar liste over builds.")
    if not runs:
        return {"text": f"GitHub viser ingen fejlede workflowkørsler i {repo}.", "url": f"https://github.com/{repo}/actions"}
    run = runs[0]
    if not isinstance(run, dict) or type(run.get("id")) is not int or type(run.get("run_attempt")) is not int:
        raise ApiError(502, "NOT_READY", "GitHub svarede uden et gyldigt kørselsnummer.")
    run_id = run["id"]
    link = f"https://github.com/{repo}/actions/runs/{run_id}/attempts/{run['run_attempt']}"
    run_title = _clean(run.get("name"), 90) or "Workflow"
    branch = _clean(run.get("head_branch"), 80)
    started = _clean(run.get("created_at"), 24)
    lines = [f"Seneste fejlede kørsel i {repo}: {run_title} #{run.get('run_number', run_id)}.",
             " · ".join(s for s in (branch, started) if s)]
    jobs_path = f"{root}/actions/runs/{run_id}/attempts/{run['run_attempt']}/jobs"
    job = None
    for page in range(1, 4):
        result = read(jobs_path, per_page=30, page=page)
        jobs = result.get("jobs") if isinstance(result, dict) else None
        if not isinstance(jobs, list):
            raise ApiError(502, "NOT_READY", "GitHub gav ikke en læsbar liste over job.")
        job = next((j for j in jobs if isinstance(j, dict) and j.get("conclusion") in ("failure", "timed_out")), None)
        if job or len(jobs) < 30:
            break
    if not job or type(job.get("id")) is not int:
        lines.append("GitHub viste intet fejlet job blandt de læste job. Åbn kørslen for at se alle detaljer.")
        return {"text": "\n".join(filter(None, lines)), "url": link}
    step = next((s for s in job.get("steps") or [] if isinstance(s, dict) and s.get("conclusion") in ("failure", "timed_out")), {})
    step_name = _clean(step.get("name"), 100)
    job_name = _clean(job.get("name"), 100) or "Ukendt job"
    lines.append(f"Fejlet job: {job_name}" + (f" → {step_name}" if step_name else ""))
    path = f"{root}/actions/jobs/{job['id']}"
    excerpt = []
    if type(step.get("number")) is int:
        excerpt = log_excerpts(logs(f"{path}/steps/{step['number']}/logs"))
    if not excerpt:
        excerpt = log_excerpts(logs(path + "/logs"))
    if excerpt:
        lines.extend(["Fra GitHubs log:", *excerpt])
    else:
        try:
            annotations = read(f"{root}/check-runs/{job['id']}/annotations", per_page=50)
        except ApiError:
            annotations = []
        notes = []
        for note in annotations if isinstance(annotations, list) else []:
            if isinstance(note, dict) and note.get("annotation_level") == "failure":
                message = _clean(note.get("message"))
                if message and message not in notes:
                    notes.append(message)
                if len(notes) == 4:
                    break
        if notes:
            lines.extend(["Fra GitHubs fejlanmærkninger:", *notes])
        else:
            lines.append("Ingen konkret fejllinje kunne læses. Åbn kørslen for hele loggen.")
    return {"text": "\n".join(filter(None, lines)), "url": link}


def register_build_report(app, settings, authorize, library):
    @app.put("/api/modules/v1/github-build/failure", include_in_schema=False)
    def failure(request: Request, response: Response, body: dict = Body(...)):
        authorize(request, settings)
        response.headers["Cache-Control"] = "no-store"
        return build_report(body.get("repo"), read=lambda path, **p: _json_read(library, path, **p),
                            logs=lambda path: _log_read(library, path))

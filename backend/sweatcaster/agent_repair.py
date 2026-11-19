"""Bug evidence -> isolated reproduction -> tested patch -> existing CodeBatch review."""

from copy import deepcopy
import os
from pathlib import Path
from threading import Lock, Thread
from time import time

from fastapi import APIRouter, Body, Depends, Request, Response

from sweatcaster.agent_repair_evidence import evidence, mac_handoff, redact
from sweatcaster.agent_repair_runner import IsolatedRunner, validate_files
from sweatcaster.agent_repair_store import DEMO, RepairStore, identifier, process_stamp
from sweatcaster.crew_proposals import validate_candidate
from sweatcaster.dto import ApiError
from sweatcaster.repository_library import RepositoryError

IOS = {"missingFramework", "linker", "swiftCompile", "memory", "watchdog"}
ACTIVE = {"reproducing", "fixing", "testing"}


class AgentRepairs:
    def __init__(self, settings, batch, *, runner=None, launch=None):
        self.store = RepairStore(settings.output_root, batch)
        self.batch = batch
        self.runner = runner or IsolatedRunner()
        self.launch = launch or (lambda fn: Thread(target=fn, daemon=True, name="agent-repair").start())
        self.gate = Lock()

    def catalog(self):
        self.store.recover()
        jobs = []
        for job in self.store.jobs():
            row = self.store.public(job)
            row["diff"] = ""
            row["evidence"]["report"] = row["evidence"]["report"][:1500]
            row["steps"] = [step[:500] for step in row["steps"][-8:]]
            for key in ("before", "after"):
                if row.get(key):
                    row[key]["log"] = row[key]["log"][:1500]
            jobs.append(row)
        return {"runner": self.runner.available(), "projects": self.store.projects(),
                "jobs": jobs,
                "detail": "Python: samme test før og efter i en isoleret kopi. iPhone/SwiftUI: konkret loganalyse og en opgave til Mac, uden påstået lokal Apple-test."}

    def update(self, job, state, summary, step=None):
        job.update(state=state, summary=summary)
        if step:
            job["steps"].append(step)
        self.store.put(job)

    def submit(self, body):
        if not isinstance(body, dict) or set(body) - {"id", "report", "repository", "files", "profile"}:
            raise ValueError("Vælg projekt, fejlrapport og kildefiler.")
        job_id = identifier(body.get("id"))
        facts = evidence(body.get("report"))
        slug = body.get("repository")
        if not isinstance(slug, str):
            raise ValueError("Vælg et projekt.")
        profile = body.get("profile", "auto")
        if profile not in ("auto", "python", "ios"):
            raise ValueError("Vælg Python eller iPhone/Mac.")
        with self.store.lock:
            self.store.recover()
            try:
                previous = self.store.get(job_id)
            except ValueError:
                previous = None
            if previous:
                if (previous["repository"], previous["evidence"]["digest"], previous["selected"], previous["profile"]) != (slug, facts["digest"], body.get("files", []), profile):
                    raise ValueError("Opgavens id er allerede brugt til en anden fejlrapport.")
                return self.store.public(previous)
            if len(self.store.jobs()) >= 20:
                raise ValueError("Slet en tidligere reparationsrapport, før du opretter en ny.")
            if any(previous["state"] in ACTIVE for previous in self.store.jobs()):
                raise ValueError("En reparationsopgave kører allerede på PC’en.")
            revision, files, paths = self.store.snapshot(slug, body.get("files", []))
            ios = profile == "ios" or profile == "auto" and (facts["kind"] in IOS or any(name.endswith(".swift") for name in files))
            if not ios and (not files or any(not name.endswith(".py") for name in files)):
                raise ValueError("Den lokale testprofil skal bruge udvalgte Python-filer. SwiftUI og iPhone-fejl sendes til Mac.")
            job = {"id": job_id, "repository": slug, "selected": body.get("files", []), "profile": profile,
                   "created": time(), "state": "reproducing", "summary": "Forbereder en separat arbejdskopi…",
                   "steps": [], "evidence": facts, "baseRevision": revision, "paths": paths,
                   "before": None, "after": None, "diff": "", "attempts": 0, "frozenTests": {}, "generatedTests": {}}
            job.update(workerPID=os.getpid(), workerStamp=process_stamp(os.getpid()))
            if ios:
                job["handoff"] = mac_handoff(slug, revision, paths, facts)
                if facts["kind"] in {"missingFramework", "memory", "watchdog"} or not files or any(not name.endswith(".swift") for name in files):
                    self.update(job, "needsMac", "Loggen er analyseret og knyttet til denne revision. Reproduktion, rettelse og Apple-bygning mangler stadig.",
                                "Fejltype: " + facts["title"] + ". Grundrevisionen er registreret; ingen Apple-test er påstået kørt.")
                    return self.store.public(job)
            if not self.gate.acquire(blocking=False):
                raise ValueError("Vent på den reparationsopgave, der allerede kører.")
            self.store.put(job)
        try:
            self.launch(lambda: self.swift_proposal(job, files) if ios else self.work(job, files))
        except RuntimeError:
            self.gate.release()
            self.update(job, "failed", "PC’en kunne ikke starte kontrollen.")
        return self.store.public(self.store.get(job_id))

    def swift_proposal(self, job, original):
        try:
            if sum(map(len, original.values())) > 6000 or any(len(value.splitlines()) > 500 for value in original.values()):
                raise ValueError("Vælg mindre Swift-filer til et afgrænset forslag. Apple-projektopsætning skal undersøges på Mac.")
            self.store.copy(job, "before", original)
            self.update(job, "fixing", "Forbereder et Swift-forslag til gennemgang og efterfølgende Mac-test.",
                        "Log og grundrevision er registreret. Ingen lokal Apple-test er kørt.")
            candidate = validate_candidate(self.batch.generate(
                "Propose a narrowly scoped Swift source fix for this exact reported failure. Preserve public names/contracts. "
                "If evidence does not identify a source fix within the selected files, feasible=false. "
                "No package/config edits outside selected paths. State concrete Mac checks; never claim an Apple build or runtime test was run.",
                original, {"evidence": job["evidence"], "base_revision": job["baseRevision"], "local_apple_test": "NOT RUN"}), set(original))
            if not candidate["feasible"]:
                raise ValueError(candidate["reason"])
            if any(redact(source) != source for source in candidate["files"].values()):
                raise ValueError("Forslaget indeholder noget, der ligner en adgangsnøgle.")
            job["macTestPlan"] = candidate["tests"]
            job["attempts"] = 1
            self.store.copy(job, "after", original | candidate["files"])
            self.store.proposal(job, original, candidate["files"], verified=False)
            self.update(job, "reviewOnMac", "Et konkret Swift-forslag er klar. Det er ikke bygget eller testet på Apple endnu; gennemgå det før Mac-test.",
                        "Kun de valgte Swift-filer blev ændret i en separat kopi. Verifikation afventer Mac.")
        except (ValueError, RuntimeError, RepositoryError) as exc:
            self.update(job, "needsMac", str(exc))
        except Exception:
            self.update(job, "needsMac", "Et sikkert Swift-forslag kunne ikke færdiggøres her. Mac-opgaven med den faktiske log er bevaret.")
        finally:
            self.gate.release()

    def reproduction(self, job, files):
        if job["frozenTests"]:
            files = files | job["frozenTests"]
            tests = [name.removesuffix(".py").replace("/", ".") for name in job["frozenTests"]]
            validate_files(files, tests)
            return files, tests
        tests = [name.removesuffix(".py").replace("/", ".") for name in files
                 if Path(name).name.startswith("test_") or Path(name).stem.endswith("_test")]
        if not tests:
            if len(files) >= 5:
                raise ValueError("Vælg højst fire kildefiler, når agenten også skal lave en reproduktionstest.")
            name = "test_agent_repro.py"
            if name in files:
                raise ValueError("Vælg projektets eksisterende reproduktionstest.")
            candidate = self.batch.generate(
                "Write one small unittest reproduction for the reported bug. The test must check the user's expected behavior, "
                "fail by assertion before the fix, and not change source. No filesystem, network, subprocess, mocks, dynamic imports or monkeypatching.",
                {name: "import unittest\n\n# Add one TestCase for the reported behavior.\n"},
                {"report": job["evidence"]["report"][:3000], "source_files": files})
            candidate = validate_candidate(candidate, {name})
            if not candidate["feasible"]:
                raise ValueError(candidate["reason"])
            job["generatedTests"] = {name: candidate["files"][name]}
            files = files | job["generatedTests"]
            tests = ["test_agent_repro"]
        validate_files(files, tests)
        job["frozenTests"] = {name: source for name, source in files.items() if name.removesuffix(".py").replace("/", ".") in tests}
        return files, tests

    def resume(self, raw):
        with self.store.lock:
            self.store.recover()
            job = self.store.get(raw)
            if job["state"] != "interrupted" or job.get("batchID"):
                raise ValueError("Denne opgave skal ikke genoptages. Opret en ny, hvis du vil ændre rapporten.")
            if any(previous["state"] in ACTIVE for previous in self.store.jobs()) or not self.gate.acquire(blocking=False):
                raise ValueError("Vent på den reparationsopgave, der allerede kører.")
            try:
                revision, files, _paths = self.store.snapshot(job["repository"], job["selected"])
                if revision != job["baseRevision"]:
                    raise ValueError("Projektets revision er ændret. Opret en ny opgave, så beviserne passer til koden.")
                job.update(workerPID=os.getpid(), workerStamp=process_stamp(os.getpid()))
                self.update(job, "reproducing", "Gentager den gemte kontrol efter serverens genstart…")
                ios = any(name.endswith(".swift") for name in files)
                self.launch(lambda: self.swift_proposal(job, files) if ios else self.work(job, files))
            except Exception:
                if self.gate.locked():
                    self.gate.release()
                raise
            return self.store.public(self.store.get(raw))

    def work(self, job, original):
        try:
            editable = {name: source for name, source in original.items()
                        if not Path(name).name.startswith("test_") and not Path(name).stem.endswith("_test")}
            if not editable or sum(map(len, editable.values())) > 6000 or any(len(value.splitlines()) > 500 for value in editable.values()):
                raise ValueError("Vælg mindre kildefiler: den første profil arbejder med højst 6.000 tegn kode ad gangen.")
            baseline, tests = self.reproduction(job, dict(original))
            self.store.copy(job, "before", baseline)
            before = self.runner.run(baseline, tests)
            before["log"] = redact(before["log"])
            job["before"] = before
            if before["passed"] or before["errors"] or before["failures"] < 1 or before["skipped"]:
                self.update(job, "needsEvidence", "Den valgte kontrol beviser ikke fejlen endnu. Ingen ændring er foreslået.",
                            "Den oprindelige kopi blev testet; et konkret fejlet forventningscheck mangler.")
                return
            self.update(job, "fixing", "Fejlen er gentaget. Agenten retter kun de valgte kildefiler.",
                        f"Fejlen blev gentaget: {before['failures']} fejlede forventningschecks. Reproduktionstesten er nu låst.")
            for attempt in range(2):
                job["attempts"] = attempt + 1
                candidate = self.batch.generate(
                    "Fix the reported bug in the selected source only. Preserve public names and contracts. "
                    "Do not alter tests or the test framework. No filesystem, network, subprocess, credentials, mocks or dynamic execution. "
                    "Return the existing feasible/files/tests proposal JSON; do not claim tests ran.", editable,
                    {"report": job["evidence"]["report"][:2500], "frozen_tests": job["frozenTests"],
                     "actual_failure": before["log"][-5000:], "previous_attempt": job.get("after")})
                candidate = validate_candidate(candidate, set(editable))
                if not candidate["feasible"]:
                    raise ValueError(candidate["reason"])
                changes = candidate["files"]
                if any(redact(source) != source for source in changes.values()):
                    raise ValueError("Forslaget indeholder noget, der ligner en nøgle, og blev ikke gemt.")
                updated = baseline | changes
                validate_files(updated, tests)
                self.store.copy(job, "after", updated)
                self.update(job, "testing", "Kører præcis den samme kontrol på den rettede kopi…")
                after = self.runner.run(updated, tests)
                after["log"] = redact(after["log"])
                job["after"] = after
                if (after["testDigest"] != before["testDigest"] or after["profile"] != before["profile"]
                        or after["image"] != before["image"] or after["testsRun"] != before["testsRun"]):
                    raise ValueError("Testgrundlaget ændrede sig. Rettelsen kan ikke godkendes på denne kontrol.")
                if after["passed"]:
                    if after["sourceDigest"] == before["sourceDigest"]:
                        raise ValueError("Ingen kodeændring kunne bekræftes.")
                    self.store.proposal(job, original, changes)
                    self.update(job, "review", "Fejlen er gentaget og den samme test består efter rettelsen. Se ændringen, før du godkender.",
                                "Samme frosne test bestod efter rettelsen. Ingen ændring er anvendt i dit projekt.")
                    return
                self.update(job, "fixing", "Kontrollen fejler stadig. Agenten får ét nyt forsøg.")
            self.update(job, "failed", "De to rettelsesforsøg bestod ikke kontrollen. Dit projekt er ikke ændret.")
        except (ValueError, RuntimeError, RepositoryError) as exc:
            self.update(job, "needsInput", str(exc))
        except Exception:
            self.update(job, "failed", "Arbejdet blev afbrudt. Ingen løsning er påstået, og projektet er ikke ændret.")
        finally:
            self.gate.release()

    def mac_report(self, raw, body):
        with self.store.lock:
            job = self.store.get(raw)
            handoff = job.get("handoff")
            if not isinstance(body, dict) or not handoff or body.get("handoffID") != handoff["id"]:
                raise ValueError("Mac-rapporten hører ikke til denne overdragelse.")
            expected = job.get("commit") or job["baseRevision"]
            if body.get("revision") != expected or body.get("state") not in ("passed", "failed"):
                raise ValueError("Rapportér resultatet fra den præcise revision.")
            checks = body.get("checks")
            if (not isinstance(checks, list) or not 1 <= len(checks) <= 8 or any(not isinstance(check, dict)
                    or not isinstance(check.get("name"), str) or not isinstance(check.get("log"), str)
                    or type(check.get("exitCode")) is not int or len(check["log"]) > 16000 for check in checks)):
                raise ValueError("Vedhæft de faktiske kontroller, exitkoder og byggeloggen fra Mac.")
            if body["state"] == "passed" and any(check["exitCode"] != 0 for check in checks):
                raise ValueError("En fejlet kontrol kan ikke meldes som bestået.")
            job["macReport"] = {"state": body["state"], "revision": expected, "source": "Mac-arbejderens rapport",
                                "checks": [{"name": check["name"][:100], "exitCode": check["exitCode"], "log": redact(check["log"])} for check in checks]}
            job["handoff"]["state"] = "macReportedPass" if body["state"] == "passed" else "macReportedFailure"
            job["summary"] = "Mac-rapport modtaget. Ingen IPA er verificeret eller gjort tilgængelig af denne funktion."
            self.store.put(job)
            return self.store.public(job)


def register_agent_repair(app, settings, authorize, *, batch):
    service = AgentRepairs(settings, batch)

    def paired(request: Request, response: Response):
        authorize(request, settings)
        response.headers["Cache-Control"] = "no-store"

    router = APIRouter(prefix="/api/modules/v1/agent-repair", dependencies=[Depends(paired)], include_in_schema=False)

    def run(action, *args):
        try:
            return action(*args)
        except (ValueError, RepositoryError) as exc:
            raise ApiError(422, "INVALID_INPUT", str(exc)) from exc

    @router.get("")
    def catalog():
        return run(service.catalog)

    @router.put("/jobs")
    def submit(body: dict = Body(...)):
        return run(service.submit, body)

    @router.get("/jobs/{raw}")
    def status(raw: str):
        service.store.recover()
        return run(lambda: service.store.public(service.store.get(raw)))

    @router.put("/jobs/{raw}/resume")
    def resume(raw: str):
        return run(service.resume, raw)

    @router.put("/jobs/{raw}/approve")
    def approve(raw: str):
        return run(lambda: service.store.public(service.store.approve(raw)))

    @router.get("/jobs/{raw}/handoff")
    def handoff(raw: str):
        return run(lambda: service.store.get(raw).get("handoff"))

    @router.get("/jobs/{raw}/bundle")
    def bundle(raw: str):
        return run(service.store.bundle, raw)

    @router.put("/jobs/{raw}/mac-report")
    def mac_report(raw: str, body: dict = Body(...)):
        return run(service.mac_report, raw, body)

    @router.put("/jobs/{raw}/remove")
    def remove(raw: str):
        return run(service.store.remove, raw)

    app.include_router(router)
    return service

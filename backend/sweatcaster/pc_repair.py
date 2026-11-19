"""Paired PC image diagnosis, fixed repairs and verified original-job retry."""

from base64 import b64encode
from copy import deepcopy
from threading import Lock, Thread
from time import monotonic
from uuid import uuid4

from fastapi import APIRouter, Body, Depends, Request, Response

from sweatcaster.dto import ApiError
from sweatcaster.pc_image_engine import ComfyControl, EngineUnavailable, diagnosis, model_busy
from sweatcaster.pc_repair_images import failed_graph, failed_images, identifier, image_result, remove_image


class PCRepair:
    def __init__(self, settings, *, control=None, is_idle=None, launch=None, clock=monotonic):
        self.settings = settings
        self.control = control or ComfyControl()
        self.is_idle = is_idle or (lambda: True)
        self.launch = launch or (lambda operation: Thread(target=operation, daemon=True, name="fadedai-pc-repair").start())
        self.clock = clock
        self.lock = Lock()
        self.jobs = {}
        self.active = None

    def available(self):
        return self.is_idle() and not model_busy(self.settings)

    def inspect(self):
        result = diagnosis(self.control)
        if not self.available():
            result["checks"].append({"id": "agents", "title": "Andre AI-opgaver", "state": "busy",
                                     "detail": "En agent eller AI-model arbejder. Jeg venter med ændringer."})
            result["actions"] = []
            result["state"] = "busy"
        result["failedJobs"] = failed_images(self.control) if result["state"] == "ready" else []
        result["detail"] = "Referencer og private studieopgaver genstartes i deres oprindelige studie. Jeg skifter ikke model eller genstarter en ukendt proces."
        with self.lock:
            result["jobs"] = [self.summary(job) for job in reversed(list(self.jobs.values()))]
        return result

    @staticmethod
    def summary(job):
        return {key: deepcopy(job[key]) for key in ("id", "state", "summary", "steps", "imageAvailable")}

    def update(self, job, *, state=None, summary=None, step=None):
        with self.lock:
            if state is not None:
                job["state"] = state
            if summary is not None:
                job["summary"] = summary
            if step is not None:
                job["steps"].append(step)

    def submit(self, body):
        if not isinstance(body, dict) or set(body) - {"id", "action", "promptID"}:
            raise ApiError(422, "INVALID_INPUT", "Vælg en af de viste rettelser.")
        job_id = identifier(body.get("id"))
        action = body.get("action")
        if action not in ("start", "releaseMemory", "retryImage"):
            raise ApiError(422, "INVALID_INPUT", "Denne PC-handling er ikke understøttet.")
        prompt_id = identifier(body.get("promptID")) if action == "retryImage" else None
        if action != "retryImage" and body.get("promptID") is not None:
            raise ApiError(422, "INVALID_INPUT", "Vælg kun en billedopgave, hvis den skal prøves igen.")
        with self.lock:
            previous = self.jobs.get(job_id)
            if previous:
                if previous["action"] != action or previous["original"] != prompt_id:
                    raise ApiError(409, "REQUEST_REUSED", "Denne rettelse har allerede andre indstillinger.")
                return self.summary(previous)
            if self.active is not None:
                raise ApiError(409, "NOT_READY", "Vent på den rettelse, der allerede kører.")
            if len(self.jobs) >= 6 or (action == "retryImage" and sum(bool(job.get("image")) for job in self.jobs.values()) >= 2):
                raise ApiError(409, "NOT_READY", "Slet et tidligere resultat her, før du starter et nyt.")
            job = {"id": job_id, "action": action, "original": prompt_id, "state": "working", "provider": None,
                   "summary": "Kontrollerer PC’en før rettelsen…", "steps": [], "imageAvailable": False,
                   "image": None, "file": None}
            self.jobs[job_id] = job
            self.active = job_id
        try:
            self.launch(lambda: self.run(job))
        except RuntimeError as exc:
            with self.lock:
                self.active = None
                self.jobs.pop(job_id, None)
            raise ApiError(503, "NOT_READY", "PC’en kunne ikke starte rettelsen. Prøv igen.") from exc
        return self.status(job_id)

    def run(self, job):
        try:
            if not self.available():
                raise ApiError(409, "NOT_READY", "En anden AI-opgave er i gang. Prøv igen, når den er færdig.")
            if job["action"] == "start":
                message = self.control.start()
            elif job["action"] == "releaseMemory":
                message = self.control.release_memory()
            else:
                message = self.retry(job)
            self.update(job, state="ready", summary=message, step=message)
        except ApiError as exc:
            self.update(job, state="needsInput" if exc.status_code == 409 else "failed", summary=str(exc))
        except (EngineUnavailable, OSError):
            self.update(job, state="failed", summary="PC’en kunne ikke bekræfte rettelsen. Der er ikke stoppet andre programmer eller valgt en anden model.")
        except Exception:
            self.update(job, state="failed", summary="Rettelsen blev afbrudt af en uventet fejl. Tjek PC’en igen.")
        finally:
            with self.lock:
                if self.active == job["id"]:
                    self.active = None

    def retry(self, job):
        self.control.idle()
        graph = failed_graph(self.control, job["original"])
        self.control.idle()
        provider = str(uuid4())
        queued = self.control.json("POST", "/prompt", {"prompt": graph, "prompt_id": provider}, limit=4096)
        provider = identifier(queued.get("prompt_id"))
        with self.lock:
            job["provider"] = provider
        self.update(job, step="Motoren har modtaget den oprindelige opskrift med samme model, beskrivelse, størrelse og seed.")
        deadline = self.clock() + 300
        for _ in range(150):
            found = image_result(self.control, provider)
            if found:
                data, file = found
                with self.lock:
                    job.update(image=data, file=file, imageAvailable=True)
                return "Billedopgaven er prøvet igen, og jeg har hentet og kontrolleret det færdige PNG-billede."
            if self.clock() >= deadline:
                break
            self.control.sleep(2)
        return self._timed_out(job)

    def _timed_out(self, job):
        # Keep the exact provider so a later explicit check can retrieve its result.
        raise ApiError(409, "NOT_READY", "Billedet er ikke færdigt endnu. Tryk Tjek resultat. Jeg har ikke afbrudt motorens andre opgaver.")

    def status(self, job_id):
        with self.lock:
            job = self.jobs.get(identifier(job_id))
            if job is None:
                raise ApiError(404, "NOT_FOUND", "Rettelsen findes ikke længere.")
            return self.summary(job)

    def refresh(self, job_id):
        with self.lock:
            job = self.jobs.get(identifier(job_id))
            if job is None:
                raise ApiError(404, "NOT_FOUND", "Rettelsen findes ikke længere.")
            provider = job["provider"]
        if provider and job["state"] != "working" and not job["imageAvailable"]:
            found = image_result(self.control, provider)
            if found:
                with self.lock:
                    job.update(image=found[0], file=found[1], imageAvailable=True, state="ready",
                               summary="Billedet er nu færdigt og er blevet hentet og kontrolleret.")
        return self.status(job_id)

    def image(self, job_id):
        with self.lock:
            job = self.jobs.get(identifier(job_id))
            if job is None or not job["imageAvailable"] or not job["image"]:
                raise ApiError(409, "NOT_READY", "Billedet er ikke klar.")
            return {"png": b64encode(job["image"]).decode("ascii")}

    def remove(self, job_id):
        with self.lock:
            job = self.jobs.get(identifier(job_id))
            if job is None:
                return {"deleted": True}
            if job["state"] == "working":
                raise ApiError(409, "NOT_READY", "Vent på rettelsen, før du sletter dens resultat.")
        if job["provider"]:
            if self.control.queue():
                raise ApiError(409, "NOT_READY", "Vent til billedkøen er tom, før resultatet slettes.")
            if not job["file"]:
                try:
                    found = image_result(self.control, job["provider"])
                except ApiError as exc:
                    if exc.status_code != 503:
                        raise
                    found = None
                if found:
                    job["file"] = found[1]
            remove_image(job["file"])
            self.control.json("POST", "/history", {"delete": [job["provider"]]}, limit=4096)
        with self.lock:
            self.jobs.pop(job["id"], None)
        return {"deleted": True}


def register_pc_repair(app, settings, authorize, *, is_idle=None):
    service = PCRepair(settings, is_idle=is_idle)

    def paired(request: Request, response: Response):
        authorize(request, settings)
        response.headers["Cache-Control"] = "no-store"

    router = APIRouter(prefix="/api/modules/v1/pc-repair", dependencies=[Depends(paired)], include_in_schema=False)

    @router.get("")
    def inspect():
        return service.inspect()

    @router.put("/recover")
    def recover(body: dict = Body(...)):
        return service.submit(body)

    @router.get("/jobs/{job_id}")
    def status(job_id: str):
        return service.status(job_id)

    @router.put("/jobs/{job_id}/refresh")
    def refresh(job_id: str):
        return service.refresh(job_id)

    @router.get("/jobs/{job_id}/image")
    def image(job_id: str):
        return service.image(job_id)

    @router.put("/jobs/{job_id}/remove")
    def remove(job_id: str):
        return service.remove(job_id)

    app.include_router(router)
    return service

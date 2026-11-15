"""Prepare, preview and approve the precise commentary that will be rendered."""

from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass, field
from pathlib import Path
import tempfile
from threading import Event, RLock
from time import monotonic
from uuid import uuid4

from fastapi import APIRouter, Body, Depends, Request, Response
from fastapi.responses import FileResponse

from sweatcaster.dto import ApiError, parse_create_body


@dataclass
class Review:
    id: str
    job: dict
    state: str = "analyzing"
    analysis: object = None
    plan: object = None
    digest: str = ""
    message: str | None = None
    scratch: object = None
    touched: float = field(default_factory=monotonic)
    cancel: Event = field(default_factory=Event)
    reviewed_lines: tuple = ()

    @property
    def busy(self):
        return self.state in {"analyzing", "previewing", "rendering"}

    def receipt(self):
        return {"id": self.id, "state": self.state, "message": self.message,
                "lines": [{"start": line.t_start, "text": line.text} for line in self.plan.lines] if self.plan else [],
                "previewReady": self.scratch is not None and self.state in {"ready", "finished"},
                "previewLines": list(self.reviewed_lines) if self.scratch is not None else None}


def register_video_review(app, settings, authorize):
    def paired(request: Request, response: Response):
        authorize(request, settings)
        response.headers["Cache-Control"] = "no-store"

    router = APIRouter(prefix="/api/modules/v1/video-review", dependencies=[Depends(paired)], include_in_schema=False)
    lock = RLock()
    reviews = {}
    pool = ThreadPoolExecutor(1, thread_name_prefix="faded-video-review")

    def manager():
        from sweatcaster.jobs import JobManager
        from sweatcaster.pipeline import Pipeline
        from sweatcaster.store import Store
        return JobManager(settings, Store(settings.output_root / "state.sqlite3"), Pipeline(settings))

    def clean(review):
        if review.scratch is not None:
            review.scratch.cleanup()
            review.scratch = None

    def expire():
        for key, item in list(reviews.items()):
            if not item.busy and monotonic() - item.touched > 3600:
                clean(item)
                del reviews[key]

    def run(review, texts, preview):
        from sweatcaster.jobs import _warning, phone_error, utc_stamp
        from sweatcaster.security import output_file
        from sweatcaster.util import UserFacingError, sha256_file

        work = None
        rendered = None
        complete = False
        try:
            jobs = manager()
            source, probe, digest = jobs._open_clip(review.job)
            if texts is None:
                analysis = jobs.pipeline.analyze(source, probe, review.job, review.cancel)
                plan = jobs.pipeline.comment(review.job["clip_id"], review.job, analysis,
                                             jobs.store.recent_reactions(settings.recent_limit), review.cancel)
                with lock:
                    review.analysis, review.plan, review.digest = analysis, plan, digest
                    review.state = "ready"
                return
            if digest != review.digest:
                raise UserFacingError("Originalklippet har ændret sig. Opret en ny prøve.")
            options = {**review.job, "faded_preview": preview}
            approved = review.plan.model_copy(update={"lines": [
                original.model_copy(update={"text": text, "word_timings": []})
                for original, text in zip(review.plan.lines, texts) if text
            ]})
            work = tempfile.TemporaryDirectory(prefix="fadedai-video-review-")
            folder = Path(work.name)
            if approved.lines:
                bundle = jobs.pipeline.narrate(approved, folder, review.cancel)
            else:
                from sweatcaster.tts import NarrationBundle
                approved = approved.model_copy(update={"commentary_source": "disabled"})
                bundle = NarrationBundle(source="disabled", live_verified=False, clips=[], warnings=[])
            rendered = folder / "preview.mp4" if preview else output_file(settings.output_root, review.id, "output.mp4")
            warnings, timed = jobs.pipeline.render(
                source=source, output=rendered, workdir=folder, analysis=review.analysis,
                plan=approved, bundle=bundle, job=options, cancel=review.cancel,
            )
            if sha256_file(source) != digest:
                raise UserFacingError("Originalklippet har ændret sig. Opret en ny prøve.")
            with lock:
                if review.cancel.is_set():
                    raise UserFacingError("Prøven blev annulleret.")
                if preview:
                    clean(review)
                    review.scratch, work = work, None
                    review.reviewed_lines = texts
                    review.state = "ready"
                else:
                    now = utc_stamp()
                    jobs._write_report(before=digest, after=digest, output=rendered, analysis=review.analysis,
                                       plan=timed, narration_source=bundle.source, warnings=warnings)
                    jobs.store.save_job({key: value for key, value in review.job.items() if key != "clip_ids"} | {
                        "id": review.id, "status": "completed", "progress": 1.0,
                        "message": "Godkendt video er klar.", "warnings": [
                            safe for warning in warnings[:12] if (safe := _warning(warning, settings.token)) is not None
                        ], "error": None,
                        "created_at": now, "updated_at": now, "output_ready": True, "output_name": "output.mp4",
                    })
                    review.state = "finished"
                complete = True
        except Exception as exc:
            _, message = phone_error(exc, settings.token)
            with lock:
                review.state = "failed" if review.plan is None else "ready"
                review.message = message
        finally:
            if work is not None:
                work.cleanup()
            if rendered is not None and not preview and not complete:
                rendered.unlink(missing_ok=True)
                rendered.with_suffix(".report.json").unlink(missing_ok=True)
            with lock:
                review.touched = monotonic()

    def find(review_id):
        expire()
        review = reviews.get(review_id)
        if review is None:
            raise ApiError(404, "NOT_FOUND", "Prøven er udløbet. Opret en ny.")
        review.touched = monotonic()
        return review

    def available():
        if any(item.busy for item in reviews.values()):
            raise ApiError(409, "NOT_READY", "PC’en laver allerede en videoprøve.")
        active = {"queued", "analyzing", "commentating", "synthesizing", "rendering"}
        if any(job["status"] in active for job in manager().store.list_jobs()):
            raise ApiError(409, "NOT_READY", "Vent til PC’ens videokø er færdig.")

    @router.put("")
    def start(body: dict = Body(...)):
        clips = body.get("clip_ids")
        if not isinstance(clips, list) or len(clips) != 1 or not isinstance(clips[0], str):
            raise ApiError(422, "INVALID_INPUT", "Vælg ét klip til prøven.")
        job = parse_create_body(body)
        if not job["commentary"]:
            raise ApiError(422, "INVALID_INPUT", "Slå kommentator til for at lave en prøve.")
        from sweatcaster.preflight import create_blockers
        blocker = create_blockers(settings, commentary=True)
        if blocker:
            raise ApiError(503, "NOT_READY", blocker)
        with lock:
            expire()
            available()
            if len(reviews) >= 4:
                oldest = min(reviews.values(), key=lambda item: item.touched)
                clean(oldest)
                del reviews[oldest.id]
            review = Review(uuid4().hex, {**job, "clip_id": clips[0]})
            reviews[review.id] = review
            pool.submit(run, review, None, False)
            return review.receipt()

    @router.get("/{review_id}")
    def status(review_id: str):
        with lock:
            return find(review_id).receipt()

    @router.put("/{review_id}/render")
    def render(review_id: str, body: dict = Body(...)):
        with lock:
            review = find(review_id)
            if review.state != "ready" or review.plan is None:
                raise ApiError(409, "NOT_READY", "Prøven er ikke klar lige nu.")
            texts, preview = body.get("lines"), body.get("preview")
            if (type(preview) is not bool or not isinstance(texts, list) or len(texts) != len(review.plan.lines)
                    or any(not isinstance(line, str) or len(line) > 280 for line in texts)):
                raise ApiError(422, "INVALID_INPUT", "Hver replik må fylde op til 280 tegn.")
            lines = tuple(" ".join(line.split()) for line in texts)
            if not preview and (review.scratch is None or review.reviewed_lines != lines):
                raise ApiError(409, "NOT_READY", "Lav en prøve med de seneste rettelser først.")
            available()
            review.message = None
            review.state = "previewing" if preview else "rendering"
            pool.submit(run, review, lines, preview)
            return review.receipt()

    @router.get("/{review_id}/preview")
    def preview_file(review_id: str):
        with lock:
            review = find(review_id)
            if review.scratch is None:
                raise ApiError(409, "NOT_READY", "Der er ingen prøve klar endnu.")
            file = Path(review.scratch.name) / "preview.mp4"
            return FileResponse(file, media_type="video/mp4", headers={"Cache-Control": "no-store"})

    app.include_router(router)

    def waiting_for_review():
        with lock:
            expire()
            return [{"id": review.id, "previewReady": review.scratch is not None}
                    for review in reversed(list(reviews.values())) if review.state == "ready"]

    return waiting_for_review

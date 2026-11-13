"""Authenticated FadedAI routes for a bot's own AIO environment."""

from fastapi import APIRouter, Body, Depends, FastAPI, Request, Response

from sweatcaster.aio_runtime import AIORuntime, AIORuntimeError
from sweatcaster.bot_computers import BotComputerError, BotComputers, ollama_reports, wire_uuid
from sweatcaster.dto import ApiError


def register_bot_computers(app: FastAPI, settings, authorize, service=None):
    if service is None:
        service = BotComputers(settings.output_root / "bot-computers.sqlite3", AIORuntime(), ollama_reports(settings),
                               propose=ollama_reports(settings, phone_actions=True))

    def paired(request: Request, response: Response):
        authorize(request, settings)
        response.headers["Cache-Control"] = "no-store"

    router = APIRouter(prefix="/api/modules/v1/bot-computers", dependencies=[Depends(paired)], include_in_schema=False)

    def run(action, *args):
        try:
            return action(*args)
        except (BotComputerError, AIORuntimeError) as exc:
            code = {404: "NOT_FOUND", 409: "CONFLICT", 422: "INVALID_INPUT",
                    429: "TOO_MANY_REQUESTS", 502: "NOT_READY", 503: "NOT_READY"}.get(exc.status, "NOT_READY")
            raise ApiError(exc.status, code, exc.message) from exc

    def computer_id(bot_id: str) -> str:
        return run(wire_uuid, bot_id)

    @router.get("/{bot_id}")
    def status(bot=Depends(computer_id)):
        return {**run(service.status, bot), "phoneActions": service.propose is not None, "taskContext": True}

    @router.post("/{bot_id}/start")
    def start(bot=Depends(computer_id)):
        return run(service.start, bot)

    @router.post("/{bot_id}/stop")
    def stop(bot=Depends(computer_id)):
        return run(service.stop, bot)

    @router.get("/{bot_id}/screen")
    def screen(bot=Depends(computer_id)):
        frame = run(service.runtime.screenshot, bot)
        return Response(frame, media_type="image/png", headers={"Cache-Control": "no-store"})

    @router.post("/{bot_id}/input")
    def desktop_input(bot=Depends(computer_id), payload: dict = Body(...)):
        action = payload.get("type")
        if action == "click":
            run(service.runtime.click, bot, payload.get("x"), payload.get("y"))
        elif action == "text":
            run(service.runtime.type_text, bot, payload.get("text"))
        elif action == "key":
            run(service.runtime.key, bot, payload.get("key"))
        elif action == "scroll":
            run(service.runtime.scroll, bot, payload.get("x"), payload.get("y"), payload.get("dx"), payload.get("dy"))
        else:
            raise ApiError(422, "INVALID_INPUT", "Ukendt handling til botcomputeren.")
        return {"ok": True}

    @router.get("/{bot_id}/jobs")
    def jobs(bot=Depends(computer_id)):
        return run(service.jobs, bot)

    @router.post("/{bot_id}/jobs")
    def enqueue(bot=Depends(computer_id), payload: dict = Body(...)):
        request_id = run(wire_uuid, payload.get("requestID"))
        source = payload.get("fileID")
        source_id = run(wire_uuid, source) if source is not None else None
        return run(lambda: service.enqueue(bot, request_id, payload.get("prompt"), source_id,
                                           phone_kind=payload.get("phoneKind"), phone_time=payload.get("phoneTime"),
                                           task_context=payload.get("taskContext")))

    @router.post("/{bot_id}/jobs/{job_id}/cancel")
    def cancel(job_id: str, bot=Depends(computer_id)):
        return run(service.cancel, bot, run(wire_uuid, job_id))

    @router.get("/{bot_id}/files")
    def files(bot=Depends(computer_id)):
        return run(service.files, bot)

    @router.post("/{bot_id}/files")
    def upload(bot=Depends(computer_id), payload: dict = Body(...)):
        return run(service.upload, bot, payload.get("name"), payload.get("content"))

    @router.get("/{bot_id}/files/{file_id}")
    def file(file_id: str, bot=Depends(computer_id)):
        return run(service.file, bot, run(wire_uuid, file_id))

    @router.post("/{bot_id}/share")
    def share(bot=Depends(computer_id), payload: dict = Body(...)):
        return run(service.share, bot, run(wire_uuid, payload.get("sourceBotID")), run(wire_uuid, payload.get("fileID")))

    app.include_router(router)
    return service

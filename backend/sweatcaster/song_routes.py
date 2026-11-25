import base64
import json

from fastapi import APIRouter, Depends, Request, Response
from starlette.concurrency import run_in_threadpool

from sweatcaster.dto import ApiError
from sweatcaster.song_studio import SongStudio, SongStudioError


def register_song_studio(app, settings, authorize, *, idle=None):
    service = SongStudio(settings.output_root, idle=idle)

    def paired(request: Request, response: Response):
        authorize(request, settings)
        response.headers["Cache-Control"] = "no-store"

    router = APIRouter(prefix="/api/modules/v1/song-studio", dependencies=[Depends(paired)], include_in_schema=False)

    def checked(call):
        try:
            return call()
        except SongStudioError as exc:
            raise ApiError(422, "INVALID_INPUT", str(exc)) from exc

    @router.get("")
    def catalog():
        return {"ready": service.engine.available(), "voiceReference": True, **service.list()}

    @router.put("/jobs/{key}")
    async def create(key: str, request: Request):
        body = bytearray()
        async for chunk in request.stream():
            if len(body) + len(chunk) > 32_030_000:
                raise ApiError(422, "INVALID_INPUT", "Vælg en kortere lydreference.")
            body.extend(chunk)
        try:
            value = json.loads(body)
        except (ValueError, RecursionError):
            raise ApiError(422, "INVALID_INPUT", "Sangens oplysninger kunne ikke læses.") from None
        return await run_in_threadpool(lambda: checked(lambda: service.submit(key, value)))

    @router.get("/jobs/{key}")
    def job(key: str):
        return checked(lambda: service.public(service.load(key)))

    @router.put("/jobs/{key}/remove")
    def remove(key: str):
        return checked(lambda: service.remove(key))

    @router.get("/jobs/{key}/audio")
    def audio(key: str):
        def read():
            value = service.load(key)
            path = service.folder(key) / "song.wav"
            if value["state"] != "completed" or not path.is_file() or path.stat().st_size > 70_000_000:
                raise SongStudioError("Sangen er ikke klar til hentning.")
            return {"audio": base64.b64encode(path.read_bytes()).decode("ascii")}
        return checked(read)

    app.include_router(router)
    return service

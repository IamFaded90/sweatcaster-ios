"""Paired, user-selected Windows inspection. Images and observations live in the response only."""

from base64 import b64encode
from contextlib import closing
import re
import secrets
import sqlite3
from threading import BoundedSemaphore, Lock
import time

from fastapi import APIRouter, Body, Depends, Request, Response

from sweatcaster import window_capture as desktop
from sweatcaster.dto import ApiError


def _vision(settings, image, question):
    from sweatcaster.config import assert_loopback_ollama
    from sweatcaster.coord import ModelCoord
    from sweatcaster.ollama_runtime import align_resident, installed_tags, mark_loaded
    from sweatcaster.vision import VISION_TAG, iter_vision_text

    assert_loopback_ollama(settings.ollama_origin)
    if VISION_TAG not in (installed_tags(settings) or ()):
        return None
    coord = ModelCoord(settings.output_root / "state.sqlite3")
    lease = coord.try_acquire(VISION_TAG, "vision", allow_pending=False)
    if not lease:
        return None
    try:
        align_resident(settings, coord, VISION_TAG)
        mark_loaded(coord, VISION_TAG)
        # Moondream is a small caption model. Long system prompts produce generic refusals.
        prompt = "What does the text in this image say?"
        if question and not re.fullmatch(r"(?:.*se (?:lige )?min skærm|hvilken tekst står der i vinduet|hvad står der)[?.! ]*",
                                         question.strip(), re.I):
            prompt = question[:300]
        deadline = time.monotonic() + 25
        for instruction in (prompt, "Describe this screenshot."):
            if time.monotonic() >= deadline:
                break
            answer = ""
            with closing(iter_vision_text(settings, VISION_TAG, instruction, image, read_timeout=20, num_predict=120)) as pieces:
                for piece in pieces:
                    answer += piece
                    if len(answer) >= 900 or time.monotonic() >= deadline:
                        break
            answer = answer[:900].strip()
            if answer and not re.search(r"(?:I am sorry|I cannot generate|as an AI|cannot provide|provide a clearer)", answer, re.I):
                return answer
        return None
    finally:
        coord.release(lease)


class WindowHelp:
    def __init__(self, settings, native=desktop, vision=_vision):
        self.settings = settings
        self.native = native
        self.vision = vision
        self.lock = Lock()
        self.tokens = {}
        self.actions = {}
        self.during_capture = BoundedSemaphore(1)

    def _remember(self, table, value, seconds):
        with self.lock:
            now = time.monotonic()
            for key in [k for k, (_, end) in table.items() if end <= now]:
                del table[key]
            if len(table) >= 640:
                del table[next(iter(table))]
            key = secrets.token_urlsafe(24)
            table[key] = (value, now + seconds)
            return key

    def _get(self, table, key, consume=False):
        with self.lock:
            item = table.pop(key, None) if consume else table.get(key)
        if item is None or item[1] <= time.monotonic():
            raise ApiError(409, "NOT_READY", "Valget er udløbet. Vælg vinduet igen.")
        return item[0]

    def windows(self):
        try:
            windows = self.native.list_windows()
        except OSError as exc:
            raise ApiError(409, "NOT_READY", "Start FadedAI i din Windows-session for at vælge et vindue.") from exc
        return {"windows": [{"id": self._remember(self.tokens, window, 300), "title": window.title}
                            for window in windows]}

    def _state(self, window):
        try:
            return self.native.state(window)
        except (ValueError, OSError) as exc:
            raise ApiError(409, "NOT_READY", "Vinduet er lukket eller ændret. Vælg det igen.") from exc

    def inspect(self, token, question):
        window = self._get(self.tokens, token)
        state = self._state(window)
        result = {"title": window.title, "labels": []}
        if state == "minimized":
            result.update(summary="Windows viser, at vinduet er minimeret. Jeg kan åbne det i sin normale størrelse.",
                          approval=self._remember(self.actions, token, 90))
            return result
        if state == "hung":
            result["summary"] = "Windows melder, at vinduet ikke svarer. Vent et øjeblik, og tjek igen."
            return result
        if not self.during_capture.acquire(blocking=False):
            raise ApiError(409, "NOT_READY", "Et vindue er ved at blive læst. Prøv igen om et øjeblik.")
        try:
            try:
                result["labels"] = self.native.labels(window)
                pixels = self.native.capture(window)
            except (ValueError, OSError):
                pixels = None
            self._state(window)
            if pixels:
                result["jpeg"] = b64encode(pixels).decode("ascii")
                try:
                    result["reading"] = self.vision(self.settings, result["jpeg"], question)
                except (ValueError, RuntimeError, OSError, sqlite3.Error):
                    result["reading"] = None
            evidence = " ".join(result["labels"])
            if re.search(r"(?:connection (?:lost|refused)|forbindelsen (?:er |blev )?afbrudt|ingen forbindelse)", evidence, re.I):
                result["summary"] = ("Vinduet melder, at forbindelsen er afbrudt. Tjek om den tjeneste, "
                                     "programmet bruger, stadig kører. Du kan derefter tjekke vinduet igen.")
            elif re.search(r"(?:not enough (?:disk )?space|disk (?:is )?full|ikke (?:nok|tilstrækkelig) (?:disk)?plads)", evidence, re.I):
                result["summary"] = "Vinduet melder, at lagerpladsen er ved at være brugt. Tjek den ledige plads på det valgte drev."
            elif result.get("reading"):
                result["summary"] = "Jeg har taget et nyt billede af vinduet. Her er billedmodellens vurdering."
            elif result["labels"]:
                result["summary"] = "Windows kunne læse teksten nedenfor i vinduet."
            elif pixels:
                result["summary"] = "Her er vinduet lige nu. PC’ens billedmodel kunne ikke give en vurdering."
            else:
                result["summary"] = "Vinduet deler hverken et læsbart billede eller tekst med Windows."
            return result
        finally:
            self.during_capture.release()

    def approve(self, token, approval):
        window = self._get(self.tokens, token)
        if self._get(self.actions, approval, consume=True) != token:
            raise ApiError(409, "NOT_READY", "Godkendelsen hører til et andet vindue.")
        if self._state(window) != "minimized":
            return {"message": "Vinduets tilstand er ændret. Jeg tjekkede igen og lod det stå."}
        try:
            self.native.restore(window)
        except (ValueError, OSError) as exc:
            raise ApiError(409, "NOT_READY", "Windows kunne ikke gendanne vinduet. Tjek igen.") from exc
        for _ in range(10):
            if self._state(window) != "minimized":
                return {"message": "Windows bekræfter, at vinduet er gendannet."}
            time.sleep(0.05)
        return {"message": "Jeg bad Windows gendanne vinduet. Ved kontrollen var det stadig minimeret."}


def register_window_help(app, settings, authorize):
    service = WindowHelp(settings)

    def paired(request: Request, response: Response):
        authorize(request, settings)
        response.headers["Cache-Control"] = "no-store"

    router = APIRouter(prefix="/api/modules/v1/window-help", dependencies=[Depends(paired)], include_in_schema=False)

    @router.get("/windows")
    def windows():
        return service.windows()

    @router.put("/inspect")
    def inspect(token: str = Body(..., max_length=64), question: str = Body("", max_length=500)):
        return service.inspect(token, question)

    @router.put("/restore")
    def restore(token: str = Body(..., max_length=64), approval: str = Body(..., max_length=64)):
        return service.approve(token, approval)

    from sweatcaster.window_operator import register_window_operator
    register_window_operator(router, service)
    app.include_router(router)
    return service

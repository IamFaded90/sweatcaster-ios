"""Paired routes for FadedAI Composio connections."""

import os
import re

from fastapi import APIRouter, Body, Depends, Request, Response

from sweatcaster.composio_library import LIBRARIES
from sweatcaster.dto import ApiError


def register_routes(app, settings, authorize, library, load):
    def paired(request: Request, response: Response):
        authorize(request, settings)
        response.headers["Cache-Control"] = "no-store"

    router = APIRouter(prefix="/api/modules/v1/composio", dependencies=[Depends(paired)], include_in_schema=False)

    @router.get("")
    def states():
        return library.states(LIBRARIES)

    @router.get("/integrations")
    def integrations(refresh: bool = False):
        return library.integrations(refresh=refresh)

    @router.put("/phone-connection")
    def phone_connection(response: Response):
        key = load().get("gmail_consumer_key", "")
        if not isinstance(key, str) or not re.fullmatch(r"ck_[A-Za-z0-9_-]{8,1021}", key):
            raise ApiError(409, "NOT_READY", "Gem Composio For You-forbindelsen på denne PC først.")
        response.headers["Cache-Control"] = "no-store"
        return {"key": key}

    @router.put("/nvidia-phone-connection")
    def nvidia_phone_connection(response: Response):
        from pathlib import Path
        from sweatcaster.emby_settings import _protect
        path = Path(os.environ["LOCALAPPDATA"]) / "FadedAI" / "nvidia.dpapi"
        try:
            encrypted = path.read_bytes()
            if len(encrypted) > 4096:
                raise ValueError("Invalid credential size")
            key = _protect(encrypted, decrypt=True).decode("utf-8")
            if not re.fullmatch(r"nvapi-[A-Za-z0-9_-]{20,1000}", key):
                raise ValueError("Invalid credential")
        except (OSError, ValueError, UnicodeError):
            raise ApiError(409, "NOT_READY", "Forbind NVIDIA på denne PC først.")
        response.headers["Cache-Control"] = "no-store"
        return {"key": key}
    @router.put("/openrouter-phone-connection")
    def openrouter_phone_connection(response: Response):
        from pathlib import Path
        from sweatcaster.emby_settings import _protect
        path = Path(os.environ["LOCALAPPDATA"]) / "FadedAI" / "openrouter.dpapi"
        try:
            encrypted = path.read_bytes()
            if len(encrypted) > 4096:
                raise ValueError("Invalid credential size")
            key = _protect(encrypted, decrypt=True).decode("utf-8")
            if not re.fullmatch(r"sk-or-v1-[A-Za-z0-9_-]{20,1000}", key):
                raise ValueError("Invalid credential")
        except (OSError, ValueError, UnicodeError):
            raise ApiError(409, "NOT_READY", "Forbind OpenRouter på denne PC først.")
        response.headers["Cache-Control"] = "no-store"
        return {"key": key}
    router.add_api_route("/{provider}/items", library.items, methods=["GET"])

    @router.put("/{provider}/link")
    def link(provider: str, bot_id: str = ""):
        if provider == "instagram":
            from sweatcaster.instagram_publishing import agent_library
            return agent_library(library, bot_id).link(provider)
        return library.link(provider)

    @router.put("/{provider}/context")
    def context(provider: str, body: dict = Body(...)):
        return library.context(provider, body.get("item"))

    @router.get("/gmail/status")
    def gmail_status():
        return {"connected": bool(library.connection("gmail")), "canSend": library.gmail() is not None}

    @router.get("/gmail/message/{identifier}")
    def gmail_message(identifier: str):
        return library.gmail_message(identifier)

    @router.get("/gmail/messages")
    def gmail_messages(q: str = ""):
        return {"messages": library.gmail_messages(q)}

    @router.put("/gmail/send")
    def gmail_send(body: dict = Body(...)):
        return library.send_gmail(body)

    @router.get("/gmail/reply/{identifier}")
    def gmail_reply_target(identifier: str):
        return library.gmail_reply_target(identifier)

    @router.put("/gmail/reply")
    def gmail_reply(body: dict = Body(...)):
        return library.reply_gmail(body)

    @router.get("/gmail/reply/receipts/{identifier}")
    def gmail_reply_receipt(identifier: str):
        return library.gmail_reply_receipt(identifier)

    @router.get("/gmail/reply/followup/{identifier}")
    def gmail_followup(identifier: str):
        return library.gmail_followup(identifier)

    from sweatcaster.instagram_publishing import register_instagram
    from sweatcaster.instagram_scheduling import InstagramSchedule, register_schedule
    register_instagram(router, library, settings.output_root)
    app.state.instagram_schedule = InstagramSchedule(library, settings.output_root)
    register_schedule(router, app.state.instagram_schedule)
    app.include_router(router)

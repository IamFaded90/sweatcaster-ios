"""Paired, transient Office imports for the agent's document library."""

import asyncio
import subprocess
import sys
from pathlib import Path

from fastapi import Request, Response
from starlette.concurrency import run_in_threadpool

from sweatcaster.dto import ApiError

LIMIT = 8_000_000


def read_office(data: bytes, kind: str, runtime: Path) -> dict:
    if not runtime.is_file():
        raise ApiError(503, "NOT_READY", "Opdatér FadedAI på PC’en for at hente dokumentlæseren.")
    try:
        result = subprocess.run(
            [str(runtime), "-I", str(Path(__file__).with_name("document_reader.py")), kind],
            input=data, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=45,
            creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
        )
    except subprocess.TimeoutExpired as exc:
        raise ApiError(422, "INVALID_INPUT", "Dokumentet tog for lang tid at læse. Prøv et kortere uddrag.") from exc
    if result.returncode == 3:
        raise ApiError(413, "TOO_LARGE", "Dokumentet er for stort. Del det op i mindre filer.")
    if result.returncode == 1:
        raise ApiError(503, "NOT_READY", "Dokumentlæseren skal opdateres på PC’en.")
    if result.returncode or len(result.stdout) > 96_000:
        raise ApiError(422, "INVALID_INPUT", "PC’en kunne ikke læse dokumentet. Prøv at gemme en lokal kopi som PDF.")
    return {"text": result.stdout.decode("utf-8")}


def register_documents(app, settings, authorize, *, runtime=None):
    if runtime is None:
        runtime = Path(__file__).resolve().parents[1] / "document-tools-venv"
        runtime /= "Scripts/python.exe" if sys.platform == "win32" else "bin/python"
    busy = asyncio.Lock()

    @app.post("/api/modules/v1/agent-documents/{kind}", include_in_schema=False)
    async def read_document(kind: str, request: Request, response: Response):
        authorize(request, settings)
        response.headers["Cache-Control"] = "no-store"
        if kind not in {"docx", "pptx", "xlsx"}:
            raise ApiError(422, "INVALID_INPUT", "Vælg en Word-, Excel- eller PowerPoint-fil.")
        if busy.locked():
            raise ApiError(409, "NOT_READY", "PC’en læser allerede et dokument. Prøv igen om lidt.")
        async with busy:
            data = bytearray()
            async for chunk in request.stream():
                if len(data) + len(chunk) > LIMIT:
                    raise ApiError(413, "TOO_LARGE", "Vælg et dokument på højst 8 MB.")
                data.extend(chunk)
            return await run_in_threadpool(read_office, bytes(data), kind, runtime)

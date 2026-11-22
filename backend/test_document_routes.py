from pathlib import Path

from fastapi import FastAPI, HTTPException
from fastapi.responses import JSONResponse
from fastapi.testclient import TestClient

from sweatcaster import document_routes
from sweatcaster.dto import ApiError


def client(monkeypatch):
    app = FastAPI()
    calls = []

    @app.exception_handler(ApiError)
    async def report(request, error):
        return JSONResponse({"error": error.code}, status_code=error.status_code)

    def authorize(request, settings):
        if request.headers.get("authorization") != "Bearer test":
            raise HTTPException(401)

    def read(data, kind, runtime):
        calls.append((data, kind))
        return {"text": "Prøve"}

    monkeypatch.setattr(document_routes, "read_office", read)
    document_routes.register_documents(app, None, authorize, runtime=Path("unused"))
    return TestClient(app), calls


def test_paired_office_bytes_only(monkeypatch):
    api, calls = client(monkeypatch)
    path = "/api/modules/v1/agent-documents/"
    paired = {"Authorization": "Bearer test"}
    assert api.post(path + "docx", content=b"example").status_code == 401
    assert api.post(path + "zip", headers=paired, content=b"example").status_code == 422
    monkeypatch.setattr(document_routes, "LIMIT", 10)
    assert api.post(path + "xlsx", headers=paired, content=b"x" * 11).status_code == 413
    result = api.post(path + "pptx", headers=paired, content=b"example")
    assert result.headers["Cache-Control"] == "no-store"
    assert result.json() == {"text": "Prøve"}
    assert calls == [(b"example", "pptx")]

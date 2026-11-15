"""Prepare public GitHub add-ons and package small static web builds."""

import base64
import binascii
import io
import json
import re
import stat
import zipfile
from pathlib import PurePosixPath
from time import monotonic
from urllib.parse import quote, urlsplit
from uuid import NAMESPACE_URL, uuid5

import requests

from sweatcaster.dto import ApiError

GITHUB = "https://api.github.com"
CODELOAD = "https://codeload.github.com"
REPO = re.compile(r"[A-Za-z0-9][A-Za-z0-9-]{0,38}/[A-Za-z0-9_.-]{1,100}")
REVISION = re.compile(r"[0-9a-f]{40}")
PART = re.compile(r"[A-Za-z0-9_][A-Za-z0-9_.-]{0,95}")
ROOTS = ("dist", "docs", "")
EXTENSIONS = frozenset((".html", ".htm", ".css", ".js", ".mjs", ".json", ".png", ".jpg", ".jpeg", ".gif",
                        ".webp", ".svg", ".ico", ".woff", ".woff2", ".ttf", ".txt", ".wasm", ".mp3", ".ogg"))
MAX_ARCHIVE = 12_000_000
MAX_BUNDLE = 6_000_000
MAX_FILES = 250
MANIFEST = "fadedai-addon.json"


def repo_name(value):
    try:
        url = urlsplit(value.strip())
        candidate = url.path.strip("/").removesuffix(".git")
        if (url.scheme == "https" and url.netloc.lower() in {"github.com", "www.github.com"}
                and len(value) <= 512 and REPO.fullmatch(candidate)
                and candidate.split("/")[1] not in {".", ".."}):
            return candidate
    except (AttributeError, ValueError):
        pass
    raise ApiError(422, "INVALID_INPUT", "Indsæt et GitHub-link til selve repoet, fx https://github.com/ejer/projekt.")


def read(url, *, maximum, missing=False, params=None):
    try:
        with requests.Session() as client:
            client.trust_env = False
            with client.get(url, params=params, timeout=(4, 6), allow_redirects=False, stream=True,
                            headers={"Accept": "application/vnd.github+json", "User-Agent": "FadedAI"}) as response:
                if response.status_code == 404 and missing:
                    return None
                if response.status_code in (403, 429):
                    raise ApiError(503, "NOT_READY", "GitHub har midlertidigt begrænset opslag. Prøv igen senere.")
                if response.status_code == 404:
                    raise ApiError(404, "NOT_FOUND", "GitHub-projektet kunne ikke hentes. Tjek, at det er offentligt.")
                if response.status_code != 200:
                    raise ValueError
                deadline = monotonic() + 12
                data = bytearray()
                for chunk in response.iter_content(64_000):
                    data.extend(chunk)
                    if len(data) > maximum or monotonic() >= deadline:
                        raise ApiError(422, "INVALID_INPUT", "GitHub-pakken er for stor eller tog for lang tid at hente.")
                return bytes(data)
    except (requests.RequestException, ValueError) as error:
        raise ApiError(502, "NOT_READY", "GitHub svarede ikke som forventet. Prøv igen.") from error


def get_json(path, *, missing=False, params=None, maximum=200_000):
    data = read(GITHUB + path, maximum=maximum, missing=missing, params=params)
    if data is None:
        return None
    try:
        value = json.loads(data)
        if isinstance(value, dict):
            return value
    except (ValueError, RecursionError):
        pass
    raise ApiError(502, "NOT_READY", "GitHub sendte et ugyldigt svar.")


def source_identity(source):
    return str(uuid5(NAMESPACE_URL, "https://github.com/" + source["repo"].lower() + "/"
                     + source["revision"] + "/" + source["kind"] + "/" + source["root"]))


def source_info(source):
    if not isinstance(source, dict) or set(source) != {"repo", "revision", "kind", "root"}:
        raise ValueError
    repo, sha, kind, root = (source[key] for key in ("repo", "revision", "kind", "root"))
    if not (isinstance(repo, str) and REPO.fullmatch(repo) and repo.split("/")[1] not in {".", ".."}
            and isinstance(sha, str) and REVISION.fullmatch(sha)
            and kind in ("manifest", "static", "pages") and root in ROOTS and (kind == "static" or root == "")):
        raise ValueError
    return {"repo": repo, "revision": sha, "kind": kind, "root": root}


def pages_url(details, repo):
    if details.get("has_pages") is not True:
        return None
    owner, name = repo.split("/")
    host = owner.lower() + ".github.io"
    return f"https://{host}/" if name.lower() == host else f"https://{host}/{name}/"


def proposal(address, *, prefer_local=False):
    repo = repo_name(address)
    details = get_json("/repos/" + repo)
    if details.get("private") is not False or str(details.get("full_name", "")).lower() != repo.lower():
        raise ApiError(404, "NOT_FOUND", "GitHub-projektet kunne ikke bekræftes som offentligt.")
    repo = details["full_name"]
    branch = details.get("default_branch")
    if not isinstance(branch, str) or not 1 <= len(branch) <= 240:
        raise ApiError(422, "INVALID_INPUT", "Projektet har ingen standardgren, der kan hentes.")
    revision = get_json(f"/repos/{repo}/commits/{quote(branch, safe='')}").get("sha")
    if not isinstance(revision, str) or not REVISION.fullmatch(revision):
        raise ApiError(502, "NOT_READY", "GitHub-versionen kunne ikke bekræftes.")

    info = {"repo": repo, "revision": revision, "kind": "manifest", "root": ""}
    contents = None if prefer_local else get_json(
        f"/repos/{repo}/contents/{MANIFEST}", missing=True, params={"ref": revision}, maximum=40_000)
    if contents is not None:
        try:
            if contents.get("type") != "file" or contents.get("encoding") != "base64":
                raise ValueError
            decoded = base64.b64decode("".join(contents["content"].split()), validate=True)
            manifest = json.loads(decoded.decode("utf-8-sig"))
            if not isinstance(manifest, dict):
                raise ValueError
            version = manifest.pop("version", None)
            if type(version) is not int or version != 1:
                raise ValueError
        except (KeyError, ValueError, TypeError, AttributeError, binascii.Error, RecursionError):
            raise ApiError(422, "INVALID_INPUT", "Projektets fadedai-addon.json kunne ikke læses.") from None
        return {**manifest, "id": source_identity(info), "source": info}

    title = repo.split("/")[1][:48]
    description = details.get("description")
    description = description.strip()[:500] if isinstance(description, str) else ""
    site = None if prefer_local else pages_url(details, repo)
    if site:
        info["kind"] = "pages"
        actions = [{"type": "link", "label": "Åbn webværktøj", "value": site}]
    else:
        for root in ROOTS:
            path = f"{root}/index.html" if root else "index.html"
            request = f"/repos/{repo}/contents/{path}"
            try:
                entry = get_json(request, missing=True, params={"ref": revision}, maximum=500_000)
            except ApiError as error:
                if error.status_code != 422:
                    raise
                entry = None
            if entry is not None and entry.get("type") == "file":
                info.update(kind="static", root=root)
                actions = [{"type": "webApp", "label": "Åbn webværktøj", "value": "index.html"}]
                break
        else:
            detail = ("Code Bot fandt ingen færdig lokal webpakke i repoet. Prøv at hente projektets udgivne webudgave."
                      if prefer_local else "Code Bot fandt ingen færdig webudgave eller FadedAI-pakke i repoet.")
            raise ApiError(422, "INVALID_INPUT", detail)
    return {"id": source_identity(info), "source": info, "title": title,
            "text": description or f"Webværktøj fra {repo}.", "actions": actions}


def pack_web_files(info):
    source_info(info)
    if info["kind"] != "static":
        raise ValueError
    archive = read(f"{CODELOAD}/{info['repo']}/zip/{info['revision']}", maximum=MAX_ARCHIVE)
    prefix = [info["root"]] if info["root"] else []
    files = []
    seen = set()
    total = 0
    try:
        with zipfile.ZipFile(io.BytesIO(archive)) as zipped:
            if len(zipped.infolist()) > 10_000:
                raise ValueError
            for entry in zipped.infolist():
                if entry.is_dir():
                    continue
                outer, separator, relative = entry.filename.partition("/")
                if not separator or not outer:
                    continue
                parts = relative.split("/")
                if parts[:len(prefix)] != prefix or len(parts) <= len(prefix):
                    continue
                parts = parts[len(prefix):]
                path = "/".join(parts)
                if PurePosixPath(path).suffix.lower() not in EXTENSIONS or path == MANIFEST:
                    continue
                if any(part.startswith(".") and part != ".." for part in parts):
                    continue
                if (not all(PART.fullmatch(part) for part in parts) or len(parts) > 10 or len(path) > 240
                        or path.lower() in seen or stat.S_ISLNK(entry.external_attr >> 16)):
                    raise ValueError
                seen.add(path.lower())
                total += entry.file_size
                if total > MAX_BUNDLE or len(files) >= MAX_FILES:
                    raise ValueError
                with zipped.open(entry) as stream:
                    data = stream.read(entry.file_size + 1)
                if len(data) != entry.file_size:
                    raise ValueError
                files.append({"path": path, "data": base64.b64encode(data).decode("ascii")})
        if not any(file["path"] == "index.html" for file in files):
            raise ValueError
    except (ValueError, zipfile.BadZipFile, RuntimeError, OSError, NotImplementedError) as error:
        raise ApiError(422, "INVALID_INPUT", "Webpakken kunne ikke installeres. Brug en færdig statisk pakke med "
                       "index.html og højst 6 MB filer.") from error
    return {"files": files}

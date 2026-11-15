"""Import the public text of a Grok Bot template without running its actions."""

from html.parser import HTMLParser
import re
from urllib.parse import urlsplit

import requests
from fastapi import Body, Request, Response

from sweatcaster.dto import ApiError

ORIGIN = "https://x.ai"
CATALOG = "/bot/marketplace"
DETAIL = re.compile(r"/bot/marketplace/bots/[a-z0-9][a-z0-9-]{0,95}")
SHARE = re.compile(r"/bot/[A-Za-z0-9_-]{16,80}")
MAX_HTML = 3_000_000
MAX_INSTRUCTIONS = 4_000


def public_path(value):
    if not isinstance(value, str) or not 1 <= len(value) <= 2048:
        return None
    try:
        parts = urlsplit(value.strip())
        path = parts.path.rstrip("/")
        if (parts.scheme == "https" and parts.hostname in {"x.ai", "www.x.ai"} and parts.port in {None, 443}
                and parts.username is None and parts.password is None
                and (DETAIL.fullmatch(path) or SHARE.fullmatch(path))):
            return path
    except ValueError:
        pass
    return None


def clean_text(text):
    return " ".join(text.split())


def bounded(text, count):
    return text.encode("utf-8", errors="replace")[:count].decode("utf-8", errors="ignore").strip()


class PublicMarkup(HTMLParser):
    def __init__(self, html):
        super().__init__(convert_charrefs=True)
        self.articles = 0
        self.capture = None
        self.fragments = []
        self.title = ""
        self.description = ""
        self.instructions = []
        self.links = []
        self.feed(html)
        self.close()

    def handle_starttag(self, tag, attrs):
        attributes = dict(attrs)
        if tag == "meta" and attributes.get("property") == "og:description":
            self.description = clean_text(attributes.get("content") or "")
        if tag == "article":
            self.articles += 1
        elif tag == "a":
            href = attributes.get("href") or ""
            path = public_path(ORIGIN + href if href.startswith("/") else href)
            if path:
                self.links.append(path)
        elif self.articles and self.capture is None:
            if tag == "h1" or tag == "p" and "whitespace-pre-wrap" in (attributes.get("class") or "").split():
                self.capture = tag
                self.fragments = []

    def handle_endtag(self, tag):
        if tag == self.capture:
            text = clean_text("".join(self.fragments))
            if text:
                if tag == "h1":
                    self.title = self.title or text
                elif len(self.instructions) < 40:
                    self.instructions.append(text)
            self.capture = None
        if tag == "article":
            self.articles = max(0, self.articles - 1)

    def handle_data(self, data):
        if self.capture:
            self.fragments.append(data)

    def marketplace_detail(self, share):
        candidate = None
        for link in self.links:
            if DETAIL.fullmatch(link):
                candidate = link
            elif SHARE.fullmatch(link):
                if link == share and candidate:
                    return candidate
                candidate = None
        return None


def fetch(path):
    try:
        with requests.Session() as session:
            session.trust_env = False
            with session.get(ORIGIN + path, headers={"Accept": "text/html", "User-Agent": "FadedAI"},
                             timeout=(4, 10), allow_redirects=False, stream=True) as response:
                if response.status_code in {401, 403, 404, 410}:
                    raise ApiError(404, "NOT_FOUND", "Skabelonen er privat, slettet eller ikke tilgængelig.")
                if response.status_code != 200 or "text/html" not in response.headers.get("Content-Type", ""):
                    raise ValueError("Invalid template response")
                data = bytearray()
                for chunk in response.iter_content(65536):
                    data.extend(chunk)
                    if len(data) > MAX_HTML:
                        raise ValueError("Template too large")
        return PublicMarkup(data.decode("utf-8", errors="replace"))
    except (requests.RequestException, ValueError) as exc:
        raise ApiError(502, "NOT_READY", "PC’en kunne ikke hente Grok-skabelonen lige nu.") from exc


def import_template(value, fetch_page=fetch):
    path = public_path(value)
    if not path:
        raise ApiError(422, "INVALID_INPUT", "Indsæt et offentligt Grok Bot-link eller et link til en bot på markedspladsen.")
    page = fetch_page(path)
    used_path = path
    if SHARE.fullmatch(path) and page.title and not page.instructions:
        try:
            candidate = fetch_page(CATALOG).marketplace_detail(path)
        except ApiError:
            candidate = None
        if not candidate:
            slug = re.sub(r"[^a-z0-9]+", "-", page.title.lower()).strip("-")
            guessed = CATALOG + "/bots/" + slug
            candidate = guessed if DETAIL.fullmatch(guessed) else None
        try:
            if candidate:
                detail = fetch_page(candidate)
                # Require the marketplace page to link back to this exact template.
                if detail.title and path in detail.links:
                    page, used_path = detail, candidate
        except ApiError:
            pass  # The public share card remains a valid source for a limited import.

    if not page.title or not page.description:
        raise ApiError(422, "INVALID_INPUT", "Grok viser ikke en offentlig botbeskrivelse på linket.")
    name = page.title[:80]
    description = bounded(page.description, 550)
    parts = [f"Rolle: {description}"]
    remaining = MAX_INSTRUCTIONS - len(parts[0].encode("utf-8"))
    for paragraph in page.instructions:
        text = bounded(paragraph, min(remaining - 2, 1800))
        if not text:
            break
        parts.append(text)
        remaining -= len(text.encode("utf-8")) + 2
        if remaining <= 40:
            break
    return {"name": name, "instructions": "\n\n".join(parts),
            "source": ORIGIN + used_path, "hasDetails": len(parts) > 1}


def register_grok_templates(app, settings, authorize):
    @app.put("/api/modules/v1/grok-template", include_in_schema=False)
    def get_grok_template(request: Request, response: Response, body: dict = Body(...)):
        authorize(request, settings)
        response.headers["Cache-Control"] = "no-store"
        return import_template(body.get("url"))

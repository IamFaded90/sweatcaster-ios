"""Extract visible product microdata from a downloaded page using an offline browser."""
import json
import os
from pathlib import Path
import sys

from playwright.sync_api import sync_playwright


def extract(data):
    with sync_playwright() as playwright:
        options = {"chromium_sandbox": True}
        edge = Path(os.environ.get("ProgramFiles(x86)", "")) / "Microsoft/Edge/Application/msedge.exe"
        if os.name == "nt" and edge.is_file():
            options["executable_path"] = str(edge)
        with playwright.chromium.launch(**options) as browser:
            context = browser.new_context(offline=True, java_script_enabled=False, service_workers="block",
                                          accept_downloads=False)
            context.route("**/*", lambda route: route.abort())
            page = context.new_page()
            page.set_content(data.decode("utf-8", errors="replace"), wait_until="domcontentloaded", timeout=4500)
            products = page.locator('[itemscope][itemtype$="/Product"]:visible')
            if products.count() != 1:
                return
            product = products.first
            offers = product.locator('[itemprop~="offers"][itemtype$="/Offer"]')
            if offers.count() != 1:
                return

            def field(scope, prop):
                nodes = scope.locator(f'[itemprop~="{prop}"]')
                if nodes.count() == 1:
                    return nodes.get_attribute("content") or nodes.get_attribute("href") or nodes.inner_text().strip()
                return None

            offer = offers.first
            result = {"@type": "Product", "name": field(product, "name") or "",
                      "offers": {"@type": "Offer", "price": field(offer, "price"),
                                 "priceCurrency": field(offer, "priceCurrency"),
                                 "availability": field(offer, "availability") or ""}}
            payload = json.dumps(result, ensure_ascii=True).replace("<", r"\u003c")
            return ('<script type="application/ld+json">' + payload + '</script>').encode()


if __name__ == "__main__":
    document = sys.stdin.buffer.read(512_001)
    if document and len(document) <= 512_000:
        sys.stdout.buffer.write(extract(document) or b"")

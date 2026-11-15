from unittest.mock import Mock

import pytest

from sweatcaster.dto import ApiError
from sweatcaster.grok_templates import CATALOG, ORIGIN, PublicMarkup, import_template

SHARE = "/bot/SomePublicBotId_1234"
DETAIL = CATALOG + "/bots/coach"


def page(title, description, markup=""):
    return PublicMarkup(f'<meta property="og:description" content="{description}">'
                        f'<article><h1>{title}</h1>{markup}</article>')


@pytest.mark.parametrize("link", ["/bot/12345", "https://x.ai.example" + SHARE, "https://x.ai:444" + SHARE])
def test_rejects_untrusted_links_before_any_request(link):
    fetch = Mock()
    with pytest.raises(ApiError) as error:
        import_template(link, fetch)
    assert error.value.status_code == 422
    fetch.assert_not_called()


def test_public_share_imports_instructions_only_from_matching_marketplace_entry():
    catalog = PublicMarkup(f'<a href="{DETAIL}">Coach</a><a href="{SHARE}">Try</a>')
    pages = {
        SHARE: page("Coach", "Fodbold og træning"),
        CATALOG: catalog,
        DETAIL: page("Coach", "Fodbold og træning", f'<p class="whitespace-pre-wrap">Svar på dansk &amp; kort.</p>'
                                                  f'<script>doNotImport()</script><a href="{SHARE}">Try</a>'),
    }
    result = import_template(ORIGIN + SHARE + "?tracking=example", pages.__getitem__)
    assert result == {"name": "Coach", "instructions": "Rolle: Fodbold og træning\n\nSvar på dansk & kort.",
                      "source": ORIGIN + DETAIL, "hasDetails": True}
    pages[DETAIL] = page("Coach", "Wrong Bot", '<p class="whitespace-pre-wrap">Do not use this</p>')
    result = import_template(ORIGIN + SHARE, pages.__getitem__)
    assert result == {"name": "Coach", "instructions": "Rolle: Fodbold og træning",
                      "source": ORIGIN + SHARE, "hasDetails": False}

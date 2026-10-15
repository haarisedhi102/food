"""Playwright harness: a real, persistent, logged-in Chrome.

Both retailers sit behind Akamai, which drops non-browser TLS fingerprints and
rejects headless automation. So we drive a real headed Chrome with a persistent
profile (you log in once, MFA included) and run every API call *inside the page*
via `page_fetch`, so it carries the browser's real TLS + cookies.
"""

from __future__ import annotations

import json
from contextlib import contextmanager
from typing import Any, Iterator

from playwright.sync_api import BrowserContext, Page, sync_playwright

from .. import config


@contextmanager
def browser(cdp: str | None = None, headless: bool = False) -> Iterator[BrowserContext]:
    config.ensure_dirs()
    with sync_playwright() as p:
        if cdp:
            b = p.chromium.connect_over_cdp(cdp)
            ctx = b.contexts[0] if b.contexts else b.new_context()
            yield ctx
            return
        ctx = p.chromium.launch_persistent_context(
            user_data_dir=str(config.BROWSER_PROFILE_DIR),
            channel="chrome",
            headless=headless,
            ignore_default_args=["--enable-automation"],
            args=["--disable-blink-features=AutomationControlled"],
        )
        try:
            yield ctx
        finally:
            ctx.close()


def page_fetch(
    page: Page,
    url: str,
    method: str = "GET",
    headers: dict[str, str] | None = None,
    body: str | None = None,
) -> dict[str, Any]:
    """Run fetch() inside the page so it uses the real browser TLS + session cookies."""
    opts: dict[str, Any] = {
        "method": method,
        "headers": headers or {},
        "credentials": "include",
    }
    if body is not None:
        opts["body"] = body
    return page.evaluate(
        """async ([url, opts]) => {
            try {
                const r = await fetch(url, opts);
                const text = await r.text();
                let json = null;
                try { json = JSON.parse(text); } catch (e) {}
                return { status: r.status, ok: r.ok, json, text };
            } catch (e) {
                return { status: -1, ok: false, json: null, text: String(e) };
            }
        }""",
        [url, opts],
    )


def ensure_login(page: Page, url: str, is_logged_in_js: str, prompt: str) -> None:
    """Navigate to `url`; if not logged in, wait for the human to finish MFA."""
    page.goto(url, wait_until="domcontentloaded", timeout=60_000)
    page.wait_for_timeout(1500)
    if page.evaluate(is_logged_in_js):
        print(f"    already logged in at {url}")
        return
    print(f"\n>>> {prompt}")
    print(f">>> A Chrome window is open at {url}. Complete login (incl. MFA), then return here.")
    input(">>> Press Enter once you are logged in... ")
    page.wait_for_timeout(2000)


def archive(prefix: str, payload: Any) -> str:
    """Persist a raw payload so re-normalizing never requires a re-scrape."""
    config.ensure_dirs()
    from datetime import datetime

    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    path = config.IMPORTS_DIR / f"{prefix}-{stamp}.json"
    path.write_text(json.dumps(payload, indent=2)[:50_000_000])
    return str(path)

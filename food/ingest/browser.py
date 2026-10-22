"""Playwright harness: a real, persistent, logged-in Chrome.

Both retailers sit behind Akamai, which drops non-browser TLS fingerprints and
rejects headless automation. So we drive a real headed Chrome with a persistent
profile (you log in once, MFA included) and run every API call *inside the page*
via `page_fetch`, so it carries the browser's real TLS + cookies.
"""

from __future__ import annotations

import json
import os
import time
from contextlib import contextmanager
from typing import Any, Callable, Iterator

from playwright.sync_api import BrowserContext, Error as PlaywrightError, Page, sync_playwright

from .. import config


def _restore_session(ctx: BrowserContext) -> None:
    """Re-inject the saved cookie jar, including session-only cookies Chromium drops."""
    path = config.SESSION_STATE_PATH
    if not path.exists():
        return
    try:
        state = json.loads(path.read_text())
    except (OSError, ValueError) as e:
        print(f"    session state unreadable: {e}")
        return
    now = time.time()
    cookies = [
        c
        for c in state.get("cookies", [])
        if c.get("expires", -1) <= 0 or c["expires"] > now
    ]
    if not cookies:
        return
    try:
        ctx.add_cookies(cookies)
        print(f"    restored {len(cookies)} session cookies")
    except PlaywrightError as e:  # a stale/invalid cookie shouldn't block the run
        print(f"    could not restore session cookies: {e}")


def save_session(ctx: BrowserContext) -> None:
    """Persist cookies + origin storage after a successful login/fetch.

    `storage_state` includes session cookies (`expires=-1`), which is the whole point:
    Kroger's `sid`/`JSESSIONID` are session-only and vanish when Chrome closes.
    """
    path = config.SESSION_STATE_PATH
    try:
        state = ctx.storage_state()
        path.parent.mkdir(parents=True, exist_ok=True)
        tmp = path.with_suffix(".tmp")
        tmp.write_text(json.dumps(state))
        os.chmod(tmp, 0o600)
        tmp.replace(path)
    except Exception as e:  # noqa: BLE001 - persistence is best-effort
        print(f"    could not save session state: {e}")


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
        _restore_session(ctx)
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
    script = """async ([url, opts]) => {
            try {
                const r = await fetch(url, opts);
                const text = await r.text();
                let json = null;
                try { json = JSON.parse(text); } catch (e) {}
                return { status: r.status, ok: r.ok, json, text };
            } catch (e) {
                return { status: -1, ok: false, json: null, text: String(e) };
            }
        }"""
    # a slow navigation can destroy the JS context mid-call; let the page settle and retry
    for attempt in range(4):
        try:
            return page.evaluate(script, [url, opts])
        except PlaywrightError:
            page.wait_for_timeout(1000 * (attempt + 1))
    return page.evaluate(script, [url, opts])


def ensure_login(
    page: Page,
    url: str,
    is_logged_in_js: str,
    prompt: str,
    refresh: Callable[[Page], None] | None = None,
) -> None:
    """Navigate to `url`; if not logged in, wait for the human to finish MFA.

    `refresh` optionally renews an expired session in place (e.g. reloading the account
    page so the SPA mints a new token) before falling back to a full login prompt.
    """
    page.goto(url, wait_until="domcontentloaded", timeout=60_000)
    _settle(page)  # the signed-out signal renders late on the SPA; don't probe too early
    if _logged_in(page, is_logged_in_js):
        page.wait_for_timeout(1500)  # let the SPA settle before the first API call
        print(f"    already logged in at {url}")
        save_session(page.context)
        return
    if refresh is not None:
        print("    session expired; trying an in-place refresh ...")
        try:
            refresh(page)
        except Exception as e:  # noqa: BLE001 - fall through to the login prompt
            print(f"    refresh attempt failed: {e}")
        if _logged_in(page, is_logged_in_js):
            print("    session refreshed without a login")
            page.wait_for_timeout(1500)
            save_session(page.context)
            return
    print(f"\n>>> {prompt}")
    print(f">>> A Chrome window is open at {url}. Complete login (incl. MFA), then return here.")
    input(">>> Press Enter once you are logged in... ")
    page.wait_for_timeout(2000)
    if _logged_in(page, is_logged_in_js):
        save_session(page.context)


def _settle(page: Page, timeout_ms: int = 15_000) -> None:
    """Wait for the initial navigation to finish before probing for login."""
    try:
        page.wait_for_load_state("networkidle", timeout=timeout_ms)
    except PlaywrightError:  # a long-polling app may never go idle; that's fine
        pass
    page.wait_for_timeout(1000)


def _logged_in(page: Page, is_logged_in_js: str, attempts: int = 6) -> bool:
    """Evaluate the login predicate, tolerating a redirect that destroys the JS context."""
    for _ in range(attempts):
        try:
            return bool(page.evaluate(is_logged_in_js))
        except PlaywrightError:  # execution context destroyed by an in-flight navigation
            page.wait_for_timeout(1000)
    return False


def archive(prefix: str, payload: Any) -> str:
    """Persist a raw payload so re-normalizing never requires a re-scrape."""
    config.ensure_dirs()
    from datetime import datetime

    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    path = config.IMPORTS_DIR / f"{prefix}-{stamp}.json"
    path.write_text(json.dumps(payload, indent=2)[:50_000_000])
    return str(path)

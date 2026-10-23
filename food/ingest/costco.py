"""Costco in-warehouse receipts via the internal GraphQL API."""

from __future__ import annotations

import json
import time
from datetime import date, timedelta
from typing import Any

from .. import config
from . import browser as b

GRAPHQL_URL = "https://ecom-api.costco.com/ebusiness/order/v1/orders/graphql"
ORDERS_URL = "https://www.costco.com/myaccount/orders"

# Public values shipped inside Costco's own browser bundle (not secrets).
WCS_CLIENT_ID = "4900eb1f-0c10-4bd9-99c3-c59e6c1ecebf"
CLIENT_IDENTIFIER = "481b1aec-aa3b-454b-b81b-48187e28f205"

# A present idToken is not enough — a stale one still yields 401. Require an unexpired JWT so
# `ensure_login` refreshes the session before prompting for a full login.
LOGGED_IN_JS = """() => {
  const token = localStorage.getItem('idToken');
  if (!token) return false;
  try {
    const part = token.split('.')[1].replace(/-/g, '+').replace(/_/g, '/');
    const claims = JSON.parse(atob(part));
    return !claims.exp || claims.exp * 1000 > Date.now();
  } catch (e) {
    return false;
  }
}"""

# Costco's idToken lives only ~12 minutes, but the orders-page SPA mints a new one from the
# stored refresh token on load. Read both the token and whether it is still valid.
TOKEN_STATE_JS = """() => {
  const token = localStorage.getItem('idToken');
  if (!token) return { token: null, exp: null, valid: false };
  try {
    const part = token.split('.')[1].replace(/-/g, '+').replace(/_/g, '/');
    const claims = JSON.parse(atob(part));
    return { token, exp: claims.exp || null, valid: !claims.exp || claims.exp * 1000 > Date.now() };
  } catch (e) {
    return { token, exp: null, valid: false };
  }
}"""

QUERY = (config.SHARED_DIR / "costco.graphql").read_text().strip()


def _headers(id_token: str) -> dict[str, str]:
    return {
        "Content-Type": "application/json-patch+json",
        "Accept": "*/*",
        "costco-x-authorization": f"Bearer {id_token}",
        "costco-x-wcs-clientid": WCS_CLIENT_ID,
        "client-identifier": CLIENT_IDENTIFIER,
        "costco.env": "ecom",
        "costco.service": "restOrders",
    }


def _window(
    lookback_days: int, since: date | None = None, today: date | None = None
) -> tuple[date, date]:
    """Start/end dates for the GraphQL query.

    `since` is the newest stored purchase date, used to make repeat syncs incremental. A
    2-day overlap catches receipts that post late; the lookback floor and today clamp it.
    """
    end = today or date.today()
    floor = end - timedelta(days=lookback_days)
    start = floor
    if since is not None and since - timedelta(days=2) > floor:
        start = since - timedelta(days=2)
    if start > end:
        start = end
    return start, end


def _refresh(page: b.Page) -> None:
    """Reload the orders page so its SPA mints a fresh idToken from the refresh token."""
    page.reload(wait_until="domcontentloaded", timeout=60_000)
    b._settle(page)


def _wait_for_valid_token(page: b.Page, timeout_s: float = 25.0) -> dict:
    """Poll for a non-expired idToken; the SPA refresh can finish after load settles."""
    deadline = time.monotonic() + timeout_s
    last: dict = {}
    while time.monotonic() < deadline:
        try:
            last = page.evaluate(TOKEN_STATE_JS)
        except Exception:  # noqa: BLE001 - navigation can destroy the JS context
            page.wait_for_timeout(500)
            continue
        if last.get("valid") and last.get("token"):
            return last
        page.wait_for_timeout(500)
    return last


def pull(
    lookback_days: int,
    document_type: str = "warehouse",
    cdp: str | None = None,
    since: date | None = None,
) -> dict:
    start, end = _window(lookback_days, since)
    # Warehouse receipts expect M/D/YYYY (no zero padding).
    variables = {
        "startDate": f"{start.month}/{start.day}/{start.year}",
        "endDate": f"{end.month}/{end.day}/{end.year}",
        "documentType": document_type,
        "documentSubType": "all",
    }

    with b.browser(cdp=cdp) as ctx:
        page = ctx.pages[0] if ctx.pages else ctx.new_page()
        b.ensure_login(
            page,
            ORDERS_URL,
            LOGGED_IN_JS,
            "Log into Costco (MFA may be required).",
            refresh=_refresh,
        )
        state = _wait_for_valid_token(page)
        if not state.get("valid") or not state.get("token"):
            raise RuntimeError("No valid Costco idToken after refresh/login.")
        print("    pulling Costco receipts ...")
        res = b.page_fetch(
            page,
            GRAPHQL_URL,
            method="POST",
            headers=_headers(state["token"]),
            body=json.dumps({"query": QUERY, "variables": variables}),
        )
        if not res["ok"] and res["status"] == 401:
            print("    Costco 401 — refreshing the session and retrying once ...")
            try:
                _refresh(page)
                state = _wait_for_valid_token(page)
                if state.get("valid") and state.get("token"):
                    res = b.page_fetch(
                        page,
                        GRAPHQL_URL,
                        method="POST",
                        headers=_headers(state["token"]),
                        body=json.dumps({"query": QUERY, "variables": variables}),
                    )
            except Exception as e:  # noqa: BLE001 - report the original 401 if refresh fails
                print(f"    refresh retry failed: {e}")
        if not res["ok"]:
            if res["status"] in (403, 429):
                raise RuntimeError(
                    f"Costco blocked/rate limited (HTTP {res['status']}); "
                    f"wait before retrying. {res['text'][:300]}"
                )
            raise RuntimeError(f"Costco GraphQL failed: HTTP {res['status']} {res['text'][:500]}")
        b.save_session(ctx)
        return res["json"]


def extract_receipts(payload: Any) -> list[dict]:
    """Return the raw receipt list from the response, handling both known shapes."""
    if not isinstance(payload, dict):
        return []
    node = (payload.get("data") or {}).get("receiptsWithCounts")
    if node is None:
        return []
    if isinstance(node, list):  # some deployments answer with a bare array
        receipts: list[Any] = node
    else:
        receipts = node.get("receipts") or []
    return [r for r in receipts if isinstance(r, dict)]

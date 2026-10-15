"""Kroger purchase history via the internal atlas endpoints."""

from __future__ import annotations

import json
import random
import time
from typing import Any

from . import browser as b

BASE = "https://www.kroger.com"
SEARCH_URL = f"{BASE}/atlas/v1/post-order/v1/purchase-history-search"
DETAILS_URL = f"{BASE}/atlas/v1/purchase-history/v2/details"

LOGGED_IN_JS = "() => !document.querySelector('a[href*=\"signin\"]')"
SEARCH_HEADERS = {"X-Kroger-Channel": "WEB", "Accept": "application/json"}
DETAILS_HEADERS = {
    "Content-Type": "application/json",
    "X-Kroger-Channel": "WEB",
    "Accept": "application/json",
}

RATE_LIMIT_MARKERS = ("too many requests", "rate limit", "try again later", "429", "throttled")

# Fuel/return-only records carry no grocery line items worth itemizing.
GROCERY_TYPES = {
    "IN_STORE",
    "SELF_SERVICE_PICKUP",
    "DELIVERY",
    "INSTACART_DELIVERY",
    "SHIP",
}


def _search_page(page: b.Page, page_no: int) -> dict:
    q = f"?pageNo={page_no}&pageSize=50"
    return b.page_fetch(page, SEARCH_URL + q, headers=SEARCH_HEADERS)


BATCH_SIZE = 10
MAX_ATTEMPTS = 4


def _body_for(keys: list[str]) -> str:
    variables = []
    for k in keys:
        parts = str(k).split("~")
        if len(parts) == 5:
            variables.append(
                {
                    "divisionNumber": parts[0],
                    "storeNumber": parts[1],
                    "transactionDate": parts[2],
                    "terminalNumber": parts[3],
                    "transactionId": parts[4],
                }
            )
    return json.dumps(variables)


def _assert_origin(page: b.Page) -> None:
    """The mypurchases SPA can navigate away mid-run. Re-assert before each request so
    fetches stay same-origin — a cross-origin fetch rejects with 'Failed to fetch'."""
    if "www.kroger.com" not in page.url:
        page.goto(f"{BASE}/mypurchases", wait_until="domcontentloaded")
        page.wait_for_timeout(1500)


def _is_rate_limited(res: dict) -> bool:
    text = (res.get("text") or "").lower()
    return any(m in text for m in RATE_LIMIT_MARKERS)


def _has_details(res: dict) -> bool:
    """True only if the response carries a purchaseHistoryDetails list. A 500 that still
    returns valid JSON (an error envelope) must NOT count as success."""
    j = res.get("json")
    if not isinstance(j, dict):
        return False
    node = (j.get("data") or {}).get("purchaseHistoryDetails")
    return isinstance(node, list)


def pull(
    lookback_days: int,
    cdp: str | None = None,
    skip_keys: set[str] | None = None,
) -> dict:
    """Page the purchase-history search, then fetch itemized details for new receipts."""
    out: dict[str, Any] = {"search": [], "details": {}}
    skip_keys = skip_keys or set()

    with b.browser(cdp=cdp) as ctx:
        page = ctx.pages[0] if ctx.pages else ctx.new_page()
        b.ensure_login(
            page,
            f"{BASE}/mypurchases",
            LOGGED_IN_JS,
            "Log into Kroger.",
        )

        page_no = 1
        while True:
            _assert_origin(page)
            res = _search_page(page, page_no)
            if not res["ok"]:
                raise RuntimeError(f"Kroger search failed: HTTP {res['status']} {res['text'][:500]}")
            body = res["json"] or {}
            node = (body.get("data") or {}).get("postOrderSearch") or {}
            records = node.get("data") or []
            out["search"].extend(records)
            print(f"    search page {page_no}: {len(records)} records")
            if node.get("isLastPage") or not records:
                break
            page_no += 1
            time.sleep(random.uniform(0.6, 1.4))

        keys = [
            r.get("receiptKey")
            for r in out["search"]
            if r.get("receiptKey")
            and r.get("purchaseType") in GROCERY_TYPES
            and str(r.get("receiptKey")) not in skip_keys
        ]
        if skip_keys:
            print(f"    skipping {len(skip_keys)} receipts already itemized")
        batches = [keys[i : i + BATCH_SIZE] for i in range(0, len(keys), BATCH_SIZE)]
        print(f"    itemizing {len(keys)} receipts in {len(batches)} batches")

        for n, batch in enumerate(batches, 1):
            body = _body_for(batch)
            res: dict = {"status": -1, "ok": False, "json": None, "text": ""}
            for attempt in range(MAX_ATTEMPTS):
                _assert_origin(page)
                res = b.page_fetch(
                    page, DETAILS_URL, method="POST", headers=DETAILS_HEADERS, body=body
                )
                if _has_details(res) or _is_rate_limited(res):
                    break
                print(
                    f"    retry {attempt + 1}/{MAX_ATTEMPTS - 1} batch {n} "
                    f"(status={res['status']}) url={page.url}"
                )
                page.goto(f"{BASE}/mypurchases", wait_until="domcontentloaded")
                page.wait_for_timeout(2000 + attempt * 2000)

            for k in batch:
                # store the whole response so failures are diagnosable from the archive
                out["details"][k] = res
            print(f"    details batch {n}/{len(batches)}: {len(batch)} receipts status={res['status']}")

            if not _has_details(res) and _is_rate_limited(res):
                print("    rate-limit signal — stopping detail fetch")
                break
            time.sleep(random.uniform(1.0, 2.5))

    return out


def extract_details(payload: Any) -> list[dict]:
    if not isinstance(payload, dict):
        return []
    node = (payload.get("data") or {}).get("purchaseHistoryDetails")
    if node is None:
        return []
    if isinstance(node, list):
        return [n for n in node if isinstance(n, dict)]
    return [node]

"""Shelf-life resolution.

Primary source is the USDA FoodKeeper dataset (public domain). Where FoodKeeper has a clear
match we take its value; otherwise the LLM supplies an estimate shaped like a FoodKeeper row
(handled in `canonicalize.py`). New sources slot into `resolve()` ahead of the LLM step.

Units matter: FoodKeeper's Min/Max numbers are meaningless without the companion `*_Metric`
column (Days | Weeks | Months | Years | When Ripe | Indefinitely | Not Recommended |
Package use-by date). We convert everything to days and treat qualitative metrics as unknown.
"""

from __future__ import annotations

import json
import sqlite3
from typing import Any

import httpx

from . import config

METRIC_DAYS = {"Days": 1, "Weeks": 7, "Months": 30, "Years": 365}
QUALITATIVE = {"When Ripe", "Indefinitely", "Not Recommended", "Package use-by date"}


def to_days(minv: Any, maxv: Any, metric: Any, prefer: str = "min") -> int | None:
    """Convert a FoodKeeper Min/Max/Metric triple to days. Qualitative metrics -> None."""
    if not metric or metric in QUALITATIVE:
        return None
    mult = METRIC_DAYS.get(str(metric))
    if mult is None:
        return None
    vals = [float(v) for v in (minv, maxv) if isinstance(v, (int, float))]
    if not vals:
        return None
    # Conservative by default: alert on the earliest plausible spoilage.
    base = min(vals) if prefer == "min" else max(vals)
    return max(1, int(round(base * mult)))


def _merge_row(row: list[dict]) -> dict:
    """FoodKeeper rows are a list of single-key dicts: [{"ID":1.0},{"Name":"Butter"},...]."""
    merged: dict[str, Any] = {}
    for cell in row:
        merged.update(cell)
    return merged


def parse_foodkeeper(payload: dict) -> tuple[list[dict], dict[int, str]]:
    sheets = {s.get("name"): s.get("data") or [] for s in payload.get("sheets", [])}
    products = [_merge_row(r) for r in sheets.get("Product", [])]
    categories: dict[int, str] = {}
    for r in sheets.get("Category", []):
        m = _merge_row(r)
        cid = m.get("ID")
        if cid is None:
            continue
        label = m.get("Category_Name") or ""
        if m.get("Subcategory_Name"):
            label = f"{label} / {m['Subcategory_Name']}"
        categories[int(cid)] = label.strip()
    return products, categories


def fetch_foodkeeper(timeout: float = 60.0) -> dict:
    """Try the official host, then byte-identical mirrors (the official host is often blocked)."""
    last_err: Exception | None = None
    for url in [config.FOODKEEPER_URL, *config.FOODKEEPER_MIRRORS]:
        try:
            r = httpx.get(
                url,
                timeout=timeout,
                follow_redirects=True,
                headers={"User-Agent": config.BROWSER_UA, "Accept": "application/json,*/*"},
            )
            if r.status_code == 200:
                return r.json()
            last_err = RuntimeError(f"HTTP {r.status_code} from {url}")
        except Exception as e:  # noqa: BLE001 - try the next source
            last_err = e
    raise RuntimeError(f"could not fetch FoodKeeper from any source: {last_err}")


def load(conn: sqlite3.Connection, payload: dict | None = None) -> int:
    payload = payload or fetch_foodkeeper()
    products, categories = parse_foodkeeper(payload)
    conn.execute("DELETE FROM shelf_life_ref")
    rows = []
    for p in products:
        fid = p.get("ID")
        if fid is None:
            continue
        cat = categories.get(int(p["Category_ID"])) if p.get("Category_ID") is not None else None
        rows.append(
            (
                int(fid),
                p.get("Name"),
                p.get("Name_subtitle"),
                cat,
                p.get("Keywords"),
                to_days(p.get("Pantry_Min"), p.get("Pantry_Max"), p.get("Pantry_Metric")),
                to_days(
                    p.get("DOP_Refrigerate_Min"),
                    p.get("DOP_Refrigerate_Max"),
                    p.get("DOP_Refrigerate_Metric"),
                ),
                to_days(
                    p.get("Refrigerate_After_Opening_Min"),
                    p.get("Refrigerate_After_Opening_Max"),
                    p.get("Refrigerate_After_Opening_Metric"),
                ),
                to_days(
                    p.get("DOP_Freeze_Min"),
                    p.get("DOP_Freeze_Max"),
                    p.get("DOP_Freeze_Metric"),
                ),
                json.dumps(p),
            )
        )
    conn.executemany(
        """INSERT INTO shelf_life_ref
           (foodkeeper_id, name, subtitle, category, keywords, pantry_days,
            dop_refrigerate_days, refrigerate_after_opening_days, dop_freeze_days, raw_json)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
        rows,
    )
    conn.commit()
    return len(rows)


def _tokens(text: str | None) -> set[str]:
    if not text:
        return set()
    out = set()
    for raw in str(text).lower().replace(";", ",").replace("/", " ").split(","):
        for word in raw.split():
            w = word.strip(".,()'\"")
            if len(w) > 2:
                out.add(w)
    return out


def search_candidates(conn: sqlite3.Connection, text: str, limit: int = 8) -> list[dict]:
    """Local, free retrieval: score FoodKeeper rows by keyword/name token overlap.

    The shortlist is handed to the LLM, which picks the right row (or none).
    """
    query = _tokens(text)
    if not query:
        return []
    scored = []
    for row in conn.execute("SELECT * FROM shelf_life_ref"):
        hay = _tokens(row["name"]) | _tokens(row["subtitle"]) | _tokens(row["keywords"])
        score = len(query & hay)
        if score:
            scored.append((score, row))
    scored.sort(key=lambda t: (-t[0], t[1]["foodkeeper_id"]))
    return [dict(r) for _, r in scored[:limit]]


STORAGE_COLUMN = {
    "freezer": "dop_freeze_days",
    "pantry": "pantry_days",
    "fridge": "dop_refrigerate_days",
    "counter": "dop_refrigerate_days",
}


def days_for(
    conn: sqlite3.Connection, foodkeeper_id: int, storage: str = "fridge", opened: bool = False
) -> int | None:
    row = conn.execute(
        "SELECT * FROM shelf_life_ref WHERE foodkeeper_id = ?", (foodkeeper_id,)
    ).fetchone()
    if row is None:
        return None
    if opened and row["refrigerate_after_opening_days"]:
        return row["refrigerate_after_opening_days"]
    col = STORAGE_COLUMN.get(storage, "dop_refrigerate_days")
    return row[col]

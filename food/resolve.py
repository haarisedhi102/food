"""Batched shelf-life resolution.

Replaces the id-only FoodKeeper rerank *and* the separate missing-shelf-life agent pass with
one agent run per batch. Each item arrives with its FoodKeeper candidate shortlist (hybrid
retrieval), every candidate enriched with the shelf-life figures that matter for storage. The
agent returns, per item, the shelf life to use and where it came from:

  foodkeeper  the picked FoodKeeper row fits (its id is kept for provenance)
  web         nothing in FoodKeeper fit; found via `web_search`
  llm         answered from its own knowledge

One run per batch keeps the fast path batched; `web_search` is used only for the items
FoodKeeper cannot answer.
"""

from __future__ import annotations

import json
import sqlite3
from typing import Any, Literal

from langchain.agents import create_agent
from langchain_core.tools import tool
from pydantic import BaseModel, Field

from . import embeddings, llm, reference

SYSTEM = """You resolve how long grocery items keep. You receive several items at once, and
for each a shortlist of FoodKeeper reference rows with their shelf-life figures in days
(pantry, refrigerate, freezer, after opening).

For EVERY item return exactly one entry:
- Prefer a FoodKeeper row. If a candidate is the same food, set source="foodkeeper",
  foodkeeper_id to its id, and shelf_life_days to that row's figure for the item's storage
  (counter/fridge -> refrigerate_days, freezer -> freezer_days, otherwise pantry_days; use
  after_opening_days when that is the figure that applies). Leave storage null to keep the
  item's current storage.
- FoodKeeper rows can be sparse or odd — e.g. a milk row with only a freezer figure and no
  refrigerated days. If a candidate only loosely fits, or its figures don't make sense for
  the item, treat it as NOT fitting and fall through to web/llm.
- If NONE of the candidates is really the same food, do NOT force a pick — a wrong match is
  worse than none. Use the web_search tool and set source="web" with shelf_life_days.
- If you are already confident, answer from your own knowledge with source="llm" and
  shelf_life_days.

shelf_life_days is whole days and is required whenever the item is perishable, including
FoodKeeper picks. Non-perishable items (dry goods, canned, spices) are is_perishable=false
with shelf_life_days null. Echo each item's name exactly in `item`."""


class ItemVerdict(BaseModel):
    """One item's resolved shelf life."""

    item: str
    source: Literal["foodkeeper", "web", "llm"] = "llm"
    foodkeeper_id: int | None = None
    shelf_life_days: int | None = None
    shelf_life_days_opened: int | None = None
    storage: str | None = None
    is_perishable: bool = True
    confidence: float = Field(default=0.5, ge=0.0, le=1.0)


class BatchVerdict(BaseModel):
    items: list[ItemVerdict]


@tool
def web_search(query: str) -> str:
    """Search the web for grocery storage and shelf-life guidance."""
    from ddgs import DDGS

    try:
        results = DDGS().text(query, max_results=5)
    except Exception as e:  # noqa: BLE001 - the agent should see the failure and adapt
        return f"search failed: {e}"
    return (
        "\n\n".join(f"{r.get('title')}\n{r.get('href')}\n{r.get('body')}" for r in results)
        or "no results"
    )


def _agent():
    """Build the batched tool-calling agent. Kept small so tests can substitute it."""
    return create_agent(
        llm.chat_model(),
        tools=[web_search],
        system_prompt=SYSTEM,
        response_format=BatchVerdict,
    )


def _candidate(row: dict) -> dict:
    return {
        "foodkeeper_id": row["foodkeeper_id"],
        "name": row["name"],
        "subtitle": row.get("subtitle"),
        "pantry_days": row.get("pantry_days"),
        "refrigerate_days": row.get("dop_refrigerate_days"),
        "freezer_days": row.get("dop_freeze_days"),
        "after_opening_days": row.get("refrigerate_after_opening_days"),
    }


def _shortlists(
    conn: sqlite3.Connection, items: list[dict], model: str | None, topn: int
) -> dict[str, list[dict]]:
    names = [it["name"] for it in items]
    retriever = reference.build_retriever(
        conn, model, limit=topn, query_vectors=reference._query_vectors(conn, model, names)
    )
    return {
        it["name"]: [_candidate(c) for c in reference.search_with(conn, retriever, it["name"], topn)]
        for it in items
    }


def resolve_batch(
    conn: sqlite3.Connection,
    items: list[dict],
    model: str | None = None,
    topn: int = 5,
) -> dict[str, ItemVerdict]:
    """Resolve shelf lives for a batch of items in a single agent run.

    `items` are {"id", "name", "category", "storage"} dicts. Returns {name: ItemVerdict}; any
    `foodkeeper_id` is validated against that item's shortlist (a hallucinated id downgrades
    to the model's own answer).
    """
    items = [it for it in items if it.get("name")]
    if not items:
        return {}
    model = model or embeddings.model_name()
    shortlists = _shortlists(conn, items, model, topn)
    payload = [
        {
            "item": it["name"],
            "category": it.get("category"),
            "storage": it.get("storage"),
            "candidates": shortlists.get(it["name"], []),
        }
        for it in items
    ]
    try:
        result: dict[str, Any] = _agent().invoke(
            {"messages": [("user", json.dumps({"items": payload}, ensure_ascii=False))]}
        )
    except Exception as e:  # noqa: BLE001 - a resolver failure must not abort classification
        print(f"    shelf-life resolver failed: {e}")
        return {}
    verdict: BatchVerdict | None = result.get("structured_response")

    out: dict[str, ItemVerdict] = {}
    for v in getattr(verdict, "items", None) or []:
        ids = {c["foodkeeper_id"] for c in shortlists.get(v.item, [])}
        if v.source == "foodkeeper" and v.foodkeeper_id not in ids:
            v = v.model_copy(update={"foodkeeper_id": None, "source": "llm"})
        out[v.item] = v
    return out


def apply(conn: sqlite3.Connection, items: list[dict], verdicts: dict[str, ItemVerdict]) -> int:
    """Write resolved shelf lives back to products, re-expirying any built inventory rows."""
    by_name = {it["name"]: it for it in items}
    applied = 0
    for name, v in verdicts.items():
        it = by_name.get(name)
        if it is None:
            continue
        days = v.shelf_life_days
        conn.execute(
            """UPDATE products
               SET shelf_life_days = ?, shelf_life_days_opened = ?,
                   storage = COALESCE(?, storage), is_perishable = ?,
                   shelf_life_source = ?, foodkeeper_id = ?, llm_confidence = ?
               WHERE id = ?""",
            (
                days,
                v.shelf_life_days_opened,
                v.storage,
                int(v.is_perishable),
                v.source,
                v.foodkeeper_id if v.source == "foodkeeper" else None,
                v.confidence,
                it["id"],
            ),
        )
        if v.is_perishable and days:
            conn.execute(
                """UPDATE inventory SET expires_on = date(acquired_on, '+' || ? || ' days')
                   WHERE product_id = ? AND status IN ('active', 'partial')""",
                (days, it["id"]),
            )
        else:
            conn.execute(
                "UPDATE inventory SET expires_on = NULL WHERE product_id = ?", (it["id"],)
            )
        applied += 1
    conn.commit()
    return applied

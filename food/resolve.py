"""Batched shelf-life resolution.

Two phases per chunk of items:

1. **Research** — a tool-calling agent receives each item with its FoodKeeper candidate
   shortlist (hybrid retrieval, each candidate enriched with its shelf-life figures) and uses
   `web_search` only where no row fits. It returns prose notes.
2. **Synthesis** — a forced structured-output call (`with_structured_output`) turns those notes
   into one verdict per item. The schema is the only tool bound, so the model cannot answer in
   prose — that is what guarantees we get structured output back.

Verdicts are keyed by product id (not name), missing items are re-asked once, and a
`foodkeeper` verdict takes its number from the validated row rather than the model. Each
verdict carries its source:

  foodkeeper  the picked FoodKeeper row fits (its id is kept for provenance)
  web         nothing in FoodKeeper fit; found via web_search
  llm         answered from its own knowledge

One run per `RESOLVE_CHUNK`, so the fast path stays batched; web_search is used only for the
items FoodKeeper cannot answer.
"""

from __future__ import annotations

import json
import sqlite3
import time
from typing import Any, Callable, Literal, TypeVar

from langchain.agents import create_agent
from langchain_core.tools import tool
from pydantic import BaseModel, Field

from . import embeddings, llm, reference

RESOLVE_CHUNK = 8  # items per agent run — keep each request small for the upstream model
ATTEMPTS = 3  # retries per phase for a transient provider error (e.g. HTTP 524)

T = TypeVar("T")

RESEARCH_SYSTEM = """You research how long grocery items keep. You receive several items at
once, and for each a shortlist of FoodKeeper reference rows with their shelf-life figures in
days (pantry, refrigerate, freezer, after opening).

For each item decide the shelf life to use and where it comes from:
- a FoodKeeper row, when a candidate is genuinely the same food and its figures make sense.
  FoodKeeper rows can be sparse or odd (e.g. a milk row with only a freezer figure and no
  refrigerated days) — if a candidate only loosely fits, do not use it;
- the web_search tool, when no row fits — search authoritative guidance (USDA/FoodKeeper,
  food-safety agencies, manufacturers);
- your own knowledge, when you are already confident.

Then write a short note per item, quoting its id: the shelf life in days, the source (a
FoodKeeper id, the web, or your own knowledge), and the storage it applies to. Do NOT return
JSON — just notes."""

SYNTH_SYSTEM = """You convert grocery shelf-life research notes into one structured verdict per
item. Return one entry per item, echoing that item's `id` in `item_id`. For each:
- source: "foodkeeper" if a FoodKeeper row was used, else "web" or "llm";
- foodkeeper_id: that row's id when source is foodkeeper, else null;
- shelf_life_days: YOUR best shelf life in whole days. Treat FoodKeeper as a slightly preferred
  source, not the authority — its figures can be unrealistic (a row listing only a 3-month
  freezer figure does not mean 90 days of fridge life). Use judgement; null only when the item
  is non-perishable;
- is_perishable: false for dry goods, canned, spices."""


class ItemVerdict(BaseModel):
    """One item's resolved shelf life."""

    item_id: int = Field(description="the item's id, echoed exactly")
    source: Literal["foodkeeper", "web", "llm"] = "llm"
    foodkeeper_id: int | None = Field(
        default=None, description="the FoodKeeper row id, when source is foodkeeper"
    )
    shelf_life_days: int | None = Field(
        default=None, description="whole days; null when the item is non-perishable"
    )
    shelf_life_days_opened: int | None = None
    storage: str | None = Field(
        default=None, description="fridge | freezer | pantry | counter"
    )
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


def _research_agent():
    """Phase 1: a tool-calling agent that gathers, but is not asked for structured output."""
    return create_agent(llm.chat_model(), tools=[web_search], system_prompt=RESEARCH_SYSTEM)


def _structured():
    """Phase 2: structured output with the schema as the only (forced) tool.

    The Command Code provider does not honour native `json_schema` response format, so we force
    a function call instead — the schema tool is the only option, so the model cannot reply in
    prose.
    """
    return llm.chat_model().with_structured_output(BatchVerdict, method="function_calling")


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
) -> dict[int, list[dict]]:
    """FoodKeeper candidates per item, keyed by product id."""
    names = [it["name"] for it in items]
    retriever = reference.build_retriever(
        conn, model, limit=topn, query_vectors=reference._query_vectors(conn, model, names)
    )
    return {
        it["id"]: [_candidate(c) for c in reference.search_with(conn, retriever, it["name"], topn)]
        for it in items
    }


def _payload(items: list[dict], shortlists: dict[int, list[dict]]) -> list[dict]:
    return [
        {
            "id": it["id"],
            "item": it["name"],
            "category": it.get("category"),
            "storage": it.get("storage"),
            "candidates": shortlists.get(it["id"], []),
        }
        for it in items
    ]


def resolve_batch(
    conn: sqlite3.Connection,
    items: list[dict],
    model: str | None = None,
    topn: int = 5,
) -> dict[int, ItemVerdict]:
    """Resolve shelf lives for a batch of items, one run per `RESOLVE_CHUNK`.

    `items` are {"id", "name", "category", "storage"} dicts. Returns {id: ItemVerdict}; any
    `foodkeeper_id` is validated against that item's shortlist (a hallucinated id downgrades to
    the model's own answer). Chunking keeps each request small; each phase is retried on a
    transient error, and any item missing from a chunk's verdicts is re-asked once.
    """
    items = [it for it in items if it.get("name") and it.get("id") is not None]
    if not items:
        return {}
    model = model or embeddings.model_name()
    shortlists = _shortlists(conn, items, model, topn)

    out: dict[int, ItemVerdict] = {}
    for start in range(0, len(items), RESOLVE_CHUNK):
        out.update(_resolve_chunk(items[start : start + RESOLVE_CHUNK], shortlists))
    return out


def _resolve_chunk(
    chunk: list[dict], shortlists: dict[int, list[dict]]
) -> dict[int, ItemVerdict]:
    payload = _payload(chunk, shortlists)

    findings = _retry(lambda: _research(payload), "research", len(chunk))
    verdict = None if findings is None else _retry(
        lambda: _synthesize(payload, findings), "synthesis", len(chunk)
    )
    if verdict is None:
        return {}

    out = _collect(verdict, chunk, shortlists)

    # completeness: re-ask once for anything the model omitted
    missing = [it for it in chunk if it["id"] not in out]
    if missing:
        retry = _retry(
            lambda: _synthesize(_payload(missing, shortlists), findings),
            "synthesis (missing)",
            len(missing),
        )
        if retry is not None:
            out.update(_collect(retry, missing, shortlists))
    return out


def _collect(
    verdict: BatchVerdict, items: list[dict], shortlists: dict[int, list[dict]]
) -> dict[int, ItemVerdict]:
    """Index a verdict by id, dropping unknown ids and mistrusted FoodKeeper ids."""
    wanted = {it["id"] for it in items}
    out: dict[int, ItemVerdict] = {}
    for v in verdict.items:
        if v.item_id not in wanted:
            continue
        ids = {c["foodkeeper_id"] for c in shortlists.get(v.item_id, [])}
        if v.source == "foodkeeper" and v.foodkeeper_id not in ids:
            v = v.model_copy(update={"foodkeeper_id": None, "source": "llm"})
        out[v.item_id] = v
    return out


def _retry(fn: Callable[[], T], phase: str, count: int) -> T | None:
    """Run `fn`, retrying a few times on a transient provider error."""
    for attempt in range(ATTEMPTS):
        try:
            return fn()
        except Exception as e:  # noqa: BLE001 - transient upstream error, retry
            last = e
            time.sleep(1.5 * (attempt + 1))
    print(f"    shelf-life {phase} failed ({count} items): {last}")
    return None


def _research(payload: list[dict]) -> str:
    """Phase 1: gather. Returns the agent's final notes as text."""
    result: dict[str, Any] = _research_agent().invoke(
        {"messages": [("user", json.dumps({"items": payload}, ensure_ascii=False))]}
    )
    messages = result.get("messages") or []
    return str(getattr(messages[-1], "content", "") or "") if messages else ""


def _synthesize(payload: list[dict], findings: str) -> BatchVerdict | None:
    """Phase 2: force the structured verdict from the items, candidates and notes."""
    user = json.dumps({"items": payload, "research_notes": findings}, ensure_ascii=False)
    result = _structured().invoke([("system", SYNTH_SYSTEM), ("user", user)])
    return result if isinstance(result, BatchVerdict) else None


def apply(conn: sqlite3.Connection, items: list[dict], verdicts: dict[int, ItemVerdict]) -> int:
    """Write resolved shelf lives back to products, re-expirying any built inventory rows."""
    by_id = {it["id"]: it for it in items}
    applied = 0
    for pid, v in verdicts.items():
        it = by_id.get(pid)
        if it is None:
            continue
        fid = v.foodkeeper_id if v.source == "foodkeeper" else None
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
                fid,
                v.confidence,
                pid,
            ),
        )
        if days:
            conn.execute(
                """UPDATE inventory SET expires_on = date(acquired_on, '+' || ? || ' days')
                   WHERE product_id = ? AND status IN ('active', 'partial')""",
                (days, pid),
            )
        elif not v.is_perishable:
            # only a known non-perishable clears expiry; an unknown keeps what it had
            conn.execute("UPDATE inventory SET expires_on = NULL WHERE product_id = ?", (pid,))
        applied += 1
    conn.commit()
    return applied

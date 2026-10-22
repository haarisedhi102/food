"""Batched shelf-life resolution.

Two phases per chunk of items:

1. **Research** — a tool-calling agent receives each item with its FoodKeeper candidate
   shortlist (hybrid retrieval, each candidate enriched with its shelf-life figures) and uses
   `web_search` only where no row fits. It returns prose notes.
2. **Synthesis** — a forced tool call (the verdict schema bound as the only tool, with
   `tool_choice="required"`) turns those notes into one verdict per item. We accept only a
   tool call — never prose — and re-ask if the model doesn't produce one.

Verdicts are keyed by product id (not name), and any item a chunk omits is re-asked once. Each
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
from concurrent.futures import ThreadPoolExecutor
from typing import Any, Callable, Literal, TypeVar

from langchain.agents import create_agent
from langchain_core.tools import tool
from pydantic import BaseModel, Field, ValidationError

from . import config, db, embeddings, jev, llm, reference

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

Then write a short note per item, quoting its id: the shelf life in days, the source (the
FoodKeeper row used, the web, or your own knowledge), and the storage it applies to. Do NOT
return JSON — just notes."""

SYNTH_SYSTEM = """You convert grocery shelf-life research notes into one structured verdict per
item. Return one entry per item, echoing that item's `id` in `item_id`. For each:
- source: "foodkeeper" if a FoodKeeper row was used, else "web" or "llm";
- shelf_life_days: YOUR best shelf life in whole days. Treat FoodKeeper as a slightly preferred
  source, not the authority — its figures can be unrealistic (a row listing only a 3-month
  freezer figure does not mean 90 days of fridge life). Use judgement; null only when the item
  is non-perishable;
- is_perishable: false for dry goods, canned, spices.

Examples (item id, name, storage -> verdict):
  12 "Whole Milk", fridge          -> {"item_id": 12, "source": "foodkeeper", "shelf_life_days": 7, "is_perishable": true}
  30 "Jasmine Rice", pantry        -> {"item_id": 30, "source": "foodkeeper", "shelf_life_days": null, "is_perishable": false}
  41 "Unsweetened Oatmilk", fridge -> {"item_id": 41, "source": "web", "shelf_life_days": 7, "is_perishable": true}
  55 "Roma Tomato", counter        -> {"item_id": 55, "source": "llm", "shelf_life_days": 7, "is_perishable": true}"""


class ItemVerdict(BaseModel):
    """One item's resolved shelf life."""

    item_id: int = Field(description="the item's id, echoed exactly")
    source: Literal["foodkeeper", "web", "llm", "jev"] = "llm"
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


VERDICT_TOOL = {
    "type": "function",
    "function": {
        "name": "shelf_life_verdicts",
        "description": "Return one shelf-life verdict per item.",
        "parameters": {
            "type": "object",
            "properties": {
                "items": {
                    "type": "array",
                    "items": {
                        "type": "object",
                        "properties": {
                            "item_id": {"type": "integer"},
                            "source": {
                                "type": "string",
                                "enum": ["foodkeeper", "web", "llm"],
                            },
                            "shelf_life_days": {"type": ["integer", "null"]},
                            "shelf_life_days_opened": {"type": ["integer", "null"]},
                            "storage": {"type": ["string", "null"]},
                            "is_perishable": {"type": "boolean"},
                            "confidence": {"type": "number"},
                        },
                        "required": [
                            "item_id",
                            "source",
                            "shelf_life_days",
                            "is_perishable",
                        ],
                    },
                }
            },
            "required": ["items"],
        },
    },
}


def _structured():
    """Phase 2: an explicit named tool forced by name.

    A raw `bind_tools([BatchVerdict], tool_choice="required")` leaves the provider free to
    choose the tool name and occasionally answer in prose. The explicit schema + named
    tool_choice was materially more reliable in the live comparison; prose is still never
    accepted.
    """
    return llm.chat_model().bind_tools(
        [VERDICT_TOOL],
        tool_choice={
            "type": "function",
            "function": {"name": "shelf_life_verdicts"},
        },
    )


def _candidate(row: dict) -> dict:
    return {
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


JEV_DAYS = {
    "d0": 0,
    "d1_2": 2,
    "d3_4": 4,
    "d5_7": 7,
    "d8_14": 14,
    "d15_30": 30,
    "d31_90": 90,
    "d91_180": 180,
    "d181_365": 365,
}
JEV_DAY_CRITERIA = {
    "d0": "0 days (use today; already spoiled)",
    "d1_2": "1-2 days (fresh fish, cut fruit, leftovers)",
    "d3_4": "3-4 days (fresh bread, cooked rice, open deli meat)",
    "d5_7": "5-7 days (fluid milk, yogurt, bananas on the counter)",
    "d8_14": "8-14 days (bell peppers, tomatoes, opened cheese)",
    "d15_30": "15-30 days (eggs, hard cheese, apples)",
    "d31_90": "31-90 days (root vegetables, winter squash, unopened juice)",
    "d91_180": "91-180 days (frozen meat, unopened shelf-stable items)",
    "d181_365": "181-365 days (canned goods, dry staples)",
    "d365p": "more than 365 days, or non-perishable",
}
JEV_RANGES = {
    "d0": (0, 0),
    "d1_2": (1, 2),
    "d3_4": (3, 4),
    "d5_7": (5, 7),
    "d8_14": (8, 14),
    "d15_30": (15, 30),
    "d31_90": (31, 90),
    "d91_180": (91, 180),
    "d181_365": (181, 365),
}
JEV_STORAGE_CRITERIA = {
    "fridge": "Refrigerated.",
    "freezer": "Frozen.",
    "pantry": "Shelf-stable, dry, or canned.",
    "counter": "Room-temperature counter, such as fresh produce or bread.",
}


def _jev_questions(
    chunk: list[dict], shortlists: dict[int, list[dict]]
) -> dict[str, Any]:
    questions: dict[str, Any] = {}
    for it in chunk:
        iid, name = it["id"], it["name"]
        items = shortlists.get(iid, [])
        questions[f"item_{iid}_perishable"] = {
            "type": "noul",
            "instructions": (
                f"Is item {iid} ({name}, category {it.get('category') or 'unknown'}, "
                f"stored {it.get('storage') or 'unknown'}) perishable and likely to expire? "
                "Use the research notes in state."
            ),
        }
        questions[f"item_{iid}_storage"] = {
            "type": "choice",
            "instructions": f"What is the correct storage location for item {iid} ({name})?",
            "criteria": JEV_STORAGE_CRITERIA,
        }
        questions[f"item_{iid}_days"] = {
            "type": "choice",
            "instructions": (
                f"How long does item {iid} ({name}, category {it.get('category') or 'unknown'}, "
                f"stored {it.get('storage') or 'unknown'}) keep before it should be used? "
                "Use the research notes and FoodKeeper candidates in state. "
                "Calibration examples: fluid milk in the fridge -> 5-7 days; fresh bread -> "
                "3-4 days; eggs in the fridge -> 15-30 days; bananas on the counter -> "
                "5-7 days. Do not put fluid milk in 31-90 days."
            ),
            "criteria": JEV_DAY_CRITERIA,
        }
        criteria = {
            f"c{i}": (
                f"{c['name']} — {c['subtitle']}" if c.get("subtitle") else (c.get("name") or "")
            )
            for i, c in enumerate(items)
        }
        criteria["none"] = "No listed FoodKeeper row is the same food."
        questions[f"item_{iid}_candidate"] = {
            "type": "choice",
            "instructions": (
                f"Which FoodKeeper row is genuinely the same food as item {iid} ({name})? "
                "Pick none when no row fits."
            ),
            "criteria": criteria,
        }
    return questions


def _candidate_days(candidate: dict, storage: str) -> int | None:
    key = {
        "fridge": "refrigerate_days",
        "freezer": "freezer_days",
        "pantry": "pantry_days",
        "counter": "pantry_days",
    }.get(storage or "pantry", "pantry_days")
    value = candidate.get(key)
    return int(value) if value is not None else None


def _jev_verdicts(
    chunk: list[dict], shortlists: dict[int, list[dict]], findings: str
) -> tuple[dict[int, ItemVerdict], dict[str, Any] | None]:
    """Jev's terminal synthesis over the research notes.

    Every answered item gets a verdict; confidence is stored on the product for review.
    There is no second synthesis model after Jev.
    """
    if not chunk or not jev.is_configured():
        return {}, None
    payload = _payload(chunk, shortlists)
    try:
        data = jev.decide(
            {"items": payload, "research_notes": findings},
            _jev_questions(chunk, shortlists),
        )
    except Exception as e:  # noqa: BLE001 - leave items pending for the next sync
        print(f"    Jev unavailable; leaving items for the next sync: {e}")
        return {}, None

    answers = data.get("answers") or {}
    out: dict[int, ItemVerdict] = {}
    for it in chunk:
        iid = it["id"]
        try:
            per_answer = answers[f"item_{iid}_perishable"]
            storage_answer = answers[f"item_{iid}_storage"]
            days_answer = answers[f"item_{iid}_days"]
        except KeyError:
            continue

        perish_prob = float(per_answer.get("noul") or 0.0)
        is_perishable = perish_prob >= 0.5
        perish_conf = max(perish_prob, 1.0 - perish_prob)

        storage = storage_answer.get("choice")
        storage_conf = float(storage_answer.get("confidence") or 0.0)
        if storage not in JEV_STORAGE_CRITERIA:
            storage = it.get("storage") or "pantry"
            storage_conf = 0.0

        if not is_perishable:
            out[iid] = ItemVerdict(
                item_id=iid,
                source="jev",
                shelf_life_days=None,
                storage=storage,
                is_perishable=False,
                confidence=min(perish_conf, storage_conf),
            )
            continue

        days_choice = days_answer.get("choice")
        days_conf = float(days_answer.get("confidence") or 0.0)

        candidates = shortlists.get(iid, [])
        cand_answer = answers.get(f"item_{iid}_candidate") or {}
        cand_conf = float(cand_answer.get("confidence") or 0.0)
        chosen = cand_answer.get("choice")
        chosen_candidate = None
        if chosen and chosen != "none" and chosen.startswith("c"):
            try:
                chosen_candidate = candidates[int(chosen[1:])]
            except (ValueError, IndexError):
                chosen_candidate = None

        candidate_days = (
            _candidate_days(chosen_candidate, storage) if chosen_candidate else None
        )
        bucket = JEV_RANGES.get(days_choice)
        agrees = (
            bucket is not None
            and candidate_days is not None
            and bucket[0] <= candidate_days <= bucket[1]
        )
        # Jev is the terminal decision. Prefer its FoodKeeper row when the row has an
        # exact day for this storage; otherwise use its day bucket. Low confidence is
        # recorded on the product for review rather than triggering another model call.
        if candidate_days is not None and (cand_conf >= 0.5 or agrees):
            out[iid] = ItemVerdict(
                item_id=iid,
                source="foodkeeper",
                shelf_life_days=int(candidate_days),
                shelf_life_days_opened=chosen_candidate.get("after_opening_days"),
                storage=storage,
                is_perishable=True,
                confidence=min(perish_conf, storage_conf, cand_conf or 0.5),
            )
            continue

        wide = bucket is not None and (bucket[1] - bucket[0]) > 7
        if days_conf < 0.5 or (wide and days_conf < 0.8):
            # A low-confidence wide bucket can badly overestimate shelf life (e.g. milk
            # in 31-90 days). Leave it unknown rather than record a risky number.
            shelf_life_days = None
        elif days_choice == "d365p":
            shelf_life_days = 365
        elif days_choice in JEV_DAYS:
            shelf_life_days = JEV_DAYS[days_choice]
        else:
            shelf_life_days = None
        out[iid] = ItemVerdict(
            item_id=iid,
            source="jev",
            shelf_life_days=shelf_life_days,
            storage=storage,
            is_perishable=True,
            confidence=min(perish_conf, storage_conf, days_conf),
        )

    usage = data.get("usage")
    if usage is not None:
        usage = {**usage, "model": data.get("model") or config.JEV_MODEL}
    return out, usage


def _log_jev_usage(conn: sqlite3.Connection, usage: dict[str, Any] | None) -> None:
    if not usage:
        return
    try:
        conn.execute(
            """INSERT INTO llm_calls (purpose, model, prompt_tokens, completion_tokens)
               VALUES (?, ?, ?, ?)""",
            (
                "resolve_jev",
                usage.get("model") or config.JEV_MODEL,
                usage.get("input_tokens"),
                usage.get("output_tokens"),
            ),
        )
        conn.commit()
    except sqlite3.Error as e:
        print(f"    could not record Jev usage: {e}")


def resolve_batch(
    conn: sqlite3.Connection,
    items: list[dict],
    model: str | None = None,
    topn: int = 5,
    workers: int | None = None,
) -> dict[int, ItemVerdict]:
    """Resolve shelf lives for a batch of items, one run per `RESOLVE_CHUNK`.

    Research always runs and produces the grounded notes. Jev is the terminal synthesis.
    The LLM synthesizer is used only when Jev is not configured at all.
    """
    items = [it for it in items if it.get("name") and it.get("id") is not None]
    if not items:
        return {}
    model = model or embeddings.model_name()
    shortlists = _shortlists(conn, items, model, topn)
    chunks = [
        items[i : i + RESOLVE_CHUNK] for i in range(0, len(items), RESOLVE_CHUNK)
    ]
    workers = workers or config.RESOLVE_WORKERS

    def task(chunk: list[dict]) -> tuple[dict[int, ItemVerdict], dict | None]:
        payload = _payload(chunk, shortlists)
        findings = _retry(lambda: _research(payload), "research", len(chunk))
        if findings is None:
            return {}, None

        if jev.is_configured():
            # Jev is the terminal synthesis. Do not call another model after it; low
            # confidence is stored for review, and a Jev failure leaves the items for
            # the next sync rather than spending another synthesis call.
            return _jev_verdicts(chunk, shortlists, findings)
        return _llm_synthesize(chunk, shortlists, findings), None

    if workers <= 1 or len(chunks) <= 1:
        results = [task(c) for c in chunks]
    else:
        with ThreadPoolExecutor(max_workers=min(workers, len(chunks))) as pool:
            results = list(pool.map(task, chunks))

    out: dict[int, ItemVerdict] = {}
    for verdicts, usage in results:
        out.update(verdicts)
        _log_jev_usage(conn, usage)
    return out


def _llm_synthesize(
    chunk: list[dict], shortlists: dict[int, list[dict]], findings: str
) -> dict[int, ItemVerdict]:
    """LLM synthesis fallback used only when Jev is disabled."""
    if not chunk:
        return {}
    payload = _payload(chunk, shortlists)
    verdict = _retry(lambda: _synthesize(payload, findings), "synthesis", len(chunk))
    if verdict is None:
        return {}

    out = _collect(verdict, chunk)

    # completeness: re-ask once for anything the model omitted
    missing = [it for it in chunk if it["id"] not in out]
    if missing:
        retry = _retry(
            lambda: _synthesize(_payload(missing, shortlists), findings),
            "synthesis (missing)",
            len(missing),
        )
        if retry is not None:
            out.update(_collect(retry, missing))
    return out


def _collect(verdict: BatchVerdict, items: list[dict]) -> dict[int, ItemVerdict]:
    """Index a verdict by id, dropping any id that isn't in the chunk."""
    wanted = {it["id"] for it in items}
    return {v.item_id: v for v in verdict.items if v.item_id in wanted}


def _retry(fn: Callable[[], T], phase: str, count: int) -> T | None:
    """Run `fn`, retrying a few times on a transient error *or* when it yields nothing."""
    last: object = "no result"
    for attempt in range(ATTEMPTS):
        try:
            result = fn()
            if result is not None:
                return result
        except Exception as e:  # noqa: BLE001 - transient upstream error, retry
            if llm.is_rate_limit_error(e):
                wait = llm.retry_after_seconds(e)
                suffix = f" (retry-after {wait:g}s)" if wait is not None else ""
                print(
                    f"    shelf-life {phase} rate limited ({count} items){suffix}; "
                    "not retrying"
                )
                return None
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
    """Phase 2: get the structured verdict by tool call only; None triggers a retry."""
    user = json.dumps({"items": payload, "research_notes": findings}, ensure_ascii=False)
    messages = [("system", SYNTH_SYSTEM), ("user", user)]
    chain = _structured()
    result = chain.invoke(messages)
    calls = getattr(result, "tool_calls", None) or []

    if not calls:
        # One corrective retry: show the model what it wrote and require the named tool.
        messages = [
            *messages,
            ("assistant", getattr(result, "content", "") or ""),
            (
                "user",
                "You must call the shelf_life_verdicts tool now. "
                "Return one verdict per item and do not answer in prose.",
            ),
        ]
        result = chain.invoke(messages)
        calls = getattr(result, "tool_calls", None) or []

    if not calls:
        return None
    call = next(
        (c for c in calls if c.get("name") == "shelf_life_verdicts"), calls[0]
    )
    try:
        return BatchVerdict(**call["args"])
    except (ValidationError, TypeError):
        return None


def apply(conn: sqlite3.Connection, items: list[dict], verdicts: dict[int, ItemVerdict]) -> int:
    """Write resolved shelf lives back to products, re-expirying any built inventory rows."""
    by_id = {it["id"]: it for it in items}
    applied = 0
    for pid, v in verdicts.items():
        it = by_id.get(pid)
        if it is None:
            continue
        days = v.shelf_life_days
        conn.execute(
            """UPDATE products
               SET shelf_life_days = ?, shelf_life_days_opened = ?,
                   storage = COALESCE(?, storage), is_perishable = ?,
                   shelf_life_source = ?, llm_confidence = ?
               WHERE id = ?""",
            (
                days,
                v.shelf_life_days_opened,
                v.storage,
                int(v.is_perishable),
                v.source,
                v.confidence,
                pid,
            ),
        )
        if days is not None:
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

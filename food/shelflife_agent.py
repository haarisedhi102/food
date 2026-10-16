"""Resolve low-confidence shelf life with a web-search agent.

Canonicalization grounds most items in FoodKeeper or a confident LLM estimate. When it is
unsure — low confidence, or a perishable with no known shelf life — parking the item in the
review queue leaves the fridge incomplete. Instead a LangChain tool-calling agent searches
the web for how long the item keeps and returns a structured answer, which is written back
to the product (and to any inventory rows already built from it).
"""

from __future__ import annotations

import sqlite3
from typing import Any

from langchain.agents import create_agent
from langchain_core.tools import tool
from pydantic import BaseModel, Field

from . import config, llm

SYSTEM = """You determine how long a grocery item keeps after purchase, and where it should be stored.
Answer from your own knowledge when you are confident. Use the web_search tool only when you need
to — an unusual or ambiguous item, an abbreviated receipt line, or guidance you might be
misremembering. If you do search, prefer authoritative sources (USDA/FoodKeeper, food-safety
agencies, manufacturers) over blogs. Express shelf life in whole days. If the item does not spoil
(dry goods, canned, spices), set is_perishable false and shelf_life_days null. Set confidence to
reflect how sure you are of the final answer."""


class ShelfLifeGuess(BaseModel):
    """Structured verdict from the shelf-life agent."""

    is_perishable: bool = True
    storage: str | None = Field(default=None, description="fridge | freezer | pantry | counter")
    shelf_life_days: int | None = Field(default=None, description="days from purchase")
    shelf_life_days_opened: int | None = None
    confidence: float = Field(default=0.5, ge=0.0, le=1.0)
    rationale: str | None = None


@tool
def web_search(query: str) -> str:
    """Search the web for grocery storage and shelf-life guidance."""
    from ddgs import DDGS

    try:
        results = DDGS().text(query, max_results=5)
    except Exception as e:  # noqa: BLE001 - the agent should see the failure and adapt
        return f"search failed: {e}"
    return (
        "\n\n".join(
            f"{r.get('title')}\n{r.get('href')}\n{r.get('body')}"
            for r in results
        )
        or "no results"
    )


def _agent():
    """Build the tool-calling agent. Kept small so tests can substitute it."""
    return create_agent(
        llm.chat_model(),
        tools=[web_search],
        system_prompt=SYSTEM,
        response_format=ShelfLifeGuess,
    )


def resolve(
    name: str, description: str | None = None, category: str | None = None
) -> ShelfLifeGuess | None:
    """Ask the agent how long `name` keeps. Returns None if it produced no verdict."""
    prompt = (
        f"Item: {name}\n"
        f"Receipt text: {description or '(none)'}\n"
        f"Category: {category or '(unknown)'}\n"
        "How long does this keep, and where should it be stored?"
    )
    result: dict[str, Any] = _agent().invoke({"messages": [("user", prompt)]})
    return result.get("structured_response")


def _apply(conn: sqlite3.Connection, product_id: int, guess: ShelfLifeGuess) -> None:
    conn.execute(
        """UPDATE products
           SET shelf_life_days = ?, shelf_life_days_opened = ?,
               storage = COALESCE(?, storage), is_perishable = ?,
               shelf_life_source = 'web', review_state = 'ok', llm_confidence = ?
           WHERE id = ?""",
        (
            guess.shelf_life_days,
            guess.shelf_life_days_opened,
            guess.storage,
            int(guess.is_perishable),
            guess.confidence,
            product_id,
        ),
    )
    # keep already-built inventory rows consistent with the new shelf life
    if guess.is_perishable and guess.shelf_life_days:
        conn.execute(
            """UPDATE inventory
               SET expires_on = date(acquired_on, '+' || ? || ' days')
               WHERE product_id = ? AND status IN ('active', 'partial')""",
            (guess.shelf_life_days, product_id),
        )
    else:
        conn.execute(
            "UPDATE inventory SET expires_on = NULL WHERE product_id = ?", (product_id,)
        )


def enrich(conn: sqlite3.Connection, limit: int | None = None) -> dict[str, int]:
    """Resolve shelf life for every needs-review product via the web-search agent."""
    sql = """
        SELECT id, canonical_name, category
        FROM products
        WHERE review_state = 'needs_review'
        ORDER BY id
    """
    if limit:
        sql += f" LIMIT {int(limit)}"
    rows = conn.execute(sql).fetchall()

    stats = {"resolved": 0, "unresolved": 0, "errors": 0}
    for row in rows:
        try:
            guess = resolve(row["canonical_name"], category=row["category"])
        except Exception as e:  # noqa: BLE001 - one bad item must not stop the batch
            print(f"    enrich failed for {row['canonical_name']}: {e}")
            stats["errors"] += 1
            continue
        if (
            guess is not None
            and guess.confidence >= config.ENRICH_MIN_CONFIDENCE
            and (guess.shelf_life_days is not None or not guess.is_perishable)
        ):
            _apply(conn, row["id"], guess)
            stats["resolved"] += 1
        else:
            stats["unresolved"] += 1
    conn.commit()
    return stats

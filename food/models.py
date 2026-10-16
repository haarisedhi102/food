"""Shared data shapes for ingestion and canonicalization."""

from __future__ import annotations

from typing import Any

from pydantic import BaseModel, Field


class NormalizedItem(BaseModel):
    """One retailer line item after the structural adapter has reconciled its shape."""

    raw_description: str
    item_key: str
    raw_pkg_size: str | None = None
    quantity: float = 1.0
    unit_price_cents: int | None = None
    line_total_cents: int | None = None


class NormalizedReceipt(BaseModel):
    """A receipt envelope produced by a per-retailer structural adapter.

    `raw` keeps the untouched upstream payload so a shifted field needs a re-normalize,
    not a re-scrape.
    """

    external_id: str
    purchased_on: str | None = None
    store: str | None = None
    total_cents: int | None = None
    items: list[NormalizedItem] = Field(default_factory=list)
    raw: Any = None


class CanonicalItem(BaseModel):
    """What the LLM returns per item_key, identical across retailers."""

    item_key: str
    canonical_name: str
    brand: str | None = None
    category: str | None = None
    pkg_size: str | None = None
    unit: str | None = None  # count | weight | volume
    is_food: bool = True
    is_perishable: bool = False
    storage: str | None = None  # fridge | freezer | pantry | counter
    shelf_life_days: int | None = None
    shelf_life_days_opened: int | None = None
    confidence: float = Field(default=0.5, ge=0.0, le=1.0)


class CanonicalBatch(BaseModel):
    items: list[CanonicalItem]

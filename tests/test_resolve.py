import json
import sqlite3
from pathlib import Path

import pytest

from food import db, resolve, shelflife

FIXTURE = Path(__file__).parent / "fixtures" / "foodkeeper_sample.json"


def _mem():
    conn = sqlite3.connect(":memory:")
    conn.row_factory = sqlite3.Row
    db.init_db(conn)
    shelflife.load(conn, payload=json.loads(FIXTURE.read_text()))
    return conn


@pytest.fixture(autouse=True)
def _no_embeddings(monkeypatch):
    # keep the resolver offline: lexical retrieval only, no query-embedding API calls
    monkeypatch.setattr(resolve.embeddings, "is_configured", lambda: False)


class _FakeMsg:
    content = "notes: eggs 21d (foodkeeper 21)"


class _FakeResearch:
    def invoke(self, payload):
        return {"messages": [_FakeMsg()]}


class _FakeToolMessage:
    """Stands in for the AIMessage phase 2 returns: the verdict arrives as a tool call."""

    def __init__(self, verdict):
        self.tool_calls = (
            [{"name": "BatchVerdict", "args": verdict.model_dump(), "id": "call_1"}]
            if verdict is not None
            else []
        )


class _FakeStructured:
    """Returns queued verdicts as tool calls, one per invoke, so the re-ask can be tested."""

    def __init__(self, *verdicts):
        self._queue = list(verdicts)

    def invoke(self, messages):
        return _FakeToolMessage(self._queue.pop(0) if self._queue else None)


def _batch(*items):
    return resolve.BatchVerdict(items=[resolve.ItemVerdict(**i) for i in items])


def test_shortlists_enrich_candidates_with_shelf_life():
    conn = _mem()
    shortlists = resolve._shortlists(conn, [{"id": 1, "name": "Jumbo Yellow Onions"}], None, 5)
    top = shortlists[1][0]
    assert top["name"] == "Onions"
    assert top["pantry_days"] == 30 and "after_opening_days" in top


def test_resolve_batch_keeps_only_ids_from_the_chunk(monkeypatch):
    conn = _mem()
    verdict = _batch(
        {"item_id": 10, "source": "foodkeeper", "shelf_life_days": 30},
        {"item_id": 99, "source": "llm", "shelf_life_days": 5},  # not in the chunk
    )
    monkeypatch.setattr(resolve, "_research_agent", lambda: _FakeResearch())
    monkeypatch.setattr(resolve, "_structured", lambda: _FakeStructured(verdict))

    out = resolve.resolve_batch(conn, [{"id": 10, "name": "Jumbo Yellow Onions"}])

    assert set(out) == {10}
    assert out[10].source == "foodkeeper" and out[10].shelf_life_days == 30


def test_resolve_batch_reasks_for_an_item_the_model_omitted(monkeypatch):
    conn = _mem()
    first = _batch({"item_id": 10, "source": "llm", "shelf_life_days": 30})
    retry = _batch({"item_id": 11, "source": "llm", "shelf_life_days": 10})
    monkeypatch.setattr(resolve, "_research_agent", lambda: _FakeResearch())
    structured = _FakeStructured(first, retry)
    monkeypatch.setattr(resolve, "_structured", lambda: structured)

    out = resolve.resolve_batch(
        conn, [{"id": 10, "name": "Jumbo Yellow Onions"}, {"id": 11, "name": "Mystery Sauce"}]
    )

    assert set(out) == {10, 11}


def test_jev_high_confidence_skips_the_llm(monkeypatch):
    conn = _mem()
    monkeypatch.setattr(resolve.jev, "is_configured", lambda: True)

    def fake_decide(state, questions):
        return {
            "model": "typesafe/jev-1.14-test",
            "answers": {
                "item_10_perishable": {"type": "noul", "noul": 0.95},
                "item_10_storage": {
                    "type": "choice",
                    "choice": "pantry",
                    "confidence": 0.95,
                },
                "item_10_days": {
                    "type": "choice",
                    "choice": "d15_30",
                    "confidence": 0.95,
                },
                "item_10_candidate": {
                    "type": "choice",
                    "choice": "none",
                    "confidence": 0.9,
                },
            },
            "usage": {"input_tokens": 100, "output_tokens": 20},
        }

    monkeypatch.setattr(resolve.jev, "decide", fake_decide)
    monkeypatch.setattr(resolve, "_research_agent", lambda: _FakeResearch())
    monkeypatch.setattr(
        resolve,
        "_structured",
        lambda: (_ for _ in ()).throw(AssertionError("LLM synthesis should not run")),
    )

    out = resolve.resolve_batch(
        conn,
        [
            {
                "id": 10,
                "name": "Jumbo Yellow Onions",
                "category": "Produce",
                "storage": "pantry",
            }
        ],
    )

    assert out[10].source == "jev"
    assert out[10].shelf_life_days == 30
    assert out[10].storage == "pantry"
    assert out[10].is_perishable is True


def test_jev_low_confidence_is_still_terminal(monkeypatch):
    conn = _mem()
    monkeypatch.setattr(resolve.jev, "is_configured", lambda: True)
    monkeypatch.setattr(
        resolve.jev,
        "decide",
        lambda state, questions: {
            "answers": {
                "item_10_perishable": {"type": "noul", "noul": 0.5},
                "item_10_storage": {
                    "type": "choice",
                    "choice": "pantry",
                    "confidence": 0.5,
                },
                "item_10_days": {
                    "type": "choice",
                    "choice": "d15_30",
                    "confidence": 0.5,
                },
                "item_10_candidate": {
                    "type": "choice",
                    "choice": "none",
                    "confidence": 0.5,
                },
            }
        },
    )
    monkeypatch.setattr(resolve, "_research_agent", lambda: _FakeResearch())
    monkeypatch.setattr(
        resolve,
        "_structured",
        lambda: (_ for _ in ()).throw(AssertionError("no LLM after Jev")),
    )

    out = resolve.resolve_batch(conn, [{"id": 10, "name": "Jumbo Yellow Onions"}])

    assert out[10].source == "jev"
    # 15-30 is a wide bucket at 0.5 confidence: unknown is safer than 30 days.
    assert out[10].shelf_life_days is None


def test_rate_limit_is_not_retried(monkeypatch):
    conn = _mem()
    calls = {"n": 0}

    class _RateLimitedResearch:
        def invoke(self, payload):
            calls["n"] += 1
            raise RuntimeError("429 Too Many Requests")

    monkeypatch.setattr(resolve, "_research_agent", lambda: _RateLimitedResearch())

    out = resolve.resolve_batch(conn, [{"id": 10, "name": "Jumbo Yellow Onions"}])

    assert out == {}
    assert calls["n"] == 1


def test_apply_keeps_the_model_number_for_a_foodkeeper_verdict():
    conn = _mem()
    conn.execute(
        "INSERT INTO products (canonical_name, category, is_food, is_perishable) VALUES ('Eggs','Dairy',1,1)"
    )
    pid = conn.execute("SELECT last_insert_rowid() id").fetchone()["id"]
    conn.execute(
        "INSERT INTO inventory (product_id, quantity, remaining_qty, acquired_on, status) VALUES (?,1,1,'2026-10-10','active')",
        (pid,),
    )
    conn.commit()

    # FoodKeeper row 21 says 3 weeks, but the model judges 10 days — the model wins
    verdicts = {
        pid: resolve.ItemVerdict(item_id=pid, source="foodkeeper", shelf_life_days=10)
    }
    resolve.apply(conn, [{"id": pid, "name": "Eggs", "storage": "fridge"}], verdicts)

    p = conn.execute("SELECT * FROM products WHERE id = ?", (pid,)).fetchone()
    assert p["shelf_life_days"] == 10
    assert p["shelf_life_source"] == "foodkeeper"
    inv = conn.execute("SELECT expires_on FROM inventory WHERE product_id = ?", (pid,)).fetchone()
    assert inv["expires_on"] == "2026-10-20"  # 2026-10-10 + 10


def test_apply_uses_the_model_number_for_a_non_foodkeeper_verdict():
    conn = _mem()
    conn.execute("INSERT INTO products (canonical_name, is_food, is_perishable) VALUES ('Milk',1,1)")
    pid = conn.execute("SELECT last_insert_rowid() id").fetchone()["id"]
    conn.commit()

    verdicts = {pid: resolve.ItemVerdict(item_id=pid, source="llm", shelf_life_days=7)}
    resolve.apply(conn, [{"id": pid, "name": "Milk"}], verdicts)

    p = conn.execute("SELECT * FROM products WHERE id = ?", (pid,)).fetchone()
    assert p["shelf_life_days"] == 7 and p["shelf_life_source"] == "llm"


def test_apply_only_clears_expiry_for_a_known_non_perishable():
    conn = _mem()
    conn.execute("INSERT INTO products (canonical_name, is_food, is_perishable) VALUES ('Mystery',1,1)")
    pid = conn.execute("SELECT last_insert_rowid() id").fetchone()["id"]
    conn.execute(
        "INSERT INTO inventory (product_id, quantity, remaining_qty, acquired_on, expires_on, status) VALUES (?,1,1,'2026-10-10','2026-11-01','active')",
        (pid,),
    )
    conn.commit()

    # perishable but no days -> leave the existing expiry alone
    resolve.apply(
        conn, [{"id": pid, "name": "Mystery"}],
        {pid: resolve.ItemVerdict(item_id=pid, source="llm", is_perishable=True, shelf_life_days=None)},
    )
    kept = conn.execute("SELECT expires_on FROM inventory WHERE product_id = ?", (pid,)).fetchone()
    assert kept["expires_on"] == "2026-11-01"

    # known non-perishable -> clear it
    resolve.apply(
        conn, [{"id": pid, "name": "Mystery"}],
        {pid: resolve.ItemVerdict(item_id=pid, source="llm", is_perishable=False)},
    )
    cleared = conn.execute("SELECT expires_on FROM inventory WHERE product_id = ?", (pid,)).fetchone()
    assert cleared["expires_on"] is None

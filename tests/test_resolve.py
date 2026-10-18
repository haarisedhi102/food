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


class _FakeStructured:
    """Returns queued verdicts, one per invoke, so the missing-item re-ask can be tested."""

    def __init__(self, *verdicts):
        self._queue = list(verdicts)

    def invoke(self, messages):
        return self._queue.pop(0) if self._queue else None


def _batch(*items):
    return resolve.BatchVerdict(items=[resolve.ItemVerdict(**i) for i in items])


def test_shortlists_enrich_candidates_with_shelf_life():
    conn = _mem()
    shortlists = resolve._shortlists(conn, [{"id": 1, "name": "Jumbo Yellow Onions"}], None, 5)
    top = shortlists[1][0]
    assert top["foodkeeper_id"] == 294
    assert "pantry_days" in top and "after_opening_days" in top


def test_resolve_batch_keys_by_id_and_drops_a_bogus_foodkeeper_id(monkeypatch):
    conn = _mem()
    verdict = _batch(
        {"item_id": 10, "source": "foodkeeper", "foodkeeper_id": 294, "shelf_life_days": 30},
        # an id that is not in the shortlist must not be trusted
        {"item_id": 11, "source": "foodkeeper", "foodkeeper_id": 999999, "shelf_life_days": 10},
    )
    monkeypatch.setattr(resolve, "_research_agent", lambda: _FakeResearch())
    monkeypatch.setattr(resolve, "_structured", lambda: _FakeStructured(verdict))

    out = resolve.resolve_batch(
        conn, [{"id": 10, "name": "Jumbo Yellow Onions"}, {"id": 11, "name": "Mystery Sauce"}]
    )

    assert out[10].foodkeeper_id == 294 and out[10].source == "foodkeeper"
    assert out[11].foodkeeper_id is None and out[11].source == "llm"


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
        pid: resolve.ItemVerdict(
            item_id=pid, source="foodkeeper", foodkeeper_id=21, shelf_life_days=10
        )
    }
    resolve.apply(conn, [{"id": pid, "name": "Eggs", "storage": "fridge"}], verdicts)

    p = conn.execute("SELECT * FROM products WHERE id = ?", (pid,)).fetchone()
    assert p["shelf_life_days"] == 10
    assert p["shelf_life_source"] == "foodkeeper" and p["foodkeeper_id"] == 21
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

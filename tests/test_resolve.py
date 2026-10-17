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


class _FakeAgent:
    def __init__(self, verdict):
        self._verdict = verdict

    def invoke(self, payload):
        return {"structured_response": self._verdict}


class _SequenceAgent:
    """Returns queued responses in order, recording each payload it is given."""

    def __init__(self, responses):
        self._responses = list(responses)
        self.payloads = []

    def invoke(self, payload):
        self.payloads.append(payload)
        return self._responses.pop(0)


def _batch(*items):
    return resolve.BatchVerdict(items=[resolve.ItemVerdict(**i) for i in items])


def test_shortlists_enrich_candidates_with_shelf_life():
    conn = _mem()
    shortlists = resolve._shortlists(conn, [{"name": "Jumbo Yellow Onions"}], None, 5)
    top = shortlists["Jumbo Yellow Onions"][0]
    assert top["foodkeeper_id"] == 294
    assert "pantry_days" in top and "after_opening_days" in top


def test_resolve_batch_keeps_a_valid_id_and_drops_a_bogus_one(monkeypatch):
    conn = _mem()
    verdict = _batch(
        {
            "item": "Jumbo Yellow Onions",
            "source": "foodkeeper",
            "foodkeeper_id": 294,
            "shelf_life_days": 30,
        },
        {  # an id that is not in the shortlist must not be trusted
            "item": "Mystery Sauce",
            "source": "foodkeeper",
            "foodkeeper_id": 999999,
            "shelf_life_days": 10,
        },
    )
    monkeypatch.setattr(resolve, "_agent", lambda: _FakeAgent(verdict))

    out = resolve.resolve_batch(conn, [{"name": "Jumbo Yellow Onions"}, {"name": "Mystery Sauce"}])

    assert out["Jumbo Yellow Onions"].foodkeeper_id == 294
    assert out["Jumbo Yellow Onions"].source == "foodkeeper"
    assert out["Mystery Sauce"].foodkeeper_id is None
    assert out["Mystery Sauce"].source == "llm"


def test_resolve_nudges_the_model_when_it_answers_in_prose(monkeypatch):
    conn = _mem()
    monkeypatch.setattr(resolve.time, "sleep", lambda *_: None)  # no backoff delay in tests
    prose = {"messages": [("ai", "Here are the shelf lives and some notes…")]}  # no structured_response
    good = {
        "messages": [("ai", "ok")],
        "structured_response": _batch(
            {
                "item": "Jumbo Yellow Onions",
                "source": "foodkeeper",
                "foodkeeper_id": 294,
                "shelf_life_days": 60,
            }
        ),
    }
    agent = _SequenceAgent([prose, good])
    monkeypatch.setattr(resolve, "_agent", lambda: agent)

    out = resolve.resolve_batch(conn, [{"name": "Jumbo Yellow Onions"}])

    assert out["Jumbo Yellow Onions"].foodkeeper_id == 294
    assert len(agent.payloads) == 2  # the prose answer, then a nudge
    assert "structured-response tool" in str(agent.payloads[1])


def test_apply_writes_shelf_life_and_syncs_inventory():
    conn = _mem()
    conn.execute(
        "INSERT INTO products (canonical_name, category, is_food, is_perishable) VALUES ('Milk','Dairy',1,0)"
    )
    pid = conn.execute("SELECT last_insert_rowid() id").fetchone()["id"]
    conn.execute(
        "INSERT INTO inventory (product_id, quantity, remaining_qty, acquired_on, status) VALUES (?,1,1,'2026-10-10','active')",
        (pid,),
    )
    conn.commit()

    verdicts = {
        "Milk": resolve.ItemVerdict(
            item="Milk", source="foodkeeper", foodkeeper_id=27, shelf_life_days=7, is_perishable=True
        )
    }
    applied = resolve.apply(conn, [{"id": pid, "name": "Milk"}], verdicts)

    assert applied == 1
    p = conn.execute("SELECT * FROM products WHERE id = ?", (pid,)).fetchone()
    assert p["shelf_life_days"] == 7
    assert p["shelf_life_source"] == "foodkeeper"
    assert p["foodkeeper_id"] == 27
    inv = conn.execute("SELECT expires_on FROM inventory WHERE product_id = ?", (pid,)).fetchone()
    assert inv["expires_on"] == "2026-10-17"  # 2026-10-10 + 7

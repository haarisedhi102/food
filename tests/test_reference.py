import json
import sqlite3
from pathlib import Path

import pytest

from food import db, embeddings, reference, shelflife

FIXTURE = Path(__file__).parent / "fixtures" / "foodkeeper_sample.json"


def _mem():
    conn = sqlite3.connect(":memory:")
    conn.row_factory = sqlite3.Row
    db.init_db(conn)
    shelflife.load(conn, payload=json.loads(FIXTURE.read_text()))
    return conn


def _fake_vectors(text: str) -> list[float]:
    tl = text.lower()
    if "egg" in tl:
        return [1.0, 0.0, 0.0]
    if "milk" in tl:
        return [0.0, 1.0, 0.0]
    if "yogurt" in tl:
        return [0.0, 0.0, 1.0]
    if "onion" in tl:
        return [0.0, 0.0, 0.0]
    return [1.0, 0.0, 0.0]  # an unknown query lands nearest the Eggs vector


@pytest.fixture
def model(monkeypatch):
    monkeypatch.setattr(embeddings, "is_configured", lambda: True)
    monkeypatch.setattr(
        embeddings,
        "embed",
        lambda texts, model=None, batch_size=None: [_fake_vectors(t) for t in texts],
    )
    return "test-model"


def test_embed_corpus_is_idempotent(model):
    conn = _mem()
    assert reference.embed_corpus(conn, model=model) == 4
    assert reference.embed_corpus(conn, model=model) == 0
    assert conn.execute("SELECT COUNT(*) n FROM shelf_life_embedding").fetchone()["n"] == 4


def test_semantic_pass_rescues_an_abbreviation(model):
    conn = _mem()
    reference.embed_corpus(conn, model=model)
    # "KS ORG A2 PR" has zero lexical overlap; only the semantic pass can surface Eggs.
    ids = [c["foodkeeper_id"] for c in reference.search(conn, "KS ORG A2 PR", model=model)]
    assert 21 in ids


def test_hybrid_keeps_lexical_matches(model):
    conn = _mem()
    reference.embed_corpus(conn, model=model)
    ids = [c["foodkeeper_id"] for c in reference.search(conn, "Jumbo Yellow Onions", model=model)]
    assert 294 in ids


def test_degrades_to_lexical_without_a_key(monkeypatch):
    monkeypatch.setattr(embeddings, "is_configured", lambda: False)
    conn = _mem()
    ids = [c["foodkeeper_id"] for c in reference.search(conn, "Jumbo Yellow Onions")]
    assert 294 in ids

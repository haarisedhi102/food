import json
import sqlite3
from pathlib import Path

import pytest
from langchain_core.embeddings import Embeddings

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


class _FakeEmbeddings(Embeddings):
    def embed_documents(self, texts):
        return [_fake_vectors(t) for t in texts]

    def embed_query(self, text):
        return _fake_vectors(text)


@pytest.fixture
def model(monkeypatch):
    monkeypatch.setattr(embeddings, "is_configured", lambda: True)
    monkeypatch.setattr(reference, "_embeddings", lambda m=None: _FakeEmbeddings())
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


def test_match_grounds_a_canonical_name(monkeypatch):
    monkeypatch.setattr(embeddings, "is_configured", lambda: False)
    conn = _mem()
    hit = reference.match(conn, "Jumbo Yellow Onions")
    assert hit is not None and hit["foodkeeper_id"] == 294
    assert reference.match(conn, "") is None


def test_match_batch_uses_the_llm_pick(monkeypatch):
    monkeypatch.setattr(embeddings, "is_configured", lambda: False)
    conn = _mem()
    monkeypatch.setattr(
        reference.llm, "chat_json", lambda *a, **k: {"picks": {"Yellow Onions": 294}}
    )
    assert reference.match_batch(conn, ["Yellow Onions"]) == {"Yellow Onions": 294}


def test_match_batch_falls_back_to_the_top_hit(monkeypatch):
    monkeypatch.setattr(embeddings, "is_configured", lambda: False)
    conn = _mem()
    monkeypatch.setattr(reference.llm, "chat_json", lambda *a, **k: {})
    picks = reference.match_batch(conn, ["Jumbo Yellow Onions"])
    assert picks["Jumbo Yellow Onions"] == 294


class _CountingEmbeddings(_FakeEmbeddings):
    def __init__(self):
        self.doc_calls = 0
        self.query_calls = 0

    def embed_documents(self, texts):
        self.doc_calls += 1
        return super().embed_documents(texts)

    def embed_query(self, text):
        self.query_calls += 1
        return super().embed_query(text)


def test_match_batch_embeds_all_queries_in_one_call(monkeypatch):
    monkeypatch.setattr(embeddings, "is_configured", lambda: True)
    counter = _CountingEmbeddings()
    monkeypatch.setattr(reference, "_embeddings", lambda m=None: counter)
    monkeypatch.setattr(reference.llm, "chat_json", lambda *a, **k: {})
    conn = _mem()
    reference.embed_corpus(conn, model="test-model")  # one batched call for the corpus
    corpus_calls = counter.doc_calls

    picks = reference.match_batch(conn, ["Eggs", "Milk", "Yogurt"], model="test-model")

    assert counter.doc_calls == corpus_calls + 1  # all three queries in one call
    assert counter.query_calls == 0  # never embedded one at a time
    assert picks["Eggs"] is not None

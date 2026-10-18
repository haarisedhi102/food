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


def _ids(rows) -> list[int]:
    return [r["foodkeeper_id"] for r in rows]


def _search(conn, text, model=None, limit=8) -> list[int]:
    """The production path: build the hybrid retriever, then take one item's shortlist."""
    retriever = reference.build_retriever(conn, model, limit)
    return _ids(reference.search_with(conn, retriever, text, limit))


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
    assert 21 in _search(conn, "KS ORG A2 PR", model=model)


def test_hybrid_keeps_lexical_matches(model):
    conn = _mem()
    reference.embed_corpus(conn, model=model)
    assert 294 in _search(conn, "Jumbo Yellow Onions", model=model)


def test_degrades_to_lexical_without_a_key(monkeypatch):
    monkeypatch.setattr(embeddings, "is_configured", lambda: False)
    conn = _mem()
    assert 294 in _search(conn, "Jumbo Yellow Onions")


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


def test_query_vectors_embeds_all_names_in_one_call(monkeypatch):
    monkeypatch.setattr(embeddings, "is_configured", lambda: True)
    counter = _CountingEmbeddings()
    monkeypatch.setattr(reference, "_embeddings", lambda m=None: counter)
    conn = _mem()
    reference.embed_corpus(conn, model="test-model")  # one batched call for the corpus
    corpus_calls = counter.doc_calls

    vectors = reference._query_vectors(conn, "test-model", ["Eggs", "Milk", "Yogurt"])

    assert counter.doc_calls == corpus_calls + 1  # all three names in one call
    assert counter.query_calls == 0  # never embedded one at a time
    assert set(vectors) == {"Eggs", "Milk", "Yogurt"}

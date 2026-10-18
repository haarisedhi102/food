"""FoodKeeper reference matching, separated from canonicalization.

Canonicalization decides what an item *is* (name, brand, category, storage). Matching
decides which FoodKeeper row, if any, grounds its shelf life. Retrieval runs on the
*canonical* name (e.g. "Organic A2 Milk"), not the raw receipt code — see
`bench/retrieval_bench.py`.

A LangChain `EnsembleRetriever` fuses two retrievers with reciprocal rank fusion: a
positive-overlap lexical retriever (only docs that actually share a token, so no zero-score
padding) and a vector retriever over the embeddings persisted in `shelf_life_embedding`.
`search_with` produces one item's shortlist; choosing the row (and the shelf life) is the
resolver's job (`resolve.py`). Without `OPENROUTER_API_KEY` (or before `embed-ref`) it
degrades to the lexical retriever alone.
"""

from __future__ import annotations

import array
import sqlite3
from typing import Any

from langchain_classic.retrievers import EnsembleRetriever
from langchain_core.documents import Document
from langchain_core.retrievers import BaseRetriever
from langchain_openai import OpenAIEmbeddings

from . import config, embeddings, shelflife


def _doc_text(row: sqlite3.Row) -> str:
    parts = [row["name"], row["subtitle"], row["keywords"]]
    return " ".join(p for p in parts if p)


def _to_blob(vec) -> bytes:
    return array.array("f", vec).tobytes()


def _from_blob(blob: bytes) -> list[float]:
    a = array.array("f")
    a.frombytes(blob)
    return list(a)


def _cosine(a, b) -> float:
    if len(a) != len(b):
        return 0.0
    return sum(x * y for x, y in zip(a, b))


def _embeddings(model: str | None = None) -> OpenAIEmbeddings:
    return OpenAIEmbeddings(
        model=model or embeddings.model_name(),
        api_key=config.OPENROUTER_API_KEY,
        base_url=config.EMBED_BASE_URL,
        chunk_size=config.EMBED_BATCH_SIZE,
        # the provider is OpenAI-compatible but not OpenAI; skip tiktoken-based chunking
        check_embedding_ctx_length=False,
    )


def embed_corpus(
    conn: sqlite3.Connection, model: str | None = None, force: bool = False
) -> int:
    """Embed and store FoodKeeper rows missing an embedding for `model`. Idempotent."""
    model = model or embeddings.model_name()
    rows = conn.execute(
        "SELECT foodkeeper_id, name, subtitle, keywords FROM shelf_life_ref"
    ).fetchall()
    if not rows:
        return 0
    done = {
        r["foodkeeper_id"]
        for r in conn.execute(
            "SELECT foodkeeper_id FROM shelf_life_embedding WHERE model = ?", (model,)
        )
    }
    todo = [r for r in rows if force or r["foodkeeper_id"] not in done]
    if not todo:
        return 0

    vectors = _embeddings(model).embed_documents([_doc_text(r) for r in todo])
    for row, vec in zip(todo, vectors):
        conn.execute(
            """INSERT OR REPLACE INTO shelf_life_embedding (foodkeeper_id, model, dim, vector)
               VALUES (?, ?, ?, ?)""",
            (row["foodkeeper_id"], model, len(vec), _to_blob(vec)),
        )
    conn.commit()
    return len(todo)


class _LexicalRetriever(BaseRetriever):
    """Token-overlap retriever that keeps only positive-overlap rows.

    Unlike a BM25 retriever that pads its result to `k` with zero-score documents (which
    then pollute rank fusion), this returns nothing when there is no shared token.
    """

    conn: Any
    k: int = 16

    def _get_relevant_documents(
        self, query: str, *, run_manager: Any = None
    ) -> list[Document]:
        q = shelflife._tokens(query)
        if not q:
            return []
        scored = []
        for r in self.conn.execute(
            "SELECT foodkeeper_id, name, subtitle, keywords FROM shelf_life_ref"
        ):
            hay = (
                shelflife._tokens(r["name"])
                | shelflife._tokens(r["subtitle"])
                | shelflife._tokens(r["keywords"])
            )
            score = len(q & hay)
            if score:
                scored.append((score, r["foodkeeper_id"], _doc_text(r)))
        scored.sort(key=lambda t: (-t[0], t[1]))
        return [
            Document(page_content=text, metadata={"foodkeeper_id": fid})
            for _, fid, text in scored[: self.k]
        ]


class _SqliteVectorRetriever(BaseRetriever):
    """Vector retriever over the embeddings persisted in `shelf_life_embedding`.

    Brute-force cosine — the FoodKeeper corpus is small, so an ANN index would be noise.
    Query vectors can be supplied up front (`query_vectors`) so a batch of items is embedded
    in one call instead of an API round-trip per name.
    """

    conn: Any
    embedding: Any
    model: str
    k: int = 8
    query_vectors: dict[str, list[float]] = {}

    def _get_relevant_documents(
        self, query: str, *, run_manager: Any = None
    ) -> list[Document]:
        q = self.query_vectors.get(query)
        if q is None:
            q = self.embedding.embed_query(query)
        rows = list(
            self.conn.execute(
                "SELECT foodkeeper_id, vector FROM shelf_life_embedding WHERE model = ?",
                (self.model,),
            )
        )
        scored = sorted(
            ((_cosine(q, _from_blob(r["vector"])), r["foodkeeper_id"]) for r in rows),
            key=lambda t: (-t[0], t[1]),
        )[: self.k]
        ids = [fid for _, fid in scored]
        text = {
            r["foodkeeper_id"]: _doc_text(r)
            for r in self.conn.execute(
                "SELECT foodkeeper_id, name, subtitle, keywords FROM shelf_life_ref"
            )
        }
        return [
            Document(page_content=text[fid], metadata={"foodkeeper_id": fid})
            for fid in ids
            if fid in text
        ]


def has_embeddings(conn: sqlite3.Connection, model: str | None = None) -> bool:
    """Whether the FoodKeeper corpus is embedded for this model (i.e. semantic search is live)."""
    model = model or embeddings.model_name()
    return (
        conn.execute(
            "SELECT 1 FROM shelf_life_embedding WHERE model = ? LIMIT 1", (model,)
        ).fetchone()
        is not None
    )


def build_retriever(
    conn: sqlite3.Connection,
    model: str | None = None,
    limit: int = 8,
    query_vectors: dict[str, list[float]] | None = None,
):
    """Build the hybrid retriever, or the lexical one alone when embeddings are
    unavailable. Returns None when the reference table is empty."""
    model = model or embeddings.model_name()
    if conn.execute("SELECT 1 FROM shelf_life_ref LIMIT 1").fetchone() is None:
        return None
    lexical = _LexicalRetriever(conn=conn, k=limit * 2)
    if not embeddings.is_configured():
        return lexical
    if not has_embeddings(conn, model):
        return lexical  # nothing embedded yet — don't pay for a query embedding

    vector = _SqliteVectorRetriever(
        conn=conn,
        embedding=_embeddings(model),
        model=model,
        k=limit * 2,
        query_vectors=query_vectors or {},
    )
    return EnsembleRetriever(retrievers=[lexical, vector], weights=[0.5, 0.5])


def _fids(docs: list[Document]) -> list[int]:
    out: list[int] = []
    for d in docs:
        fid = d.metadata.get("foodkeeper_id")
        if fid is not None and fid not in out:
            out.append(fid)
    return out


def _rows(conn: sqlite3.Connection, ids: list[int]) -> list[dict]:
    if not ids:
        return []
    by_id = {
        r["foodkeeper_id"]: dict(r) for r in conn.execute("SELECT * FROM shelf_life_ref")
    }
    return [by_id[fid] for fid in ids if fid in by_id]


def search_with(
    conn: sqlite3.Connection, retriever, text: str, limit: int = 8
) -> list[dict]:
    """Run a prebuilt retriever and return candidate FoodKeeper rows, best first."""
    if retriever is None or not text:
        return []
    return _rows(conn, _fids(retriever.invoke(text))[:limit])


def _query_vectors(
    conn: sqlite3.Connection, model: str, names: list[str]
) -> dict[str, list[float]]:
    """Embed every query name in one batched call.

    Embedding per name is an API round-trip each (seconds apiece); batching them into a
    single `embed_documents` call is the difference between minutes and seconds.
    """
    if not embeddings.is_configured():
        return {}
    if conn.execute(
        "SELECT 1 FROM shelf_life_embedding WHERE model = ? LIMIT 1", (model,)
    ).fetchone() is None:
        return {}
    return dict(zip(names, _embeddings(model).embed_documents(names)))

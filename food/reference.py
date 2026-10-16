"""FoodKeeper reference matching, separated from canonicalization.

Canonicalization decides what an item *is* (name, brand, category, storage). Matching
decides which FoodKeeper row, if any, grounds its shelf life. Keeping the two apart means
retrieval can grow (lexical -> hybrid -> reranked) without touching the normalization
prompt, and the retrieval quality can be measured on its own.

Retrieval is hybrid: the existing keyword/token overlap plus a semantic pass over
embeddings stored in `shelf_life_embedding`. The two rankings are fused with Reciprocal
Rank Fusion. When embeddings are not configured (or the call fails) this degrades to the
lexical ranking alone, so the pipeline keeps working offline.
"""

from __future__ import annotations

import array
import math
import sqlite3

from . import config, embeddings, shelflife

# RRF constant; 60 is the value from the original paper.
RRF_K = 60


def _doc_text(row: sqlite3.Row) -> str:
    parts = [row["name"], row["subtitle"], row["keywords"]]
    return " ".join(p for p in parts if p)


def _to_blob(vec: list[float]) -> bytes:
    return array.array("f", vec).tobytes()


def _from_blob(blob: bytes) -> array.array:
    a = array.array("f")
    a.frombytes(blob)
    return a


def _normalize(vec) -> list[float]:
    norm = math.sqrt(sum(v * v for v in vec)) or 1.0
    return [v / norm for v in vec]


def _cosine(a, b) -> float:
    if len(a) != len(b):
        return 0.0
    return sum(x * y for x, y in zip(a, b))


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

    vectors = embeddings.embed([_doc_text(r) for r in todo], model=model)
    for row, vec in zip(todo, vectors):
        norm = _normalize(vec)
        conn.execute(
            """INSERT OR REPLACE INTO shelf_life_embedding (foodkeeper_id, model, dim, vector)
               VALUES (?, ?, ?, ?)""",
            (row["foodkeeper_id"], model, len(norm), _to_blob(norm)),
        )
    conn.commit()
    return len(todo)


def _lexical_ids(conn: sqlite3.Connection, text: str, limit: int) -> list[int]:
    return [c["foodkeeper_id"] for c in shelflife.search_candidates(conn, text, limit=limit)]


def _semantic_ids(
    conn: sqlite3.Connection, text: str, limit: int, model: str, min_score: float
) -> list[int]:
    if not embeddings.is_configured() or not text:
        return []
    try:
        q = _normalize(embeddings.embed([text], model=model)[0])
    except Exception:  # noqa: BLE001 - retrieval degrades to lexical on any embedding failure
        return []
    scored = [
        (_cosine(q, _from_blob(row["vector"])), row["foodkeeper_id"])
        for row in conn.execute(
            "SELECT foodkeeper_id, vector FROM shelf_life_embedding WHERE model = ?", (model,)
        )
    ]
    scored.sort(key=lambda t: (-t[0], t[1]))
    return [fid for score, fid in scored[:limit] if score >= min_score]


def _rows(conn: sqlite3.Connection, ids: list[int]) -> list[dict]:
    if not ids:
        return []
    by_id = {
        r["foodkeeper_id"]: dict(r)
        for r in conn.execute("SELECT * FROM shelf_life_ref")
    }
    return [by_id[fid] for fid in ids if fid in by_id]


def search(
    conn: sqlite3.Connection,
    text: str,
    limit: int = 8,
    model: str | None = None,
    min_score: float | None = None,
) -> list[dict]:
    """Hybrid keyword + semantic FoodKeeper candidates, best first."""
    model = model or embeddings.model_name()
    min_score = config.EMBED_MIN_SCORE if min_score is None else min_score
    pool = limit * 2
    lex = _lexical_ids(conn, text, pool)
    sem = _semantic_ids(conn, text, pool, model, min_score)

    if not sem:
        return _rows(conn, lex[:limit])

    scores: dict[int, float] = {}
    for rank, fid in enumerate(lex):
        scores[fid] = scores.get(fid, 0.0) + 1.0 / (RRF_K + rank + 1)
    for rank, fid in enumerate(sem):
        scores[fid] = scores.get(fid, 0.0) + 1.0 / (RRF_K + rank + 1)
    order = sorted(scores, key=lambda f: (-scores[f], f))
    return _rows(conn, order[:limit])

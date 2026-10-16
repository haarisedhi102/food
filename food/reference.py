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
import json
import math
import sqlite3

from . import config, embeddings, llm, shelflife

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
    conn: sqlite3.Connection, text: str, limit: int, model: str
) -> list[int]:
    if not embeddings.is_configured() or not text:
        return []
    rows = list(
        conn.execute(
            "SELECT foodkeeper_id, vector FROM shelf_life_embedding WHERE model = ?", (model,)
        )
    )
    if not rows:
        return []  # nothing embedded yet — don't pay for a query embedding
    try:
        q = _normalize(embeddings.embed([text], model=model)[0])
    except Exception:  # noqa: BLE001 - retrieval degrades to lexical on any embedding failure
        return []
    scored = [(_cosine(q, _from_blob(row["vector"])), row["foodkeeper_id"]) for row in rows]
    scored.sort(key=lambda t: (-t[0], t[1]))
    # Rank, don't threshold: an absolute cosine floor is model-dependent and was filtering
    # out every hit (even strong matches fall below 0.5 on these models). RRF ranks instead.
    return [fid for _, fid in scored[:limit]]


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
) -> list[dict]:
    """Hybrid keyword + semantic FoodKeeper candidates, best first."""
    model = model or embeddings.model_name()
    pool = limit * 2
    lex = _lexical_ids(conn, text, pool)
    sem = _semantic_ids(conn, text, pool, model)

    if not sem:
        return _rows(conn, lex[:limit])

    scores: dict[int, float] = {}
    for rank, fid in enumerate(lex):
        scores[fid] = scores.get(fid, 0.0) + 1.0 / (RRF_K + rank + 1)
    for rank, fid in enumerate(sem):
        scores[fid] = scores.get(fid, 0.0) + 1.0 / (RRF_K + rank + 1)
    order = sorted(scores, key=lambda f: (-scores[f], f))
    return _rows(conn, order[:limit])


def match(conn: sqlite3.Connection, name: str, model: str | None = None) -> dict | None:
    """The FoodKeeper row that grounds a *canonical* product name, or None (top hybrid hit,
    no rerank). Prefer `match_batch` when grounding several names at once."""
    if not name:
        return None
    hits = search(conn, name, limit=1, model=model)
    return hits[0] if hits else None


MATCH_SYSTEM = """You map grocery items to the single best FoodKeeper reference row.
For each item you receive a readable name and a shortlist of FoodKeeper candidates
(id + name). Pick the id whose row best matches the item, or null if none fit.
Respond with ONLY JSON: {"picks": {"<item name>": <id or null>}}"""


def match_batch(
    conn: sqlite3.Connection,
    names: list[str],
    model: str | None = None,
    topn: int = 5,
) -> dict[str, int | None]:
    """Ground a batch of canonical names in FoodKeeper: hybrid retrieval gives each item a
    shortlist, and one LLM call picks the final row. Returns {name: foodkeeper_id | None}.

    Retrieval runs on the canonical name (see `bench/retrieval_bench.py`: canonical + rrf +
    rerank is the best strategy we measured, ~0.94 recall@1)."""
    uniq = list(dict.fromkeys(n for n in names if n))
    if not uniq:
        return {}
    cand = {n: search(conn, n, limit=topn, model=model) for n in uniq}
    if not any(cand.values()):
        return {n: None for n in uniq}

    payload = [
        {
            "item": n,
            "candidates": [{"id": c["foodkeeper_id"], "name": c["name"]} for c in cand[n]],
        }
        for n in uniq
    ]
    try:
        data = llm.chat_json(
            conn, "match", MATCH_SYSTEM, json.dumps({"items": payload}, ensure_ascii=False)
        )
        picks = data.get("picks") or {}
    except Exception:  # noqa: BLE001 - a failed rerank falls back to the top hybrid hit
        picks = {}

    out: dict[str, int | None] = {}
    for n in uniq:
        pick = picks.get(n)
        if isinstance(pick, str) and pick.strip().isdigit():
            pick = int(pick)
        if isinstance(pick, int) and any(c["foodkeeper_id"] == pick for c in cand[n]):
            out[n] = pick
        else:
            out[n] = cand[n][0]["foodkeeper_id"] if cand[n] else None
    return out

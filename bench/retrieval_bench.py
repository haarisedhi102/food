"""Retrieval benchmark: which strategy best maps grocery items onto FoodKeeper rows?

Compares, over a hand-labelled gold set drawn from real receipts:

  * query source  — the raw receipt description vs the LLM's canonical name vs both
  * retriever     — lexical token overlap, semantic cosine, hybrid (reciprocal rank fusion)
  * embedding model — whatever FOOD_EMBED_MODEL is set to, and any extra models listed

Scored with recall@1/3/5 and MRR. Run against a DB that has `shelf_life_ref` populated:

    FOOD_DB_PATH=/path/to/food.db uv run python bench/retrieval_bench.py
"""

from __future__ import annotations

import math
import os
import sqlite3
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from food import db, embeddings, shelflife  # noqa: E402

# (raw receipt description, canonical name, expected substring in the FoodKeeper row name)
GOLD = [
    ("Kroger® Unsalted Butter Sticks", "Unsalted Butter Sticks", "butter"),
    ("Land O Lakes Unsalted Butter in Half Sticks", "Unsalted Butter Half Sticks", "butter"),
    ("Kroger® Heavy Whipping Cream Pint", "Heavy Whipping Cream", "cream"),
    ("Kroger® Original Sour Cream", "Sour Cream", "cream"),
    ("Kroger® Large Grade A Eggs", "Large Eggs", "egg"),
    ("Kenz Henz Large All-Natural Pastured Eggs", "Pasture-Raised Eggs", "egg"),
    ("PASTURE EGGS 2DZ GRADE A P360/300 SL22", "Pasture-Raised Eggs", "egg"),
    ("Horizon Organic Growing Years Whole Milk", "Organic Whole Milk", "milk"),
    ("Simple Truth Organic® Vitamin D Whole Milk Gallon", "Organic Vitamin D Whole Milk", "milk"),
    ("KS ORG A2 PR 3/64OZ SL30 33X4 P132", "Organic A2 Milk", "milk"),
    ("Roundy's® Select Vitamin D Whole Milk", "Vitamin D Whole Milk", "milk"),
    ("Stonyfield Organic Whole Milk Pear Spinach Mango Yogurt", "Whole Milk Yogurt", "yogurt"),
    ("Simple Truth Organic® Sharp White Cheddar Shredded Cheese", "Sharp White Cheddar", "cheese"),
    ("Sara Lee Delightful Honey Whole Wheat Bread", "Honey Whole Wheat Bread", "bread"),
    ("Healthy Life High Fiber Honey Wheat Bread", "High Fiber Honey Wheat Bread", "bread"),
    ("Barilla Protein+ (Plus) Penne Pasta", "Protein Penne Pasta", "pasta"),
    ("Barilla Protein+ (Plus) Spaghetti Pasta", "Protein Spaghetti Pasta", "pasta"),
    ("King Arthur All Purpose Unbleached Flour", "All Purpose Flour", "flour"),
    ("Bertolli® Organic Olive Oil Basil & Garlic Pasta Sauce", "Olive Oil Pasta Sauce", "pasta"),
    ("Kroger® Sliced Ripe Olives", "Sliced Ripe Olives", "olive"),
    ("Simple Truth Organic® Whole Carrots Bag", "Whole Carrots", "carrot"),
    ("Fresh Red Hothouse Bell Pepper", "Red Bell Pepper", "pepper"),
    ("Fresh Roma Tomato", "Roma Tomato", "tomato"),
    ("Simple Truth Organic® Double Concentrated Tomato Paste", "Tomato Paste", "tomato"),
    ("Jumbo Yellow Onions", "Yellow Onions", "onion"),
    ("Jumbo Red Onions", "Red Onions", "onion"),
    ("Russet Potato", "Russet Potato", "potato"),
    ("Fresh Bunch of Bananas – 5-7 Bananas", "Bananas", "banana"),
    ("Fresh Banana - Single", "Banana", "banana"),
    ("Garlic", "Garlic", "garlic"),
    ("SHRIMP 31/40 6T 6H P576 SL90", "Shrimp", "shrimp"),
    ("KS COLMBIAN 3LBS 1.36KG", "Colombian Coffee", "coffee"),
    ("ZYN VTY 12/12OZ", "Zyn Variety Pack", ""),  # non-food: expected to find nothing
]

NON_FOOD_INDEX = {idx for idx, g in enumerate(GOLD) if g[2] == ""}


def _docs(conn: sqlite3.Connection) -> tuple[list[int], list[str]]:
    ids, texts = [], []
    for r in conn.execute(
        "SELECT foodkeeper_id, name, subtitle, keywords FROM shelf_life_ref"
    ):
        ids.append(r["foodkeeper_id"])
        texts.append(" ".join(p for p in (r["name"], r["subtitle"], r["keywords"]) if p))
    return ids, texts


def _names(conn: sqlite3.Connection) -> dict[int, str]:
    return {
        r["foodkeeper_id"]: (r["name"] or "")
        for r in conn.execute("SELECT foodkeeper_id, name FROM shelf_life_ref")
    }


def _lexical_rank(query: str, ids, texts) -> list[int]:
    q = shelflife._tokens(query)
    scored = [(len(q & shelflife._tokens(t)), i) for i, t in enumerate(texts)]
    scored = [s for s in scored if s[0] > 0]
    scored.sort(key=lambda s: (-s[0], ids[s[1]]))
    return [ids[i] for _, i in scored]


def _semantic_rank(qvec, ids, mat) -> list[int]:
    scored = [(sum(a * b for a, b in zip(qvec, v)), fid) for v, fid in zip(mat, ids)]
    scored.sort(key=lambda s: (-s[0], s[1]))
    return [fid for _, fid in scored]


def _rrf(*rankings: list[int], k: int = 60) -> list[int]:
    scores: dict[int, float] = {}
    for ranking in rankings:
        for rank, fid in enumerate(ranking):
            scores[fid] = scores.get(fid, 0.0) + 1.0 / (k + rank + 1)
    return sorted(scores, key=lambda f: (-scores[f], f))


def _evaluate(name: str, rank_fn) -> dict:
    hits = {1: 0, 3: 0, 5: 0}
    rr = 0.0
    n = 0
    for idx, (raw, canon, expect) in enumerate(GOLD):
        if idx in NON_FOOD_INDEX:
            continue
        n += 1
        ranked = rank_fn(raw, canon)
        for k in hits:
            if any(expect in name_of(fid).lower() for fid in ranked[:k]):
                hits[k] += 1
        for rank, fid in enumerate(ranked[:10], 1):
            if expect in name_of(fid).lower():
                rr += 1.0 / rank
                break
    return {
        "strategy": name,
        "r@1": hits[1] / n,
        "r@3": hits[3] / n,
        "r@5": hits[5] / n,
        "mrr": rr / n,
    }


name_of = lambda fid: NAMES.get(fid, "")  # noqa: E731
NAMES: dict[int, str] = {}


def run_for_model(conn, model: str) -> list[dict]:
    ids, texts = _docs(conn)
    print(f"\n=== model: {model} ===")
    print("embedding corpus...", flush=True)
    mat = embeddings.embed(texts, model=model)

    def qvec(text: str) -> list[float]:
        v = embeddings.embed([text], model=model)[0]
        n = math.sqrt(sum(x * x for x in v)) or 1.0
        return [x / n for x in v]

    cache: dict[str, list[int]] = {}

    def ranked(source: str, retriever: str):
        def fn(raw: str, canon: str) -> list[int]:
            query = {"raw": raw, "canonical": canon, "both": f"{canon} {raw}"}[source]
            key = f"{source}|{query}"
            sem = cache.get(key) if retriever in ("semantic", "hybrid") else None
            lex = (
                _lexical_rank(query, ids, texts)
                if retriever in ("lexical", "hybrid")
                else []
            )
            if retriever in ("semantic", "hybrid") and sem is None:
                sem = _semantic_rank(qvec(query), ids, mat)
                cache[key] = sem
            if retriever == "lexical":
                return lex
            if retriever == "semantic":
                return sem
            return _rrf(lex, sem)

        return fn

    rows = []
    for source in ("raw", "canonical", "both"):
        for retriever in ("lexical", "semantic", "hybrid"):
            rows.append(_evaluate(f"{source:9} + {retriever}", ranked(source, retriever)))
    return rows


def main() -> None:
    conn = db.connect()
    global NAMES
    NAMES = _names(conn)
    models = [embeddings.model_name()]
    extra = os.getenv("BENCH_MODELS", "")
    models += [m.strip() for m in extra.split(",") if m.strip() and m.strip() not in models]

    all_rows = []
    for model in models:
        all_rows += run_for_model(conn, model)
    conn.close()

    print(f"\n{'strategy':28} {'R@1':>6} {'R@3':>6} {'R@5':>6} {'MRR':>6}")
    for r in all_rows:
        print(
            f"{r['strategy']:28} {r['r@1']:6.2f} {r['r@3']:6.2f} {r['r@5']:6.2f} {r['mrr']:6.2f}"
        )


if __name__ == "__main__":
    main()

"""Retrieval benchmark v2 — measures the FoodKeeper *retriever*.

Scores by **exact** FoodKeeper id (a gold item may accept several ids), not substring, so
near-misses no longer count as hits. This is a proxy for retrieval quality only: the shipped
pipeline (`resolve.py`) no longer picks a row by id — an agent decides the shelf life and the
row is just a hint — so these numbers do not describe end-to-end accuracy. Compares:

  * query source : raw receipt description vs canonical name
  * retriever    : positive-overlap lexical | semantic cosine | hybrid RRF
  * LLM rerank   : optionally let the model pick the best candidate from the top-k
  * embedding    : whatever FOOD_EMBED_MODEL is (plus BENCH_MODELS)

Run against a DB with `shelf_life_ref` populated:

    FOOD_DB_PATH=/path/to/food.db FOOD_EMBED_MODEL=baai/bge-base-en-v1.5 \
        uv run python bench/retrieval_bench.py
"""

from __future__ import annotations

import json
import math
import os
import sqlite3
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from food import db, embeddings, llm, shelflife  # noqa: E402

# (raw receipt description, canonical name, acceptable FoodKeeper ids)
GOLD: list[tuple[str, str, set[int]]] = [
    ("Kroger® Unsalted Butter Sticks", "Unsalted Butter Sticks", {1}),
    ("Land O Lakes Unsalted Butter in Half Sticks", "Unsalted Butter Half Sticks", {1}),
    ("Kroger® Heavy Whipping Cream Pint", "Heavy Whipping Cream", {11, 12, 13}),
    ("Kroger® Heavy Whipping Cream Quart", "Heavy Whipping Cream", {11, 12, 13}),
    ("Kroger® Original Sour Cream", "Sour Cream", {11, 12, 13}),
    ("Kenz Henz Large All-Natural Pastured Eggs", "Pasture-Raised Eggs", {21, 22, 23}),
    ("PASTURE EGGS 2DZ GRADE A P360/300 SL22", "Pasture-Raised Eggs", {21, 22, 23}),
    ("Horizon Organic Growing Years Whole Milk", "Organic Whole Milk", {27, 383}),
    ("Simple Truth Organic® Vitamin D Whole Milk Gallon", "Organic Vitamin D Whole Milk", {27, 383}),
    ("KS ORG A2 PR 3/64OZ SL30 33X4 P132", "Organic A2 Milk", {27, 383}),
    ("Stonyfield Organic Whole Milk Pear Spinach Mango Yogurt", "Whole Milk Yogurt", {33}),
    ("Simple Truth Organic® Sharp White Cheddar Shredded Cheese", "Sharp White Cheddar", {3, 4, 5, 6, 7}),
    ("Sara Lee Delightful Honey Whole Wheat Bread", "Honey Whole Wheat Bread", {460, 461, 574}),
    ("Healthy Life High Fiber Honey Wheat Bread", "High Fiber Honey Wheat Bread", {460, 461, 574}),
    ("Barilla Protein+ (Plus) Penne Pasta", "Protein Penne Pasta", {335}),
    ("Barilla Protein+ (Plus) Spaghetti Pasta", "Protein Spaghetti Pasta", {335}),
    ("King Arthur All Purpose Unbleached Flour", "All Purpose Flour", {222, 223}),
    ("Kroger® Sliced Ripe Olives", "Sliced Ripe Olives", {187, 352}),
    ("Simple Truth Organic® Whole Carrots Bag", "Whole Carrots", {279, 491}),
    ("Fresh Red Hothouse Bell Pepper", "Red Bell Pepper", {296, 458}),
    ("Fresh Roma Tomato", "Roma Tomato", {306}),
    ("Simple Truth Organic® Double Concentrated Tomato Paste", "Tomato Paste", {501}),
    ("Jumbo Yellow Onions", "Yellow Onions", {294, 295}),
    ("Jumbo Red Onions", "Red Onions", {294, 295}),
    ("Russet Potato", "Russet Potato", {297, 393}),
    ("Fresh Bunch of Bananas – 5-7 Bananas", "Bananas", {251}),
    ("Fresh Banana - Single", "Banana", {251}),
    ("Garlic", "Garlic", {235, 285}),
    ("SHRIMP 31/40 6T 6H P576 SL90", "Shrimp", {151, 325}),
    ("KS COLMBIAN 3LBS 1.36KG", "Colombian Coffee", {400, 401, 402}),
    ("SIMPLY OJ C2 T20H5 P200 SL35", "Orange Juice", {455, 456, 457}),
    ("SKINNYPOP 28 T8H7 P56 SL110", "SkinnyPop Popcorn", {389, 390, 391}),
    ("KENCOLESSTEE", "Coleslaw Dressing", {356, 623, 624, 625, 626}),
]

RRF_K = 60


def _corpus(conn: sqlite3.Connection):
    ids, texts, names = [], [], {}
    for r in conn.execute("SELECT foodkeeper_id, name, subtitle, keywords FROM shelf_life_ref"):
        ids.append(r["foodkeeper_id"])
        texts.append(" ".join(p for p in (r["name"], r["subtitle"], r["keywords"]) if p))
        names[r["foodkeeper_id"]] = r["name"] or ""
    return ids, texts, names


def _lex_pos(query, ids, texts):
    q = shelflife._tokens(query)
    scored = [(len(q & shelflife._tokens(t)), ids[i]) for i, t in enumerate(texts)]
    scored = [s for s in scored if s[0] > 0]  # positive overlap only — no zero-score padding
    scored.sort(key=lambda s: (-s[0], s[1]))
    return [fid for _, fid in scored]


def _sem(qvec, ids, mat):
    scored = [(sum(a * b for a, b in zip(qvec, v)), fid) for v, fid in zip(mat, ids)]
    scored.sort(key=lambda s: (-s[0], s[1]))
    return [fid for _, fid in scored]


def _rrf(*rankings):
    scores: dict[int, float] = {}
    for ranking in rankings:
        for rank, fid in enumerate(ranking):
            scores[fid] = scores.get(fid, 0.0) + 1.0 / (RRF_K + rank + 1)
    return sorted(scores, key=lambda f: (-scores[f], f))


def _evaluate(rank_fns: dict, names) -> list[dict]:
    n = len(GOLD)
    rows = []
    for label, fn in rank_fns.items():
        hits = {1: 0, 3: 0, 5: 0}
        rr = 0.0
        for raw, canon, gold in GOLD:
            ranked = fn(raw, canon)
            for k in hits:
                if any(fid in gold for fid in ranked[:k]):
                    hits[k] += 1
            for rank, fid in enumerate(ranked[:10], 1):
                if fid in gold:
                    rr += 1.0 / rank
                    break
        rows.append(
            {
                "strategy": label,
                "r@1": hits[1] / n,
                "r@3": hits[3] / n,
                "r@5": hits[5] / n,
                "mrr": rr / n,
            }
        )
    return rows


def _llm_rerank(conn, base_fn, names, topn=5):
    """One batched LLM call: given each item's top-k candidates, pick the best id."""
    payload = []
    cache: dict[tuple, list[int]] = {}
    for raw, canon, _ in GOLD:
        cands = base_fn(raw, canon)[:topn]
        cache[(raw, canon)] = cands
        payload.append(
            {
                "key": f"{raw}||{canon}",
                "item": canon,
                "receipt_text": raw,
                "candidates": [{"id": fid, "name": names[fid]} for fid in cands if fid in names],
            }
        )
    system = (
        "You map a grocery item to a FoodKeeper row. For each item pick the single best "
        "candidate id, or null if none fit. Return JSON: {\"picks\":{\"<key>\": <id|null>}}."
    )
    data = llm.chat_json(conn, "bench", system, json.dumps({"items": payload}))
    picks = data.get("picks", {})

    def fn(raw, canon):
        cands = cache[(raw, canon)]
        chosen = picks.get(f"{raw}||{canon}")
        if isinstance(chosen, str) and chosen.isdigit():
            chosen = int(chosen)
        out = [chosen] if isinstance(chosen, int) else []
        out += [fid for fid in cands if fid != chosen]
        return out + [fid for fid in _ALL_IDS if fid not in out]

    return fn


def run_model(conn, model, names, use_llm):
    ids, texts, _ = _corpus(conn)
    print(f"\n=== model: {model} ===", flush=True)
    mat = embeddings.embed(texts, model=model)

    def qvec(text):
        v = embeddings.embed([text], model=model)[0]
        n = math.sqrt(sum(x * x for x in v)) or 1.0
        return [x / n for x in v]

    defs = {}
    for source in ("canonical", "raw"):
        def make(source=source, which="lex"):
            def fn(raw, canon):
                q = canon if source == "canonical" else raw
                lex = _lex_pos(q, ids, texts)
                if which == "lex":
                    return lex
                sem = _sem(qvec(q), ids, mat)
                return sem if which == "sem" else _rrf(lex, sem)

            return fn

        defs[f"{source:9} lex_pos"] = make(which="lex")
        defs[f"{source:9} semantic"] = make(which="sem")
        defs[f"{source:9} rrf"] = make(which="rrf")

    if use_llm:
        for base in (f"canonical rrf", f"canonical semantic"):
            defs[f"{base} +llm"] = _llm_rerank(conn, defs[base], names)

    return _evaluate(defs, names)


_ALL_IDS: list[int] = []


def main() -> None:
    global _ALL_IDS
    conn = db.connect()
    _ALL_IDS, _, names = _corpus(conn)

    models = [embeddings.model_name()]
    models += [m.strip() for m in os.getenv("BENCH_MODELS", "").split(",") if m.strip() and m.strip() not in models]
    use_llm = os.getenv("BENCH_LLM", "1") != "0"

    all_rows = []
    for model in models:
        all_rows += [(model, r) for r in run_model(conn, model, names, use_llm)]
    conn.close()

    print(f"\n{'model':34} {'strategy':26} {'R@1':>6} {'R@3':>6} {'R@5':>6} {'MRR':>6}")
    for model, r in all_rows:
        print(
            f"{model:34} {r['strategy']:26} {r['r@1']:6.2f} {r['r@3']:6.2f} "
            f"{r['r@5']:6.2f} {r['mrr']:6.2f}"
        )


if __name__ == "__main__":
    main()

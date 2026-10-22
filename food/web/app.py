"""FastAPI dashboard: the virtual fridge & pantry.

Binds 127.0.0.1 only — there is no auth and the data is your purchase history.
"""

from __future__ import annotations

from datetime import date
from pathlib import Path

from fastapi import FastAPI, Form, Request
from fastapi.responses import RedirectResponse
from fastapi.templating import Jinja2Templates

from .. import config, db, inventory, llm

TEMPLATES = Jinja2Templates(directory=str(Path(__file__).parent / "templates"))
TEMPLATES.env.globals["relative"] = lambda days: _relative(days)
# Brand for a row's second line, or "" when there's nothing useful to add — no brand, or a brand
# the name already contains. Mirrors `ItemRow.brandText` in the Swift app.
TEMPLATES.env.globals["brand_of"] = lambda name, brand: (
    brand if brand and brand.lower() not in (name or "").lower() else ""
)
LOCATIONS = ["fridge", "freezer", "pantry", "counter"]
# "Use soon" leads the dashboard: everything within this window, across every shelf. Mirrors
# `AppModel.useSoonDays` in the Swift app so the phone and the web read the same.
USE_SOON_DAYS = 7
# A shelf longer than this starts collapsed; see `_shelf_collapsed`. Only the pantry ever hits it.
COLLAPSE_THRESHOLD = 50
CHAT_SYSTEM = config.SHARED_PROMPTS["chat"]

app = FastAPI(title="Virtual Fridge & Pantry")


def _conn():
    conn = db.connect()
    db.init_db(conn)
    return conn


def _days_left(expires_on: str | None) -> int | None:
    if not expires_on:
        return None
    return (date.fromisoformat(expires_on) - date.today()).days


def _relative(days: int | None) -> str:
    """Human phrasing for a days-left value, mirroring `Chat.relative` in the Swift app so the
    web dashboard and the phone read the same: today / tomorrow / in N days / N days past."""
    if days is None:
        return "no expiry"
    if days < -1:
        return f"{-days} days past"
    if days == -1:
        return "yesterday"
    if days == 0:
        return "today"
    if days == 1:
        return "tomorrow"
    return f"in {days} days"


def _shelves(conn) -> dict[str, list[dict]]:
    rows = inventory.active(conn)
    shelves: dict[str, list[dict]] = {loc: [] for loc in LOCATIONS}
    for r in rows:
        if r["status"] == "expired":
            continue
        r["days_left"] = _days_left(r["expires_on"])
        shelves.setdefault(r["location"] or "pantry", []).append(r)
    return shelves


def _snapshot(conn) -> str:
    rows = inventory.active(conn)
    lines = []
    for r in rows:
        if r["status"] == "expired":
            continue
        d = _days_left(r["expires_on"])
        when = "no expiry" if d is None else (f"{d}d left" if d >= 0 else f"{-d}d past")
        lines.append(f"- {r['canonical_name']} x{r['remaining_qty']:g} [{r['location']}] ({when})")
    return "\n".join(lines) or "(nothing in stock)"


@app.get("/")
def index(request: Request, archived: int = 0, q: str = "", show: str = ""):
    conn = _conn()
    shelves = _shelves(conn)
    soon = inventory.expiring_soon(conn, days=USE_SOON_DAYS)
    for r in soon:
        r["days_left"] = _days_left(r["expires_on"])
    extra = inventory.active(conn, include_archived=True) if archived else []
    conn.close()

    # "Use soon" leads: the shelf sections then show only what's left (beyond the horizon), so
    # nothing appears twice and the dashboard reads as "act on these, browse the rest" — exactly
    # like the phone's Kitchen tab.
    soon_ids = {r["id"] for r in soon}
    rest = {
        loc: [r for r in rows if r["id"] not in soon_ids] for loc, rows in shelves.items()
    }
    totals = {loc: len(shelves.get(loc, [])) for loc in LOCATIONS}

    # `show=<loc>` expands a long shelf (the pantry) on request.
    expanded = {s for s in show.split(",") if s}

    def collapsed(loc: str) -> bool:
        return len(rest.get(loc, [])) >= COLLAPSE_THRESHOLD and loc not in expanded

    # Search across all shelves by name / brand / category — the same fields the phone
    # searches. When a query is present the shelves collapse into one result list.
    needle = q.strip().lower()
    results: list[dict] = []
    if needle:
        for row in shelves.values():
            for r in row:
                hay = " ".join(
                    str(r.get(f) or "") for f in ("canonical_name", "brand", "category")
                ).lower()
                if needle in hay:
                    results.append(r)

    visible = {
        loc: ([] if collapsed(loc) else rest.get(loc, [])) for loc in LOCATIONS
    }
    # Precompute the `show=` values for the expand/collapse links, so the template stays simple.
    show_links = {
        loc: ",".join(sorted(expanded | {loc})) for loc in LOCATIONS
    }
    hide_links = {
        loc: ",".join(sorted(expanded - {loc})) for loc in LOCATIONS
    }
    return TEMPLATES.TemplateResponse(
        request,
        "index.html",
        {
            "use_soon_days": USE_SOON_DAYS,
            "shelves": visible,
            "rest": rest,
            "locations": LOCATIONS,
            "soon": soon,
            "counts": totals,
            "collapsed": {loc: collapsed(loc) for loc in LOCATIONS},
            "expanded": expanded,
            "show_links": show_links,
            "hide_links": hide_links,
            "archived": bool(archived),
            "archived_rows": [r for r in extra if r["status"] == "archived"][:100],
            "today": date.today().isoformat(),
            "q": q,
            "results": results,
        },
    )


@app.post("/inventory/{iid}/status")
def set_status(iid: int, status: str = Form(...)):
    conn = _conn()
    inventory.set_status(conn, iid, status)
    conn.close()
    return RedirectResponse("/", status_code=303)


@app.get("/item/{pid}")
def item(request: Request, pid: int):
    conn = _conn()
    product = conn.execute("SELECT * FROM products WHERE id = ?", (pid,)).fetchone()
    if product is None:
        conn.close()
        return TEMPLATES.TemplateResponse(request, "missing.html", {"pid": pid}, status_code=404)
    history = conn.execute(
        """SELECT r.purchased_on, ri.unit_price_cents, ri.line_total_cents, r.retailer
           FROM receipt_items ri JOIN receipts r ON r.id = ri.receipt_id
           JOIN item_map m ON m.retailer = r.retailer AND m.item_key = ri.item_key
           WHERE m.product_id = ? ORDER BY r.purchased_on ASC""",
        (pid,),
    ).fetchall()
    stock = conn.execute(
        "SELECT * FROM inventory WHERE product_id = ? ORDER BY acquired_on DESC", (pid,)
    ).fetchall()
    conn.close()
    points = [
        {"date": h["purchased_on"], "price": (h["unit_price_cents"] or 0) / 100}
        for h in history
        if h["unit_price_cents"]
    ]
    return TEMPLATES.TemplateResponse(
        request,
        "item.html",
        {
            "p": dict(product),
            "history": [dict(h) for h in history],
            "stock": [dict(s) for s in stock],
            "points": points,
        },
    )


@app.get("/chat")
def chat_page(request: Request):
    return TEMPLATES.TemplateResponse(request, "chat.html", {"answer": None, "question": ""})


@app.post("/chat")
def chat_ask(request: Request, question: str = Form(...)):
    conn = _conn()
    try:
        answer = llm.chat_text(
            conn,
            "chat",
            CHAT_SYSTEM,
            f"Current stock:\n{_snapshot(conn)}\n\nQuestion: {question}",
            use_cache=True,
        )
    except Exception as e:  # noqa: BLE001 - surface the failure in the UI
        answer = f"Sorry, the assistant failed: {e}"
    conn.close()
    return TEMPLATES.TemplateResponse(
        request, "chat.html", {"answer": answer, "question": question}
    )


@app.get("/api/inventory")
def api_inventory(archived: int = 0):
    conn = _conn()
    rows = inventory.active(conn, include_archived=bool(archived))
    conn.close()
    for r in rows:
        r["days_left"] = _days_left(r["expires_on"])
    return rows


@app.get("/api/expiring")
def api_expiring(days: int = 3):
    conn = _conn()
    rows = inventory.expiring_soon(conn, days=days)
    conn.close()
    for r in rows:
        r["days_left"] = _days_left(r["expires_on"])
    return rows


@app.post("/api/ask")
def api_ask(question: str = Form(...)):
    conn = _conn()
    answer = llm.chat_text(
        conn,
        "chat",
        CHAT_SYSTEM,
        f"Current stock:\n{_snapshot(conn)}\n\nQuestion: {question}",
        use_cache=True,
    )
    conn.close()
    return {"question": question, "answer": answer}

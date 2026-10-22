"""`food` command line."""

from __future__ import annotations

import json
from datetime import date
from pathlib import Path
from typing import Optional

import typer
from rich.console import Console

from . import config, db, normalize

app = typer.Typer(add_completion=False, help="Virtual fridge & pantry.")
console = Console()


@app.callback()
def _startup() -> None:
    """Wire up optional Phoenix tracing before any command runs."""
    from . import tracing

    tracing.setup()


def _conn():
    conn = db.connect()
    db.init_db(conn)
    return conn


@app.command("init-db")
def init_db() -> None:
    """Create the SQLite schema."""
    _conn().close()
    console.print(f"[green]initialised[/] {config.DB_PATH}")


def _run_sync(conn, retailer: str, lookback: int | None, cdp: str | None) -> None:
    """Pull, normalize and store receipts for one or more retailers."""
    from .ingest import browser as bwin, costco, kroger

    targets = ["costco", "kroger"] if retailer == "all" else [retailer]
    for name in targets:
        console.rule(f"[bold]{name}[/]")
        if name == "costco":
            # Same incremental rule as the iOS app: with no explicit lookback (sync/refresh),
            # start from the newest stored purchase date instead of re-pulling the whole window.
            since = None
            if lookback is None:
                row = conn.execute(
                    "SELECT MAX(purchased_on) AS latest FROM receipts WHERE retailer = 'costco'"
                ).fetchone()
                if row and row["latest"]:
                    since = date.fromisoformat(row["latest"])
            raw = costco.pull(
                lookback or config.COSTCO_LOOKBACK_DAYS, cdp=cdp, since=since
            )
            path = bwin.archive("costco", raw)
            receipts = normalize.normalize_costco(raw)
        elif name == "kroger":
            # skip receipts we've already itemized so re-syncs are fast and gentle
            done = {
                row["external_id"]
                for row in conn.execute(
                    "SELECT DISTINCT external_id FROM receipts WHERE retailer = 'kroger'"
                )
            }
            raw = kroger.pull(
                lookback or config.KROGER_LOOKBACK_DAYS, cdp=cdp, skip_keys=done
            )
            path = bwin.archive("kroger", raw)
            receipts = normalize.normalize_kroger(raw)
        else:
            raise typer.BadParameter(f"unknown retailer: {name}")

        new_r, new_i = normalize.store(conn, name, receipts)
        console.print(
            f"[green]{name}[/]: {len(receipts)} receipts seen, "
            f"[bold]{new_r}[/] new receipts, [bold]{new_i}[/] new items"
        )
        console.print(f"    raw archived: {path}")


@app.command("sync")
def sync(
    retailer: str = typer.Option("all", help="costco | kroger | all"),
    lookback: Optional[int] = typer.Option(None, help="Override lookback window (days)"),
    cdp: Optional[str] = typer.Option(None, help="Attach to an existing Chrome via CDP URL"),
) -> None:
    """Pull receipts from Kroger and/or Costco through a real logged-in Chrome."""
    conn = _conn()
    _run_sync(conn, retailer, lookback, cdp)
    conn.close()


@app.command("import")
def import_file(
    path: Path = typer.Argument(..., exists=True, dir_okay=False),
    retailer: str = typer.Option(..., help="costco | kroger"),
) -> None:
    """Import a previously saved raw payload (keeps the pipeline alive if a scraper breaks)."""
    raw = json.loads(Path(path).read_text())
    normalizer = normalize.NORMALIZERS.get(retailer)
    if normalizer is None:
        raise typer.BadParameter(f"unknown retailer: {retailer}")
    conn = _conn()
    receipts = normalizer(raw)
    new_r, new_i = normalize.store(conn, retailer, receipts)
    conn.close()
    console.print(
        f"[green]{retailer}[/]: {len(receipts)} receipts, "
        f"[bold]{new_r}[/] new, [bold]{new_i}[/] new items"
    )


@app.command("sync-ref")
def sync_ref() -> None:
    """(Re)load the USDA FoodKeeper shelf-life reference table."""
    from . import shelflife

    conn = _conn()
    n = shelflife.load(conn)
    conn.close()
    console.print(f"[green]loaded[/] {n} FoodKeeper rows")


@app.command("embed-ref")
def embed_ref(force: bool = typer.Option(False, help="Re-embed every row, not just new ones")) -> None:
    """Embed the FoodKeeper table for hybrid reference search (needs OPENROUTER_API_KEY)."""
    from . import embeddings, reference

    if not embeddings.is_configured():
        console.print("[red]OPENROUTER_API_KEY is not set[/] — semantic search stays disabled.")
        raise typer.Exit(1)
    conn = _conn()
    n = reference.embed_corpus(conn, force=force)
    conn.close()
    console.print(f"[green]embedded[/] {n} FoodKeeper rows with {embeddings.model_name()}")


def _load_reference(conn) -> None:
    """Load FoodKeeper and, when configured, embed it. Both steps are idempotent."""
    from . import embeddings, reference, shelflife

    n = shelflife.load(conn)
    console.print(f"[green]loaded[/] {n} FoodKeeper rows")
    if not embeddings.is_configured():
        console.print(
            "[yellow]note[/] OPENROUTER_API_KEY is not set — skipping embeddings, "
            "search stays keyword-only."
        )
        return
    m = reference.embed_corpus(conn)
    console.print(f"[green]embedded[/] {m} FoodKeeper rows with {embeddings.model_name()}")


@app.command("probe-kroger")
def probe_kroger(cdp: Optional[str] = typer.Option(None)) -> None:
    """Diagnostic: reproduce the details batch pattern and print each response status."""
    from .ingest import browser as bwin, kroger

    with bwin.browser(cdp=cdp) as ctx:
        page = ctx.pages[0] if ctx.pages else ctx.new_page()
        bwin.ensure_login(page, f"{kroger.BASE}/mypurchases", kroger.LOGGED_IN_JS, "Log into Kroger.")
        res = kroger._search_page(page, 1)
        recs = ((res.get("json") or {}).get("data") or {}).get("postOrderSearch", {}).get("data") or []
        keys = [
            r["receiptKey"]
            for r in recs
            if r.get("purchaseType") in kroger.GROCERY_TYPES and r.get("receiptKey")
        ]
        console.print(f"page url after search: {page.url}")
        console.print(f"grocery receipt keys on page 1: {len(keys)}")

        def body_for(ks):
            out = []
            for k in ks:
                p = str(k).split("~")
                if len(p) == 5:
                    out.append(
                        {
                            "divisionNumber": p[0],
                            "storeNumber": p[1],
                            "transactionDate": p[2],
                            "terminalNumber": p[3],
                            "transactionId": p[4],
                        }
                    )
            return json.dumps(out)

        for label, ks in (("single", keys[:1]), ("batch-10", keys[:10]), ("batch-25", keys[:25])):
            out = bwin.page_fetch(
                page, kroger.DETAILS_URL, method="POST", headers=kroger.DETAILS_HEADERS, body=body_for(ks)
            )
            console.print(
                f"{label:>9}: status={out['status']} ok={out['ok']} url={page.url} "
                f"text_head={(out.get('text') or '')[:80]!r}"
            )


def _warn_if_lexical(conn) -> None:
    """FoodKeeper search degrades to keyword-only when the corpus isn't embedded — say so."""
    from . import embeddings, reference

    if embeddings.is_configured() and not reference.has_embeddings(conn):
        console.print(
            "[yellow]note[/] FoodKeeper embeddings are missing for this model, so search is "
            "keyword-only. Run `food embed-ref` for hybrid search."
        )


def _run_classify(conn, limit: int | None = None) -> dict:
    """Canonicalize pending items and resolve each item's shelf life, in one pass."""
    from . import canonicalize, llm

    if not conn.execute("SELECT 1 FROM shelf_life_ref LIMIT 1").fetchone():
        console.print(
            "[yellow]note[/] FoodKeeper reference is empty — run `food sync-ref`. "
            "Shelf lives will fall back to the model/web."
        )
    _warn_if_lexical(conn)
    try:
        stats = canonicalize.canonicalize(conn, limit)
    except llm.LLMError as e:
        console.print(f"[red]{e}[/]")
        raise typer.Exit(1)
    console.print(
        f"[green]canonicalized[/] {stats['ok']} items "
        f"({stats['batches']} batches, {stats['fallback']} unparsed); "
        f"[green]shelf life[/] {stats['resolved']} resolved"
    )
    return stats


@app.command("classify")
def classify(limit: Optional[int] = typer.Option(None, help="Max items to canonicalize")) -> None:
    """Canonicalize unmapped receipt items, resolving each item's shelf life in one pass."""
    conn = _conn()
    _run_classify(conn, limit)
    conn.close()


@app.command("resolve")
def resolve_command(
    refresh: bool = typer.Option(
        False, "--refresh", help="Re-resolve every food item, including ones that already have a shelf life"
    ),
    ids: Optional[str] = typer.Option(None, help="Comma-separated product ids to limit to"),
    limit: Optional[int] = typer.Option(None, help="Max items to resolve"),
) -> None:
    """(Re)resolve shelf lives for stored products — fill gaps, or refresh the whole catalogue."""
    from . import resolve as resolver

    conn = _conn()
    _warn_if_lexical(conn)
    sql = "SELECT id, canonical_name AS name, category, storage FROM products WHERE is_food = 1"
    params: list = []
    if ids:
        selected = [int(x) for x in ids.split(",") if x.strip()]
        sql += f" AND id IN ({','.join('?' * len(selected))})"
        params += selected
    elif not refresh:
        # default: only the gaps — perishable-looking food that never got a shelf life
        sql += " AND shelf_life_days IS NULL AND (is_perishable = 1 OR storage IN ('fridge','freezer'))"
    sql += " ORDER BY id"
    if limit:
        sql += f" LIMIT {int(limit)}"

    items = [dict(r) for r in conn.execute(sql, params)]
    if not items:
        console.print("nothing to resolve")
        conn.close()
        return
    applied = resolver.apply(conn, items, resolver.resolve_batch(conn, items))
    conn.close()
    console.print(f"[green]resolved[/] {applied} of {len(items)} items")


def _run_stock(conn, show_archived: bool = False) -> None:
    """Build/refresh the virtual fridge & pantry, then show what's about to go bad."""
    from . import inventory

    created = inventory.build(conn)
    res = inventory.refresh_status(conn)
    soon = inventory.expiring_soon(conn, days=3)
    active_rows = inventory.active(conn, include_archived=show_archived)
    console.print(
        f"[green]inventory[/]: {created} new rows "
        f"({res['expired']} expired, {res['archived']} archived); {len(active_rows)} active"
    )
    console.print(f"[bold]expiring within 3 days[/]: {len(soon)}")
    for r in soon[:20]:
        console.print(f"   {r['expires_on']}  {r['canonical_name']}  [{r['location']}]")


@app.command("stock")
def stock(show_archived: bool = typer.Option(False, help="Include archived rows")) -> None:
    """Build/refresh the virtual fridge & pantry, then show what's about to go bad."""
    conn = _conn()
    _run_stock(conn, show_archived)
    conn.close()


def _reachable_urls(host: str, port: int) -> list[str]:
    import socket

    urls = []
    if host in ("0.0.0.0", "::", ""):
        try:
            s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            s.connect(("8.8.8.8", 80))
            urls.append(f"http://{s.getsockname()[0]}:{port}")
            s.close()
        except Exception:  # noqa: BLE001 - offline is fine
            pass
        urls.insert(0, f"http://127.0.0.1:{port}")
    else:
        urls.append(f"http://{host}:{port}")
    return urls


def _serve(host: str, port: int) -> None:
    """Run the dashboard (blocking)."""
    import uvicorn

    from .web.app import app as webapp

    for url in _reachable_urls(host, port):
        console.print(f"[green]dashboard[/] {url}")
    if host in ("0.0.0.0", "::", ""):
        console.print(
            "[yellow]note[/] reachable by anyone on this network — there is no login. "
            "Prefer Tailscale over a public tunnel."
        )
    uvicorn.run(webapp, host=host, port=port, log_level="warning")


@app.command("serve")
def serve(
    port: int = typer.Option(8000, help="Port to bind"),
    host: str = typer.Option(
        "127.0.0.1",
        help="Bind address. Use 0.0.0.0 to reach it from your phone over LAN/Tailscale.",
    ),
) -> None:
    """Run the dashboard."""
    _serve(host, port)


@app.command("bootstrap")
def bootstrap(
    days: int = typer.Option(90, help="Days of receipt history to pull"),
    retailer: str = typer.Option("all", help="costco | kroger | all"),
    skip_ref: bool = typer.Option(False, "--skip-ref", help="Skip loading/embedding FoodKeeper"),
    cdp: Optional[str] = typer.Option(None, help="Attach to an existing Chrome via CDP URL"),
    serve_dash: bool = typer.Option(False, "--serve", help="Start the dashboard when setup finishes"),
    port: int = typer.Option(8000, help="Dashboard port (with --serve)"),
    host: str = typer.Option("127.0.0.1", help="Dashboard bind address (with --serve)"),
) -> None:
    """Fresh setup in one shot: schema, FoodKeeper reference, `days` of receipts, classify,
    inventory. Idempotent, so it is safe to re-run."""
    conn = _conn()
    if not skip_ref:
        console.rule("[bold]reference[/]")
        _load_reference(conn)
    console.rule("[bold]receipts[/]")
    _run_sync(conn, retailer, days, cdp)
    console.rule("[bold]classify[/]")
    _run_classify(conn)
    console.rule("[bold]inventory[/]")
    _run_stock(conn)
    conn.close()
    if serve_dash:
        _serve(host, port)


@app.command("refresh")
def refresh(
    retailer: str = typer.Option("all", help="costco | kroger | all"),
    lookback: Optional[int] = typer.Option(None, help="Override lookback window (days)"),
    cdp: Optional[str] = typer.Option(None, help="Attach to an existing Chrome via CDP URL"),
    serve_dash: bool = typer.Option(
        False, "--serve", help="Start the dashboard when the update finishes"
    ),
    port: int = typer.Option(8000, help="Dashboard port (with --serve)"),
    host: str = typer.Option("127.0.0.1", help="Dashboard bind address (with --serve)"),
) -> None:
    """Incremental update for an interval/cron: pull new receipts, classify, rebuild inventory.
    Assumes the reference is already loaded (see `bootstrap`)."""
    conn = _conn()
    console.rule("[bold]receipts[/]")
    _run_sync(conn, retailer, lookback, cdp)
    console.rule("[bold]classify[/]")
    _run_classify(conn)
    console.rule("[bold]inventory[/]")
    _run_stock(conn)
    conn.close()
    if serve_dash:
        _serve(host, port)


@app.command("digest")
def digest(days: int = typer.Option(3, help="Horizon in days")) -> None:
    """Ask the LLM for a 'use it or lose it' plan from what's expiring soonest."""
    from . import inventory, llm

    conn = _conn()
    soon = inventory.expiring_soon(conn, days=days)
    if not soon:
        console.print(f"[green]nothing expiring in {days} days[/]")
        conn.close()
        return
    listed = "\n".join(
        f"- {r['canonical_name']} x{r['remaining_qty']:g} [{r['location']}] (by {r['expires_on']})"
        for r in soon
    )
    try:
        text = llm.chat_text(
            conn,
            "digest",
            "You are a practical home cook. Given items about to expire, suggest what to make.",
            f"Use these up soon:\n{listed}\n\nSuggest a short plan.",
            use_cache=True,
        )
    except llm.LLMError as e:
        console.print(f"[red]{e}[/]")
        conn.close()
        raise typer.Exit(1)
    conn.close()
    console.print(text)


@app.command("status")
def status() -> None:
    """Show what's in the database so far."""
    from . import llm

    conn = _conn()
    for r in conn.execute("SELECT retailer, COUNT(*) c FROM receipts GROUP BY retailer"):
        console.print(f"receipts[{r['retailer']}] = {r['c']}")
    for label, sql in (
        ("receipt_items", "SELECT COUNT(*) c FROM receipt_items"),
        ("products", "SELECT COUNT(*) c FROM products"),
        ("inventory", "SELECT COUNT(*) c FROM inventory"),
        ("shelf_life_ref", "SELECT COUNT(*) c FROM shelf_life_ref"),
    ):
        try:
            rows = conn.execute(sql).fetchall()
        except Exception as e:  # schema not migrated yet
            console.print(f"{label}: [red]{e}[/]")
            continue
        console.print(f"{label} = {rows[0]['c'] if rows else 0}")

    for purpose in ("canonicalize", "resolve_jev", "chat", "digest"):
        console.print(f"llm_calls[{purpose}] today = {llm.calls_today(conn, purpose)}")
    from . import canonicalize

    console.print(f"pending canonicalization = {canonicalize.pending_count(conn)}")
    conn.close()


if __name__ == "__main__":
    app()

# Project handoff

_Last updated: 2026-10-22_

## Where things stand

The Python pipeline and the iOS app are at behavioral parity for the parts that matter:

- **Python**: Costco/Kroger ingest → normalize → canonicalize → batched shelf-life resolver →
  inventory → dashboard. Incremental follow-up syncs use a per-retailer watermark.
- **iOS**: same schema and stages on-device (`Sync.run`), plus a sync-progress banner that
  survives dismissing the browser sheet.
- **Parity verified**: resolver prompts/chunking/retries/apply rules, canonicalize batching,
  schema, snapshot output, and the Costco/Kroger date-window math. Last checks: `55 passed`
  (pytest), `23 passed` (Swift tests), iOS device build succeeds.
- **Costco**: full 90-day e2e run completed. The `idToken` lives ~12 minutes; loading
  `/myaccount/orders` mints a new one from the refresh cookie. The pipeline now waits for a
  valid token and retries once on 401 instead of asking for a login.
- **Data model**: see `docs/er.md`.

## Current blocker

Kroger is returning an Akamai rate limit:

```json
{"message": "Too many requests", "referenceNum": "...", "clientIP": "..."}
```

This is **IP-level throttling, not an account ban**. Stop all automated requests until the
window clears. Test once from a different network (cellular); if that works, the account is
fine. Do not retry from the blocked IP — it extends the block.

## Session handling

- `data/browser-profile` is a persistent Chrome profile.
- `data/session-state.json` (gitignored, mode `0600`) stores the full Playwright cookie jar,
  including session-only cookies, plus origin storage. It is restored at browser launch and
  saved after a confirmed login and after a successful pull.
- This is the fix for Kroger: `sid`, `JSESSIONID`, and `x-ms-cpim-sso` are session-only, so
  they vanished whenever Chrome closed. The year-long `loggedIn`/`bannerRememberMe` flags are
  UI state, not authentication. `RT` is an opaque 62-char first-party cookie, not the OAuth
  refresh token; it is not on the critical path.

## Pick up here

1. When the Kroger block clears, log in once with the capture window, then run a second sync
   with Chrome closed to confirm the restored cookie jar avoids the login.
2. Port the same persistence to iOS: capture full cookie properties and re-inject them into
   `WKWebsiteDataStore.default().httpCookieStore` on launch (Application Support or Keychain).
3. Make the Swift Kroger detail loop stop on 429/rate-limit markers instead of retrying every
   chunk; Python already does this.
4. Optional cleanup from the parity review:
   - Costco query in `WebModel` omits `itemDescription02`, `transactionDate`,
     `warehouseNumber`, `transactionNumber`, which the normalizer reads.
   - Swift resolver decoding is looser than Python's Pydantic validation (source/confidence/
     `is_perishable`).
   - Embedding corpus is sent as one request on iOS instead of batches of 64.

## Quick commands

Empty kitchen, without touching the real database:

```bash
TMP=$(mktemp -d)
export FOOD_DB_PATH="$TMP/food.db"
uv run food init-db
uv run food sync-ref
uv run food embed-ref
uv run food serve --port 8001
```

Import a raw payload fetched once (no browser login on the Python side):

```bash
uv run food import data/imports/<retailer>-<stamp>.json --retailer costco
uv run food classify
uv run food stock
```

iOS:

```bash
cd mobile/ios
xcodegen generate
# Secrets.env from Secrets.env.example (Debug builds only; never commit keys)
```

No provider keys or `.env` files are committed.

"""Central configuration, loaded from the environment / .env."""

from __future__ import annotations

import json
import os
from pathlib import Path

from dotenv import load_dotenv

load_dotenv()

ROOT = Path(__file__).resolve().parent.parent
# Canonical contract files live in the FoodCore resource bundle so Swift can load them
# without symlinks. The installed wheel maps that directory to `shared/`.
_RESOURCE_CONTRACT = ROOT / "mobile/ios/FoodCore/Sources/FoodCore/Resources"
SHARED_DIR = _RESOURCE_CONTRACT if _RESOURCE_CONTRACT.exists() else ROOT / "shared"


def _shared_json(name: str, default):
    try:
        return json.loads((SHARED_DIR / name).read_text())
    except (OSError, ValueError):
        return default


SHARED_CONFIG = _shared_json("config.json", {})
SHARED_PROMPTS = _shared_json("prompts.json", {})
SHARED_JEV = _shared_json("jev.json", {})

DATA_DIR = Path(os.getenv("FOOD_DATA_DIR", ROOT / "data"))
IMPORTS_DIR = DATA_DIR / "imports"
BROWSER_PROFILE_DIR = DATA_DIR / "browser-profile"
# Full cookie jar (including session-only cookies) saved after a successful login. Chromium
# does not persist session cookies to the profile, but Kroger's auth lives in them.
SESSION_STATE_PATH = DATA_DIR / "session-state.json"
DB_PATH = Path(os.getenv("FOOD_DB_PATH", DATA_DIR / "food.db"))

# LLM (Command Code Provider API)
CMD_API_KEY = os.getenv("CMD_API_KEY", "")
BASE_URL = os.getenv("FOOD_BASE_URL", "https://api.commandcode.ai/provider/v1")
# Benchmarked on this task: MiMo V2.6 Flash returned 30/30 valid items in 52s vs 89s
# (Muse Spark 1.3 Contributor) and 121s (Qwen 3.7 Flash), at $0.14/$0.28 per 1M.
MODEL = os.getenv("FOOD_MODEL", "xiaomi/mimo-v2.6-flash")
FALLBACK_MODELS = [
    m.strip()
    for m in os.getenv(
        "FOOD_FALLBACK_MODELS",
        "meta/muse-spark-1.3-contributor,Qwen/Qwen3.7-Flash,poolside/laguna-s-2.1-free",
    ).split(",")
    if m.strip()
]
CLASSIFY_WORKERS = int(
    os.getenv("FOOD_CLASSIFY_WORKERS", str(SHARED_CONFIG.get("classify_workers", 6)))
)
RESOLVE_WORKERS = int(
    os.getenv("FOOD_RESOLVE_WORKERS", str(SHARED_CONFIG.get("resolve_workers", 4)))
)
# Per-request controls: keep a slow generation from blocking the whole batch.
LLM_TIMEOUT_S = float(
    os.getenv("FOOD_LLM_TIMEOUT_S", str(SHARED_CONFIG.get("llm_timeout_s", 120)))
)
LLM_MAX_TOKENS = int(
    os.getenv("FOOD_LLM_MAX_TOKENS", str(SHARED_CONFIG.get("llm_max_tokens", 8192)))
)
LLM_MAX_CONNECTIONS = int(
    os.getenv("FOOD_LLM_MAX_CONNECTIONS", str(SHARED_CONFIG.get("llm_max_connections", 8)))
)

# Jev (TypeSafe's typed decision model) for final shelf-life selection. It is only
# used by the resolver, never by canonicalization. Uses the Command Code provider.
JEV_ENABLED = os.getenv(
    "FOOD_JEV_ENABLED", "1" if SHARED_CONFIG.get("jev_enabled", True) else "0"
).lower() in ("1", "true", "yes")
# Command Code's System One route; TypeSafeClassifier appends /v1/systemone.
JEV_BASE_URL = os.getenv(
    "FOOD_JEV_BASE_URL",
    SHARED_CONFIG.get("jev_base_url", "https://api.commandcode.ai/provider"),
)
JEV_MODEL = os.getenv(
    "FOOD_JEV_MODEL", SHARED_CONFIG.get("jev_model", "typesafe/jev-1.14.0")
)
JEV_TIMEOUT_S = float(
    os.getenv("FOOD_JEV_TIMEOUT_S", str(SHARED_CONFIG.get("jev_timeout_s", 8)))
)

# Embeddings (OpenRouter, OpenAI-compatible /embeddings). Defaults to a cheap paid model:
# the free tier caps at ~20 requests/min, which throttles per-item matching, and the paid
# model matched better in the benchmark anyway. Override with FOOD_EMBED_MODEL.
OPENROUTER_API_KEY = os.getenv("OPENROUTER_API_KEY", "")
EMBED_BASE_URL = os.getenv("FOOD_EMBED_BASE_URL", "https://openrouter.ai/api/v1")
EMBED_MODEL = os.getenv("FOOD_EMBED_MODEL", "baai/bge-base-en-v1.5")
EMBED_BATCH_SIZE = int(os.getenv("FOOD_EMBED_BATCH_SIZE", "64"))

# Optional observability: Arize Phoenix. Needs `uv sync --group tracing`; off by default.
PHOENIX_ENABLED = os.getenv("PHOENIX_ENABLED", "").lower() in ("1", "true", "yes")
PHOENIX_PROJECT = os.getenv("PHOENIX_PROJECT", "food")
# Blank means the local Phoenix (http://localhost:6006); set for Phoenix Cloud.
PHOENIX_ENDPOINT = os.getenv("PHOENIX_COLLECTOR_ENDPOINT", "http://localhost:6006/v1/traces")

# Ingestion
COSTCO_LOOKBACK_DAYS = int(os.getenv("FOOD_COSTCO_LOOKBACK_DAYS", "90"))
KROGER_LOOKBACK_DAYS = int(os.getenv("FOOD_KROGER_LOOKBACK_DAYS", "90"))

# Budgets / decay
CHAT_DAILY_BUDGET = int(os.getenv("FOOD_CHAT_DAILY_BUDGET", "30"))
ARCHIVE_AFTER_DAYS = int(os.getenv("FOOD_ARCHIVE_AFTER_DAYS", "14"))

# Reference data. The official host is Akamai-blocked from some networks, so we fall
# back to byte-identical GitHub mirrors of the same FMA-Data-v128 dataset.
FOODKEEPER_URL = os.getenv(
    "FOODKEEPER_URL", "https://www.fsis.usda.gov/shared/data/EN/foodkeeper.json"
)
FOODKEEPER_MIRRORS = [
    "https://raw.githubusercontent.com/jfarrar1/FoodKeeper-API/master/foodkeeper.json",
    "https://raw.githubusercontent.com/iamademar/fusentra/main/data/raw/foodkeeper/foodkeeper.json",
    "https://raw.githubusercontent.com/jaimedmar/fusentra/main/data/raw/foodkeeper/foodkeeper.json",
]
BROWSER_UA = os.getenv(
    "FOOD_BROWSER_UA",
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
)


def ensure_dirs() -> None:
    for d in (DATA_DIR, IMPORTS_DIR, BROWSER_PROFILE_DIR):
        d.mkdir(parents=True, exist_ok=True)

"""LLM plumbing built on LangChain.

Each configured model becomes a `ChatOpenAI` runnable. They are wrapped with `.with_retry`
for transient failures and chained with `.with_fallbacks`, so a 429 or error transparently
falls through to the next model and the caller sees a single runnable. Every call is
recorded in `llm_calls` so per-purpose budgets can be enforced; chat/digest responses are
cached in `prompt_cache`.
"""

from __future__ import annotations

import hashlib
import json
import sqlite3
from typing import Any

from langchain_core.messages import HumanMessage, SystemMessage
from langchain_openai import ChatOpenAI

from . import config


class LLMError(RuntimeError):
    pass


def _text(content: Any) -> str:
    """Flatten an AIMessage content payload (str, or a list of content blocks) to text."""
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        parts: list[str] = []
        for block in content:
            if isinstance(block, str):
                parts.append(block)
            elif isinstance(block, dict) and block.get("type") == "text":
                parts.append(block.get("text", ""))
        return "".join(parts)
    return str(content or "")


def _cache_key(system: str, user: str) -> str:
    return hashlib.sha256(f"{system}\x00{user}".encode()).hexdigest()


def extract_json(text: str) -> dict:
    """Free models wrap JSON in prose or fences; pull out the first object."""
    t = (text or "").strip()
    if t.startswith("```"):
        t = t.split("```", 2)[1]
        if t.startswith("json"):
            t = t[4:]
    start = t.find("{")
    end = t.rfind("}")
    if start == -1 or end == -1 or end < start:
        raise ValueError(f"no JSON object found in: {text[:200]!r}")
    return json.loads(t[start : end + 1])


def calls_today(conn: sqlite3.Connection, purpose: str | None = None) -> int:
    if purpose:
        row = conn.execute(
            "SELECT COUNT(*) n FROM llm_calls WHERE date(created_at) = date('now') AND purpose = ?",
            (purpose,),
        ).fetchone()
    else:
        row = conn.execute(
            "SELECT COUNT(*) n FROM llm_calls WHERE date(created_at) = date('now')"
        ).fetchone()
    return row["n"]


def _model(model: str, temperature: float) -> ChatOpenAI:
    return ChatOpenAI(
        model=model,
        api_key=config.CMD_API_KEY,
        base_url=config.BASE_URL,
        temperature=temperature,
        max_retries=2,
    ).with_retry(stop_after_attempt=3, wait_exponential_jitter=True)


def _chain(models: list[str], temperature: float):
    if not config.CMD_API_KEY:
        raise LLMError(
            "CMD_API_KEY is not set. Create one in Command Code Studio -> API keys and put it "
            "in .env as CMD_API_KEY=..."
        )
    runs = [_model(m, temperature) for m in models]
    primary, *rest = runs
    return primary.with_fallbacks(rest) if rest else primary


def _record(conn: sqlite3.Connection, purpose: str, msg: Any) -> None:
    meta = getattr(msg, "usage_metadata", None) or {}
    rmeta = getattr(msg, "response_metadata", None) or {}
    conn.execute(
        "INSERT INTO llm_calls (purpose, model, prompt_tokens, completion_tokens) VALUES (?, ?, ?, ?)",
        (
            purpose,
            rmeta.get("model_name"),
            meta.get("input_tokens"),
            meta.get("output_tokens"),
        ),
    )


def chat_json(
    conn: sqlite3.Connection,
    purpose: str,
    system: str,
    user: str,
    models: list[str] | None = None,
    use_cache: bool = False,
    temperature: float = 0.0,
) -> dict:
    """Call the fallback chain, returning parsed JSON. `use_cache` is for chat/digest only —
    classification is cached via `item_map` instead."""
    models = models or [config.MODEL, *config.FALLBACK_MODELS]
    key = _cache_key(system, user)
    if use_cache:
        row = conn.execute(
            "SELECT response_json FROM prompt_cache WHERE cache_key = ?", (key,)
        ).fetchone()
        if row:
            return json.loads(row["response_json"])

    try:
        msg = _chain(models, temperature).invoke(
            [SystemMessage(system), HumanMessage(user)]
        )
    except Exception as e:  # noqa: BLE001 - surface as a domain error
        raise LLMError(f"all models failed ({models}): {e}") from e

    data = extract_json(_text(getattr(msg, "content", "")))
    _record(conn, purpose, msg)
    if use_cache:
        conn.execute(
            "INSERT OR REPLACE INTO prompt_cache (cache_key, response_json) VALUES (?, ?)",
            (key, json.dumps(data)),
        )
    conn.commit()
    return data


def chat_text(
    conn: sqlite3.Connection,
    purpose: str,
    system: str,
    user: str,
    models: list[str] | None = None,
    use_cache: bool = False,
    temperature: float = 0.2,
) -> str:
    """Free-form text response (chat). Same fallback + accounting as `chat_json`."""
    models = models or [config.MODEL, *config.FALLBACK_MODELS]
    key = _cache_key(system, user)
    if use_cache:
        row = conn.execute(
            "SELECT response_json FROM prompt_cache WHERE cache_key = ?", (key,)
        ).fetchone()
        if row:
            return json.loads(row["response_json"])

    try:
        msg = _chain(models, temperature).invoke(
            [SystemMessage(system), HumanMessage(user)]
        )
    except Exception as e:  # noqa: BLE001 - surface as a domain error
        raise LLMError(f"all models failed ({models}): {e}") from e

    text = _text(getattr(msg, "content", "")).strip()
    _record(conn, purpose, msg)
    if use_cache:
        conn.execute(
            "INSERT OR REPLACE INTO prompt_cache (cache_key, response_json) VALUES (?, ?)",
            (key, json.dumps(text)),
        )
    conn.commit()
    return text


def models_available() -> list[str]:
    return [config.MODEL, *config.FALLBACK_MODELS]

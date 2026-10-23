"""LLM plumbing built on LangChain.

Each configured model becomes a `ChatOpenAI` runnable. They are wrapped with `.with_retry`
for transient failures and chained with `.with_fallbacks`; a 429 is surfaced instead of
being retried across models. Every call is recorded in `llm_calls` so per-purpose budgets
can be enforced; chat/digest responses are cached in `prompt_cache`.
"""

from __future__ import annotations

import hashlib
import json
import sqlite3
from functools import lru_cache
from typing import Any

import httpx
from langchain_core.messages import HumanMessage, SystemMessage
from langchain_openai import ChatOpenAI
from openai import APIConnectionError, APITimeoutError, InternalServerError

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


# One keep-alive pool for every chat call. Creating a ChatOpenAI per batch was doing a new
# TLS handshake each time; this reuses connections across canonicalize and resolver calls.
_HTTP = httpx.Client(
    timeout=config.LLM_TIMEOUT_S,
    limits=httpx.Limits(
        max_connections=config.LLM_MAX_CONNECTIONS,
        max_keepalive_connections=config.LLM_MAX_CONNECTIONS,
    ),
)


@lru_cache(maxsize=None)
def _chat_model_cached(model: str, temperature: float, max_tokens: int) -> ChatOpenAI:
    if not config.CMD_API_KEY:
        raise LLMError(
            "CMD_API_KEY is not set. Create one in Command Code Studio -> API keys and put it "
            "in .env as CMD_API_KEY=..."
        )
    return ChatOpenAI(
        model=model,
        api_key=config.CMD_API_KEY,
        base_url=config.BASE_URL,
        temperature=temperature,
        max_tokens=max_tokens,
        timeout=config.LLM_TIMEOUT_S,
        max_retries=0,
        http_client=_HTTP,
    )


def chat_model(
    model: str | None = None, temperature: float = 0.0, max_tokens: int | None = None
) -> ChatOpenAI:
    """A cached ChatOpenAI. For callers that need a chat model rather than a chain
    (agents, tool-calling). The shared instance reuses the httpx connection pool."""
    return _chat_model_cached(
        model or config.MODEL, temperature, max_tokens or config.LLM_MAX_TOKENS
    )


@lru_cache(maxsize=None)
def _model_cached(model: str, temperature: float, max_tokens: int):
    return chat_model(model, temperature, max_tokens).with_retry(
        retry_if_exception_type=(APIConnectionError, APITimeoutError, InternalServerError),
        stop_after_attempt=3,
        wait_exponential_jitter=True,
    )


@lru_cache(maxsize=None)
def _chain_cached(models: tuple[str, ...], temperature: float, max_tokens: int):
    runs = [_model_cached(m, temperature, max_tokens) for m in models]
    primary, *rest = runs
    if not rest:
        return primary
    # Fall back on transport/5xx errors, but not on a 429: retrying a rate limit across
    # the same provider is exactly what we want to avoid.
    return primary.with_fallbacks(
        rest,
        exceptions_to_handle=(APIConnectionError, APITimeoutError, InternalServerError),
    )


def _chain(models: list[str], temperature: float = 0.0):
    return _chain_cached(tuple(models), temperature, config.LLM_MAX_TOKENS)


def is_rate_limit_error(exc: BaseException) -> bool:
    """True for HTTP 429 / provider rate limits, which we must not blindly retry."""
    status = getattr(exc, "status_code", None)
    if status is None:
        response = getattr(exc, "response", None)
        status = getattr(response, "status_code", None)
    if status == 429:
        return True
    text = str(exc).lower()
    return "429" in text or "rate limit" in text or "too many requests" in text


def retry_after_seconds(exc: BaseException) -> float | None:
    response = getattr(exc, "response", None)
    headers = getattr(response, "headers", None) or {}
    value = headers.get("retry-after") or headers.get("Retry-After")
    try:
        return float(value) if value is not None else None
    except (TypeError, ValueError):
        return None


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

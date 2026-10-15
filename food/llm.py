"""Command Code Provider API client.

OpenAI-compatible Chat Completions at `{BASE_URL}/chat/completions`, authenticated with a
Command Code API key. Free models are trialled in order; a 429 or error falls through to the
next. Every call is recorded in `llm_calls` so per-purpose budgets can be enforced.
"""

from __future__ import annotations

import hashlib
import json
import sqlite3
from typing import Any

from openai import OpenAI

from . import config


class LLMError(RuntimeError):
    pass


def _client() -> OpenAI:
    if not config.CMD_API_KEY:
        raise LLMError(
            "CMD_API_KEY is not set. Create one in Command Code Studio -> API keys and put it "
            "in .env as CMD_API_KEY=..."
        )
    return OpenAI(api_key=config.CMD_API_KEY, base_url=config.BASE_URL)


def _cache_key(model: str, system: str, user: str) -> str:
    return hashlib.sha256(f"{model}\x00{system}\x00{user}".encode()).hexdigest()


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


def chat_json(
    conn: sqlite3.Connection,
    purpose: str,
    system: str,
    user: str,
    models: list[str] | None = None,
    use_cache: bool = False,
    temperature: float = 0.0,
) -> dict:
    """Call the model, returning parsed JSON. `use_cache` is for chat/digest only —
    classification is cached via `item_map` instead."""
    models = models or [config.MODEL, *config.FALLBACK_MODELS]
    last: Exception | None = None

    for model in models:
        key = _cache_key(model, system, user)
        if use_cache:
            row = conn.execute(
                "SELECT response_json FROM prompt_cache WHERE cache_key = ?", (key,)
            ).fetchone()
            if row:
                return json.loads(row["response_json"])
        try:
            resp = _client().chat.completions.create(
                model=model,
                messages=[
                    {"role": "system", "content": system},
                    {"role": "user", "content": user},
                ],
                temperature=temperature,
            )
            data = extract_json(resp.choices[0].message.content or "")
        except Exception as e:  # noqa: BLE001 - try the next free model
            last = e
            continue

        usage = getattr(resp, "usage", None)
        conn.execute(
            "INSERT INTO llm_calls (purpose, model, prompt_tokens, completion_tokens) VALUES (?, ?, ?, ?)",
            (
                purpose,
                model,
                getattr(usage, "prompt_tokens", None),
                getattr(usage, "completion_tokens", None),
            ),
        )
        if use_cache:
            conn.execute(
                "INSERT OR REPLACE INTO prompt_cache (cache_key, response_json) VALUES (?, ?)",
                (key, json.dumps(data)),
            )
        conn.commit()
        return data

    raise LLMError(f"all models failed ({models}): {last}")


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
    last: Exception | None = None

    for model in models:
        key = _cache_key(model, system, user)
        if use_cache:
            row = conn.execute(
                "SELECT response_json FROM prompt_cache WHERE cache_key = ?", (key,)
            ).fetchone()
            if row:
                return json.loads(row["response_json"])
        try:
            resp = _client().chat.completions.create(
                model=model,
                messages=[
                    {"role": "system", "content": system},
                    {"role": "user", "content": user},
                ],
                temperature=temperature,
            )
            text = (resp.choices[0].message.content or "").strip()
        except Exception as e:  # noqa: BLE001 - try the next model
            last = e
            continue

        usage = getattr(resp, "usage", None)
        conn.execute(
            "INSERT INTO llm_calls (purpose, model, prompt_tokens, completion_tokens) VALUES (?, ?, ?, ?)",
            (
                purpose,
                model,
                getattr(usage, "prompt_tokens", None),
                getattr(usage, "completion_tokens", None),
            ),
        )
        if use_cache:
            conn.execute(
                "INSERT OR REPLACE INTO prompt_cache (cache_key, response_json) VALUES (?, ?)",
                (key, json.dumps(text)),
            )
        conn.commit()
        return text

    raise LLMError(f"all models failed ({models}): {last}")


def models_available() -> list[str]:
    return [config.MODEL, *config.FALLBACK_MODELS]

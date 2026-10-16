"""Embeddings via the OpenRouter API (OpenAI-compatible `/embeddings`).

The default model is free, so a small credit balance is never touched; a paid model is
opt-in through `FOOD_EMBED_MODEL`. When no key is configured the client reports itself
unavailable and callers fall back to lexical-only retrieval. Requests are batched to stay
well under the provider's free-tier request limits.
"""

from __future__ import annotations

from typing import Sequence

from openai import OpenAI

from . import config


class EmbeddingError(RuntimeError):
    pass


def is_configured() -> bool:
    return bool(config.OPENROUTER_API_KEY)


def model_name() -> str:
    return config.EMBED_MODEL


def _client() -> OpenAI:
    if not config.OPENROUTER_API_KEY:
        raise EmbeddingError(
            "OPENROUTER_API_KEY is not set. Add one to .env to enable semantic search."
        )
    return OpenAI(api_key=config.OPENROUTER_API_KEY, base_url=config.EMBED_BASE_URL)


def embed(
    texts: Sequence[str],
    model: str | None = None,
    batch_size: int | None = None,
) -> list[list[float]]:
    """Embed `texts`, preserving input order, batching to limit request count."""
    if not texts:
        return []
    model = model or config.EMBED_MODEL
    batch_size = batch_size or config.EMBED_BATCH_SIZE
    client = _client()
    out: list[list[float]] = []
    for i in range(0, len(texts), batch_size):
        chunk = list(texts[i : i + batch_size])
        resp = client.embeddings.create(model=model, input=chunk)
        # sort by index so a provider that reorders does not scramble the results
        for item in sorted(resp.data, key=lambda d: d.index):
            out.append(list(item.embedding))
    return out

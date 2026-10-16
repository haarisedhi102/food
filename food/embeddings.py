"""Embedding configuration shared by the retrieval layer.

The actual embedding calls are made through LangChain's `OpenAIEmbeddings` against the
OpenRouter endpoint (see `reference.py`). This module only holds the bits callers need to
reason about availability and the model name.
"""

from __future__ import annotations

from . import config


class EmbeddingError(RuntimeError):
    pass


def is_configured() -> bool:
    return bool(config.OPENROUTER_API_KEY)


def model_name() -> str:
    return config.EMBED_MODEL

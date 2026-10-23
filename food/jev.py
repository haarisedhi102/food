"""Jev through LangChain's TypeSafe integration.

Using `TypeSafeClassifier` (a LangChain `Runnable`) means the existing OpenInference
LangChain instrumentation carries Jev decisions into Phoenix automatically, and LangSmith
gets its dedicated decision view when tracing is enabled there.

Chat and Jev both use the Command Code provider; OpenRouter remains embeddings-only.
"""

from __future__ import annotations

from functools import lru_cache
from typing import Any

from langchain_typesafe import Choice, Noul, Score, TypeSafeClassifier

from . import config


class JevError(RuntimeError):
    pass


def is_configured() -> bool:
    return config.JEV_ENABLED and bool(config.CMD_API_KEY)


@lru_cache(maxsize=None)
def _classifier() -> TypeSafeClassifier:
    return TypeSafeClassifier(
        model=config.JEV_MODEL,
        api_key=config.CMD_API_KEY,
        # TypeSafeClassifier appends /v1/systemone.
        base_url=config.JEV_BASE_URL,
        timeout=config.JEV_TIMEOUT_S,
    )


def _to_question(q: dict[str, Any]):
    kind = q.get("type")
    if kind == "noul":
        return Noul(instructions=q["instructions"])
    if kind == "choice":
        return Choice(instructions=q["instructions"], criteria=q["criteria"])
    if kind == "score":
        return Score(instructions=q["instructions"], criteria=q["criteria"])
    raise JevError(f"unsupported Jev question type: {kind!r}")


def decide(state: dict[str, Any], questions: dict[str, Any]) -> dict[str, Any]:
    """One typed decision request, returned in the Decisions-API shape used by the resolver."""
    if not is_configured():
        raise JevError("Jev is not configured (FOOD_JEV_ENABLED / CMD_API_KEY)")
    payload = {
        "state": state,
        "questions": {key: _to_question(q) for key, q in questions.items()},
    }
    try:
        response = _classifier().invoke(payload)
    except Exception as e:  # noqa: BLE001 - the resolver leaves items pending
        raise JevError(f"Jev request failed: {e}") from e

    answers: dict[str, Any] = {}
    for key, answer in (response.nouls or {}).items():
        answers[key] = {"type": "noul", "noul": answer.noul}
    for key, answer in (response.choices or {}).items():
        answers[key] = {
            "type": "choice",
            "choice": answer.choice,
            "confidence": answer.confidence,
            "probabilities": answer.probabilities,
        }
    for key, answer in (response.scores or {}).items():
        answers[key] = {
            "type": "score",
            "score": answer.score,
            "confidence": answer.confidence,
            "probabilities": answer.probabilities,
        }

    usage = response.usage
    if usage is not None and hasattr(usage, "model_dump"):
        usage = usage.model_dump()
    return {
        "model": response.model,
        "answers": answers,
        "usage": usage,
        "request_id": response.request_id,
    }

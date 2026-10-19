"""Optional Arize Phoenix tracing, so every LLM call is visible in a local Phoenix UI.

Off unless `PHOENIX_ENABLED=1`. Install the extras once with `uv sync --group tracing`,
run `uv run phoenix serve`, then start any `food` command. Auto-instrumentation picks up
whichever OpenInference instrumentors are installed — the plain OpenAI client used today
and the LangChain stack both get traced.
"""

from __future__ import annotations

from . import config

_configured = False


def setup() -> bool:
    """Register a Phoenix tracer and auto-instrument installed libraries. Idempotent.

    Returns True the first time it wires tracing up, False when disabled or unavailable.
    """
    global _configured
    if _configured or not config.PHOENIX_ENABLED:
        return False
    try:
        from phoenix.otel import register
    except ImportError:
        return False

    register(
        project_name=config.PHOENIX_PROJECT,
        endpoint=config.PHOENIX_ENDPOINT or None,
        auto_instrument=True,
    )
    _configured = True
    return True

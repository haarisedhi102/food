import pytest

from food import llm


class _Msg:
    def __init__(self, content):
        self.content = content
        self.usage_metadata = {"input_tokens": 3, "output_tokens": 5}
        self.response_metadata = {"model_name": "test-model"}


class _Chain:
    def __init__(self, content):
        self.content = content

    def invoke(self, messages):
        return _Msg(self.content)


def test_chat_json_parses_and_records(conn, monkeypatch):
    monkeypatch.setattr(llm, "_chain", lambda models, temp: _Chain('here you go:\n```json\n{"a": 1}\n```'))
    out = llm.chat_json(conn, "canonicalize", "sys", "user")
    assert out == {"a": 1}
    assert llm.calls_today(conn, "canonicalize") == 1


def test_chat_json_caches_when_asked(conn, monkeypatch):
    calls = {"n": 0}

    def chain(models, temp):
        calls["n"] += 1
        return _Chain('{"a": 1}')

    monkeypatch.setattr(llm, "_chain", chain)
    llm.chat_json(conn, "digest", "sys", "u", use_cache=True)
    llm.chat_json(conn, "digest", "sys", "u", use_cache=True)
    assert calls["n"] == 1  # second call served from prompt_cache


def test_chat_text_returns_stripped_text(conn, monkeypatch):
    monkeypatch.setattr(llm, "_chain", lambda models, temp: _Chain("  hello  "))
    assert llm.chat_text(conn, "chat", "sys", "u") == "hello"


def test_all_models_failing_raises_domain_error(conn, monkeypatch):
    def boom(models, temp):
        raise RuntimeError("429")

    monkeypatch.setattr(llm, "_chain", boom)
    with pytest.raises(llm.LLMError):
        llm.chat_json(conn, "canonicalize", "sys", "u")

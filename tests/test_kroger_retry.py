import pytest
from tenacity import wait_none

from food.ingest import kroger


class _DummyPage:
    url = "https://www.kroger.com/mypurchases"

    def goto(self, *args, **kwargs):
        pass

    def wait_for_timeout(self, *args):
        pass


@pytest.fixture(autouse=True)
def _fast_retries(monkeypatch):
    # no real backoff sleeps in tests
    monkeypatch.setattr(kroger, "WAIT", wait_none())
    monkeypatch.setattr(kroger, "_assert_origin", lambda page: None)
    monkeypatch.setattr(kroger, "_reorigin", lambda page, n: None)


def _good():
    return {
        "status": 200,
        "ok": True,
        "json": {"data": {"purchaseHistoryDetails": [{"items": []}]}},
        "text": "",
    }


def _bad(status=500, text="oops"):
    return {"status": status, "ok": False, "json": None, "text": text}


def test_retries_transient_failure_then_succeeds(monkeypatch):
    calls = {"n": 0}

    def fake_fetch(*args, **kwargs):
        calls["n"] += 1
        return _bad() if calls["n"] < 3 else _good()

    monkeypatch.setattr(kroger.b, "page_fetch", fake_fetch)
    res = kroger._fetch_details(_DummyPage(), "[]", 1, 1)
    assert res["status"] == 200
    assert calls["n"] == 3


def test_gives_up_after_max_attempts(monkeypatch):
    calls = {"n": 0}

    def fake_fetch(*args, **kwargs):
        calls["n"] += 1
        return _bad()

    monkeypatch.setattr(kroger.b, "page_fetch", fake_fetch)
    res = kroger._fetch_details(_DummyPage(), "[]", 1, 1)
    assert calls["n"] == kroger.MAX_ATTEMPTS
    assert res["status"] == 500  # last result surfaced, not an exception


def test_rate_limit_is_not_retried(monkeypatch):
    calls = {"n": 0}

    def fake_fetch(*args, **kwargs):
        calls["n"] += 1
        return _bad(429, "Too Many Requests")

    monkeypatch.setattr(kroger.b, "page_fetch", fake_fetch)
    res = kroger._fetch_details(_DummyPage(), "[]", 1, 1)
    assert calls["n"] == 1
    assert res["status"] == 429

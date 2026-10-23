from datetime import date

from food.ingest.costco import _window

TODAY = date(2026, 10, 19)


def test_first_sync_uses_the_full_lookback():
    assert _window(90, since=None, today=TODAY) == (date(2026, 7, 21), TODAY)


def test_since_starts_two_days_earlier_for_late_posts():
    assert _window(90, since=date(2026, 10, 10), today=TODAY) == (date(2026, 10, 8), TODAY)


def test_since_never_goes_past_the_lookback_floor():
    assert _window(30, since=date(2026, 1, 1), today=TODAY) == (date(2026, 9, 19), TODAY)


def test_since_in_the_future_clamps_to_today():
    assert _window(90, since=date(2026, 12, 1), today=TODAY) == (TODAY, TODAY)

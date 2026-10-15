import json
import sqlite3
from pathlib import Path

import pytest

from food import db, shelflife

FIXTURE = Path(__file__).parent / "fixtures" / "foodkeeper_sample.json"


def _mem() -> sqlite3.Connection:
    conn = sqlite3.connect(":memory:")
    conn.row_factory = sqlite3.Row
    db.init_db(conn)
    return conn


@pytest.mark.parametrize(
    "minv,maxv,metric,expected",
    [
        (1, 2, "Weeks", 7),
        (3, 5, "Days", 3),
        (1, 2, "Months", 30),
        (3, 5, "Weeks", 21),
        (1, 1, "Indefinitely", None),
        (None, None, "Package use-by date", None),
        (3, 5, "Days", 3),  # conservative: earliest plausible spoilage
    ],
)
def test_to_days(minv, maxv, metric, expected):
    assert shelflife.to_days(minv, maxv, metric) == expected


def test_load_and_days_for():
    conn = _mem()
    n = shelflife.load(conn, payload=json.loads(FIXTURE.read_text()))
    assert n == 4

    # Eggs: DOP_Refrigerate 3-5 weeks -> 21 days
    assert shelflife.days_for(conn, 21, "fridge") == 21
    # Milk: metric is qualitative -> unknown (falls through to the LLM)
    assert shelflife.days_for(conn, 27, "fridge") is None
    # Milk freeze DOP: 3 months -> 90 days
    assert shelflife.days_for(conn, 27, "freezer") == 90
    # Yogurt: 1-2 weeks -> 7 days, opened -> 1 day
    assert shelflife.days_for(conn, 33, "fridge") == 7
    assert shelflife.days_for(conn, 33, "fridge", opened=True) == 1
    # Onions live in the pantry
    assert shelflife.days_for(conn, 294, "pantry") == 30
    # unknown id
    assert shelflife.days_for(conn, 99999, "fridge") is None


def test_search_candidates():
    conn = _mem()
    shelflife.load(conn, payload=json.loads(FIXTURE.read_text()))

    ids = [c["foodkeeper_id"] for c in shelflife.search_candidates(conn, "Jumbo Yellow Onions")]
    assert 294 in ids

    ids = [c["foodkeeper_id"] for c in shelflife.search_candidates(conn, "Kroger Yogurt")]
    assert 33 in ids

    # A heavily abbreviated Costco string has no local match -> LLM must decide.
    assert shelflife.search_candidates(conn, "KS ORG A2 PR") == []


def test_parse_foodkeeper_categories():
    products, categories = shelflife.parse_foodkeeper(json.loads(FIXTURE.read_text()))
    assert len(products) == 4
    assert categories[7] == "Dairy Products & Eggs"
    assert categories[18] == "Produce / Fresh Fruits"

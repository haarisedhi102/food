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


def test_load():
    conn = _mem()
    assert shelflife.load(conn, payload=json.loads(FIXTURE.read_text())) == 4


def test_parse_foodkeeper_categories():
    products, categories = shelflife.parse_foodkeeper(json.loads(FIXTURE.read_text()))
    assert len(products) == 4
    assert categories[7] == "Dairy Products & Eggs"
    assert categories[18] == "Produce / Fresh Fruits"

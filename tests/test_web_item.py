import sqlite3

import pytest
from fastapi.testclient import TestClient

import importlib

from food import db

web = importlib.import_module("food.web.app")


@pytest.fixture
def client(tmp_path, monkeypatch):
    path = tmp_path / "food.db"
    conn = db.connect(path)
    db.init_db(conn)
    conn.execute(
        """INSERT INTO products
           (id, canonical_name, is_food, is_perishable, storage, shelf_life_days)
           VALUES (1, 'Milk', 1, 1, 'fridge', NULL)"""
    )
    conn.execute(
        """INSERT INTO inventory (product_id, quantity, remaining_qty, acquired_on, status)
           VALUES (1, 1, 1, '2026-10-21', 'active')"""
    )
    conn.commit()
    conn.close()

    monkeypatch.setattr(web, "_conn", lambda: db.connect(path))
    with TestClient(web.app) as test_client:
        yield test_client, path


def _product(path):
    conn = sqlite3.connect(path)
    conn.row_factory = sqlite3.Row
    try:
        return conn.execute("SELECT * FROM products WHERE id = 1").fetchone()
    finally:
        conn.close()


def _expiry(path):
    conn = sqlite3.connect(path)
    try:
        return conn.execute(
            "SELECT expires_on FROM inventory WHERE product_id = 1"
        ).fetchone()[0]
    finally:
        conn.close()


def test_shelf_life_save_pins_value_and_updates_expiry(client):
    test_client, path = client

    response = test_client.post(
        "/item/1/shelf-life", data={"days": "7"}, follow_redirects=False
    )

    assert response.status_code == 303
    product = _product(path)
    assert product["shelf_life_days"] == 7
    assert product["shelf_life_source"] == "user"
    assert product["needs_review"] == 0
    assert _expiry(path) == "2026-10-28"


def test_shelf_life_validation_and_missing_product(client):
    test_client, _ = client

    assert test_client.post(
        "/item/1/shelf-life", data={"days": "0"}, follow_redirects=False
    ).status_code == 400
    assert test_client.post(
        "/item/999/shelf-life", data={"days": "7"}, follow_redirects=False
    ).status_code == 404


def test_review_flag_and_clear(client):
    test_client, path = client

    assert test_client.post(
        "/item/1/review", data={}, follow_redirects=False
    ).status_code == 303
    assert _product(path)["needs_review"] == 1

    assert test_client.post(
        "/item/1/review", data={"clear": "true"}, follow_redirects=False
    ).status_code == 303
    assert _product(path)["needs_review"] == 0

    assert test_client.post(
        "/item/999/review", data={}, follow_redirects=False
    ).status_code == 404

"""Schema-drift guards.

These assert the exact field paths the parsers depend on. When a retailer changes their
undocumented payload, one of these fails loudly instead of the pipeline silently producing
empty data.
"""

import json
from pathlib import Path

import pytest

FIX = Path(__file__).parent / "fixtures"


def _load(name):
    return json.loads((FIX / name).read_text())


def test_costco_receipt_shape():
    raw = _load("costco_sample.redacted.json")
    receipts = raw["data"]["receiptsWithCounts"]["receipts"]
    assert receipts, "no receipts in fixture"

    r = receipts[0]
    for field in ("transactionBarcode", "transactionDateTime", "warehouseName", "total", "itemArray"):
        assert field in r, f"Costco receipt lost field {field!r}"

    item = r["itemArray"][0]
    for field in ("itemNumber", "itemDescription01", "unit", "amount", "itemUnitPriceAmount"):
        assert field in item, f"Costco item lost field {field!r}"


def test_kroger_search_shape():
    raw = _load("kroger_sample.redacted.json")
    rec = raw["search"][0]
    for field in ("receiptKey", "purchaseType", "createdDateTime", "total", "lineItems"):
        assert field in rec, f"Kroger search record lost field {field!r}"
    assert "value" in rec["createdDateTime"]


def test_kroger_detail_shape():
    raw = _load("kroger_sample.redacted.json")
    batch = next(iter(raw["details"].values()))["json"]
    receipts = batch["data"]["purchaseHistoryDetails"]
    assert receipts, "no receipts in details batch"

    r = receipts[0]
    assert (r.get("purchaseId") or {}).get("receiptId"), "detail receipt lost purchaseId.receiptId"

    item = r["items"][0]
    pd = item["purchasedData"]
    for field in ("upc", "displayInfo", "pricingInfo", "quantityInfo"):
        assert field in pd, f"Kroger item lost purchasedData.{field}"


@pytest.mark.parametrize(
    "path",
    [
        ("purchasedData", "displayInfo", "description"),
        ("purchasedData", "pricingInfo", "totalPricePaid"),
        ("purchasedData", "quantityInfo", "received"),
    ],
)
def test_kroger_item_leaf_fields(path):
    raw = _load("kroger_sample.redacted.json")
    batch = next(iter(raw["details"].values()))["json"]
    item = batch["data"]["purchaseHistoryDetails"][0]["items"][0]
    node = item
    for key in path:
        assert key in node, f"missing {'.'.join(path)}"
        node = node[key]

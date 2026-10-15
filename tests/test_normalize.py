import json
from pathlib import Path

from food import normalize

FIX = Path(__file__).parent / "fixtures"


def test_costco_normalize_drops_discounts_and_keys_on_item_number():
    raw = json.loads((FIX / "costco_sample.redacted.json").read_text())
    receipts = normalize.normalize_costco(raw)

    assert len(receipts) == 1
    r = receipts[0]
    assert r["purchased_on"] and len(r["purchased_on"]) == 10
    assert r["items"], "expected at least one item"

    for item in r["items"]:
        assert not item["raw_description"].startswith("/")  # discount lines removed
        assert item["item_key"]  # keyed on itemNumber (or a described fallback)

    # the fixture contains a "/ <item>" discount line; it must not survive
    raw_items = raw["data"]["receiptsWithCounts"]["receipts"][0]["itemArray"]
    assert len(r["items"]) < len(raw_items)


def test_kroger_attributes_only_the_matching_receipt():
    """Regression: a details batch returns one receipt per key, and each carries
    purchaseId.receiptId. We must map each key to its own receipt, not spread the whole
    batch across every key."""
    raw = json.loads((FIX / "kroger_sample.redacted.json").read_text())
    receipts = normalize.normalize_kroger(raw)

    assert len(receipts) == 1
    r = receipts[0]

    batch = raw["details"][next(iter(raw["details"]))]["json"]["data"]["purchaseHistoryDetails"]
    total_in_batch = sum(len(x.get("items") or []) for x in batch)
    matching = next(
        x for x in batch if (x.get("purchaseId") or {}).get("receiptId") == r["external_id"]
    )

    assert len(r["items"]) == len(matching["items"])
    assert len(r["items"]) < total_in_batch, "items leaked from other receipts in the batch"
    for item in r["items"]:
        assert item["item_key"]  # keyed on upc

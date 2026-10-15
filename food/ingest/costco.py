"""Costco in-warehouse receipts via the internal GraphQL API."""

from __future__ import annotations

import json
from datetime import date, timedelta
from typing import Any

from . import browser as b

GRAPHQL_URL = "https://ecom-api.costco.com/ebusiness/order/v1/orders/graphql"

# Public values shipped inside Costco's own browser bundle (not secrets).
WCS_CLIENT_ID = "4900eb1f-0c10-4bd9-99c3-c59e6c1ecebf"
CLIENT_IDENTIFIER = "481b1aec-aa3b-454b-b81b-48187e28f205"

LOGGED_IN_JS = "() => !!localStorage.getItem('idToken')"

QUERY = """
query receiptsWithCounts($startDate: String!, $endDate: String!, $documentType: String!, $documentSubType: String!) {
  receiptsWithCounts(startDate: $startDate, endDate: $endDate, documentType: $documentType, documentSubType: $documentSubType) {
    inWarehouse
    gasStation
    carWash
    gasAndCarWash
    receipts {
      transactionBarcode
      transactionDate
      transactionDateTime
      transactionType
      documentType
      receiptType
      warehouseName
      warehouseNumber
      warehouseCity
      warehouseState
      membershipNumber
      total
      subTotal
      totalItemCount
      itemArray {
        itemNumber
        itemDescription01
        itemDescription02
        itemIdentifier
        itemDepartmentNumber
        transDepartmentNumber
        unit
        amount
        itemUnitPriceAmount
        taxFlag
      }
    }
  }
}
"""


def _headers(id_token: str) -> dict[str, str]:
    return {
        "Content-Type": "application/json-patch+json",
        "Accept": "*/*",
        "costco-x-authorization": f"Bearer {id_token}",
        "costco-x-wcs-clientid": WCS_CLIENT_ID,
        "client-identifier": CLIENT_IDENTIFIER,
        "costco.env": "ecom",
        "costco.service": "restOrders",
    }


def pull(lookback_days: int, document_type: str = "warehouse", cdp: str | None = None) -> dict:
    start = date.today() - timedelta(days=lookback_days)
    end = date.today()
    # Warehouse receipts expect M/D/YYYY (no zero padding).
    variables = {
        "startDate": f"{start.month}/{start.day}/{start.year}",
        "endDate": f"{end.month}/{end.day}/{end.year}",
        "documentType": document_type,
        "documentSubType": "all",
    }

    with b.browser(cdp=cdp) as ctx:
        page = ctx.pages[0] if ctx.pages else ctx.new_page()
        b.ensure_login(
            page,
            "https://www.costco.com/",
            LOGGED_IN_JS,
            "Log into Costco (MFA may be required).",
        )
        tok = page.evaluate(
            "() => ({ idToken: localStorage.getItem('idToken'), clientID: localStorage.getItem('clientID') })"
        )
        if not tok.get("idToken"):
            raise RuntimeError("No Costco idToken in localStorage — login did not stick.")
        print("    pulling Costco receipts ...")
        res = b.page_fetch(
            page,
            GRAPHQL_URL,
            method="POST",
            headers=_headers(tok["idToken"]),
            body=json.dumps({"query": QUERY, "variables": variables}),
        )
        if not res["ok"]:
            raise RuntimeError(f"Costco GraphQL failed: HTTP {res['status']} {res['text'][:500]}")
        return res["json"]


def extract_receipts(payload: Any) -> list[dict]:
    """Return the raw receipt list from the response, handling both known shapes."""
    if not isinstance(payload, dict):
        return []
    node = (payload.get("data") or {}).get("receiptsWithCounts")
    if node is None:
        return []
    if isinstance(node, list):  # some deployments answer with a bare array
        receipts: list[Any] = node
    else:
        receipts = node.get("receipts") or []
    return [r for r in receipts if isinstance(r, dict)]

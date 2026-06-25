"""Vivid Seats Broker Webservices API client (read-only).

Host: https://brokers.vividseats.com/webservices/v1
Auth: ?apiToken=<token> query param. Token in vault as VIVID_API_TOKEN.
Format: XML responses (parsed to flat dicts here for parity with the
original Unified-Order-Suite client — Vivid's broker XML is shallow and
the suite always reads it that way).

Endpoints used:
  GET /getOrders                       list broker orders (filterable via
                                       ?status=, e.g. 'PENDING_SHIPMENT')
  GET /getPendingRetransferOrders      orders awaiting retransfer
  GET /getOrder                        single-order detail (?orderId=...)

Imported from JulianS4K/Unified-Order-Suite. The original suite included
a fulfillment write (POST /transferOrderViaURL); that endpoint is NOT
imported here. Vivid Seats orders are in the same RULE 2 read-only
bucket as the Evo /v9/orders and SG /sales feeds — `brokers.vividseats.com`
is on the FORBIDDEN_HOSTS allowlist in scripts/check_readonly.py and
this module appears in CLIENT_FILES.
"""
from __future__ import annotations

from defusedxml import ElementTree as ET
from typing import Any

from broker_http import get_with_retry


# RULE 2 — READ-ONLY against brokers.vividseats.com.
# Vivid Seats orders are part of the orders/sales bucket alongside Evo
# and SG. Any non-GET attempt raises before a network call is made. The
# runtime guard pairs with the static check in scripts/check_readonly.py
# and the unit tests in tests/test_readonly_guards.py.
ALLOWED_HTTP_METHODS = frozenset({"GET"})


class VividError(RuntimeError):
    pass


class VividReadOnlyError(VividError):
    """Raised when a non-GET method is attempted against Vivid Seats."""


def _assert_readonly_method(method: str) -> None:
    if method.upper() not in ALLOWED_HTTP_METHODS:
        raise VividReadOnlyError(
            f"READ-ONLY violation: method {method} is not allowed. "
            "Vivid Seats client is read-only by design (RULE 2 spirit). "
            "Pulling data only — never write back to brokers.vividseats.com."
        )


class VividClient:
    BASE_URL = "https://brokers.vividseats.com/webservices/v1"

    def __init__(self, api_token: str, *, timeout: int = 30):
        if not api_token:
            raise VividError("Vivid Seats apiToken is required")
        self.api_token = (api_token or "").strip()
        self.timeout = timeout

    # ---------- transport ----------

    def _get(self, path: str, params: dict | None = None) -> bytes:
        _assert_readonly_method("GET")  # RULE 2 enforcement
        url = f"{self.BASE_URL}{path}"
        clean: dict[str, Any] = {"apiToken": self.api_token}
        for k, v in (params or {}).items():
            if v is not None:
                clean[k] = v
        # Unified retry/backoff (broker_http.get_with_retry): exponential
        # backoff honoring Retry-After across the canonical transient set
        # (429/502/503/504). Previously this loop only backed off on 429/503.
        r = get_with_retry(url, params=clean, timeout=self.timeout)
        if not r.ok:
            raise VividError(f"HTTP {r.status_code}")
        return r.content

    # ---------- XML helpers ----------

    @staticmethod
    def _flatten(elem: ET.Element) -> dict[str, str]:
        return {c.tag: (c.text.strip() if c.text else "") for c in elem}

    @classmethod
    def _parse_orders(cls, xml_bytes: bytes) -> list[dict[str, str]]:
        """Parse <orders><order>...</order></orders> to a list of flat dicts.
        Nested structure is intentionally collapsed (matches the upstream
        Unified-Order-Suite reader)."""
        try:
            root = ET.fromstring(xml_bytes)
        except ET.ParseError:
            return []
        return [cls._flatten(order) for order in root.findall("order")]

    @classmethod
    def _parse_single_order(cls, xml_bytes: bytes) -> dict[str, str]:
        """Parse a single-<order> XML response (e.g. /getOrder) to a flat dict."""
        try:
            root = ET.fromstring(xml_bytes)
        except ET.ParseError:
            return {}
        return cls._flatten(root)

    # ---------- Orders ----------

    def list_orders(
        self,
        *,
        status: str | None = "PENDING_SHIPMENT",
        **extra: Any,
    ) -> list[dict[str, str]]:
        """GET /getOrders — broker orders. Defaults to status=PENDING_SHIPMENT
        (the filter the Unified-Order-Suite uses). Pass status=None to omit."""
        xml = self._get("/getOrders", {"status": status, **extra})
        return self._parse_orders(xml)

    def list_pending_retransfer_orders(self) -> list[dict[str, str]]:
        """GET /getPendingRetransferOrders — orders awaiting retransfer."""
        xml = self._get("/getPendingRetransferOrders")
        return self._parse_orders(xml)

    def list_active_orders(self) -> list[dict[str, str]]:
        """Pending shipment + pending retransfer, deduped by orderId.
        Mirrors the Unified-Order-Suite fetch_vivid combined view."""
        combined = self.list_orders() + self.list_pending_retransfer_orders()
        unique: dict[str, dict[str, str]] = {}
        for row in combined:
            oid = row.get("orderId")
            if oid:
                unique[oid] = row
        return list(unique.values())

    def get_order(self, order_id: int) -> dict[str, str]:
        """GET /getOrder — single-order detail."""
        xml = self._get("/getOrder", {"orderId": int(order_id)})
        return self._parse_single_order(xml)

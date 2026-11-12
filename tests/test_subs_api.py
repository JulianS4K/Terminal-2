"""Tests for the sub finder API (routers/subs_api.py, /api/v1/subs).

Pins: the key check (X-API-Key or Bearer, 401 / rate limit / quota), input validation before
anything reaches SQL, the exact RPC arguments, and how a SQL answer maps to an HTTP status.
The matching itself is SQL (mig 20261112000000) and is exercised against Postgres separately.
"""
from __future__ import annotations

import pytest

fastapi = pytest.importorskip("fastapi")
from fastapi import FastAPI  # noqa: E402
from fastapi.testclient import TestClient  # noqa: E402

from routers import subs_api as s  # noqa: E402
from routers.mcp_api import hash_key  # noqa: E402

KEY = "s4k_crm_test"
JOB = "3f0c2a0e-1b7d-4c55-9a53-0d6f1f0a9b11"
ORDER = {"order_number": "659213629", "site": "Viagogo", "tevo_event_id": 3241050,
         "section": "217", "row": "G", "qty": 2, "sold_ea": 125.72}


class _Rpc:
    def __init__(self, db, name, args):
        self.db, self.name, self.args = db, name, args

    def execute(self):
        self.db.rpcs.append((self.name, self.args))
        if self.name in self.db.errors:
            raise self.db.errors[self.name]
        if self.name == "mcp_verify_key":
            ok = self.args["p_key_hash"] == hash_key(KEY)
            return type("R", (), {"data": [dict(self.db.key_row)] if ok else []})()
        return type("R", (), {"data": self.db.rpc_data.get(self.name)})()


class FakeDB:
    def __init__(self, rpc_data=None, errors=None, key_row=None):
        self.rpc_data, self.errors = rpc_data or {}, errors or {}
        self.key_row = {"id": 7, "label": "crm", "tier": "external"} if key_row is None else key_row
        self.rpcs = []

    def rpc(self, name, args):
        return _Rpc(self, name, args)

    def last(self, name):
        return [a for n, a in self.rpcs if n == name][-1]


class _Limiter:
    def __init__(self, allow=True):
        self.allow, self.calls = allow, []

    def check(self, *a):
        self.calls.append(a)
        return self.allow


def _client(db, limiter=None):
    app = FastAPI()
    app.include_router(s.make_router(lambda: db, limiter=limiter))
    return TestClient(app)


H = {"x-api-key": KEY}


# ---------------------------------------------------------------- pure helpers

def test_clean_order_accepts_id_or_name_and_date():
    row, why = s.clean_order(dict(ORDER, tevo_event_id="3241050"), 0)
    assert why is None and row == {"order_number": "659213629", "site": "Viagogo", "venue": None,
                                   "section": "217", "row": "G", "qty": 2, "sold_ea": 125.72,
                                   "tevo_event_id": 3241050}
    by_name = {"order_number": "A-1", "event_name": " Utah at Arizona ", "event_date": "2026-11-14",
               "section": "19", "row": "5", "qty": "2"}
    row, why = s.clean_order(by_name, 0)
    assert why is None and row["event_name"] == "Utah at Arizona" and row["event_date"] == "2026-11-14"
    assert row["sold_ea"] is None and "tevo_event_id" not in row


@pytest.mark.parametrize("patch, needle", [
    ({"order_number": ""}, "order_number"),
    ({"order_number": "a b;c"}, "order_number"),
    ({"order_number": {"x": 1}}, "order_number"),
    ({"section": " "}, "section and row"),
    ({"row": None}, "section and row"),
    ({"qty": 0}, "qty"),
    ({"qty": "two"}, "qty"),
    ({"qty": True}, "qty"),
    ({"qty": 51}, "qty"),
    ({"sold_ea": "x"}, "sold_ea"),
    ({"sold_ea": 0}, "sold_ea"),
    ({"sold_ea": True}, "sold_ea"),
    ({"tevo_event_id": "abc"}, "tevo_event_id"),
    ({"tevo_event_id": True}, "tevo_event_id"),
    ({"tevo_event_id": None}, "event_name"),
    ({"tevo_event_id": None, "event_name": "X", "event_date": "11/14/26"}, "event_date"),
])
def test_clean_order_refusals(patch, needle):
    row, why = s.clean_order(dict(ORDER, **patch), 3)
    assert row is None and needle in why and "orders[3]" in why


def test_clean_order_not_an_object():
    assert s.clean_order("x", 1) == (None, "orders[1] must be an object")


def test_parse_instant():
    assert s.parse_instant(None) == (None, True) and s.parse_instant("  ") == (None, True)
    assert s.parse_instant("2026-11-12T19:54:00Z") == ("2026-11-12T19:54:00+00:00", True)
    assert s.parse_instant("2026-11-12T14:54:00-05:00") == ("2026-11-12T19:54:00+00:00", True)
    assert s.parse_instant("2026-11-12T19:54:00") == ("2026-11-12T19:54:00+00:00", True)  # no zone = UTC
    assert s.parse_instant("yesterday") == (None, False)


# ---------------------------------------------------------------- auth

def test_auth_refusals():
    db = FakeDB()
    c = _client(db)
    assert c.get("/api/v1/subs/ping").status_code == 401
    assert c.get("/api/v1/subs/ping", headers={"x-api-key": "nope"}).status_code == 401
    # a key lookup that blows up is a refusal, not a 500
    assert _client(FakeDB(errors={"mcp_verify_key": RuntimeError("db")})).get(
        "/api/v1/subs/ping", headers=H).status_code == 401
    assert _client(FakeDB(key_row={"label": "no id"})).get("/api/v1/subs/ping", headers=H).status_code == 401


def test_rate_limit_and_quota():
    lim = _Limiter(allow=False)
    r = _client(FakeDB(key_row={"id": 7, "rate_per_min": 5}), limiter=lim).get("/api/v1/subs/ping", headers=H)
    assert r.status_code == 429 and r.json() == {"error": "rate_limited", "retry_after_seconds": 60,
                                                 "rate_per_min": 5}
    assert lim.calls == [("subs:7", 5, 60.0)]
    r = _client(FakeDB(key_row={"id": 7, "daily_quota": 3, "calls_today": 3})).get("/api/v1/subs/ping", headers=H)
    assert r.status_code == 429 and r.json()["error"] == "quota_exhausted"


def test_ping_scopes_bearer_and_usage_stamp_never_fails():
    db = FakeDB(rpc_data={"sub_finder_access": {"find": True, "buy": False, "max_orders_per_job": 50}},
                errors={"mcp_count_call": RuntimeError("stamp")})
    r = _client(db, limiter=_Limiter()).get("/api/v1/subs/ping", headers={"authorization": f"Bearer {KEY}"})
    body = r.json()
    assert r.status_code == 200 and body["scopes"] == ["subs:find"] and body["max_orders_per_job"] == 50
    assert body["key_label"] == "crm" and body["generated_at"].endswith("Z")
    assert db.last("mcp_count_call") == {"p_key_id": 7, "p_tool": "subs.ping"}
    # no access row at all -> no scopes, the module ceiling
    body = _client(FakeDB()).get("/api/v1/subs/ping", headers=H).json()
    assert body["scopes"] == [] and body["max_orders_per_job"] == s.MAX_ORDERS


# ---------------------------------------------------------------- submit

def test_submit_passes_clean_rows_and_idempotency_key():
    db = FakeDB(rpc_data={"sub_finder_submit": {"job_id": JOB, "status": "pulling", "order_count": 1}})
    r = _client(db).post("/api/v1/subs/jobs", headers=dict(H, **{"idempotency-key": " sheet-new-1 "}),
                         json={"orders": [ORDER]})
    assert r.status_code == 202 and r.json()["job_id"] == JOB
    args = db.last("sub_finder_submit")
    assert args["p_key_id"] == 7 and args["p_key_label"] == "crm" and args["p_idempotency_key"] == "sheet-new-1"
    assert args["p_orders"] == [{"order_number": "659213629", "site": "Viagogo", "venue": None, "section": "217",
                                 "row": "G", "qty": 2, "sold_ea": 125.72, "tevo_event_id": 3241050}]
    # the body field works when there is no header
    _client(db).post("/api/v1/subs/jobs", headers=H, json={"orders": [ORDER], "idempotency_key": "b"})
    assert db.last("sub_finder_submit")["p_idempotency_key"] == "b"


def test_submit_refusals_never_reach_sql():
    db = FakeDB()
    c = _client(db)
    assert c.post("/api/v1/subs/jobs", json={"orders": [ORDER]}).status_code == 401
    for body in ({"orders": []}, {"orders": "x"}, [1], {"orders": [ORDER] * (s.MAX_ORDERS + 1)},
                 {"orders": [dict(ORDER, qty=0)]}):
        r = c.post("/api/v1/subs/jobs", headers=H, json=body)
        assert r.status_code == 422 and r.json()["error"] == "invalid"
    r = c.post("/api/v1/subs/jobs", headers=dict(H, **{"content-type": "application/json"}), content=b"{nope")
    assert r.status_code == 422
    assert not [n for n, _ in db.rpcs if n == "sub_finder_submit"]


def test_submit_sql_refusal_maps_to_status():
    db = FakeDB(rpc_data={"sub_finder_submit": {"error": "forbidden", "detail": "this key may not"}})
    r = _client(db).post("/api/v1/subs/jobs", headers=H, json={"orders": [ORDER]})
    assert r.status_code == 403 and r.json()["error"] == "forbidden"


# ---------------------------------------------------------------- read

def test_job_read():
    db = FakeDB(rpc_data={"sub_finder_job_json": {"job_id": JOB, "status": "done", "items": []}})
    c = _client(db)
    assert c.get(f"/api/v1/subs/jobs/{JOB}").status_code == 401
    r = c.get(f"/api/v1/subs/jobs/{JOB.upper()}", headers=H)
    assert r.status_code == 200 and r.json()["status"] == "done"
    assert db.last("sub_finder_job_json") == {"p_key_id": 7, "p_job_id": JOB}
    assert c.get("/api/v1/subs/jobs/not-a-uuid", headers=H).status_code == 404
    # NULL from SQL = not this key's job
    r = _client(FakeDB()).get(f"/api/v1/subs/jobs/{JOB}", headers=H)
    assert r.status_code == 404 and r.json()["error"] == "not_found"


def test_results_cursor_and_bounds():
    db = FakeDB(rpc_data={"sub_finder_results": {"count": 0, "total": 0, "items": [],
                                                 "generated_at": "2026-11-12T20:00:00.000000Z"}})
    c = _client(db)
    assert c.get("/api/v1/subs/results").status_code == 401
    r = c.get("/api/v1/subs/results", headers=H,
              params={"updated_since": "2026-11-12T19:54:00Z", "limit": 50, "offset": 100})
    assert r.status_code == 200 and r.json()["generated_at"].endswith("Z")
    assert db.last("sub_finder_results") == {"p_key_id": 7, "p_updated_since": "2026-11-12T19:54:00+00:00",
                                             "p_limit": 50, "p_offset": 100}
    c.get("/api/v1/subs/results", headers=H)
    assert db.last("sub_finder_results") == {"p_key_id": 7, "p_updated_since": None, "p_limit": 200,
                                             "p_offset": 0}
    for params in ({"updated_since": "soon"}, {"limit": 0}, {"limit": 1001}, {"offset": -1}):
        assert c.get("/api/v1/subs/results", headers=H, params=params).status_code == 422
    # an error code SQL may add later still answers as a client error, not a 200
    db.rpc_data["sub_finder_results"] = {"error": "something_new"}
    assert c.get("/api/v1/subs/results", headers=H).status_code == 400


# ---------------------------------------------------------------- buy

def test_buy_passes_through_and_maps_refusals():
    db = FakeDB(rpc_data={"sub_finder_buy": {"buy_id": 20, "state": "requested"}})
    c = _client(db)
    url = f"/api/v1/subs/jobs/{JOB}/orders/659213629/buy"
    assert c.post(url, json={"listing_id": "6833175743"}).status_code == 401
    r = c.post(url, headers=H, json={"listing_id": 6833175743, "requested_by": " dana "})
    assert r.status_code == 202 and r.json()["buy_id"] == 20
    assert db.last("sub_finder_buy") == {
        "p_key_id": 7, "p_key_label": "crm", "p_job_id": JOB, "p_order_number": "659213629",
        "p_listing_id": "6833175743", "p_requested_by": "dana"}
    for body in ({}, {"listing_id": "abc"}, [1]):
        assert c.post(url, headers=H, json=body).status_code == 422
    assert c.post(url, headers=dict(H, **{"content-type": "application/json"}), content=b"{").status_code == 422
    assert c.post(f"/api/v1/subs/jobs/{JOB}/orders/bad%20order/buy", headers=H,
                  json={"listing_id": "1"}).status_code == 422
    assert c.post("/api/v1/subs/jobs/nope/orders/659213629/buy", headers=H,
                  json={"listing_id": "1"}).status_code == 404
    for code, status in (("forbidden", 403), ("not_found", 404), ("conflict", 409), ("invalid", 422)):
        db.rpc_data["sub_finder_buy"] = {"error": code}
        assert c.post(url, headers=H, json={"listing_id": "1"}).status_code == status

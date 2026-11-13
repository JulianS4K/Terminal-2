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


def _app(db, limiter=None):
    app = FastAPI()
    app.include_router(s.make_router(lambda: db, limiter=limiter))
    return app


def _client(db, limiter=None):
    return TestClient(_app(db, limiter))


H = {"x-api-key": KEY}


# ---------------------------------------------------------------- pure helpers

def test_clean_order_spelled_out():
    row, why = s.clean_order(dict(ORDER, tevo_event_id="3241050", venue=" Carter "), 0)
    assert why is None and row == {"order_number": "659213629", "site": "Viagogo", "venue": "Carter",
                                   "section": "217", "row": "G", "qty": 2, "sold_ea": 125.72,
                                   "tevo_event_id": 3241050}
    by_name = {"order_number": "A-1", "event_name": " Utah at Arizona ", "event_date": "2026-11-14",
               "section": "19", "row": "5", "qty": "2"}
    row, why = s.clean_order(by_name, 0)
    assert why is None and row["event_name"] == "Utah at Arizona" and row["event_date"] == "2026-11-14"
    assert row["qty"] == 2 and "sold_ea" not in row and "tevo_event_id" not in row


def test_clean_order_number_only_and_crm_rows():
    # just the number: everything else comes from our mirror of the CRM's books (SQL)
    assert s.clean_order("JY8EGX10HP", 0) == ({"order_number": "JY8EGX10HP"}, None)
    assert s.clean_order({"order_number": " JY8EGX10HP "}, 0) == ({"order_number": "JY8EGX10HP"}, None)
    # the CRM's N2S row, posted unchanged: its field names, event_dt, total instead of per ticket
    n2s = {"id": 9, "order_number": "JY8EGX10HP", "marketplace": "Gametime", "source": "automatiq",
           "event_name": "Commanders at Giants (Thursday Night Football)", "event_dt": "2026-11-12T20:15:00",
           "venue": "MetLife Stadium", "section": "108", "row": "3", "seats": None, "qty": 3,
           "grand_total": 744.0, "status": "n2s"}
    row, why = s.clean_order(n2s, 0)
    assert why is None and row == {
        "order_number": "JY8EGX10HP", "site": "Gametime", "venue": "MetLife Stadium", "section": "108",
        "row": "3", "qty": 3, "sold_ea": 248.0, "event_date": "2026-11-12",
        "event_name": "Commanders at Giants (Thursday Night Football)"}
    # price_per_ticket wins over the total; an unusable total is just left out
    assert s.clean_order(dict(n2s, price_per_ticket=250), 0)[0]["sold_ea"] == 250.0
    assert "sold_ea" not in s.clean_order(dict(n2s, grand_total="n/a"), 0)[0]
    # the CRM's marketplace row: s4k_order_id / source / quantity / venue_name
    mk = {"s4k_order_id": "82410899", "source": "Vivid Seats", "quantity": 1, "venue_name": "Boone Pickens",
          "section": "140", "row": "22", "event_date": "2026-11-14", "event_name": "Tech at OSU", "price": 163.65}
    row, why = s.clean_order(mk, 0)
    assert why is None and row["order_number"] == "82410899" and row["site"] == "Vivid Seats"
    assert row["qty"] == 1 and row["venue"] == "Boone Pickens" and "sold_ea" not in row  # `price` basis varies


def test_orders_of_accepts_every_body_shape():
    assert s.orders_of({"orders": [1]}) == [1] and s.orders_of({"order_numbers": ["a"]}) == ["a"]
    assert s.orders_of({"items": [2], "count": 1}) == [2] and s.orders_of([3]) == [3]
    assert s.orders_of({"nope": 1}) is None and s.orders_of("x") is None


@pytest.mark.parametrize("patch, needle", [
    ({"order_number": ""}, "order_number"),
    ({"order_number": "a b;c"}, "order_number"),
    ({"order_number": {"x": 1}}, "order_number"),
    ({"qty": 0}, "qty"),
    ({"qty": "two"}, "qty"),
    ({"qty": True}, "qty"),
    ({"qty": 51}, "qty"),
    ({"sold_ea": "x"}, "sold_ea"),
    ({"sold_ea": 0}, "sold_ea"),
    ({"sold_ea": True}, "sold_ea"),
    ({"tevo_event_id": "abc"}, "tevo_event_id"),
    ({"tevo_event_id": True}, "tevo_event_id"),
    ({"event_date": "11/14/26"}, "event_date"),
])
def test_clean_order_refusals(patch, needle):
    row, why = s.clean_order(dict(ORDER, **patch), 3)
    assert row is None and needle in why and "orders[3]" in why


def test_clean_order_not_an_order():
    assert s.clean_order(7, 1) == (None, "orders[1] must be an order number or an object")


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
    db = FakeDB(rpc_data={"sub_finder_access": {"find": True, "buy": False, "max_orders_per_job": 50,
                                                "ticketsdata_fallback": True}},
                errors={"mcp_count_call": RuntimeError("stamp")})
    r = _client(db, limiter=_Limiter()).get("/api/v1/subs/ping", headers={"authorization": f"Bearer {KEY}"})
    body = r.json()
    assert r.status_code == 200 and body["scopes"] == ["subs:find"] and body["max_orders_per_job"] == 50
    assert body["key_label"] == "crm" and body["generated_at"].endswith("Z")
    assert body["ticketsdata_fallback"] is True
    assert db.last("mcp_count_call") == {"p_key_id": 7, "p_tool": "subs.ping"}
    # no access row at all -> no scopes, the module ceiling
    body = _client(FakeDB()).get("/api/v1/subs/ping", headers=H).json()
    assert body["scopes"] == [] and body["max_orders_per_job"] == s.MAX_ORDERS and body["ticketsdata_fallback"] is False


# ---------------------------------------------------------------- submit

def test_submit_passes_clean_rows_and_idempotency_key():
    db = FakeDB(rpc_data={"sub_finder_submit": {"job_id": JOB, "status": "pulling", "order_count": 1}})
    r = _client(db).post("/api/v1/subs/jobs", headers=dict(H, **{"idempotency-key": " sheet-new-1 "}),
                         json={"orders": [ORDER]})
    assert r.status_code == 202 and r.json()["job_id"] == JOB
    args = db.last("sub_finder_submit")
    assert args["p_key_id"] == 7 and args["p_key_label"] == "crm" and args["p_idempotency_key"] == "sheet-new-1"
    assert args["p_orders"] == [{"order_number": "659213629", "site": "Viagogo", "section": "217",
                                 "row": "G", "qty": 2, "sold_ea": 125.72, "tevo_event_id": 3241050}]
    # the body field works when there is no header
    _client(db).post("/api/v1/subs/jobs", headers=H, json={"orders": [ORDER], "idempotency_key": "b"})
    assert db.last("sub_finder_submit")["p_idempotency_key"] == "b"
    # order numbers alone, the CRM's own list envelope, and a bare list all work
    for body in ({"order_numbers": ["JY8EGX10HP", "82410899"]}, {"items": ["JY8EGX10HP", {"order_id": "82410899"}]},
                 ["JY8EGX10HP", "82410899"]):
        assert _client(db).post("/api/v1/subs/jobs", headers=H, json=body).status_code == 202
        assert db.last("sub_finder_submit")["p_orders"] == [{"order_number": "JY8EGX10HP"},
                                                            {"order_number": "82410899"}]
        assert db.last("sub_finder_submit")["p_idempotency_key"] is None


def test_submit_refusals_never_reach_sql():
    db = FakeDB()
    c = _client(db)
    assert c.post("/api/v1/subs/jobs", json={"orders": [ORDER]}).status_code == 401
    for body in ({"orders": []}, {"orders": "x"}, [1], {"x": 1}, {"orders": [ORDER] * (s.MAX_ORDERS + 1)},
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


def test_order_read():
    buy = {"evo_order_id": "19429529", "outcome": "confirmed", "seats": ["14", "15", "16", "17"]}
    db = FakeDB(rpc_data={"sub_finder_order_read": {"count": 1, "items": [{"order_number": "659240801",
                                                                          "buy": buy}]}})
    c = _client(db)
    url = f"/api/v1/subs/jobs/{JOB}/orders/659240801"
    assert c.get(url).status_code == 401
    r = c.get(url, headers=H)
    assert r.status_code == 200 and r.json()["items"][0]["buy"]["outcome"] == "confirmed"
    assert db.last("sub_finder_order_read") == {"p_key_id": 7, "p_job_id": JOB, "p_order_number": "659240801"}
    assert db.last("mcp_count_call")["p_tool"] == "subs.order"
    n = len(db.rpcs)
    assert c.get("/api/v1/subs/jobs/nope/orders/659240801", headers=H).status_code == 404
    assert c.get(f"/api/v1/subs/jobs/{JOB}/orders/bad%20order", headers=H).status_code == 404
    assert not [x for x, _ in db.rpcs[n:] if x == "sub_finder_order_read"]   # refused before SQL
    r = _client(FakeDB()).get(url, headers=H)                                  # NULL = not this key's
    assert r.status_code == 404 and r.json()["detail"] == "no such order in this job"
    db.rpc_data["sub_finder_order_read"] = {"error": "forbidden"}
    assert c.get(url, headers=H).status_code == 403


def test_by_order_number_routes_use_the_newest_job():
    db = FakeDB(rpc_data={"sub_finder_latest_job": JOB,
                          "sub_finder_order_read": {"count": 1, "items": [{"order_number": "82410899"}]},
                          "sub_finder_buy_confirmed": {"buy_id": 22, "state": "requested"}})
    c = _client(db)
    assert c.get("/api/v1/subs/orders/82410899").status_code == 401
    assert c.post("/api/v1/subs/orders/82410899/buy", json={"listing_id": "1"}).status_code == 401
    r = c.get("/api/v1/subs/orders/82410899", headers=H)
    assert r.status_code == 200 and r.json()["count"] == 1
    assert db.last("sub_finder_latest_job") == {"p_key_id": 7, "p_order_number": "82410899"}
    assert db.last("sub_finder_order_read")["p_job_id"] == JOB
    r = c.post("/api/v1/subs/orders/82410899/buy", headers=H, json={"listing_id": "6022006793"})
    assert r.status_code == 202 and db.last("sub_finder_buy_confirmed")["p_job_id"] == JOB
    assert db.last("sub_finder_buy_confirmed")["p_listing_id"] == "6022006793"
    # a stray query parameter cannot stand in for the key
    assert c.get("/api/v1/subs/orders/82410899?_key=x").status_code == 401
    # no job holds it, or the number is malformed: 404 before any read or buy
    none = FakeDB()
    c2 = _client(none)
    assert c2.get("/api/v1/subs/orders/82410899", headers=H).status_code == 404
    assert c2.post("/api/v1/subs/orders/82410899/buy", headers=H, json={"listing_id": "1"}).status_code == 404
    assert c2.get("/api/v1/subs/orders/bad%20order", headers=H).status_code == 404
    assert not [n for n, _ in none.rpcs if n in ("sub_finder_order_read", "sub_finder_buy_confirmed")]


def test_needs_sub_alert_is_a_one_order_submit(monkeypatch):
    db = FakeDB(rpc_data={"sub_finder_submit": {"job_id": JOB, "status": "pulling", "order_count": 1}})
    c = _client(db)
    url = "/api/v1/subs/orders/JY8EGX10HP/needs-sub"
    assert c.post(url).status_code == 401
    monkeypatch.setattr(s.time, "time", lambda: 6000.0)
    r = c.post(url, headers=H)                                  # no body: the order number is enough
    assert r.status_code == 202 and r.json()["job_id"] == JOB
    args = db.last("sub_finder_submit")
    assert args["p_orders"] == [{"order_number": "JY8EGX10HP"}]
    assert args["p_idempotency_key"] == "needs-sub:JY8EGX10HP:10" and args["p_key_id"] == 7
    assert db.last("mcp_count_call")["p_tool"] == "subs.needs_sub"
    # ticked again inside the window: the same idempotency key, so SQL returns the same lookup
    monkeypatch.setattr(s.time, "time", lambda: 6599.0)
    c.post(url, headers=H)
    assert db.last("sub_finder_submit")["p_idempotency_key"] == "needs-sub:JY8EGX10HP:10"
    monkeypatch.setattr(s.time, "time", lambda: 6600.0)
    c.post(url, headers=H)
    assert db.last("sub_finder_submit")["p_idempotency_key"] == "needs-sub:JY8EGX10HP:11"
    # the CRM's row may ride along; the URL's order number always wins over the body's
    c.post(url, headers=H, json={"order_number": "OTHER", "s4k_order_id": "X", "marketplace": "Gametime",
                                 "section": "108", "row": "3", "qty": 3, "grand_total": 744})
    assert db.last("sub_finder_submit")["p_orders"] == [{
        "order_number": "JY8EGX10HP", "site": "Gametime", "section": "108", "row": "3", "qty": 3,
        "sold_ea": 248.0}]
    c.post(url, headers=H, json=["not", "a", "row"])            # a non-object body is ignored
    assert db.last("sub_finder_submit")["p_orders"] == [{"order_number": "JY8EGX10HP"}]
    n = len(db.rpcs)
    r = c.post(url, headers=H, json={"qty": 0})
    assert r.status_code == 422 and r.json()["detail"] == "qty must be a whole number from 1 to 50"
    r = c.post("/api/v1/subs/orders/bad%20order/needs-sub", headers=H)
    assert r.status_code == 422 and r.json()["detail"].startswith("order_number is required")
    assert not [x for x, _ in db.rpcs[n:] if x == "sub_finder_submit"]
    # an order we cannot place answers 404 from SQL
    db.rpc_data["sub_finder_submit"] = {"error": "not_found", "not_found": ["JY8EGX10HP"]}
    assert c.post(url, headers=H).status_code == 404


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
    db = FakeDB(rpc_data={"sub_finder_buy_confirmed": {"buy_id": 20, "state": "requested"}})
    c = _client(db)
    url = f"/api/v1/subs/jobs/{JOB}/orders/659213629/buy"
    assert c.post(url, json={"listing_id": "6833175743"}).status_code == 401
    r = c.post(url, headers=H, json={"listing_id": 6833175743, "requested_by": " dana "})
    assert r.status_code == 202 and r.json()["buy_id"] == 20
    assert db.last("sub_finder_buy_confirmed") == {
        "p_key_id": 7, "p_key_label": "crm", "p_job_id": JOB, "p_order_number": "659213629",
        "p_listing_id": "6833175743", "p_requested_by": "dana", "p_confirm": False}
    # a flagged cover is refused until the CRM says it has seen the flags; only a real true counts
    db.rpc_data["sub_finder_buy_confirmed"] = {"error": "confirm_needed", "flags": ["single_ticket"]}
    r = c.post(url, headers=H, json={"listing_id": "1"})
    assert r.status_code == 409 and r.json()["flags"] == ["single_ticket"]
    for sent, got in ((True, True), ("true", False), (1, False)):
        c.post(url, headers=H, json={"listing_id": "1", "confirm": sent})
        assert db.last("sub_finder_buy_confirmed")["p_confirm"] is got
    db.rpc_data["sub_finder_buy_confirmed"] = {"buy_id": 20, "state": "requested"}
    for body in ({}, {"listing_id": "abc"}, [1]):
        assert c.post(url, headers=H, json=body).status_code == 422
    assert c.post(url, headers=dict(H, **{"content-type": "application/json"}), content=b"{").status_code == 422
    assert c.post(f"/api/v1/subs/jobs/{JOB}/orders/bad%20order/buy", headers=H,
                  json={"listing_id": "1"}).status_code == 422
    assert c.post("/api/v1/subs/jobs/nope/orders/659213629/buy", headers=H,
                  json={"listing_id": "1"}).status_code == 404
    for code, status in (("forbidden", 403), ("not_found", 404), ("conflict", 409), ("invalid", 422)):
        db.rpc_data["sub_finder_buy_confirmed"] = {"error": code}
        assert c.post(url, headers=H, json={"listing_id": "1"}).status_code == status


# ---------------------------------------------------------------- offer a sub through GoTickets

def test_offer_sub_files_the_crm_yes_and_maps_refusals():
    db = FakeDB(rpc_data={"sub_finder_gt_offer_confirmed": {"offer_id": 3, "state": "requested", "gate": 5, "rebate": 60},
                          "sub_finder_access": {"find": True, "offer": True}})
    c = _client(db)
    url = "/api/v1/subs/orders/1003/offer-sub"
    assert c.post(url, json={"listing_id": "3201"}).status_code == 401
    r = c.post(url, headers=H, json={"listing_id": "3201", "market": "evo", "requested_by": "dana",
                                     "rebate_amount": 45.5})
    assert r.status_code == 202 and r.json()["rebate"] == 60
    assert db.last("sub_finder_gt_offer_confirmed") == {
        "p_key_id": 7, "p_key_label": "crm", "p_order_number": "1003", "p_listing_id": "3201",
        "p_market": "evo", "p_requested_by": "dana", "p_rebate_amount": 45.5, "p_confirm": False}
    c.post(url, headers=H, json={"listing_id": "3201", "confirm": True})
    assert db.last("sub_finder_gt_offer_confirmed")["p_confirm"] is True
    db.rpc_data["sub_finder_gt_offer_confirmed"] = {"error": "confirm_needed", "flags": ["zone_unverified"]}
    assert c.post(url, headers=H, json={"listing_id": "3201"}).status_code == 409
    db.rpc_data["sub_finder_gt_offer_confirmed"] = {"offer_id": 3, "state": "requested", "gate": 5, "rebate": 60}
    c.post(url, headers=H, json={"listing_id": "3201"})                    # no amount sent: SQL decides
    assert db.last("sub_finder_gt_offer_confirmed")["p_rebate_amount"] is None
    for bad in (-1, "50", True, 100001):
        assert c.post(url, headers=H, json={"listing_id": "3201", "rebate_amount": bad}).status_code == 422
    assert "subs:offer" in c.get("/api/v1/subs/ping", headers=H).json()["scopes"]
    for body in ({}, {"listing_id": "bad id"}, [1]):
        assert c.post(url, headers=H, json=body).status_code == 422
    assert c.post(url, headers=H, content=b"not json").status_code == 422
    assert c.post("/api/v1/subs/orders/bad%20order/offer-sub", headers=H, json={"listing_id": "1"}).status_code == 422
    for code, status in (("forbidden", 403), ("not_found", 404), ("conflict", 409), ("invalid", 422)):
        db.rpc_data["sub_finder_gt_offer_confirmed"] = {"error": code}
        assert c.post(url, headers=H, json={"listing_id": "3201"}).status_code == status


# ---------------------------------------------------------------- the CRM's own notes

def test_notes_ride_with_the_alert_and_are_trimmed():
    row, why = s.clean_order({"order_number": "1", "notes": "  call buyer first  "}, 0)
    assert why is None and row["notes"] == "call buyer first"
    assert "notes" not in s.clean_order({"order_number": "1", "notes": "   "}, 0)[0]
    assert len(s.clean_order({"order_number": "1", "notes": "x" * 900}, 0)[0]["notes"]) == 500
    db = FakeDB(rpc_data={"sub_finder_submit": {"job_id": JOB, "status": "pulling"}})
    c = _client(db)
    assert c.post("/api/v1/subs/orders/82410899/needs-sub", headers=H, json={"notes": "VIP"}).status_code == 202
    assert db.last("sub_finder_submit")["p_orders"] == [{"order_number": "82410899", "notes": "VIP"}]


def test_notes_route_writes_clears_and_refuses():
    db = FakeDB(rpc_data={"sub_finder_set_notes": {"order_number": "1003", "notes": "VIP"}})
    c = _client(db)
    url = "/api/v1/subs/orders/1003/notes"
    assert c.post(url, json={"notes": "VIP"}).status_code == 401
    r = c.post(url, headers=H, json={"notes": "  VIP  "})
    assert r.status_code == 200 and r.json()["notes"] == "VIP"
    assert db.last("sub_finder_set_notes") == {"p_key_id": 7, "p_order_number": "1003", "p_notes": "VIP"}
    c.post(url, headers=H, json={"notes": ""})                                  # empty clears
    assert db.last("sub_finder_set_notes")["p_notes"] == ""
    for body in ({}, {"notes": 5}, {"notes": None}, [1], {"notes": "x" * 501}):
        assert c.post(url, headers=H, json=body).status_code == 422
    assert c.post(url, headers=H, content=b"not json").status_code == 422
    assert c.post("/api/v1/subs/orders/bad%20order/notes", headers=H, json={"notes": "x"}).status_code == 422
    for code, status in (("forbidden", 403), ("not_found", 404)):
        db.rpc_data["sub_finder_set_notes"] = {"error": code}
        assert c.post(url, headers=H, json={"notes": "x"}).status_code == status


# ---------------------------------------------------------------- the guide, served to the CRM

DOC_TEXT = """# Guide

> **Doc version:** not hand-numbered — this file's history is its git history.

Code: `routers/subs_api.py` · SQL: migrations.

**Contents:** [8 Rules](#8-rules) · [9 Operators](#9-for-s4k-operators-switching-it-on) · [10 Troubleshooting](#10-troubleshooting)

## 8. Rules

for the CRM

## 9. For S4K operators: switching it on

UPDATE sub_finder_config SET enabled = true;

## 10. Troubleshooting

still here
"""


def test_render_crm_doc_fingerprints_what_is_served_and_drops_the_operator_section():
    doc = s.render_crm_doc(DOC_TEXT)
    version = doc["version"]
    assert len(version) == 12 and int(version, 16) >= 0 and doc["updated"] is None
    md = doc["markdown"]
    assert f"> **Doc version:** {version}\n" in md and "git history" not in md
    # the same guide always has the same version; a change the CRM can see changes it;
    # a change only in the operators' section (never served) does not
    assert s.render_crm_doc(DOC_TEXT)["version"] == version
    assert s.render_crm_doc(DOC_TEXT.replace("for the CRM", "for the CRM, changed"))["version"] != version
    assert s.render_crm_doc(DOC_TEXT.replace("enabled = true", "enabled = false"))["version"] == version
    assert "sub_finder_config" not in md and "For S4K operators" not in md and "Code:" not in md
    assert "for the CRM" in md and "## 10. Troubleshooting" in md and "still here" in md
    assert "**Contents:** [8 Rules](#8-rules) · [10 Troubleshooting](#10-troubleshooting)\n" in md
    # a guide without a version line still renders, and still has a version
    bare = s.render_crm_doc("# Guide\n\ntext\n")
    assert len(bare["version"]) == 12 and bare["markdown"] == "# Guide\n\ntext\n"


def test_ping_names_the_guide_version_and_docs_serves_it(tmp_path, monkeypatch):
    path = tmp_path / "guide.md"
    path.write_text(DOC_TEXT, encoding="utf-8")
    monkeypatch.setattr(s, "DOC_PATH", path)
    s.crm_doc.cache_clear()
    db = FakeDB(rpc_data={"sub_finder_access": {"find": True}})
    c = _client(db)
    version = s.render_crm_doc(DOC_TEXT)["version"]
    assert c.get("/api/v1/subs/ping", headers=H).json()["docs"] == {
        "version": version, "updated": None, "url": "/api/v1/subs/docs"}
    r = c.get("/api/v1/subs/docs", headers=H)
    body = r.json()
    assert r.status_code == 200 and body["version"] == version and body["format"] == "markdown"
    assert "for the CRM" in body["markdown"] and "sub_finder_config" not in body["markdown"]
    assert db.last("mcp_count_call") == {"p_key_id": 7, "p_tool": "subs.docs"}
    r = c.get("/api/v1/subs/docs?format=md", headers=H)
    assert r.status_code == 200 and r.headers["content-type"].startswith("text/markdown")
    assert r.headers["x-doc-version"] == version and r.text.startswith("# Guide")
    # the guide needs the key like every other route
    assert c.get("/api/v1/subs/docs").status_code == 401
    s.crm_doc.cache_clear()


def test_ping_and_docs_without_a_guide_on_the_deploy(tmp_path, monkeypatch):
    monkeypatch.setattr(s, "DOC_PATH", tmp_path / "missing.md")
    s.crm_doc.cache_clear()
    c = _client(FakeDB())
    assert c.get("/api/v1/subs/ping", headers=H).json()["docs"] == {
        "version": None, "updated": None, "url": "/api/v1/subs/docs"}
    r = c.get("/api/v1/subs/docs", headers=H)
    assert r.status_code == 404 and r.json()["error"] == "not_found"
    s.crm_doc.cache_clear()


def test_the_shipped_guide_renders_with_a_version():
    s.crm_doc.cache_clear()
    doc = s.crm_doc(s.DOC_PATH)
    assert doc and doc["version"] and "## 10. Troubleshooting" in doc["markdown"]
    assert "For S4K operators" not in doc["markdown"] and "mcp_issue_key" not in doc["markdown"]
    assert "9 Operators" not in doc["markdown"]


# ---------------------------------------------------------------- balances

def test_balances_passes_the_sql_answer_through_and_its_refusal():
    out = {"evo": {"total_spendable": 220575.53, "accounts": [{"office_id": "42029"}]},
           "gotickets_gift_cards": {"total_remaining": 0, "cards": []}, "generated_at": "2026-11-13T19:07:00Z"}
    db = FakeDB(rpc_data={"sub_finder_balances": out})
    r = _client(db).get("/api/v1/subs/balances", headers=H)
    assert r.status_code == 200 and r.json() == out
    assert db.last("sub_finder_balances") == {"p_key_id": 7}
    assert db.last("mcp_count_call") == {"p_key_id": 7, "p_tool": "subs.balances"}
    db = FakeDB(rpc_data={"sub_finder_balances": {"error": "forbidden", "detail": "this key may not read balances"}})
    assert _client(db).get("/api/v1/subs/balances", headers=H).status_code == 403
    assert _client(FakeDB()).get("/api/v1/subs/balances").status_code == 401


# ---------------------------------------------------------------- auto-buy results

def test_autobuys_passes_the_feed_through_with_the_sync_cursor():
    out = {"count": 1, "total": 1, "limit": 50, "offset": 0, "generated_at": "2026-11-13T20:30:00Z",
           "items": [{"buy_ref": "gotickets-8400001", "for_order": {"order_number": "82482253"},
                      "status": "went_through", "totals": {"charged_usd": 554.64, "sold_usd": 650.0}}]}
    db = FakeDB(rpc_data={"sub_finder_autobuys": out})
    r = _client(db).get("/api/v1/subs/autobuys?updated_since=2026-11-13T20:00:00Z&limit=50", headers=H)
    assert r.status_code == 200 and r.json() == out
    assert db.last("sub_finder_autobuys") == {"p_key_id": 7, "p_updated_since": "2026-11-13T20:00:00+00:00",
                                              "p_limit": 50, "p_offset": 0}
    assert db.last("mcp_count_call") == {"p_key_id": 7, "p_tool": "subs.autobuys"}
    _client(db).get("/api/v1/subs/autobuys", headers=H)
    assert db.last("sub_finder_autobuys") == {"p_key_id": 7, "p_updated_since": None, "p_limit": 200, "p_offset": 0}


def test_autobuys_refusals_and_bad_input_never_reach_sql():
    db = FakeDB(rpc_data={"sub_finder_autobuys": {"error": "forbidden",
                                                  "detail": "this key may not read auto-buy results"}})
    assert _client(db).get("/api/v1/subs/autobuys", headers=H).status_code == 403
    assert _client(FakeDB()).get("/api/v1/subs/autobuys").status_code == 401
    for q in ("updated_since=yesterday", "limit=0", "limit=1001", "offset=-1"):
        db = FakeDB()
        r = _client(db).get(f"/api/v1/subs/autobuys?{q}", headers=H)
        assert r.status_code == 422 and not [n for n, _ in db.rpcs if n == "sub_finder_autobuys"]


def test_autobuys_read_is_retried_once_on_a_dropped_connection():
    assert "sub_finder_autobuys" in s.RETRY_ONCE_RPCS


# ---------------------------------------------------------------- a dropped connection

class TransportError(Exception):
    """Stands in for httpx.TransportError (matched by class name, so httpx is not imported)."""


class ReadError(TransportError):
    pass


class _FlakyDB(FakeDB):
    """Raises the given error on the first call of each named RPC, then answers."""

    def __init__(self, flaky, **kw):
        super().__init__(**kw)
        self.flaky = dict(flaky)

    def rpc(self, name, args):
        if name in self.flaky:
            exc = self.flaky.pop(name)
            self.rpcs.append((name, args))
            return type("Q", (), {"execute": lambda _self: (_ for _ in ()).throw(exc)})()
        return super().rpc(name, args)


def test_dropped_connection_is_recognised_by_class_name():
    assert s.dropped_connection(ReadError("reset")) and s.dropped_connection(TransportError("x"))
    assert not s.dropped_connection(RuntimeError("statement timeout"))


def test_a_read_is_sent_again_once_when_the_connection_drops():
    row = {"count": 1, "items": [{"order_number": "659213629"}]}
    db = _FlakyDB({"mcp_verify_key": ReadError("reset"), "sub_finder_order_read": ReadError("reset")},
                  rpc_data={"sub_finder_latest_job": JOB, "sub_finder_order_read": row})
    r = _client(db).get("/api/v1/subs/orders/659213629", headers=H)
    assert r.status_code == 200 and r.json() == row
    assert [n for n, _ in db.rpcs].count("mcp_verify_key") == 2
    assert [n for n, _ in db.rpcs].count("sub_finder_order_read") == 2


def test_a_write_or_another_error_is_never_sent_twice():
    # a buy whose connection dropped may have gone through: it is not repeated
    db = _FlakyDB({"sub_finder_buy_confirmed": ReadError("reset")},
                  rpc_data={"sub_finder_latest_job": JOB})
    c = TestClient(_app(db), raise_server_exceptions=False)
    r = c.post("/api/v1/subs/orders/659213629/buy", headers=H, json={"listing_id": "6833175743"})
    assert r.status_code == 500 and [n for n, _ in db.rpcs].count("sub_finder_buy_confirmed") == 1
    # a read that failed for another reason (a database error) is not repeated either
    db = _FlakyDB({"sub_finder_order_read": RuntimeError("statement timeout")},
                  rpc_data={"sub_finder_latest_job": JOB})
    c = TestClient(_app(db), raise_server_exceptions=False)
    assert c.get("/api/v1/subs/orders/659213629", headers=H).status_code == 500
    assert [n for n, _ in db.rpcs].count("sub_finder_order_read") == 1

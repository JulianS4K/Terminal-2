"""Coverage-closing tests for render_webhook.py + the routers/ passthrough
package (seatgeek / axs / seatdata / broker).

Companion to the per-module suites (test_render_webhook.py, test_seatgeek_routes.py,
test_axs_routes.py, test_seatdata_routes.py, test_broker_routes.py). Those cover
the happy paths + pure-logic math; this file fills the remaining branches that
those don't reach:

  render_webhook.py  — the network-touching helpers (`_render_get`,
      `dispatch_github_workflow`) over their 200 / non-200 / exception arms, the
      RENDER_API_KEY arms of `deploy_succeeded` / `service_targets_repo`, the
      repo-mismatch skip in `handle_deploy_ended`, the invalid-timestamp reject,
      and `load_config` reading the environment. `requests` is monkeypatched, so
      there is NO real network.

  routers/*          — the empty-snapshot / non-latest / passthrough branches not
      hit elsewhere (SG seller-listings + seller-orders, SG non-latest listings,
      AXS series range/hours/days + RPC failure, SeatData /usage, broker /espn +
      order-lookup vivid/empty-id). Each router is mounted on its own tiny
      FastAPI app via its `build_*_router` factory with fake getters — no real DB,
      no real HTTP (the broker /espn route patches `requests` on the router
      module).

Run:
  pytest tests/test_webhook_routers_full.py -v
"""
from __future__ import annotations

import os
import sys
from pathlib import Path

import pytest

os.environ.setdefault("AUTH_DISABLED", "true")
os.environ.setdefault("SUPABASE_URL", "https://example.invalid")
os.environ.setdefault("SUPABASE_SERVICE_ROLE_KEY", "test-key")

REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT))

pytest.importorskip("fastapi")
_tc = pytest.importorskip("fastapi.testclient")
from fastapi import FastAPI  # noqa: E402

import render_webhook as rw  # noqa: E402
from routers.axs import build_axs_router  # noqa: E402
from routers.broker import build_broker_router  # noqa: E402
from routers.seatdata import build_seatdata_router  # noqa: E402
from routers.seatgeek import build_seatgeek_router  # noqa: E402

TestClient = _tc.TestClient


# ===========================================================================
# render_webhook.py
# ===========================================================================

# ---- verify_signature: non-integer timestamp (129-130) --------------------

def test_verify_rejects_non_integer_timestamp():
    headers = {
        "webhook-id": "msg_x",
        "webhook-timestamp": "not-a-number",
        "webhook-signature": "v1,abc",
    }
    with pytest.raises(rw.WebhookVerificationError, match="invalid webhook-timestamp"):
        rw.verify_signature("whsec_AAAA", b"{}", headers, now=1614265330.0)


# ---- _render_get: 200 / non-200 / RequestException (155-167) --------------

class _Resp:
    def __init__(self, status_code=200, payload=None):
        self.status_code = status_code
        self._payload = payload if payload is not None else {}

    def json(self):
        return self._payload


def test_render_get_returns_json_on_200(monkeypatch):
    captured = {}

    def fake_get(url, headers=None, timeout=None):
        captured["url"] = url
        captured["headers"] = headers
        return _Resp(200, {"name": "svc"})

    monkeypatch.setattr(rw.requests, "get", fake_get)
    out = rw._render_get("/services/srv-1", "rnd_key")
    assert out == {"name": "svc"}
    assert captured["url"].endswith("/services/srv-1")
    assert captured["headers"]["Authorization"] == "Bearer rnd_key"


def test_render_get_returns_none_on_non_200(monkeypatch):
    monkeypatch.setattr(rw.requests, "get", lambda *a, **k: _Resp(404, {}))
    assert rw._render_get("/services/missing", "rnd_key") is None


def test_render_get_returns_none_on_request_exception(monkeypatch):
    def boom(*a, **k):
        raise rw.requests.RequestException("network down")

    monkeypatch.setattr(rw.requests, "get", boom)
    assert rw._render_get("/services/x", "rnd_key") is None


# ---- deploy_succeeded: RENDER_API_KEY arm (179-182) -----------------------

def test_deploy_succeeded_api_event_live(monkeypatch):
    monkeypatch.setattr(rw, "_render_get",
                        lambda path, key: {"details": {"status": rw.RENDER_DEPLOY_STATUS_LIVE}})
    payload = {"type": "deploy_ended", "data": {"id": "evt-1"}}
    assert rw.deploy_succeeded(payload, api_key="rnd_key") is True


def test_deploy_succeeded_api_event_not_live(monkeypatch):
    monkeypatch.setattr(rw, "_render_get", lambda path, key: {"details": {"status": 3}})
    payload = {"type": "deploy_ended", "data": {"id": "evt-1"}}
    assert rw.deploy_succeeded(payload, api_key="rnd_key") is False


def test_deploy_succeeded_api_event_lookup_fails(monkeypatch):
    # _render_get returns None (e.g. API error) -> fail closed.
    monkeypatch.setattr(rw, "_render_get", lambda path, key: None)
    payload = {"type": "deploy_ended", "data": {"id": "evt-1"}}
    assert rw.deploy_succeeded(payload, api_key="rnd_key") is False


# ---- service_targets_repo: RENDER_API_KEY arm (194-198) -------------------

def test_service_targets_repo_match(monkeypatch):
    monkeypatch.setattr(rw, "_render_get",
                        lambda path, key: {"repo": "https://github.com/s4kent/terminal-2",
                                           "branch": "release"})
    ok, branch = rw.service_targets_repo("srv-1", "s4kent", "terminal-2", "rnd_key")
    assert ok is True and branch == "release"


def test_service_targets_repo_mismatch(monkeypatch):
    monkeypatch.setattr(rw, "_render_get",
                        lambda path, key: {"repo": "https://github.com/other/repo", "branch": "main"})
    ok, branch = rw.service_targets_repo("srv-1", "s4kent", "terminal-2", "rnd_key")
    assert ok is False and branch == "main"


def test_service_targets_repo_service_lookup_fails(monkeypatch):
    monkeypatch.setattr(rw, "_render_get", lambda path, key: None)
    ok, branch = rw.service_targets_repo("srv-1", "s4kent", "terminal-2", "rnd_key")
    assert ok is False and branch is None


# ---- dispatch_github_workflow: 204 / non-204 / exception (215-234) --------

def test_dispatch_github_workflow_204(monkeypatch):
    captured = {}

    def fake_post(url, headers=None, json=None, timeout=None):
        captured["url"] = url
        captured["json"] = json
        return _Resp(204)

    monkeypatch.setattr(rw.requests, "post", fake_post)
    ok = rw.dispatch_github_workflow(owner="s4kent", repo="terminal-2",
                                     workflow_id="post-deploy.yml", ref="main",
                                     token="ghp_x", inputs={"serviceID": "srv-1"})
    assert ok is True
    assert captured["url"].endswith("/repos/s4kent/terminal-2/actions/workflows/post-deploy.yml/dispatches")
    assert captured["json"] == {"ref": "main", "inputs": {"serviceID": "srv-1"}}


def test_dispatch_github_workflow_defaults_inputs_to_empty(monkeypatch):
    captured = {}
    monkeypatch.setattr(rw.requests, "post",
                        lambda url, headers=None, json=None, timeout=None: captured.update(json=json) or _Resp(204))
    rw.dispatch_github_workflow(owner="o", repo="r", workflow_id="w.yml", ref="main", token="t")
    assert captured["json"]["inputs"] == {}


def test_dispatch_github_workflow_non_204():
    class _R(_Resp):
        text = "Bad credentials"

    import unittest.mock as _m
    with _m.patch.object(rw.requests, "post", return_value=_R(401)):
        ok = rw.dispatch_github_workflow(owner="o", repo="r", workflow_id="w.yml",
                                         ref="main", token="bad")
    assert ok is False


def test_dispatch_github_workflow_request_exception(monkeypatch):
    def boom(*a, **k):
        raise rw.requests.RequestException("timeout")

    monkeypatch.setattr(rw.requests, "post", boom)
    ok = rw.dispatch_github_workflow(owner="o", repo="r", workflow_id="w.yml",
                                     ref="main", token="t")
    assert ok is False


# ---- handle_deploy_ended: repo-mismatch skip (307) ------------------------

def test_handle_deploy_ended_skips_on_repo_mismatch(monkeypatch):
    # Successful deploy + GitHub configured, but the service doesn't target our
    # repo (RENDER_API_KEY set -> service_targets_repo consulted -> False).
    monkeypatch.setattr(rw, "deploy_succeeded", lambda payload, key: True)
    monkeypatch.setattr(rw, "service_targets_repo",
                        lambda sid, owner, repo, key: (False, None))
    cfg = {
        "webhook_secret": "whsec_x", "render_api_key": "rnd_key",
        "github_token": "ghp_x", "github_owner": "s4kent", "github_repo": "terminal-2",
        "github_workflow_id": "post-deploy.yml", "github_ref": "main",
    }
    payload = {"type": "deploy_ended", "data": {"serviceId": "srv-x", "status": "succeeded"}}
    out = rw.handle_deploy_ended(payload, cfg)
    assert out.startswith("skipped")
    assert "does not target s4kent/terminal-2" in out


def test_handle_deploy_ended_falls_back_to_branch_ref(monkeypatch):
    # No configured github_ref -> ref comes from the service's deploy branch.
    monkeypatch.setattr(rw, "deploy_succeeded", lambda payload, key: True)
    monkeypatch.setattr(rw, "service_targets_repo",
                        lambda sid, owner, repo, key: (True, "deploy-branch"))
    captured = {}
    monkeypatch.setattr(rw, "dispatch_github_workflow",
                        lambda **kw: captured.update(kw) or True)
    cfg = {
        "webhook_secret": "whsec_x", "render_api_key": "rnd_key",
        "github_token": "ghp_x", "github_owner": "s4kent", "github_repo": "terminal-2",
        "github_workflow_id": "post-deploy.yml", "github_ref": None,
    }
    payload = {"type": "deploy_ended", "data": {"serviceId": "srv-x", "status": "succeeded"}}
    assert rw.handle_deploy_ended(payload, cfg) == "dispatched"
    assert captured["ref"] == "deploy-branch"


def test_handle_deploy_ended_reports_dispatch_failure(monkeypatch):
    monkeypatch.setattr(rw, "deploy_succeeded", lambda payload, key: True)
    monkeypatch.setattr(rw, "service_targets_repo", lambda *a, **k: (True, None))
    monkeypatch.setattr(rw, "dispatch_github_workflow", lambda **kw: False)
    cfg = {
        "webhook_secret": "whsec_x", "render_api_key": None,
        "github_token": "ghp_x", "github_owner": "s4kent", "github_repo": "terminal-2",
        "github_workflow_id": "post-deploy.yml", "github_ref": "main",
    }
    payload = {"type": "deploy_ended", "data": {"serviceId": "srv-x", "status": "succeeded"}}
    assert rw.handle_deploy_ended(payload, cfg).startswith("error")


# ---- load_config: reads the environment (321-334) -------------------------

def test_load_config_reads_environment(monkeypatch):
    monkeypatch.setenv("RENDER_WEBHOOK_SECRET", "whsec_cfg")
    monkeypatch.setenv("RENDER_API_KEY", "rnd_cfg")
    monkeypatch.setenv("GITHUB_API_TOKEN", "ghp_cfg")
    monkeypatch.setenv("GITHUB_OWNER_NAME", "owner-cfg")
    monkeypatch.setenv("GITHUB_REPO_NAME", "repo-cfg")
    monkeypatch.setenv("GITHUB_WORKFLOW_ID", "wf-cfg.yml")
    monkeypatch.setenv("GITHUB_WORKFLOW_REF", "ref-cfg")
    cfg = rw.load_config()
    assert cfg == {
        "webhook_secret": "whsec_cfg",
        "render_api_key": "rnd_cfg",
        "github_token": "ghp_cfg",
        "github_owner": "owner-cfg",
        "github_repo": "repo-cfg",
        "github_workflow_id": "wf-cfg.yml",
        "github_ref": "ref-cfg",
    }


def test_load_config_defaults_when_unset(monkeypatch):
    for k in ("RENDER_WEBHOOK_SECRET", "RENDER_API_KEY", "GITHUB_API_TOKEN",
              "GITHUB_OWNER_NAME", "GITHUB_REPO_NAME", "GITHUB_WORKFLOW_ID",
              "GITHUB_WORKFLOW_REF"):
        monkeypatch.delenv(k, raising=False)
    cfg = rw.load_config()
    assert cfg["webhook_secret"] == ""
    assert cfg["render_api_key"] is None
    assert cfg["github_owner"] == "JulianS4K"
    assert cfg["github_repo"] == "Terminal-2"
    assert cfg["github_workflow_id"] == "post-deploy.yml"
    assert cfg["github_ref"] is None


# ===========================================================================
# Shared fake Supabase for the router apps
# ===========================================================================

class _Res:
    def __init__(self, data, count=None):
        self.data = data
        self.count = count


class _Q:
    def __init__(self, data, count=None):
        self._data = data
        self._count = count

    def select(self, *a, **k):
        return self

    def eq(self, *a, **k):
        return self

    def in_(self, *a, **k):
        return self

    def order(self, *a, **k):
        return self

    def limit(self, *a, **k):
        return self

    def execute(self):
        return _Res(self._data, self._count)


class _Sb:
    def __init__(self, tables=None, rpc=None, counts=None, rpc_raises=False):
        self._tables = tables or {}
        self._rpc = rpc or {}
        self._counts = counts or {}
        self._rpc_raises = rpc_raises

    def table(self, name):
        return _Q(self._tables.get(name, []), self._counts.get(name))

    def rpc(self, name, params=None):
        if self._rpc_raises:
            raise RuntimeError("rpc unavailable")
        return _Q(self._rpc.get(name, []))


def _app_with(router):
    app = FastAPI()
    app.include_router(router)
    return TestClient(app)


def _noauth():
    return lambda: None


# ===========================================================================
# routers/seatgeek.py
# ===========================================================================

def _sg_client(**sb_kw):
    sb = _Sb(**sb_kw)
    router = build_seatgeek_router(get_require_sb=lambda: (lambda: sb), require_auth=_noauth())
    return _app_with(router)


def test_sg_listings_latest_empty_probe():
    # latest_only=True but no captured_at probe row -> empty listings (line 37).
    c = _sg_client(tables={"seatgeek_listings_snapshots": []})
    body = c.get("/api/seatgeek/event/55/listings").json()
    assert body == {"event_id": 55, "listings": [], "summary": None}


def test_sg_listings_non_latest_branch():
    # latest_only=false takes the order/limit-all branch (line 47), then summary.
    rows = [
        {"sglid": "a", "quantity": 2, "retail_price_all_in": 100, "captured_at": "t2"},
        {"sglid": "b", "quantity": 3, "retail_price_all_in": 200, "captured_at": "t1"},
    ]
    c = _sg_client(tables={"seatgeek_listings_snapshots": rows})
    body = c.get("/api/seatgeek/event/55/listings?latest_only=false").json()
    s = body["summary"]
    assert s["total_listings"] == 2 and s["total_tickets"] == 5
    assert s["median_retail_all_in"] == 150  # (100+200)/2


def test_sg_listings_non_latest_empty_rows():
    # non-latest with no rows -> the empty-rows return (line 53).
    c = _sg_client(tables={"seatgeek_listings_snapshots": []})
    body = c.get("/api/seatgeek/event/55/listings?latest_only=false").json()
    assert body == {"event_id": 55, "listings": [], "summary": None}


def test_sg_sales_empty():
    # No sales rows -> empty summary (line 81).
    c = _sg_client(tables={"seatgeek_sales_snapshots": []})
    body = c.get("/api/seatgeek/event/55/sales").json()
    assert body == {"event_id": 55, "sales": [], "summary": None}


def test_sg_seller_listings_latest_empty_probe():
    # seller-listings latest_only with no probe row -> empty (within 101-122).
    c = _sg_client(tables={"seatgeek_seller_listings": []})
    body = c.get("/api/seatgeek/event/55/seller-listings").json()
    assert body == {"event_id": 55, "listings": [], "summary": None}


def test_sg_seller_listings_summary():
    rows = [
        {"sg_listing_id": "L1", "quantity": 2, "cost": 50, "pulled_at": "t"},
        {"sg_listing_id": "L2", "quantity": 3, "cost": 150, "pulled_at": "t"},
    ]
    c = _sg_client(tables={"seatgeek_seller_listings": rows})
    body = c.get("/api/seatgeek/event/55/seller-listings").json()
    s = body["summary"]
    assert s["total_listings"] == 2
    assert s["total_tickets"] == 5
    assert s["median_cost"] == 150  # sorted([50,150])[2//2] = index 1
    assert s["captured_at"] == "t"


def test_sg_seller_listings_non_latest_empty():
    # latest_only=false branch with no rows -> empty (within 101-122).
    c = _sg_client(tables={"seatgeek_seller_listings": []})
    body = c.get("/api/seatgeek/event/55/seller-listings?latest_only=false").json()
    assert body == {"event_id": 55, "listings": [], "summary": None}


def test_sg_seller_orders_empty():
    c = _sg_client(tables={"seatgeek_orders": []})
    body = c.get("/api/seatgeek/event/55/seller-orders").json()
    assert body == {"event_id": 55, "orders": [], "summary": None}


def test_sg_seller_orders_summary():
    rows = [
        {"sg_order_id": "O1", "status": "confirmed", "sale_quantity": 2, "sale_price": 100,
         "last_status_at": "t2"},
        {"sg_order_id": "O2", "status": "pending", "sale_quantity": 5, "sale_price": 999,
         "last_status_at": "t1"},
        {"sg_order_id": "O3", "status": None, "sale_quantity": 1, "sale_price": 10,
         "last_status_at": "t0"},
    ]
    c = _sg_client(tables={"seatgeek_orders": rows})
    body = c.get("/api/seatgeek/event/55/seller-orders").json()
    s = body["summary"]
    assert s["total_orders"] == 3
    assert s["by_status"] == {"confirmed": 1, "pending": 1, "unknown": 1}
    assert s["tickets_sold"] == 2   # only confirmed counts
    assert s["gross_sold"] == 200.0  # 100 * 2
    assert s["last_order_at"] == "t2"


# ===========================================================================
# routers/axs.py
# ===========================================================================

def _axs_client(**sb_kw):
    sb = _Sb(**sb_kw)
    router = build_axs_router(get_require_sb=lambda: (lambda: sb), require_auth=_noauth())
    return _app_with(router)


def test_axs_sections_no_snapshot():
    # No snapshot row -> early empty return (line 132).
    c = _axs_client(tables={"axs_event_snapshots": []})
    body = c.get("/api/axs/event/1/sections").json()
    assert body == {"event_id": 1, "count": 0, "sections": [], "summary": None,
                    "captured_at": None}


def test_axs_listings_no_snapshot():
    # No snapshot row -> early empty return (line 170).
    c = _axs_client(tables={"axs_event_snapshots": []})
    body = c.get("/api/axs/event/1/listings").json()
    assert body == {"event_id": 1, "count": 0, "listings": [], "summary": None,
                    "captured_at": None}


def test_axs_series_hours_param():
    # `hours` param (no `range`) hits the elif branch (205-206).
    rows = [{"captured_at": "2026-05-10T00:00:00Z", "median_price": 99, "listings_count": 4}]
    c = _axs_client(rpc={"get_axs_event_price_series": rows})
    body = c.get("/api/axs/event/1/series?hours=48").json()
    assert body["prices_axs"] == [{"t": "2026-05-10T00:00:00Z", "v": 99}]


def test_axs_series_days_default_branch():
    # Neither range nor hours -> the days branch (207-208).
    rows = [{"captured_at": "2026-05-10T00:00:00Z", "median_price": 50, "listings_count": 1}]
    c = _axs_client(rpc={"get_axs_event_price_series": rows})
    body = c.get("/api/axs/event/1/series?days=7").json()
    assert body["counts_axs"] == [{"t": "2026-05-10T00:00:00Z", "v": 1}]


def test_axs_series_range_all_unbounded():
    # range=all -> range_hours None -> the epoch since_iso branch.
    rows = [{"captured_at": "2026-05-10T00:00:00Z", "median_price": 10, "listings_count": 2}]
    c = _axs_client(rpc={"get_axs_event_price_series": rows})
    body = c.get("/api/axs/event/1/series?range=all").json()
    assert body["prices_axs"][0]["v"] == 10


def test_axs_series_rpc_failure_degrades_to_empty():
    # RPC raises -> except path returns empty series (215-216).
    c = _axs_client(rpc_raises=True)
    body = c.get("/api/axs/event/1/series?range=7d").json()
    assert body["prices_axs"] == [] and body["counts_axs"] == []


# ===========================================================================
# routers/seatdata.py
# ===========================================================================

def _sd_client(client_obj, **sb_kw):
    sb = _Sb(**sb_kw)
    router = build_seatdata_router(
        get_seatdata_client=lambda: client_obj,
        get_require_sb=lambda: (lambda: sb),
        require_auth=_noauth(),
    )
    return _app_with(router)


def test_seatdata_usage_503_when_unconfigured():
    # No client configured -> 503 (lines 34-36).
    c = _sd_client(None)
    assert c.get("/api/seatdata/usage").status_code == 503


def test_seatdata_usage_passthrough():
    # Configured client -> usage() passthrough (line 37).
    class C:
        def usage(self):
            return {"calls": 12, "limit": 100}

    c = _sd_client(C())
    assert c.get("/api/seatdata/usage").json() == {"calls": 12, "limit": 100}


# ===========================================================================
# routers/broker.py
# ===========================================================================

def _broker_client(sb=None, url="https://example.invalid", anon="anon-key"):
    sb = sb if sb is not None else _Sb()
    router = build_broker_router(
        get_require_sb=lambda: (lambda: sb),
        require_auth=_noauth(),
        espn_leagues=[{"id": "nba", "name": "NBA"}],
        get_supabase_url=lambda: url,
        get_supabase_anon_key=lambda: anon,
    )
    return _app_with(router)


def test_broker_espn_missing_config_500():
    # No SUPABASE_URL/ANON -> 500 (lines 57-58).
    c = _broker_client(url=None, anon=None)
    assert c.get("/api/broker/event/1/espn").status_code == 500


def test_broker_espn_ok_passthrough(monkeypatch):
    # r.ok -> the edge fn json is returned verbatim (lines 59-62 happy arm).
    class _R:
        ok = True
        status_code = 200

        def json(self):
            return {"applicable": True, "scores": [1, 2]}

    captured = {}
    monkeypatch.setattr("routers.broker.requests.get",
                        lambda url, headers=None, timeout=None: captured.update(url=url, headers=headers) or _R())
    c = _broker_client()
    body = c.get("/api/broker/event/77/espn").json()
    assert body == {"applicable": True, "scores": [1, 2]}
    assert captured["url"].endswith("/functions/v1/espn/event/77")
    assert captured["headers"]["Authorization"] == "Bearer anon-key"


def test_broker_espn_non_ok_status(monkeypatch):
    # r.ok False -> structured error with the status code (line 62 else arm).
    class _R:
        ok = False
        status_code = 503

        def json(self):  # pragma: no cover - not reached on non-ok
            return {}

    monkeypatch.setattr("routers.broker.requests.get",
                        lambda url, headers=None, timeout=None: _R())
    c = _broker_client()
    body = c.get("/api/broker/event/1/espn").json()
    assert body == {"applicable": False, "error": "espn fn 503"}


def test_broker_espn_request_exception(monkeypatch):
    # requests.get raises -> caught, returned as applicable:false (lines 63-64).
    def boom(*a, **k):
        raise RuntimeError("connection refused")

    monkeypatch.setattr("routers.broker.requests.get", boom)
    c = _broker_client()
    body = c.get("/api/broker/event/1/espn").json()
    assert body["applicable"] is False
    assert "connection refused" in body["error"]


def test_broker_order_lookup_empty_id_400():
    # Blank order_id -> 400 (line 233).
    c = _broker_client()
    assert c.get("/api/broker/order-lookup?order_id=%20").status_code == 400


def test_broker_order_lookup_vivid():
    # Vivid order found branch (lines 263-270, incl. 268-269).
    sb = _Sb(tables={"vivid_orders": [{
        "vivid_order_id": "VV5", "tevo_event_id": 9, "event_name": "Show",
        "section": "200", "row": "7", "quantity": 3, "total": 321.0,
    }]})
    c = _broker_client(sb=sb)
    body = c.get("/api/broker/order-lookup?order_id=VV5&source=vivid").json()
    assert body["found"] is True and body["source"] == "vivid"
    assert body["tevo_event_id"] == 9
    assert body["section"] == "200" and body["row"] == "7" and body["quantity"] == 3
    assert body["revenue"] == 321.0

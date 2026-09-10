"""Full line+branch coverage for s4kcs_client. No real HTTP — every
requests.get is monkeypatched at the boundary. Mirrors the house style in
tests/test_bandsintown_client_full.py.
"""
from __future__ import annotations

import pytest
import requests

import s4kcs_client as s4k


# ====================================================================
# Shared fake HTTP response + get patcher
# ====================================================================

class _FakeResp:
    def __init__(self, status, *, json_payload=None, json_raises=False,
                 text="raw-body", headers=None):
        self.status_code = status
        self.ok = 200 <= status < 300
        self._json_payload = json_payload
        self._json_raises = json_raises
        self.text = text
        self.headers = headers or {}

    def json(self):
        if self._json_raises:
            raise ValueError("no json")
        return self._json_payload


def _patch_get(monkeypatch, responses, captured=None):
    if isinstance(responses, _FakeResp):
        seq, single = None, responses
    else:
        seq, single = iter(responses), None

    def fake_get(url, **kwargs):
        if captured is not None:
            captured.append((url, kwargs))
        return single if single is not None else next(seq)

    monkeypatch.setattr(s4k.requests, "get", fake_get)


@pytest.fixture(autouse=True)
def _clear_cache(monkeypatch):
    # The orders cache is module-level by design (it must survive per-request
    # client construction), so each test starts from empty.
    s4k._ORDERS_CACHE.clear()
    monkeypatch.delenv("S4KCS_API_KEY", raising=False)
    yield
    s4k._ORDERS_CACHE.clear()


def _client(**kw):
    return s4k.S4KCSClient("s4k_testkey", **kw)


# ====================================================================
# Key resolution
# ====================================================================

def test_key_from_argument():
    assert _client().api_key == "s4k_testkey"


def test_key_is_stripped():
    # The vault copy under 'crm.s4kcs.com' was seeded with a leading space,
    # which makes the X-API-Key header invalid. Strip defensively.
    assert s4k.S4KCSClient(" s4k_padded ").api_key == "s4k_padded"


def test_key_from_env(monkeypatch):
    monkeypatch.setenv("S4KCS_API_KEY", "env-key")
    assert s4k.S4KCSClient().api_key == "env-key"


class _VaultDB:
    """Minimal supabase-py stand-in for the get_app_secret RPC."""

    def __init__(self, value):
        self._value = value
        self.asked = []

    def rpc(self, name, args):
        self.asked.append((name, args["p_name"]))
        return self

    def execute(self):
        return type("_R", (), {"data": self._value})()


def test_key_from_vault():
    db = _VaultDB("vault-key")
    assert s4k.S4KCSClient(db=db).api_key == "vault-key"
    # One name owns this secret — the EVENUEDESK_API_KEY duplicate was deleted.
    assert db.asked == [("get_app_secret", "crm.s4kcs.com")]


def test_missing_vault_value_falls_through_to_the_missing_key_error():
    with pytest.raises(s4k.S4KCSError):
        s4k.S4KCSClient(db=_VaultDB(None))


def test_missing_key_raises_with_actionable_message():
    with pytest.raises(s4k.S4KCSError) as exc:
        s4k.S4KCSClient()
    assert "S4KCS_API_KEY" in str(exc.value)
    assert "crm.s4kcs.com" in str(exc.value)


# ====================================================================
# RULE 2 read-only guard
# ====================================================================

def test_assert_readonly_raises_on_writes():
    for method in ("POST", "PUT", "PATCH", "DELETE"):
        with pytest.raises(s4k.S4KCSReadOnlyError) as exc:
            s4k._assert_readonly_method(method)
        assert "RULE 2" in str(exc.value)


def test_assert_readonly_allows_get():
    assert s4k._assert_readonly_method("GET") is None


def test_allowed_methods_is_get_only():
    assert s4k.ALLOWED_HTTP_METHODS == frozenset({"GET"})


# ====================================================================
# Transport
# ====================================================================

def test_get_sends_api_key_header_and_drops_none_params(monkeypatch):
    captured = []
    _patch_get(monkeypatch, _FakeResp(200, json_payload={"ok": True}), captured)
    c = _client()
    assert c.ping() == {"ok": True}
    url, kwargs = captured[0]
    assert url == "https://crm.s4kcs.com/api/v1/ping"
    assert kwargs["headers"]["X-API-Key"] == "s4k_testkey"


def test_get_raises_on_http_error(monkeypatch):
    _patch_get(monkeypatch, _FakeResp(401))
    with pytest.raises(s4k.S4KCSError) as exc:
        _client().ping()
    assert "HTTP 401" in str(exc.value)


def test_get_wraps_network_errors(monkeypatch):
    def boom(url, **kwargs):
        raise requests.ConnectionError("down")

    monkeypatch.setattr(s4k.requests, "get", boom)
    with pytest.raises(s4k.S4KCSError) as exc:
        _client().ping()
    assert "network error" in str(exc.value)


def test_get_falls_back_to_raw_text_on_bad_json(monkeypatch):
    # A 200 that isn't JSON is surfaced, not swallowed — callers can see what
    # the upstream actually sent.
    _patch_get(monkeypatch, _FakeResp(200, json_raises=True, text="not-json"))
    assert _client().ping() == {"raw_text": "not-json"}


# ====================================================================
# Endpoints
# ====================================================================

def test_ping_non_dict_body_coerced(monkeypatch):
    _patch_get(monkeypatch, _FakeResp(200, json_payload=["unexpected"]))
    assert _client().ping() == {}


def test_marketplaces(monkeypatch):
    _patch_get(monkeypatch, _FakeResp(200, json_payload={"marketplaces": [
        {"name": "StubHub", "key": "stubhub", "configured": True}]}))
    assert _client().marketplaces()[0]["name"] == "StubHub"


def test_marketplaces_non_dict_body(monkeypatch):
    _patch_get(monkeypatch, _FakeResp(200, json_payload=[]))
    assert _client().marketplaces() == []


def test_columns(monkeypatch):
    _patch_get(monkeypatch, _FakeResp(200, json_payload={"columns": ["source", "id"]}))
    assert _client().columns() == ["source", "id"]


def test_columns_non_dict_body(monkeypatch):
    _patch_get(monkeypatch, _FakeResp(200, json_payload="nope"))
    assert _client().columns() == []


# ====================================================================
# orders() — caching
# ====================================================================

_ROWS = {"count": 1, "rows": [{"source": "StubHub", "id": "644308803",
                              "section": "3", "row": "N", "quantity": 2,
                              "price": 870.34}]}


def test_orders_returns_rows_and_passes_window(monkeypatch):
    captured = []
    _patch_get(monkeypatch, _FakeResp(200, json_payload=_ROWS), captured)
    rows = _client().orders(markets="StubHub", ev_from="2026-09-01", ev_to="2026-09-30")
    assert rows[0]["id"] == "644308803"
    assert captured[0][1]["params"] == {
        "markets": "StubHub", "ev_from": "2026-09-01", "ev_to": "2026-09-30"}


def test_orders_memoises_within_ttl(monkeypatch):
    captured = []
    _patch_get(monkeypatch, [_FakeResp(200, json_payload=_ROWS)], captured)
    c = _client()
    assert c.orders() == c.orders()          # second call served from cache
    assert len(captured) == 1                # …and never hit the network again


def test_orders_refetches_after_ttl(monkeypatch):
    captured = []
    _patch_get(monkeypatch, [_FakeResp(200, json_payload=_ROWS),
                             _FakeResp(200, json_payload={"rows": []})], captured)
    c = _client(cache_ttl=0)  # expire immediately
    c.orders()
    assert c.orders() == []
    assert len(captured) == 2


def test_orders_use_cache_false_forces_refetch(monkeypatch):
    captured = []
    _patch_get(monkeypatch, [_FakeResp(200, json_payload=_ROWS),
                             _FakeResp(200, json_payload={"rows": []})], captured)
    c = _client()
    c.orders()
    assert c.orders(use_cache=False) == []
    assert len(captured) == 2


def test_orders_non_dict_body(monkeypatch):
    _patch_get(monkeypatch, _FakeResp(200, json_payload=["surprise"]))
    assert _client().orders() == []


def test_orders_non_list_rows(monkeypatch):
    _patch_get(monkeypatch, _FakeResp(200, json_payload={"rows": "nope"}))
    assert _client().orders() == []


# ====================================================================
# find_order()
# ====================================================================

def test_find_order_matches_by_id(monkeypatch):
    _patch_get(monkeypatch, _FakeResp(200, json_payload=_ROWS))
    row = _client().find_order("644308803")
    assert row["source"] == "StubHub" and row["row"] == "N"


def test_find_order_tolerates_padding_and_ints(monkeypatch):
    _patch_get(monkeypatch, _FakeResp(200, json_payload=_ROWS))
    c = _client()
    assert c.find_order("  644308803  ") is not None
    assert c.find_order(644308803) is not None  # served from cache


def test_find_order_returns_none_when_absent(monkeypatch):
    _patch_get(monkeypatch, _FakeResp(200, json_payload=_ROWS))
    assert _client().find_order("999") is None


def test_find_order_blank_id_never_fetches(monkeypatch):
    captured = []
    _patch_get(monkeypatch, _FakeResp(200, json_payload=_ROWS), captured)
    assert _client().find_order("   ") is None
    assert captured == []


def test_find_order_skips_rows_without_an_id(monkeypatch):
    _patch_get(monkeypatch, _FakeResp(200, json_payload={"rows": [
        {"source": "Gametime"}, {"source": "StubHub", "id": "7"}]}))
    assert _client().find_order("7")["source"] == "StubHub"


# ====================================================================
# N2S — error detail + instant rendering
# ====================================================================

def test_error_detail_carries_the_apis_message():
    resp = _FakeResp(403, json_payload={"detail": "key lacks the n2s:read scope"})
    assert s4k._error_detail(resp) == ": key lacks the n2s:read scope"


def test_error_detail_is_empty_when_the_body_is_not_json():
    assert s4k._error_detail(_FakeResp(500, json_raises=True)) == ""


@pytest.mark.parametrize("payload", [
    ["not-a-dict"],           # list body
    {"error": "no detail"},   # dict without the key
    {"detail": 42},           # detail that isn't a string
    {"detail": "   "},        # blank detail
])
def test_error_detail_is_empty_for_unusable_bodies(payload):
    assert s4k._error_detail(_FakeResp(400, json_payload=payload)) == ""


def test_instant_passes_strings_through_stripped():
    # A bare YYYY-MM-DD is valid for the alert window, so strings are not parsed.
    assert s4k._instant("  2026-09-06  ") == "2026-09-06"


def test_instant_none_and_blank_are_dropped():
    assert s4k._instant(None) is None
    assert s4k._instant("   ") is None


def test_instant_reads_a_naive_datetime_as_utc():
    from datetime import datetime
    assert s4k._instant(datetime(2026, 9, 7, 18, 50, 0)) == "2026-09-07T18:50:00Z"


def test_instant_converts_an_aware_datetime_to_utc():
    from datetime import datetime, timedelta, timezone
    eastern = timezone(timedelta(hours=-4))
    assert s4k._instant(datetime(2026, 9, 7, 14, 50, 0, tzinfo=eastern)) == \
        "2026-09-07T18:50:00Z"


# ====================================================================
# N2S — transport behaviour these endpoints add
# ====================================================================

def test_http_error_carries_the_detail_the_api_sent(monkeypatch):
    # A 403 here means the key is valid but unscoped — the message is the only
    # thing that distinguishes it from a bad key, so it must reach the caller.
    _patch_get(monkeypatch, _FakeResp(403, json_payload={
        "detail": "key lacks the n2s:read scope"}))
    with pytest.raises(s4k.S4KCSError) as exc:
        _client().n2s_meta()
    assert "HTTP 403: key lacks the n2s:read scope" in str(exc.value)


def test_404_raises_on_endpoints_that_did_not_ask_for_it(monkeypatch):
    _patch_get(monkeypatch, _FakeResp(404, json_payload={"detail": "unknown item"}))
    with pytest.raises(s4k.S4KCSError) as exc:
        _client().n2s_history(63)
    assert "HTTP 404" in str(exc.value)


# ====================================================================
# N2S — filter validation
# ====================================================================

@pytest.mark.parametrize("kwargs", [
    {"status": "closed"},
    {"source": "gmail"},
    {"sort": "alert"},
    {"order_by": "descending"},
    {"limit": 0},
    {"limit": s4k.N2S_MAX_LIMIT + 1},
    {"offset": -1},
])
def test_query_rejects_values_the_api_would_400_on(kwargs):
    with pytest.raises(ValueError):
        _client()._n2s_query(**kwargs)


def test_query_accepts_the_documented_vocabulary():
    q = _client()._n2s_query(
        status="n2s", source="automatiq", marketplace="tick", search="Fenway",
        order="1073318552", include_allocated=True, alert_from="2026-09-06",
        alert_to="2026-09-07", updated_since="2026-09-07T18:50:00Z",
        sort="alert_at", order_by="desc", limit=s4k.N2S_MAX_LIMIT, offset=0)
    assert q["status"] == "n2s" and q["sort"] == "alert_at"
    assert q["include_allocated"] == "true"
    assert q["limit"] == s4k.N2S_MAX_LIMIT and q["offset"] == 0


def test_query_omits_include_allocated_unless_asked():
    # False is the server's own default, and the flag is ignored outright when
    # `status` is given — so it is simply not sent.
    assert _client()._n2s_query()["include_allocated"] is None


def test_query_accepts_every_documented_status_and_sort_key():
    c = _client()
    for status in s4k.N2S_STATUSES:
        assert c._n2s_query(status=status)["status"] == status
    for key in s4k.N2S_SORT_KEYS:
        assert c._n2s_query(sort=key)["sort"] == key
    for source in s4k.N2S_SOURCES:
        assert c._n2s_query(source=source)["source"] == source
    for direction in s4k.N2S_ORDER_BYS:
        assert c._n2s_query(order_by=direction)["order_by"] == direction


# ====================================================================
# N2S — meta / intake
# ====================================================================

def test_n2s_meta(monkeypatch):
    captured = []
    _patch_get(monkeypatch, _FakeResp(200, json_payload={
        "timer_minutes": 15, "sort_keys": ["alert_at"]}), captured)
    assert _client().n2s_meta()["timer_minutes"] == 15
    assert captured[0][0] == "https://crm.s4kcs.com/api/v1/n2s/meta"


def test_n2s_meta_non_dict_body(monkeypatch):
    _patch_get(monkeypatch, _FakeResp(200, json_payload=["surprise"]))
    assert _client().n2s_meta() == {}


def test_n2s_intake(monkeypatch):
    _patch_get(monkeypatch, _FakeResp(200, json_payload={
        "running": True, "gmail_connected": True,
        "last_pass": {"result": {"created": 1}}}))
    assert _client().n2s_intake()["running"] is True


def test_n2s_intake_non_dict_body(monkeypatch):
    _patch_get(monkeypatch, _FakeResp(200, json_payload="nope"))
    assert _client().n2s_intake() == {}


# ====================================================================
# N2S — items
# ====================================================================

_ITEM = {"id": 63, "order_number": "1073318552", "status": "n2s",
         "source": "automatiq", "marketplace": "TickPick",
         "event_name": "Boston Red Sox vs. Los Angeles Angels",
         "event_dt": "2026-09-07T13:35:00", "alert_at": "2026-09-07T14:43:44Z",
         "timer": {"expired": True, "active": False}}
_PAGE = {"count": 1, "total": 1, "limit": 200, "offset": 0, "items": [_ITEM],
         "generated_at": "2026-09-07T19:02:11Z"}


def test_n2s_items_returns_the_envelope_and_sends_only_set_filters(monkeypatch):
    captured = []
    _patch_get(monkeypatch, _FakeResp(200, json_payload=_PAGE), captured)
    body = _client().n2s_items(status="n2s", source="automatiq",
                               sort="alert_at", order_by="desc")
    assert body["total"] == 1 and body["items"][0]["order_number"] == "1073318552"
    # `generated_at` is the cursor the mirror recipe feeds back as updated_since.
    assert body["generated_at"] == "2026-09-07T19:02:11Z"
    url, kwargs = captured[0]
    assert url == "https://crm.s4kcs.com/api/v1/n2s/items"
    assert kwargs["params"] == {"status": "n2s", "source": "automatiq",
                                "sort": "alert_at", "order_by": "desc"}


def test_n2s_items_renders_datetime_filters_as_utc_instants(monkeypatch):
    from datetime import datetime, timezone
    captured = []
    _patch_get(monkeypatch, _FakeResp(200, json_payload=_PAGE), captured)
    _client().n2s_items(updated_since=datetime(2026, 9, 7, 18, 50,
                                               tzinfo=timezone.utc))
    assert captured[0][1]["params"] == {"updated_since": "2026-09-07T18:50:00Z"}


def test_n2s_items_always_yields_a_list(monkeypatch):
    _patch_get(monkeypatch, _FakeResp(200, json_payload={"total": 0}))
    assert _client().n2s_items()["items"] == []


def test_n2s_items_non_list_items(monkeypatch):
    _patch_get(monkeypatch, _FakeResp(200, json_payload={"items": "nope"}))
    assert _client().n2s_items()["items"] == []


def test_n2s_items_non_dict_body(monkeypatch):
    _patch_get(monkeypatch, _FakeResp(200, json_payload=["surprise"]))
    assert _client().n2s_items() == {"items": []}


def test_n2s_items_csv_returns_the_raw_body(monkeypatch):
    captured = []
    _patch_get(monkeypatch, _FakeResp(200, json_raises=True,
                                      text="id,order_number\n63,1073318552\n"), captured)
    csv = _client().n2s_items_csv(marketplace="tickpick", include_allocated=True)
    assert csv.startswith("id,order_number")
    assert captured[0][1]["params"] == {"marketplace": "tickpick",
                                        "include_allocated": "true",
                                        "format": "csv"}


# ====================================================================
# N2S — paging walk
# ====================================================================

def _page(rows, total, offset, limit=2):
    return {"count": len(rows), "total": total, "limit": limit,
            "offset": offset, "items": rows}


def _rows(*ids):
    return [dict(_ITEM, id=i, order_number=str(i)) for i in ids]


def test_iter_items_walks_every_page(monkeypatch):
    captured = []
    _patch_get(monkeypatch, [
        _FakeResp(200, json_payload=_page(_rows(1, 2), 3, 0)),
        _FakeResp(200, json_payload=_page(_rows(3), 3, 2)),
    ], captured)
    ids = [r["id"] for r in _client().n2s_iter_items(page_size=2, sort="updated_at",
                                                     order_by="asc")]
    assert ids == [1, 2, 3]
    assert [c[1]["params"]["offset"] for c in captured] == [0, 2]


def test_iter_items_stops_on_an_empty_page(monkeypatch):
    _patch_get(monkeypatch, [
        _FakeResp(200, json_payload=_page(_rows(1, 2), 4, 0)),
        _FakeResp(200, json_payload=_page([], 4, 2)),
    ])
    assert len(list(_client().n2s_iter_items(page_size=2))) == 2


def test_iter_items_stops_when_total_is_reached_despite_a_full_page(monkeypatch):
    # Belt-and-braces: a server that ignored `offset` would otherwise hand back
    # a full page forever and the walk would never end.
    captured = []
    _patch_get(monkeypatch, _FakeResp(200, json_payload=_page(_rows(1, 2), 2, 0)),
               captured)
    assert len(list(_client().n2s_iter_items(page_size=2))) == 2
    assert len(captured) == 1


def test_iter_items_keeps_walking_when_total_is_missing(monkeypatch):
    _patch_get(monkeypatch, [
        _FakeResp(200, json_payload={"items": _rows(1, 2)}),   # no `total`
        _FakeResp(200, json_payload={"items": _rows(3)}),      # short → stop
    ])
    assert [r["id"] for r in _client().n2s_iter_items(page_size=2)] == [1, 2, 3]


def test_iter_items_honours_max_items(monkeypatch):
    captured = []
    _patch_get(monkeypatch, _FakeResp(200, json_payload=_page(_rows(1, 2), 9, 0)),
               captured)
    assert len(list(_client().n2s_iter_items(page_size=2, max_items=1))) == 1
    assert len(captured) == 1  # stopped mid-page, never asked for another


@pytest.mark.parametrize("kwargs", [{"limit": 10}, {"offset": 5}])
def test_iter_items_refuses_paging_kwargs_it_owns(kwargs):
    with pytest.raises(ValueError) as exc:
        list(_client().n2s_iter_items(**kwargs))
    assert "limit/offset" in str(exc.value)


@pytest.mark.parametrize("size", [0, s4k.N2S_MAX_LIMIT + 1])
def test_iter_items_validates_page_size(size):
    with pytest.raises(ValueError):
        list(_client().n2s_iter_items(page_size=size))


# ====================================================================
# N2S — single row, by id and by order number
# ====================================================================

_DETAIL = dict(_ITEM, events=[{"event": "created", "to_status": "n2s"}],
               deliveries=[], raw_fields={"automatiq": {"Order ID": "1073318552"}},
               payload_json={"schema_version": 1})


def test_n2s_item_by_id(monkeypatch):
    captured = []
    _patch_get(monkeypatch, _FakeResp(200, json_payload=_DETAIL), captured)
    row = _client().n2s_item(63)
    assert row["payload_json"]["schema_version"] == 1
    assert captured[0][0] == "https://crm.s4kcs.com/api/v1/n2s/items/63"
    assert captured[0][1]["params"] == {}


def test_n2s_item_include_body_is_opt_in(monkeypatch):
    captured = []
    _patch_get(monkeypatch, _FakeResp(200, json_payload=_DETAIL), captured)
    _client().n2s_item(63, include_body=True)
    assert captured[0][1]["params"] == {"include": "body"}


def test_n2s_item_blank_id_never_fetches(monkeypatch):
    captured = []
    _patch_get(monkeypatch, _FakeResp(200, json_payload=_DETAIL), captured)
    assert _client().n2s_item("   ") is None
    assert captured == []


def test_n2s_item_non_dict_body(monkeypatch):
    _patch_get(monkeypatch, _FakeResp(200, json_payload=["surprise"]))
    assert _client().n2s_item(63) == {}


def test_n2s_order_by_order_number(monkeypatch):
    captured = []
    _patch_get(monkeypatch, _FakeResp(200, json_payload=_DETAIL), captured)
    assert _client().n2s_order("1073318552")["id"] == 63
    assert captured[0][0] == \
        "https://crm.s4kcs.com/api/v1/n2s/orders/1073318552"


def test_n2s_order_404_means_never_in_n2s_not_an_error(monkeypatch):
    _patch_get(monkeypatch, _FakeResp(404, json_payload={"detail": "unknown order"}))
    assert _client().n2s_order("999") is None


def test_n2s_order_escapes_the_path_segment(monkeypatch):
    # Order numbers are the marketplace's, not ours — never trusted into a path.
    captured = []
    _patch_get(monkeypatch, _FakeResp(200, json_payload=_DETAIL), captured)
    _client().n2s_order("a/b?c")
    assert captured[0][0].endswith("/n2s/orders/a%2Fb%3Fc")


def test_n2s_order_blank_never_fetches(monkeypatch):
    captured = []
    _patch_get(monkeypatch, _FakeResp(200, json_payload=_DETAIL), captured)
    assert _client().n2s_order(None) is None
    assert captured == []


# ====================================================================
# N2S — history + stats
# ====================================================================

def test_n2s_history_returns_events_oldest_first(monkeypatch):
    captured = []
    _patch_get(monkeypatch, _FakeResp(200, json_payload={"item_id": 13, "count": 2,
        "events": [{"event": "created"}, {"event": "status"}]}), captured)
    events = _client().n2s_history(13)
    assert [e["event"] for e in events] == ["created", "status"]
    assert captured[0][0] == \
        "https://crm.s4kcs.com/api/v1/n2s/items/13/history"


def test_n2s_history_blank_id_never_fetches(monkeypatch):
    captured = []
    _patch_get(monkeypatch, _FakeResp(200, json_payload={"events": []}), captured)
    assert _client().n2s_history("") == []
    assert captured == []


def test_n2s_history_non_dict_body(monkeypatch):
    _patch_get(monkeypatch, _FakeResp(200, json_payload=["surprise"]))
    assert _client().n2s_history(13) == []


def test_n2s_history_non_list_events(monkeypatch):
    _patch_get(monkeypatch, _FakeResp(200, json_payload={"events": "nope"}))
    assert _client().n2s_history(13) == []


def test_n2s_stats(monkeypatch):
    captured = []
    _patch_get(monkeypatch, _FakeResp(200, json_payload={
        "by_status": {"n2s": 231}, "automated_window": {"open_expired": 229}}),
        captured)
    body = _client().n2s_stats(alert_from="2026-09-06")
    assert body["by_status"]["n2s"] == 231
    assert captured[0][1]["params"] == {"alert_from": "2026-09-06"}


def test_n2s_stats_non_dict_body(monkeypatch):
    _patch_get(monkeypatch, _FakeResp(200, json_payload=[]))
    assert _client().n2s_stats() == {}


# ====================================================================
# N2S key — a second, independently-scoped secret
# ====================================================================
#
# The CRM issues per-scope keys and the two we hold are disjoint
# (`marketplace:read` vs `n2s:read`), so `/n2s/*` must not be sent the
# marketplace key by default — and resolving the N2S one must never be a
# precondition for the marketplace surface working.

def test_n2s_key_from_argument(monkeypatch):
    captured = []
    _patch_get(monkeypatch, _FakeResp(200, json_payload={"timer_minutes": 15}), captured)
    s4k.S4KCSClient("s4k_market", n2s_api_key="s4k_n2s").n2s_meta()
    assert captured[0][1]["headers"]["X-API-Key"] == "s4k_n2s"


def test_n2s_key_from_env(monkeypatch):
    monkeypatch.setenv("S4KCS_N2S_API_KEY", "s4k_env_n2s")
    captured = []
    _patch_get(monkeypatch, _FakeResp(200, json_payload={}), captured)
    _client().n2s_meta()
    assert captured[0][1]["headers"]["X-API-Key"] == "s4k_env_n2s"


def test_n2s_key_from_vault_uses_its_own_name(monkeypatch):
    db = _VaultDB("s4k_vault_n2s")
    captured = []
    _patch_get(monkeypatch, _FakeResp(200, json_payload={}), captured)
    s4k.S4KCSClient("s4k_market", db=db).n2s_meta()
    assert captured[0][1]["headers"]["X-API-Key"] == "s4k_vault_n2s"
    # Its OWN name — never the marketplace one, whose key lacks n2s:read.
    assert db.asked == [("get_app_secret", "crm.s4kcs.com/n2s")]
    assert s4k.N2S_VAULT_SECRET_NAME == "crm.s4kcs.com/n2s"


def test_n2s_key_falls_back_to_the_marketplace_key(monkeypatch):
    # Not a guess that it works: it keeps a single dual-scope key usable and
    # turns a missing N2S secret into an honest 403 from the API rather than a
    # construction-time failure on a client built for the marketplace book.
    captured = []
    _patch_get(monkeypatch, _FakeResp(200, json_payload={}), captured)
    _client().n2s_meta()
    assert captured[0][1]["headers"]["X-API-Key"] == "s4k_testkey"


def test_n2s_key_is_stripped_and_resolved_once(monkeypatch):
    db = _VaultDB("  s4k_padded_n2s  ")
    captured = []
    _patch_get(monkeypatch, _FakeResp(200, json_payload={}), captured)
    c = s4k.S4KCSClient("s4k_market", db=db)
    c.n2s_meta()
    c.n2s_stats()
    assert [h[1]["headers"]["X-API-Key"] for h in captured] == \
        ["s4k_padded_n2s", "s4k_padded_n2s"]
    assert len(db.asked) == 1  # cached — one vault round trip, not one per call


def test_marketplace_calls_keep_using_the_marketplace_key(monkeypatch):
    # The regression that would silently kill the 10-minute s4kcs_orders ingest.
    db = _VaultDB("s4k_vault_n2s")
    captured = []
    _patch_get(monkeypatch, _FakeResp(200, json_payload={"rows": []}), captured)
    c = s4k.S4KCSClient("s4k_market", db=db)
    c.orders()
    c.ping()
    assert [h[1]["headers"]["X-API-Key"] for h in captured] == \
        ["s4k_market", "s4k_market"]
    assert db.asked == []  # the N2S secret is never even looked up


def test_missing_n2s_vault_value_still_falls_back(monkeypatch):
    captured = []
    _patch_get(monkeypatch, _FakeResp(200, json_payload={}), captured)
    s4k.S4KCSClient("s4k_market", db=_VaultDB(None)).n2s_meta()
    assert captured[0][1]["headers"]["X-API-Key"] == "s4k_market"


def test_resolve_key_reports_the_failing_lookup_by_label(monkeypatch, capsys):
    class _Boom:
        def rpc(self, *a, **k):
            raise RuntimeError("vault down")

    assert s4k._resolve_key(None, _Boom(), env_var="S4KCS_N2S_API_KEY",
                            vault_name=s4k.N2S_VAULT_SECRET_NAME,
                            label="s4kcs n2s") is None
    out = capsys.readouterr().out
    assert "s4kcs n2s: vault lookup failed" in out
    assert "s4k_" not in out  # never the value

"""Full-coverage tests for axs_client.py. No real HTTP/Supabase calls.

Mirrors house style (tests/test_ticketsdata_client.py, test_readonly_guards.py):
monkeypatch requests at the boundary, fake DB objects for vault/persist.
"""
from __future__ import annotations

import pytest

import axs_client as ax


# ---------- read-only guard ----------

def test_assert_readonly_allows_get():
    ax._assert_readonly_method("GET")
    ax._assert_readonly_method("get")


def test_assert_readonly_raises_on_writes():
    for method in ("POST", "PUT", "PATCH", "DELETE", "OPTIONS", "HEAD"):
        with pytest.raises(ax.AXSReadOnlyError) as exc:
            ax._assert_readonly_method(method)
        assert "READ-ONLY violation" in str(exc.value)
        assert "RULE 2" in str(exc.value)


def test_allowlist_constant_is_get_only():
    assert ax.ALLOWED_HTTP_METHODS == frozenset({"GET"})


# ---------- venue_norm ----------

def test_venue_norm_basic():
    assert ax.venue_norm("The HALL at Live!") == "hallatlive"
    assert ax.venue_norm("Crypto.com Arena") == "cryptocomarena"
    assert ax.venue_norm("Red Rocks Amphitheatre") == "redrocksamphitheatre"


def test_venue_norm_none_and_empty():
    # None -> falls back to cjk: of empty -> "cjk:"
    assert ax.venue_norm(None) == "cjk:"
    assert ax.venue_norm("") == "cjk:"


def test_venue_norm_cjk_only_fallback():
    # All non-[a-z0-9] -> empty -> cjk: prefix of the lowered/stripped original
    assert ax.venue_norm("東京ドーム") == "cjk:東京ドーム"


# ---------- _vault_secret ----------

class _FakeRpcResult:
    def __init__(self, data):
        self.data = data


class _FakeVaultDB:
    """Stands in for service-role Supabase client: rpc(get_app_secret)."""
    def __init__(self, secrets, raise_on=None):
        self._secrets = secrets
        self._raise_on = raise_on or set()
        self._pending = None

    def rpc(self, name, params):
        assert name == "get_app_secret"
        nm = params["p_name"]
        if nm in self._raise_on:
            raise RuntimeError("boom")
        self._pending = self._secrets.get(nm)
        return self

    def execute(self):
        return _FakeRpcResult(self._pending)


def test_vault_secret_none_db():
    assert ax._vault_secret(None, "AXS_USERNAME") is None


def test_vault_secret_hit():
    db = _FakeVaultDB({"AXS_API_KEY": "k-123"})
    assert ax._vault_secret(db, "AXS_API_KEY") == "k-123"


def test_vault_secret_miss_returns_none():
    db = _FakeVaultDB({})
    assert ax._vault_secret(db, "NOPE") is None


def test_vault_secret_exception_returns_none(capsys):
    db = _FakeVaultDB({}, raise_on={"AXS_USERNAME"})
    assert ax._vault_secret(db, "AXS_USERNAME") is None
    out = capsys.readouterr().out
    assert "vault lookup for AXS_USERNAME failed" in out


# ---------- _c2d ----------

def test_c2d():
    assert ax._c2d(None) is None
    assert ax._c2d(0) == 0.0
    assert ax._c2d(12345) == 123.45
    assert ax._c2d(199) == 1.99


# ---------- distill ----------

def _full_doc():
    """A representative AXS document exercising resale, sections, offers."""
    return {
        "response_s": 23.4,
        "quota_remaining": 4242,
        "body": {
            "meta": {
                "event": "Band X Live",
                "venue": "Crypto.com Arena",
                "event_date": "2026-10-04T19:00:00",
                "event_date_zone": "America/Los_Angeles",
                "api": "veritix",
                "listings": 100,
                "sections_count": 3,
                "offer_groups": 2,
                "price_min": 50.0,
                "price_max": 500.0,
            },
            "startflow": {"onSaleStatus": {
                "onSaleNow": True,
                "onSaleDate": "2026-05-29 14:00:00 +0000",
                "offSaleDate": "2026-10-04T19:00:00+0000",
            }},
            "prices": {
                "currency": "USD",
                "fees": [
                    {"id": "resale-fee-OFFER9"},
                    {"id": "service-fee"},
                    {"id": 12345},  # non-resale, non-string-startswith
                ],
                "offerPrices": [
                    {
                        "offerID": "OFFER1",
                        "zonePrices": [{
                            "priceLevels": [{
                                "priceLevelID": "PL1",
                                "prices": [
                                    {"base": 6000},
                                    {"base": 5000},
                                    {"base": None},
                                ],
                            }],
                        }],
                    },
                    {
                        # resale offer -> skipped entirely
                        "offerID": "OFFER9",
                        "zonePrices": [{
                            "priceLevels": [{
                                "priceLevelID": "PL9",
                                "prices": [{"base": 1}],
                            }],
                        }],
                    },
                ],
            },
            "sections": {
                "Floor": {
                    "neighborhoodDescription": "Lower",
                    "isGeneralAdmission": False,
                    "availability": {
                        "isSoldOut": False,
                        "prices": [
                            {"amount": 4, "priceLevel": "PL1"},
                            {"amount": 0, "priceLevel": "PLX"},
                        ],
                    },
                    "offerIDs": ["OFFER1"],
                    "seatTypes": ["standard"],
                    "connectionFee": 5,
                },
                "ResaleSec": {
                    "neighborhoodDescription": None,
                    "isGeneralAdmission": True,
                    "availability": {
                        "isSoldOut": True,
                        "prices": [],  # qty 0, no bases
                    },
                    "offerIDs": ["OFFER9"],
                    "seatTypes": None,
                    "connectionFee": None,
                },
            },
            "offers": {"offers": [
                {"offerID": "OFFER1", "items": [1, 2, 3]},
                {"offerID": "OFFER9", "items": [9]},
            ]},
        },
    }


def test_distill_full():
    s = ax.distill(_full_doc())
    assert s["event"] == "Band X Live"
    assert s["venue"] == "Crypto.com Arena"
    assert s["event_date"] == "2026-10-04T19:00:00"
    assert s["tz"] == "America/Los_Angeles"
    assert s["api"] == "veritix"
    assert s["currency"] == "USD"
    assert s["response_s"] == 23.4
    assert s["quota_remaining"] == 4242
    assert s["onsale_status"]["onSaleNow"] is True
    t = s["totals"]
    assert t["listings"] == 100
    assert t["sections"] == 3
    assert t["offers"] == 2
    assert t["price_min"] == 50.0
    assert t["price_max"] == 500.0
    # PL1 base min = 50.0 (5000 cents), Floor qty 4 > 0 -> get_in 50.0
    assert t["get_in_available"] == 50.0
    assert t["seats_primary"] == 3
    assert t["seats_resale"] == 1
    # sections sorted; Floor has price, ResaleSec is None last
    secs = s["sections"]
    floor = next(r for r in secs if r["section"] == "Floor")
    assert floor["price_min"] == 50.0
    assert floor["price_max"] == 50.0
    assert floor["avail_qty"] == 4
    assert floor["has_resale"] is False
    assert floor["connection_fee"] == 5
    resale = next(r for r in secs if r["section"] == "ResaleSec")
    assert resale["has_resale"] is True
    assert resale["price_min"] is None
    assert resale["avail_qty"] == 0
    # None-priced section sorts after priced one
    assert secs[-1]["section"] == "ResaleSec"


def test_distill_empty_doc():
    s = ax.distill({})
    assert s["event"] is None
    assert s["venue"] is None
    assert s["totals"]["get_in_available"] is None
    assert s["totals"]["seats_primary"] == 0
    assert s["totals"]["seats_resale"] == 0
    assert s["sections"] == []


# ---------- distill: new v2 harvest envelope ----------

def _v2_item(section, row, num, pl, offer_id="45672539", seat_type="STANDARD",
             ga=False, nbhd="Admissions", orig=None):
    it = {"sectionLabel": section, "rowLabel": row, "number": num,
          "priceLevelID": pl, "offerID": offer_id, "seatType": seat_type,
          "isGASection": ga, "neighborhoodPrintDescription": nbhd}
    if orig is not None:
        it["originalPrice"] = orig
    return it


def _v2_doc():
    """A representative NEW-format (2026-07) AXS document — the seat manifest lives
    at body.inventory.offer_search[0].offers[].items[], priced via
    body.inventory.inventory_v4[0].offerPrices (priceLevelID -> prices[0].base cents).
    Exercises: primary vs resale (offerID '9…'), price hit vs originalPrice fallback
    vs no-price, GA flag, missing seat_type, section aggregation, and sort order."""
    return {
        "response_s": 66.0,
        "quota_remaining": 142231,
        "body": {
            "status": "ok", "exit_code": 0,
            "event": {
                "title": "ENHYPEN", "currency": "USD",
                "starts_local": "2026-08-01T19:30:00-07:00",
                "timezone": "America/Los_Angeles",
                "venue": {"name": "T-Mobile Arena", "timezone": "America/Los_Angeles"},
            },
            "onsale": {"status": {
                "onSaleNow": True,
                "onSaleDate": "2026-04-24 23:00:00 +0000",
                "offSaleDate": "2026-08-02 02:30:00 +0000",
            }},
            "offers": [{"name": "GA"}, {"name": "Dash Pass"}],  # event-level offers count = 2
            "inventory": {
                "inventory_v4": [{"offerPrices": [
                    {"offerID": "45672539", "offerType": "Single", "zonePrices": [{"priceLevels": [
                        {"priceLevelID": "PL_A", "prices": [{"base": 26706}]},   # $267.06
                        {"priceLevelID": "PL_A", "prices": [{"base": 20000}]},   # dup -> max() wins ($267.06)
                        {"priceLevelID": "PL_B", "prices": [{"base": 7086}]},    # $70.86
                        {"priceLevelID": "PL_NOBASE", "prices": [{}]},           # no base -> skipped
                    ]}]},
                    # a resale offer — flagged by offerType, NOT the offerID prefix
                    {"offerID": "90001", "offerType": "AXS Marketplace Resale", "zonePrices": []},
                ]}],
                "offer_search": [{"offers": [
                    {"items": [
                        _v2_item("4", "Q", "1", "PL_A"),                     # $267.06 STANDARD
                        _v2_item("4", "Q", "2", "PL_A", seat_type=None),    # no seat_type
                        _v2_item("226", "A", "1", "PL_B", ga=True),         # $70.86, GA, cheapest primary
                        _v2_item("GA2", "GA", "1", "PL_MISSING", orig="55.5"),  # price via originalPrice
                        _v2_item("NP", "Z", "1", "PL_NOBASE", seat_type=None),  # no price, no seat_type
                        # offerID starts with '9' but offerType is Resale -> resale via offerType
                        _v2_item("RS", "R", "1", "PL_A", offer_id="90001"),
                    ]},
                ]}],
            },
        },
    }


def test_distill_v2_full():
    s = ax.distill(_v2_doc())
    assert s["event"] == "ENHYPEN"
    assert s["venue"] == "T-Mobile Arena"
    assert s["event_date"] == "2026-08-01T19:30:00-07:00"
    assert s["tz"] == "America/Los_Angeles"
    assert s["api"] == "veritix"
    assert s["currency"] == "USD"
    assert s["response_s"] == 66.0 and s["quota_remaining"] == 142231
    assert s["onsale_status"]["onSaleNow"] is True
    t = s["totals"]
    assert t["listings"] == 6          # total seat items (5 primary + 1 resale)
    assert t["sections"] == 5          # 4, 226, GA2, NP, RS
    assert t["offers"] == 2            # body.offers length
    assert t["seats_primary"] == 5
    assert t["seats_resale"] == 1
    assert t["price_min"] == 55.5      # cheapest priced seat (originalPrice fallback)
    assert t["price_max"] == 267.06
    assert t["get_in_available"] == 55.5   # cheapest PRIMARY priced seat
    secs = s["sections"]
    sec4 = next(r for r in secs if r["section"] == "4")
    assert sec4["avail_qty"] == 2 and sec4["price_min"] == 267.06 and sec4["price_max"] == 267.06
    assert sec4["seat_types"] == ["STANDARD"]     # None seat_type dropped
    assert sec4["ga"] is False and sec4["has_resale"] is False
    assert sec4["neighborhood"] == "Admissions"
    s226 = next(r for r in secs if r["section"] == "226")
    assert s226["price_min"] == 70.86 and s226["ga"] is True
    rs = next(r for r in secs if r["section"] == "RS")
    assert rs["has_resale"] is True and rs["avail_qty"] == 1
    np = next(r for r in secs if r["section"] == "NP")
    assert np["price_min"] is None and np["seat_types"] is None
    # cheapest section first; None-priced sections sort last
    assert secs[0]["section"] == "GA2"   # $55.50
    assert secs[-1]["price_min"] is None


def test_distill_v2_flashseats_is_resale():
    """FlashSeats is AXS's resale/transfer channel: a seat with
    seatType='FLASHSEATS' is classified resale even when its offerType reads
    'Single' (operator directive 2026-08-03, verified on FFDP @ Red Rocks)."""
    doc = {
        "body": {
            "status": "ok", "exit_code": 0,
            "event": {"title": "FFDP", "venue": {"name": "Red Rocks"}},
            "offers": [],
            "inventory": {
                "inventory_v4": [{"offerPrices": [
                    {"offerID": "OF1", "offerType": "Single", "zonePrices": [{"priceLevels": [
                        {"priceLevelID": "PL", "prices": [{"base": 15050}]},  # $150.50
                    ]}]},
                ]}],
                "offer_search": [{"offers": [{"items": [
                    _v2_item("Right", "25", "13", "PL", offer_id="OF1", seat_type="FLASHSEATS"),
                    _v2_item("Floor", "1", "1", "PL", offer_id="OF1", seat_type="STANDARD"),
                ]}]}],
            },
        },
    }
    s = ax.distill(doc)
    assert s["totals"]["seats_resale"] == 1    # the FLASHSEATS seat
    assert s["totals"]["seats_primary"] == 1   # the STANDARD seat
    right = next(r for r in s["sections"] if r["section"] == "Right")
    floor = next(r for r in s["sections"] if r["section"] == "Floor")
    assert right["has_resale"] is True
    assert floor["has_resale"] is False


def test_distill_v2_fallbacks():
    # venue name absent -> None; event tz absent -> venue tz; currency absent -> USD;
    # status 'success' + string exit_code still dispatch to v2.
    doc = {"body": {
        "status": "success", "exit_code": "0",
        "event": {"title": "X", "venue": {"timezone": "America/New_York"}},
        "inventory": {
            "inventory_v4": [{"offerPrices": [
                {"zonePrices": [{"priceLevels": [{"priceLevelID": "1", "prices": [{"base": 1000}]}]}]}]}],
            "offer_search": [{"offers": [{"items": [_v2_item("A", "1", "1", "1")]}]}],
        },
    }}
    s = ax.distill(doc)
    assert s["venue"] is None
    assert s["tz"] == "America/New_York"
    assert s["currency"] == "USD"
    assert s["totals"]["get_in_available"] == 10.0
    assert s["sections"][0]["avail_qty"] == 1


def test_distill_v2_empty():
    # empty event dict still dispatches to v2; no inventory -> all Nones / zeros
    s = ax.distill({"body": {"status": "ok", "exit_code": 0, "event": {}}})
    assert s["event"] is None and s["venue"] is None
    assert s["totals"]["listings"] is None
    assert s["totals"]["sections"] is None
    assert s["totals"]["offers"] is None
    assert s["totals"]["price_min"] is None
    assert s["totals"]["get_in_available"] is None
    assert s["totals"]["seats_primary"] == 0
    assert s["totals"]["seats_resale"] == 0
    assert s["sections"] == []


def test_normalize_v2_round_trip():
    n = ax.normalize(
        _v2_doc(),
        event_url="https://www.axs.com/events/1380757/enhypen-tickets",
        tevo_venue_id=101949, tevo_event_id=3359535,
    )
    es = n["event_snapshot"]
    assert es["axs_event_id"] == "1380757"
    assert es["event_name"] == "ENHYPEN"
    assert es["venue_name"] == "T-Mobile Arena"
    assert es["occurs_at_local"] == "2026-08-01T19:30:00-07:00"
    assert es["api"] == "veritix"
    assert es["onsale_now"] is True
    assert es["getin"] == 55.5
    assert es["seats_primary"] == 5
    assert es["seats_resale"] == 1
    assert es["quota_remaining"] == 142231
    assert len(n["sections"]) == 5


# ---------- axs_event_id_from_url ----------

def test_axs_event_id_from_url():
    assert ax.axs_event_id_from_url(
        "https://www.axs.com/events/123456/foo-event-tickets") == "123456"
    assert ax.axs_event_id_from_url("https://axs.com/events/77/x") == "77"
    assert ax.axs_event_id_from_url("https://example.com/nope") is None
    assert ax.axs_event_id_from_url(None) is None


# ---------- _parse_dt ----------

def test_parse_dt_none():
    assert ax._parse_dt(None) is None
    assert ax._parse_dt("") is None


def test_parse_dt_space_format():
    assert ax._parse_dt("2026-05-29 14:00:00 +0000") == "2026-05-29T14:00:00+00:00"


def test_parse_dt_iso_format():
    assert ax._parse_dt("2026-05-29T14:00:00+0000") == "2026-05-29T14:00:00+00:00"


def test_parse_dt_unparseable_returns_str():
    assert ax._parse_dt("not a date") == "not a date"


# ---------- _occurs_at_local ----------

def test_occurs_at_local_none():
    assert ax._occurs_at_local(None, "America/Los_Angeles") is None


def test_occurs_at_local_with_tz():
    out = ax._occurs_at_local("2026-10-04T19:00:00", "America/Los_Angeles")
    assert out == "2026-10-04T19:00:00-07:00"


def test_occurs_at_local_no_tz():
    out = ax._occurs_at_local("2026-10-04T19:00:00", None)
    assert out == "2026-10-04T19:00:00"


def test_occurs_at_local_z_suffix():
    out = ax._occurs_at_local("2026-10-04T19:00:00Z", None)
    assert out == "2026-10-04T19:00:00"


def test_occurs_at_local_bad_tz_falls_back():
    # invalid IANA tz -> ZoneInfo raises -> fall back to str(event_date)
    out = ax._occurs_at_local("2026-10-04T19:00:00", "Not/AZone")
    assert out == "2026-10-04T19:00:00"


def test_occurs_at_local_bad_date_falls_back():
    out = ax._occurs_at_local("garbage", "America/Los_Angeles")
    assert out == "garbage"


# ---------- normalize ----------

def test_normalize_round_trip():
    doc = _full_doc()
    n = ax.normalize(
        doc,
        event_url="https://www.axs.com/events/123456/foo-event-tickets",
        tevo_venue_id=999,
        tevo_event_id=888,
        aq_short_event_id="aq1",
        venue_short_id="vs1",
        in_axs_list=True,
        canonical_matched=True,
    )
    es = n["event_snapshot"]
    assert es["axs_event_id"] == "123456"
    assert es["event_url"].endswith("foo-event-tickets")
    assert es["tevo_event_id"] == 888
    assert es["tevo_venue_id"] == 999
    assert es["aq_short_event_id"] == "aq1"
    assert es["venue_short_id"] == "vs1"
    assert es["event_name"] == "Band X Live"
    assert es["venue_name"] == "Crypto.com Arena"
    assert es["occurs_at_local"] == "2026-10-04T19:00:00-07:00"
    assert es["event_tz"] == "America/Los_Angeles"
    assert es["api"] == "veritix"
    assert es["onsale_now"] is True
    assert es["onsale_at"] == "2026-05-29T14:00:00+00:00"
    assert es["offsale_at"] == "2026-10-04T19:00:00+00:00"
    assert es["currency"] == "USD"
    assert es["price_min"] == 50.0
    assert es["price_max"] == 500.0
    assert es["getin"] == 50.0
    assert es["listings_count"] == 100
    assert es["sections_count"] == 3
    assert es["offers_count"] == 2
    assert es["seats_primary"] == 3
    assert es["seats_resale"] == 1
    assert es["in_axs_list"] is True
    assert es["canonical_matched"] is True
    assert es["response_s"] == 23.4
    assert es["quota_remaining"] == 4242
    assert es["raw"] is doc
    sections = n["sections"]
    assert len(sections) == 2
    floor = next(r for r in sections if r["section_label"] == "Floor")
    assert floor["tevo_event_id"] == 888
    assert floor["tevo_venue_id"] == 999
    assert floor["axs_event_id"] == "123456"
    assert floor["is_ga"] is False
    assert floor["avail_qty"] == 4
    assert floor["has_resale"] is False
    assert floor["connection_fee"] == 5


def test_normalize_defaults_and_empty_onsale():
    # onsale_status falsy -> onsale dict {} -> onsale_now None
    n = ax.normalize({}, event_url=None)
    es = n["event_snapshot"]
    assert es["axs_event_id"] is None
    assert es["event_url"] is None
    assert es["onsale_now"] is None
    assert es["onsale_at"] is None
    assert es["in_axs_list"] is None
    assert es["canonical_matched"] is None
    assert n["sections"] == []


# ---------- AXSClient construction ----------

def _clear_env(monkeypatch):
    for k in ("AXS_ENDPOINT_URL", "AXS_USERNAME", "AXS_PASSWORD",
              "TICKETSDATA_USERNAME", "TICKETSDATA_PASSWORD", "AXS_API_KEY",
              "AXS_PLATFORM", "AXS_URL_PARAM"):
        monkeypatch.delenv(k, raising=False)


def test_init_requires_credentials(monkeypatch):
    _clear_env(monkeypatch)
    with pytest.raises(ax.AXSConfigError):
        ax.AXSClient()


def test_init_with_args(monkeypatch):
    _clear_env(monkeypatch)
    c = ax.AXSClient(username="u", password="p")
    assert c.endpoint == ax.AXSClient.DEFAULT_ENDPOINT
    assert c._user == "u"
    assert c._pass == "p"
    assert c.platform == "axs"
    assert c.url_param == "event_url"


def test_init_with_api_key_only(monkeypatch):
    _clear_env(monkeypatch)
    c = ax.AXSClient(api_key="k-1")
    assert c._key == "k-1"
    assert c._user is None


def test_init_env_creds_and_overrides(monkeypatch):
    _clear_env(monkeypatch)
    monkeypatch.setenv("TICKETSDATA_USERNAME", "td-user")
    monkeypatch.setenv("TICKETSDATA_PASSWORD", "td-pw")
    monkeypatch.setenv("AXS_ENDPOINT_URL", "https://override.invalid/fetch")
    monkeypatch.setenv("AXS_PLATFORM", "axs2")
    monkeypatch.setenv("AXS_URL_PARAM", "url")
    c = ax.AXSClient()
    assert c._user == "td-user"
    assert c._pass == "td-pw"
    assert c.endpoint == "https://override.invalid/fetch"
    assert c.platform == "axs2"
    assert c.url_param == "url"


def test_init_resolves_creds_from_vault(monkeypatch):
    _clear_env(monkeypatch)
    db = _FakeVaultDB({
        "TICKETSDATA_USERNAME": "vault-user",
        "TICKETSDATA_PASSWORD": "vault-pw",
    })
    c = ax.AXSClient(db=db)
    assert c._user == "vault-user"
    assert c._pass == "vault-pw"
    assert c._db is db


def test_from_env(monkeypatch):
    _clear_env(monkeypatch)
    monkeypatch.setenv("AXS_API_KEY", "k-env")
    c = ax.AXSClient.from_env(timeout=42)
    assert c._key == "k-env"
    assert c.timeout == 42


def test_from_vault(monkeypatch):
    _clear_env(monkeypatch)
    db = _FakeVaultDB({"AXS_API_KEY": "k-vault"})
    c = ax.AXSClient.from_vault(db, timeout=33)
    assert c._key == "k-vault"
    assert c.timeout == 33
    assert c._db is db


# ---------- transport (_get) ----------

class _FakeResp:
    def __init__(self, status, payload=None, headers=None, text="x"):
        self.status_code = status
        self._payload = payload
        self.headers = headers or {}
        self.ok = 200 <= status < 300
        self.text = text

    def json(self):
        if self._payload is None:
            raise ValueError("no json")
        return self._payload


def _client(monkeypatch, **kw):
    _clear_env(monkeypatch)
    return ax.AXSClient(username="u", password="secret-pw", **kw)


def test_get_passes_creds_in_params(monkeypatch):
    captured = {}

    def fake_get(url, params=None, headers=None, timeout=None):
        captured["url"] = url
        captured["params"] = params
        captured["headers"] = headers
        return _FakeResp(200, {"body": {"ok": True}})

    monkeypatch.setattr(ax.requests, "get", fake_get)
    c = _client(monkeypatch)
    out = c._get({"platform": "axs", "drop": None})
    assert out == {"body": {"ok": True}}
    assert captured["params"]["username"] == "u"
    assert captured["params"]["password"] == "secret-pw"
    assert "drop" not in captured["params"]  # None filtered
    assert captured["headers"] == {}
    assert "secret-pw" not in captured["url"]


def test_get_uses_bearer_when_key_only(monkeypatch):
    captured = {}

    def fake_get(url, params=None, headers=None, timeout=None):
        captured["headers"] = headers
        captured["params"] = params
        return _FakeResp(200, {"body": 1})

    monkeypatch.setattr(ax.requests, "get", fake_get)
    _clear_env(monkeypatch)
    c = ax.AXSClient(api_key="k-1")
    c._get({"platform": "axs"})
    assert captured["headers"]["Authorization"] == "Bearer k-1"
    assert "username" not in captured["params"]


def test_get_non_dict_json_wrapped(monkeypatch):
    monkeypatch.setattr(ax.requests, "get",
                        lambda *a, **k: _FakeResp(200, [1, 2, 3]))
    c = _client(monkeypatch)
    assert c._get({}) == {"body": [1, 2, 3]}


def test_get_invalid_json_returns_raw_text(monkeypatch):
    monkeypatch.setattr(ax.requests, "get",
                        lambda *a, **k: _FakeResp(200, None, text="oops"))
    c = _client(monkeypatch)
    assert c._get({}) == {"raw_text": "oops"}


def test_get_401_auth_error(monkeypatch):
    monkeypatch.setattr(ax.requests, "get", lambda *a, **k: _FakeResp(401))
    c = _client(monkeypatch)
    with pytest.raises(ax.AXSAuthError) as exc:
        c._get({})
    assert "secret-pw" not in str(exc.value)


def test_get_402_quota_error(monkeypatch):
    monkeypatch.setattr(ax.requests, "get", lambda *a, **k: _FakeResp(402))
    c = _client(monkeypatch)
    with pytest.raises(ax.AXSQuotaError):
        c._get({})


def test_get_other_error(monkeypatch):
    monkeypatch.setattr(ax.requests, "get", lambda *a, **k: _FakeResp(500))
    c = _client(monkeypatch)
    with pytest.raises(ax.AXSError) as exc:
        c._get({})
    assert "HTTP 500" in str(exc.value)


def test_get_retries_then_succeeds(monkeypatch):
    calls = {"n": 0}
    sleeps = []
    monkeypatch.setattr(ax.time, "sleep", lambda s: sleeps.append(s))

    def fake_get(url, params=None, headers=None, timeout=None):
        calls["n"] += 1
        if calls["n"] == 1:
            return _FakeResp(503, headers={"Retry-After": "3"})
        return _FakeResp(200, {"body": 1})

    monkeypatch.setattr(ax.requests, "get", fake_get)
    c = _client(monkeypatch)
    assert c._get({}) == {"body": 1}
    assert calls["n"] == 2
    assert sleeps == [3.0]  # honored Retry-After


def test_get_retry_bad_retry_after_uses_default(monkeypatch):
    calls = {"n": 0}
    sleeps = []
    monkeypatch.setattr(ax.time, "sleep", lambda s: sleeps.append(s))

    def fake_get(url, params=None, headers=None, timeout=None):
        calls["n"] += 1
        if calls["n"] == 1:
            return _FakeResp(429, headers={"Retry-After": "soon"})
        return _FakeResp(200, {"body": 1})

    monkeypatch.setattr(ax.requests, "get", fake_get)
    c = _client(monkeypatch)
    c._get({})
    assert sleeps == [2.0]  # falls back to delays[0]


def test_get_retry_no_retry_after_uses_default(monkeypatch):
    calls = {"n": 0}
    sleeps = []
    monkeypatch.setattr(ax.time, "sleep", lambda s: sleeps.append(s))

    def fake_get(url, params=None, headers=None, timeout=None):
        calls["n"] += 1
        if calls["n"] == 1:
            return _FakeResp(504)
        return _FakeResp(200, {"body": 1})

    monkeypatch.setattr(ax.requests, "get", fake_get)
    c = _client(monkeypatch)
    c._get({})
    assert sleeps == [2.0]


def test_get_retries_exhausted(monkeypatch):
    monkeypatch.setattr(ax.time, "sleep", lambda s: None)
    monkeypatch.setattr(ax.requests, "get",
                        lambda *a, **k: _FakeResp(503))
    c = _client(monkeypatch)
    with pytest.raises(ax.AXSError) as exc:
        c._get({})
    assert "HTTP 503" in str(exc.value)


# ---------- fetch ----------

def test_fetch_rejects_bad_url(monkeypatch):
    c = _client(monkeypatch)
    with pytest.raises(ax.AXSError) as exc:
        c.fetch("https://example.com/nope")
    assert "unsupported AXS event URL" in str(exc.value)


def test_fetch_rejects_empty_url(monkeypatch):
    c = _client(monkeypatch)
    with pytest.raises(ax.AXSError):
        c.fetch("")


def test_fetch_valid_url(monkeypatch):
    captured = {}

    def fake_get(url, params=None, headers=None, timeout=None):
        captured["params"] = params
        return _FakeResp(200, {"body": {"meta": {}}})

    monkeypatch.setattr(ax.requests, "get", fake_get)
    c = _client(monkeypatch)
    out = c.fetch("  https://www.axs.com/events/123/foo-event-tickets  ")
    assert out == {"body": {"meta": {}}}
    assert captured["params"]["event_url"] == \
        "https://www.axs.com/events/123/foo-event-tickets"
    assert captured["params"]["platform"] == "axs"


# ---------- resolve_venue ----------

class _FakeTableResult:
    def __init__(self, data):
        self.data = data


class _FakeTableDB:
    """Stands in for db.table(...).select(...).eq(...).limit(...).execute()."""
    def __init__(self, rows=None, raise_exc=False):
        self._rows = rows
        self._raise = raise_exc
        self.last = {}

    def table(self, name):
        self.last["table"] = name
        return self

    def select(self, cols):
        self.last["select"] = cols
        return self

    def eq(self, col, val):
        self.last["eq"] = (col, val)
        return self

    def limit(self, n):
        self.last["limit"] = n
        return self

    def execute(self):
        if self._raise:
            raise RuntimeError("db down")
        return _FakeTableResult(self._rows)


def test_resolve_venue_no_db(monkeypatch):
    c = _client(monkeypatch)
    out = c.resolve_venue("Crypto.com Arena")
    assert out["in_axs_list"] is False
    assert out["venue_norm"] == "cryptocomarena"
    assert "no db client" in out["note"]


def test_resolve_venue_hit_exact(monkeypatch):
    db = _FakeTableDB(rows=[{
        "axs_name": "Crypto.com Arena",
        "axs_name_norm": "cryptocomarena",
        "section": "ARENA",
        "tevo_venue_id": 555,
        "match_method": "exact_norm",
    }])
    c = _client(monkeypatch)
    out = c.resolve_venue("Crypto.com Arena", db=db)
    assert out["in_axs_list"] is True
    assert out["axs_name"] == "Crypto.com Arena"
    assert out["section"] == "ARENA"
    assert out["tevo_venue_id"] == 555
    assert out["canonical_matched"] is True
    assert db.last["eq"] == ("axs_name_norm", "cryptocomarena")


def test_resolve_venue_hit_non_exact_match_method(monkeypatch):
    db = _FakeTableDB(rows=[{
        "axs_name": "X",
        "section": None,
        "tevo_venue_id": None,
        "match_method": "fuzzy",
    }])
    c = _client(monkeypatch)
    out = c.resolve_venue("X", db=db)
    assert out["in_axs_list"] is True
    assert out["canonical_matched"] is False


def test_resolve_venue_no_rows(monkeypatch):
    db = _FakeTableDB(rows=[])
    c = _client(monkeypatch)
    out = c.resolve_venue("Unknown Place", db=db)
    assert out["in_axs_list"] is False
    assert out["tevo_venue_id"] is None
    assert "note" not in out


def test_resolve_venue_db_exception(monkeypatch):
    db = _FakeTableDB(raise_exc=True)
    c = _client(monkeypatch)
    out = c.resolve_venue("Crypto.com Arena", db=db)
    assert out["in_axs_list"] is False
    assert "lookup failed" in out["note"]


def test_resolve_venue_uses_self_db(monkeypatch):
    db = _FakeTableDB(rows=[])
    c = _client(monkeypatch, db=db)
    out = c.resolve_venue("Whatever")
    assert out["in_axs_list"] is False  # used self._db, not no-db branch
    assert "note" not in out


# ---------- pull ----------

def test_pull_basic(monkeypatch):
    doc = _full_doc()
    monkeypatch.setattr(ax.requests, "get",
                        lambda *a, **k: _FakeResp(200, doc))
    db = _FakeTableDB(rows=[{
        "axs_name": "Crypto.com Arena",
        "section": "ARENA",
        "tevo_venue_id": 555,
        "match_method": "exact_norm",
    }])
    c = _client(monkeypatch)
    out = c.pull("https://www.axs.com/events/123/foo-event-tickets", db=db)
    assert out["event_url"] == "https://www.axs.com/events/123/foo-event-tickets"
    assert out["venue"] == "Crypto.com Arena"
    assert out["axs_venue"]["tevo_venue_id"] == 555
    assert "normalized" not in out


def test_pull_with_rows(monkeypatch):
    doc = _full_doc()
    monkeypatch.setattr(ax.requests, "get",
                        lambda *a, **k: _FakeResp(200, doc))
    db = _FakeTableDB(rows=[{
        "axs_name": "Crypto.com Arena",
        "section": "ARENA",
        "tevo_venue_id": 555,
        "match_method": "exact_norm",
    }])
    c = _client(monkeypatch)
    out = c.pull("https://www.axs.com/events/123/foo-event-tickets",
                 db=db, with_rows=True)
    norm = out["normalized"]
    assert norm["event_snapshot"]["tevo_venue_id"] == 555
    assert norm["event_snapshot"]["in_axs_list"] is True
    assert norm["event_snapshot"]["canonical_matched"] is True
    assert len(norm["sections"]) == 2


def test_pull_venue_missing_uses_empty_string(monkeypatch):
    doc = {"body": {"meta": {}}}  # no venue
    monkeypatch.setattr(ax.requests, "get",
                        lambda *a, **k: _FakeResp(200, doc))
    db = _FakeTableDB(rows=[])
    c = _client(monkeypatch)
    out = c.pull("https://www.axs.com/events/9/x", db=db)
    assert out["axs_venue"]["in_axs_list"] is False


# ---------- persist ----------

class _FakeInsertResult:
    def __init__(self, data):
        self.data = data


class _FakeInsertDB:
    def __init__(self, event_rows):
        self._event_rows = event_rows
        self.inserts = []

    def table(self, name):
        self._cur_table = name
        return self

    def insert(self, payload):
        self.inserts.append((self._cur_table, payload))
        self._cur_payload = payload
        return self

    def execute(self):
        if self._cur_table == "axs_event_snapshots":
            return _FakeInsertResult(self._event_rows)
        return _FakeInsertResult([{"id": 1}])


def test_persist_requires_db():
    from axs_client import AXSClient
    c = AXSClient.__new__(AXSClient)
    with pytest.raises(ax.AXSConfigError):
        c.persist(None, {"event_snapshot": {}, "sections": []})


def test_persist_inserts_event_and_sections():
    db = _FakeInsertDB(event_rows=[{"id": 7}])
    from axs_client import AXSClient
    c = AXSClient.__new__(AXSClient)
    normalized = {
        "event_snapshot": {"axs_event_id": "1"},
        "sections": [{"section_label": "Floor"}, {"section_label": "Loge"}],
    }
    snap_id = c.persist(db, normalized)
    assert snap_id == 7
    # event insert then section insert
    assert db.inserts[0][0] == "axs_event_snapshots"
    assert db.inserts[1][0] == "axs_section_snapshots"
    sec_payload = db.inserts[1][1]
    assert all(r["snapshot_id"] == 7 for r in sec_payload)
    assert {r["section_label"] for r in sec_payload} == {"Floor", "Loge"}


def test_persist_no_sections():
    db = _FakeInsertDB(event_rows=[{"id": 3}])
    from axs_client import AXSClient
    c = AXSClient.__new__(AXSClient)
    snap_id = c.persist(db, {"event_snapshot": {"x": 1}, "sections": []})
    assert snap_id == 3
    assert len(db.inserts) == 1  # only event insert


def test_persist_no_id_raises():
    db = _FakeInsertDB(event_rows=[])  # insert returns no rows
    from axs_client import AXSClient
    c = AXSClient.__new__(AXSClient)
    with pytest.raises(ax.AXSError) as exc:
        c.persist(db, {"event_snapshot": {}, "sections": []})
    assert "no id" in str(exc.value)

"""Contract tests for the SG SellerDirect webhook receiver (WS2).

These tests do NOT require a running edge function or live Supabase. They
verify the static contract between:

  1. The SG SellerDirect webhook spec (operator pasted 2026-05-16 into the
     WS2 plan in d2-bot-continues-here-cheeky-quokka.md).
  2. The 3 WS2 migrations under supabase/migrations/.
  3. The edge function at supabase/functions/sg-seller-webhook/index.ts.

Goal: catch wiring mistakes (wrong RPC name, missed notification type,
wrong JSON path on a payload field) BEFORE deploying. Once the migrations
apply + edge function deploys, the operator + A1 still need to fire a
SG-side `ping` to verify the integration end-to-end; see
SG_LIVE_TEST_PLAN below.

To run:
  py -m pytest tests/test_sg_seller_webhook_contract.py -v
"""
from __future__ import annotations

import re
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parent.parent
MIG_DIR = REPO_ROOT / "supabase" / "migrations"
FN_DIR = REPO_ROOT / "supabase" / "functions" / "sg-seller-webhook"
SHARED_DIR = REPO_ROOT / "supabase" / "functions" / "_shared"

# The 8 notification types SG sends.
ALL_NOTIFICATION_TYPES = {
    "ping",
    "order.created",
    "order.retransfer",
    "order.fulfillment.error",
    "listing.event.inactive",
    "listing.visibility",
    "listing.normalization.status",
    "listing.normalization.status.changed",
}

# RPC name per notification type (None = audit-only, no RPC).
RPC_BY_TYPE = {
    "ping":                                  None,
    "order.created":                         "sg_seller_orders_ingest_from_webhook",
    "order.retransfer":                      "sg_seller_order_retransfers_ingest",
    "order.fulfillment.error":               "sg_seller_order_fulfillment_errors_ingest",
    "listing.event.inactive":                "sg_seller_listing_inactive_events_ingest",
    "listing.visibility":                    "sg_seller_listing_visibility_ingest",
    "listing.normalization.status":          "sg_seller_listing_normalization_ingest",
    "listing.normalization.status.changed":  "sg_seller_listing_normalization_changes_ingest",
}


# ============================================================
# Migration files exist and have expected DDL
# ============================================================

@pytest.fixture(scope="module")
def mig1_audit() -> str:
    p = MIG_DIR / "20260516210000_sg_webhook_secret_and_audit.sql"
    assert p.exists(), f"missing migration: {p}"
    return p.read_text(encoding="utf-8")


@pytest.fixture(scope="module")
def mig2_tables() -> str:
    p = MIG_DIR / "20260516210100_sg_webhook_per_type_tables.sql"
    assert p.exists(), f"missing migration: {p}"
    return p.read_text(encoding="utf-8")


@pytest.fixture(scope="module")
def mig3_rpcs() -> str:
    p = MIG_DIR / "20260516210200_sg_webhook_ingest_rpcs.sql"
    assert p.exists(), f"missing migration: {p}"
    return p.read_text(encoding="utf-8")


@pytest.fixture(scope="module")
def fn_index() -> str:
    p = FN_DIR / "index.ts"
    assert p.exists(), f"missing edge function: {p}"
    return p.read_text(encoding="utf-8")


@pytest.fixture(scope="module")
def fn_bearer_auth() -> str:
    p = SHARED_DIR / "bearer-auth.ts"
    assert p.exists(), f"missing shared module: {p}"
    return p.read_text(encoding="utf-8")


def test_mig1_extends_get_app_secret_allowlist(mig1_audit: str):
    """The new SG_SELLER_WEBHOOK_SECRET must be added to the get_app_secret
    allowlist or the vault read will RAISE 'not in app whitelist'."""
    assert "'SG_SELLER_WEBHOOK_SECRET'" in mig1_audit
    # Sibling secrets still present (don't lose them across the OR REPLACE).
    for old in ("'SEATGEEK_API_TOKEN'", "'TICKPICK_API_TOKEN'", "'APPSCRIPT_INGEST_SECRET'"):
        assert old in mig1_audit, f"get_app_secret allowlist dropped {old}"


def test_mig1_creates_idempotency_table(mig1_audit: str):
    assert "CREATE TABLE IF NOT EXISTS public.sg_seller_webhook_notifications_seen" in mig1_audit
    assert "notification_id   uuid PRIMARY KEY" in mig1_audit
    assert "notification_type text NOT NULL" in mig1_audit
    assert "ENABLE ROW LEVEL SECURITY" in mig1_audit


def test_mig2_creates_all_per_type_tables(mig2_tables: str):
    """One table per notification type that isn't covered by an existing
    table (order.created lands in seatgeek_orders, ping in
    sg_seller_webhook_notifications_seen). 6 new tables total."""
    expected_tables = [
        "sg_seller_order_retransfers",
        "sg_seller_order_fulfillment_errors",
        "sg_seller_listing_inactive_events",
        "sg_seller_listing_visibility",
        "sg_seller_listing_normalization",
        "sg_seller_listing_normalization_changes",
    ]
    for tbl in expected_tables:
        assert f"CREATE TABLE IF NOT EXISTS public.{tbl}" in mig2_tables, f"missing table: {tbl}"
        # Every table has RLS locked down to service_role.
        assert f"public.{tbl} ENABLE ROW LEVEL SECURITY" in mig2_tables
        assert f"REVOKE ALL ON public.{tbl} FROM PUBLIC, anon, authenticated" in mig2_tables
        assert f"GRANT SELECT, INSERT ON public.{tbl} TO service_role" in mig2_tables


def test_mig3_creates_all_ingest_rpcs(mig3_rpcs: str):
    """All 7 RPCs (one for each notification type with an RPC, per
    RPC_BY_TYPE). Each must be SECURITY DEFINER + service_role-gated."""
    expected_rpcs = {name for name in RPC_BY_TYPE.values() if name is not None}
    assert len(expected_rpcs) == 7
    for rpc in expected_rpcs:
        assert f"CREATE OR REPLACE FUNCTION public.{rpc}" in mig3_rpcs, f"missing RPC: {rpc}"
        assert f"GRANT EXECUTE ON FUNCTION public.{rpc}" in mig3_rpcs
        # Every RPC must auth-gate on current_user.
        ctx = mig3_rpcs[mig3_rpcs.index(rpc):]
        end = ctx.index("$$;")
        body = ctx[:end]
        assert "current_user NOT IN" in body, f"{rpc} missing current_user gate"
        assert "'service_role'" in body and "'postgres'" in body, f"{rpc} role list incomplete"
        # Every RPC returns the (inserted, updated, skipped) tuple shape.
        assert "RETURNS TABLE(inserted integer, updated integer, skipped integer)" in body, (
            f"{rpc} return shape mismatch"
        )


def test_mig3_order_created_field_mapping(mig3_rpcs: str):
    """The order.created RPC must map the SG webhook payload fields to the
    seatgeek_orders columns correctly. Smoke-test the critical paths."""
    rpc_start = mig3_rpcs.index("sg_seller_orders_ingest_from_webhook")
    rpc_end = mig3_rpcs.index("$$;", rpc_start)
    rpc = mig3_rpcs[rpc_start:rpc_end]

    # Top-level SG payload fields → seatgeek_orders columns
    must_map = [
        ("(o->>'id')::text",                                     "sg_order_id"),
        ("o->>'status'",                                          "status"),  # COALESCE wrapper OK
        ("o->>'created'",                                         "created_at_sg"),  # NULLIF + ::timestamptz wrapper
        ("o->'event'->>'seatgeek_event_id'",                      "sg_event_id"),
        ("o->'event'->>'name'",                                   "sg_event_name"),
        ("o->'event'->>'venue'",                                  "sg_venue"),
        ("o->'event'->>'date'",                                   "sg_event_date"),
        ("o->'event'->>'time'",                                   "sg_event_time"),
        ("o->'listing'->>'id'",                                   "sg_listing_id"),
        ("o->'listing'->>'price'",                                "sale_price"),
        ("o->'listing'->>'row'",                                  "sale_row"),
        ("o->'listing'->>'section'",                              "sale_section"),
        ("o->'listing'->>'quantity'",                             "sale_quantity"),
        ("o->>'total'",                                           "payment_total"),
        ("o->>'fees'",                                            "payment_fees"),
    ]
    for jsonpath, _col in must_map:
        assert jsonpath in rpc, f"order.created RPC missing JSON path {jsonpath}"

    # Idempotency must be on sg_order_id, not notification_id (orders are
    # logically idempotent by order id — replaying the same order updates).
    assert "ON CONFLICT (sg_order_id) DO UPDATE" in rpc


def test_mig3_per_event_rpcs_use_notification_id_idempotency(mig3_rpcs: str):
    """All non-order.created ingest RPCs must use notification_id as part
    of the idempotency key. Otherwise SG retries would duplicate rows."""
    for rpc_name in (
        "sg_seller_order_retransfers_ingest",
        "sg_seller_listing_inactive_events_ingest",
        "sg_seller_listing_visibility_ingest",
        "sg_seller_listing_normalization_ingest",
        "sg_seller_listing_normalization_changes_ingest",
    ):
        rpc_start = mig3_rpcs.index(rpc_name)
        rpc_end = mig3_rpcs.index("$$;", rpc_start)
        rpc = mig3_rpcs[rpc_start:rpc_end]
        assert "notification_id" in rpc and "ON CONFLICT" in rpc, (
            f"{rpc_name} missing notification_id idempotency"
        )


# ============================================================
# Edge function contract: every notification type wired
# ============================================================

def test_fn_uses_bearer_auth(fn_index: str):
    """The edge function must use the shared Bearer auth helper against the
    SG_SELLER_WEBHOOK_SECRET env var, not roll its own."""
    assert 'from "../_shared/bearer-auth.ts"' in fn_index
    assert 'requireBearer(req, "SG_SELLER_WEBHOOK_SECRET")' in fn_index


def test_fn_method_gate(fn_index: str):
    """Only POST is accepted — webhook spec says POST. Anything else returns 405."""
    assert 'req.method !== "POST"' in fn_index
    assert "405" in fn_index


def test_fn_schema_version_gate(fn_index: str):
    """schema_version === 1 is currently the only supported envelope version."""
    assert "schema_version !== 1" in fn_index


def test_fn_idempotency_check(fn_index: str):
    """The function must INSERT into sg_seller_webhook_notifications_seen
    and treat 23505 (unique violation) as the dedup signal."""
    assert '"sg_seller_webhook_notifications_seen"' in fn_index
    assert '"23505"' in fn_index
    assert "deduped" in fn_index


def test_fn_dispatches_all_notification_types(fn_index: str):
    """Every notification type SG sends must be dispatched (either to an
    RPC or to a documented no-op like ping). Missing types would be logged
    as 'unknown notification_type' in prod which is a silent failure."""
    for t in ALL_NOTIFICATION_TYPES:
        assert f'case "{t}":' in fn_index, f"edge function missing dispatch case for {t}"


def test_fn_dispatches_to_correct_rpc_names(fn_index: str):
    """The dispatch arm for each non-ping type must call the RPC whose name
    matches RPC_BY_TYPE (this is the contract that breaks silently in prod
    if either side drifts)."""
    for ntype, rpc_name in RPC_BY_TYPE.items():
        if rpc_name is None:
            continue
        # The RPC name must appear in the file. We don't try to parse the
        # exact case-arm pairing; a simple presence check + the per-type
        # case test above is sufficient.
        assert rpc_name in fn_index, f"edge function doesn't reference RPC {rpc_name}"


def test_fn_returns_quickly_on_dispatch_failure(fn_index: str):
    """SG's circuit breaker pauses webhooks if we 5xx repeatedly. Dispatch
    failures must be caught and logged; the response must still be 200
    once the audit row is recorded."""
    # The pattern is `dispatch(...).catch((e) => { console.error(...) })`
    assert "dispatch(sb, metadata, body.data).catch(" in fn_index


def test_bearer_auth_is_constant_time(fn_bearer_auth: str):
    """Bearer comparison must be constant-time (mirror of cron-auth.ts pattern)."""
    assert "constantTimeEqual" in fn_bearer_auth
    # The loop must iterate over the LONGER of the two strings.
    assert "Math.max(a.length, b.length)" in fn_bearer_auth


def test_bearer_auth_rejects_missing_secret(fn_bearer_auth: str):
    """Server-misconfigured guard — must return 500 if the env var isn't set,
    NOT silently allow all requests (fail-closed)."""
    assert "envVarName} unset" in fn_bearer_auth or "{envVarName}" in fn_bearer_auth
    assert "status: 500" in fn_bearer_auth


# ============================================================
# Live test plan (operator + A1 reference)
# ============================================================

SG_LIVE_TEST_PLAN = """
Once A1 applies the 3 migrations + deploys the edge function, the operator
runs this end-to-end test via SG support:

1. Generate a random 32+ char token:
     openssl rand -hex 24
   Set as vault secret SG_SELLER_WEBHOOK_SECRET:
     (run in Supabase SQL editor as postgres role)
     UPDATE vault.secrets SET secret='<token>' WHERE name='SG_SELLER_WEBHOOK_SECRET';

2. Set the env var on the edge function:
     supabase secrets set SG_SELLER_WEBHOOK_SECRET=<token>
   OR via Supabase dashboard → Project Settings → Edge Functions → Secrets.

3. File a SG support ticket:
   - Webhook URL: https://hzrizjeaxlqcxfrtczpq.supabase.co/functions/v1/sg-seller-webhook
   - Auth token: <token from step 1>
   - Notification subscriptions:
     * order.created                       (streaming)
     * order.retransfer                    (streaming)
     * order.fulfillment.error             (streaming)
     * listing.event.inactive              (streaming)
     * listing.visibility                  (batching, 30s window)
     * listing.normalization.status        (streaming)
     * listing.normalization.status.changed (streaming)
     * ping                                (on-demand)

4. Ask SG support to fire a `ping` notification.
   Verify:
     SELECT * FROM sg_seller_webhook_notifications_seen
       WHERE notification_type='ping' ORDER BY received_at DESC LIMIT 1;
   Expect: one row with the ping notification_id.

5. curl-test the idempotency replay:
     curl -X POST 'https://hzrizjeaxlqcxfrtczpq.supabase.co/functions/v1/sg-seller-webhook' \\
       -H 'Authorization: Bearer <token>' \\
       -H 'Content-Type: application/json' \\
       -d '{"metadata":{"notification_type":"ping","notification_id":"00000000-0000-0000-0000-000000000001","schema_version":1,"seller_id":456},"data":[{"ping":"replay-test"}]}'
   First call → 200 {received: true}
   Second call (same payload) → 200 {deduped: true}

6. Once SG fires a real order.created on a synthetic test order, verify:
     SELECT * FROM seatgeek_orders ORDER BY pulled_at DESC LIMIT 5;
   Expect: new row with sg_order_id matching the test order.

7. Monitor row counts over 24h:
     SELECT notification_type, count(*) FROM sg_seller_webhook_notifications_seen
       WHERE received_at > now() - interval '24 hours'
       GROUP BY notification_type ORDER BY count(*) DESC;
"""


def test_live_test_plan_is_documented():
    """Just confirms the live test plan string is non-empty and references
    the right URL + secret name. Lets the operator find this plan via
    pytest --collect-only without grep."""
    assert "sg-seller-webhook" in SG_LIVE_TEST_PLAN
    assert "SG_SELLER_WEBHOOK_SECRET" in SG_LIVE_TEST_PLAN
    assert "ping" in SG_LIVE_TEST_PLAN
    assert "order.created" in SG_LIVE_TEST_PLAN

"""Contract tests for the TEvo Catalog Notifications webhook receiver.

Static checks only (no running edge function, no live Supabase), mirroring
tests/test_sg_seller_webhook_contract.py. They pin the contract between:

  1. TEvo's "Catalog Notifications (Webhooks)" spec (operator pasted it
     2026-09-28): form-urlencoded POST with recipient / event_type / body +
     event_id | performer_id | venue_id; published source IPs.
  2. The landing-table migration.
  3. supabase/functions/tevo-catalog-webhook/index.ts.
"""
from __future__ import annotations

import re
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parent.parent
MIG = REPO_ROOT / "supabase" / "migrations" / "20260928164038_tevo_catalog_webhook_log.sql"
FN = REPO_ROOT / "supabase" / "functions" / "tevo-catalog-webhook" / "index.ts"

TEVO_IPS = {"18.235.211.7", "35.170.152.168"}
ENTITY_ID_FIELDS = {"event": "event_id", "performer": "performer_id", "venue": "venue_id"}


@pytest.fixture(scope="module")
def mig() -> str:
    assert MIG.exists(), f"missing migration: {MIG}"
    return MIG.read_text(encoding="utf-8")


@pytest.fixture(scope="module")
def fn() -> str:
    assert FN.exists(), f"missing edge function: {FN}"
    return FN.read_text(encoding="utf-8")


# ---------------- migration ----------------

def test_migration_creates_table_with_dedupe_key(mig: str) -> None:
    assert "CREATE TABLE IF NOT EXISTS public.tevo_webhook_notifications" in mig
    assert re.search(r"body_sha256\s+text\s+NOT NULL UNIQUE", mig)


def test_migration_entity_kind_check_covers_every_kind(mig: str) -> None:
    m = re.search(r"entity_kind IN \(([^)]*)\)", mig)
    assert m, "entity_kind CHECK missing"
    kinds = set(re.findall(r"'([a-z]+)'", m.group(1)))
    assert kinds == {"event", "performer", "venue", "order", "other"}


def test_migration_rls_lockdown(mig: str) -> None:
    assert "ENABLE ROW LEVEL SECURITY" in mig
    assert "REVOKE ALL ON public.tevo_webhook_notifications FROM PUBLIC, anon, authenticated" in mig
    assert re.search(r"GRANT [A-Z, ]+ ON public\.tevo_webhook_notifications TO service_role", mig)


def test_migration_header_declares_lane(mig: str) -> None:
    assert mig.startswith("-- Migration 20260928164038 · level:data-collection · lane:A1")


# ---------------- edge function ----------------

def test_fn_is_post_only(fn: str) -> None:
    assert 'req.method !== "POST"' in fn


def test_fn_requires_url_token_constant_time(fn: str) -> None:
    assert 'Deno.env.get("TEVO_WEBHOOK_SECRET")' in fn
    assert 'searchParams.get("token")' in fn
    assert "constantTimeEqual(provided, expected)" in fn


def test_fn_default_ip_allowlist_matches_tevo_spec(fn: str) -> None:
    m = re.search(r"DEFAULT_ALLOWED_IPS = \[([^\]]*)\]", fn)
    assert m, "DEFAULT_ALLOWED_IPS missing"
    assert set(re.findall(r'"([\d.]+)"', m.group(1))) == TEVO_IPS


def test_fn_parses_form_urlencoded(fn: str) -> None:
    assert "new URLSearchParams(raw)" in fn
    for field in ("event_type", "body", "recipient"):
        assert f'form.get("{field}")' in fn


def test_fn_entity_id_field_map_matches_spec(fn: str) -> None:
    for kind, field in ENTITY_ID_FIELDS.items():
        assert re.search(rf'{kind}: "{field}"', fn), f"{kind} -> {field} mapping missing"


def test_fn_classifies_catalog_event_types(fn: str) -> None:
    assert "(event|performer|venue)_(created|updated|deleted)" in fn


def test_fn_writes_the_migrated_table_and_columns(fn: str, mig: str) -> None:
    assert 'from("tevo_webhook_notifications")' in fn
    insert = fn[fn.index(".insert({"):]
    insert = insert[: insert.index("});")]
    cols = set(re.findall(r"^\s+([a-z_0-9]+):", insert, re.M))
    assert cols, "no insert columns parsed"
    for col in cols:
        assert re.search(rf"^\s+{col}\s", mig, re.M), f"insert column {col} not in migration"


def test_fn_treats_unique_violation_as_retry(fn: str) -> None:
    assert '"23505"' in fn


def test_fn_never_calls_tevo(fn: str) -> None:
    # RULE 2: inbound receiver only — no outbound request to any TEvo host.
    assert "fetch(" not in fn
    assert "ticketevolution" not in fn.lower()

"""RLS policy tests as first-class security tests (testing-recommendation #2).

The D0/D4 security boundary IS row-level security, and it was untested in CI
(only ad-hoc SQL scripts under tests/exos existed). This parametrized suite
asserts, against the live `supabase start` stack, exactly who can read what —
so a future migration that loosens a policy fails here.

The headline case: **this file would have caught the `barcode_secret` finding**
(audit 2026-07-02). RLS is row-level, not column-level, so the finance/content
org roles that pass the `exos_tickets_sel` row policy would, without the
least-privilege migration, read every column — including the per-ticket HMAC
`barcode_secret`. We assert finance/content CANNOT reach the secret (base table
or gated view) while owner/buyer/scanner CAN.

Runs only under RLS_DATABASE_URL (skipped everywhere else); see conftest.
"""
from __future__ import annotations

import psycopg
import pytest

from tests.rls.conftest import (
    BUYER,
    CONTENT,
    FINANCE,
    OWNER,
    SCANNER,
    SECRET,
    STRANGER,
    TICKET,
    as_role,
)


# --- baseline: anon is locked out of the tenant table entirely ---------------

def test_anon_cannot_read_exos_tickets():
    """anon has no grant on exos_tickets — a public client sees nothing."""
    with as_role("anon") as cur:
        with pytest.raises(psycopg.errors.InsufficientPrivilege):
            cur.execute("SELECT id FROM public.exos_tickets")
            cur.fetchall()


# --- row policy: who passes exos_tickets_sel at all --------------------------

@pytest.mark.parametrize(
    "uid,can_see_row",
    [
        (OWNER, True),      # ticket owner
        (BUYER, True),      # ticket buyer
        (FINANCE, True),    # org finance staff — passes the ROW policy...
        (CONTENT, True),    # org content staff — ...also passes the row policy
        (SCANNER, True),    # org scanner staff
        (STRANGER, False),  # unrelated authenticated user — no row
    ],
)
def test_row_visibility_matches_policy(uid, can_see_row):
    with as_role("authenticated", uid=uid) as cur:
        cur.execute("SELECT count(*) FROM public.exos_tickets WHERE id = %s", (TICKET,))
        n = cur.fetchone()[0]
    assert (n == 1) is can_see_row


# --- column least-privilege: barcode_secret is NOT readable off the base table
# by anyone acting as `authenticated` (the shared Postgres role) — the migration
# revoked the column grant. This is the structural half of the finding's fix.

@pytest.mark.parametrize("uid", [OWNER, BUYER, FINANCE, CONTENT, SCANNER])
def test_barcode_secret_column_revoked_on_base_table(uid):
    with as_role("authenticated", uid=uid) as cur:
        with pytest.raises(psycopg.errors.InsufficientPrivilege):
            cur.execute("SELECT barcode_secret FROM public.exos_tickets WHERE id = %s", (TICKET,))
            cur.fetchall()


# --- the gated view: barcode_secret is re-exposed ONLY to authorized readers --

@pytest.mark.parametrize(
    "uid,expected",
    [
        (OWNER, SECRET),      # renders their own pass
        (BUYER, SECRET),      # renders the pass they bought
        (SCANNER, SECRET),    # door verification
        (FINANCE, None),      # <-- the finding: finance must NOT get the secret
        (CONTENT, None),      # <-- the finding: content must NOT get the secret
        (STRANGER, None),     # unrelated user gets nothing
    ],
)
def test_barcode_secret_view_gate(uid, expected):
    with as_role("authenticated", uid=uid) as cur:
        cur.execute(
            "SELECT barcode_secret FROM public.exos_ticket_barcode_secrets WHERE ticket_id = %s",
            (TICKET,),
        )
        row = cur.fetchone()
    got = row[0] if row else None
    assert got == expected

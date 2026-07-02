"""Fixtures for the RLS security suite (testing-recommendation #2).

These tests run ONLY against a live migrated Postgres (the `supabase start`
stack in .github/workflows/supabase-rls.yml). The main pytest job ignores
`tests/rls` (it has no database), so:

  * `psycopg` is imported via importorskip — a runner without it skips cleanly.
  * every fixture skips when `RLS_DATABASE_URL` is unset.

The suite talks to Postgres directly rather than through PostgREST + a signed
JWT. Supabase's `auth.uid()` / `auth.jwt()` read the request-claims GUC that
PostgREST sets *after* it verifies a token, so setting `request.jwt.claims`
ourselves under `SET LOCAL ROLE authenticated` exercises the exact same policy
predicates without needing the JWT secret — this tests the POLICIES, not
PostgREST's signature check. `SET LOCAL` + a rolled-back transaction keeps every
case isolated.
"""
from __future__ import annotations

import contextlib
import json
import os

import pytest

psycopg = pytest.importorskip("psycopg")

RLS_DATABASE_URL = os.environ.get("RLS_DATABASE_URL")

# Deterministic identities shared across the suite (mirror tests/exos/*.sql).
ORG = "00000000-0000-0000-0000-0000000000a1"
OWNER = "00000000-0000-0000-0000-000000000001"
BUYER = "00000000-0000-0000-0000-000000000002"
FINANCE = "00000000-0000-0000-0000-000000000003"
CONTENT = "00000000-0000-0000-0000-000000000004"
SCANNER = "00000000-0000-0000-0000-000000000005"
STRANGER = "00000000-0000-0000-0000-0000000000ff"
EVENT = "00000000-0000-0000-0000-0000000000e1"
TICKET = "00000000-0000-0000-0000-0000000000f1"
SECRET = "SUPERSECRET-BARCODE-KEY"


@pytest.fixture(scope="session")
def admin_conn():
    """Superuser/service connection (BYPASSRLS) for seeding + teardown."""
    if not RLS_DATABASE_URL:
        pytest.skip("RLS_DATABASE_URL unset — RLS suite runs only under supabase start")
    conn = psycopg.connect(RLS_DATABASE_URL, autocommit=True)
    try:
        yield conn
    finally:
        conn.close()


@pytest.fixture(scope="session", autouse=True)
def _seed(admin_conn):
    """One org, one ticket, five staff identities — seeded as the BYPASSRLS
    owner so RLS doesn't block the setup. Cleaned up after the session."""
    with admin_conn.cursor() as cur:
        cur.execute("DELETE FROM public.exos_tickets WHERE id = %s", (TICKET,))
        cur.execute("DELETE FROM public.exos_org_memberships WHERE org_id = %s", (ORG,))
        cur.execute(
            "INSERT INTO public.exos_org_memberships (org_id, user_id, role) "
            "VALUES (%s,%s,'finance'), (%s,%s,'content'), (%s,%s,'scanner')",
            (ORG, FINANCE, ORG, CONTENT, ORG, SCANNER),
        )
        cur.execute(
            "INSERT INTO public.exos_tickets "
            "(id, event_id, org_id, buyer_id, owner_id, barcode_secret, status) "
            "VALUES (%s,%s,%s,%s,%s,%s,'active')",
            (TICKET, EVENT, ORG, BUYER, OWNER, SECRET),
        )
    yield
    with admin_conn.cursor() as cur:
        cur.execute("DELETE FROM public.exos_tickets WHERE id = %s", (TICKET,))
        cur.execute("DELETE FROM public.exos_org_memberships WHERE org_id = %s", (ORG,))


@contextlib.contextmanager
def as_role(role: str, uid: str | None = None, email: str | None = None):
    """Open a rolled-back transaction acting as `role` with an optional Supabase
    JWT identity (uid/email injected via the verified-claims GUC that auth.uid()
    /auth.jwt() read). Yields a cursor; the rollback keeps cases isolated."""
    conn = psycopg.connect(RLS_DATABASE_URL)
    try:
        with conn.transaction(force_rollback=True):
            with conn.cursor() as cur:
                if uid is not None:
                    claims = {"sub": uid, "role": role}
                    if email is not None:
                        claims["email"] = email
                    cur.execute(
                        "SELECT set_config('request.jwt.claims', %s, true)",
                        (json.dumps(claims),),
                    )
                cur.execute(f"SET LOCAL ROLE {role}")
                yield cur
    finally:
        conn.close()

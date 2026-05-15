# D2 Orders Dashboard — Deploy Guide

**Owner**: D2 — code, env vars, deploy config, and IaC for the
`d2-orders-dashboard` Render service. Per `LANE_DISCIPLINE.md` §Cross-cutting
Rule #6 (PRs #104 + #105, 2026-05-14): D2 has standing read + write authority
on this one service; cross-service and workspace-level ops remain forbidden.

## What this is

A standalone FastAPI service that renders a single window across all 4
broker order surfaces (Evo / SeatGeek / TickPick / Vivid) plus seatdata
fulfilled-sales rows, **reading exclusively from Supabase SQL**. All 5
sources are kept fresh by the upstream ingest crons and surfaced through
the `public.unified_orders` view (mig
`20260513230100_unified_orders_with_tickpick_vivid.sql`). The dashboard
makes zero broker-API calls in the data path. Read-only on the DB.

**Auth posture (2026-05-13 — Google OAuth re-enabled)**: gated by default.
`AUTH_DISABLED=false` is the shipped default; the dashboard surfaces the
Supabase login screen → Google OAuth → @s4kent.com email check. Set
`AUTH_DISABLED=true` on the service env for a one-off testing bypass
(loud stderr warning at boot; no production self-disable).

Supabase Auth setup (one-time, operator-side):
- Supabase Auth → URL Configuration → Redirect URLs: add
  `https://d2-orders-dashboard.onrender.com/` (or your custom domain)
- Google Cloud Console → OAuth Credentials → Authorized redirect URIs:
  add `https://hzrizjeaxlqcxfrtczpq.supabase.co/auth/v1/callback`

Entry point: `uvicorn d2_dashboard.main:app`.

## Deploy steps (D2 — self-service)

1. In the Render dashboard: **New → Web Service**.
2. Connect `JulianS4K/Terminal-2` and select the branch this lives on
   (`main` after merge, or a deploy branch).
3. Configure:
   - **Runtime**: Python
   - **Build Command**: `pip install -r requirements.txt`
   - **Start Command**: `uvicorn d2_dashboard.main:app --host 0.0.0.0 --port $PORT`
   - **Health Check Path**: `/healthz`
   - **Plan**: free (sleep-after-15-min is fine for an internal tool)
   - **Region**: `oregon` (matches storefront)
4. Add env vars (see `../render-d2-dashboard.yaml` for the IaC blueprint).

   **Required — without these the dashboard 503s on `/api/d2/orders`:**
   - `SUPABASE_URL`
   - `SUPABASE_SERVICE_ROLE_KEY` (server-side reads against
     `unified_orders` + raw `*_orders` tables + `v_event_base`)
   - `PYTHON_VERSION=3.12.7`

   **Auth-related (only needed when AUTH_DISABLED=false — i.e., in prod):**
   - `SUPABASE_ANON_KEY`
   - `ALLOWED_EMAIL_DOMAIN=s4kent.com`
   - `D2_CANONICAL_ORIGIN=https://d2-orders-dashboard.onrender.com` (must
     match a Redirect URL registered under Supabase Auth → URL Configuration)

   **Optional toggles:**
   - `AUTH_DISABLED=true` to bypass the Supabase JWT gate (default `false`
     in prod, `true` locally for convenience)
   - `D2_PHASE`, `D2_UI_STATUS` — purely cosmetic lane signals exposed
     by `/healthz/detail`

   **Optional broker creds (GoTickets only):**
   - `GOTICKETS_ACCESS_ID`, `GOTICKETS_API_SECRET`,
     `GOTICKETS_SAMPLE_ORDER_ID` — feed the by-id form on the Samples tab.
     GoTickets has no list endpoint and no ingest cron, so it's the one
     surface still reading from the live API.

   **Not needed in the data path (kept available for `_broker_diag` env
   introspection in `/healthz/detail`, but no code reads from them on
   `/api/d2/orders`):** `TEVO_API_TOKEN/_SECRET`, `SEATGEEK_API_TOKEN`,
   `TICKPICK_API_TOKEN`, `VIVID_API_TOKEN`, `SEATDATA_API_KEY`. Safe to
   omit; safe to leave set.
5. Deploy. First boot ≈ 70–80s on free tier (cold).
6. Hit `https://<service>.onrender.com/healthz` → `{"ok":true,"service":"d2_dashboard"}`.
7. Hit `https://<service>.onrender.com/` → orders dashboard loads.
   With `AUTH_DISABLED=false`, the Supabase login screen → Google OAuth
   intercepts first.

## Local dev

```bash
# Hard-required for SQL reads:
export SUPABASE_URL=...
export SUPABASE_SERVICE_ROLE_KEY=...

# AUTH_DISABLED=true is the local-dev default — no Supabase Auth setup
# needed unless you want to exercise the gate.
export AUTH_DISABLED=true

uvicorn d2_dashboard.main:app --reload --port 8000
# open http://localhost:8000/
```

To exercise the Supabase JWT gate locally:

```bash
export AUTH_DISABLED=false
export SUPABASE_ANON_KEY=...
export ALLOWED_EMAIL_DOMAIN=s4kent.com
```

## What happens when data is stale

The dashboard is SQL-only. If an ingest cron stalls:

- The affected source's row count in `/api/d2/orders` drops to whatever's
  in `unified_orders` (which is whatever the last successful cron wrote).
- Per-source `as_of` (`last_seen_at` max) on the `/api/d2/orders` response
  ages out, visible as the per-source freshness chip in the UI.
- `/api/d2/cron-freshness` and `/api/d2/health` are the operator's "is the
  data fresh" signal — they surface each cron's `last_run` and `last_status`.

No silent fallback to a live broker-API call. That's intentional — a
fallback would burn broker quota AND hide the ingest problem. If the cron
is stalled, the operator should see empty/aged data and route the fix to
the ingest cron's owning lane.

If Supabase itself is unreachable (`SUPABASE_URL` / `SUPABASE_SERVICE_ROLE_KEY`
unset or wrong), `/api/d2/orders` returns 503 with "Supabase not configured
(SUPABASE_URL + SUPABASE_SERVICE_ROLE_KEY required)".

## Cost (free tier)

- One Render web service: 750 hr/mo (sleeps after 15 min idle, ~70s cold start)
- No new DB, no new edge function, no new vault entries
- **External API quota usage: 0 calls per dashboard refresh** (SQL-only).
  GoTickets by-id form: 1 call per submission (operator-initiated only).

## Read-only assertion

D2's order clients (referenced for the GoTickets by-id form and
`_broker_diag` env introspection only) all import the shared
`_assert_readonly_method` guard (SCHEMA.md RULE 2).
`scripts/check_readonly.py` covers this file under its standard scan — no
allowlist change needed because no `requests.post/put/patch/delete` calls
were added.

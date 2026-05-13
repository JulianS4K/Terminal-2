# D2 Orders Dashboard — Deploy Guide

**Owner**: D2 ships the code. D1 owns the Render workspace and provisions the
service (`bot_chat` row 57 — INFRA OWNERSHIP RULE).

## What this is

A standalone FastAPI service that renders a single window across all 4
broker order surfaces (Evo / SeatGeek / TickPick / Vivid) plus a SeatData
analytics tab. Read-only — no writes to any external API.

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

## Deploy steps (D1 / operator action)

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
4. Add env vars (see `render.yaml.example` for the full list). Names below
   match the Supabase Vault canonical keys (uppercase with `_API_`). Legacy
   storefront names (`TEVO_TOKEN`, `TEVO_SECRET`, `TICKPICK_TOKEN`) are also
   accepted by the loader — pick whichever you already have populated.

   **Required (SQL reads for cron-backed sources):**
   - `SUPABASE_URL`
   - `SUPABASE_SERVICE_ROLE_KEY` (server-side reads against
     `unified_orders` + `v_event_base`. Independent of the Supabase JWT
     auth gate. Without these, the dashboard falls back to direct upstream
     API calls for every refresh, burning broker-API quota.)

   **Required (broker creds for sources NOT in unified_orders, i.e. tickpick
   + vivid + gotickets, and as a fallback when SQL is empty):**
   - `TEVO_API_TOKEN`, `TEVO_API_SECRET`
   - `SEATGEEK_API_TOKEN`
   - `TICKPICK_API_TOKEN`
   - `VIVID_API_TOKEN`
   - `SEATDATA_API_KEY` (optional — only the SeatData tab needs it)
   - `GOTICKETS_ACCESS_ID` + `GOTICKETS_API_SECRET` (GoTickets has no list
     endpoint — by-id lookup only via the Samples tab's GoTickets form)
   - `GOTICKETS_SAMPLE_ORDER_ID` (optional — a known-good GoTickets order
     ID. When set, the Samples tab's gotickets chip exercises `get_sale()`
     against it on each refresh)
   - `PYTHON_VERSION=3.12.7`

   **Auth-related (only needed when AUTH_DISABLED=false):**
   - `SUPABASE_URL`, `SUPABASE_ANON_KEY`, `ALLOWED_EMAIL_DOMAIN`
   - `D2_CANONICAL_ORIGIN=https://d2-orders-dashboard.onrender.com` (must
     match a Redirect URL registered under Supabase Auth → URL Configuration)

   **Optional toggles:**
   - `AUTH_DISABLED=false` to enable the Supabase JWT gate (default `true`)
   - `D2_UI_STATUS=rebuilt` to flip the `/healthz/detail` lane signal

   **Not wired yet** (Vault has values, no client module exists in D2):
   `GOTICKETS_ACCESS_ID/GOTICKETS_API_SECRET`, `STUBHUB_API_TOKEN`,
   `VIAGOGO_API_TOKEN`, `VIVID_AUTOMATOR_TOKEN`. Setting these on the
   service is harmless — they just won't appear in the merged orders
   table until D2 ships clients for them.
5. Deploy. First boot ≈ 70–80s on free tier (cold).
6. Hit `https://<service>.onrender.com/healthz` → `{"ok":true,"service":"d2_dashboard"}`.
7. Hit `https://<service>.onrender.com/` → orders dashboard loads directly
   (anonymous-by-default). With `AUTH_DISABLED=false` set, you'll hit the
   Supabase login screen → Google OAuth instead.

Alternative: merge the `services:` block from `render.yaml.example` into the
root `./render.yaml` (D1 lane — D2 cannot touch that file). On next push to
the configured branch, Render will provision the second service automatically.

## Local dev

```bash
# AUTH_DISABLED=true is now the shipped default — no Supabase / OAuth setup
# needed for local dev unless you want to test the gate.
export TEVO_API_TOKEN=... TEVO_API_SECRET=...
# (optional creds for the other 3 sources)

uvicorn d2_dashboard.main:app --reload --port 8000
# open http://localhost:8000/
```

To exercise the Supabase JWT gate locally:

```bash
export AUTH_DISABLED=false
export SUPABASE_URL=...
export SUPABASE_ANON_KEY=...
export ALLOWED_EMAIL_DOMAIN=s4kent.com
```

## What happens if a credential is missing

The `/api/d2/orders` endpoint fans out to all 4 sources in parallel. Each
source reports its own ok/error. A missing credential or a dead upstream
shows as an `error` chip in the page header and an empty rows list — the
other three sources render normally. No single failure blanks the page.

## Cost (free tier)

- One Render web service: 750 hr/mo (sleeps after 15 min idle, ~70s cold start)
- No new DB, no new edge function, no new vault entries
- External API quota usage: 4 GET calls per dashboard refresh (one per source).
  SeatData tab adds 2 more (`account` + `usage`) only when that tab is opened.

## Read-only assertion

All four order clients import the existing `_assert_readonly_method` guard
(SCHEMA.md RULE 2). `scripts/check_readonly.py` already covers this file
under its standard scan — no allowlist change needed because no
`requests.post/put/patch/delete` calls were added.

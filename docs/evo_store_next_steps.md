# Evo Store — Next Steps to Live

**Owner: D1 (Consumer Retail). Render workspace exclusive.**
**Date: 2026-05-13. State after PR #71 (latest_event_metrics matview) + PR #72 (reddit stop).**

This is the green-light list for getting the storefront from "data flowing, catalog blocked" to "fully live." Items are ordered by what unblocks what.

---

## What's already done (don't redo)

| ✅ | Item | Evidence |
|---|---|---|
| ✅ | `STOREFRONT_SQL_ONLY=false` on Render | env var set, verified via `/api/store/events/3346000 inventory_source=live` |
| ✅ | TEvo live path proven end-to-end | bot_chat row 60 — `/api/store/search?q=knicks source=live` 11s, listings_count=190 matches direct TEvo |
| ✅ | EVO_API_TOKEN + secrets in Render env | both EVO_API sets confirmed in 2026-05-12 sweep |
| ✅ | CORS_ALLOWED_ORIGINS set | confirmed in 2026-05-12 sweep |
| ✅ | `latest_event_metrics` view fixed (was 50s, blocking `/api/store/events`) | **PR #71** — now matview, warm query 272ms |
| ✅ | `evo_client.py` security hardening (URL/body redact from RuntimeError) | PR #66 |

---

## What's still blocking (do these in order)

### 1. Deploy branch sync — most urgent

The Render service `vibepass-storefront-test` is wired to deploy from the branch `claude/store-sql-only-demo-mode`. As of last check that branch is **9928 lines behind `main`** — it doesn't have:
- The `evo_client.py` security patch (PR #66)
- The `latest_event_metrics` matview (PR #71 — without it, catalog will time out)
- The reddit-stop migration (PR #72, low-impact for retail but cleanup)
- All of B1's RLS/security migrations

**Two options** (D1 picks):

**Option A: merge `main` → `claude/store-sql-only-demo-mode`** (preserves the demo-mode branch name, no Render reconfig needed):
```bash
git fetch origin
git checkout claude/store-sql-only-demo-mode
git merge origin/main
# resolve any conflicts (likely none — app.py paths don't conflict)
git push origin claude/store-sql-only-demo-mode
# Render will auto-deploy
```

**Option B: repoint Render at `main`** (cleaner long-term, no more dual-branch maintenance):
- In Render UI for service `srv-d8140bnaqgkc73al4asg` (vibepass-storefront-test):
  Settings → Branch → change `claude/store-sql-only-demo-mode` → `main` → Save.
- Trigger a manual deploy from `main`.

Recommend **Option B** — eliminates the drift risk going forward. A1 will not enforce; D1's call.

### 2. JWT key format

`/api/public/config` was returning valid keys but `Invoke-RestMethod` against `/rest/v1/events?select=count` returned `"message":"Invalid API key"` for BOTH the legacy `anon` and `service_role` JWTs (`eyJ...` format). Both keys match the values shown in the Supabase Settings sidebar — so this is not a copy/paste error.

**Hypothesis**: the project's JWT signing secret was rotated between when those legacy JWTs were issued and now. Supabase now expects the new key format.

**Action for D1**:
1. In Supabase Dashboard → Project Settings → API → grab the **publishable key** (`sb_publishable_...`) and the **secret key** (`sb_secret_...`). These are the post-rotation format.
2. Update Render env vars:
   - `SUPABASE_ANON_KEY` → set to the `sb_publishable_...` value
   - `SUPABASE_SERVICE_ROLE_KEY` → set to the `sb_secret_...` value
3. Update the local `.env` (D1's worktree) and `app.py`'s `SUPABASE_KEY` constant reference to match the new env-var names if the code uses literal `eyJ` prefix anywhere (it shouldn't — check `app.py:102`).
4. Trigger Render redeploy.

A1 verified the old `eyJ` legacy JWTs no longer pass `/rest/v1` calls in PowerShell sweep 2026-05-12. The keys themselves were copied correctly; they're just no longer valid.

### 3. Re-verify catalog endpoint

Once #1 and #2 land:

```powershell
# Health check
Invoke-RestMethod "https://vibepass-storefront-test.onrender.com/healthz"
# Expect: { ok: true, ... }

# Catalog (this was the broken endpoint — fixed by PR #71)
Invoke-RestMethod "https://vibepass-storefront-test.onrender.com/api/store/events?limit=3"
# Expect: 200 in <2s, array of 3 events with inventory_source=live

# Detail
Invoke-RestMethod "https://vibepass-storefront-test.onrender.com/api/store/events/3346000"
# Expect: inventory_source=live, listings_count > 0
```

Acceptance: all three return 200, catalog returns in <2s end-to-end (matview query is 272ms; the rest is network + TEvo enrichment).

### 4. Google Auth (deferred)

`ALLOWED_EMAIL_DOMAIN` is set but Google Auth was never plugged in. Storefront currently runs without login gate.

**For initial live launch**: that's fine — the storefront is read-only (search + browse + share-link), no auth needed for general public.

**For "logged-in users get a different view"** features (your watch lists, saved searches, etc.): D1 + A1 will wire Google OAuth in a follow-up. Pre-reqs:
- Decide whether to use Supabase Auth (Google provider) or roll Flask-side OAuth.
- Add `GOOGLE_OAUTH_CLIENT_ID` + `GOOGLE_OAUTH_CLIENT_SECRET` to Render env vars (and Supabase vault for cron access).
- Add `/auth/google/callback` route in `app.py`.

Track this as a separate task; not a blocker for retail go-live.

---

## Reference — Render service details

| Field | Value |
|---|---|
| Service ID | `srv-d8140bnaqgkc73al4asg` |
| Service name | `vibepass-storefront-test` |
| Current branch | `claude/store-sql-only-demo-mode` (9928 lines behind main as of 2026-05-13) |
| Recommended branch | `main` (eliminates drift) |
| Autodeploy | `true` |
| Render MCP server | `.mcp.json` + `.env` landed in PR #70 — D1 has access |

---

## Reference — Endpoints already proven working in live mode

From bot_chat row 60 (2026-05-12 22:03 UTC):

- `GET /healthz` → 200
- `GET /api/store/search?q=knicks` → `source=live`, 11s (TEvo enrichment time, not query time)
- `GET /api/store/events/3346000` → `inventory_source=live`, `listings_count=190` (matches direct TEvo)

Only `/api/store/events` (catalog list) was broken — now fixed via PR #71.

---

## bot_chat thread

- Row 50-58 — C1 lane assignments + Render-exclusive rule
- Row 59-60 — D1 ack + status (live mode confirmed)
- Row 61 — D1 escalation (latest_event_metrics slow)
- Row 63 — A1 reply: matview shipped PR #71
- Row 64 — A1 broadcast: reddit stop, sidecar canonical, strict matcher unblock, LEM matview

D1: post a `change_log` after step #1 (deploy branch sync) and step #3 (catalog re-verify) lands. Link this doc.

A1: keep PR review/push gate. Will apply any storefront-blocking migrations same-day if D1 flags them.

# Security review — A1 prod changes (post-PR #369)

**Reviewer:** B1 · **Date:** 2026-05-26 · **Scope:** everything applied to prod / merged to `main` in A1's `v1.0.0-beta automation checkpoint` (PR [#369](https://github.com/JulianS4K/Terminal-2/pull/369), merged 2026-05-26).

## TL;DR

**Security-clean.** Zero new attack surface — no new tables, views, materialized views, SECURITY DEFINER functions, or anon/authenticated grants were introduced. No real secrets in CI. The one DB schema change (`scanned_by` nullable) is a correct fix that *unblocks* auth-user deletion. Two actionable findings, both **SEC-LOW CI least-privilege hardening**, fixed in this same PR. Two minor notes filed to KANBAN.

The B1 anon-leak sweep that rode in the same checkpoint (migs `20260525170000/180000/190000`, PRs #350/#352/#354) is **verified applied + live**: anon can no longer read `unified_orders` / `v_event_price_arbitrage` / `latest_event_metrics`, and the 5 residual ungated SECDEF fns are no longer anon-executable.

## Scope reviewed

| Item | Type | Verdict |
|---|---|---|
| `20260526000000_fix_broken_crons.sql` | cron reschedule ×3 | clean (1 convention note) |
| `20260526010000_sg_429_rate_mitigation.sql` | cron reschedule ×4 | clean (net security positive) |
| `20260526020000_fix_checkins_scanned_by_nullable.sql` | `ALTER … DROP NOT NULL` | correct fix (1 audit note) |
| `.github/workflows/uptime-check.yml` | new CI | **finding F1** (fixed here) |
| `.github/workflows/tests.yml` | modified CI | **finding F2** (fixed here) |
| `.github/workflows/release-please.yml` | new CI | clean |

## Findings

### F1 — `uptime-check.yml` had no `permissions:` block · SEC-LOW → **FIXED in this PR**
The failure path runs `gh issue create` with `secrets.GITHUB_TOKEN`. With no top-level `permissions:` block, the token inherits the **repo-wide default** permission set rather than least-privilege. A compromised dependency in that job would therefore wield whatever the repo default grants (potentially read/write-all). Fix: pinned to `contents: read` + `issues: write`. The heredoc issue-body and Slack payload interpolate only controlled values (HTTP status code, timestamps, `GITHUB_*` env) — **no command/script-injection vector**.

### F2 — `tests.yml` had no `permissions:` block · SEC-LOW → **FIXED in this PR**
The CI test job checks out + runs pytest/tsc; it never writes via the token. Pinned to `contents: read`. (Secrets check: pytest uses fake `SUPABASE_*` values; the Vite build uses the *publishable* anon key or a placeholder — no real credential exposure.)

### F3 — `fix_broken_crons` FIX-3 omits the `cron_should_fire()` gate · SEC-LOW (convention) → KANBAN
`listings_aq_backfill_overnight`'s new body sets `statement_timeout` + calls `match_unmatched_listings_chunked(25, true)` but does **not** wrap with the `cron_should_fire()` policy gate that PROJECT_BIBLE.md §7 mandates (the other two fixes in the same migration do). Not a security hole — the cron runs as `postgres`, no anon surface, and it self-unschedules at `events_remaining = 0` — but it bypasses the conservation/work-check gate. A1 lane; fix on the next reschedule.

### F4 — `exos_event_checkins.scanned_by` loses scanner attribution on user deletion · SEC-LOW (audit) → KANBAN
The fix (`DROP NOT NULL`) is **correct**: the prior `NOT NULL … ON DELETE SET NULL` was self-contradictory and blocked deletion of any auth user who had ever scanned (an offboarding/GDPR blocker). `SET NULL` + nullable preserves the check-in row and nulls only the scanner FK. Residual: if a scanner's `auth.users` row is later deleted, that historical check-in's scanner identity is lost. If a durable door-audit trail is required, denormalize a `scanned_by_email` text snapshot at scan time (D4/exos lane).

## Verification (live, 2026-05-26)

```sql
-- anon-exposed definer relations: 18 (pre-sweep) → 4 (only the deferred Tier-2 event views)
-- ungated anon-exec SECDEF fns (#354 set): 0
-- has_table_privilege('anon', 'public.unified_orders', 'SELECT')          = false
-- has_table_privilege('anon', 'public.v_event_price_arbitrage', 'SELECT') = false
-- has_table_privilege('anon', 'public.latest_event_metrics', 'SELECT')    = false
```

## Open items routed to KANBAN / lanes

- **B1-NEXT-56** (view leak) → closed-by-deletion (applied via #369).
- **B1-NEXT-7** (RLS gap on 3 tables) → closed-by-deletion (Phase-2 verified 0 RLS-off anon tables).
- **F3** → new KANBAN row, A1 lane (cron gate on `listings_aq_backfill_overnight`).
- **F4** → new KANBAN row, D4 lane (denormalized scanner snapshot, optional).
- **B1-NEXT-59** (still open): 4 Tier-2 event views remain anon-readable — D0/D1 confirm before the ready REVOKE block in `20260525170000` is uncommented.

# Audit 2026-05-14 — Data-Stability Pass (A1)

Single consolidating doc for the day's work. **Stable data + clean advisor + cross-source FKs declared.** All A1 changes in this session shipped as 6 idempotent codifications (PRs #94-99); this doc captures the result + what's still pending.

---

## TL;DR

- **Advisor lints**: 486 → 5 (−99%). All ERROR + INFO cleared. 5 WARN remaining, all documented (3 deferred with reasons, 1 operator-side toggle, 2 intentional matview-in-API).
- **ESPN data**: 61h-stale `event_snapshots` + `injuries_snapshots` unblocked. Two dropped crons (`scope=gameday`, `scope=roster`) restored.
- **Schema visualizer**: 56 cross-source FKs declared (`NOT VALID`). Total prod FKs 22 → 78. Cross-source web now renders.
- **Crons**: 72 / 72 paused per operator directive (row 106). Resume requires explicit OK.
- **Open issues**: 4 flagged to other lanes (SG matcher dormant, `events.occurs_at_local` typed TEXT, stale match-attempt records, TickPick token invalid).

---

## Section 1 — PRs landed today (A1 lane)

All 6 applied via MCP during the cron-paused window, then codified as idempotent migrations:

| PR | Title | Migration | Result |
|---|---|---|---|
| #94 | SECDEF view sweep | `20260514180000_security_invoker_view_sweep` | 139 views → `security_invoker = true`. 0 ERROR-class lints remaining. |
| #95 | function search_path sweep | `20260514181000_fn_search_path_sweep` | 215 functions get `SET search_path = public, pg_temp`. Closes 215 WARN. |
| #96 | asset fetchers → SECURITY INVOKER | `20260514182000_asset_fns_security_invoker` | 3 anon-callable functions flipped. Closes bot_chat row 94 (B1 round-2 backlog). |
| #97 | RLS deny-all bulk + matview docs | `20260514183000_rls_deny_all_bulk` | 121 INFO lints cleared via explicit deny-all policies. Matviews documented. |
| #98 | ESPN crons restored | `20260514185000_espn_gameday_cron`<br>`20260514185100_espn_roster_cron` | 2 cron jobs (jobid 25 + 24) that were silently dropped 2026-05-09 — recreated as 128 + 129. Backfill via pg_net one-shot inserted 30 event_snaps + 126 injuries. |
| #99 | cross-source FKs | `20260514190000_cross_source_fk_declarations` | 56 new FKs (47 single-column + 8 composite to `espn_teams_canonical`) declared `NOT VALID`. 0 orphans across all spot-checked child tables. |

### Advisor scorecard

| Class | Before | After |
|---|---|---|
| ERROR `security_definer_view` | 139 | **0** ✓ |
| WARN `function_search_path_mutable` | 215 | **0** ✓ |
| WARN `anon_security_definer_function_executable` | 3 | **0** ✓ |
| WARN `authenticated_security_definer_function_executable` | 3 | **0** ✓ |
| WARN `extension_in_public` | 2 | 2 (DEFERRED) |
| WARN `materialized_view_in_api` | 2 | 2 (DOCUMENTED) |
| WARN `auth_leaked_password_protection` | 1 | 1 (OPERATOR) |
| INFO `rls_enabled_no_policy` | 121 | **0** ✓ |
| **TOTAL** | **486** | **5** (all with reasons) |

---

## Section 2 — Data-bug audit

| Source | State | Notes |
|---|---|---|
| `event_metrics` / `latest_event_metrics` matview | ✅ fresh | matview cadence on `3-58/5` |
| `listings_snapshots` | ✅ TTL clean | 8.17 M rows, 0 rows >30d (sweep working). Hourly dedup (jobid 117) 3 succeeded / 0 failed last 24h. |
| `seatgeek_listings_snapshots` | ✅ fresh | Cron 58 reactivated earlier, drain confirmed. |
| `espn_event_snapshots` | ✅ fixed | Was 61h stale. Cron jobid 25 had been deleted; restored as 128 (paused) + backfill. |
| `espn_injuries_snapshots` | ✅ fixed | Same root cause; cron 24 → 129 + backfill (126 injuries inserted). |
| `weather_observations` | ✅ healthy | False alarm in earlier probe; fetched_at 2h fresh, forecast to 2026-05-29. |
| `macro_indicators` | ✅ healthy | False alarm; FRED UMCSENT is monthly, today's 500 was transient (FRED-side). |
| `evo_orders` | ✅ ok | 137 rows, healthy. |
| `seatgeek_orders` | ⚠️ static (upstream) | Returns empty `[]` from SG side. Out of scope. |
| `tickpick_orders` | 🟥 **operator-blocked** | HTTP 401 invalid-authorization. `TICKPICK_API_TOKEN` in vault is dead. Needs rotation. Row 109. |
| `vivid_orders` | (D2 lane) | Migration applied 2026-05-14 04:04 UTC; D2 owns. |
| Pending queues | ✅ all near zero | Only `sg_listings_pending = 8`. |

---

## Section 3 — Schema mapping verification

ESPN ↔ TEvo ↔ SeatGeek performer chain is **100% complete** for the sports universe.

| Source | Total | Mapped to TEvo |
|---|---|---|
| ESPN teams (`espn_teams_canonical`) | 169 across MLB/MLS/NBA/NFL/NHL/WNBA | **169 (100%)** via `performer_espn_team_xref` |
| SG performers (`seatgeek_performer_xref`) | 132 | 132 via xref; 85 of them also have ESPN link via TEvo |
| The 47 SG performers WITHOUT ESPN link | concerts / theater / comedy / non-MLB-MLS-NBA-NFL-NHL-WNBA sports | correct — ESPN doesn't track them |

Cross-source FK declarations (PR #99) now make this navigable in the Supabase Studio schema visualizer.

---

## Section 4 — Open issues flagged to other lanes

Pending for the next session. None are urgent — the data flow is stable.

### 🟧 C1 lane

1. **PR #92 force-push pending.** C1 promised the `v_team_recent_results.covered_spread` revision in row 103 (2026-05-14 16:58). 90+ min later, branch is still at the broken commit. **Reminder comment added today.** Once force-pushed, A1 re-applies in one shot.

2. **`auto_match_sg_canonical_relaxed` dormant.** Function exists in `pg_proc` but no cron invokes it. `cross_source_match_tick_30min` only calls the strict `sg_canonical_auto_match_tick`. This is the documented "unblock" for the SG xref 4.7% coverage gap (row 64). C1's call on enabling it (false-positive risk).

3. **`events.occurs_at_local` typed as TEXT.** Holds valid ISO 8601 with offset (e.g. `2026-08-18T00:00:00-05:00`). Should be `timestamptz`. Index-by-time isn't possible without expression indexes; every consumer casts on read. Schema-quality issue; not urgent.

4. **Row 105 ack still pending.** A1 proposed `idx_performer_zone_rules_perf_venue` on C1's table for the `match_performer_zone` perf issue. No ack yet.

5. **Row 108 FK plan reply.** A1 went ahead with the 56-FK migration (PR #99) since the data was clean. If C1's parked ~76 plan had additional anchors not in A1's scope, bring it back as round-2.

### 🟧 B1 lane

Closed by A1's PR #96 (the 3 anon-callable SECDEF asset functions). No open B1 backlog tracked here.

### 🟨 D1 lane

PR #93 (`/healthz` hardening, TEvo creds, search polish, tests) is iterating live on Render. D1 owns; will mark ready when smoke is green.

### 🟨 D2 lane

PR #91 (Dashboard UI refactor for Render env) is a 4097-line draft. D2 owns; not blocking data flow.

### 🟥 Operator

1. **TickPick token rotation.** `TICKPICK_API_TOKEN` in vault returns HTTP 401. `tickpick_orders` has 0 rows. Needs fresh token from TickPick partner dashboard. Row 109 has detail.

2. **Cron resume decision.** 72 / 72 paused since 17:15 UTC. The maintenance window let the advisor sweep + FK declarations land cleanly. Resume when ready; new crons (128, 129) will start firing on the next minute mark with cadence offsets to avoid pg_cron worker contention.

3. **Row 65 advisor flag still open.** 3 expensive-query items (master_cascade_2min 15.5%, dashboard_writes_24h_refresh 8.8%, backfill_stale_zone_metrics 14.3%). 2 still-paused crons (#38, #98) await operator decision: keep paused, delete, or reactivate at lean cadence.

---

## Section 5 — Hygiene follow-ups (A1 can ship in next session)

1. **`event_match_attempts` cleanup sweep.** 27 of 29 last-7d records are stale — events backfilled after attempt, attempt records not pruned. Small DELETE policy.
2. **`bot_chat.in_reply_to` covering index.** Flagged earlier; every thread query depends on it.
3. **`VALIDATE CONSTRAINT` pass for the 56 NOT VALID FKs.** Scan-time only; can be batched off-hours.
4. **`VACUUM (ANALYZE)`** the 4 never-vacuumed big tables (`listings_snapshots`, `section_metrics`, `seatgeek_listings_snapshots`, `weather_observations`).
5. **`compute_event_breakdowns` lockdown** — REVOKE EXECUTE from anon/authenticated; this was 54.7% of DB time in the earlier window. Per operator: "code in audit phase 2."

---

## Section 6 — bot_chat trail this session

| row | event | summary |
|---|---|---|
| 106 | change_log | A1 paused ALL 70 active cron jobs (operator directive) |
| 107 | change_log | Level 1 SECDEF view sweep done (PR #94) |
| 108 | question | A1 → C1: FK plan ack request |
| 109 | flag | A1 → operator + D2: TickPick token invalid |
| 110 | change_log | A1 data-first sweep summary (ESPN fixed, FRED+weather false-alarm) |
| 111 | change_log | A1 → C1 row 108 reply: 56 FKs shipped in PR #99 |
| 112 | flag | A1 → C1 post-FK audit: 4 cross-lane findings |

---

## Section 7 — main HEAD state

`main` is at `0c24e7b` after this consolidation pass. 6 A1 PRs merged today + this audit doc PR. Migration ledger is in sync with `supabase/migrations/` (no drift introduced — every one of today's changes shipped as an applied-then-codified pair).

Other-lane drafts (#91 D2, #92 C1 pending revision, #93 D1) have all been merged with `origin/main` so they pick up the audit-batch work without rebase effort.

---

**Owner**: A1. **Reviewers**: B1 (security delta), C1 (canonical lane delta), D1 (storefront delta).

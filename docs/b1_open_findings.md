# B1 OPEN SECURITY FINDINGS — live ledger

**Owner**: B1 (Security Manager)
**Last B1 sweep**: 2026-05-17 ~22:00 UTC
**Auto-pruning**: see Protocol below

This is the **operating subset** of open security/defense-in-depth findings B1 has surfaced. The historical audit trail (with closure dates + closure PRs) lives in [`KANBAN.md`](../KANBAN.md) under "B1-NEXT queue" sections — that record is not pruned.

## Protocol

1. **Fixing bot deletes its row from this table in the same PR as the fix.** Don't annotate "✅ CLOSED" here — the row's absence IS the closure signal. (KANBAN keeps the historical record with the CLOSED marker.)
2. **B1 populates as new findings surface** — per-session sweep, war-games rotations, post-merge audits.
3. **Severity tiers** (per [`docs/b1_operating_constraints.md`](b1_operating_constraints.md) §5 severity matrix):
   - `SEC-CRIT` = exploitable today (patch within session, B1 cross-lane authority applies)
   - `SEC-HIGH` = exploitable under common conditions (patch within session, B1 cross-lane authority)
   - `SEC-MED` = defense-in-depth gap (file PR comment to owning lane; fix at lane convenience)
   - `SEC-LOW` = hygiene (operator-only or backlog)
4. **Lane-owner column** identifies who fixes (not who filed). If a row is cross-lane, the primary owner is listed; secondary in parens.
5. **Action column** is the smallest fix that closes the finding — usually a single migration / config change / PR comment.

If you fix a row, just delete it. If you start work, replace the row with `[IN PROGRESS by <lane>, PR #<n>]` so B1's next sweep doesn't double-file.

## SEC-HIGH (exploitable / sequencing-risk)

| ID | Lane | Finding | Action |
|---|---|---|---|
| B1-NEXT-7 | A1 + C1 | RLS gap on 3 tables: `cron_pause_state_20260514`, `sg_event_priority_state`, `sg_priority_policy` (rowsecurity=false, 0 policies, anon SELECT grant). Same pattern as Phase-1 `aq_*_map` gap. | Author `<ts>_security_rls_gap_close_3_tables.sql` — enable RLS + add deny-by-default policy |
| B1-NEXT-11 | Operator | Leaked `CRON_SECRET` in git history (commit `5297739`). Value rotated but repo is public → internet-readable. | Operator decides: `git filter-repo` + force-push window, OR accept (rotated, contained blast radius). G-1. |

## SEC-MED (defense-in-depth)

| ID | Lane | Finding | Action |
|---|---|---|---|
| B1-NEXT-1 | D2 | `d2_cron_freshness()` missing `current_user NOT IN` body guard. REVOKE/GRANT done; this is the 3rd element of §6. | 1-statement `CREATE OR REPLACE FUNCTION` adding guard at top of body |
| B1-NEXT-3 | B1 | Edge function auth-posture inventory (16 fns). Per-function record of `x-cron-secret` vs open vs JWT-gated. | Author `docs/edge_function_auth_inventory.md` |
| B1-NEXT-5 | B1 | Vault orphans check — `release_health_check()` row for `get_app_secret` allowlist entries unused by any prod fn/cron/edge-fn. | 1 SQL migration adding a new row to `release_health_check()` |
| B1-NEXT-8 | A1 | `_health_check_pg_net_errors()` missing §6 body guard (added by PR #115). | Add guard via CREATE OR REPLACE; preserve return shape |
| B1-NEXT-12 | Operator | `dependabot_security_updates` is disabled. | Settings → Code security → Enable. G-2. |
| B1-NEXT-13 | Operator | `secret_scanning_non_provider_patterns` disabled — catches project-shape secrets (`CRON_SECRET`, `APPSCRIPT_INGEST_SECRET`). | Operator settings toggle. G-3. |
| B1-NEXT-14 | Operator | `secret_scanning_validity_checks` disabled — confirms whether leaked tokens still active. | Operator settings toggle. G-4. |
| B1-NEXT-18 | Operator | Verify Actions secrets populated for `sync-check.yml` (`SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY`). Sweep returned empty — could be filtered or unset. | Operator confirms next session via Settings → Secrets |
| B1-NEXT-29 | A1 | `refresh_sg_broker_sales_event_metrics(integer)` missing §6 body guard. Hourly cron at :17. | Add guard via CREATE OR REPLACE |
| B1-NEXT-30 | A1 (D2) | `sg_seller_orders_queue(p_pages, p_statuses)` missing §6 body guard. | Add guard via CREATE OR REPLACE |
| B1-NEXT-31 | A1 | §6 body guard absent on 7 JWT-gated SECDEF RPCs: `get_broker_event_page` (v1/v2/v3), `get_event_sg_listings_full`, `get_event_evo_listings_full`, `get_event_sg_sales_full`, `get_event_cross_source_metrics`. JWT body check IS the primary mitigation; guard is 2nd belt. | Add guard via CREATE OR REPLACE per fn (or batch migration) |
| B1-NEXT-39 | D0 + D1 | `/api/store/search` exposes `we_own` (bool) + `owned_tix` (count). LANE_DISCIPLINE.md §D1 wall rule lists `is_owned` as forbidden. May be intentional storefront-product behavior. bot_chat 308 to D0/D1 for product-intent clarification. | If intentional: add carveout to LANE_DISCIPLINE.md §D1. If not: filter columns from `/api/store/search` response in `app.py` |

## SEC-LOW (hygiene / operator-only)

| ID | Lane | Finding | Action |
|---|---|---|---|
| B1-NEXT-2 | A1 | Drop dead v1 (7-arg) overload of `match_to_aq_event_id` (superseded by 8-arg in mig 20260515230000). **Verify status** — A1 PR #177 may have already dropped this. | `DROP FUNCTION IF EXISTS public.match_to_aq_event_id(text,bigint,text,text,timestamptz,numeric,numeric);` if still present |
| B1-NEXT-4 | B1 | Evaluate CodeQL / SAST for FastAPI + edge functions. Decide whether to add as CI workflow. | Research + decision doc |
| B1-NEXT-6 | B1 | Egress payload review on `*_public` / `/api/store/*` RPCs. (Partial pass via war-games W-3 2026-05-17; rotational.) | Quarterly sweep against [`docs/war_games_playbook.md`](war_games_playbook.md) W-3 + W-4 |
| B1-NEXT-10 | A1 | Migration slot collisions: `20260515300000` (3 files), `20260515320000` (2 files). MIGRATION_CONVENTIONS.md §3 bump-by-30-or-50 not followed. | Rename to next free slots in a future cleanup PR |
| B1-NEXT-15 | Operator | Branch-protection `enforce_admins=false` on `main`. Admin can bypass. | Operator decision (single-operator risk profile acceptable). G-6. |
| B1-NEXT-16 | Operator | `required_signatures=false` on `main`. | Operator decision. G-7. |
| B1-NEXT-17 | Operator | Actions `sha_pinning_required=false`. Workflows use mutable tags (`@v4`). | Operator decision. G-8. |
| B1-NEXT-19 | D1 | Render `ipAllowList: 0.0.0.0/0` on `d2-orders-dashboard` + `vibepass-terminal-test`. Both auth-gated at app layer. | PR comment to D1 — optional tightening. R-1. |
| B1-NEXT-20 | D1 | Render services `autoDeploy: yes`. Consider manual approval gate for `vibepass-storefront-test` (public retail). | PR comment to D1. R-2. |
| B1-NEXT-21 | Operator | No active Slack MCP in repo. Future state: B1 monitors workspace admins/2FA/incidents. | Operator decides Slack MCP install |
| B1-NEXT-24 | B1 | Periodic full-pass drift audit of `PROJECT_BIBLE.md` §4 RPC table (verify all listed RPCs exist with stated signatures). | Quarterly cadence; rotational |
| B1-NEXT-25 | B1 | Periodic full-pass drift audit of `RESOURCES_BIBLE.md` §1 external services. | Quarterly |
| B1-NEXT-26 | B1 | bot_chat thread-closure rate dashboard — add to `release_health_check()` as `coordination.thread_closure_rate_7d`. | 1 SQL migration adding a new row |
| B1-NEXT-27 | B1 | Cross-bible consistency check (PROJECT_BIBLE.md vs LANE_DISCIPLINE.md vs BOT_HIERARCHY.md). | Periodic full diff |
| B1-NEXT-28 | B1 (post-Slack-MCP) | Slack channel signal-quality metric. | Blocked on B1-NEXT-21 |
| B1-NEXT-35 | Operator | Create scheduled task `b1-war-games-rotation`. Every 4h, posts to `#terminal-2-admin` on findings, silent on clean runs. | Operator approves Slack MCP tool + cron creation |
| B1-NEXT-37 | A1 | Backfill `cron_policy` rows for 4 collect-listings windowed crons (1-7d/7-30d/30-60d/60d+). `fire_no_policy` decision currently. | 1 SQL INSERT into `cron_policy` |

## Recently closed (last 7 days — for reference; will rotate out)

These rows have been deleted by the fixing bot per protocol. Historical detail in KANBAN.md.

| ID | Closed by | Date |
|---|---|---|
| B1-NEXT-32 / 33 / 34 | A1 PR #174 | 2026-05-16 |
| B1-NEXT-36 | PR #176 (B1-authored, A1-applied) | 2026-05-16 / 17 |
| B1-NEXT-38 | A1 mig `20260517170000` | 2026-05-17 |

---

**For deeper context** on any row, search `KANBAN.md` for `B1-NEXT-N` — the original entry has full rationale, links to originating PRs, and detection method. This live ledger is the operational subset.

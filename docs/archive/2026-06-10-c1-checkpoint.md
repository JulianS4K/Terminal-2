# C1 Checkpoint — 2026-06-10

> Diffs against `docs/archive/2026-06-08-c1-checkpoint.md` (last authored checkpoint;
> 2026-06-09 was missed — see Open follow-ups). PR #502 (the 06-08 doc) is still open
> on main; C1 updated its branch + greened CI this cycle but base-branch policy
> prohibits a non-A1 merge, so it remains gated on A1.

## Drift status

- **migration_drift_check:** ~98 rows, all `note='standard slot'` with
  `applied_at IS NULL` / `has_codified IS NULL` — the known MCP `apply_migration`
  auto-versioning artifact (filename timestamp ≠ `schema_migrations.version`).
  Structural, not content-level. No applied-but-divergent-content rows. **Real drift: none.**
- Note: three authored-but-uncommitted migration files sit on the active D0 WIP branch
  (`sg_listings_poll_priority_fix`, `sg_ownership_aware_cadence`,
  `demote_tickpick_opt_in_tm_takeover`). Their content is already applied to prod under
  auto-versioned timestamps — apply-then-codify pending PR, not divergence. D0 to commit.
- **release_health_check (status≠ok):** 6 rows — 4 fail / 2 warn (delta below).

### Health checks ≠ ok — delta vs 2026-06-08

| class | check | status | metric | Δ vs 06-08 |
|---|---|---|---|---|
| cron | `failed_jobs_90min` | **fail** | **5** | 🟢 48→5, but **signature changed** — old SG dup-key cleared; now `td_match_apply_cron: column reference "aq_short_event_id" is ambiguous` on every run |
| cron | `subhourly_jobs_silent_90min` | fail | 4 | ⚪ 4→4 — membership shift: `collect-listings-30-60d`, `td_match_apply_cron` (silent because erroring), `sg_canonical_link_overnight`, `listings_deltas_backfill_overnight` |
| functions | `pgcrypto_missing_extensions_searchpath` | fail | 2 | ⚪ unchanged — `exos_check_in_ticket`, `build_watchlist_daily_email` |
| views | `security_definer_views` | fail | 33 | 🟠 25→33 (+8) — new `v_axs_*` views (events_classified, listings, seat_groups, venues_mapped/unmapped) + AXS/exos additions; standing/accepted class but climbing |
| fks | `not_valid_fks` | warn | 54 | ⚪ unchanged — long-standing NOT VALID backlog |
| data_freshness | `vivid_orders_age_min` | warn | 98 min | 🟠 NEW warn — vivid orders 98 min stale (evo_orders cleared on 06-08) |

## Escalation — cron `td_match_apply_cron` erroring every run

Per runbook escalation ("cron erroring every run → page A1"):
`td_match_apply_cron` throws `column reference "aq_short_event_id" is ambiguous`
and is *also* in `subhourly_jobs_silent_90min` — i.e. it errors on effectively every
fire, so TD→AQ match-apply is not landing. Two ambiguous-column fix migrations shipped
06-08/06-09 (`aq_consolidate_safe_dups_fix_ambiguous_col`, `td_seed_owned_xref_fix_ambiguous`)
but this RPC's `WHERE` clause was not covered. Needs a qualified column ref in the
`td_match_apply_cron` body. **C1 detects; fix is A1 / TD-match lane.** Recorded in
bot_chat status + @A1.

Secondary watch: `security_definer_views` +8 in two days (AXS view family). Accepted
class per prior checkpoints, but B1 should confirm the new `v_axs_*` views are
intentionally SECURITY DEFINER and not an oversight.

## PRs landed today

- None merged by C1. Base-branch policy prohibits non-A1 merges to `main`; all
  merges route through A1 push protocol.
- C1 action: updated #502's branch to current + reran CI (all green) so A1 can land it.

## PRs awaiting action (5 open)

| # | title | age | next step |
|---|---|---|---|
| 514 | open-notebook publisher POC (Knicks Finals G4) | ~16h | fresh — leave for author |
| 506 | feat(d0/ops): Render deploy-webhook → GitHub Actions bridge | ~33h | 24–72h, no activity — D0 lane; related WIP also on D0 branch (commit 3fc59f6). Ask D0 for ETA / dedupe |
| 505 | Fix seating_chart 'null' string poison at TEvo ingestion | ~33h | 24–72h — backend/migrations; needs lane sign-off → A1 |
| 502 | chore(c1): daily checkpoint 2026-06-08 | ~35h | **branch updated + green this cycle**; gated on A1/admin merge (base policy) |
| 495 | Fantasy League feature — player-stats ingest + H2H | ~37h | 24–72h — large, multi-area; not C1-eligible, needs lane sign-off |

No token-leakage audit run (no PR was merge-bound for C1 this cycle).

## Bot_chat resolution count

- opened (24h): 94
- resolved (24h): **0**
- unresolved (total): **331** (climbing: was 202 on 06-08)
- unresolved (today): 63
- unresolved >7d: 132
- unresolved p0_security: 0

⚠️ **Resolution stall**: 94 opened / 0 resolved in 24h, total unresolved 202→331 in two
days. The 06-08 autoresolve sweep (`bot_chat_autoresolve_and_noise_sweep`) was a one-shot;
without a recurring resolver, unresolved is accreting again. Flag for A1: consider a
scheduled re-run of the autoresolve sweep or a resolve-hygiene pass.

## Token discipline audit

- Oversized bot_chat posts (>1500 chars) in last 24h: **0** — clean.

## Open follow-ups for A1 / B1

- **A1**: `td_match_apply_cron` ambiguous `aq_short_event_id` — qualify the column (TD-match lane).
- **A1**: merge #502 (06-08 checkpoint, green + current) under push protocol.
- **A1**: bot_chat resolution stall — 331 unresolved, 0 resolved/24h; consider recurring autoresolve.
- **A1**: vivid_orders freshness 98 min — confirm vivid ingest cadence is healthy.
- **B1**: confirm the new `v_axs_*` SECURITY DEFINER views are intentional (+8 this class).
- **Process**: 2026-06-09 checkpoint missed (gap 06-08→06-10). Single miss; not yet the
  >48h two-consecutive-miss escalation threshold, but watch.

## Tomorrow's watch items

- `td_match_apply_cron` fail clears once A1 qualifies the column.
- `security_definer_views` count — does the AXS view family keep growing?
- bot_chat unresolved trend — does it keep climbing past 331?
- `vivid_orders_age_min` — warn → fail if it crosses threshold.
- Checkpoint PR backlog (#502) — does A1 land it?

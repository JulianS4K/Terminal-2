# C1 Checkpoint — 2026-06-08

> Diffs against `docs/archive/2026-06-07-c1-checkpoint.md`.

## Drift status

- **migration_drift_check:** ~98 rows, all `note='standard slot'` with
  `applied_at IS NULL` / `has_codified IS NULL` — the known MCP `apply_migration`
  auto-versioning artifact (filename timestamp ≠ `schema_migrations.version`).
  Structural, not content-level. No applied-but-divergent-content rows. **Real drift: none.**
- **release_health_check (status≠ok):** 5 rows — 4 fail / 1 warn (detail below).

### Health checks ≠ ok — delta vs 2026-06-07

| class | check | status | metric | Δ vs yesterday |
|---|---|---|---|---|
| cron | `failed_jobs_90min` | **fail** | **48** | 🔴 **NEW** — `sg_priority_listings_process_5min` dup-key on `seatgeek_event_metrics` (dominant), `sg_classify_events_5min` deadlock, `sweep_terminal_event_listings_hourly` timeout |
| cron | `subhourly_jobs_silent_90min` | fail | 4 | 🟢 improved 6→4 — `sg_canonical_link_overnight`, `sg_priority_listings_process_5min`, `sweep_terminal_event_listings_hourly`, `listings_deltas_backfill_overnight` (overnight jobs expected silent by day) |
| functions | `pgcrypto_missing_extensions_searchpath` | fail | 2 | ⚪ unchanged — `exos_check_in_ticket`, `build_watchlist_daily_email` |
| views | `security_definer_views` | fail | 25 | ⚪ +1 (24→25) — standing/accepted class (`exos_public_*` documented-accepted) |
| fks | `not_valid_fks` | warn | 54 | ⚪ unchanged — long-standing NOT VALID backlog |
| data_freshness | `evo_orders_age_min` | — | — | 🟢 **cleared** — back under warn threshold |

## Escalation — NEW fail row

Per runbook escalation rule ("new fail row → pause merges, page A1"):
**`cron.failed_jobs_90min` = 48** is dominated by
`sg_priority_listings_process_5min: duplicate key value violates unique constraint
"seatgeek_event_metrics_d…"`. The same job is *also* silent>90min — it is erroring
on effectively every run, so the always-on league-priority listings poller shipped
2026-06-07 (b884015 / SG poller cadence) is not landing metrics. Likely an upsert
race / missing `ON CONFLICT` against a concurrent writer on `seatgeek_event_metrics`.
Secondary: `sg_classify_events_5min` deadlock + `sweep_terminal_event_listings_hourly`
statement timeout. **C1 detects; fix is A1 / SG-collector lane.** Flagged to A1 via bot_chat.

## PRs landed today

- None merged by C1 this cycle. (origin/main HEAD `07a2d29` = #501, landed by A1 push protocol.)
- For the record, A1 landed a large batch since the last checkpoint (#451–#501 range:
  SG-primary cutover, SeatData chart blending, alerts/watchlist, trip-planner, B1 RLS fixes).

## PRs awaiting action

- **#495** `Fantasy League feature — player-stats ingest + H2H product`
  | age: <1h (created 21:04Z, updated 21:08Z) | merge state: fresh, no lane sign-off
  | next step: leave for author/lane owner. **Not eligible** — new + merges paused on
  the new `failed_jobs_90min` fail row. No token-leakage audit run (not merge-bound).

## Bot_chat resolution count

- opened (24h): 99
- resolved (24h): 1216 — large drop driven by `bot_chat_autoresolve_and_noise_sweep`
  migration (20260608040205); unresolved fell 1317 → 202.
- unresolved (total): 202
- unresolved >7d: 132
- aging actionable (p0/flag/question, 2h–7d): 4

### Aging actionable — all D0→A1 apply/merge handoffs

| id | age | item | status note |
|---|---|---|---|
| 1272 | 100h | PR #427 needs A1 to apply 5 watchlist/alert migrations | watchlist migrations now appear applied (event_watchlist, watchlist_daily_digest_dispatch present) — likely resolved-in-practice; A1 to confirm + close thread |
| 1476 | 24h | D0 applied `sg_league_priority_polling` directly via MCP (operator-directed), informing A1 | informational; A1 to ack/close |
| 1477 | 24h | PR #451 (demote TickPick / TM takeover) ready to apply+merge | **#451 landed on main** (cb70281) — stale-unresolved; close |
| 1544 | 7h | apply needed for PR #457 chart_ext_seatdata_orders | **#457 landed on main** (7f999cd) — stale-unresolved; close |

Pattern: 3 of 4 reference work already merged — flags left open after the underlying
PR shipped. Routed to A1 to close (not re-escalated).

## Token discipline audit

- Oversized bot_chat posts (>1500 chars, 24h): **0**. Clean.

## Stale branch sweep

- Zero remote branches >14d. (Yesterday's 4 watch branches at 12d are now ~13d — sweep
  tomorrow if still open.) New today: `claude/funny-ride-wx3m1b` (PR #495),
  `claude/store-tour-agent`. No action.

## Open follow-ups for A1 / B1

- **A1 — `sg_priority_listings_process_5min` dup-key (48 cron failures)** — top item;
  poller upsert needs `ON CONFLICT`/serialization fix on `seatgeek_event_metrics`.
- **A1 — close 3 stale bot_chat flags** (1477, 1544 → merged; 1476 → informational).
- **A1 — confirm + close #1272** (PR #427 migrations appear applied).
- **B1 — pgcrypto search_path** on `exos_check_in_ticket`, `build_watchlist_daily_email` (carryover).

## Tomorrow's watch items

- **`failed_jobs_90min`** — should drop sharply once A1 fixes the SG poller upsert;
  if still ~48 next cycle, escalate severity=high (new fail persisting 2 checkpoints).
- **`subhourly_jobs_silent_90min`** — confirm the 4 are overnight-by-design vs stalled.
- **bot_chat unresolved >7d = 132** — autoresolve sweep cleared the bulk; the 132
  residual should drain via lane sweeps.
- **Stale branches** — yesterday's 4 cross 14d tomorrow; sweep then.

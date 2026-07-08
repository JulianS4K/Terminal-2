---
name: check-poll-mapping-health
description: >-
  Read-only daily health sweep over the ingest pipeline: data-poll failures
  (source freshness, cron deadman, cron/queue/429 monitors) + event-mapping
  drift (unmapped tevo_event_id, AQ-hub dupes, SG canonical link gaps).
  Report + one bot_chat ledger row only — never mutates, never "fixes" (Rule 1).
  Run by the scheduled daily Routine, or on demand when polls/mapping look off.
allowed-tools: Read, Grep, Glob, Bash, AskUserQuestion, mcp__Supabase__execute_sql
---

# Check poll + mapping health

## Overview
Agent-side review layer over the DB's own monitors (`health_monitor_5min` →
`record_source_freshness()` / `record_cron_deadman()`, `RESOURCES_BIBLE §5`) plus the
mapping-drift checks no cron watches. This is **SQL-query mode** (`CLAUDE.md` activation
rule): read-only investigation; the only permitted write is `bot_chat_log()` (standing).
Prefix EVERY query with `SET statement_timeout='8s';` — MCP runs as service_role, uncapped
(`PROJECT_BIBLE §3`). Cross-source facts: `PROJECT_BIBLE §0/§5`; don't restate them here.

## Process
1. **Monitors first** — latest row per check; `off` status = intentionally-inactive poller, NOT a failure:
   `SELECT DISTINCT ON (check_class, check_name) check_class, check_name, status, metric, detail, captured_at
    FROM health_check_history WHERE check_class IN ('source_freshness','cron_deadman','scheduler')
      AND captured_at > now() - interval '1 day' ORDER BY check_class, check_name, captured_at DESC;`
2. **Cron + queue failures (24h):** `SELECT * FROM v_cron_health WHERE fail_24h > 0 ORDER BY fail_24h DESC;`
   and `SELECT * FROM v_pg_net_queue_health WHERE status <> 'clean';`
3. **Upstream pollers:** `SELECT * FROM v_td_poll_health;` (fail_pct, last_ok_at) ·
   `SELECT * FROM v_sg_broker_429_health ORDER BY hour_bucket DESC LIMIT 6;` (pct_429).
   If TD/AXS look silent or stale, probe the CAUSE before flagging: `SELECT td_budget_ok();`
   (false = deliberate credit-gate pause → context, not incident) and the upstream-maintenance
   signature (`RESOURCES_BIBLE §5.1`). AXS fetches burn TD credits — the two stall together.
4. **Mapping drift** — judge DELTAS vs the previous run + the baselines below, never bare presence
   (fresh rows are NULL until the :22/:35/:40 backfill chain; parking/cancelled/international/
   `evo_only` are expected-NULL — `PROJECT_BIBLE §5`):
   - Unmapped orders: `SELECT 'tickpick_orders' AS t, count(*) AS total, count(*) FILTER (WHERE tevo_event_id IS NULL) AS unmapped FROM tickpick_orders
     UNION ALL SELECT 'vivid_orders', count(*), count(*) FILTER (WHERE tevo_event_id IS NULL) FROM vivid_orders
     UNION ALL SELECT 'axs_events', count(*), count(*) FILTER (WHERE tevo_event_id IS NULL) FROM axs_events;`
   - Hub: dup-`tevo_event_id` count (`GROUP BY tevo_event_id HAVING count(*)>1` — §3 aq-dupes landmine)
     + future hub rows w/o tevo: `WHERE tevo_event_id IS NULL AND aq_source IS DISTINCT FROM 'evo_only' AND event_date >= current_date`.
   - SG link gap: `SELECT count(*) FROM sg_events_canonical WHERE sg_event_date >= current_date AND tevo_event_id IS NULL;`
     (ignore `match_status` — stale-by-design; thousands of linked rows still read 'pending').
   - Context only: `discovery_gap_alerts` unresolved + detected-last-7d counts, top `gap_type`s
     (high-volume auto-alert table — a delta metric, not per-row actionable).
5. **Screen vs known state** so nothing gets re-filed: `KANBAN.md` 🟢 OPEN WORK + drift watchlist
   (e.g. `release_health_check`'s stale expected-job list; SG listings path dark by design since 2026-07-02).
6. **Report + ledger.** Final message: severity-ordered findings, each with its evidence row and
   probable cause. Then exactly ONE ledger row so the next run can diff against it:
   `SELECT bot_chat_log(p_level=>'data-collection', p_lane=>'A1', p_event_type=>'change_log',
      p_message=>'[poll-mapping-health] <one line of metrics>; findings: <one-liners or none>');`
   Use `p_event_type=>'flag'` instead only for a NEW material failure that needs action.
   Previous run: `SELECT message FROM bot_chat WHERE message LIKE '[poll-mapping-health]%' ORDER BY id DESC LIMIT 1;`

**Baselines (2026-07-08):** tickpick 574/2578 unmapped · vivid 736/2182 · axs_events 164/368 ·
aq dup tevo_ids 249 · future hub no-tevo 1,999 · SG future unlinked 1,662 · gap_alerts detected-7d 4,097.

## Red flags — stop if any are true
- Any INSERT/UPDATE/DELETE/DDL, cron (un)schedule, edge-fn deploy, or backfill run — fixes are
  separate operator-gated tasks; `bot_chat_log`/`bot_chat_resolve` are this skill's only writes.
- `count(*)` / scan on `sd_sales_normalized` — it is a VIEW running a per-row normalizer
  (`normalize_sd_listing`); it blows the timeout (verified 2026-07-08). Same for unbounded scans
  on firehoses (`listings_snapshots`, `seatgeek_*_snapshots` — `PROJECT_BIBLE §3`).
- A query without `SET statement_timeout='8s';` in front of it.
- Flagging `off`-status freshness rows, `TRACK_BLINDSPOT` tiers, `evo_only` rows, or
  `match_status='pending'` as failures.
- Re-enabling a disabled matcher cron (`auto_match_sg_canonical_v3_hourly` + the 4 `/match`
  siblings were disabled deliberately 2026-06-19 — `PROJECT_BIBLE §3`).

## Rationalizations — excuse → why it's wrong
| "I'll just…" | Reality |
|---|---|
| "…join the source id to `events` to size the gap." | Raw cross-source ids NEVER align → silent 0 rows (§0). Resolve via `aq_event_map`. |
| "…treat every unmapped row as a failure." | Expected-NULL classes exist (parking/cancelled/international/`evo_only`/fresh rows). Judge the DELTA vs baseline. |
| "…report the stale source, done." | A staleness cluster usually has ONE cause (budget gate, upstream maintenance, paused poller). Name it, or state you probed and couldn't. |
| "…quick-fix it while I'm here." | Rule 1: mutation is never safe by default. This skill observes; fixing is a new, operator-gated task. |

## Verification
Reason — don't re-run — that all hold: every reported failure carries its evidence row (monitor
row, cron error, or count-vs-baseline delta); every staleness cluster got a cause probe; the only
write performed was the single `bot_chat_log` row; no known/KANBAN-tracked gap was re-filed as new.

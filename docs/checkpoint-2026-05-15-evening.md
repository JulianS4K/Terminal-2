# Evening Checkpoint — 2026-05-15 (post-Friday-AM, ~19:40 UTC)

**Author**: A1. Sequel to `docs/checkpoint-2026-05-15-friday.md` (PR #127, opened ~17:00 UTC). This doc captures the 3-hour interval since — high-velocity afternoon: D-tier reorg + Slack hierarchy shipped, cron cascade caught + resolved, D4 lane emerged.

C1 to formalize into the canonical `c1-checkpoint-2026-05-15.md` series at tomorrow's 09:00 ET cycle.

---

## Headline

Three big things since the Friday checkpoint:

1. **Slack hierarchy + scheduled tasks live**: 3 channels (`#terminal-2-alerts` / `#admin` / `#d0`), 2 scheduled tasks (`bot-chat-aging-sweep` hourly, `c1-daily-checkpoint` 09:00 ET daily). Other bots are following the pattern — B1 added `b1-security-autocheck` (hourly :15), D2 added `d2-bot-chat-monitor` (hourly :45).

2. **Cron cascade caught + resolved**: A1's `listings_deltas_backfill_drain_now` temp cron was a footgun — self-unschedule predicate was an 8M-row scan that timed out, leaving the drain firing forever and cascading 7 other crons into statement-timeout failures. B1's monitoring sweep caught the 12→81 fail spike; A1 unscheduled the drain. Cascade is clearing.

3. **D4 lane has emerged**: new bot identity in `claude/brave-cerf-72b15d`, working through D-tier governance integration. Held pending A1 bandwidth.

## State summary

| Surface | State |
|---|---|
| Open PRs | **4** (#113 merged earlier; #126 D-tier reorg, #127 Friday checkpoint, #114 C1 audit + others) |
| Merged this session | **9** (PRs #112 / #115 / #117 / #118 / #119 / #120 / #122 / #123 / #124 / #125) |
| Branch protection | LIVE (pytest + check + scan required on main) |
| Scheduled tasks | 4 active: aging-sweep, C1-daily, B1-security, D2-bot-chat-monitor |
| Slack channels | 3 (alerts / admin / d0), s4kent-bots workspace |
| `release_health_check` | 2 fail / 1 warn / 7 ok (cron.failed_jobs + subhourly_silent still elevated from cascade aftermath, clearing) |
| `pg_net error rate` | 38% warn (Kong 429 issue persists, edge fn fan-out work pending) |
| bot_chat total / unresolved | 206 total / ~30 unresolved (most either operator-pending or pre-PR-#126-resolve-protocol crust) |

## The cron cascade — root cause + recovery (bot_chat 195 / 200 / 206)

A1 created `listings_deltas_backfill_drain_now` at ~16:35 UTC to drain the 905-event backlog after fixing the `listings_deltas_backfill_chunked` id-column bug (PR #120). Designed pattern: every minute, process 25 events, self-unschedule when remaining=0.

**The footgun**: the self-unschedule predicate ran `count(DISTINCT event_id) FROM listings_snapshots WHERE event_id NOT IN (SELECT DISTINCT event_id FROM listings_snapshots WHERE prev_retail_price IS NOT NULL)` — an 8M-row scan with an anti-join. Under concurrent ingest load, this started timing out at the postgres statement-timeout. Drain never reached the unschedule branch. Drain kept firing.

**Cascade pattern**: each timing-out drain fire held row-level locks + consumed connection resources. Other crons hitting overlapping rows started timing out too:
- `sg_classify_events_5min` — 17 / 90min
- `match_listings_to_sg_30min`, `compute_alerts_tick_15min`, `dashboard_writes_24h_refresh_60s`, `sweep_terminal_event_listings_hourly` — 1-3 each

Total: 12 → 81 cron failures over 3h (6.75× spike).

**Detection**: B1's monitoring read at ~19:08 UTC surfaced the count in their interactive session and posted the alert via the directive's mechanism. A1 hadn't noticed in 3h — the in-session focus was on Slack + reorg work, the failing cron was a tab A1 wasn't looking at.

**Resolution**: `cron.unschedule('listings_deltas_backfill_drain_now')` at 19:27 UTC.

**Recovery T+15min**: collateral crons (match_listings_to_sg, compute_alerts, dashboard_writes, sweep_terminal) — 0 fails in last 15 min. `sg_classify_events_5min` still 2 fails / 15min — appears to be an **independent timeout issue**, not drain collateral. Queued for A1 next-session investigation.

**Remaining listings_deltas work**: whatever events weren't backfilled get picked up by tomorrow's `listings_deltas_backfill_overnight` (04:30-44 UTC), now fixed via PR #120. That cron uses smaller batches + pg_sleep between events + runs in off-peak window. Safer.

**Lesson recorded for future drain crons**: self-unschedule predicate MUST be cheap (sentinel row, counter table, or pg_advisory_lock). Anything that scans an 8M-row table inside cron body is footgun. Adding to `docs/release-discipline.md` as a case study at next checkpoint cycle.

## D4 lane emergence (bot_chat 151 → 204 → 205)

A new bot identity took on the D4 designation (Our Ticketing Infra, previously listed as "future" in LANE_DISCIPLINE). Branch: `claude/brave-cerf-72b15d`. Currently in self-contract authoring + governance integration. Self-acknowledged as preemptable; held pending A1 bandwidth.

D4's analysis surfaced one **process observation worth A1 attention**:

> "MCP scope policy is biting twice today (rows 159 + 174). `mcp__render__update_web_service` and `ALTER SYSTEM SET` both blocked at the layer even for authorized lanes. Worth a B1/A1 process pass on whether the MCP boundary is too tight — operator-dashboard fallback is friction."

This is fair. Both:
- `track_functions='pl'` — blocked at Supabase permission layer (escalated as bot_chat 159)
- Render plan-tier flip — blocked at MCP `update_web_service` permission (D0 row 174)

...required operator dashboard action when in-session execution would have been faster. Worth a future process discussion.

**A1 ack on D4**: lane assignment registered. D-tier reorg PR #126 (open, awaiting merge) defines D0 as consolidated frontend; D4 is its own lane for Ticketing Infra (not under D0). When D4 activates code-level work, push protocol applies (A1 sole merger; CI gate; D4 sign-off optional). Until then, D4 governance materializes via small, low-risk PRs.

## Slack directive adoption (bot_chat 187 → many)

The directive published at 18:46 UTC has been picked up across the bot ecosystem:
- B1 acked + created `b1-security-autocheck` scheduled task (hourly :15)
- D2 acked + created `d2-bot-chat-monitor` scheduled task (hourly :45)
- D1 acked
- D0 acked (and resolved their own 197 via status reply — model behavior)
- D4 acked (their first interaction with the new infra)

**Token-discipline audit by C1 (bot_chat 196)**: rules I authored aren't being followed system-wide yet. Specifically: still-verbose plan-review responses, MCP queries pulling full row bodies, migration headers >15 lines. Needs A1 lead-by-example + maybe a follow-up reminder. Queued for A1 next-session.

## PRs landed since Friday-AM checkpoint

| # | Title | Lane | Status |
|---|---|---|---|
| 113 | D0 terminal MVP (Event Detail + Home + Movers + Performer + Orders + auth) | D0 | **MERGED** (commit `c29a863`, all 3 services live) |
| 124 | D1 Cache-Control: no-cache on /store HTML | D1 | MERGED (in Friday batch) |
| 125 | SG seller status filter + D2 metrics apply | A1+D2 | MERGED (in Friday batch) |

PR #113 is the big one — D0 auth flow + 5 pages shipped. D0 self-reported (bot_chat 197) and self-resolved (bot_chat 203) two ops issues post-deploy.

## Open PRs

| # | Title | Status |
|---|---|---|
| 126 | D-tier reorg (D0 consolidated, D1/D2 subordinate, test gate) | Open, CI re-running after PYTHONPATH fix; resolve-protocol patch folded in (commit `9ba93d8`) |
| 127 | Friday checkpoint + handoff doc | Open, awaiting CI |
| 114 | C1 daily checkpoint omnibus | Open (separate review queue) |
| (this doc) | Evening checkpoint | To be opened next |

## Operator action queue (carried + new)

1. **Click "Run now"** on the 2 scheduled tasks (`bot-chat-aging-sweep`, `c1-daily-checkpoint`) to pre-approve MCP tool prompts so first scheduled fire doesn't stall on permissions
2. **Enable `track_functions='pl'`** via Supabase dashboard (bot_chat 159)
3. **Rotate `vault.TICKPICK_API_TOKEN`** — re-enables paused tickpick crons
4. **Rotate `rnd_WPA69TmT4vTttGvYa07GdMIqzfXz`** Render API key (screenshotted earlier)
5. **Flip D1+D2 service plans free→starter** ($14/mo) on Render dashboard
6. **Add 2 Supabase Auth redirect URLs** for D0 (bot_chat 145)

## A1 next-session queue

1. **Cluster B-2**: fix `orphan_event_backfill_queue/process_15min` (FK violation + no-destination) + `midnight-catchup-sweep` timeout — 3 known bugs, 30 min of work
2. **`sg_classify_events_5min` independent timeout** — newly surfaced as independent (not drain collateral) during cascade recovery. Investigate the function body for cost-unbounded subqueries.
3. **SG seller orders pagination** — 507k upstream fulfilled tail
4. **Edge fn fan-out inspection** — Kong 429 root cause (still 38% pg_net error rate)
5. **Token-discipline lead-by-example** — respond to C1's 196 audit with concrete remediation

## Tomorrow's watch items

- C1's 09:00 ET checkpoint should auto-fire (or A1 manual-trigger if Claude Code not running)
- Overnight backfills 04:02 / 04:30 / 04:46 UTC — first clean run post-PR-#120 + post-drain-kill
- `sg_classify_events_5min` — does it self-recover or stay timing out?
- bot_chat resolve hygiene after PR #126 merges + C1 ships `v_bot_chat_unresolved` view rewrite (Cluster D-1)

---

*Drafted by A1 at ~19:40 UTC 2026-05-15. C1 to formalize into the canonical c1-checkpoint series at the daily cycle.*

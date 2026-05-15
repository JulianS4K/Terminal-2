# Session 2026-05-14 Handoff (A1 → C1 + subordinates)

Branch: `claude/aq-event-map-cross-source-pk` at commit `05159c9` (6 migrations ahead of `main`'s `0200c01`).

---

## What shipped this session (live in prod + codified)

| Migration | Purpose |
|---|---|
| `20260515210000_universal_aq_matcher_sweep` | 4-tier matcher + sweep cron + SYS- synthetic fallback |
| `20260515220000_aq_venue_performer_maps` | cross-source venue (712) + performer (863) ID maps |
| `20260515230000_matcher_v2_tier_1_5` | Tier 1.5 venue-id matching |
| `20260515240000_listings_aq_linkage` | listings AQ-linkage + market tracking views |
| `20260515250000_cron_policy_gate` | 4-stage cron gate (budget/interval/work/window) |
| `20260515250001_cron_policy_max_staleness_floor` | max-staleness floor on ingest work-checks |

**Coverage post-session**:
- Sales/orders 100% AQ-linked across 5 surfaces (vivid 99.9%, 1 ignored)
- Listings: 100% will be linked after tonight's 04:02-04:14 UTC drain
- 71 active crons paused via `cron_pause_state_20260514` snapshot; 2 new active (retrofit + prune)

---

## What C1 needs to execute next

### 1. Apply `20260515250002_sales_freshness_60min` (operator directive: "60 mins for sales")

Tighten staleness floors from 4h/6h to 60 min on the 3 ingest work-checks:

```sql
UPDATE public.cron_policy SET
  work_check_sql = regexp_replace(work_check_sql, 'interval ''4 hours''', 'interval ''60 minutes''', 'g'),
  notes = notes || ' [staleness floor tightened 4h->60min 2026-05-14]',
  updated_at = now()
WHERE jobname IN ('vivid_orders_queue_30min','tickpick_orders_queue_30min');

UPDATE public.cron_policy SET
  work_check_sql = regexp_replace(work_check_sql, 'interval ''6 hours''', 'interval ''60 minutes''', 'g'),
  notes = notes || ' [staleness floor tightened 6h->60min 2026-05-14]',
  updated_at = now()
WHERE jobname = 'evo_orders_queue_30min';

UPDATE public.cron_policy SET offpeak_min_interval_min = 60
WHERE jobname IN ('vivid_orders_queue_30min','tickpick_orders_queue_30min','evo_orders_queue_30min')
  AND offpeak_min_interval_min > 60;
```

### 2. Apply `20260515250003_listings_cadence_halve` (operator directive: "halve these")

Halve the per-window listings collector cadences. Requires either:
- (a) UPDATE the snapshot table's `schedule` column for those rows BEFORE calling `cron_resume_with_gate`, OR
- (b) Extend `cron_resume_with_gate(p_jobname, p_schedule_override text DEFAULT NULL)` to accept an override

Recommended: option (b) — cleaner, preserves snapshot as audit.

| Cron | OLD cadence | NEW cadence (halved) |
|---|---|---|
| `collect-listings-0-24h` (TEvo) | ~21 min, 67/day | ~10 min, 144/day |
| `collect-listings-7-30d` (TEvo) | 3/day | 6/day |
| `collect-listings-30-60d` (TEvo) | 2/day | 4/day |
| `collect-listings-60d+` (TEvo) | 1/day | 2/day |
| `sg_listings_0-24h` | ~23 min, 63/day | ~12 min, 126/day |
| `sg_listings_1-7d` | ~5h, 9/day | ~2.5h, 18/day |
| `sg_listings_7-30d` | 3/day | 6/day |
| `sg_listings_30-60d` | 2/day | 4/day |
| `sg_listings_60d+` | 1/day | 2/day |

Confirm exact original schedules first: `SELECT jobname, schedule, command FROM cron_pause_state_20260514 WHERE jobname LIKE 'collect-listings-%' OR jobname LIKE 'sg_listings_%';`

### 3. Graduate the 70 paused crons through the gate

Recommended order:
1. Sales ingest first (Vivid, TickPick, SG broker, SG seller, Evo) — fresh data is operator's stated priority
2. Listings collectors (per Section 2, with halved cadences)
3. Heavy sweeps (`match_unmatched_orders_sweep_hourly`, `cross_source_match_tick_30min`, etc.) — already have policy rows pinning them to 5-7 AM ET
4. Refresh views (`latest_event_metrics_refresh_5min`, `dashboard_writes_24h_refresh_60s`)
5. Always-on (vault, health checks)

Per-cron pattern: `SELECT public.cron_resume_with_gate('<jobname>');`

---

## 5-event spot check report (operator request)

**Method**: Top 5 events by `listings_snapshots` volume. All are historical (May 1-5 vs today 5/14) — illustrate pipeline shape, not future-event correlations.

| Event | Date | Price changes | TGs | Min/Avg/Max | Qty | Sales |
|---|---|---|---|---|---|---|
| Orioles@Yankees | 5/1 | 12,118 | 2,841 | $8.60 / $159.60 / $101,998.98 | 57,752 | 0 |
| Orioles@Yankees | 5/2 | 9,323 | 1,869 | $16.25 / $284.36 / $101,998.98 | 40,924 | 0 |
| Orioles@Yankees | 5/3 | 14,513 | 2,430 | $16.21 / $132.18 / $101,998.98 | 74,214 | 0 |
| Orioles@Yankees | 5/4 | 13,280 | 3,235 | $6.79 / $228.71 / $101,998.98 | 63,292 | 0 |
| Rangers@Yankees | 5/5 | 13,060 | 2,909 | $6.93 / $137.05 / $101,992.05 | 62,455 | 0 |

**Hour-of-day price-change pattern (ET) across these 5 events** — peak 2-4 PM ET, off-peak 5-7 AM:
```
00:2442  04:654  08:1736  12:4090  16:5572  20:3821
01:1576  05:306  09:2007  13:3617  17:3694  21:2364
02:1009  06:326  10:2122  14:6418* 18:3331  22:2353
03:709   07:649  11:3482  15:4542  19:2941  23:2533
```

### Gaps + flags

- **$101,998.98 max prices** on every event — investigate (suite/season ticket packages OR data quality)
- **Zero weather observations** for Yankee Stadium 4/24-5/06 → flag to weather lane
- **Zero ESPN snapshots** in the same window → flag to ESPN lane
- **Zero captured sales** for these games — past games, sales pipeline rebuild + AQ matching shipped this session, future events will show full correlation

---

## Owned-inventory bridge ("owned = 24" hint)

The TEvo API's owned-inventory concept maps to our DB as:

- **Brokerage**: `brokerage_id = 1768` ("S4K Entertainment")
- **Offices**: `office_id = 42029` ("Office 3", 1.34M rows) + `office_id = 6412` ("Office 2", 7 rows)
- **Boolean shortcut**: `is_owned = true`
- **Volume**: 1,337,450 of 8,156,026 listings rows = 16.4%

**Query for all current events where we have owned listings**:
```sql
SELECT ls.event_id AS tevo_event_id,
       e.name, e.venue_name, e.occurs_at_local,
       count(*) AS owned_listings,
       count(DISTINCT ls.tevo_ticket_group_id) AS distinct_ticket_groups,
       sum(ls.quantity) AS total_qty,
       max(ls.captured_at) AS last_seen
FROM public.listings_snapshots ls
LEFT JOIN public.events e ON e.id = ls.event_id
WHERE ls.is_owned = true
  AND e.occurs_at_local::timestamptz > now()
GROUP BY 1,2,3,4
ORDER BY owned_listings DESC;
```

**Top active owned events** (as of 2026-05-14, NBA playoffs):

| Event | Date (local) | Owned listings | TGs |
|---|---|---|---|
| Thunder @ Lakers G3 | 5/9 17:30 PT | 88,582 | 5,468 |
| Thunder @ Lakers G4 | 5/11 19:30 PT | 68,244 | 4,431 |
| T-Wolves @ Spurs G2 | 5/6 20:30 CT | 61,663 | 2,703 |
| T-Wolves @ Spurs G1 | 5/4 20:30 CT | 59,713 | 2,532 |
| 76ers @ Knicks G2 (MSG) | 5/6 19:00 ET | 57,408 | 4,759 |
| TBD @ Knicks Round 3 G1 (MSG) | 5/20 | 9,477 (growing) | 1,199 |
| Cavs @ Pistons G5 (LCA) | 5/13 20:00 ET | 17,400 | 1,445 |

---

## Subordinate-specific action items

### Weather lane
- Backfill `weather_observations` for Yankee Stadium 4/24-5/06 (currently zero rows)
- Verify the weather queue cron covers all `venue_assets` rows with `latitude/longitude` set (106/111 venues geocoded)

### ESPN lane
- Backfill `espn_event_snapshots` for the same window
- Verify `espn_scoreboard_queue_4h` cron picks up venue-tagged MLB games

### D0 (Terminal FE)
- Build operator-facing view of S4K-owned events with active listings (query above)
- Surface high-value events for operator attention (88k+ listings on Thunder@Lakers G3)

### D1 (Consumer retail)
- No direct action; new `v_market_listings_by_event` view enables cross-exchange price comparison in retail UI when needed

---

## Open follow-ups (next session)

1. **Outlier prices** ($101,998.98) — investigate + filter strategy
2. **Weather + ESPN backfill** — coverage gap for historical events
3. **xlsx re-extract** — adds AQ Performer UUID (`aq_performer_map.performer_uuid` currently NULL)
4. **`release_health_check()` `format()` bug** — fails when staleness > 60 min (will trigger as soon as crons resume; 10-line fix)
5. **Auto-reconcile SYS- → curated** — when operator adds real AQ entries, migrate SYS- order rows
6. **Cron graduation queue** — operator decides order; recommended in Section 3

---

## Plan file reference

Full design + verification SQL: `~/.claude/plans/zany-skipping-fox.md` (operator-local; mirror lives in commit history of `claude/aq-event-map-cross-source-pk`).

Owner: A1 (handing off to C1).

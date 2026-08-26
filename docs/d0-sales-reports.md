# D0 Sales Reports — build spec

> **Doc version:** v1.2.0 (2026-08-26)
> **Status:** Shipped & live in `Terminal .5` (project `hzrizjeaxlqcxfrtczpq`) — DB layer, the FastAPI read layer (`routers/d0_sales.py`) and the terminal pages (`static/terminal/sales.{html,js}`, `leagues.js`) are all built; `tests/test_d0_sales_routes.py` covers the routes. (v1.1.0 corrected the stale "FastAPI + terminal UI are the remaining build" line, which outlived the build by ~2 months.)
> **Scope:** D0 terminal surface. Read-only over already-applied Supabase objects — **do not rebuild the data layer.**

This is the self-contained build note for the league/performer **sales reports**. The SQL is done and verified against live data; what's left is the FastAPI read layer and the terminal pages that render it. Everything below is grounded in the actual database objects, not memory — column lists, the refresh functions, the cron schedules, and the validation numbers were all pulled from the live project on 2026-06-24.

A reader cross-checking facts: the canonical homes are `PROJECT_BIBLE.md §5` (cross-source architecture), `docs/d0_terminal_build.md` (terminal build manual), and `RESOURCES_BIBLE.md` (table catalogue). This doc only adds the sales-report-specific wiring; it does not restate those.

---

## 0. What already exists (DON'T rebuild)

### 0.1 Snapshot table

`public.d0_sales_fact` — a plain table (NOT a matview), rebuilt by a refresh function. One row per **sale line**. Columns:

| col | type | notes |
|---|---|---|
| `source` | text | `seatgeek_sales` · `seatdata` · `evo` · `seatgeek_orders` · `tickpick` · `vivid` |
| `is_owned` | bool | `true` = our own order (evo / sg_orders / tickpick / vivid); `false` = market (seatgeek_sales / seatdata) |
| `event_id` | bigint | TEVO event id (canonical join key everywhere) |
| `league` | text | one of `MLB NBA NFL NHL MLS WNBA` |
| `section` | text | raw source section string, `(blank)` if empty, `(no section)` for sources that don't carry one |
| `qty` | numeric | tickets on the line |
| `price_per_ticket` | numeric | per-ticket price |
| `gross` | numeric | line revenue (`price_per_ticket * qty`, source-specific) |

Indexes: `idx_d0_sales_fact_event(event_id)`, `idx_d0_sales_fact_league(league)`. **RLS is ENABLED** on this table (see §5).

### 0.2 Report views (all live, `public` schema)

**League-level**
- `d0_league_summary` — `league, total_revenue, tickets_sold, median_price, avg_price, sale_lines`
- `d0_league_price_weighted` — `league, tickets, weighted_median_price`
- `d0_league_performers` — `performer_id, performer_name, league` (the MLB/NBA/NFL/NHL/MLS/WNBA roster from `performer_metadata.espn_league`)
- `d0_league_events` — `event_id, league` (event → home-team's league)
- `d0_league_event_roles` — `event_id, event_league, performer_id, performer_name, performer_league, role` (home/away expansion per event)
- `d0_league_visiting_teams` — `league, visiting_performer_id, visiting_team, away_revenue, away_tickets, away_median_price, rank_by_revenue, rank_by_median_price`

**Performer-level** (all carry `performer_id, performer_name, performer_league, role`)
- `d0_perf_sale_lines` — the per-line grain: `+ source, is_owned, section, qty, price_per_ticket, gross` (base view the rest aggregate from)
- `d0_perf_home_away` — `home_revenue, away_revenue, total_revenue, home_tickets, away_tickets, home_median_price, away_median_price`
- `d0_perf_price_stats` — `sales, tickets, p25, median, p75, avg_price, max_price` (per role)
- `d0_perf_price_weighted` — `tickets, weighted_median_price` (per role)
- `d0_perf_by_source` — `source, is_owned, tickets, revenue` (per role)
- `d0_perf_sections` — `section, tickets, revenue, rank_by_revenue, rank_by_volume` (per role; excludes `(no section)`)
- `d0_perf_top5_sections` — same as sections, pre-filtered to `rank_by_revenue <= 5`

**Ops**
- `d0_refresh_health` — `jobname, status, start_time, end_time, duration_secs, return_message` (reads `cron.job_run_details` for the two refresh jobs)

### 0.3 Refresh functions + crons (live)

| function | purpose |
|---|---|
| `d0_refresh_sales_fact()` | full rebuild — `DELETE` all + re-`INSERT` from all 6 sources |
| `d0_refresh_sales_fact_active(p_window interval default '3 days')` | incremental — rebuild only events with `events.last_seen >= now()-p_window`; returns event count |

| cron | schedule (UTC) | command |
|---|---|---|
| `d0_refresh_sales_fact_nightly` | `40 6 * * *` | `select d0_refresh_sales_fact_active();` |
| `d0_refresh_sales_fact_weekly_full` | `10 2 * * 0` | `select d0_refresh_sales_fact();` |

### 0.4 Applied migrations (already in prod DB)

`20260624173953_d0_sales_reports_views` · `20260624174321_d0_sales_fact_materialize` · `20260624175249_d0_sales_fact_rls_and_refresh` · `20260624175914_d0_weighted_median_top5_and_schedule` · `20260624180410_d0_incremental_refresh_and_health`

> ⚠️ These were applied directly to prod; the `.sql` files are **not yet committed** to `supabase/migrations/`. If B1/A1 want them under version control, that's a separate file-only PR (RULE-6 doc set is unaffected). The objects themselves are live regardless.

---

## 1. Data model & attribution rules

**Universe — split by source since mig `20260826120000`.**

- **Owned sources** (`evo`, `seatgeek_orders`, `tickpick`, `vivid`) cover **all events**, via `d0_sales_events` (a left join to the league roster). Non-league sales land with **`league IS NULL`** — the column is nullable now. This is what makes S4K sales at comedy, community, mid-tier-music and venue-distributed events visible at all.
- **Market sources** (`seatgeek_sales`, `seatdata`) stay gated to the 6 ESPN leagues via `d0_league_events`, deliberately: extending them adds 420,849 SeatData lines alone to a ~924k-row table, and the SG-sales firehose join over the non-league universe did not complete in 60s. Widening market breadth is its own decision.

An event's `league` is still its **home team's** league. The league-level views (`d0_league_summary`, `d0_league_price_weighted`) filter `league IS NOT NULL`, so league reporting is unchanged; every performer view inner-joins `d0_league_event_roles` and so admits league events only.

> **Known gap (not fixed by that migration).** 200 fulfilled `seatgeek_orders` and 68 `evo_order_items` carry no resolvable `tevo_event_id`, so they cannot join an event and stay untracked regardless of universe. That is an order→event mapping problem (`backfill_order_tevo_from_aq()`, hourly :40).

**Home / away expansion (`d0_league_event_roles`).** Each event fans out to every performer on it (`performer_ids || primary_performer_id`, de-duped). `role = 'home'` when the performer is `events.primary_performer_id`, else `'away'`. Because `d0_perf_sale_lines` joins fact rows to *every* role on the event, **a single sale is counted once under the home team and once under the away team.** This is intentional — it lets "Inter Miami sales" mean *all sales at Inter Miami events*, home or away.

> 🚨 **Double-count rule.** Because of the home/away expansion, **you cannot sum performer-level revenue across teams to get a league total** — every sale would be counted twice. For league totals always use `d0_league_summary` (which aggregates `d0_sales_fact` directly, no role join). Performer views are for *per-team* questions only.

**Owned vs market.** `is_owned=true` = our sales (evo, seatgeek_orders, tickpick, vivid). `is_owned=false` = broker/market data (seatgeek_sales, seatdata). Split with the `source` / `is_owned` columns (`d0_perf_by_source`) when a report needs "our sales vs the market."

**Two medians, on purpose.**
- **Per-sale median** (`d0_perf_price_stats.median`, `d0_league_summary.median_price`) — `percentile_cont(0.5)` over sale *lines*. Each line counts once regardless of qty. Good for "typical transaction."
- **Quantity-weighted median** (`*_price_weighted.weighted_median_price`) — the price at which cumulative qty crosses 50% of total qty. Each *ticket* counts once. Good for "typical seat sold." These differ, sometimes a lot — surface both and label them.

---

## 2. Caveats (read before wiring — these bite)

1. **SeatGeek canonical-mapping trap.** `seatgeek_sales` is joined via `sg_events_canonical.tevo_event_id → le.event_id`, NOT raw `tevo_event_id` on the snapshot. Using the raw column **undercounts SeatGeek volume ~3×** because most SG sales rows carry a null/uncanonical tevo id until the canonical matcher links them. The refresh function already does this correctly — just don't "simplify" the join.
2. **Lopsided league coverage.** Volume is wildly uneven (MLB has ~348k sale lines; NFL ~760). Low-volume leagues' medians are noisy. The UI should show `sale_lines` so a user can weight the read.
3. **SeatData is zero for MLS.** SeatData has no MLS feed, so MLS market data comes essentially only from SeatGeek. Don't present "no SeatData rows" as "no sales."
4. **Owned ≠ market.** Owned volume is tiny next to market for most teams (e.g. Inter Miami: 2 owned tickets vs 4,154 market). Don't blend them into one "revenue" number without the split.
5. **Home-less clubs.** A handful of MLS clubs have no `primary_performer_id` home mapping yet, so they only ever appear as `away`. They'll have a null/absent `home_*` block — render gracefully, don't assume both roles exist.
6. **Raw section strings.** `section` is the unnormalized source string (`club 119`, `107`, `(blank)`). No venue-section normalization is applied. Group/label as-is; `d0_perf_sections` already drops `(no section)`.

---

## 3. FastAPI read layer (the build)

Follow the existing convention in `app.py`: a global service-role client `sb` (`create_client(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY)`), `db = require_sb()`, `_=Depends(require_auth)`, return a plain dict. Views are read with `db.table(<view>).select("*")...` (PostgREST); the role expansion makes `eq("performer_id", id)` the standard filter. Suggested home: a new `routers/d0_sales.py` mounted like the other routers, or inline next to the `/api/broker/...` block.

| endpoint | backing view(s) | params | returns |
|---|---|---|---|
| `GET /api/d0/sales/leagues` | `d0_league_summary` + `d0_league_price_weighted` | — | per-league totals (joined on `league`) |
| `GET /api/d0/sales/leagues/{league}/visiting-teams` | `d0_league_visiting_teams` | `league`, `limit` | away-team leaderboard for a league |
| `GET /api/d0/sales/performers/{performer_id}` | `d0_perf_home_away` + `d0_perf_price_stats` + `d0_perf_price_weighted` | `performer_id` | the performer report header (home/away revenue, price dist, weighted median) |
| `GET /api/d0/sales/performers/{performer_id}/by-source` | `d0_perf_by_source` | `performer_id` | owned-vs-market split per role |
| `GET /api/d0/sales/performers/{performer_id}/sections` | `d0_perf_sections` or `d0_perf_top5_sections` | `performer_id`, `top5: bool`, `role` | section leaderboard |
| `GET /api/d0/sales/health` | `d0_refresh_health` | — | last refresh runs (for the health page) |

Example — league index:

```python
@app.get("/api/d0/sales/leagues")
def d0_sales_leagues(_=Depends(require_auth)):
    db = require_sb()
    summ = {r["league"]: r for r in db.table("d0_league_summary").select("*").execute().data or []}
    for w in db.table("d0_league_price_weighted").select("*").execute().data or []:
        summ.setdefault(w["league"], {"league": w["league"]})["weighted_median_price"] = w["weighted_median_price"]
    return {"leagues": sorted(summ.values(), key=lambda r: -(r.get("total_revenue") or 0))}
```

Example response (real data, 2026-06-24):

```json
{"leagues": [
  {"league":"MLB","total_revenue":96902138.24,"tickets_sold":1122825,"median_price":64.29,"avg_price":89.75,"sale_lines":348179,"weighted_median_price":...},
  {"league":"NBA","total_revenue":59468394.54,"tickets_sold":12768,"median_price":3240.00,"avg_price":5199.82,"sale_lines":6137}
]}
```

Example — performer report header (`GET /api/d0/sales/performers/72393`, Inter Miami):

```python
@app.get("/api/d0/sales/performers/{performer_id}")
def d0_sales_performer(performer_id: int, _=Depends(require_auth)):
    db = require_sb()
    ha  = (db.table("d0_perf_home_away").select("*").eq("performer_id", performer_id).execute().data or [None])[0]
    ps  =  db.table("d0_perf_price_stats").select("*").eq("performer_id", performer_id).execute().data or []
    wgt =  db.table("d0_perf_price_weighted").select("*").eq("performer_id", performer_id).execute().data or []
    if ha is None:
        raise HTTPException(404, "no sales for performer")
    return {"performer_id": performer_id, "performer_name": ha["performer_name"],
            "league": ha["performer_league"], "home_away": ha,
            "price_stats": {r["role"]: r for r in ps},
            "weighted": {r["role"]: r["weighted_median_price"] for r in wgt}}
```

---

## 4. Security / grants

- **RLS is ON for `d0_sales_fact`.** The views are `SELECT`-grantable to `anon`/`authenticated` but reading them still hits the base table's RLS. **Do not expose these to the browser via PostgREST + anon key.** Go through the FastAPI service-role layer, which is the established D0 pattern (`sb` already uses `SUPABASE_SERVICE_ROLE_KEY`, which bypasses RLS). No new GRANT/policy work is required for the planned UI.
- `coworker_readonly` and `analyst_ro` already hold `SELECT` on the fact table + all views (for ad-hoc analyst queries). Nothing to add there.
- If a future requirement genuinely needs direct anon/PostgREST read (it shouldn't), that's an **A1** DB-security decision (RULE-1/§5), filed as a migration + `bot_chat` to A1 — not something the D0 UI build should add on its own.

---

## 5. Ops

- **Refresh model.** `d0_refresh_sales_fact()` is a single-transaction `DELETE` + `INSERT`. Readers either see the old full set or the new one — no torn/empty window for SELECTs (the truncate-and-reload happens inside one txn). Safe to run live.
- **Manual refresh** (A1-gated, prod-mutation per RULE-1): `select d0_refresh_sales_fact();` (full) or `select d0_refresh_sales_fact_active('7 days'::interval);` (wider incremental window).
- **Health.** Surface `d0_refresh_health` on the terminal health page — alert if the newest `d0_refresh_sales_fact_nightly` run isn't `succeeded` or is >24h stale. (Table starts empty until the first cron fire.)

---

## 6. Terminal UI (the build)

> **Reality check:** the D0 terminal is **vanilla JS + uPlot**, served as static pages from `static/terminal/` (see `static/terminal/app.js`, `nav.js`, `auth.js`, `lib/supabase.js`, `performer.html`/`performer.js`, charts via `lib/uplot.iife.min.js`). It is **not** a React app — build these two screens as terminal pages in that idiom, fetching the §3 endpoints with the shared auth'd `fetch` helper, not a JS Supabase client. (Earlier drafts of this note said "React"; the repo says otherwise.)

**Screen A — League dashboard** (`static/terminal/sales.html` + `sales.js`)
- Table of leagues from `/api/d0/sales/leagues`: revenue, tickets, per-sale median, weighted median, `sale_lines` (so noise is visible). Sort by revenue.
- Click a league → away-team leaderboard from `/visiting-teams` (revenue + median, ranked). uPlot bar for top-N.

**Screen B — Performer report** (extend existing `performer.html`/`performer.js`, add a "Sales" tab)
- Header: home vs away revenue & tickets, per-sale median + weighted median, owned-vs-market split (`/by-source`).
- Price distribution: p25 / median / p75 / max per role (`price_stats`) — uPlot or a simple bar.
- Sections: top-5 by revenue per role (`/sections?top5=true`), raw section labels.
- Respect §2.5: render only the roles present (home-less clubs show away only).

---

## 7. Validation numbers (smoke-test the wiring)

**`d0_league_summary` (live 2026-06-24):**

| league | total_revenue | tickets_sold | median_price | avg_price | sale_lines |
|---|---:|---:|---:|---:|---:|
| MLB | 96,902,138.24 | 1,122,825 | 64.29 | 89.75 | 348,179 |
| NBA | 59,468,394.54 | 12,768 | 3,240.00 | 5,199.82 | 6,137 |
| WNBA | 4,868,476.79 | 43,612 | 79.00 | 120.83 | 17,884 |
| MLS | 1,370,618.76 | 19,027 | 54.00 | 73.93 | 6,378 |
| NHL | 1,080,196.88 | 1,533 | 723.00 | 872.63 | 687 |
| NFL | 906,876.89 | 2,003 | 373.39 | 461.73 | 760 |

**Inter Miami** (`performer_id = 72393`, MLS):
- `d0_perf_home_away`: home_revenue 395,213.43 / away_revenue 134,474.02 / total 529,687.45; home_tickets 3,423 / away_tickets 733; home_median 89.33 / away_median 173.00
- `d0_perf_price_stats` home: sales 1,193, tickets 3,423, p25 61.00, median 89.33, p75 132.64, avg 120.69, max 2,100
- `d0_perf_price_weighted`: home tickets 3,423 → weighted_median 87.87; away tickets 733 → weighted_median 172.00 (note ≠ per-sale median, as expected)
- `d0_perf_by_source`: seatgeek_sales home 3,423 tix / $395,213.43 · seatgeek_sales away 731 tix / $134,070.82 · evo (owned) away 2 tix / $403.20 — i.e. ~2 owned vs 4,154 market tickets (§2.4 in miniature)

If your endpoints return these, the join logic and the home/away expansion are wired correctly.

---

## 8. Build checklist

- [ ] `routers/d0_sales.py` (or inline) — the 6 endpoints in §3, `require_auth` + service-role `require_sb()`.
- [ ] Smoke each endpoint against §7 numbers (esp. league totals from `d0_league_summary`, NOT summed performers).
- [ ] `static/terminal/sales.html` + `sales.js` — league dashboard (Screen A).
- [ ] Performer "Sales" tab in `performer.js` (Screen B), role-aware rendering.
- [ ] `d0_refresh_health` panel on the health page + >24h-stale alert.
- [ ] (Optional, separate PR) commit the 5 `20260624…d0_sales_*` migration `.sql` files into `supabase/migrations/` for version control.
- [ ] Don't touch the DB layer; don't expose views to anon/PostgREST; don't sum performer revenue for league totals.

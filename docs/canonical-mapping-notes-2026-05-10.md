# Canonical mapping & drift-prevention — notes for future chats

**Branch / PR:** `claude/audit-datasets-schemas-auoc3` → PR #51
**Audit date:** 2026-05-10
**Migrations added:** `20260510120000_phase1_*` through `20260510170000_phase11_*`

---

## TL;DR

The cross-source mapping layer (Tevo ↔ ESPN / SeatGeek / SeatData / Wikipedia)
is now backfilled, drift-locked with triggers and UNIQUE constraints, and
audit-instrumented. **Drift is 0/0** and **1-to-1 health is 0 violations across
all 6 mappings**. Run `SELECT * FROM v_one_to_one_health;` and
`SELECT audit_cross_source_health();` for live state.

If you're picking this up for further work, **read the "Known issues" and
"What NOT to do" sections below before changing anything**.

---

## Architecture

### The mapping pipeline

```
            per-source xref tables (PK on tevo_id; UNIQUE on external)
            ────────────────────────────────────────────────────────────
            event_xref                    (tevo_event_id ↔ espn_event_id)
            seatgeek_event_xref            (tevo_event_id ↔ sg_event_id)
            seatdata_event_xref            (tevo_event_id ↔ sd_event_id)
            seatgeek_venue_xref            (tevo_venue_id ↔ sg_venue_name)
            seatdata_venue_xref            (tevo_venue_id ↔ sd_*_venue_id)
            performer_espn_team_xref       (tevo_perf_id ↔ espn_team_id × league)
            seatgeek_performer_xref        (tevo_perf_id ↔ sg_performer_name)
            seatdata_performer_xref        (tevo_perf_id ↔ sd_performer_name)
            performer_wikipedia            (tevo_perf_id ↔ wiki_pageid/title)
            venue_assets.espn_venue_id     (tevo_venue_id ↔ espn_venue_id)
            sg_events_canonical            (sg_event_id, may set tevo_event_id)
                            ↓
              AFTER INSERT / UPDATE / DELETE TRIGGERS
                            ↓
            performer_external_ids          (Tevo-keyed, source ∈ data_sources)
            ↓ trigger ↓
            canonical_external_ids          (entity_kind, tevo_id, source_key)
                            ↑
                  audit views read from here
```

**Vocabulary contract** — `canonical_external_ids.source_key` and
`performer_external_ids.source` must be values from `data_sources.source_key`:

```
espn  open_meteo  osm_nominatim  seatdata  sg_broker  sg_seller  tevo  wikipedia  espn_team
```

Phase 3 added `espn_team` (sub-source for team-identity rows from
`performer_espn_team_xref`) and normalized legacy `seatgeek` → `sg_broker`.

### What each phase did

| Phase | File | Purpose |
|---|---|---|
| 1 | `20260510120000_phase1_backfill_event_xrefs.sql` | Backfill `seatgeek_event_xref` and `seatdata_event_xref` from snapshot tables and `sg_events_canonical`. |
| 2 | `20260510120100_phase2_backfill_performer_external_ids.sql` | Add SG / SD / Wikipedia rows to `performer_external_ids` (was ESPN-only). |
| 3 | `20260510120200_phase3_backfill_canonical_external_ids.sql` | Backfill `canonical_external_ids` from every xref + `venue_assets` + PEI. Added `espn_team` to `data_sources`; normalized `seatgeek` → `sg_broker`. |
| 4 | `20260510120300_phase4_drift_prevention_triggers.sql` | 12 trigger functions: every per-source xref AFTER INSERT/UPDATE/DELETE mirrors into PEI / CEI. `sg_events_canonical` → `seatgeek_event_xref` auto-mirror. |
| 5 | `20260510120400_phase5_date_venue_overlay_views.sql` | `v_event_base` + 10 overlay views (holidays, school_breaks, weather, NWS, reddit, major_calendar, sporting_rivalries, MLB_branded_series, ESPN news, ESPN injuries). |
| 6 | `20260510120500_phase6_audit_views_and_rpc.sql` | `v_canonical_coverage_v2`, `v_canonical_drift`, `v_orphan_*`, `v_event_overlay_summary`, `audit_cross_source_health()` RPC. |
| 7 | `20260510130000_phase7_drift_hardening_and_extra_overlays.sql` | TRUNCATE drift guards (statement-level); venue country normalization (`USA`/`Canada` → ISO `US`/`CA` so holidays match); `v_event_espn_state` / `v_event_team_standings` / `v_event_evo_orders` / `v_event_competitors` overlays. |
| 8 | `20260510140000_phase8_sg_candidate_performer_view.sql` | `v_sg_unmatched_candidate_performers` + `record_sg_performer_match()` RPC. Edge Function `match-sg-performers-to-tevo` calls Tevo `/v9/performers/search`. |
| 9 | `20260510150000_phase9_one_to_one_constraints.sql` | UNIQUE constraints on the reverse direction of every performer / venue mapping. Cleaned 2 wrong `venue_assets.espn_venue_id` rows (State Farm Arena vs Canada Life Centre, crypto.com Arena vs Intuit Dome). |
| 10 | `20260510160000_phase10_candidate_normalization.sql` | Filter parking + theater_tour candidates; strip Preseason / Weekend N / Saturday Only / Citi Presale; collapse `X X` duplicates; alias map (Oakland Athletics → Athletics, LA Galaxy → Los Angeles Galaxy, etc.). Edge Function v3 retries each alias. |
| 11 | `20260510170000_phase11_sg_event_matcher_by_venue_date.sql` | `v_sg_event_match_proposals` + `sg_match_event_by_venue_date()` + `auto_match_sg_canonical_relaxed()`. Match SG events to Tevo events by venue + date when performer name is unparseable. |

### Trigger inventory (drift prevention)

| Source table | Trigger | Fires |
|---|---|---|
| `event_xref` | `event_xref_cei_sync` | INS/UPD/DEL row, TRUNCATE statement |
| `seatgeek_event_xref` | `seatgeek_event_xref_cei_sync` | INS/UPD/DEL, TRUNCATE |
| `seatdata_event_xref` | `seatdata_event_xref_cei_sync` | INS/UPD/DEL, TRUNCATE |
| `seatgeek_venue_xref` | `seatgeek_venue_xref_cei_sync` | INS/UPD/DEL, TRUNCATE |
| `seatdata_venue_xref` | `seatdata_venue_xref_cei_sync` | INS/UPD/DEL, TRUNCATE |
| `venue_assets` | `venue_assets_espn_cei_sync` | INS/UPD of `espn_venue_id`, DEL |
| `performer_external_ids` | `performer_external_ids_cei_sync` | INS/UPD/DEL row, TRUNCATE statement |
| `seatgeek_performer_xref` | `seatgeek_perf_xref_pei_sync` | INS/UPD/DEL — writes PEI which cascades to CEI |
| `seatdata_performer_xref` | `seatdata_perf_xref_pei_sync` | INS/UPD/DEL — writes PEI |
| `performer_wikipedia` | `performer_wikipedia_pei_sync` | INS/UPD/DEL — writes PEI (skips `is_rejected`) |
| `performer_espn_team_xref` | `performer_espn_team_xref_cei_sync` | INS/UPD/DEL row, TRUNCATE |
| `sg_events_canonical` | `sg_events_canonical_to_xref` | INS/UPD of `tevo_event_id` — auto-mirror to `seatgeek_event_xref` |

### Live audit endpoints (use these to monitor)

```sql
SELECT audit_cross_source_health();          -- jsonb snapshot: drift / coverage / overlays
SELECT * FROM v_one_to_one_health;           -- 6 rows; n_violations should always be 0
SELECT * FROM v_canonical_coverage_v2;       -- per-entity per-source coverage
SELECT * FROM v_canonical_drift;             -- empty if registry is in sync
SELECT * FROM v_orphan_seatgeek_data;        -- SG listings/sales/orders without tevo_event_id
SELECT * FROM v_event_overlay_summary LIMIT 20;
SELECT * FROM v_sg_event_match_proposals LIMIT 20;
SELECT * FROM v_sg_unmatched_candidate_performers;
```

---

## Current state (2026-05-10)

```
canonical_external_ids       1,817 rows
  event/espn        855
  event/seatdata      1
  event/sg_broker    11
  performer/espn    217
  performer/espn_team 169
  performer/sg_broker 130
  performer/wikipedia 294
  venue/espn        109
  venue/sg_broker    31

performer_external_ids         641 rows
  espn        217
  sg_broker   130
  wikipedia   294

drift_xref_to_canonical          0
drift_canonical_to_xref          0
v_one_to_one_health violations   0  (all 6 mappings)

sg_events_canonical:  11 matched / 217 unmatched
events:             3,346 total
venues:               363 total (derived from events.venue_id)
performers:           342 total (derived from events.primary_performer_id)
```

---

## Known issues (LIVE — please be careful)

### 1. Most unmatched SG events are historical and unmatchable
- 185/217 unmatched `sg_events_canonical` rows have `sg_event_date` between
  2018-2020. Tevo's `events` table only carries current/future events
  (older entries get pruned by Tevo). **We can never match these.**
- 31 are upcoming (next 12 months); they'll match incrementally as Tevo's
  `collect-listings` cron walks its date windows. No code change required.
- **Don't write code that "fixes" the 185 historic ones — there is nothing
  in `events` to match them to.** The relaxed matcher
  `auto_match_sg_canonical_relaxed()` correctly returns `unmatched` for
  these.

### 2. Tevo's catalog lags SG for some upcoming events
- Confirmed: SG has events at Mercedes-Benz Stadium on 2026-05-09 but
  Tevo's earliest event there is 2026-08-01. Stanford Stadium / The Wiltern
  have 0 Tevo events at all. The fix is on the **ingest** side
  (`collect-listings` window coverage), not the matcher.

### 3. Genuinely noisy SG event names (~7 candidates)
- `many more`, `Forged in Houston`, `The Sunday Service Choir`,
  `REFES DU SOL` (diacritics garbled — should be `RÜFÜS DU SOL`),
  `Papa Roach, I Prevail and Ice Nine Kills` (comma-separated headliners
  not split because commas can appear in real names like `Earth, Wind & Fire`).
- These won't match performer-side. The Phase 11 venue+date matcher
  picks them up automatically when they fall on the same venue/date as
  a Tevo event. **Don't add comma-splitting to the parser without a
  whitelist for "real" performer names that contain commas.**

### 4. Touring Broadway shows are filtered out by design
- `Frozen the Musical New York`, `Dear Evan Hansen Philadelphia`,
  `The Book of Mormon Portland` are tour stops, not unique performers.
  `v_sg_unmatched_candidate_performers` excludes them via
  `'\s+the\s+Musical'` and an explicit show-name list. **If you add a new
  touring show, append it to the list in the migration view.**

### 5. ESPN team_id is per-league
- The `performer_external_ids` reverse UNIQUE is on
  `(source, external_id, COALESCE(league, '__no_league__'))` — ESPN team
  `14` is Boston Bruins (NHL), Atlanta Braves (MLB), Memphis Grizzlies (NBA),
  etc. **Never query `WHERE source='espn' AND external_id='14'` without
  also filtering on `league`.**

### 6. Two cleaned-up venue_assets rows (Phase 9)
- `espn_venue_id=1827` was wrongly assigned to `tevo_venue_id=3316`
  (Canada Life Centre, Winnipeg) — corrected to 1228 (State Farm Arena).
- `espn_venue_id=1841` was wrongly assigned to `tevo_venue_id=48249`
  (Intuit Dome) — corrected to 1480 (crypto.com Arena).
- The `crawl-venues-and-performers` Edge Function may re-assign these if
  its name-matching is non-exact. **Watch for `v_one_to_one_health`
  violations on `venue_assets:reverse(espn_venue_id)`** — that's the
  signal the bug is back.

### 7. Holidays / school_breaks overlays use ISO 2-letter country codes
- `holidays.country` and `school_break_windows.country` use `US`/`CA`/`MX`.
- `venue_assets.country` was historically `USA`/`Canada`/null.
- `v_event_base.venue_country` normalizes via a CASE expression. **If new
  venue ingestion writes `United States` or other variants, add the case
  to the CASE in the `v_event_base` definition.**

### 8. canonical_external_ids events section has many-to-one (intentional)
- ESPN tournament `external_id='189-2026'` appears 52 times (52 Tevo
  events all link to one ESPN tournament container). This is **not** a
  drift bug — `v_canonical_drift` returns 0 because the PK is
  `(entity_kind, tevo_id, source_key)` and 52 different `tevo_id` values
  legitimately point to the same `external_id`. Don't try to
  enforce UNIQUE on `(entity_kind, source_key, external_id)` for events.

---

## What NOT to do

1. **Don't write to `canonical_external_ids` or `performer_external_ids`
   directly** from any new function/cron/Edge Function. Only the
   `trg_sync_*` triggers should. If you need to add a new external link,
   write to the per-source xref table (or to PEI for athlete-style
   performers) — the trigger fans out.

2. **Don't add `seatgeek` as a `data_sources.source_key`.** Phase 3 normalized
   the broker source to `sg_broker` for FK consistency. Adding `seatgeek`
   would split the registry.

3. **Don't `TRUNCATE` an xref table without checking the resync trigger
   fires** — the `*_truncate_resync` triggers from Phase 7 rebuild the
   canonical slice, but only if they survive (e.g., `DROP TABLE … CASCADE`
   would drop them).

4. **Don't add comma-splitting to performer name parsing** without a
   whitelist for `Earth, Wind & Fire`-style legitimate performer names.

5. **Don't try to backfill the 185 historic 2018-2020 SG events.** Tevo
   won't have them. They will stay `tevo_event_id IS NULL` forever, and
   that's correct.

6. **Don't drop the `pei_reverse_uniq` index** — that's the constraint
   that prevents two different Tevo performers from claiming the same
   ESPN/SG/wiki external id within a league.

---

## Where new work should plug in

### Adding a new source (e.g., StubHub)
1. Add to `data_sources` first: `INSERT INTO data_sources (source_key, …)`.
2. Create `stubhub_event_xref`, `stubhub_venue_xref`, `stubhub_performer_xref`
   keyed on `tevo_*_id`.
3. Add UNIQUE on the reverse direction of each (Phase 9 pattern).
4. Add 3 trigger functions following the `trg_sync_cei__*` pattern in
   Phase 4 (`event_xref` / `venue_xref` / `performer_xref` mirror to CEI/PEI).
5. Add 1 TRUNCATE resync trigger per table following the Phase 7 pattern.
6. Backfill via Phase 3-style `INSERT ... ON CONFLICT DO UPDATE`.
7. Update `v_canonical_coverage_v2` to include the new source column.
8. Update `audit_cross_source_health()` overlay_coverage to include it.

### Adding a new overlay (e.g., parking inventory per event)
1. New view following the Phase 5 pattern joining `v_event_base` to the
   new domain by venue / date / performer.
2. Add to `v_event_overlay_summary` (one EXISTS column + sum into
   `overlay_signal_count`).
3. Add to `audit_cross_source_health()` `overlay_coverage` jsonb section.

### Manual override for a noisy SG performer name
- Currently no override table. If you need one:
  ```sql
  CREATE TABLE sg_performer_manual_overrides (
    sg_performer_name text PRIMARY KEY,
    tevo_performer_id bigint NOT NULL,
    notes text,
    added_at timestamptz DEFAULT NOW()
  );
  ```
  Then have the matcher Edge Function check this table first, before
  calling Tevo search. Don't write directly to `seatgeek_performer_xref`
  from app code — go through `record_sg_performer_match()` so the
  triggers see the row.

---

## Edge Function: `match-sg-performers-to-tevo`

- **Auth:** `verify_jwt: true`. Cron-style invocation via `net.http_post`
  with the project's anon key as Bearer token.
- **Env:** uses `TEVO_TOKEN` / `TEVO_SECRET` (with fallback to
  `TEVO_API_TOKEN` / `TEVO_API_SECRET` for the legacy `tevo-perf-find`).
- **Query params:**
  - `limit` (default 80, max 200)
  - `dry_run=true` — preview matches without writing
  - `min_confidence` (default 0.75) — `1.00 exact_lc`, `0.90 slug_eq`,
    `0.75 token_superset`, `0.40 popularity_top` (rejected by default)
- **Alias retry:** if the primary candidate name returns no high-confidence
  hit, the function retries each name in the `aliases` array from
  `v_sg_unmatched_candidate_performers`. Recorded in
  `seatgeek_performer_xref.match_method` as `tevo_search:alias:exact_lc` etc.
- **Calls** `record_sg_performer_match()` RPC — the Phase 4 triggers do
  the rest of the cascade.

---

## Open follow-ups (not in PR #51)

1. Closure of the **34,705 SG listings + 1,422 sales + 400 orders + 713
   seller listings** still without `tevo_event_id`. Those are referenced by
   the 185 historic + 32 upcoming-but-unscheduled-in-Tevo SG events;
   they will close as Tevo's catalog catches up to upcoming dates. The
   historic ones will never close — consider archiving them to a
   `_historic_orphans` table after, say, 90 days post-event-date.
2. **Comma-separated co-headliners** (Phase 10's noisy parses) — if it's
   worth recovering, build a small `concert_headliner_aliases` table.
3. **Diacritics** — the SG ingest pipeline drops UTF-8 modifiers
   (`RÜFÜS DU SOL` → `REFES DU SOL`). Check
   `seatgeek_listings_snapshots.raw->>'event_name'` for the actual
   bytes; the canonical view truncates them. Worth fixing at
   the ingest layer (one-line `SET CLIENT_ENCODING = 'UTF8'` somewhere?).
4. **Phase 11 dry-run mode** is implemented for `auto_match_sg_canonical_relaxed`,
   but no cron schedules it. If you want continuous backfill as Tevo's
   catalog walks forward, add a 30-min cron:
   ```sql
   SELECT cron.schedule('sg_relaxed_match_30min',
     '*/30 * * * *',
     $$ SELECT auto_match_sg_canonical_relaxed(0.5, false); $$);
   ```

---

## Quick troubleshooting

| Symptom | Check | Likely cause |
|---|---|---|
| `audit_cross_source_health()` shows non-zero drift | `SELECT * FROM v_canonical_drift LIMIT 20;` | A new write path bypassed the triggers. Look for `INSERT INTO canonical_external_ids` outside `trg_sync_*` functions. |
| `v_one_to_one_health` shows violations | `SELECT * FROM v_one_to_one_health;` | A cron / matcher created two Tevo entities mapping to the same external id. Check `crawl-venues-and-performers` and the Phase-8 / Phase-11 matchers. |
| New SG event arrives but never gets `tevo_event_id` | `SELECT * FROM v_sg_event_match_proposals WHERE sg_event_id = X;` | Either Tevo doesn't have an event at that venue/date yet, or venue name doesn't match. Check `seatgeek_venue_xref` first. |
| New SG performer not flowing into `canonical_external_ids` | `SELECT * FROM seatgeek_performer_xref WHERE sg_performer_name ILIKE 'X%';` | If row is there but not in CEI, the trigger fired but PEI write failed (FK to data_sources?). Check Postgres logs. |

---

## Files added in PR #51

```
supabase/migrations/20260510120000_phase1_backfill_event_xrefs.sql
supabase/migrations/20260510120100_phase2_backfill_performer_external_ids.sql
supabase/migrations/20260510120200_phase3_backfill_canonical_external_ids.sql
supabase/migrations/20260510120300_phase4_drift_prevention_triggers.sql
supabase/migrations/20260510120400_phase5_date_venue_overlay_views.sql
supabase/migrations/20260510120500_phase6_audit_views_and_rpc.sql
supabase/migrations/20260510130000_phase7_drift_hardening_and_extra_overlays.sql
supabase/migrations/20260510140000_phase8_sg_candidate_performer_view.sql
supabase/migrations/20260510150000_phase9_one_to_one_constraints.sql
supabase/migrations/20260510160000_phase10_candidate_normalization.sql
supabase/migrations/20260510170000_phase11_sg_event_matcher_by_venue_date.sql
supabase/functions/match-sg-performers-to-tevo/index.ts
docs/canonical-mapping-notes-2026-05-10.md     ← this file
```

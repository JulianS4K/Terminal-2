# C1 Ownership Takeover — 2026-05-14

Operator directive 2026-05-14: "assume ownership of C1 till we're done."

A1 audited the 3 outstanding C1 items (rows 105, 108, 112) and resolved each. No
code changes needed for 3 of them; the 4th (row 112 part 2) is deferred.

## Row 105 — `idx_performer_zone_rules_perf_venue` ack request

**A1 status**: ALREADY DONE. A1's earlier diagnosis (during D2 cron-health plan
review at row 104) pointed at the wrong table.

The `match_performer_zone()` SQL function joins:
- `performer_zones (performer_id, venue_id) → zone_id`
- `performer_zone_rules (zone_id) → section_from/to, row_from/to`

The (performer_id, venue_id) join path is on `performer_zones`, NOT
`performer_zone_rules`. And `performer_zones` already has
`idx_perf_zones_pv ON (performer_id, venue_id)` (3,553-row table, instant
build). So no index is needed.

The `midnight-catchup-sweep` (jobid 36) timeout fix from row 104 step 3c —
`SET LOCAL statement_timeout = '5min'` — remains as the appropriate
band-aid. Real perf bottleneck (if any) is per-listing iteration cost, not
a missing index.

**Closed.**

## Row 108 — FK plan completeness reply

**A1 status**: PR #99 shipped 56 cross-source FKs across the 7 anchors C1's
parked plan was likely targeting:
- events(id): +19
- sg_events_canonical(sg_event_id): +11
- venue_assets(tevo_venue_id): +9
- espn_teams_canonical(espn_team_id, espn_league) composite: +8
- performer_metadata(performer_id): +7
- macro_series_config(series_id): +1
- espn_athletes(espn_athlete_id): +1

If C1's parked plan included additional anchors not in A1's scope, A1 can
ship a round-2 migration on slot `20260514200000`. Pending C1 input;
otherwise considered complete.

**Closed.**

## Row 112 part 1 — `auto_match_sg_canonical_relaxed` wire-up

**A1 status**: Function works correctly; data has no real overlap.

**Probe**:
- 232 SG canonical events total
- 11 already matched (4.7%)
- 185 marked `match_status='ignored_historic'` (intentional skip)
- 36 are eligible (`pending`, non-null date, non-skip status)

**Test run** of `auto_match_sg_canonical_relaxed(0.5, false)`:
- Attempted 221, unique_matches=0, overlap_matches=0, unmatched=221

**Why**: `v_sg_event_match_proposals` is EMPTY (0 rows). The view's filter
finds NO SG-event candidates with any TEvo-event venue overlap on the
same date.

**Spot-check of 8 SG-vs-TEvo pairs on same date** (no `tevo_event_id` set):

| SG venue | TEvo venue | Same event? |
|---|---|---|
| Intuit Dome | CareFirst Arena | NO |
| The Greek Theatre - LA | CareFirst Arena | NO |
| Citi Field | Hard Rock Stadium | NO |
| American Family Field | Madison Square Garden | NO |
| Kia Forum | Rogers Centre | NO |
| Crypto.com Arena | Madison Square Garden | NO |
| Kia Forum | Target Field | NO |
| Chase Field | Sphere | NO |

These are entirely different events at entirely different venues on the
same dates — coincidental date overlap, not matchable pairs.

**Conclusion**: the 4.7% match coverage is **data reality**, not a
matcher bug. SG tracks events TEvo doesn't have brokers for (concerts,
parking-only listings, MLB venues we aren't selling). No automated
matching can recover these — they'd require operator-curated mappings or
expanding TEvo's broker network.

A1 did NOT wire the relaxed matcher as a cron — wiring it would burn
worker slots running an empty matcher every 30 min. **Closed as
not-actionable.**

## Row 112 part 2 — `events.occurs_at_local` TEXT → timestamptz

**A1 status**: deferred to audit phase 2.

The column holds valid ISO 8601 with offset; all 3,539 rows cast cleanly
to `timestamptz`. **But** there are **32 dependent views** on this
column, and Postgres refuses `ALTER COLUMN ... TYPE timestamptz` without
DROPping them first.

A single migration would have to:
1. DROP all 32 views CASCADE
2. ALTER TABLE
3. CREATE all 32 views (in correct dep order)

That's a high-risk omnibus that should be authored as its own staged
migration with full view-text capture + post-apply smoke. Per operator
directive "code in audit phase 2", deferring.

Workaround for now: callers cast explicitly (e.g.
`e.occurs_at_local::timestamptz`). Phase 15b's `v_team_schedule_30d`
already does this.

**Deferred.**

---

Owner: A1 (acting C1 during this takeover). Reverts to C1 when operator
gives the all-clear.

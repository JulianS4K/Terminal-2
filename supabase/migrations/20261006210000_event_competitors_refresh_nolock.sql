-- Migration 20261006210000 · level:data-collection · lane:A1 (operator-routed to D0, "fix the competitors refresh job so it doesn't recur") · writes:refresh_event_competitors(),event_competitors_snapshot · reads:venue_assets,events · pre:20260509350000,20260518020000
--
-- ============================================================================
-- Migration 20261006210000 — refresh_event_competitors without the table lock
--
-- Lane:     A1 data plane (cron 232 event_competitors_refresh_hourly), operator-
--           routed 2026-10-06 after it took the Supabase API down.
-- Touches:  refresh_event_competitors() (W, replaced) → event_competitors_snapshot
--           (W: row upserts instead of TRUNCATE). No DDL, no cron change.
-- Pre-reqs: 20260509350000 (snapshot table + v_competing_events),
--           20260518020000 (cron 232, :40 hourly)
--
-- Already applied to prod · via MCP 2026-10-06 19:25 UTC under operator
-- direction ("fix the competitors refresh job so it doesn't recur" → apply now).
--
-- INCIDENT 2026-10-06 18:41–18:55 UTC (Bad Gateway on /terminal/):
--   refresh_event_competitors() did TRUNCATE event_competitors_snapshot, then
--   INSERT … FROM v_competing_events in the same transaction. TRUNCATE holds an
--   ACCESS EXCLUSIVE lock until commit, and the INSERT never finished: every
--   run since 2026-09-15 was killed at 15 min ("failed" in job_run_details —
--   last good refreshed_at 2026-09-15 18:40). So for 15 min of every hour the
--   table was unreadable. PostgREST restarted at 18:41:25 inside that window;
--   its schema-cache query opens every exposed relation, waited on the lock past
--   the authenticator's 8 s statement_timeout, and every API call returned 503
--   PGRST002 until the run died at 18:55 and released the lock. (The 17:52–17:58
--   pickups 502s were the same lock — 8 s waits on the 17:40 run.)
--
-- WHY IT NEVER FINISHED:
--   * v_venue_neighbors cross-joins venue_assets (6,162 geocoded venues → 38M
--     pairs) through haversine_miles(), a plpgsql function: 17.5 s even with a
--     bounding box; unbounded, it dominates.
--   * v_competing_events then self-joins ALL events (142k, past included) on
--     occurs_at_local::timestamptz — occurs_at_local is text, so the ±24 h test
--     can't use an index.
--   Measured on prod 2026-10-06 (temp tables only): neighbors with a lat/lon box
--   + inline float haversine 0.9 s (241,562 pairs ≤ 20 mi); upcoming events
--   (local day ≥ today−2) 114,667; competing pairs ±24 h 3,869,704 over 94,840
--   events, built in 33 s.
--
-- CHANGE
--   1. Never lock readers out: no TRUNCATE. Upsert changed rows only
--      (IS DISTINCT FROM, so an hourly run rewrites just what moved) and zero
--      rows whose event left scope / has no competitor (count 0, [] — readers
--      already default a missing row to exactly that). Readers keep seeing the
--      previous snapshot until commit; only row locks are taken.
--   2. lock_timeout 5 s on the function: if anything ever does hold the table,
--      the refresh fails fast instead of queueing behind/ahead of readers.
--   3. Same rule as v_competing_events (other venue ≤ 20 mi, start within
--      ±24 h, not the same event), computed in temp tables:
--        - neighbors via a ±0.3° lat / ±0.6° lon box (≥ 20 mi everywhere below
--          ~60° N) then the haversine inline in float8;
--        - events scoped to upcoming (local day ≥ today − 2) — past events have
--          no use for a "competing tonight" list;
--        - candidate pairs joined on (venue_id, local day ±1), then the exact
--          ±24 h test on the parsed timestamps.
--   4. competitors keeps the same JSON shape and order (distance, |hours|) but
--      is capped at the 10 nearest; competitors_count stays the full count.
--      Unbounded lists (hundreds per NYC event) would make the table ~1 GB for
--      a panel that shows a handful.
--   v_competing_events / v_venue_neighbors are left as they are (read by
--   v_event_competing_events); this function no longer reads them.
--
-- NOTE: refreshed_at now moves only when a row's content changes. Coverage
--   grows from 7,719 events (2026-09-15) to ~95k upcoming. compute_alerts_tick
--   ('competing_event_added', count ≥ 5) reads every row; it has no active cron
--   today — scope it before re-enabling or it will fire for most of the book.
--
-- rollback: re-apply refresh_event_competitors() from 20260509350000.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.refresh_event_competitors()
RETURNS integer
LANGUAGE plpgsql
SET search_path TO 'public', 'pg_temp'
SET lock_timeout TO '5s'
AS $function$
DECLARE
  v_from text := to_char((now() AT TIME ZONE 'America/New_York')::date - 2, 'YYYY-MM-DD');
  v_rows int;
BEGIN
  -- Temp tables are ON COMMIT DROP (one call per transaction, as cron 232 does).
  -- Geocoded venues.
  CREATE TEMP TABLE _ec_va ON COMMIT DROP AS
    SELECT tevo_venue_id AS id, latitude::float8 AS lat, longitude::float8 AS lon
    FROM venue_assets
    WHERE latitude IS NOT NULL AND longitude IS NOT NULL;
  CREATE INDEX ON _ec_va (lat);
  ANALYZE _ec_va;

  -- Venue pairs within 20 mi (box first, then great-circle distance).
  CREATE TEMP TABLE _ec_nb ON COMMIT DROP AS
    SELECT venue_id, nv, dist FROM (
      SELECT a.id AS venue_id, b.id AS nv,
             round((3959 * 2 * asin(sqrt(
               sin(radians(b.lat - a.lat) / 2) ^ 2
               + cos(radians(a.lat)) * cos(radians(b.lat)) * sin(radians(b.lon - a.lon) / 2) ^ 2
             )))::numeric, 2) AS dist
      FROM _ec_va a
      JOIN _ec_va b
        ON b.lat BETWEEN a.lat - 0.3 AND a.lat + 0.3
       AND b.lon BETWEEN a.lon - 0.6 AND a.lon + 0.6
       AND a.id <> b.id
    ) z
    WHERE dist <= 20;
  CREATE INDEX ON _ec_nb (venue_id);
  ANALYZE _ec_nb;

  -- Upcoming events (occurs_at_local is text: 'YYYY-MM-DDTHH:MI:SS±HH:MM').
  CREATE TEMP TABLE _ec_ev ON COMMIT DROP AS
    SELECT id, venue_id, occurs_at_local::timestamptz AS ts, left(occurs_at_local, 10)::date AS d
    FROM events
    WHERE left(occurs_at_local, 10) >= v_from
      AND left(occurs_at_local, 10) ~ '^\d{4}-\d{2}-\d{2}$'
      AND venue_id IS NOT NULL;
  CREATE INDEX ON _ec_ev (venue_id, d);
  ANALYZE _ec_ev;

  -- Competing pairs → full count + 10 nearest per event.
  CREATE TEMP TABLE _ec_new ON COMMIT DROP AS
    WITH pairs AS (
      SELECT e.id AS eid, c.id AS cid, n.dist,
             round((extract(epoch FROM c.ts - e.ts) / 3600)::numeric, 1) AS hrs
      FROM _ec_ev e
      JOIN _ec_nb n ON n.venue_id = e.venue_id
      JOIN _ec_ev c ON c.venue_id = n.nv
                   AND c.d BETWEEN e.d - 1 AND e.d + 1
                   AND c.id <> e.id
                   AND abs(extract(epoch FROM c.ts - e.ts)) <= 86400
    ),
    ranked AS (
      SELECT eid, cid, dist, hrs,
             row_number() OVER (PARTITION BY eid ORDER BY dist, abs(hrs), cid) AS rn,
             count(*)     OVER (PARTITION BY eid) AS n
      FROM pairs
    )
    SELECT r.eid AS tevo_event_id,
           max(r.n)::int AS competitors_count,
           jsonb_agg(jsonb_build_object(
             'tevo_event_id', r.cid,
             'name',          c.name,
             'venue_name',    c.venue_name,
             'distance_mi',   round(r.dist, 1),
             'hours_offset',  r.hrs
           ) ORDER BY r.rn) AS competitors
    FROM ranked r
    JOIN events c ON c.id = r.cid
    WHERE r.rn <= 10
    GROUP BY r.eid;
  CREATE UNIQUE INDEX ON _ec_new (tevo_event_id);
  ANALYZE _ec_new;

  -- Events that left scope (past, or no competitor any more) are zeroed, not
  -- deleted: readers treat count 0 / [] exactly like a missing row.
  UPDATE event_competitors_snapshot s
     SET competitors_count = 0, competitors = '[]'::jsonb, refreshed_at = now()
   WHERE s.competitors_count <> 0
     AND NOT EXISTS (SELECT 1 FROM _ec_new n WHERE n.tevo_event_id = s.tevo_event_id);

  INSERT INTO event_competitors_snapshot AS s (tevo_event_id, competitors_count, competitors, refreshed_at)
  SELECT tevo_event_id, competitors_count, competitors, now()
  FROM _ec_new
  ON CONFLICT (tevo_event_id) DO UPDATE
    SET competitors_count = EXCLUDED.competitors_count,
        competitors       = EXCLUDED.competitors,
        refreshed_at      = EXCLUDED.refreshed_at
    WHERE s.competitors_count IS DISTINCT FROM EXCLUDED.competitors_count
       OR s.competitors       IS DISTINCT FROM EXCLUDED.competitors;

  SELECT count(*) INTO v_rows FROM _ec_new;
  RETURN v_rows;
END;
$function$;

COMMENT ON FUNCTION public.refresh_event_competitors() IS
  'Rebuild event_competitors_snapshot for upcoming events: other venues ≤ 20 mi, start within ±24 h. Row upserts only (no TRUNCATE — the old lock took PostgREST down 2026-10-06), lock_timeout 5 s, competitors capped at 10 nearest, competitors_count = full count. Returns events with ≥ 1 competitor. Mig 20261006210000.';

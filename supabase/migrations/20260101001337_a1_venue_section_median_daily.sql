-- ============================================================================
-- Migration 20260705153500 — venue-anchored daily section medians (+performer/away-team dims)
--
-- Lane:     A1 (data plane) + D0 read surface (RPC)
-- Touches:  venue_section_price_daily (NEW, W), venue_section_rollup_state (NEW, W),
--           venue_section_performer_agg / venue_section_opponent_agg (NEW, W — read-layer aggs),
--           rollup_venue_section_price_daily() / venue_section_rollup_catchup() /
--           refresh_venue_section_aggs() / get_venue_section_medians() (NEW fns),
--           v_venue_section_medians_by_performer / v_venue_section_medians_by_opponent (NEW views),
--           cron.job (schedule venue_section_rollup_hourly), cron_policy (W),
--           section_metrics (R), events (R), venue_section_map (R), performer_metadata (R)
-- Pre-reqs: 20260705153000 (retention engine — section_metrics 60d policy assumes this rollup,
--           and its §0 idx_section_metrics_captured serves this fn's day-window scans),
--           20260608120000 (venue_section_map), performer_metadata populated
--
-- WHY (operator-directed 2026-07-05): raw listing/section data ages out on the
-- retention ladder (section_metrics 60d), destroying the ability to compare how a
-- VENUE'S sections price across events long-term. This table keeps ONE row per
-- (event, venue-section, day) — the day's last section_metrics capture — INDEFINITELY,
-- keyed to the venue (venue_id + canonical section token from venue_section_map;
-- sections are venue facts, not free-floating strings), and denormalized with the
-- event's performer (home team / headliner) and derived AWAY TEAM so section medians
-- can be sliced "across away team and performer" without re-joining aged-out raws.
--
-- Away-team derivation (validated 12/12 on live rows, 2026-07-05):
--   1. parse the TEvo "X at Y" name → away name → exact match on performer_metadata
--      (popularity-ranked on name collisions);
--   2. else, for 2-performer games, the non-primary performer_ids element;
--   3. else NULL (concerts/TBD — performer dim still populated from primary).
--
-- Volume: ~one row per active event × section × day (tens of k/day; narrow row).
-- Retention: INDEFINITE by design — do NOT add a retention_policy row.
-- NOTE (one-time apply race, accepted): section_metrics currently holds ~64d
-- (sweeps dead since 07-01) vs the 60d policy re-armed by 20260705153000. The
-- >60d tail may be TTL'd before the oldest-first catchup reaches it — that tail
-- was already outside the operator-set window and only survived because the
-- sweeps died; steady-state has rollup sealing days ~59 days before deletion.
-- ============================================================================

-- ── 1. The daily table ───────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS public.venue_section_price_daily (
  event_id             bigint      NOT NULL,     -- TEvo event id
  section_key          text        NOT NULL,     -- canonical venue-section token (venue_section_map.section_token_base, else normalized raw)
  snapshot_date        date        NOT NULL,     -- UTC day of the source capture
  venue_id             bigint      NOT NULL,     -- TEvo venue id (sections are venue-anchored)
  section_raw          text,                     -- as seen in section_metrics
  seatmap_key          text,                     -- canonical seatmap section name when mapped
  zone                 text,
  event_date           date,
  days_to_event        integer,                  -- event_date - snapshot_date
  event_type           text,
  performer_id         bigint,                   -- home team / headliner (events.primary_performer_id)
  performer_name       text,
  opponent_performer_id bigint,                  -- derived away team (NULL for non-games)
  opponent_name        text,
  tickets_count        integer,
  groups_count         integer,
  getin_price          numeric,
  retail_p25           numeric,
  retail_median        numeric,
  retail_p75           numeric,
  owned_tickets_count  integer,
  owned_median_retail  numeric,
  captured_at          timestamptz,              -- source section_metrics capture
  created_at           timestamptz NOT NULL DEFAULT now(),
  updated_at           timestamptz NOT NULL DEFAULT now(),
  meta                 jsonb,
  PRIMARY KEY (event_id, section_key, snapshot_date)
);

CREATE INDEX IF NOT EXISTS idx_vspd_venue_section_date
  ON public.venue_section_price_daily (venue_id, section_key, snapshot_date DESC);
CREATE INDEX IF NOT EXISTS idx_vspd_performer
  ON public.venue_section_price_daily (performer_id, venue_id, section_key);
CREATE INDEX IF NOT EXISTS idx_vspd_opponent
  ON public.venue_section_price_daily (opponent_performer_id, venue_id, section_key)
  WHERE opponent_performer_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_vspd_snapshot_date
  ON public.venue_section_price_daily (snapshot_date);

REVOKE ALL ON TABLE public.venue_section_price_daily FROM anon, authenticated;
ALTER TABLE public.venue_section_price_daily ENABLE ROW LEVEL SECURITY;
DO $p$ BEGIN
  CREATE POLICY "service_role_all" ON public.venue_section_price_daily
    TO service_role USING (true) WITH CHECK (true);
EXCEPTION WHEN duplicate_object THEN NULL; END $p$;

COMMENT ON TABLE public.venue_section_price_daily IS
  'One row per (event, venue-section, UTC day) = the day''s LAST section_metrics capture. '
  'Venue-anchored (venue_id + venue_section_map token) with performer + derived away-team '
  'dims for cross-event section-median analysis. INDEFINITE retention (survives the '
  'section_metrics 60d TTL). Writer: rollup_venue_section_price_daily(). Mig 20260705153500.';

-- ── 2. Per-day rollup state (drives catchup; marks 0-row days as done) ──────

CREATE TABLE IF NOT EXISTS public.venue_section_rollup_state (
  snapshot_date date PRIMARY KEY,
  source_rows   bigint      NOT NULL DEFAULT 0,
  rows_upserted bigint      NOT NULL DEFAULT 0,
  processed_at  timestamptz NOT NULL DEFAULT now()
);
REVOKE ALL ON TABLE public.venue_section_rollup_state FROM anon, authenticated;
ALTER TABLE public.venue_section_rollup_state ENABLE ROW LEVEL SECURITY;
DO $p$ BEGIN
  CREATE POLICY "service_role_all" ON public.venue_section_rollup_state
    TO service_role USING (true) WITH CHECK (true);
EXCEPTION WHEN duplicate_object THEN NULL; END $p$;

-- ── 3. One-day rollup ────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.rollup_venue_section_price_daily(
  p_date date DEFAULT (now() AT TIME ZONE 'utc')::date
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_from timestamptz := p_date::timestamptz;
  v_to   timestamptz := (p_date + 1)::timestamptz;
  v_src  bigint := 0;
  v_n    integer := 0;
BEGIN
  IF current_user NOT IN ('service_role','postgres','supabase_admin') THEN
    RAISE EXCEPTION 'forbidden: rollup_venue_section_price_daily is service-only' USING ERRCODE='42501';
  END IF;

  WITH src AS (
    -- day's LAST capture per (event, normalized section); parking/ancillary excluded
    SELECT DISTINCT ON (sm.event_id, lower(btrim(sm.section)))
           sm.event_id,
           lower(btrim(sm.section)) AS section_norm,
           sm.section               AS section_raw,
           sm.zone,
           sm.tickets_count, sm.groups_count,
           sm.getin_price, sm.retail_p25, sm.retail_median, sm.retail_p75,
           sm.owned_tickets_count, sm.owned_median_retail,
           sm.captured_at
    FROM public.section_metrics sm
    WHERE sm.captured_at >= v_from AND sm.captured_at < v_to
      AND COALESCE(sm.is_ancillary, false) = false
      AND sm.section IS NOT NULL AND btrim(sm.section) <> ''
    ORDER BY sm.event_id, lower(btrim(sm.section)), sm.captured_at DESC
  ),
  ev AS (
    SELECT e.id, e.venue_id, e.event_type,
           e.primary_performer_id, e.primary_performer_name,
           e.performer_ids,
           CASE WHEN e.occurs_at_local ~ '^\d{4}-\d{2}-\d{2}'
                THEN left(e.occurs_at_local, 10)::date END AS event_date,
           CASE WHEN e.event_type = 'game' AND e.name ~* ' at '
                THEN lower(btrim(regexp_replace(split_part(e.name, ' at ', 1), '^.*(?:-|:)\s*', '')))
           END AS away_name_parsed
    FROM public.events e
    WHERE e.venue_id IS NOT NULL
      AND e.id IN (SELECT DISTINCT event_id FROM src)
  ),
  evx AS (
    -- resolve away team: name-parse → performer_metadata (popularity-ranked), else 2-performer pair rule
    SELECT DISTINCT ON (ev.id)
           ev.*,
           COALESCE(
             pm.performer_id,
             CASE WHEN ev.event_type = 'game' AND array_length(ev.performer_ids, 1) = 2
                  THEN (SELECT x::bigint FROM unnest(ev.performer_ids) x
                        WHERE x::bigint <> ev.primary_performer_id LIMIT 1)
             END) AS opponent_performer_id,
           COALESCE(pm.name, ev.away_name_parsed) AS opponent_name
    FROM ev
    LEFT JOIN public.performer_metadata pm
           ON ev.away_name_parsed IS NOT NULL AND lower(pm.name) = ev.away_name_parsed
    ORDER BY ev.id, pm.popularity_score DESC NULLS LAST, pm.performer_id
  ),
  joined AS (
    SELECT s.*,
           x.venue_id, x.event_type, x.event_date,
           x.primary_performer_id, x.primary_performer_name,
           x.opponent_performer_id, x.opponent_name,
           COALESCE(NULLIF(vsm.section_token_base, ''), s.section_norm) AS section_key,
           vsm.seatmap_key
    FROM src s
    JOIN evx x ON x.id = s.event_id
    LEFT JOIN LATERAL (
      -- venue_section_map carries several rows per (venue, raw section) — take the best
      SELECT m.section_token_base, m.seatmap_key
      FROM public.venue_section_map m
      WHERE m.tevo_venue_id = x.venue_id
        AND m.platform = 'evo'
        AND m.section_raw = s.section_norm
      ORDER BY m.confidence DESC NULLS LAST, m.seen_listings DESC NULLS LAST
      LIMIT 1
    ) vsm ON true
  ),
  final AS (
    -- token normalization can collapse two raw sections into one key — keep latest capture
    SELECT DISTINCT ON (event_id, section_key) *
    FROM joined
    ORDER BY event_id, section_key, captured_at DESC
  )
  INSERT INTO public.venue_section_price_daily (
    event_id, section_key, snapshot_date, venue_id, section_raw, seatmap_key, zone,
    event_date, days_to_event, event_type,
    performer_id, performer_name, opponent_performer_id, opponent_name,
    tickets_count, groups_count, getin_price, retail_p25, retail_median, retail_p75,
    owned_tickets_count, owned_median_retail, captured_at
  )
  SELECT f.event_id, f.section_key, p_date, f.venue_id, f.section_raw, f.seatmap_key, f.zone,
         f.event_date, (f.event_date - p_date), f.event_type,
         f.primary_performer_id, f.primary_performer_name, f.opponent_performer_id, f.opponent_name,
         f.tickets_count, f.groups_count, f.getin_price, f.retail_p25, f.retail_median, f.retail_p75,
         f.owned_tickets_count, f.owned_median_retail, f.captured_at
  FROM final f
  ON CONFLICT (event_id, section_key, snapshot_date) DO UPDATE SET
    venue_id             = EXCLUDED.venue_id,
    section_raw          = EXCLUDED.section_raw,
    seatmap_key          = EXCLUDED.seatmap_key,
    zone                 = EXCLUDED.zone,
    event_date           = EXCLUDED.event_date,
    days_to_event        = EXCLUDED.days_to_event,
    event_type           = EXCLUDED.event_type,
    performer_id         = EXCLUDED.performer_id,
    performer_name       = EXCLUDED.performer_name,
    opponent_performer_id = EXCLUDED.opponent_performer_id,
    opponent_name        = EXCLUDED.opponent_name,
    tickets_count        = EXCLUDED.tickets_count,
    groups_count         = EXCLUDED.groups_count,
    getin_price          = EXCLUDED.getin_price,
    retail_p25           = EXCLUDED.retail_p25,
    retail_median        = EXCLUDED.retail_median,
    retail_p75           = EXCLUDED.retail_p75,
    owned_tickets_count  = EXCLUDED.owned_tickets_count,
    owned_median_retail  = EXCLUDED.owned_median_retail,
    captured_at          = EXCLUDED.captured_at,
    updated_at           = now();

  GET DIAGNOSTICS v_n = ROW_COUNT;

  SELECT count(*) INTO v_src FROM public.section_metrics sm
   WHERE sm.captured_at >= v_from AND sm.captured_at < v_to;

  INSERT INTO public.venue_section_rollup_state (snapshot_date, source_rows, rows_upserted, processed_at)
  VALUES (p_date, v_src, v_n, now())
  ON CONFLICT (snapshot_date) DO UPDATE
    SET source_rows = EXCLUDED.source_rows,
        rows_upserted = EXCLUDED.rows_upserted,
        processed_at = now();

  RETURN v_n;
END $function$;

REVOKE ALL ON FUNCTION public.rollup_venue_section_price_daily(date) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rollup_venue_section_price_daily(date) TO service_role;
COMMENT ON FUNCTION public.rollup_venue_section_price_daily(date) IS
  'Upserts venue_section_price_daily for one UTC day from section_metrics (day''s last capture '
  'per event×section, ancillary excluded), venue-anchored via venue_section_map(platform=evo), '
  'away team via name-parse→performer_metadata else 2-performer pair rule. Idempotent. '
  'Mig 20260705153500.';

-- ── 4. Catchup driver (today first, then unsealed/missing days; budget-bounded) ──

CREATE OR REPLACE FUNCTION public.venue_section_rollup_catchup(
  p_max_days       integer DEFAULT 3,
  p_budget_seconds integer DEFAULT 240
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_start timestamptz := clock_timestamp();
  v_today date := (now() AT TIME ZONE 'utc')::date;
  v_done  integer := 0;
  v_d     date;
BEGIN
  IF current_user NOT IN ('service_role','postgres','supabase_admin') THEN
    RAISE EXCEPTION 'forbidden: venue_section_rollup_catchup is service-only' USING ERRCODE='42501';
  END IF;

  FOR v_d IN
    SELECT d FROM (
      SELECT v_today AS d, 0 AS ord                      -- always refresh today
      UNION ALL
      SELECT gs::date, 1
      FROM generate_series(v_today - 70, v_today - 1, interval '1 day') gs
      LEFT JOIN public.venue_section_rollup_state st ON st.snapshot_date = gs::date
      WHERE st.snapshot_date IS NULL                      -- never processed
         OR st.processed_at < st.snapshot_date + interval '1 day'  -- processed mid-day, not sealed
    ) cand
    ORDER BY ord, d
    LIMIT p_max_days
  LOOP
    EXIT WHEN clock_timestamp() - v_start > make_interval(secs => p_budget_seconds);
    PERFORM public.rollup_venue_section_price_daily(v_d);
    v_done := v_done + 1;
  END LOOP;

  -- Refresh the read-layer aggregates whenever the substrate moved.
  IF v_done > 0 THEN
    PERFORM public.refresh_venue_section_aggs();
  END IF;

  RETURN v_done;
END $function$;

REVOKE ALL ON FUNCTION public.venue_section_rollup_catchup(integer, integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.venue_section_rollup_catchup(integer, integer) TO service_role;
COMMENT ON FUNCTION public.venue_section_rollup_catchup(integer, integer) IS
  'Drives rollup_venue_section_price_daily: refreshes today every fire, back-fills missing/'
  'unsealed days from the trailing 70d window (bounded by p_max_days + wall-clock budget). '
  'Backlog self-drains over ~1-2 days of hourly fires, then it''s today+yesterday only. '
  'Mig 20260705153500.';

-- ── 5. Aggregate rollups — the READ layer (per away team / per performer) ────
-- The daily table stays the source of truth (exact medians, re-slicing,
-- corrections); these small aggregates are what dashboards/RPCs read.
-- performer_kind splits venues with sports teams: 'team' (home team; opponent
-- slices live in the opponent agg) vs 'other' (concert/show headliners).

CREATE TABLE IF NOT EXISTS public.venue_section_performer_agg (
  venue_id          bigint  NOT NULL,
  performer_id      bigint  NOT NULL,
  section_key       text    NOT NULL,
  performer_kind    text    NOT NULL DEFAULT 'other' CHECK (performer_kind IN ('team','other')),
  performer_name    text,
  seatmap_key       text,
  events_seen       integer NOT NULL DEFAULT 0,
  day_samples       integer NOT NULL DEFAULT 0,
  median_price      numeric,   -- percentile_cont(.5) over each event's LATEST daily median
  median_price_365d numeric,   -- same, events last seen within 365d
  min_getin         numeric,
  first_seen        date,
  last_seen         date,
  refreshed_at      timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (venue_id, performer_id, section_key)
);
CREATE INDEX IF NOT EXISTS idx_vspa_venue_kind
  ON public.venue_section_performer_agg (venue_id, performer_kind, performer_id);

CREATE TABLE IF NOT EXISTS public.venue_section_opponent_agg (
  venue_id              bigint  NOT NULL,
  performer_id          bigint  NOT NULL,   -- home team the opponent visited
  opponent_performer_id bigint  NOT NULL,
  section_key           text    NOT NULL,
  performer_name        text,
  opponent_name         text,
  seatmap_key           text,
  events_seen           integer NOT NULL DEFAULT 0,
  day_samples           integer NOT NULL DEFAULT 0,
  median_price          numeric,
  median_price_365d     numeric,
  min_getin             numeric,
  first_seen            date,
  last_seen             date,
  refreshed_at          timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (venue_id, performer_id, opponent_performer_id, section_key)
);
CREATE INDEX IF NOT EXISTS idx_vsoa_venue_section
  ON public.venue_section_opponent_agg (venue_id, section_key, median_price DESC);

REVOKE ALL ON TABLE public.venue_section_performer_agg FROM anon, authenticated;
REVOKE ALL ON TABLE public.venue_section_opponent_agg  FROM anon, authenticated;
ALTER TABLE public.venue_section_performer_agg ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.venue_section_opponent_agg  ENABLE ROW LEVEL SECURITY;
DO $p$ BEGIN
  CREATE POLICY "service_role_all" ON public.venue_section_performer_agg
    TO service_role USING (true) WITH CHECK (true);
EXCEPTION WHEN duplicate_object THEN NULL; END $p$;
DO $p$ BEGIN
  CREATE POLICY "service_role_all" ON public.venue_section_opponent_agg
    TO service_role USING (true) WITH CHECK (true);
EXCEPTION WHEN duplicate_object THEN NULL; END $p$;

COMMENT ON TABLE public.venue_section_performer_agg IS
  'Per (venue, performer, section) price aggregate — kind=team (home team) vs other '
  '(concerts/shows). Rebuilt by refresh_venue_section_aggs() after each daily rollup; '
  'medians computed EXACTLY from venue_section_price_daily (each event''s latest daily row). '
  'Read layer only — never a source of truth. Mig 20260705153500.';
COMMENT ON TABLE public.venue_section_opponent_agg IS
  'Per (venue, home team, AWAY TEAM, section) price aggregate for games. Same refresh/'
  'semantics as venue_section_performer_agg. Mig 20260705153500.';

CREATE OR REPLACE FUNCTION public.refresh_venue_section_aggs()
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_perf integer := 0;
  v_opp  integer := 0;
BEGIN
  IF current_user NOT IN ('service_role','postgres','supabase_admin') THEN
    RAISE EXCEPTION 'forbidden: refresh_venue_section_aggs is service-only' USING ERRCODE='42501';
  END IF;

  -- Full rebuild: the daily table is the truth, the aggs are disposable.
  -- (Scope to touched venues if this ever outgrows its budget.)
  -- Explicit DELETE before INSERT — a wipe inside a data-modifying CTE has
  -- unspecified execution order vs the main statement and can PK-collide.
  DELETE FROM public.venue_section_performer_agg;

  WITH reps AS (
    -- one representative row per (event, section) = the event's LATEST daily capture
    SELECT DISTINCT ON (event_id, section_key) *
    FROM public.venue_section_price_daily
    WHERE performer_id IS NOT NULL AND retail_median IS NOT NULL
    ORDER BY event_id, section_key, snapshot_date DESC
  ),
  days AS (
    SELECT venue_id, performer_id, section_key, count(*) AS day_samples
    FROM public.venue_section_price_daily
    WHERE performer_id IS NOT NULL AND retail_median IS NOT NULL
    GROUP BY 1,2,3
  ),
  agg AS (
    SELECT r.venue_id, r.performer_id, r.section_key,
           CASE WHEN bool_or(r.event_type = 'game') THEN 'team' ELSE 'other' END AS performer_kind,
           max(r.performer_name)  AS performer_name,
           max(r.seatmap_key)     AS seatmap_key,
           count(*)               AS events_seen,
           percentile_cont(0.5) WITHIN GROUP (ORDER BY r.retail_median) AS median_price,
           percentile_cont(0.5) WITHIN GROUP (ORDER BY r.retail_median)
             FILTER (WHERE r.snapshot_date >= current_date - 365)       AS median_price_365d,
           min(r.getin_price)     AS min_getin,
           min(r.snapshot_date)   AS first_seen,
           max(r.snapshot_date)   AS last_seen
    FROM reps r
    GROUP BY r.venue_id, r.performer_id, r.section_key
  )
  INSERT INTO public.venue_section_performer_agg
    (venue_id, performer_id, section_key, performer_kind, performer_name, seatmap_key,
     events_seen, day_samples, median_price, median_price_365d, min_getin,
     first_seen, last_seen, refreshed_at)
  SELECT a.venue_id, a.performer_id, a.section_key, a.performer_kind, a.performer_name, a.seatmap_key,
         a.events_seen, COALESCE(d.day_samples, 0), a.median_price, a.median_price_365d, a.min_getin,
         a.first_seen, a.last_seen, now()
  FROM agg a LEFT JOIN days d USING (venue_id, performer_id, section_key);
  GET DIAGNOSTICS v_perf = ROW_COUNT;

  DELETE FROM public.venue_section_opponent_agg;

  WITH reps AS (
    SELECT DISTINCT ON (event_id, section_key) *
    FROM public.venue_section_price_daily
    WHERE performer_id IS NOT NULL AND opponent_performer_id IS NOT NULL
      AND retail_median IS NOT NULL
    ORDER BY event_id, section_key, snapshot_date DESC
  ),
  days AS (
    SELECT venue_id, performer_id, opponent_performer_id, section_key, count(*) AS day_samples
    FROM public.venue_section_price_daily
    WHERE performer_id IS NOT NULL AND opponent_performer_id IS NOT NULL
      AND retail_median IS NOT NULL
    GROUP BY 1,2,3,4
  ),
  agg AS (
    SELECT r.venue_id, r.performer_id, r.opponent_performer_id, r.section_key,
           max(r.performer_name) AS performer_name,
           max(r.opponent_name)  AS opponent_name,
           max(r.seatmap_key)    AS seatmap_key,
           count(*)              AS events_seen,
           percentile_cont(0.5) WITHIN GROUP (ORDER BY r.retail_median) AS median_price,
           percentile_cont(0.5) WITHIN GROUP (ORDER BY r.retail_median)
             FILTER (WHERE r.snapshot_date >= current_date - 365)       AS median_price_365d,
           min(r.getin_price)    AS min_getin,
           min(r.snapshot_date)  AS first_seen,
           max(r.snapshot_date)  AS last_seen
    FROM reps r
    GROUP BY r.venue_id, r.performer_id, r.opponent_performer_id, r.section_key
  )
  INSERT INTO public.venue_section_opponent_agg
    (venue_id, performer_id, opponent_performer_id, section_key, performer_name, opponent_name,
     seatmap_key, events_seen, day_samples, median_price, median_price_365d, min_getin,
     first_seen, last_seen, refreshed_at)
  SELECT a.venue_id, a.performer_id, a.opponent_performer_id, a.section_key, a.performer_name,
         a.opponent_name, a.seatmap_key, a.events_seen, COALESCE(d.day_samples, 0),
         a.median_price, a.median_price_365d, a.min_getin, a.first_seen, a.last_seen, now()
  FROM agg a LEFT JOIN days d USING (venue_id, performer_id, opponent_performer_id, section_key);
  GET DIAGNOSTICS v_opp = ROW_COUNT;

  RETURN v_perf + v_opp;
END $function$;

REVOKE ALL ON FUNCTION public.refresh_venue_section_aggs() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.refresh_venue_section_aggs() TO service_role;
COMMENT ON FUNCTION public.refresh_venue_section_aggs() IS
  'Full rebuild of venue_section_{performer,opponent}_agg from venue_section_price_daily. '
  'Called by venue_section_rollup_catchup() after each rollup pass. Mig 20260705153500.';

-- ── 5b. Views (thin reads over the aggs — same names as the design docs) ─────

CREATE OR REPLACE VIEW public.v_venue_section_medians_by_performer
WITH (security_invoker = true) AS
SELECT venue_id, performer_id, performer_name, performer_kind, section_key, seatmap_key,
       events_seen, day_samples, median_price, median_price_365d, min_getin, first_seen, last_seen
FROM public.venue_section_performer_agg;

CREATE OR REPLACE VIEW public.v_venue_section_medians_by_opponent
WITH (security_invoker = true) AS
SELECT venue_id, performer_id AS home_performer_id, performer_name AS home_performer_name,
       opponent_performer_id, opponent_name, section_key, seatmap_key,
       events_seen, day_samples, median_price, median_price_365d, min_getin, first_seen, last_seen
FROM public.venue_section_opponent_agg;

REVOKE ALL ON public.v_venue_section_medians_by_performer  FROM anon, authenticated;
REVOKE ALL ON public.v_venue_section_medians_by_opponent   FROM anon, authenticated;
GRANT SELECT ON public.v_venue_section_medians_by_performer TO service_role;
GRANT SELECT ON public.v_venue_section_medians_by_opponent  TO service_role;
COMMENT ON VIEW public.v_venue_section_medians_by_performer IS
  'How each venue section prices across a performer''s events (kind=team vs other). '
  'Reads venue_section_performer_agg (exact medians, refreshed after each rollup).';
COMMENT ON VIEW public.v_venue_section_medians_by_opponent IS
  'How each venue section prices BY AWAY TEAM at a home venue. '
  'Reads venue_section_opponent_agg.';

-- ── 5c. Terminal RPC — venue page Sections panel ─────────────────────────────
-- Venues with sports teams get team blocks (with per-opponent slices) SEPARATE
-- from concert/other performers, per operator direction 2026-07-05.

CREATE OR REPLACE FUNCTION public.get_venue_section_medians(p_venue_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_email text;
  v_teams jsonb;
  v_others jsonb;
  v_refreshed timestamptz;
BEGIN
  v_email := coalesce(auth.jwt()->>'email', '');
  IF v_email NOT LIKE '%@s4kent.com'
     AND current_user NOT IN ('service_role','postgres','supabase_admin') THEN
    RAISE EXCEPTION 'forbidden: % is not @s4kent.com', v_email USING ERRCODE='42501';
  END IF;

  SELECT max(refreshed_at) INTO v_refreshed
  FROM public.venue_section_performer_agg WHERE venue_id = p_venue_id;

  -- Team blocks: sections ordered by median, each with its away-team slice.
  SELECT jsonb_agg(t ORDER BY t->>'performer_name')
  INTO v_teams
  FROM (
    SELECT jsonb_build_object(
      'performer_id', pa.performer_id,
      'performer_name', max(pa.performer_name),
      'sections', jsonb_agg(jsonb_build_object(
          'section_key', pa.section_key,
          'seatmap_key', pa.seatmap_key,
          'median_price', round(pa.median_price::numeric, 2),
          'median_price_365d', round(pa.median_price_365d::numeric, 2),
          'events_seen', pa.events_seen,
          'min_getin', pa.min_getin,
          'last_seen', pa.last_seen,
          'opponents', (
            SELECT jsonb_agg(jsonb_build_object(
                     'opponent_performer_id', oa.opponent_performer_id,
                     'opponent_name', oa.opponent_name,
                     'median_price', round(oa.median_price::numeric, 2),
                     'events_seen', oa.events_seen
                   ) ORDER BY oa.median_price DESC)
            FROM public.venue_section_opponent_agg oa
            WHERE oa.venue_id = pa.venue_id
              AND oa.performer_id = pa.performer_id
              AND oa.section_key = pa.section_key
          )
        ) ORDER BY pa.median_price DESC NULLS LAST)
    ) AS t
    FROM public.venue_section_performer_agg pa
    WHERE pa.venue_id = p_venue_id AND pa.performer_kind = 'team'
    GROUP BY pa.performer_id
  ) teams;

  -- Concert / other performers: separate list (operator note: never mixed with teams).
  SELECT jsonb_agg(o ORDER BY (o->>'events_total')::int DESC)
  INTO v_others
  FROM (
    SELECT jsonb_build_object(
      'performer_id', pa.performer_id,
      'performer_name', max(pa.performer_name),
      'events_total', max(pa.events_seen),
      'sections', jsonb_agg(jsonb_build_object(
          'section_key', pa.section_key,
          'seatmap_key', pa.seatmap_key,
          'median_price', round(pa.median_price::numeric, 2),
          'median_price_365d', round(pa.median_price_365d::numeric, 2),
          'events_seen', pa.events_seen,
          'min_getin', pa.min_getin,
          'last_seen', pa.last_seen
        ) ORDER BY pa.median_price DESC NULLS LAST)
    ) AS o
    FROM public.venue_section_performer_agg pa
    WHERE pa.venue_id = p_venue_id AND pa.performer_kind = 'other'
    GROUP BY pa.performer_id
  ) others;

  RETURN jsonb_build_object(
    'venue_id', p_venue_id,
    'teams',  COALESCE(v_teams,  '[]'::jsonb),
    'others', COALESCE(v_others, '[]'::jsonb),
    'refreshed_at', v_refreshed
  );
END $function$;

REVOKE ALL ON FUNCTION public.get_venue_section_medians(bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_venue_section_medians(bigint) TO authenticated, service_role;
COMMENT ON FUNCTION public.get_venue_section_medians(bigint) IS
  'D0 venue page SECTIONS panel. Email-gated @s4kent.com. Returns teams[] (home teams w/ '
  'per-section medians + away-team slices) SEPARATE from others[] (concert/show performers), '
  'reading venue_section_{performer,opponent}_agg. Mig 20260705153500.';

-- ── 6. Cron (hourly; today refresh + backlog drain in one path) ──────────────

SELECT cron.schedule(
  'venue_section_rollup_hourly',
  '52 * * * *',
  $cron$BEGIN; SET LOCAL statement_timeout='600s'; DO $b$ BEGIN
    IF NOT public.cron_should_fire('venue_section_rollup_hourly') THEN RETURN; END IF;
    PERFORM public.venue_section_rollup_catchup(3, 300);
  END $b$; COMMIT;$cron$
);

INSERT INTO public.cron_policy (jobname, peak_hours_et, peak_min_interval_min,
  offpeak_min_interval_min, daily_max_fires, work_check_sql, enabled, notes)
VALUES ('venue_section_rollup_hourly', ARRAY[]::int[], 60, 60, 24, 'SELECT true', true,
  'Venue-section daily median rollup (today refresh + ≤2 backfill days per fire, 300s budget). '
  'Feeds venue_section_price_daily (INDEFINITE retention) before section_metrics 60d TTL. Mig 20260705153500.')
ON CONFLICT (jobname) DO UPDATE
  SET enabled = true, notes = EXCLUDED.notes, updated_at = now();

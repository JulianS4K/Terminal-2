-- ============================================================================
-- Migration 20260705153500 — venue-anchored daily section medians (+performer/away-team dims)
--
-- Lane:     A1 (data plane)
-- Touches:  venue_section_price_daily (NEW, W), venue_section_rollup_state (NEW, W),
--           rollup_venue_section_price_daily() (NEW fn), venue_section_rollup_catchup() (NEW fn),
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

  RETURN v_done;
END $function$;

REVOKE ALL ON FUNCTION public.venue_section_rollup_catchup(integer, integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.venue_section_rollup_catchup(integer, integer) TO service_role;
COMMENT ON FUNCTION public.venue_section_rollup_catchup(integer, integer) IS
  'Drives rollup_venue_section_price_daily: refreshes today every fire, back-fills missing/'
  'unsealed days from the trailing 70d window (bounded by p_max_days + wall-clock budget). '
  'Backlog self-drains over ~1-2 days of hourly fires, then it''s today+yesterday only. '
  'Mig 20260705153500.';

-- ── 5. Analysis views (median-of-daily-medians across events) ────────────────

CREATE OR REPLACE VIEW public.v_venue_section_medians_by_performer
WITH (security_invoker = true) AS
SELECT performer_id, performer_name, venue_id, section_key,
       count(DISTINCT event_id)                                   AS events_seen,
       count(*)                                                   AS day_samples,
       percentile_cont(0.5) WITHIN GROUP (ORDER BY retail_median) AS median_retail_median,
       round(avg(retail_median), 2)                               AS avg_retail_median,
       min(getin_price)                                           AS min_getin,
       max(snapshot_date)                                         AS latest_snapshot_date
FROM public.venue_section_price_daily
WHERE performer_id IS NOT NULL AND retail_median IS NOT NULL
GROUP BY performer_id, performer_name, venue_id, section_key;

CREATE OR REPLACE VIEW public.v_venue_section_medians_by_opponent
WITH (security_invoker = true) AS
SELECT opponent_performer_id, opponent_name, venue_id, performer_id AS home_performer_id, section_key,
       count(DISTINCT event_id)                                   AS events_seen,
       count(*)                                                   AS day_samples,
       percentile_cont(0.5) WITHIN GROUP (ORDER BY retail_median) AS median_retail_median,
       round(avg(retail_median), 2)                               AS avg_retail_median,
       min(getin_price)                                           AS min_getin,
       max(snapshot_date)                                         AS latest_snapshot_date
FROM public.venue_section_price_daily
WHERE opponent_performer_id IS NOT NULL AND retail_median IS NOT NULL
GROUP BY opponent_performer_id, opponent_name, venue_id, performer_id, section_key;

REVOKE ALL ON public.v_venue_section_medians_by_performer  FROM anon, authenticated;
REVOKE ALL ON public.v_venue_section_medians_by_opponent   FROM anon, authenticated;
GRANT SELECT ON public.v_venue_section_medians_by_performer TO service_role;
GRANT SELECT ON public.v_venue_section_medians_by_opponent  TO service_role;
COMMENT ON VIEW public.v_venue_section_medians_by_performer IS
  'How each venue section prices across a performer''s (home team''s / headliner''s) events — '
  'median-of-daily-medians over venue_section_price_daily.';
COMMENT ON VIEW public.v_venue_section_medians_by_opponent IS
  'How each venue section prices BY AWAY TEAM at a home venue — median-of-daily-medians '
  'over venue_section_price_daily (games only).';

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

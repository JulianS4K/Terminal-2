-- Migration 20261027030432 · level:ops · lane:A1 (data plane — ML feature store) · writes:enrich_zone_price_observations()(replace),zone_metrics_captured_brin(new),zpo_build_state(new),zpo_daily_tick()(new),cron zone_price_observations_daily(replace) · reads:zone_metrics,zone_price_observations,events,venue_assets,nws_alerts,nws_alert_zones,axs_events,v_axs_listings,v_event_price_arbitrage,espn_news,espn_injuries_snapshots,espn_event_snapshots,event_xref,performer_espn_team_xref,athlete_wikipedia · pre:20260708170500 (enrich v1)
--
-- ============================================================================
-- Fix the zone_price_observations feature store (cron 482), dead since 2026-10-24
--
-- WHAT BROKE: the daily job ran fine for months on a few dozen events/day. When the
-- league pins went live (mig 20261023054000) zone_metrics jumped from ~0 to ~140 k rows
-- across ~4,500 events/day, and enrich_zone_price_observations() hit the 15-min cron
-- timeout every night (Oct 24 velocity step; Oct 25/26 primary-market step). The cron
-- runs build + enrich in ONE transaction, so each enrich timeout also rolled back that
-- day's build: zone_price_observations has 0 rows for Oct 23–26.
--
-- Measured on prod (rolled-back test blocks, 300 events of 2026-10-26):
--   build_zone_price_observations      35 ms/event → ~155 s/day         unchanged (fine)
--   velocity (lag() over WHOLE table)  > 58 s, timed out                → 0.19 s (index lateral)
--   primary vs secondary (view)        > 58 s, timed out                → ~1.2 s (scoped to the day)
--   weather alerts (view)              26.6 s                           → 2.1 s  (active alerts first)
--   home news buzz                     12.7 s, grows per event          → per team (once per team)
--   injuries                           23.2 s, re-counts per row        → per team aggregate
--   rivalry 0.2 s · weather 3.6 s · wiki 0.1 s · broadcast 5.1 s       unchanged / scoped
--
-- WHAT THIS CHANGES
--   enrich_zone_price_observations(date)  same signature, same columns, same meaning; every
--     step now starts from the day's event_ids instead of computing over all events and
--     filtering at the join. NULL date still means "all dates" (now loops per date).
--   zone_metrics_captured_brin             BRIN on captured_at so a day's rows are found by time.
--   zpo_build_state + zpo_daily_tick()     the runner. Builds a day event-by-event with a
--     resumable cursor and a wall-clock budget, THEN enriches it in its own exception
--     block — an enrichment failure is recorded in zpo_build_state.last_error and no
--     longer rolls back the build; the next run retries enrichment only. Each run walks the
--     last 14 days oldest-first (velocity reads the previous day): unbuilt days are built
--     (resuming from the cursor), yesterday is rebuilt once after it has ended, today is
--     built once a day, empty days are recorded once and skipped. Enrichment never starts in
--     the last 2 min of the budget (a statement timeout can't be caught and would roll the
--     run back).
--   cron zone_price_observations_daily     same name, now runs zpo_daily_tick(600) every
--     30 min 06:15–11:45 UTC (off-peak, 2–7 AM ET); budget per run 600 s. Ticks after the
--     day's work is done exit in milliseconds.
--   SECURITY: build_zone_price_observations(), build_zone_price_observations_day() and
--     enrich_zone_price_observations() are SECURITY DEFINER writers that were EXECUTE-able
--     by anon and authenticated (missed by 20261021163000_sec_revoke_anon_secdef_writers).
--     Revoked; service_role only. Only caller outside SQL: none (espn-collect only names it
--     in a comment and uses the service-role key anyway).
--
-- BACKFILL: Oct 23–26 are rebuilt automatically by the first ticks (zone_metrics still
-- holds them: 29 k / 124 k / 148 k / 144 k rows).
--
-- ROLLBACK: re-apply the enrich body from 20260708170500 + later enrichment migrations,
--           SELECT cron.unschedule('zone_price_observations_daily') and re-schedule the
--           old 4-statement command at '0 7 * * *'; DROP FUNCTION zpo_daily_tick(integer);
--           DROP TABLE zpo_build_state; DROP INDEX zone_metrics_captured_brin.
-- ============================================================================

SET LOCAL lock_timeout = '10s';

-- ---------------------------------------------------------------------------
-- Enrichment, scoped to one capture date
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.enrich_zone_price_observations(p_capture_date date DEFAULT NULL::date)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_rows integer := 0;
  v_d    date;
BEGIN
  -- NULL keeps its old meaning (every date) — one scoped pass per date.
  IF p_capture_date IS NULL THEN
    FOR v_d IN SELECT DISTINCT capture_date FROM zone_price_observations ORDER BY 1 LOOP
      v_rows := v_rows + public.enrich_zone_price_observations(v_d);
    END LOOP;
    RETURN v_rows;
  END IF;

  -- 1. rivalry (fast as-is)
  UPDATE zone_price_observations z
     SET is_rivalry = true, rivalry_name = r.rivalry_name,
         rivalry_intensity = r.rivalry_intensity, rivalry_is_branded = r.is_branded
    FROM v_event_sporting_rivalries r
   WHERE r.tevo_event_id = z.event_id AND z.capture_date = p_capture_date;
  GET DIAGNOSTICS v_rows = ROW_COUNT;

  -- 2. weather (fast as-is)
  UPDATE zone_price_observations z
     SET wx_temp_f = w.temp_f, wx_precip_pct = w.precip_pct, wx_wind_mph = w.wind_mph,
         wx_summary = w.weather_summary, wx_kind = w.weather_kind
    FROM v_event_weather_with_fallback w
   WHERE w.tevo_event_id = z.event_id AND z.capture_date = p_capture_date;

  -- 3. weather alerts — same rule as v_event_active_weather_alerts (status Actual, game time
  --    inside effective..expires/ends/+6h, venue county OR forecast zone, game within the
  --    last day), but find the handful of alerts in force during the day's games FIRST.
  WITH day_ev AS (
    SELECT e.id, e.occurs_at_local::timestamptz AS t, va.ugc_county_code AS c, va.ugc_forecast_zone AS f
      FROM (SELECT DISTINCT event_id FROM zone_price_observations WHERE capture_date = p_capture_date) de
      JOIN events e ON e.id = de.event_id
      JOIN venue_assets va ON va.tevo_venue_id = e.venue_id
     WHERE e.occurs_at_local ~ '^\d{4}-\d\d-\d\dT'
       AND e.occurs_at_local::timestamptz > now() - interval '1 day'),
  bounds AS (SELECT min(t) AS lo, max(t) AS hi FROM day_ev),
  act AS (
    SELECT a.id, a.impact_tier, a.effective_at,
           coalesce(a.expires_at, a.ends_at, a.effective_at + interval '6 hours') AS until_at
      FROM nws_alerts a, bounds b
     WHERE a.status = 'Actual' AND a.effective_at <= b.hi
       AND coalesce(a.expires_at, a.ends_at, a.effective_at + interval '6 hours') >= b.lo),
  hits AS (
    SELECT DISTINCT ON (de.id) de.id AS tevo_event_id, act.impact_tier
      FROM act
      JOIN nws_alert_zones zz ON zz.alert_id = act.id
      JOIN day_ev de ON (zz.ugc_code = de.c OR zz.ugc_code = de.f)
                    AND de.t >= act.effective_at AND de.t <= act.until_at
     ORDER BY de.id, act.impact_tier)
  UPDATE zone_price_observations z
     SET wx_has_alert = true, wx_alert_tier = hits.impact_tier
    FROM hits
   WHERE hits.tevo_event_id = z.event_id AND z.capture_date = p_capture_date;

  -- 4. primary (AXS face) vs secondary — same arithmetic as v_event_primary_vs_secondary,
  --    computed only for the day's events.
  WITH day_ev AS (SELECT DISTINCT event_id FROM zone_price_observations WHERE capture_date = p_capture_date),
  latest_axs AS (
    SELECT ae.tevo_event_id, max(ae.last_snapshot_id) AS snap
      FROM axs_events ae
     WHERE ae.tevo_event_id IN (SELECT event_id FROM day_ev) AND ae.last_snapshot_id IS NOT NULL
     GROUP BY ae.tevo_event_id),
  axs_face AS (
    SELECT l.event_id AS tevo_event_id,
           min(l.retail_price) FILTER (WHERE l.retail_price > 0) AS getin,
           percentile_cont(0.5) WITHIN GROUP (ORDER BY l.retail_price::double precision)
             FILTER (WHERE l.retail_price > 0) AS median,
           count(*) FILTER (WHERE l.retail_price > 0) AS listings
      FROM v_axs_listings l
      JOIN latest_axs la ON la.tevo_event_id = l.event_id AND la.snap = l.snapshot_id
     WHERE l.src = 'primary'
     GROUP BY l.event_id),
  p AS (
    SELECT a.tevo_event_id, a.getin, a.median, a.listings,
           round((least(arb.tevo_retail_min, arb.sg_all_min) - a.getin) / nullif(a.getin, 0) * 100, 1) AS flip_pct,
           CASE WHEN least(arb.tevo_retail_min, arb.sg_all_min) IS NULL THEN 'no_secondary'
                WHEN least(arb.tevo_retail_min, arb.sg_all_min) >= a.getin THEN 'secondary_premium'
                ELSE 'below_face' END AS signal
      FROM axs_face a
      JOIN v_event_price_arbitrage arb ON arb.tevo_event_id = a.tevo_event_id
     WHERE a.getin IS NOT NULL)
  UPDATE zone_price_observations z
     SET primary_getin = p.getin, primary_median = p.median, primary_listings = p.listings,
         primary_flip_margin_pct = p.flip_pct, primary_signal = p.signal
    FROM p
   WHERE p.tevo_event_id = z.event_id AND z.capture_date = p_capture_date;

  -- 5. velocity — previous capture of the same (event, zone) via the
  --    (event_id, zone, capture_date) unique index instead of lag() over the whole table.
  UPDATE zone_price_observations z
     SET vel_prev_capture_date = prev.capture_date,
         vel_days_since_prev   = (z0.capture_date - prev.capture_date),
         vel_tickets_prev      = prev.tickets_count,
         vel_tickets_sold      = prev.tickets_count - z0.tickets_count,
         vel_getin_prev        = prev.getin_price,
         vel_getin_delta_pct   = CASE WHEN prev.getin_price > 0
                                   THEN round(100 * (z0.getin_price - prev.getin_price) / prev.getin_price, 2) END,
         vel_median_delta_pct  = CASE WHEN prev.retail_median > 0
                                   THEN round(100 * (z0.retail_median - prev.retail_median) / prev.retail_median, 2) END
    FROM zone_price_observations z0
    CROSS JOIN LATERAL (
      SELECT q.capture_date, q.tickets_count, q.getin_price, q.retail_median
        FROM zone_price_observations q
       WHERE q.event_id = z0.event_id AND q.zone = z0.zone AND q.capture_date < z0.capture_date
       ORDER BY q.capture_date DESC
       LIMIT 1) prev
   WHERE z0.capture_date = p_capture_date AND z.observation_id = z0.observation_id;

  -- 6. home news buzz, 7 days — counted once per team, then summed per event over its
  --    xref teams (same result as the per-event LEFT JOIN count).
  WITH ev AS (
    SELECT DISTINCT event_id, performer_id FROM zone_price_observations WHERE capture_date = p_capture_date),
  teams AS (
    SELECT DISTINCT x.espn_team_id FROM ev JOIN performer_espn_team_xref x ON x.tevo_performer_id = ev.performer_id),
  team_cnt AS (
    SELECT t.espn_team_id, count(n.espn_article_id) AS cnt
      FROM teams t
      LEFT JOIN espn_news n ON n.espn_team_id = t.espn_team_id
            AND n.published_at >= (p_capture_date - 7)::timestamptz
            AND n.published_at <  (p_capture_date + 1)::timestamptz
     GROUP BY t.espn_team_id),
  b AS (
    SELECT ev.event_id, sum(tc.cnt) AS cnt
      FROM ev
      JOIN performer_espn_team_xref x ON x.tevo_performer_id = ev.performer_id
      JOIN team_cnt tc ON tc.espn_team_id = x.espn_team_id
     GROUP BY ev.event_id)
  UPDATE zone_price_observations z
     SET buzz_home_news_7d = b.cnt
    FROM b
   WHERE b.event_id = z.event_id AND z.capture_date = p_capture_date;

  -- 7. injuries — latest status per (team, athlete) for the day's home teams only, and the
  --    injured count once per team (was re-counted for every row).
  WITH home AS (
    SELECT DISTINCT z.event_id, z.star_athlete_name, x.espn_team_id
      FROM zone_price_observations z
      JOIN performer_espn_team_xref x ON x.tevo_performer_id = z.performer_id
     WHERE z.capture_date = p_capture_date),
  latest_inj AS (
    SELECT DISTINCT ON (s.espn_team_id, s.athlete_name) s.espn_team_id, s.athlete_name, s.status
      FROM espn_injuries_snapshots s
     WHERE s.espn_team_id IN (SELECT espn_team_id FROM home)
     ORDER BY s.espn_team_id, s.athlete_name, s.last_seen_at DESC NULLS LAST),
  team_inj AS (
    SELECT espn_team_id, count(*) FILTER (WHERE status ~* 'out|injured reserve|doubtful|suspend') AS injured_cnt
      FROM latest_inj GROUP BY espn_team_id),
  resolved AS (
    SELECT h.event_id, li.status AS star_status, coalesce(ti.injured_cnt, 0) AS injured_cnt
      FROM home h
      LEFT JOIN latest_inj li ON li.espn_team_id = h.espn_team_id AND lower(li.athlete_name) = lower(h.star_athlete_name)
      LEFT JOIN team_inj ti ON ti.espn_team_id = h.espn_team_id)
  UPDATE zone_price_observations z
     SET star_injury_status = res.star_status,
         star_out = (res.star_status ~* 'out|injured reserve|doubtful|suspend'),
         home_injured_count = res.injured_cnt
    FROM resolved res
   WHERE res.event_id = z.event_id AND z.capture_date = p_capture_date;

  -- 8. roster / star Wikipedia page views (fast as-is)
  UPDATE zone_price_observations z
     SET roster_wiki_pv_sum = agg.pv_sum, roster_wiki_pv_max = agg.pv_max
    FROM (
      SELECT z2.event_id, sum(aw.wiki_pv_30d) AS pv_sum, max(aw.wiki_pv_30d) AS pv_max
        FROM (SELECT DISTINCT event_id, roster_athlete_ids FROM zone_price_observations
               WHERE roster_athlete_ids IS NOT NULL AND capture_date = p_capture_date) z2
        CROSS JOIN LATERAL jsonb_array_elements_text(z2.roster_athlete_ids) AS aid(id)
        JOIN athlete_wikipedia aw ON aw.espn_athlete_id = aid.id AND aw.wiki_pv_30d IS NOT NULL
       GROUP BY z2.event_id) agg
   WHERE agg.event_id = z.event_id AND z.capture_date = p_capture_date;

  UPDATE zone_price_observations z
     SET star_athlete_pv = aw.wiki_pv_30d
    FROM athlete_wikipedia aw
   WHERE aw.espn_athlete_id = z.star_athlete_id AND aw.wiki_pv_30d IS NOT NULL
     AND z.capture_date = p_capture_date;

  -- 9. national TV — latest ESPN snapshot carrying broadcast info, for the day's events only
  WITH day_espn AS (
    SELECT DISTINCT x.espn_event_id, x.tevo_event_id
      FROM (SELECT DISTINCT event_id FROM zone_price_observations WHERE capture_date = p_capture_date) de
      JOIN event_xref x ON x.tevo_event_id = de.event_id
     WHERE x.espn_event_id IS NOT NULL),
  latest_snap AS (
    SELECT de.tevo_event_id, s.meta
      FROM day_espn de
      CROSS JOIN LATERAL (
        SELECT es.meta FROM espn_event_snapshots es
         WHERE es.espn_event_id = de.espn_event_id AND es.meta ? 'broadcast'
         ORDER BY es.captured_at DESC LIMIT 1) s),
  bcast AS (
    SELECT ls.tevo_event_id,
           bool_or(
             n ~* '\m(ESPN[0-9]?|ESPNU|ESPN Deportes|ABC|CBS|FOX|FS1|FS2|NBC|TBS|TNT|truTV|Peacock|Prime Video|Apple TV|Netflix|Amazon|MLB Network|NFL Network|NBA TV|NHL Network|USA Network|USA Net|CNBC|TSN|Sportsnet|CTV|TUDN|Univision|Telemundo|FOX Deportes|ION|Roku)\M'
             AND n !~* 'unlmtd|unlimited|league pass'
             AND n !~* '\.tv$') AS is_national,
           string_agg(n, ', ' ORDER BY n) AS networks
      FROM latest_snap ls
      CROSS JOIN LATERAL jsonb_array_elements_text(ls.meta->'broadcast'->'networks') n
     GROUP BY ls.tevo_event_id)
  UPDATE zone_price_observations z
     SET is_national_tv = b.is_national, broadcast_networks = nullif(b.networks, '')
    FROM bcast b
   WHERE b.tevo_event_id = z.event_id AND z.capture_date = p_capture_date;

  RETURN v_rows;
END $function$;

-- BRIN on zone_metrics.captured_at: the runner selects a day's rows by time; the only
-- existing indexes lead with event_id. Rows arrive in time order, so BRIN is tiny (48 kB on
-- 1.2 GB). On prod it was built beforehand with CREATE INDEX CONCURRENTLY (no write lock on
-- the hot table), so this statement is a no-op there; fresh environments build it here.
CREATE INDEX IF NOT EXISTS zone_metrics_captured_brin ON public.zone_metrics USING brin (captured_at);

-- ---------------------------------------------------------------------------
-- Runner state + runner
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.zpo_build_state (
  capture_date      date        PRIMARY KEY,
  events_total      integer,
  last_event_id     bigint      NOT NULL DEFAULT 0,   -- resumable cursor (events built in id order)
  events_built      integer     NOT NULL DEFAULT 0,
  rows_built        bigint      NOT NULL DEFAULT 0,
  build_started_at  timestamptz,
  build_finished_at timestamptz,
  enriched_at       timestamptz,
  enrich_seconds    numeric,
  last_error        text,
  updated_at        timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.zpo_build_state ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.zpo_build_state FROM anon, authenticated;
COMMENT ON TABLE public.zpo_build_state IS
  'Per capture_date progress of the zone_price_observations build (resumable cursor) and enrichment. Written by zpo_daily_tick (mig 20261027030432).';

CREATE OR REPLACE FUNCTION public.zpo_daily_tick(p_budget_seconds integer DEFAULT 600)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_start   timestamptz := clock_timestamp();
  v_budget  interval := make_interval(secs => p_budget_seconds);
  v_caller  text;
  v_d       date;
  st        public.zpo_build_state%ROWTYPE;
  v_ev      bigint;
  v_n       integer;
  v_t0      timestamptz;
  v_log     jsonb := '[]'::jsonb;
  v_stop    boolean := false;
  v_stale   boolean;
BEGIN
  -- inside SECURITY DEFINER current_user is the owner; check the caller's role
  v_caller := CASE WHEN coalesce(current_setting('role', true), 'none') IN ('', 'none')
                   THEN session_user::text ELSE current_setting('role', true) END;
  IF v_caller NOT IN ('service_role','postgres','supabase_admin') THEN
    RAISE EXCEPTION 'forbidden: zpo_daily_tick is service-only (caller %)', v_caller USING ERRCODE = '42501';
  END IF;

  -- Last 14 days, oldest first (velocity reads the previous day's rows).
  FOR v_d IN SELECT d::date FROM generate_series(current_date - 14, current_date, interval '1 day') d ORDER BY d LOOP
    EXIT WHEN v_stop;
    SELECT * INTO st FROM public.zpo_build_state WHERE capture_date = v_d;

    -- first sight of a day: count its events once (BRIN on captured_at); empty days are recorded as done
    IF st.capture_date IS NULL THEN
      SELECT count(DISTINCT event_id) INTO v_n FROM zone_metrics
       WHERE captured_at >= v_d::timestamptz AND captured_at < (v_d + 1)::timestamptz;
      INSERT INTO public.zpo_build_state (capture_date, events_total, build_started_at, build_finished_at, enriched_at)
      VALUES (v_d, v_n, now(),
              CASE WHEN v_n = 0 THEN now() END,
              CASE WHEN v_n = 0 THEN now() END)
      ON CONFLICT (capture_date) DO NOTHING;
      SELECT * INTO st FROM public.zpo_build_state WHERE capture_date = v_d;
    END IF;

    -- A finished build is stale only for YESTERDAY when it was made before the day ended
    -- (it saw a partial day). Today is built once per day; older days once.
    v_stale := st.build_finished_at IS NOT NULL
               AND v_d = current_date - 1
               AND st.build_finished_at < (v_d + 1)::timestamptz;
    IF v_stale THEN
      SELECT count(DISTINCT event_id) INTO v_n FROM zone_metrics
       WHERE captured_at >= v_d::timestamptz AND captured_at < (v_d + 1)::timestamptz;
      UPDATE public.zpo_build_state
         SET events_total = v_n, last_event_id = 0, events_built = 0, rows_built = 0,
             build_started_at = now(), build_finished_at = NULL, enriched_at = NULL,
             enrich_seconds = NULL, last_error = NULL, updated_at = now()
       WHERE capture_date = v_d;
      SELECT * INTO st FROM public.zpo_build_state WHERE capture_date = v_d;
    END IF;

    CONTINUE WHEN st.build_finished_at IS NOT NULL AND st.enriched_at IS NOT NULL;   -- done

    -- build, event by event, from the resumable cursor
    IF st.build_finished_at IS NULL THEN
      FOR v_ev IN
        SELECT DISTINCT event_id FROM zone_metrics
         WHERE captured_at >= v_d::timestamptz AND captured_at < (v_d + 1)::timestamptz
           AND event_id > st.last_event_id
         ORDER BY event_id
      LOOP
        IF clock_timestamp() - v_start > v_budget THEN v_stop := true; EXIT; END IF;
        v_n := public.build_zone_price_observations(v_ev, v_d);
        UPDATE public.zpo_build_state
           SET last_event_id = v_ev, events_built = events_built + 1, rows_built = rows_built + v_n, updated_at = now()
         WHERE capture_date = v_d;
      END LOOP;
      IF v_stop THEN
        SELECT * INTO st FROM public.zpo_build_state WHERE capture_date = v_d;
        v_log := v_log || jsonb_build_object('date', v_d, 'status', 'build_paused',
                                             'events_built', st.events_built, 'events_total', st.events_total);
        EXIT;
      END IF;
      UPDATE public.zpo_build_state SET build_finished_at = now(), updated_at = now() WHERE capture_date = v_d;
    END IF;

    -- enrichment takes ~30–60 s for a full day: don't start it in the last 2 minutes of the
    -- budget (a statement timeout cannot be caught and would roll the whole run back)
    IF clock_timestamp() - v_start > v_budget - interval '2 minutes' THEN
      v_log := v_log || jsonb_build_object('date', v_d, 'status', 'enrich_deferred');
      v_stop := true; EXIT;
    END IF;

    v_t0 := clock_timestamp();
    BEGIN
      PERFORM public.enrich_zone_price_observations(v_d);
      UPDATE public.zpo_build_state
         SET enriched_at = now(), enrich_seconds = round(extract(epoch FROM clock_timestamp() - v_t0)::numeric, 1),
             last_error = NULL, updated_at = now()
       WHERE capture_date = v_d;
      SELECT * INTO st FROM public.zpo_build_state WHERE capture_date = v_d;
      v_log := v_log || jsonb_build_object('date', v_d, 'status', 'done', 'rows', st.rows_built,
                                           'events', st.events_built, 'enrich_s', st.enrich_seconds);
    EXCEPTION WHEN OTHERS THEN
      -- recorded; the build above is kept and the next run retries enrichment only
      UPDATE public.zpo_build_state SET last_error = left(SQLERRM, 500), updated_at = now() WHERE capture_date = v_d;
      v_log := v_log || jsonb_build_object('date', v_d, 'status', 'enrich_failed', 'error', left(SQLERRM, 200));
    END;
  END LOOP;

  RETURN jsonb_build_object('days', v_log, 'seconds', round(extract(epoch FROM clock_timestamp() - v_start)::numeric, 1),
                            'stopped_on_budget', v_stop);
END $$;

-- ---------------------------------------------------------------------------
-- Grants: service_role only (these are SECURITY DEFINER writers)
-- ---------------------------------------------------------------------------
REVOKE ALL ON FUNCTION public.zpo_daily_tick(integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.zpo_daily_tick(integer) TO service_role;
REVOKE ALL ON FUNCTION public.enrich_zone_price_observations(date) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.enrich_zone_price_observations(date) TO service_role;
REVOKE ALL ON FUNCTION public.build_zone_price_observations(bigint, date) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.build_zone_price_observations(bigint, date) TO service_role;
REVOKE ALL ON FUNCTION public.build_zone_price_observations_day(date) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.build_zone_price_observations_day(date) TO service_role;

-- ---------------------------------------------------------------------------
-- Cron: same job name, new runner, off-peak window (06:15–11:45 UTC = 2–7 AM ET in EDT)
-- ---------------------------------------------------------------------------
DO $c$
BEGIN
  PERFORM cron.unschedule(jobid) FROM cron.job WHERE jobname = 'zone_price_observations_daily';
  PERFORM cron.schedule('zone_price_observations_daily', '15,45 6-11 * * *',
    $cmd$DO $b$ BEGIN IF NOT public.cron_try_lock('zone_price_observations_daily') THEN RETURN; END IF; PERFORM public.zpo_daily_tick(600); END $b$;$cmd$);
END $c$;

-- ============================================================================
-- VERIFY: SELECT * FROM public.zpo_build_state ORDER BY capture_date;
--         SELECT capture_date, count(*) FROM public.zone_price_observations WHERE capture_date >= '2026-10-23' GROUP BY 1 ORDER BY 1;
--         SELECT jobname, schedule FROM cron.job WHERE jobname = 'zone_price_observations_daily';
-- ============================================================================

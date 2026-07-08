-- ============================================================================
-- Migration 20260708174000 — Athlete Wikipedia pageviews + roster_wiki_pv fill
--
-- Lane:     data plane (A1)
-- Touches:  athlete_wikipedia (add pageview columns + fetch machinery),
--           queue/process_athlete_wiki_pageviews() (new), 2 crons,
--           enrich_zone_price_observations() (fill roster_wiki_pv_* + star pv)
--
-- Completes the player-brand pipeline: now that athletes are matched to Wikipedia
-- titles, pull 30-day pageviews (mainstream-fame signal, complements the stats-
-- based fantasy brand) and aggregate them into the zone store. The builder
-- already stores roster_athlete_ids per row, so roster_wiki_pv_* is a clean
-- enrichment join — no builder rewrite.
--
-- Wikimedia REST pageviews API (unauthenticated, UA required):
--   /metrics/pageviews/per-article/en.wikipedia/all-access/all-agents/
--     {title}/daily/{start}/{end}  -> { items:[{ timestamp, views }] }
-- ============================================================================

ALTER TABLE athlete_wikipedia ADD COLUMN IF NOT EXISTS wiki_pv_30d        integer;
ALTER TABLE athlete_wikipedia ADD COLUMN IF NOT EXISTS wiki_pv_pulled_at  timestamptz;
ALTER TABLE athlete_wikipedia ADD COLUMN IF NOT EXISTS wiki_pv_request_id bigint;

ALTER TABLE zone_price_observations ADD COLUMN IF NOT EXISTS star_athlete_pv integer;

-- ----------------------------------------------------------------------------
-- (1) queue pageview fetches for matched athletes (staleness-rotating)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION queue_athlete_wiki_pageviews(p_limit int DEFAULT 30)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  r RECORD; v_req bigint; v_count int := 0;
  v_start text := to_char(current_date - 31, 'YYYYMMDD');
  v_end   text := to_char(current_date - 1,  'YYYYMMDD');
  v_ua jsonb := jsonb_build_object('User-Agent',
    'Terminal2-S4K/1.0 (https://github.com/JulianS4K/Terminal-2; admin@s4kent.com)',
    'Accept','application/json');
BEGIN
  FOR r IN
    SELECT espn_athlete_id, wiki_title
    FROM athlete_wikipedia
    WHERE wiki_pageid IS NOT NULL AND NOT is_rejected AND wiki_title IS NOT NULL
      AND (wiki_pv_pulled_at IS NULL OR wiki_pv_pulled_at < now() - interval '7 days')
    ORDER BY wiki_pv_pulled_at NULLS FIRST
    LIMIT p_limit
  LOOP
    SELECT net.http_get(
      url := 'https://wikimedia.org/api/rest_v1/metrics/pageviews/per-article/en.wikipedia/all-access/all-agents/'
             || replace(r.wiki_title, ' ', '_') || '/daily/' || v_start || '/' || v_end,
      headers := v_ua, timeout_milliseconds := 12000
    ) INTO v_req;
    UPDATE athlete_wikipedia SET wiki_pv_request_id = v_req WHERE espn_athlete_id = r.espn_athlete_id;
    v_count := v_count + 1;
    PERFORM pg_sleep(0.2);
  END LOOP;
  RETURN v_count;
END $$;

-- ----------------------------------------------------------------------------
-- (2) process responses -> wiki_pv_30d (sum of daily views)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION process_athlete_wiki_pageviews()
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE r RECORD; v_body jsonb; v_sum bigint; v_n int := 0;
BEGIN
  FOR r IN
    SELECT aw.espn_athlete_id, aw.wiki_pv_request_id, h.content, h.status_code
    FROM athlete_wikipedia aw
    JOIN net._http_response h ON h.id = aw.wiki_pv_request_id
    WHERE aw.wiki_pv_request_id IS NOT NULL
  LOOP
    IF r.status_code = 200 THEN
      BEGIN v_body := r.content::jsonb; EXCEPTION WHEN OTHERS THEN v_body := NULL; END;
      SELECT COALESCE(sum((it->>'views')::bigint), 0) INTO v_sum
        FROM jsonb_array_elements(COALESCE(v_body->'items','[]'::jsonb)) it;
      UPDATE athlete_wikipedia
         SET wiki_pv_30d = v_sum, wiki_pv_pulled_at = now(), wiki_pv_request_id = NULL
       WHERE espn_athlete_id = r.espn_athlete_id;
      v_n := v_n + 1;
    ELSE
      -- 404 (title has no pageview record) / other: mark pulled with 0 so staleness advances
      UPDATE athlete_wikipedia
         SET wiki_pv_30d = COALESCE(wiki_pv_30d, 0), wiki_pv_pulled_at = now(), wiki_pv_request_id = NULL
       WHERE espn_athlete_id = r.espn_athlete_id;
    END IF;
  END LOOP;
  RETURN v_n;
END $$;

-- ----------------------------------------------------------------------------
-- (3) crons (offset a minute; every 30 min)
-- ----------------------------------------------------------------------------
SELECT cron.schedule('athlete_wiki_pageviews_queue',   '10,40 * * * *', $$ SELECT public.queue_athlete_wiki_pageviews(30); $$);
SELECT cron.schedule('athlete_wiki_pageviews_process', '12,42 * * * *', $$ SELECT public.process_athlete_wiki_pageviews(); $$);

-- ----------------------------------------------------------------------------
-- (4) fill roster_wiki_pv_* + star_athlete_pv in enrich (uses stored
--     roster_athlete_ids, no builder rewrite)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION enrich_zone_price_observations(p_capture_date date DEFAULT NULL)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_rows integer;
BEGIN
  UPDATE zone_price_observations z
     SET is_rivalry = true, rivalry_name = r.rivalry_name,
         rivalry_intensity = r.rivalry_intensity, rivalry_is_branded = r.is_branded
    FROM v_event_sporting_rivalries r
   WHERE r.tevo_event_id = z.event_id
     AND (p_capture_date IS NULL OR z.capture_date = p_capture_date);
  GET DIAGNOSTICS v_rows = ROW_COUNT;

  UPDATE zone_price_observations z
     SET wx_temp_f = w.temp_f, wx_precip_pct = w.precip_pct, wx_wind_mph = w.wind_mph,
         wx_summary = w.weather_summary, wx_kind = w.weather_kind
    FROM v_event_weather_with_fallback w
   WHERE w.tevo_event_id = z.event_id
     AND (p_capture_date IS NULL OR z.capture_date = p_capture_date);
  UPDATE zone_price_observations z
     SET wx_has_alert = true, wx_alert_tier = a.impact_tier
    FROM (SELECT DISTINCT ON (tevo_event_id) tevo_event_id, impact_tier
            FROM v_event_active_weather_alerts ORDER BY tevo_event_id, impact_tier) a
   WHERE a.tevo_event_id = z.event_id
     AND (p_capture_date IS NULL OR z.capture_date = p_capture_date);

  UPDATE zone_price_observations z
     SET primary_getin = p.axs_primary_getin, primary_median = p.axs_primary_median,
         primary_listings = p.axs_primary_listings,
         primary_flip_margin_pct = p.flip_margin_pct, primary_signal = p.signal
    FROM v_event_primary_vs_secondary p
   WHERE p.tevo_event_id = z.event_id
     AND (p_capture_date IS NULL OR z.capture_date = p_capture_date);

  WITH lagged AS (
    SELECT event_id, zone, capture_date, getin_price, tickets_count, retail_median,
           lag(capture_date)  OVER w AS prev_date,
           lag(getin_price)   OVER w AS getin_prev,
           lag(tickets_count) OVER w AS tickets_prev,
           lag(retail_median) OVER w AS median_prev
      FROM zone_price_observations
     WINDOW w AS (PARTITION BY event_id, zone ORDER BY capture_date, captured_at)
  )
  UPDATE zone_price_observations z
     SET vel_prev_capture_date = l.prev_date,
         vel_days_since_prev   = (l.capture_date - l.prev_date),
         vel_tickets_prev      = l.tickets_prev,
         vel_tickets_sold      = l.tickets_prev - z.tickets_count,
         vel_getin_prev        = l.getin_prev,
         vel_getin_delta_pct   = CASE WHEN l.getin_prev > 0
                                   THEN round(100*(z.getin_price - l.getin_prev)/l.getin_prev, 2) END,
         vel_median_delta_pct  = CASE WHEN l.median_prev > 0
                                   THEN round(100*(z.retail_median - l.median_prev)/l.median_prev, 2) END
    FROM lagged l
   WHERE l.event_id = z.event_id AND l.zone = z.zone AND l.capture_date = z.capture_date
     AND l.prev_date IS NOT NULL
     AND (p_capture_date IS NULL OR z.capture_date = p_capture_date);

  UPDATE zone_price_observations z
     SET buzz_home_news_7d = b.cnt
    FROM (
      SELECT ez.event_id, ez.capture_date, count(n.espn_article_id) AS cnt
        FROM (SELECT DISTINCT event_id, capture_date, performer_id
                FROM zone_price_observations
               WHERE (p_capture_date IS NULL OR capture_date = p_capture_date)) ez
        JOIN performer_espn_team_xref x ON x.tevo_performer_id = ez.performer_id
        LEFT JOIN espn_news n ON n.espn_team_id = x.espn_team_id
              AND n.published_at >= (ez.capture_date - 7)::timestamptz
              AND n.published_at <  (ez.capture_date + 1)::timestamptz
       GROUP BY ez.event_id, ez.capture_date
    ) b
   WHERE b.event_id = z.event_id AND b.capture_date = z.capture_date
     AND (p_capture_date IS NULL OR z.capture_date = p_capture_date);

  WITH latest_inj AS (
    SELECT DISTINCT ON (espn_team_id, athlete_name) espn_team_id, athlete_name, status
      FROM espn_injuries_snapshots
     ORDER BY espn_team_id, athlete_name, last_seen_at DESC NULLS LAST
  ),
  home AS (
    SELECT DISTINCT z.event_id, z.capture_date, z.star_athlete_name, x.espn_team_id
      FROM zone_price_observations z
      JOIN performer_espn_team_xref x ON x.tevo_performer_id = z.performer_id
     WHERE (p_capture_date IS NULL OR z.capture_date = p_capture_date)
  ),
  resolved AS (
    SELECT h.event_id, h.capture_date, li.status AS star_status,
           (SELECT count(*) FROM latest_inj li2
             WHERE li2.espn_team_id = h.espn_team_id
               AND li2.status ~* 'out|injured reserve|doubtful|suspend') AS injured_cnt
      FROM home h
      LEFT JOIN latest_inj li ON li.espn_team_id = h.espn_team_id
            AND lower(li.athlete_name) = lower(h.star_athlete_name)
  )
  UPDATE zone_price_observations z
     SET star_injury_status = res.star_status,
         star_out = (res.star_status ~* 'out|injured reserve|doubtful|suspend'),
         home_injured_count = res.injured_cnt
    FROM resolved res
   WHERE res.event_id = z.event_id AND res.capture_date = z.capture_date
     AND (p_capture_date IS NULL OR z.capture_date = p_capture_date);

  -- (7) roster wiki pageviews (over the stored roster) + the star's pageviews.
  --     Unnest each roster once via LATERAL, then equi-join athlete ids (both
  --     text) so the planner can hash-join — an IN (set-returning subquery) here
  --     degrades to a per-row nested loop over the whole athlete table.
  UPDATE zone_price_observations z
     SET roster_wiki_pv_sum = agg.pv_sum,
         roster_wiki_pv_max = agg.pv_max
    FROM (
      SELECT z2.event_id, z2.capture_date,
             sum(aw.wiki_pv_30d) AS pv_sum, max(aw.wiki_pv_30d) AS pv_max
        FROM (SELECT DISTINCT event_id, capture_date, roster_athlete_ids
                FROM zone_price_observations
               WHERE roster_athlete_ids IS NOT NULL
                 AND (p_capture_date IS NULL OR capture_date = p_capture_date)) z2
        CROSS JOIN LATERAL jsonb_array_elements_text(z2.roster_athlete_ids) AS aid(id)
        JOIN athlete_wikipedia aw
          ON aw.espn_athlete_id = aid.id AND aw.wiki_pv_30d IS NOT NULL
       GROUP BY z2.event_id, z2.capture_date
    ) agg
   WHERE agg.event_id = z.event_id AND agg.capture_date = z.capture_date
     AND (p_capture_date IS NULL OR z.capture_date = p_capture_date);

  UPDATE zone_price_observations z
     SET star_athlete_pv = aw.wiki_pv_30d
    FROM athlete_wikipedia aw
   WHERE aw.espn_athlete_id = z.star_athlete_id AND aw.wiki_pv_30d IS NOT NULL
     AND (p_capture_date IS NULL OR z.capture_date = p_capture_date);

  RETURN v_rows;
END $$;

REVOKE ALL ON FUNCTION enrich_zone_price_observations(date) FROM public;

-- ============================================================================
-- Migration 20260708175000 — National-TV / broadcast enrichment
--
-- Lane:     data plane (A1)
-- Touches:  zone_price_observations (add broadcast columns),
--           enrich_zone_price_observations() (extend — signal group 8)
--
-- The next "featurize data we already fetch" signal: a nationally-televised
-- game shifts demand (bigger stage, but also a stay-home substitute). ESPN's
-- summary payload carries broadcasts[]; espn-collect now stashes {networks,
-- national} into espn_event_snapshots.meta->'broadcast' (no writer-SQL change —
-- it rides the existing meta jsonb through upsert_espn_event_snapshot).
--
-- Enrichment joins the latest snapshot per ESPN event → tevo event via
-- event_xref. Forward-looking: values populate as espn-collect re-snapshots
-- events after the edge-function deploy (broadcast is null on older snapshots).
-- ============================================================================

ALTER TABLE zone_price_observations ADD COLUMN IF NOT EXISTS is_national_tv     boolean;
ALTER TABLE zone_price_observations ADD COLUMN IF NOT EXISTS broadcast_networks text;

COMMENT ON COLUMN zone_price_observations.is_national_tv IS
  'Game carried on a national broadcast (ESPN summary broadcasts[].market = '
  '"national"), from espn_event_snapshots.meta->broadcast. Set by '
  'enrich_zone_price_observations() group 8; null when no snapshot broadcast yet.';

CREATE OR REPLACE FUNCTION enrich_zone_price_observations(p_capture_date date DEFAULT NULL)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_rows integer;
BEGIN
  -- (1) rivalry (static per event)
  UPDATE zone_price_observations z
     SET is_rivalry = true, rivalry_name = r.rivalry_name,
         rivalry_intensity = r.rivalry_intensity, rivalry_is_branded = r.is_branded
    FROM v_event_sporting_rivalries r
   WHERE r.tevo_event_id = z.event_id
     AND (p_capture_date IS NULL OR z.capture_date = p_capture_date);
  GET DIAGNOSTICS v_rows = ROW_COUNT;

  -- (2) weather (forecast w/ climatology fallback) + active alert
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

  -- (3) primary market (AXS/Ticketmaster face vs secondary)
  UPDATE zone_price_observations z
     SET primary_getin = p.axs_primary_getin, primary_median = p.axs_primary_median,
         primary_listings = p.axs_primary_listings,
         primary_flip_margin_pct = p.flip_margin_pct, primary_signal = p.signal
    FROM v_event_primary_vs_secondary p
   WHERE p.tevo_event_id = z.event_id
     AND (p_capture_date IS NULL OR z.capture_date = p_capture_date);

  -- (4) sell-through velocity / momentum (self-lag over each event×zone series)
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

  -- (5) home-team news buzz (trailing 7d ending at capture_date)
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

  -- (6) star availability + home injured count (latest injury snapshot)
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

  -- (7) roster wiki pageviews (LATERAL unnest + equi-join, hashable) + star pv
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

  -- (8) national-TV / broadcast (latest snapshot per ESPN event → tevo event).
  --     ESPN's market flag calls MLB.TV / League Pass "national", so almost every
  --     game would read national=true. Derive the real signal from the network
  --     NAMES instead: a curated set of genuine national broadcasters, excluding
  --     always-on OTT packages (MLB.TV, League Pass, ESPN Unlmtd) and team-owned
  --     ".TV" RSN feeds. broadcast_networks keeps the full raw list for context.
  WITH latest_snap AS (
    SELECT DISTINCT ON (espn_event_id) espn_event_id, meta
      FROM espn_event_snapshots
     WHERE meta ? 'broadcast'
     ORDER BY espn_event_id, captured_at DESC
  ),
  bcast AS (
    SELECT ls.espn_event_id,
           bool_or(
             n ~* '\m(ESPN[0-9]?|ESPNU|ESPN Deportes|ABC|CBS|FOX|FS1|FS2|NBC|TBS|TNT|truTV|Peacock|Prime Video|Apple TV|Netflix|Amazon|MLB Network|NFL Network|NBA TV|NHL Network|USA Network|USA Net|CNBC|TSN|Sportsnet|CTV|TUDN|Univision|Telemundo|FOX Deportes|ION|Roku)\M'
             AND n !~* 'unlmtd|unlimited|league pass'
             AND n !~* '\.tv$'
           ) AS is_national,
           string_agg(n, ', ' ORDER BY n) AS networks
      FROM latest_snap ls
      CROSS JOIN LATERAL jsonb_array_elements_text(ls.meta->'broadcast'->'networks') n
     GROUP BY ls.espn_event_id
  )
  UPDATE zone_price_observations z
     SET is_national_tv = b.is_national,
         broadcast_networks = NULLIF(b.networks, '')
    FROM bcast b
    JOIN event_xref x ON x.espn_event_id = b.espn_event_id
   WHERE x.tevo_event_id = z.event_id
     AND (p_capture_date IS NULL OR z.capture_date = p_capture_date);

  RETURN v_rows;
END $$;

REVOKE ALL ON FUNCTION enrich_zone_price_observations(date) FROM public;

-- Backfill (broadcast group is a no-op until espn-collect re-snapshots events
-- with the new meta.broadcast; the other 7 groups re-run harmlessly).
SELECT enrich_zone_price_observations(NULL);

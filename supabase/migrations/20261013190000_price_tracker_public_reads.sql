-- Migration 20261013190000 · level:public-read · lane:D1 (operator-routed 2026-10-13) · writes:price_tracker_category(),price_tracker_events(),price_tracker_event(),price_tracker_search() · reads:events,latest_event_metrics,event_metrics,event_listing_snapshot_daily,section_metrics,performer_metadata,v_event_weather_with_fallback · pre:none
--
-- ============================================================================
-- Migration 20261013190000 — public ticket-price tracker (/prices)
--
-- Lane:     D1 (public, no-login surface) · operator-directed 2026-10-13
--           ("lets build this site, or a version" + "this is public domain")
-- Touches:  price_tracker_category(text,text)                 (W, new; IMMUTABLE)
--           price_tracker_events(bigint,bigint,text,text,date,date,text,int) (W, new)
--           price_tracker_event(bigint)                       (W, new)
--           price_tracker_search(text,int)                    (W, new)
-- Pre-reqs: none (reads existing tables/views only)
--
-- Already applied to prod · via MCP 2026-10-13 under operator direction
--   ("Apply now"). Verified post-apply on the same samples as the pre-apply
--   read-only dry runs: venue 33372 -> 21 upcoming (Mercedes-Benz Stadium,
--   min get-in $32.24); NFL next 7d -> 15; event 3226757 -> 360 history
--   points, 6 zones, forecast 'flat'; search 'atlanta' -> 6 performers /
--   6 venues; missing event -> NULL. EXECUTE: service_role only (anon and
--   authenticated = false on all four).
--
-- WHY: /prices is a public get-in price tracker (home table, event page with
--   price history, performer + venue pages). The pages are served by
--   routers/prices.py, which calls these with the SERVICE ROLE — so the
--   functions are plain SECURITY INVOKER (no SECDEF, no email gate) and are
--   REVOKED from PUBLIC/anon/authenticated. Nothing new is reachable through
--   PostgREST by an anonymous or logged-in client.
--
-- WHAT IS EXPOSED (via the router, to the public): market data only — event
--   name/date/venue/performer, the EVO get-in price + its history, per-zone
--   get-in, weather, and the naive 24h forecast direction. NEVER owned
--   inventory, owned counts, orders, brokerage names or wholesale prices.
--
-- DATA SOURCE: "get-in" = event_metrics.getin_price (EVO retail, per ticket,
--   no buyer fees). History = event_metrics captures, prefixed by the 3x/day
--   event_listing_snapshot_daily.evo_retail_getin ONLY for dates before the
--   event's first event_metrics capture — after that, the daily snapshot
--   re-copies the last known EVO value and would draw a fake "checked" line.
--   ⚠ As of 2026-10-13 the terminal listing pollers are paused (mig
--   20260927043400, N2S priority), so captured_at is ~2026-09-27 for nearly
--   every event; the pages show "checked N ago" from captured_at, honestly.
--
-- Rollback: DROP FUNCTION each of the four (no data written anywhere).
-- ============================================================================

-- Broad category for home-page chips + filters. Team events mostly carry the
-- generic event_type 'game', so the performer's ESPN league wins when present.
CREATE OR REPLACE FUNCTION public.price_tracker_category(p_event_type text, p_league text DEFAULT NULL)
RETURNS text
LANGUAGE sql IMMUTABLE
SET search_path = public, pg_temp
AS $$
  SELECT CASE
    WHEN upper(p_league) IN ('NFL','MLB','NBA','NHL','WNBA','MLS') THEN lower(p_league)
    WHEN p_event_type = 'nfl'                                  THEN 'nfl'
    WHEN p_event_type IN ('mlb')                               THEN 'mlb'
    WHEN p_event_type IN ('nba')                               THEN 'nba'
    WHEN p_event_type IN ('nhl')                               THEN 'nhl'
    WHEN p_event_type IN ('wnba')                              THEN 'wnba'
    WHEN p_event_type IN ('mls-major-league-soccer')           THEN 'mls'
    WHEN p_event_type LIKE 'ncaa%'                             THEN 'college'
    WHEN p_event_type IN ('concert','concerts','rock-pop','country-folk','rap-hip-hop',
                          'alternative-rock','indie-music','hard-rock-metal','latin',
                          'r-b-urban-soul','jazz-blues','dance-electronic','k-pop','j-pop',
                          'reggae','classical','world-music','festivals','new-age-spiritual',
                          'dj','opera')
      OR p_event_type LIKE 'festivals-%'                       THEN 'concerts'
    WHEN p_event_type IN ('broadway-musicals','broadway-on-tour','broadway-plays','musicals',
                          'plays','off-broadway','theatre','miscellaneous-theatre',
                          'ballet-dance','cabaret','las-vegas-shows','magic','burlesque')
                                                               THEN 'theater'
    WHEN p_event_type IN ('comedy')                            THEN 'comedy'
    WHEN p_event_type IN ('baseball','basketball','football','hockey','soccer','sports',
                          'boxing','fighting','mixed-martial-arts-mma','wrestling','wwe',
                          'tennis','golf','pga','lpga','motorsports','nascar','formula-1',
                          'indycar-series','auto-racing','horse-racing','rugby','lacrosse',
                          'volleyball','english-premier-league','nwsl','ahl','echl','minor-league',
                          'world-cup','monster-trucks','rodeo','supercross','extreme-sports','game')
                                                               THEN 'sports'
    ELSE 'other'
  END
$$;

-- Event list for the home / performer / venue tables.
--   p_when      'upcoming' (default) | 'past' | 'all'
--   p_day_from / p_day_to  local-date window (inclusive) on occurs_at_local
--   p_category  a price_tracker_category() value, or NULL for all
--   p_sort      'price' (get-in desc, default) | 'date' | 'popular'
-- Returns {entity, total, rows[]}. Only rows with a get-in price unless scoped
-- to a performer/venue (those pages list every event, get-in or not).
CREATE OR REPLACE FUNCTION public.price_tracker_events(
  p_performer_id bigint DEFAULT NULL,
  p_venue_id     bigint DEFAULT NULL,
  p_category     text   DEFAULT NULL,
  p_when         text   DEFAULT 'upcoming',
  p_day_from     date   DEFAULT NULL,
  p_day_to       date   DEFAULT NULL,
  p_sort         text   DEFAULT 'price',
  p_limit        int    DEFAULT 100
)
RETURNS jsonb
LANGUAGE sql STABLE
SET search_path = public, pg_temp
AS $$
  WITH params AS (
    SELECT to_char(current_date, 'YYYY-MM-DD')                       AS today,
           to_char(p_day_from, 'YYYY-MM-DD')                         AS d_from,
           to_char(p_day_to, 'YYYY-MM-DD')                           AS d_to,
           least(greatest(coalesce(p_limit, 100), 1), 500)           AS lim,
           (p_performer_id IS NOT NULL OR p_venue_id IS NOT NULL)    AS scoped
  ),
  ev AS (
    SELECT e.id, e.name, e.occurs_at_local, e.venue_id, e.venue_name, e.venue_location,
           e.primary_performer_id, e.primary_performer_name, e.popularity_score,
           public.price_tracker_category(e.event_type, pm.espn_league) AS category,
           m.getin_price, m.captured_at
    FROM public.events e
    CROSS JOIN params p
    LEFT JOIN public.performer_metadata pm ON pm.performer_id = e.primary_performer_id
    LEFT JOIN public.latest_event_metrics m ON m.event_id = e.id AND m.getin_price > 0
    WHERE e.state <> 'ignored'
      AND e.occurs_at_local IS NOT NULL
      AND e.name !~* '(cancel+ed|parking)'
      AND (p_performer_id IS NULL OR e.primary_performer_id = p_performer_id
           OR p_performer_id = ANY (e.performer_ids))
      AND (p_venue_id IS NULL OR e.venue_id = p_venue_id)
      AND (p_category IS NULL OR public.price_tracker_category(e.event_type, pm.espn_league) = p_category)
      AND CASE coalesce(p_when, 'upcoming')
            WHEN 'past' THEN left(e.occurs_at_local, 10) <  p.today
            WHEN 'all'  THEN true
            ELSE             left(e.occurs_at_local, 10) >= p.today
          END
      AND (p.d_from IS NULL OR left(e.occurs_at_local, 10) >= p.d_from)
      AND (p.d_to   IS NULL OR left(e.occurs_at_local, 10) <= p.d_to)
      AND (p.scoped OR m.getin_price IS NOT NULL)
  ),
  page AS (
    SELECT ev.*
    FROM ev, params p
    ORDER BY
      CASE WHEN p_sort = 'date'    THEN ev.occurs_at_local END
        ASC  NULLS LAST,
      CASE WHEN p_sort = 'popular' THEN ev.popularity_score END
        DESC NULLS LAST,
      ev.getin_price DESC NULLS LAST,
      ev.occurs_at_local
    LIMIT (SELECT lim FROM params)
  ),
  rows AS (
    SELECT pg.*,
      (SELECT h.getin_price FROM public.event_metrics h
        WHERE h.event_id = pg.id AND h.captured_at <= now() - interval '3 days'  AND h.getin_price > 0
        ORDER BY h.captured_at DESC LIMIT 1) AS g3,
      (SELECT h.getin_price FROM public.event_metrics h
        WHERE h.event_id = pg.id AND h.captured_at <= now() - interval '7 days'  AND h.getin_price > 0
        ORDER BY h.captured_at DESC LIMIT 1) AS g7,
      (SELECT h.getin_price FROM public.event_metrics h
        WHERE h.event_id = pg.id AND h.captured_at <= now() - interval '14 days' AND h.getin_price > 0
        ORDER BY h.captured_at DESC LIMIT 1) AS g14,
      (SELECT h.getin_price FROM public.event_metrics h
        WHERE h.event_id = pg.id AND h.captured_at <= now() - interval '30 days' AND h.getin_price > 0
        ORDER BY h.captured_at DESC LIMIT 1) AS g30
    FROM page pg
  )
  SELECT jsonb_build_object(
    'entity', CASE
      WHEN p_performer_id IS NOT NULL THEN (
        SELECT jsonb_build_object('kind', 'performer', 'id', p_performer_id,
                 'name', coalesce(
                   (SELECT pm.name FROM public.performer_metadata pm WHERE pm.performer_id = p_performer_id),
                   (SELECT e.primary_performer_name FROM public.events e
                     WHERE e.primary_performer_id = p_performer_id
                     ORDER BY e.occurs_at_local DESC LIMIT 1))))
      WHEN p_venue_id IS NOT NULL THEN (
        SELECT jsonb_build_object('kind', 'venue', 'id', p_venue_id,
                 'name', e.venue_name, 'location', e.venue_location)
        FROM public.events e WHERE e.venue_id = p_venue_id
        ORDER BY e.occurs_at_local DESC LIMIT 1)
    END,
    'total', (SELECT count(*) FROM ev),
    'min_getin', (SELECT min(getin_price) FROM ev),
    'rows', coalesce((
      SELECT jsonb_agg(jsonb_build_object(
        'id', r.id, 'name', r.name, 'occurs_at_local', r.occurs_at_local,
        'venue_id', r.venue_id, 'venue_name', r.venue_name, 'venue_location', r.venue_location,
        'performer_id', r.primary_performer_id, 'performer_name', r.primary_performer_name,
        'category', r.category,
        'getin', r.getin_price, 'captured_at', r.captured_at,
        'change', jsonb_build_object(
          '3d',  CASE WHEN r.g3  > 0 AND r.getin_price IS NOT NULL THEN round((r.getin_price - r.g3)  / r.g3  * 100, 1) END,
          '7d',  CASE WHEN r.g7  > 0 AND r.getin_price IS NOT NULL THEN round((r.getin_price - r.g7)  / r.g7  * 100, 1) END,
          '14d', CASE WHEN r.g14 > 0 AND r.getin_price IS NOT NULL THEN round((r.getin_price - r.g14) / r.g14 * 100, 1) END,
          '30d', CASE WHEN r.g30 > 0 AND r.getin_price IS NOT NULL THEN round((r.getin_price - r.g30) / r.g30 * 100, 1) END)
      ) ORDER BY
          CASE WHEN p_sort = 'date'    THEN r.occurs_at_local END ASC NULLS LAST,
          CASE WHEN p_sort = 'popular' THEN r.popularity_score END DESC NULLS LAST,
          r.getin_price DESC NULLS LAST, r.occurs_at_local)
      FROM rows r), '[]'::jsonb)
  )
$$;

-- One event: header, current get-in + 3-day change, price history, per-zone
-- history + current zone table, weather, forecast direction.
CREATE OR REPLACE FUNCTION public.price_tracker_event(p_event_id bigint)
RETURNS jsonb
LANGUAGE sql STABLE
SET search_path = public, pg_temp
AS $$
  WITH e AS (
    SELECT ev.id, ev.name, ev.occurs_at_local, ev.venue_id, ev.venue_name, ev.venue_location,
           ev.primary_performer_id, ev.primary_performer_name,
           public.price_tracker_category(ev.event_type, pm.espn_league) AS category
    FROM public.events ev
    LEFT JOIN public.performer_metadata pm ON pm.performer_id = ev.primary_performer_id
    WHERE ev.id = p_event_id AND ev.state <> 'ignored'
  ),
  cur AS (
    SELECT m.getin_price, m.captured_at, m.tickets_count
    FROM public.latest_event_metrics m WHERE m.event_id = p_event_id
  ),
  prior3 AS (
    SELECT h.getin_price, h.captured_at FROM public.event_metrics h
    WHERE h.event_id = p_event_id AND h.captured_at <= now() - interval '3 days' AND h.getin_price > 0
    ORDER BY h.captured_at DESC LIMIT 1
  ),
  first_em AS (
    SELECT min(captured_at) AS t FROM public.event_metrics WHERE event_id = p_event_id
  ),
  hist AS (
    SELECT h.captured_at AS t, h.getin_price AS v
    FROM public.event_metrics h
    WHERE h.event_id = p_event_id AND h.getin_price > 0
    UNION ALL
    SELECT d.captured_at, d.evo_retail_getin
    FROM public.event_listing_snapshot_daily d, first_em f
    WHERE d.event_id = p_event_id AND d.evo_retail_getin > 0
      AND (f.t IS NULL OR d.captured_at < f.t)
  ),
  zcap AS (
    SELECT s.zone, s.captured_at, min(s.getin_price) AS getin,
           sum(s.tickets_count) AS tix
    FROM public.section_metrics s
    WHERE s.event_id = p_event_id AND s.zone IS NOT NULL AND s.zone <> 'unmapped' AND s.getin_price > 0
      AND NOT coalesce(s.is_ancillary, false)
    GROUP BY s.zone, s.captured_at
  ),
  zlatest AS (
    SELECT DISTINCT ON (zone) zone, captured_at, getin, tix
    FROM zcap ORDER BY zone, captured_at DESC
  ),
  ztop AS (
    SELECT zone FROM zlatest ORDER BY tix DESC NULLS LAST LIMIT 8
  ),
  w AS (
    SELECT is_indoor, weather_kind, temp_f, precip_pct, wind_mph, weather_summary
    FROM public.v_event_weather_with_fallback WHERE tevo_event_id = p_event_id LIMIT 1
  ),
  fc AS (
    SELECT public.predict_event_median_24h(p_event_id) AS j
  )
  SELECT CASE WHEN NOT EXISTS (SELECT 1 FROM e) THEN NULL ELSE jsonb_build_object(
    'event', (SELECT jsonb_build_object(
        'id', e.id, 'name', e.name, 'occurs_at_local', e.occurs_at_local,
        'venue_id', e.venue_id, 'venue_name', e.venue_name, 'venue_location', e.venue_location,
        'performer_id', e.primary_performer_id, 'performer_name', e.primary_performer_name,
        'category', e.category) FROM e),
    'current', (SELECT jsonb_build_object(
        'getin', c.getin_price, 'captured_at', c.captured_at, 'tickets', c.tickets_count,
        'prior_3d', p.getin_price,
        'change_3d_pct', CASE WHEN p.getin_price > 0 AND c.getin_price > 0
                              THEN round((c.getin_price - p.getin_price) / p.getin_price * 100, 1) END)
      FROM (SELECT 1) one LEFT JOIN cur c ON true LEFT JOIN prior3 p ON true),
    'history', coalesce((SELECT jsonb_agg(jsonb_build_array(
        extract(epoch FROM t)::bigint, v) ORDER BY t) FROM hist), '[]'::jsonb),
    'zones', coalesce((SELECT jsonb_agg(jsonb_build_object(
        'zone', zl.zone, 'getin', zl.getin, 'tickets', zl.tix, 'captured_at', zl.captured_at,
        'history', (SELECT jsonb_agg(jsonb_build_array(extract(epoch FROM z.captured_at)::bigint, z.getin)
                     ORDER BY z.captured_at) FROM zcap z WHERE z.zone = zl.zone))
        ORDER BY zl.getin)
      FROM zlatest zl JOIN ztop t ON t.zone = zl.zone), '[]'::jsonb),
    'weather', (SELECT to_jsonb(w) FROM w),
    'forecast', (SELECT jsonb_build_object(
        'dte_days', (fc.j->>'dte_days')::int,
        'direction', CASE
          WHEN (fc.j->>'dte_days') IS NULL OR (fc.j->>'dte_days')::int < 0 THEN 'closed'
          WHEN (fc.j->>'current_median') IS NULL THEN 'unknown'
          WHEN (fc.j->>'predicted_median_24h')::numeric > (fc.j->>'current_median')::numeric THEN 'increase'
          WHEN (fc.j->>'predicted_median_24h')::numeric < (fc.j->>'current_median')::numeric THEN 'decrease'
          ELSE 'flat' END,
        'spike_up_prob_pct', (fc.j->>'spike_up_prob_pct')::numeric,
        'sample_n', (fc.j->>'sample_n')::int) FROM fc)
  ) END
$$;

-- Search box: performers, venues, events with an upcoming date matching p_q.
CREATE OR REPLACE FUNCTION public.price_tracker_search(p_q text, p_limit int DEFAULT 8)
RETURNS jsonb
LANGUAGE sql STABLE
SET search_path = public, pg_temp
AS $$
  WITH q AS (
    SELECT '%' || replace(replace(replace(trim(p_q), '\', '\\'), '%', '\%'), '_', '\_') || '%' AS pat,
           least(greatest(coalesce(p_limit, 8), 1), 25) AS lim,
           to_char(current_date, 'YYYY-MM-DD') AS today
  ),
  up AS (
    SELECT e.* FROM public.events e, q
    WHERE e.state <> 'ignored' AND left(e.occurs_at_local, 10) >= q.today
      AND e.name !~* '(cancel+ed|parking)'
      AND (e.name ILIKE q.pat OR e.primary_performer_name ILIKE q.pat OR e.venue_name ILIKE q.pat)
  )
  SELECT CASE WHEN length(trim(coalesce(p_q, ''))) < 2 THEN
    jsonb_build_object('performers', '[]'::jsonb, 'venues', '[]'::jsonb, 'events', '[]'::jsonb)
  ELSE jsonb_build_object(
    'performers', coalesce((SELECT jsonb_agg(x ORDER BY x.n DESC) FROM (
        SELECT up.primary_performer_id AS id, max(up.primary_performer_name) AS name, count(*) AS n
        FROM up, q WHERE up.primary_performer_name ILIKE q.pat AND up.primary_performer_id IS NOT NULL
        GROUP BY up.primary_performer_id ORDER BY count(*) DESC LIMIT (SELECT lim FROM q)) x), '[]'::jsonb),
    'venues', coalesce((SELECT jsonb_agg(x ORDER BY x.n DESC) FROM (
        SELECT up.venue_id AS id, max(up.venue_name) AS name, max(up.venue_location) AS location, count(*) AS n
        FROM up, q WHERE up.venue_name ILIKE q.pat AND up.venue_id IS NOT NULL
        GROUP BY up.venue_id ORDER BY count(*) DESC LIMIT (SELECT lim FROM q)) x), '[]'::jsonb),
    'events', coalesce((SELECT jsonb_agg(x ORDER BY x.occurs_at_local) FROM (
        SELECT up.id, up.name, up.occurs_at_local, up.venue_name
        FROM up, q WHERE up.name ILIKE q.pat
        ORDER BY up.popularity_score DESC NULLS LAST LIMIT (SELECT lim FROM q)) x), '[]'::jsonb)
  ) END
$$;

-- Service role only: the public reaches these through routers/prices.py.
REVOKE ALL ON FUNCTION public.price_tracker_category(text, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.price_tracker_events(bigint, bigint, text, text, date, date, text, int) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.price_tracker_event(bigint) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.price_tracker_search(text, int) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.price_tracker_category(text, text) TO service_role;
GRANT EXECUTE ON FUNCTION public.price_tracker_events(bigint, bigint, text, text, date, date, text, int) TO service_role;
GRANT EXECUTE ON FUNCTION public.price_tracker_event(bigint) TO service_role;
GRANT EXECUTE ON FUNCTION public.price_tracker_search(text, int) TO service_role;

-- Migration 20261023052000 · level:feature · lane:D0 (MCP) + A1 (read RPC) · writes:mcp_team_report()(new),index events_primary_performer_occurs_idx · reads:events,event_metrics,seatgeek_event_metrics,seatgeek_sales_snapshots,gotickets_listings_snapshots,performer_sales_daily,performer_metrics_daily,listing_obs_section_daily,performer_espn_team_xref,v_team_roster_full,v_espn_injuries_current,v_team_recent_results,espn_news,reddit_posts,prediction_markets,prediction_market_xref,weather_observations,espn_transactions,player_price_effect,listings_poll_pins,espn_team_snapshots · pre:20261023051000,20261023044000
--
-- ============================================================================
-- Migration 20261023052000 — mcp_team_report: one call = a team's market +
--   context ("Knicks since we started polling")
--
-- Operator 2026-10-23: the MCP should return, for the Knicks (and any team),
-- listing trends and metrics, ESPN data, Reddit, Kalshi, roster and weather,
-- "since we started polling", tweakable by the caller. Joe: "u dont want to do it
-- raw" — so this returns processed metrics (daily get-in / median / inventory,
-- sales medians), never raw listings, and never our own book (no owned_* fields).
--
-- mcp_team_report(p_team, p_since, p_home_only, p_max_events, p_news_limit)
--   p_team       TEvo performer id ("16303") or exact team name ("New York Knicks")
--   p_since      trend start; default = first EVO capture on the team's upcoming
--                games ("since we started polling"), capped at 180 days back
--   p_home_only  default true (home games = team is primary performer)
--   p_max_events upcoming games returned with per-game trends (1..41, default 10)
--   p_news_limit ESPN + Reddit items each (1..25, default 8)
-- Each game carries `data_quality` so a caller never prices off missing data:
--   live (EVO capture < 6 h), stale (older), none (never polled).
-- ============================================================================

-- Team lookups (primary performer → upcoming games) had no index: 150 k-row scan per call.
CREATE INDEX IF NOT EXISTS events_primary_performer_occurs_idx
  ON public.events (primary_performer_id, occurs_at_local);

CREATE OR REPLACE FUNCTION public.mcp_team_report(
  p_team        text,
  p_since       date    DEFAULT NULL,
  p_home_only   boolean DEFAULT true,
  p_max_events  integer DEFAULT 10,
  p_news_limit  integer DEFAULT 8)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
SET statement_timeout = '25s'
AS $$
DECLARE
  v_pid      bigint;
  v_name     text;
  v_espn     text;
  v_league   text;
  v_since    date;
  v_max      integer := LEAST(GREATEST(coalesce(p_max_events, 10), 1), 41);
  v_news     integer := LEAST(GREATEST(coalesce(p_news_limit, 8), 1), 25);
  v_events   bigint[];
  v_out      jsonb;
BEGIN
  IF current_user NOT IN ('service_role','postgres','supabase_admin') THEN
    RAISE EXCEPTION 'forbidden: mcp_team_report is service-only' USING ERRCODE='42501';
  END IF;

  IF btrim(coalesce(p_team, '')) ~ '^\d+$' THEN
    v_pid := btrim(p_team)::bigint;
  ELSE
    SELECT e.primary_performer_id INTO v_pid
      FROM public.events e
     WHERE lower(e.primary_performer_name) = lower(btrim(p_team))
       AND e.occurs_at_local >= to_char(now(), 'YYYY-MM-DD')
     GROUP BY 1 ORDER BY count(*) DESC LIMIT 1;
  END IF;
  IF v_pid IS NULL THEN
    RETURN jsonb_build_object('error', 'team not found — pass the TEvo performer id or the exact team name (use `search`)');
  END IF;

  SELECT max(e.primary_performer_name) INTO v_name FROM public.events e WHERE e.primary_performer_id = v_pid;
  SELECT x.espn_team_id, x.espn_league INTO v_espn, v_league
    FROM public.performer_espn_team_xref x WHERE x.tevo_performer_id = v_pid LIMIT 1;

  -- Upcoming games: home = team is primary performer (indexed); else any event listing the team.
  IF coalesce(p_home_only, true) THEN
    SELECT array_agg(id ORDER BY occ) INTO v_events FROM (
      SELECT e.id, e.occurs_at_local AS occ
        FROM public.events e
       WHERE e.primary_performer_id = v_pid
         AND e.occurs_at_local >= to_char(now() - interval '3 hours', 'YYYY-MM-DD"T"HH24')
         AND coalesce(e.state, 'shown') <> 'ignored'
       ORDER BY e.occurs_at_local LIMIT v_max) q;
  ELSE
    SELECT array_agg(id ORDER BY occ) INTO v_events FROM (
      SELECT e.id, e.occurs_at_local AS occ
        FROM public.events e
       WHERE left(e.occurs_at_local, 10) >= to_char(now() - interval '3 hours', 'YYYY-MM-DD')
         AND (e.primary_performer_id = v_pid OR v_pid::text = ANY (e.performer_ids::text[]))
         AND coalesce(e.state, 'shown') <> 'ignored'
       ORDER BY e.occurs_at_local LIMIT v_max) q;
  END IF;

  v_since := coalesce(p_since,
    -- per-game first capture via the (event_id, captured_at) PK; min() over ANY(array)
    -- walks the captured_at index instead and times out.
    (SELECT min(f.first_at)::date
       FROM unnest(v_events) AS u(eid)
       CROSS JOIN LATERAL (SELECT m.captured_at AS first_at FROM public.event_metrics m
                            WHERE m.event_id = u.eid ORDER BY m.captured_at LIMIT 1) f),
    current_date - 30);
  v_since := GREATEST(v_since, current_date - 180);

  SELECT jsonb_build_object(
    'team', jsonb_build_object('performer_id', v_pid, 'name', v_name, 'espn_team_id', v_espn, 'league', v_league),
    'since', v_since,
    'polling', (SELECT jsonb_agg(jsonb_build_object('pin', p.pin_key, 'venue', p.venue_name, 'sources', p.sources,
                                                    'enabled', p.enabled, 'pinned_at', p.created_at))
                  FROM public.listings_poll_pins p WHERE p.performer_id = v_pid),
    -- espn_team_snapshots direct: ESPN team ids repeat across leagues (18 = Knicks AND an NHL
    -- team) and v_espn_team_state keeps one row per id, so it can return the wrong league.
    'standing', (SELECT jsonb_build_object('record', s.record_summary, 'standing', s.standing_summary,
                         'wins', s.wins, 'losses', s.losses, 'win_pct', s.win_pct, 'games_back', s.games_back,
                         'conference_rank', s.conference_rank, 'division_rank', s.division_rank,
                         'streak', s.streak, 'as_of', s.captured_at)
                   FROM public.espn_team_snapshots s
                  WHERE s.espn_team_id = v_espn AND lower(s.espn_league) = lower(v_league)
                  ORDER BY s.captured_at DESC LIMIT 1),
    'games', (
      SELECT coalesce(jsonb_agg(g ORDER BY g->>'occurs_at_local'), '[]'::jsonb) FROM (
        SELECT jsonb_build_object(
          'event_id', e.id, 'name', e.name, 'occurs_at_local', e.occurs_at_local,
          'days_out', (left(e.occurs_at_local, 10)::date - current_date),
          'evo_now', (SELECT jsonb_build_object('captured_at', m.captured_at, 'tickets', m.tickets_count,
                              'listings', m.groups_count, 'getin', m.getin_price, 'p25', m.retail_p25,
                              'median', m.retail_median, 'p75', m.retail_p75)
                        FROM public.event_metrics m WHERE m.event_id = e.id
                       ORDER BY m.captured_at DESC LIMIT 1),
          'sg_now', (SELECT jsonb_build_object('captured_at', s.captured_at, 'listings', s.listings_all_count,
                              'tickets', s.listings_all_tickets, 'getin', s.listings_all_min,
                              'median', s.listings_all_median, 'p75', s.listings_all_p75)
                       FROM public.seatgeek_event_metrics s WHERE s.tevo_event_id = e.id
                      ORDER BY s.captured_at DESC LIMIT 1),
          'gt_seen_24h', (SELECT jsonb_build_object('listings', count(*), 'getin', min(price),
                                   'median', round(percentile_cont(0.5) WITHIN GROUP (ORDER BY price)::numeric, 2))
                            FROM (SELECT DISTINCT ON (g.gt_listing_id) g.all_in_price AS price
                                    FROM public.gotickets_listings_snapshots g
                                   WHERE g.tevo_event_id = e.id AND g.captured_at > now() - interval '24 hours'
                                     AND g.all_in_price > 0
                                   ORDER BY g.gt_listing_id, g.captured_at DESC) gl),
          'sg_sales_30d', (SELECT jsonb_build_object('sales', count(*), 'tickets', sum(q),
                                    'median', round(percentile_cont(0.5) WITHIN GROUP (ORDER BY p)::numeric, 2),
                                    'last_sale_at', max(t))
                             FROM (SELECT DISTINCT ON (ss.sg_sale_id) ss.broadcast_price AS p,
                                          coalesce(ss.quantity, 1) AS q, ss.sale_at_utc AS t
                                     FROM public.seatgeek_sales_snapshots ss
                                    WHERE ss.tevo_event_id = e.id AND ss.sale_at_utc > now() - interval '30 days'
                                    ORDER BY ss.sg_sale_id, ss.pulled_at DESC) sl),
          'trend_daily', (SELECT jsonb_agg(jsonb_build_object('day', d.day, 'getin', d.getin, 'median', d.median,
                                                              'tickets', d.tickets) ORDER BY d.day)
                            FROM (SELECT DISTINCT ON (m.captured_at::date) m.captured_at::date AS day,
                                         m.getin_price AS getin, m.retail_median AS median, m.tickets_count AS tickets
                                    FROM public.event_metrics m
                                   WHERE m.event_id = e.id AND m.captured_at >= v_since
                                   ORDER BY m.captured_at::date, m.captured_at DESC) d),
          'kalshi', (SELECT jsonb_agg(jsonb_build_object('market', pm.market_id, 'title', pm.title,
                                       'team', pm.team_name, 'yes_price', pm.yes_price, 'volume', pm.volume,
                                       'updated_at', pm.updated_at))
                       FROM public.prediction_market_xref x
                       JOIN public.prediction_markets pm ON pm.source = x.source AND pm.market_id = x.market_id
                      WHERE x.tevo_event_id = e.id AND x.source = 'kalshi'),
          -- weather_observations direct on (tevo_venue_id, observed_at): forecast/observation
          -- nearest the start (v_event_weather_with_fallback scans every event).
          'weather', (SELECT jsonb_build_object('observed_at', w.observed_at, 'forecast', w.is_forecast,
                                'temp_f', w.temp_f, 'precip_pct', w.precip_pct, 'wind_mph', w.wind_mph,
                                'summary', w.weather_summary)
                        FROM public.weather_observations w
                       WHERE w.tevo_venue_id = e.venue_id
                         AND w.observed_at BETWEEN e.occurs_at_local::timestamptz - interval '12 hours'
                                               AND e.occurs_at_local::timestamptz + interval '12 hours'
                       ORDER BY w.is_forecast, abs(extract(epoch FROM (w.observed_at - e.occurs_at_local::timestamptz)))
                       LIMIT 1),
          'data_quality', CASE
             WHEN NOT EXISTS (SELECT 1 FROM public.event_metrics m WHERE m.event_id = e.id) THEN 'none'
             WHEN (SELECT max(m.captured_at) FROM public.event_metrics m WHERE m.event_id = e.id)
                  > now() - interval '6 hours' THEN 'live'
             ELSE 'stale' END
        ) AS g
          FROM public.events e WHERE e.id = ANY (v_events)
      ) gg),
    'team_market_daily', (SELECT jsonb_agg(jsonb_build_object('day', d.snapshot_date, 'split', d.split,
                                   'events', d.event_count, 'getin_median', d.getin_median,
                                   'price_median', d.price_median, 'price_p90', d.price_p90) ORDER BY d.snapshot_date)
                            FROM public.performer_metrics_daily d
                           WHERE d.performer_id = v_pid AND d.snapshot_date >= v_since AND d.split = 'all'),
    'sales_daily', (SELECT jsonb_agg(jsonb_build_object('day', s.sale_day, 'source', s.source, 'events', s.events,
                             'sales', s.sales, 'tickets', s.tickets, 'median', s.median_price,
                             'p25', s.p25_price, 'p75', s.p75_price) ORDER BY s.sale_day, s.source)
                      FROM public.performer_sales_daily s
                     WHERE s.performer_id = v_pid AND s.sale_day >= v_since),
    'recent_results', (SELECT jsonb_agg(r ORDER BY r->>'captured_at' DESC) FROM (
                         SELECT jsonb_build_object('captured_at', rr.captured_at, 'home', rr.is_home,
                                  'score', rr.team_score || '-' || rr.opp_score, 'result', rr.result,
                                  'spread', rr.spread_line, 'covered', rr.covered_spread) AS r
                           FROM public.v_team_recent_results rr
                          WHERE rr.tevo_performer_id = v_pid
                          ORDER BY rr.captured_at DESC LIMIT 10) q),
    'roster', (SELECT jsonb_agg(jsonb_build_object('name', r.display_name, 'jersey', r.jersey,
                       'position', r.position_abbr, 'age', r.age, 'status', r.status,
                       'experience_years', r.experience_years) ORDER BY r.display_name)
                 FROM public.v_team_roster_full r WHERE r.tevo_performer_id = v_pid),
    'injuries', (SELECT jsonb_agg(jsonb_build_object('name', i.athlete_name, 'position', i.position,
                         'status', i.status, 'injury', i.injury_type, 'comment', i.short_comment,
                         'return_date', i.return_date, 'as_of', i.injury_as_of))
                   FROM public.v_espn_injuries_current i
                  WHERE i.espn_team_id = v_espn AND lower(i.espn_league) = lower(v_league)),
    'transactions', (SELECT jsonb_agg(t ORDER BY t->>'date' DESC) FROM (
                       SELECT jsonb_build_object('date', tx.txn_date, 'description', tx.description) AS t
                         FROM public.espn_transactions tx
                        WHERE tx.espn_team_id = v_espn AND lower(tx.espn_league) = lower(v_league)
                          AND tx.txn_date > now() - interval '60 days'
                        ORDER BY tx.txn_date DESC LIMIT 15) q),
    'player_value', (SELECT jsonb_agg(jsonb_build_object('name', pe.athlete_name, 'position', pe.position_abbr,
                             'games_played', pe.games_played, 'games_missed', pe.games_missed,
                             'ticket_price_lift_pct', pe.lift_resid_pct, 'confidence', pe.confidence)
                             ORDER BY pe.lift_resid_pct DESC NULLS LAST)
                       FROM public.player_price_effect pe
                      WHERE pe.espn_league = v_league
                        AND pe.espn_athlete_id IN (SELECT r.espn_athlete_id::text FROM public.v_team_roster_full r
                                                    WHERE r.tevo_performer_id = v_pid)),
    'espn_news', (SELECT jsonb_agg(n ORDER BY n->>'published_at' DESC) FROM (
                    SELECT jsonb_build_object('headline', n.headline, 'description', n.description,
                             'url', n.url, 'published_at', n.published_at) AS n
                      FROM public.espn_news n
                     WHERE n.espn_team_id = v_espn AND lower(n.espn_league) = lower(v_league)
                     ORDER BY n.published_at DESC NULLS LAST LIMIT v_news) q),
    'reddit', (SELECT jsonb_agg(r ORDER BY (r->>'score')::int DESC) FROM (
                 SELECT jsonb_build_object('subreddit', rp.subreddit, 'title', rp.title, 'score', rp.score,
                          'comments', rp.num_comments, 'created_utc', rp.created_utc, 'url', rp.url) AS r
                   FROM public.reddit_posts rp
                  WHERE rp.tevo_performer_id = v_pid AND rp.created_utc > now() - interval '7 days'
                  ORDER BY rp.score DESC NULLS LAST LIMIT v_news) q),
    'kalshi_futures', (SELECT jsonb_agg(jsonb_build_object('source', pm.source, 'title', pm.title,
                               'yes_price', pm.yes_price, 'volume', pm.volume, 'close_time', pm.close_time))
                         FROM public.prediction_market_xref x
                         JOIN public.prediction_markets pm ON pm.source = x.source AND pm.market_id = x.market_id
                        WHERE x.tevo_performer_id = v_pid AND x.tevo_event_id IS NULL
                          AND coalesce(pm.status, 'open') NOT IN ('settled', 'closed', 'finalized')),
    'generated_at', now()
  ) INTO v_out;

  RETURN v_out;
END $$;
REVOKE ALL ON FUNCTION public.mcp_team_report(text, date, boolean, integer, integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.mcp_team_report(text, date, boolean, integer, integer) TO service_role;

-- VERIFY: SELECT jsonb_pretty(public.mcp_team_report('16303'));
-- ROLLBACK: DROP FUNCTION public.mcp_team_report(text, date, boolean, integer, integer);

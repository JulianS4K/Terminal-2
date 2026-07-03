-- Cast price reference: one row per team/show with home + away median price.
-- SEPARATE from performer_metadata / EVO performer tables by design — this is a
-- pricing-anchor rollup (road-draw value), not a catalog. Consumed by the pricing
-- model + terminal, and is the entity source for the Google-Trends cast-pool job
-- (per-person trends land in why_signals scope='performer').
--
-- entity_type: 'team' (sports) | 'show' (broadway)
-- away_median_price: median event retail_median across games where this team is the
--   VISITOR ("<away> at <home>") — i.e. how much this team lifts prices on the road.

CREATE TABLE IF NOT EXISTS cast_price_ref (
  cast_id               bigserial PRIMARY KEY,
  entity_type           text NOT NULL,          -- 'team' | 'show'
  entity_name           text NOT NULL,
  entity_key            text,                   -- espn_team_id / show_slug
  league                text,                   -- espn_league (teams); NULL for shows
  tevo_performer_id     bigint,
  home_events           int     DEFAULT 0,
  home_median_price     numeric,
  away_events           int     DEFAULT 0,
  away_median_price     numeric,                -- road-draw anchor (sports)
  overall_median_price  numeric,
  refreshed_at          timestamptz NOT NULL DEFAULT now(),
  UNIQUE (entity_type, entity_name)
);

CREATE INDEX IF NOT EXISTS cast_price_ref_type_idx   ON cast_price_ref (entity_type);
CREATE INDEX IF NOT EXISTS cast_price_ref_league_idx ON cast_price_ref (league);
CREATE INDEX IF NOT EXISTS cast_price_ref_perf_idx   ON cast_price_ref (tevo_performer_id);

-- Rebuildable rollup. Uses the latest event_metrics per event within a 45-day window.
CREATE OR REPLACE FUNCTION refresh_cast_price_ref() RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  WITH latest AS (
    SELECT DISTINCT ON (event_id) event_id, retail_median
    FROM event_metrics
    WHERE captured_at > now() - interval '45 days' AND retail_median IS NOT NULL
    ORDER BY event_id, captured_at DESC
  ),
  ev AS (
    SELECT e.id, e.name, e.primary_performer_id, e.primary_performer_name AS home_team,
           trim(split_part(e.name, ' at ', 1)) AS away_team, lm.retail_median
    FROM events e JOIN latest lm ON lm.event_id = e.id
  ),
  -- team universe = performers tagged with an espn_league (i.e. real sports teams)
  teams AS (
    SELECT performer_id, name, espn_league FROM performer_metadata WHERE espn_league IS NOT NULL
  ),
  home AS (
    SELECT t.performer_id, count(*) n,
           percentile_cont(0.5) WITHIN GROUP (ORDER BY ev.retail_median) med
    FROM teams t JOIN ev ON ev.primary_performer_id = t.performer_id
    GROUP BY t.performer_id
  ),
  away AS (
    SELECT t.performer_id, count(*) n,
           percentile_cont(0.5) WITHIN GROUP (ORDER BY ev.retail_median) med
    FROM teams t JOIN ev ON lower(ev.away_team) = lower(t.name) AND ev.name LIKE '% at %'
    GROUP BY t.performer_id
  ),
  team_rows AS (
    SELECT 'team'::text etype, t.name ename, t.performer_id::text ekey, t.espn_league league,
           t.performer_id tevo_pid,
           COALESCE(h.n,0) he, h.med hmed, COALESCE(a.n,0) ae, a.med amed,
           COALESCE(h.med, a.med) omed
    FROM teams t LEFT JOIN home h ON h.performer_id=t.performer_id
                 LEFT JOIN away a ON a.performer_id=t.performer_id
    WHERE h.n IS NOT NULL OR a.n IS NOT NULL
  ),
  show_rows AS (
    SELECT 'show'::text etype, s.title ename, s.show_slug ekey, NULL::text league,
           s.tevo_performer_id tevo_pid,
           count(ev.id)::int he,
           percentile_cont(0.5) WITHIN GROUP (ORDER BY ev.retail_median) hmed,
           0 ae, NULL::numeric amed,
           percentile_cont(0.5) WITHIN GROUP (ORDER BY ev.retail_median) omed
    FROM broadway_show_ref s
    JOIN ev ON s.event_name_pattern IS NOT NULL AND ev.name ILIKE '%'||s.event_name_pattern||'%'
    GROUP BY s.title, s.show_slug, s.tevo_performer_id
  )
  INSERT INTO cast_price_ref
    (entity_type, entity_name, entity_key, league, tevo_performer_id,
     home_events, home_median_price, away_events, away_median_price, overall_median_price, refreshed_at)
  SELECT etype, ename, ekey, league, tevo_pid,
         he, round(hmed,2), ae, round(amed,2), round(omed,2), now()
  FROM (SELECT * FROM team_rows UNION ALL SELECT * FROM show_rows) u
  ON CONFLICT (entity_type, entity_name) DO UPDATE SET
     entity_key=EXCLUDED.entity_key, league=EXCLUDED.league,
     tevo_performer_id=EXCLUDED.tevo_performer_id,
     home_events=EXCLUDED.home_events, home_median_price=EXCLUDED.home_median_price,
     away_events=EXCLUDED.away_events, away_median_price=EXCLUDED.away_median_price,
     overall_median_price=EXCLUDED.overall_median_price, refreshed_at=now();
END;
$$;

-- ============================================================================
-- Migration 20260509240000 — Home/away derivation + ESPN state fix + zone auto-assign
--
-- Three day-trader-driven additions:
--
-- (a) v_event_home_away — derives home + away performer from venue match.
--     Handles "Hawks at TD Garden" -> Celtics=home, Hawks=away because
--     TD Garden is in performer_home_venues for Celtics. Falls back to
--     events.primary_performer_id when no home match found.
--
-- (b) v_espn_team_state + v_espn_injuries_current — fixes the broken
--     _latest views that only carried content_hash, not actual fields.
--     Workaround for is_baseline bug: DISTINCT ON (id) ORDER BY captured_at
--     DESC always returns latest snapshot regardless of baseline flag.
--
-- (c) v_listing_zone_auto + v_section_to_curated_zone — auto-assigns
--     curated zones to listings via performer_zone_rules. Falls back to
--     numeric_fallback when no curated zone exists for (performer, venue).
--
-- (d) v_event_full_sports — single-row-per-event view extending v_event_full
--     with home/away identification + standings + injury counts + news +
--     pricing. The one query a sports day-trader actually wants.
-- ============================================================================

CREATE OR REPLACE VIEW v_event_home_away AS
WITH event_perfs AS (
  SELECT e.id AS tevo_event_id,
         e.venue_id  AS event_venue_id,
         e.primary_performer_id,
         e.primary_performer_name,
         pid::bigint AS performer_id
  FROM events e
  CROSS JOIN LATERAL unnest(coalesce(e.performer_ids, ARRAY[e.primary_performer_id])) AS pid
),
ranked AS (
  SELECT ep.tevo_event_id,
         ep.performer_id,
         ep.event_venue_id,
         pm.name AS performer_name,
         pm.espn_team_id,
         pm.espn_league,
         (phv.venue_id = ep.event_venue_id) AS is_home_match,
         ep.primary_performer_id,
         ep.primary_performer_name
  FROM event_perfs ep
  LEFT JOIN performer_metadata pm ON pm.performer_id = ep.performer_id
  LEFT JOIN performer_home_venues phv
         ON phv.performer_id = ep.performer_id
        AND phv.venue_id = ep.event_venue_id
),
home_pick AS (
  SELECT DISTINCT ON (tevo_event_id) tevo_event_id,
    performer_id   AS home_performer_id,
    performer_name AS home_performer_name,
    espn_team_id   AS home_espn_team_id,
    espn_league
  FROM ranked
  ORDER BY tevo_event_id,
           is_home_match DESC NULLS LAST,
           (performer_id = primary_performer_id) DESC,
           performer_id
),
away_pick AS (
  SELECT DISTINCT ON (r.tevo_event_id) r.tevo_event_id,
    r.performer_id   AS away_performer_id,
    r.performer_name AS away_performer_name,
    r.espn_team_id   AS away_espn_team_id
  FROM ranked r
  JOIN home_pick h ON h.tevo_event_id = r.tevo_event_id
  WHERE r.performer_id <> h.home_performer_id
  ORDER BY r.tevo_event_id, r.is_home_match ASC NULLS FIRST, r.performer_id
)
SELECT
  e.id AS tevo_event_id, e.name AS event_name, e.occurs_at_local::date AS event_date,
  e.venue_id, e.venue_name,
  hp.home_performer_id, hp.home_performer_name, hp.home_espn_team_id,
  hp.espn_league,
  ap.away_performer_id, ap.away_performer_name, ap.away_espn_team_id,
  (hp.home_performer_id = e.primary_performer_id) AS primary_is_home,
  (e.occurs_at_local::date - current_date) AS days_to_event
FROM events e
LEFT JOIN home_pick hp ON hp.tevo_event_id = e.id
LEFT JOIN away_pick ap ON ap.tevo_event_id = e.id;

CREATE OR REPLACE VIEW v_espn_team_state AS
SELECT DISTINCT ON (espn_team_id)
  espn_team_id, espn_league,
  wins, losses, ties, win_pct,
  games_back, playoff_seed, conference_rank, division_rank,
  record_summary, standing_summary, streak,
  captured_at AS state_as_of
FROM espn_team_snapshots
WHERE captured_at > now() - interval '30 days'
ORDER BY espn_team_id, captured_at DESC;

CREATE OR REPLACE VIEW v_espn_injuries_current AS
SELECT DISTINCT ON (athlete_id)
  espn_team_id, espn_league,
  athlete_id, athlete_name, position,
  status, injury_type, short_comment, long_comment, return_date,
  captured_at AS injury_as_of
FROM espn_injuries_snapshots
WHERE captured_at > now() - interval '14 days' AND status IS NOT NULL
ORDER BY athlete_id, captured_at DESC;

-- Section-range matcher (numeric-aware + text-aware)
CREATE OR REPLACE FUNCTION section_in_range(p_section text, p_from text, p_to text)
RETURNS boolean AS $$
DECLARE s_num int; f_num int; t_num int;
BEGIN
  IF p_section IS NULL OR p_from IS NULL OR p_to IS NULL THEN RETURN false; END IF;
  IF p_section ~ '^[0-9]+$' AND p_from ~ '^[0-9]+$' AND p_to ~ '^[0-9]+$' THEN
    s_num := p_section::int; f_num := p_from::int; t_num := p_to::int;
    RETURN s_num BETWEEN least(f_num, t_num) AND greatest(f_num, t_num);
  END IF;
  IF p_section = p_from OR p_section = p_to THEN RETURN true; END IF;
  RETURN lower(p_section) BETWEEN lower(p_from) AND lower(p_to)
      OR lower(p_section) BETWEEN lower(p_to)   AND lower(p_from);
END;
$$ LANGUAGE plpgsql IMMUTABLE;

CREATE OR REPLACE VIEW v_listing_zone_auto AS
SELECT
  ls.event_id AS tevo_event_id,
  ls.tevo_ticket_group_id,
  ls.section, ls.row, ls.captured_at,
  hp.home_performer_id,
  pz.id   AS zone_id,
  pz.name AS zone_name,
  pz.source AS zone_source,
  CASE WHEN pz.id IS NOT NULL THEN 'curated'
       WHEN ls.section ~ '^[0-9]+$' THEN 'numeric_fallback'
       ELSE 'unknown'
  END AS zone_assignment_method
FROM listings_snapshots ls
LEFT JOIN v_event_home_away hp ON hp.tevo_event_id = ls.event_id
LEFT JOIN performer_zones pz
       ON pz.performer_id = hp.home_performer_id
      AND pz.venue_id     = (SELECT venue_id FROM events WHERE id = ls.event_id)
LEFT JOIN performer_zone_rules pzr
       ON pzr.zone_id = pz.id
      AND section_in_range(ls.section, pzr.section_from, pzr.section_to)
      AND (pzr.row_from IS NULL OR pzr.row_to IS NULL
           OR section_in_range(ls.row, pzr.row_from, pzr.row_to))
WHERE pz.id IS NULL OR pzr.id IS NOT NULL;

CREATE OR REPLACE VIEW v_section_to_curated_zone AS
SELECT DISTINCT
  hp.tevo_event_id, hp.venue_id, hp.home_performer_id,
  pzr.section_from, pzr.section_to, pzr.row_from, pzr.row_to,
  pz.id AS zone_id, pz.name AS zone_name, pz.source AS zone_source
FROM v_event_home_away hp
JOIN performer_zones pz ON pz.performer_id = hp.home_performer_id
                       AND pz.venue_id     = hp.venue_id
JOIN performer_zone_rules pzr ON pzr.zone_id = pz.id;

CREATE OR REPLACE VIEW v_event_full_sports AS
SELECT
  ce.tevo_event_id, ce.tevo_name AS event_name, ce.event_date,
  ce.tevo_venue_name AS venue_name, ce.canonical_label,
  ce.lifecycle_status, ce.sources_count,
  ce.espn_event_id, ce.sd_event_id, ce.sg_event_id,
  hp.home_performer_id, hp.home_performer_name, hp.home_espn_team_id,
  hp.away_performer_id, hp.away_performer_name, hp.away_espn_team_id,
  hp.days_to_event, hp.primary_is_home,
  hts.record_summary  AS home_record, hts.streak AS home_streak, hts.win_pct AS home_win_pct,
  ats.record_summary  AS away_record, ats.streak AS away_streak, ats.win_pct AS away_win_pct,
  (SELECT count(*) FROM v_espn_injuries_current i WHERE i.espn_team_id = hp.home_espn_team_id AND i.status='Out')        AS home_injuries_out,
  (SELECT count(*) FROM v_espn_injuries_current i WHERE i.espn_team_id = hp.home_espn_team_id AND i.status='Day-To-Day') AS home_injuries_dtd,
  (SELECT count(*) FROM v_espn_injuries_current i WHERE i.espn_team_id = hp.away_espn_team_id AND i.status='Out')        AS away_injuries_out,
  (SELECT count(*) FROM v_espn_injuries_current i WHERE i.espn_team_id = hp.away_espn_team_id AND i.status='Day-To-Day') AS away_injuries_dtd,
  (SELECT count(*) FROM espn_news n WHERE n.espn_team_id = hp.home_espn_team_id AND n.published_at > now() - interval '24 hours') AS home_news_24h,
  (SELECT count(*) FROM espn_news n WHERE n.espn_team_id = hp.away_espn_team_id AND n.published_at > now() - interval '24 hours') AS away_news_24h,
  (SELECT round(percentile_cont(0.5) WITHIN GROUP (ORDER BY retail_price)::numeric, 2)
   FROM listings_snapshots WHERE event_id = ce.tevo_event_id AND captured_at > now() - interval '24 hours') AS tevo_retail_median,
  (SELECT count(*) FROM listings_snapshots WHERE event_id = ce.tevo_event_id AND captured_at > now() - interval '24 hours') AS tevo_listings_count,
  (SELECT round(percentile_cont(0.5) WITHIN GROUP (ORDER BY retail_price)::numeric, 2)
   FROM listings_snapshots WHERE event_id = ce.tevo_event_id AND is_owned AND captured_at > now() - interval '24 hours') AS our_owned_median,
  (SELECT count(*) FROM listings_snapshots WHERE event_id = ce.tevo_event_id AND is_owned AND captured_at > now() - interval '24 hours') AS our_owned_count
FROM v_canonical_event ce
LEFT JOIN v_event_home_away hp ON hp.tevo_event_id = ce.tevo_event_id
LEFT JOIN v_espn_team_state hts ON hts.espn_team_id = hp.home_espn_team_id
LEFT JOIN v_espn_team_state ats ON ats.espn_team_id = hp.away_espn_team_id;

COMMENT ON VIEW v_event_home_away IS 'Identifies home + away performer via venue match; falls back to primary_performer_id.';
COMMENT ON VIEW v_espn_team_state IS 'Current standings/streak per team. Sidesteps is_baseline bug via DISTINCT ON captured_at DESC.';
COMMENT ON VIEW v_espn_injuries_current IS 'Latest injury status per athlete. Same DISTINCT ON workaround.';
COMMENT ON VIEW v_listing_zone_auto IS 'Auto-assigns curated zone via performer_zone_rules; falls back to numeric_fallback.';
COMMENT ON VIEW v_section_to_curated_zone IS 'Per-event (section_range, zone) lookup for cross-source aggregation.';
COMMENT ON VIEW v_event_full_sports IS 'Single-row sports event view: home/away + standings + injuries + news + pricing.';

-- ============================================================================
-- Migration 20260708130000 — Add NWSL, CFL, NCAA football to the ESPN pipeline
--
-- Lane:     data plane (A1)
-- Touches:  espn_teams_canonical  (INSERT NWSL+CFL catalog rows; NCAAF is seeded
--                                   by the espn-seed-teams edge function — 755
--                                   teams across all conferences, impractical to
--                                   hand-author, refreshed from ESPN like the
--                                   original 169 pro teams were)
--           performer_espn_team_xref   (INSERT: Tevo performer → ESPN team, drives
--                                        the event matcher + zone feature store)
--           performer_external_ids     (INSERT source='espn' rows, drives the
--                                        espn-collect standings collector)
--
-- Operator directive (2026-07-08): "create nwsl, tennis, golf, and cfb [Canadian
--   football] ... also college level [football, all conferences] ... those too."
--   Tennis + golf were already fully wired (espn_tournament_queue / classifier /
--   matcher live; 80-100% of Tevo tournament events already matched), so this
--   migration covers only the net-new TEAM sports.
--
-- Team catalog (espn_teams_canonical) is populated by the `espn-seed-teams` edge
-- function (server-side ESPN fetch). NWSL (16) + CFL (9) are snapshotted below so
-- a fresh migration replay reproduces the small, stable leagues without the edge
-- call; NCAAF's 755 rows stay edge-seeded.
--
-- Idempotent: all INSERTs are ON CONFLICT DO NOTHING (never clobber a real row).
-- ============================================================================

-- ----------------------------------------------------------------------------
-- (1) Canonical catalog snapshot for the small stable leagues (NWSL, CFL).
--     NCAAF is intentionally omitted here — seeded via espn-seed-teams.
-- ----------------------------------------------------------------------------
INSERT INTO espn_teams_canonical(espn_league, espn_team_id, display_name) VALUES
 -- NWSL (2026 season, incl. Boston Legacy + Denver Summit expansion)
 ('NWSL','15360','Chicago Stars FC'),
 ('NWSL','15362','Portland Thorns FC'),
 ('NWSL','15363','Seattle Reign FC'),
 ('NWSL','15364','Gotham FC'),
 ('NWSL','15365','Washington Spirit'),
 ('NWSL','15366','North Carolina Courage'),
 ('NWSL','17346','Houston Dash'),
 ('NWSL','18206','Orlando Pride'),
 ('NWSL','19141','Utah Royals'),
 ('NWSL','20905','Racing Louisville FC'),
 ('NWSL','20907','Kansas City Current'),
 ('NWSL','21422','Angel City FC'),
 ('NWSL','21423','San Diego Wave FC'),
 ('NWSL','22187','Bay FC'),
 ('NWSL','131562','Boston Legacy FC'),
 ('NWSL','131563','Denver Summit FC'),
 -- CFL
 ('CFL','79','BC Lions'),
 ('CFL','80','Calgary Stampeders'),
 ('CFL','81','Edmonton Elks'),
 ('CFL','82','Hamilton Tiger-Cats'),
 ('CFL','83','Montreal Alouettes'),
 ('CFL','84','Saskatchewan Roughriders'),
 ('CFL','85','Toronto Argonauts'),
 ('CFL','86','Winnipeg Blue Bombers'),
 ('CFL','87','Ottawa Red Blacks')
ON CONFLICT (espn_team_id, espn_league) DO NOTHING;

-- ----------------------------------------------------------------------------
-- (2) Resolve Tevo performers → ESPN teams for NWSL + NCAAF.
--     (CFL has zero Tevo inventory today, so nothing to map; the catalog is
--      seeded so standings light up automatically if CFL inventory appears.)
--
--     NCAAF: Tevo names carry a " Football" suffix ("Georgia Bulldogs Football")
--            — strip it and exact-match the ESPN display name. The suffix gate
--            keeps non-football performers (volleyball, basketball) out.
--     NWSL:  strip a trailing " FC" on both sides ("Utah Royals FC"→"Utah Royals").
--     Aliases cover the handful of naming variants ESPN spells differently.
-- ----------------------------------------------------------------------------
WITH ncaaf_exact AS (
  SELECT pm.performer_id, etc.espn_team_id, 'NCAAF'::text AS espn_league,
         etc.display_name, 'exact_strip_football'::text AS method
  FROM performer_metadata pm
  JOIN espn_teams_canonical etc ON etc.espn_league = 'NCAAF'
    AND lower(trim(regexp_replace(pm.name, '\s+Football$', '', 'i'))) = lower(trim(etc.display_name))
  WHERE pm.name ~* '\yFootball$'
),
ncaaf_alias AS (
  SELECT a.performer_id, a.espn_team_id, 'NCAAF'::text, etc.display_name, 'alias'::text
  FROM (VALUES
    (26007, '41'),    -- Connecticut Huskies Football            -> UConn Huskies
    (30067, '2229'),  -- FIU Golden Panthers Football            -> Florida International Panthers
    (15854, '2755'),  -- Grambling State Tigers Football         -> Grambling Tigers
    (30064, '193'),   -- Miami (Ohio) Redhawks Football          -> Miami (OH) RedHawks
    (30272, '2630'),  -- Tennessee Martin Skyhawks Football      -> UT Martin Skyhawks
    (40208, '2429')   -- UNC Charlotte 49ers Football            -> Charlotte 49ers
  ) AS a(performer_id, espn_team_id)
  JOIN performer_metadata pm ON pm.performer_id = a.performer_id
  JOIN espn_teams_canonical etc ON etc.espn_league = 'NCAAF' AND etc.espn_team_id = a.espn_team_id
),
nwsl_exact AS (
  SELECT pm.performer_id, etc.espn_team_id, 'NWSL'::text, etc.display_name, 'exact_strip_fc'::text
  FROM performer_metadata pm
  JOIN espn_teams_canonical etc ON etc.espn_league = 'NWSL'
    AND lower(trim(regexp_replace(pm.name, '\s+FC$', '', 'i')))
      = lower(trim(regexp_replace(etc.display_name, '\s+FC$', '', 'i')))
),
nwsl_alias AS (
  SELECT pm.performer_id, etc.espn_team_id, 'NWSL'::text, etc.display_name, 'alias'::text
  FROM performer_metadata pm
  JOIN espn_teams_canonical etc ON etc.espn_league = 'NWSL' AND etc.display_name = 'Gotham FC'
  WHERE pm.performer_id = 41816   -- NJ/NY Gotham FC
),
all_map AS (
  SELECT * FROM ncaaf_exact
  UNION SELECT * FROM ncaaf_alias
  UNION SELECT * FROM nwsl_exact
  UNION SELECT * FROM nwsl_alias
),
resolved AS (
  SELECT DISTINCT ON (performer_id, espn_league)
         performer_id, espn_team_id, espn_league, display_name, method
  FROM all_map
  ORDER BY performer_id, espn_league, method   -- 'alias' < 'exact_*' (arbitrary, no overlap in practice)
),
ins_xref AS (
  INSERT INTO performer_espn_team_xref(tevo_performer_id, espn_team_id, espn_league, match_method)
  SELECT performer_id, espn_team_id, espn_league, method FROM resolved
  ON CONFLICT (tevo_performer_id, espn_league) DO NOTHING
  RETURNING 1
)
INSERT INTO performer_external_ids(performer_id, source, external_id, external_name, league, meta)
SELECT r.performer_id, 'espn', r.espn_team_id, r.display_name, r.espn_league,
       jsonb_build_object(
         'espn_slug', CASE r.espn_league
                        WHEN 'NWSL'  THEN 'soccer/usa.nwsl'
                        WHEN 'NCAAF' THEN 'football/college-football'
                        WHEN 'CFL'   THEN 'football/cfl'
                      END,
         'backfilled_from', 'seed_new_leagues_20260708',
         'espn_display_name', r.display_name)
FROM resolved r
ON CONFLICT (performer_id, source) DO NOTHING;

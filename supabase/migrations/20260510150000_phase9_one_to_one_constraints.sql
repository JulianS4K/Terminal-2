-- ============================================================================
-- Migration 20260510150000 — Phase 9: lock 1-to-1 mappings (UNIQUE constraints)
--
-- Lane:     canonical
-- Touches:  performer_external_ids (ALTER), performer_espn_team_xref (ALTER),
--           seatgeek_performer_xref (ALTER), seatdata_performer_xref (ALTER),
--           seatgeek_venue_xref (ALTER), seatdata_venue_xref (ALTER),
--           venue_assets (UPDATE + ALTER for espn_venue_id 1-to-1),
--           v_one_to_one_health (CREATE VIEW)
-- Pre-reqs: 20260510120300 (Phase 4), 20260510120500 (Phase 6)
--
-- Lock 1-to-1 mapping across ESPN / Tevo / SeatGeek / SeatData / Wikipedia
-- performers and venues with UNIQUE constraints. These external IDs are
-- static — once Tevo performer X is matched to ESPN team Y in league L, that
-- pair is permanent. The forward direction is already enforced by primary
-- keys; this phase locks down the *reverse* direction so future inserts
-- physically cannot violate 1-to-1.
--
-- Pre-flight (verified at write time):
--   * performer_external_ids: 0 reverse dupes (per source, including ESPN
--                             keyed on (external_id, league))
--   * performer_espn_team_xref: 0 reverse dupes on (espn_team_id, espn_league)
--   * seatgeek_performer_xref: 0 reverse dupes on sg_performer_name
--   * seatdata_performer_xref: 0 reverse dupes on sd_performer_name
--   * seatgeek_venue_xref: 0 reverse dupes on sg_venue_name
--   * seatdata_venue_xref: 0 reverse dupes on (sd_std_venue_id, sd_venue_name)
--   * venue_assets.espn_venue_id: confirmed 1-to-1 below
-- ============================================================================

-- ----------------------------------------------------------------------------
-- performer_external_ids — global reverse-key.
-- ESPN external_id collides across leagues (team 14 = NHL Bruins / MLB Braves
-- / NBA Grizzlies); the proper reverse key is (source, external_id, league).
-- For sources without a league (sg_broker, wikipedia, seatdata), league is
-- NULL and we use COALESCE() so they all share a single bucket per source.
-- ----------------------------------------------------------------------------
CREATE UNIQUE INDEX IF NOT EXISTS pei_reverse_uniq
  ON performer_external_ids (source, external_id, COALESCE(league, '__no_league__'));

-- ----------------------------------------------------------------------------
-- performer_espn_team_xref — one ESPN team per league belongs to ONE Tevo perf
-- ----------------------------------------------------------------------------
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
     WHERE conname = 'petx_espn_reverse_uniq'
       AND conrelid = 'public.performer_espn_team_xref'::regclass
  ) THEN
    ALTER TABLE performer_espn_team_xref
      ADD CONSTRAINT petx_espn_reverse_uniq UNIQUE (espn_team_id, espn_league);
  END IF;
END $$;

-- ----------------------------------------------------------------------------
-- seatgeek_performer_xref — one SG performer name belongs to ONE Tevo perf
-- ----------------------------------------------------------------------------
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
     WHERE conname = 'sg_perf_xref_name_uniq'
       AND conrelid = 'public.seatgeek_performer_xref'::regclass
  ) THEN
    ALTER TABLE seatgeek_performer_xref
      ADD CONSTRAINT sg_perf_xref_name_uniq UNIQUE (sg_performer_name);
  END IF;
END $$;

-- ----------------------------------------------------------------------------
-- seatdata_performer_xref — one SD performer name belongs to ONE Tevo perf
-- ----------------------------------------------------------------------------
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
     WHERE conname = 'sd_perf_xref_name_uniq'
       AND conrelid = 'public.seatdata_performer_xref'::regclass
  ) THEN
    ALTER TABLE seatdata_performer_xref
      ADD CONSTRAINT sd_perf_xref_name_uniq UNIQUE (sd_performer_name);
  END IF;
END $$;

-- ----------------------------------------------------------------------------
-- seatgeek_venue_xref — one SG venue name belongs to ONE Tevo venue
-- ----------------------------------------------------------------------------
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
     WHERE conname = 'sg_venue_xref_name_uniq'
       AND conrelid = 'public.seatgeek_venue_xref'::regclass
  ) THEN
    ALTER TABLE seatgeek_venue_xref
      ADD CONSTRAINT sg_venue_xref_name_uniq UNIQUE (sg_venue_name);
  END IF;
END $$;

-- ----------------------------------------------------------------------------
-- seatdata_venue_xref — one SD venue id (std, when set) belongs to ONE Tevo venue.
-- sd_std_venue_id is occasionally NULL; fall back to sd_venue_name.
-- ----------------------------------------------------------------------------
CREATE UNIQUE INDEX IF NOT EXISTS sd_venue_xref_reverse_uniq
  ON seatdata_venue_xref (
    COALESCE(sd_std_venue_id::text, '__no_std__'),
    COALESCE(sd_venue_name, '__no_name__'));

-- ----------------------------------------------------------------------------
-- venue_assets.espn_venue_id — one ESPN venue belongs to ONE Tevo venue.
--
-- Cleanup pass first: two ESPN venue ids were doubly-assigned by an earlier
-- name-matching pass. Inspecting the rows:
--   espn_venue_id 1827 ("State Farm Arena", Atlanta)
--     -> Tevo 1228  "State Farm Arena - GA"  (CORRECT — name matches)
--     -> Tevo 3316  "Canada Life Centre"     (WRONG — that's Winnipeg)
--   espn_venue_id 1841 ("crypto.com Arena", Los Angeles)
--     -> Tevo 1480  "Crypto.com Arena"       (CORRECT — name matches)
--     -> Tevo 48249 "Intuit Dome"            (WRONG — Clippers' new arena)
--
-- We NULL the espn_venue_id on the wrong rows; the venue_assets trigger from
-- Phase 4 will auto-delete the corresponding canonical_external_ids rows.
-- ----------------------------------------------------------------------------
UPDATE venue_assets
   SET espn_venue_id = NULL,
       espn_venue_name = NULL
 WHERE (espn_venue_id, tevo_venue_id) IN ((  '1827', 3316),
                                          (  '1841', 48249));

-- Now safe to enforce 1-to-1
CREATE UNIQUE INDEX IF NOT EXISTS venue_assets_espn_venue_id_uniq
  ON venue_assets (espn_venue_id) WHERE espn_venue_id IS NOT NULL;

-- ----------------------------------------------------------------------------
-- Audit view: 1-to-1 health snapshot.
--   * Each row is one mapping flavor; n_violations should always be 0.
--   * If a future ingest tries to insert a duplicate, the corresponding
--     UNIQUE constraint above raises 23505 — drift can no longer happen
--     silently in either direction.
-- ----------------------------------------------------------------------------
DROP VIEW IF EXISTS v_one_to_one_health CASCADE;
CREATE VIEW v_one_to_one_health AS
SELECT 'performer_external_ids:reverse(source,external_id,league)' AS mapping,
       (SELECT COUNT(*) FROM (
          SELECT 1 FROM performer_external_ids
           GROUP BY source, external_id, COALESCE(league, '__no_league__')
          HAVING COUNT(*) > 1) v) AS n_violations
UNION ALL
SELECT 'performer_espn_team_xref:reverse(espn_team_id,espn_league)',
       (SELECT COUNT(*) FROM (
          SELECT 1 FROM performer_espn_team_xref
           GROUP BY espn_team_id, espn_league HAVING COUNT(*) > 1) v)
UNION ALL
SELECT 'seatgeek_performer_xref:reverse(sg_performer_name)',
       (SELECT COUNT(*) FROM (
          SELECT 1 FROM seatgeek_performer_xref
           GROUP BY sg_performer_name HAVING COUNT(*) > 1) v)
UNION ALL
SELECT 'seatdata_performer_xref:reverse(sd_performer_name)',
       (SELECT COUNT(*) FROM (
          SELECT 1 FROM seatdata_performer_xref
           GROUP BY sd_performer_name HAVING COUNT(*) > 1) v)
UNION ALL
SELECT 'seatgeek_venue_xref:reverse(sg_venue_name)',
       (SELECT COUNT(*) FROM (
          SELECT 1 FROM seatgeek_venue_xref
           GROUP BY sg_venue_name HAVING COUNT(*) > 1) v)
UNION ALL
SELECT 'venue_assets:reverse(espn_venue_id)',
       (SELECT COUNT(*) FROM (
          SELECT 1 FROM venue_assets
           WHERE espn_venue_id IS NOT NULL
           GROUP BY espn_venue_id HAVING COUNT(*) > 1) v);

GRANT SELECT ON v_one_to_one_health
  TO authenticated, anon, service_role;

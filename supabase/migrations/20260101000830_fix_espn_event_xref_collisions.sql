-- Fix ESPN↔TEvo (EVO) event_xref collisions for MLS / MLB / NFL / NHL / NBA.
--
-- Problem: one ESPN event mapped to multiple distinct TEvo events. Audit (2026-06-06)
-- found 144 collision groups across MLB (136), NBA (7), NHL (1); MLS and NFL are clean.
-- Every offending duplicate originates from a DEPRECATED matcher
-- (team_date / team_date_legacy / auto_date_team_v1) that was superseded by
-- in_db_strict_v1 + the a1_espn_* bridges but never had its stale rows reaped.
-- Each duplicate maps a TEvo game to an ESPN event whose home/away teams and/or
-- date do not match the TEvo game (typically the next day's game in a series, or an
-- entirely different matchup; in NBA, speculative "TBD"/"If Necessary" playoff rows).
--
-- Fix: within each collided ESPN event (in the 5 leagues, excluding tournament rows),
-- delete every xref row whose mapped ESPN event's home team, away team, and Pacific-Time
-- game date do NOT all agree with the TEvo event. We only act when the ESPN event's real
-- teams are known (both sides resolve via performer_espn_team_xref) so a team-coverage gap
-- can never trigger a wrongful delete. Verified-correct rows (in_db_strict_v1 / a1_espn_*)
-- always survive. Events left without an xref self-heal via the existing match cron.
--
-- Read-only-upstream invariant (CLAUDE.md §2) untouched: this only edits our own
-- cross-reference table; no listing-source API is read or written.
-- (No explicit BEGIN/COMMIT: the migration runner wraps this file in one transaction,
--  so the final assertion's RAISE EXCEPTION rolls back the whole change on any mismatch.)

-- 1. Archive the rows we are about to delete (full recoverability).
CREATE TABLE IF NOT EXISTS public.event_xref_cleanup_archive_20260606 (
  LIKE public.event_xref INCLUDING ALL
);
ALTER TABLE public.event_xref_cleanup_archive_20260606
  ADD COLUMN IF NOT EXISTS archived_at timestamptz NOT NULL DEFAULT now(),
  ADD COLUMN IF NOT EXISTS archive_reason text;

WITH nontourn AS (
  SELECT * FROM public.event_xref
  WHERE match_method <> 'tournament_token_overlap'
    AND espn_league IN ('MLS','MLB','NFL','NHL','NBA')
),
collided AS (
  SELECT espn_event_id, espn_league
  FROM nontourn
  GROUP BY 1,2
  HAVING count(DISTINCT tevo_event_id) > 1
),
bad AS (
  SELECT ex.tevo_event_id
  FROM nontourn ex
  JOIN collided c
    ON c.espn_event_id = ex.espn_event_id AND c.espn_league = ex.espn_league
  JOIN public.events e ON e.id = ex.tevo_event_id
  JOIN public.espn_event_date_lookup edl
    ON edl.espn_event_id = ex.espn_event_id AND edl.espn_league = ex.espn_league
  LEFT JOIN public.performer_espn_team_xref ph
    ON ph.espn_team_id = edl.home_team_id AND ph.espn_league = ex.espn_league
  LEFT JOIN public.performer_espn_team_xref pa
    ON pa.espn_team_id = edl.away_team_id AND pa.espn_league = ex.espn_league
  WHERE ph.tevo_performer_id IS NOT NULL          -- only act when real teams are known
    AND pa.tevo_performer_id IS NOT NULL
    AND NOT (
      e.primary_performer_id = ph.tevo_performer_id
      AND ph.tevo_performer_id = ANY(e.performer_ids)
      AND pa.tevo_performer_id = ANY(e.performer_ids)
      AND left(e.occurs_at_local,10)::date
          = (edl.game_at_utc AT TIME ZONE 'America/Los_Angeles')::date
    )
)
INSERT INTO public.event_xref_cleanup_archive_20260606 AS a
SELECT x.*, now(), 'espn_xref_collision_cleanup_20260606'
FROM public.event_xref x
JOIN bad ON bad.tevo_event_id = x.tevo_event_id;

-- 2. Delete exactly the archived rows.
DELETE FROM public.event_xref x
USING public.event_xref_cleanup_archive_20260606 a
WHERE a.archive_reason = 'espn_xref_collision_cleanup_20260606'
  AND a.tevo_event_id = x.tevo_event_id;

-- 3. Assertion: zero residual collisions per the canonical guard view (which already
--    excludes legitimate same-date/same-home cases: split doubleheaders and TEvo-side
--    duplicate event rows that correctly share one ESPN event).
DO $$
DECLARE v_remaining int;
BEGIN
  SELECT count(*) INTO v_remaining
  FROM public.v_event_xref_collisions
  WHERE espn_league IN ('MLS','MLB','NFL','NHL','NBA');
  RAISE NOTICE 'espn xref cleanup: % residual collision group(s) remain (per guard view)', v_remaining;
  IF v_remaining > 0 THEN
    RAISE EXCEPTION 'expected 0 residual guard collisions, found %', v_remaining;
  END IF;
END $$;

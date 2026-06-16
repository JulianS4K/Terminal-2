-- Migration 20260616051500 · lane:D3 (author) → A1 (apply) · writes:world_cup_2026 (new table + refresh fn) · reads:sg_events_canonical, events, latest_event_metrics · pre:20260615140000_wc_enable_sh_vd_collection · auth:operator-requested 2026-06-16 ("map world cup events for entire event series ... into a table in supabase")
--
-- D3 — consolidate the 2026 FIFA World Cup event series into a single mapping
-- table, `public.world_cup_2026`, one row per match. Today the full schedule
-- lives only in `sg_events_canonical` (SeatGeek-sourced), and the EVO/TEvo
-- crosswalk (sg_events_canonical.tevo_event_id) is populated for just 1 of 104
-- matches (Match 72, Atlanta — the one we own). This table is the canonical,
-- one-stop view of the series: parsed tournament structure (match #, stage,
-- group, teams) + venue + the EVO linkage + our ownership snapshot.
--
-- WHY A TABLE (not a view): the operator asked for a table. To keep it from
-- rotting as the autotrack maps more matches to TEvo and as we acquire
-- inventory, the dynamic columns (tevo_event_id, we_own, owned_*) are NOT
-- frozen — they are (re)derived by refresh_world_cup_2026(), which UPSERTs from
-- the canonical sources. Call it ad hoc, or wire it to the existing
-- cross_source_match_tick cadence later (follow-up; no cron added here).
--
-- COVERAGE: 101 of 104 matches are currently in sg_events_canonical. Matches
-- 28, 53, 71 are absent from the upstream SeatGeek feed (not invented here);
-- they populate automatically on the next refresh once SG lists them.
--
-- Idempotent: CREATE TABLE/INDEX IF NOT EXISTS, CREATE OR REPLACE FUNCTION,
-- UPSERT on match_number. Safe to re-run.

CREATE TABLE IF NOT EXISTS public.world_cup_2026 (
  match_number          int PRIMARY KEY,            -- 1..104, FIFA match number
  stage                 text NOT NULL,              -- Group Stage / Round of 32 / ... / Final
  group_label           text,                       -- 'Group A'..'Group L' (group stage only)
  team_a                text,                        -- null until the matchup is set (knockouts)
  team_b                text,
  match_label           text NOT NULL,              -- 'Team A vs Team B' or 'TBD'
  event_datetime        timestamptz,                -- kickoff (UTC)
  event_date            date,
  venue_name            text,                        -- real venue name as SG carries it
  venue_city            text,
  venue_state           text,
  venue_country         text,
  sg_event_id           bigint,                      -- SeatGeek canonical event id
  sg_event_name         text,
  tevo_event_id         bigint,                      -- EVO/TEvo crosswalk (null until matched)
  tevo_event_name       text,
  we_own                boolean NOT NULL DEFAULT false,
  owned_tickets_count   int NOT NULL DEFAULT 0,
  owned_median_retail   numeric,
  has_seller_listings   boolean NOT NULL DEFAULT false,
  match_status          text,
  refreshed_at          timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.world_cup_2026 IS
  'Canonical 2026 FIFA World Cup match series (one row per match). Static tournament structure + EVO/TEvo linkage + ownership snapshot. Populated/maintained by refresh_world_cup_2026() from sg_events_canonical + events + latest_event_metrics. D3 2026-06-16.';

-- Lock down to backend (service-role) access only, matching peer tables
-- (events, sg_events_canonical). RLS on + no policy => anon/authenticated are
-- denied; the FastAPI storefront reads via the service key, which bypasses RLS.
ALTER TABLE public.world_cup_2026 ENABLE ROW LEVEL SECURITY;

CREATE INDEX IF NOT EXISTS idx_world_cup_2026_date     ON public.world_cup_2026(event_date);
CREATE INDEX IF NOT EXISTS idx_world_cup_2026_owned    ON public.world_cup_2026(we_own) WHERE we_own;
CREATE INDEX IF NOT EXISTS idx_world_cup_2026_tevo     ON public.world_cup_2026(tevo_event_id) WHERE tevo_event_id IS NOT NULL;

-- Re-derive every row from the canonical sources. SECURITY DEFINER so it can be
-- called by the cross-source match cadence (which runs as the cron role) the
-- same way the other matcher ticks are; search_path pinned per project rule.
CREATE OR REPLACE FUNCTION public.refresh_world_cup_2026()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $fn$
DECLARE v_rows int; v_owned int; v_linked int;
BEGIN
  INSERT INTO public.world_cup_2026 AS w (
    match_number, stage, group_label, team_a, team_b, match_label,
    event_datetime, event_date, venue_name, venue_city, venue_state, venue_country,
    sg_event_id, sg_event_name, tevo_event_id, tevo_event_name,
    we_own, owned_tickets_count, owned_median_retail, has_seller_listings,
    match_status, refreshed_at
  )
  SELECT DISTINCT ON (s.match_number)
    s.match_number,
    CASE
      WHEN s.match_number BETWEEN 1  AND 72  THEN 'Group Stage'
      WHEN s.match_number BETWEEN 73 AND 88  THEN 'Round of 32'
      WHEN s.match_number BETWEEN 89 AND 96  THEN 'Round of 16'
      WHEN s.match_number BETWEEN 97 AND 100 THEN 'Quarter-Final'
      WHEN s.match_number BETWEEN 101 AND 102 THEN 'Semi-Final'
      WHEN s.match_number = 103 THEN 'Third-Place Play-off'
      WHEN s.match_number = 104 THEN 'Final'
      ELSE 'Unknown'
    END AS stage,
    CASE WHEN s.group_letter IS NOT NULL THEN 'Group ' || s.group_letter END AS group_label,
    s.team_a, s.team_b,
    CASE WHEN s.team_a IS NOT NULL AND s.team_b IS NOT NULL
         THEN s.team_a || ' vs ' || s.team_b ELSE 'TBD' END AS match_label,
    s.sg_datetime_utc, s.sg_event_date,
    s.sg_venue_name, s.sg_venue_city, s.sg_venue_state, s.sg_venue_country,
    s.sg_event_id, s.sg_event_name,
    s.tevo_event_id, e.name AS tevo_event_name,
    COALESCE(m.owned_tickets_count, 0) > 0 AS we_own,
    COALESCE(m.owned_tickets_count, 0) AS owned_tickets_count,
    NULLIF(m.owned_median_retail::text, '')::numeric AS owned_median_retail,
    COALESCE(s.has_seller_listings, false) AS has_seller_listings,
    s.match_status,
    now()
  FROM (
    SELECT
      c.*,
      (regexp_match(c.sg_event_name, 'Match\s+([0-9]+)'))[1]::int AS match_number,
      NULLIF((regexp_match(c.sg_event_name, '^(.*?)\s+vs\s+.+?\s*-\s*World Cup'))[1], '') AS team_a,
      NULLIF((regexp_match(c.sg_event_name, '\s+vs\s+(.+?)\s*-\s*World Cup'))[1], '') AS team_b,
      (regexp_match(c.sg_event_name, '\(Group ([A-L])\)'))[1] AS group_letter
    FROM public.sg_events_canonical c
    WHERE c.sg_event_name ~* 'world cup - match [0-9]+'
  ) s
  LEFT JOIN public.events e               ON e.id = s.tevo_event_id
  LEFT JOIN public.latest_event_metrics m ON m.event_id = s.tevo_event_id
  WHERE s.match_number IS NOT NULL
  -- A matched (tevo-linked) canonical row wins if the same match number ever
  -- appears more than once upstream.
  ORDER BY s.match_number, (s.tevo_event_id IS NOT NULL) DESC, s.updated_at DESC
  ON CONFLICT (match_number) DO UPDATE SET
    stage               = EXCLUDED.stage,
    group_label         = EXCLUDED.group_label,
    team_a              = EXCLUDED.team_a,
    team_b              = EXCLUDED.team_b,
    match_label         = EXCLUDED.match_label,
    event_datetime      = EXCLUDED.event_datetime,
    event_date          = EXCLUDED.event_date,
    venue_name          = EXCLUDED.venue_name,
    venue_city          = EXCLUDED.venue_city,
    venue_state         = EXCLUDED.venue_state,
    venue_country       = EXCLUDED.venue_country,
    sg_event_id         = EXCLUDED.sg_event_id,
    sg_event_name       = EXCLUDED.sg_event_name,
    tevo_event_id       = EXCLUDED.tevo_event_id,
    tevo_event_name     = EXCLUDED.tevo_event_name,
    we_own              = EXCLUDED.we_own,
    owned_tickets_count = EXCLUDED.owned_tickets_count,
    owned_median_retail = EXCLUDED.owned_median_retail,
    has_seller_listings = EXCLUDED.has_seller_listings,
    match_status        = EXCLUDED.match_status,
    refreshed_at        = now();

  SELECT count(*), count(*) FILTER (WHERE we_own), count(*) FILTER (WHERE tevo_event_id IS NOT NULL)
    INTO v_rows, v_owned, v_linked
  FROM public.world_cup_2026;

  RETURN jsonb_build_object(
    'rows', v_rows, 'owned', v_owned, 'evo_linked', v_linked, 'refreshed_at', now()
  );
END;
$fn$;

-- Populate now.
SELECT public.refresh_world_cup_2026();

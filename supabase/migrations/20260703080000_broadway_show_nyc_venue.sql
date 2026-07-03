-- Migration 20260703080000 · level:standard · lane:broadway (D3)/D0 · writes:broadway_show_ref,get_broker_performer_index · reads:events · pre:20260703070000
--
-- NYC-Broadway-only fix. A Broadway show's production performer (e.g.
-- "Wicked - Musical" = 21123) spans the whole franchise — Broadway AND the
-- national tour — so linking a show to that performer's page leaked tour stops
-- (Wicked→Boston, Hamilton→Fort Worth, Hadestown→TX, & Juliet→TX/WI, Cursed
-- Child/Outsiders→CA, Chicago→FL). Each NYC Broadway house runs exactly one
-- show, so pin every show to its NYC venue_id and scope the Broadway views to
-- it: the directory upcoming-count is counted by VENUE (NYC only), and the
-- directory entry now carries tevo_venue_id so the frontend loads the show's
-- performer page scoped to that house (NYC performances only, no tour dates).

ALTER TABLE public.broadway_show_ref
  ADD COLUMN IF NOT EXISTS tevo_venue_id bigint;

COMMENT ON COLUMN public.broadway_show_ref.tevo_venue_id IS
  'The NYC Broadway house (tevo venue). The house runs one show, so scoping to '
  'it keeps the Broadway views NYC-only even when the performer is a franchise '
  'that also tours.';

UPDATE public.broadway_show_ref r SET tevo_venue_id = v.vid
FROM (VALUES
  ('and-juliet',2041),('becky-shaw',649),('buena-vista',3724),('cats-jellicle-ball',185),
  ('chicago',42),('death-becomes-her',880),('death-of-a-salesman',2012),('dog-day-afternoon',1690),
  ('every-brilliant-thing',33418),('fallen-angels',2595),('giant',1065),('hadestown',1700),
  ('hamilton',1305),('cursed-child',31499),('joe-turner',115),('maybe-happy-ending',129),
  ('mj',1095),('oh-mary',882),('operation-mincemeat',585),('proof',167),('ragtime',2076),
  ('schmigadoon',1094),('six',190),('stranger-things',929),('the-balusters',6095),
  ('book-of-mormon',1839),('great-gatsby',187),('lion-king',1022),('lost-boys',1180),
  ('the-outsiders',1942),('two-strangers',2890),('wicked',568)
) AS v(slug, vid)
WHERE r.show_slug = v.slug;

-- Directory RPC: Broadway entries carry tevo_venue_id and count upcoming events
-- by the NYC VENUE (was: by the franchise performer, which included tour dates).
CREATE OR REPLACE FUNCTION public.get_broker_performer_index()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE v_email text; v_result jsonb;
BEGIN
  v_email := coalesce(auth.jwt()->>'email', '');
  IF v_email NOT LIKE '%@s4kent.com' THEN
    RAISE EXCEPTION 'forbidden: % is not an @s4kent.com email', v_email USING ERRCODE = '42501';
  END IF;

  WITH base AS (
    SELECT xt.tevo_performer_id, xt.espn_team_id, xt.espn_league,
           ap.performer_name, etc.display_name, etc.abbreviation
    FROM public.performer_espn_team_xref xt
    LEFT JOIN public.aq_performer_map ap ON ap.tevo_performer_id = xt.tevo_performer_id
    LEFT JOIN public.espn_teams_canonical etc
      ON etc.espn_team_id = xt.espn_team_id AND etc.espn_league = xt.espn_league
    WHERE xt.espn_league IN ('NFL','NBA','MLB','MLS','WNBA') AND xt.tevo_performer_id IS NOT NULL
  ),
  counts AS (
    SELECT b.tevo_performer_id, COUNT(*) AS events_count_next_90d
    FROM base b
    JOIN public.events ev ON ev.primary_performer_id = b.tevo_performer_id
    WHERE ev.occurs_at_local ~ '^\d{4}'
      AND ev.occurs_at_local::timestamptz >= now()
      AND ev.occurs_at_local::timestamptz < now() + interval '90 days'
    GROUP BY b.tevo_performer_id
  ),
  rows0 AS (
    SELECT b.espn_league,
           jsonb_build_object(
             'tevo_performer_id', b.tevo_performer_id, 'performer_name', b.performer_name,
             'espn_team_id', b.espn_team_id, 'abbreviation', b.abbreviation,
             'display_name', b.display_name,
             'events_count_next_90d', coalesce(c.events_count_next_90d, 0)
           ) AS team_obj,
           coalesce(b.display_name, b.performer_name, '') AS sort_key
    FROM base b LEFT JOIN counts c ON c.tevo_performer_id = b.tevo_performer_id
  ),
  bway AS (
    SELECT 'Broadway'::text AS espn_league,
           jsonb_build_object(
             'show_slug', r.show_slug,
             'display_name', r.title,
             'performer_name', r.title,
             'tevo_performer_id', r.tevo_performer_id,
             'tevo_venue_id', r.tevo_venue_id,
             'events_count_next_90d', (
               SELECT count(*) FROM public.events e
               WHERE e.venue_id = r.tevo_venue_id
                 AND e.primary_performer_id = r.tevo_performer_id
                 AND e.occurs_at_local ~ '^\d{4}'
                 AND e.occurs_at_local::timestamptz >= now()
                 AND e.occurs_at_local::timestamptz < now() + interval '90 days')
           ) AS team_obj,
           r.title AS sort_key
    FROM public.broadway_show_ref r
    WHERE r.tevo_performer_id IS NOT NULL
  ),
  rows_all AS (
    SELECT espn_league, team_obj, sort_key FROM rows0
    UNION ALL
    SELECT espn_league, team_obj, sort_key FROM bway
  ),
  per_league AS (
    SELECT espn_league, jsonb_agg(team_obj ORDER BY sort_key) AS teams, COUNT(*) AS team_count
    FROM rows_all GROUP BY espn_league
  )
  SELECT jsonb_build_object(
    'counts',  jsonb_object_agg(espn_league, team_count) ||
               jsonb_build_object('total', (SELECT sum(team_count) FROM per_league)),
    'leagues', jsonb_object_agg(espn_league, teams)
  ) INTO v_result FROM per_league;

  RETURN coalesce(v_result, jsonb_build_object('counts', '{}'::jsonb, 'leagues', '{}'::jsonb));
END $function$;

-- Migration 20260703060000 · level:standard · lane:broadway (D3)/D0 · writes:broadway_show_ref,get_broker_performer_index · reads:events · pre:20260703050000
--
-- Give each Broadway show its canonical TEvo performer id (the show-as-performer,
-- e.g. Oh, Mary! = 103169 "Oh Mary!", Wicked = 21123 "Wicked - Musical"), so the
-- performer-space directory can land a show on its PERFORMER page (like a team)
-- instead of a single performance's event page. Resolved 2026-07-03 as the
-- production performer at each show's venue (dominant by event count, preferring
-- the "- Musical"/"- Play" production over any concert one-offs sharing a
-- multi-use house — e.g. the Palace's Nikki Glaser dates, so Lost Boys → 11679
-- "The Lost Boys - Musical", not the concerts). Verified: 32/32 shows resolve
-- to a single production performer.
--
-- Also repoints the RPC's Broadway branch to emit tevo_performer_id (so the
-- frontend links to performer.html like the sports teams) and to count upcoming
-- performances by that performer id directly.

ALTER TABLE public.broadway_show_ref
  ADD COLUMN IF NOT EXISTS tevo_performer_id bigint;

CREATE INDEX IF NOT EXISTS idx_broadway_show_ref_performer
  ON public.broadway_show_ref (tevo_performer_id) WHERE tevo_performer_id IS NOT NULL;

COMMENT ON COLUMN public.broadway_show_ref.tevo_performer_id IS
  'Canonical TEvo performer for the show (the production, e.g. "Wicked - Musical"). '
  'Lets the directory + a performer-scoped cast panel key off the show-as-performer.';

UPDATE public.broadway_show_ref r SET tevo_performer_id = v.pid
FROM (VALUES
  ('and-juliet',84478),('becky-shaw',129437),('buena-vista',101609),
  ('cats-jellicle-ball',85697),('chicago',30044),('death-becomes-her',98360),
  ('death-of-a-salesman',18177),('dog-day-afternoon',128595),('every-brilliant-thing',68212),
  ('fallen-angels',128974),('giant',117628),('hadestown',68595),('hamilton',45745),
  ('cursed-child',52519),('joe-turner',18976),('maybe-happy-ending',73068),('mj',72759),
  ('oh-mary',103169),('operation-mincemeat',115883),('proof',19867),('ragtime',19894),
  ('schmigadoon',128500),('six',70429),('stranger-things',99790),('the-balusters',132722),
  ('book-of-mormon',21899),('great-gatsby',95463),('lion-king',30059),('lost-boys',11679),
  ('the-outsiders',42653),('two-strangers',104557),('wicked',21123)
) AS v(slug, pid)
WHERE r.show_slug = v.slug;

-- Repoint the directory RPC's Broadway branch to the performer id.
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
             'events_count_next_90d', (
               SELECT count(*) FROM public.events e
               WHERE e.primary_performer_id = r.tevo_performer_id
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

-- Broadway "file index" — the show → cast analog of the players-by-team index.
-- Mirrors get_espn_team_index / get_espn_team_roster but over the Broadway
-- cast pipeline (broadway_show_ref = shows, broadway_cast_run = cast stints).
-- Surfaces via the existing Broadway pseudo-league in the performer directory
-- and the performer/event Cast tab (cast-panel.js); these RPCs make the index
-- directly queryable.

-- Show index: every tracked Broadway show with its venue/city + cast counts.
CREATE OR REPLACE FUNCTION public.get_broadway_show_index()
 RETURNS TABLE (show_slug text, title text, venue text, city text,
                tevo_performer_id bigint, tevo_venue_id bigint,
                cast_count int, open_count int)
 LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public','pg_temp'
AS $function$
  SELECT r.show_slug, r.title, r.venue_name_pattern, r.city,
         r.tevo_performer_id, r.tevo_venue_id,
         count(c.id)::int AS cast_count,
         count(c.id) FILTER (WHERE c.is_open)::int AS open_count
  FROM public.broadway_show_ref r
  LEFT JOIN public.broadway_cast_run c ON c.show_slug = r.show_slug
  GROUP BY r.show_slug, r.title, r.venue_name_pattern, r.city, r.tevo_performer_id, r.tevo_venue_id
  ORDER BY r.title;
$function$;
comment on function public.get_broadway_show_index is
  'Broadway show index (shows with venue/city + cast counts) — the show->cast file index.';

-- A show's cast (the index leaf): performer/role stints, current runs first.
CREATE OR REPLACE FUNCTION public.get_broadway_show_cast(p_show_slug text)
 RETURNS TABLE (performer_name text, role text, run_start date, run_end date,
                is_open boolean, is_final_confirmed boolean, source_url text)
 LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public','pg_temp'
AS $function$
  SELECT performer_name, role, run_start, run_end, is_open, is_final_confirmed, source_url
  FROM public.broadway_cast_run
  WHERE show_slug = p_show_slug
  ORDER BY is_open DESC, run_start DESC NULLS LAST, performer_name;
$function$;
comment on function public.get_broadway_show_cast is
  'Cast stints for a Broadway show (leaf of the Broadway show->cast index).';

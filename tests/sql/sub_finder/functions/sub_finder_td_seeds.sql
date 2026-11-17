CREATE OR REPLACE FUNCTION public.sub_finder_td_seeds(p_tevo_event_id bigint)
 RETURNS TABLE(seed text, url text, ambiguous boolean, ord integer)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  WITH m AS (
    SELECT a.id, a.sh_event_id, a.sg_event_id, a.vivid_event_id
      FROM public.aq_event_map a WHERE a.tevo_event_id = p_tevo_event_id
  ), cand AS (
    SELECT 'stubhub' AS seed, 'https://www.stubhub.com/event/' || m.sh_event_id AS url, 1 AS kind, min(m.id) AS first_id,
           (SELECT count(DISTINCT x.sh_event_id) FROM m x WHERE x.sh_event_id IS NOT NULL) > 1 AS ambiguous
      FROM m WHERE m.sh_event_id IS NOT NULL GROUP BY m.sh_event_id
    UNION ALL
    SELECT 'seatgeek', c.sg_url, 2, min(c.sg_event_id),
           (SELECT count(DISTINCT x.sg_event_id) FROM m x WHERE x.sg_event_id IS NOT NULL) > 1
      FROM public.sg_events_canonical c
     WHERE c.sg_url ~ '^https?://(www\.)?seatgeek\.com/'
       AND (c.sg_event_id IN (SELECT m.sg_event_id FROM m WHERE m.sg_event_id IS NOT NULL)
            OR c.tevo_event_id = p_tevo_event_id)
     GROUP BY c.sg_url
    UNION ALL
    SELECT 'vivid', 'https://www.vividseats.com/production/' || m.vivid_event_id, 3, min(m.id),
           (SELECT count(DISTINCT x.vivid_event_id) FROM m x WHERE x.vivid_event_id IS NOT NULL) > 1
      FROM m WHERE m.vivid_event_id IS NOT NULL GROUP BY m.vivid_event_id
  )
  SELECT c.seed, c.url, c.ambiguous, row_number() OVER (ORDER BY c.ambiguous, c.kind, c.first_id, c.url)::integer
    FROM cand c
   WHERE NOT EXISTS (SELECT 1 FROM public.events e WHERE e.id = p_tevo_event_id AND e.name ~* '\mparking\M')
     AND NOT EXISTS (SELECT 1 FROM public.sub_finder_td_seed_log l
                      WHERE l.event_url = c.url AND l.at > now() - interval '14 days')
$function$


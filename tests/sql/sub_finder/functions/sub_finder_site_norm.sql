CREATE OR REPLACE FUNCTION public.sub_finder_site_norm(p text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
AS $function$
  SELECT CASE
    WHEN k IS NULL THEN NULL
    WHEN k LIKE 'gotick%' OR k = 'gotix' THEN 'gotickets'
    WHEN k LIKE 'tickpick%' THEN 'tickpick'
    WHEN k LIKE 'vivid%' THEN 'vivid'
    WHEN k LIKE 'seatgeek%' THEN 'seatgeek'
    WHEN k IN ('evo', 'tevo') OR k LIKE 'ticketevo%' THEN 'evo'
    WHEN k LIKE 'stubhub%' THEN 'stubhub'
    WHEN k LIKE 'gametime%' THEN 'gametime'
    WHEN k LIKE 'viagogo%' THEN 'viagogo'
    WHEN k LIKE 'ticketmaster%' THEN 'ticketmaster'
    ELSE k END
  FROM (SELECT nullif(lower(regexp_replace(coalesce(p, ''), '[^A-Za-z]', '', 'g')), '') AS k) q;
$function$


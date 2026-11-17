CREATE OR REPLACE FUNCTION public.sub_finder_scratch()
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
  IF to_regclass('pg_temp._sf_l') IS NOT NULL THEN DROP TABLE _sf_l; END IF;
  CREATE TEMP TABLE _sf_l (
    market text, via text, eid bigint, lid text, section text, seat_row text, quantity integer,
    px numeric, sp integer[], pulled_at timestamptz, link text, price_note text,
    view_note text) ON COMMIT DROP;
END
$function$


CREATE OR REPLACE FUNCTION public.sub_finder_td_writeback(p_tevo_event_id bigint, p_matches jsonb, p_local_date date)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  r     record;
  v_res text;
  v_out text := '';
BEGIN
  FOR r IN SELECT * FROM (VALUES
      ('stubhub', substring(coalesce(p_matches->>'stubhub', '')    FROM '/event/([0-9]{4,18})')),
      ('vivid',   substring(coalesce(p_matches->>'vividseats', '') FROM '/production/([0-9]{4,18})'))) v(src, id)
  LOOP
    CONTINUE WHEN r.id IS NULL;
    BEGIN
      v_res := public.event_mapper_apply(r.src, r.id::bigint, p_tevo_event_id, NULL, NULL, p_local_date);
      IF coalesce(v_res, '') <> '' THEN v_out := v_out || r.src || ' ' || r.id || ': ' || v_res || ' '; END IF;
    EXCEPTION WHEN OTHERS THEN
      v_out := v_out || r.src || ' ' || r.id || ': error ';
    END;
  END LOOP;
  RETURN nullif(btrim(v_out), '');
END
$function$


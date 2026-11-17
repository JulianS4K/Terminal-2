-- Stand-ins for the N2S auto-buy dry run's extra skip rules (lane D7), for mig 20261113460000:
-- the tables n2s_dryrun_extra_reasons() reads and the function itself as production has it.
-- The migration's md5 guard passes only if this copy equals production's.
CREATE TABLE IF NOT EXISTS public.n2s_cover_queue (n2s_id bigint, sub_source text, sub_listing_id text, order_row text, sub_row text);
ALTER TABLE public.n2s_gt_order_dryrun
  ADD COLUMN IF NOT EXISTS decision text, ADD COLUMN IF NOT EXISTS sub_source text,
  ADD COLUMN IF NOT EXISTS sub_listing_id text, ADD COLUMN IF NOT EXISTS n2s_id bigint;
CREATE OR REPLACE FUNCTION public.n2s_section_level(p text) RETURNS text LANGUAGE sql IMMUTABLE AS $$ SELECT left(p, 1) $$;

CREATE OR REPLACE FUNCTION public.n2s_dryrun_extra_reasons(p_n2s_id bigint, p_sub_source text, p_listing text, p_section text, p_sub_section text, p_timer_expires_at timestamp with time zone)
 RETURNS text[]
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v text[] := '{}';
  a text := public.n2s_section_level(p_section);
  b text := public.n2s_section_level(p_sub_section);
  r_sold text;
  r_sub text;
BEGIN
  IF a IS NOT NULL AND b IS NOT NULL AND a <> b THEN
    v := array_append(v, 'level_mismatch');
  END IF;
  IF EXISTS (SELECT 1 FROM public.n2s_gt_order_dryrun d
              WHERE d.decision = 'would_buy' AND d.sub_source = p_sub_source
                AND d.sub_listing_id = p_listing AND d.n2s_id <> p_n2s_id) THEN
    v := array_append(v, 'listing_taken');
  END IF;
  IF p_timer_expires_at IS NOT NULL AND p_timer_expires_at - now() < interval '6 minutes' THEN
    v := array_append(v, 'not_enough_time');
  END IF;
  SELECT btrim(q.order_row), btrim(q.sub_row) INTO r_sold, r_sub
    FROM public.n2s_cover_queue q
   WHERE q.n2s_id = p_n2s_id AND q.sub_source = p_sub_source AND q.sub_listing_id = p_listing
   LIMIT 1;
  IF r_sold ~ '^[A-Za-z]+$' AND r_sub ~ '^[A-Za-z]+$'
     AND (length(r_sold) = 1) <> (length(r_sub) = 1) THEN
    v := array_append(v, 'row_letter_mismatch');
  END IF;
  RETURN v;
END $function$;

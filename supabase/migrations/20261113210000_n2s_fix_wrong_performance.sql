-- Migration 20261113210000 · level:secondary-sales · lane:D7 (N2S mapping) + A1 (CRM book) · writes:n2s_items(tevo_event_id,mapped_via),s4kcs_orders(tevo_event_id,map_method),n2s_performance_correction_log,cron:n2s_fix_wrong_performance_10min · reads:events,n2s_autobuy_exec · pre:20261113200000
--
-- N2S rows mapped to the WRONG PERFORMANCE of a multi-show run, and the self-correction for it.
--
-- Reported by the sub finder session (bot_chat 6652, 2026-11-13): three open N2S orders whose
-- tevo_event_id is a different show of the same name at the same venue than the row's own
-- event_dt (the venue-local time printed on the ticket — authoritative):
--   82468437  Vivid    Here There Are Blueberries  11-14 14:00 → mapped 3531636 (19:00)   should 3531635
--   658275850 StubHub  Buena Vista Social Club     10-29 19:30 → mapped 3413466 (10-28)   should 3413468
--   658130646 StubHub  Billy Crystal 860           12-09 19:00 → mapped 3419724 (12-10)   should 3424069
-- Verified 2026-11-13 against events.occurs_at_local.
--
-- WHY IT HAPPENS
--   1. The N2S surface hands the resolver only event_dt::date (event_mapper_surface_sql
--      'n2s_items': local_date = event_dt::date, event_time_utc = NULL). With no time, the
--      resolver's AQ-hub fallback guesses 12:00 then 19:00 and match_to_aq_event_id takes the
--      hub row inside ±6 h — so a 14:00 matinee lands on the 19:00 show (the 14:00 hub row has no
--      venue/TEvo link), and a 12-09 19:00 show lands on a hub row stored as '2026-12-10 00:00'
--      (a date-only row read as midnight, 5 h away).
--   2. n2s_crm_order_identity copies the CRM book's tevo_event_id, and the CRM book was itself
--      on the wrong night for both StubHub orders (3413466 / 3421533).
--   3. event_mapper_map_surface only ever fills an EMPTY tevo_event_id, so a wrong one is never
--      revisited.
--
-- THE FIX (deliberately narrow; the shared resolver and match_to_aq_event_id are untouched —
-- every source goes through them, and the CRM book's own UTC-date cases depend on today's
-- behaviour, see s4kcs_fix_wrong_night):
--   n2s_fix_wrong_performance(p_apply) re-points an OPEN n2s_items row when
--     · its mapped event's local start (to the minute) differs from event_dt, AND
--     · EXACTLY ONE event at the same TEvo venue with the same normalised name
--       (event_mapper_norm_name) starts at event_dt to the minute.
--   Ties, no candidate, parking passes that merely differ by a minute (no same-name event at
--   event_dt) → untouched. Never overrides mappings that came from a marketplace's own order
--   record or an operator (n2s_operator_manual, n2s_{evo,gt,vivid,sg}_order_identity). Skips a
--   row with an auto-buy attempt that has a buy order or a live lease (n2s_autobuy_exec).
--   The same order's CRM-book row (s4kcs_orders, joined by n2s_order_key) is re-pointed too when
--   it is on a different start — except CRM identity methods (order_id_*, catalog_identity,
--   night_corrected_order_id_*) — because the sub finder reads StubHub orders from that book.
--   Every change is logged in n2s_performance_correction_log; p_apply=false is a dry run.
--   Runs once now and every 10 minutes (cron :09/:19/…).

BEGIN;

CREATE TABLE IF NOT EXISTS public.n2s_performance_correction_log (
  id              bigserial PRIMARY KEY,
  n2s_id          bigint      NOT NULL,
  order_number    text,
  event_dt        timestamp,
  old_tevo_id     bigint,
  old_local       text,
  old_mapped_via  text,
  new_tevo_id     bigint      NOT NULL,
  new_local       text,
  crm_old_tevo_id bigint,
  crm_updated     boolean     NOT NULL DEFAULT false,
  corrected_at    timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE public.n2s_performance_correction_log IS
  'One row per N2S order re-pointed by n2s_fix_wrong_performance(): mapped to another performance '
  'of the same show/venue than its own event_dt. Mig 20261113210000.';
ALTER TABLE public.n2s_performance_correction_log ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.n2s_performance_correction_log FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.n2s_fix_wrong_performance(p_apply boolean DEFAULT false, p_limit integer DEFAULT 500)
 RETURNS TABLE(out_n2s_id bigint, out_order text, out_event_dt timestamp, out_old_tevo bigint, out_old_local text,
               out_new_tevo bigint, out_new_local text, out_crm_old_tevo bigint, out_action text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE rr record; v_n int; v_crm int;
BEGIN
  IF current_user NOT IN ('postgres', 'service_role', 'supabase_admin') THEN
    RAISE EXCEPTION 'n2s_fix_wrong_performance: caller % not authorized', current_user USING ERRCODE = '42501';
  END IF;

  FOR rr IN
    WITH cand AS (
      SELECT n.n2s_id, n.order_number, n.n2s_order_key, n.event_dt, n.tevo_event_id AS old_tevo,
             n.mapped_via, em.occurs_at_local AS old_local, em.venue_id,
             public.event_mapper_norm_name(em.name) AS nm,
             to_char(n.event_dt, 'YYYY-MM-DD"T"HH24:MI') AS want_min
        FROM public.n2s_items n
        JOIN public.events em ON em.id = n.tevo_event_id
       WHERE NOT coalesce(n.is_terminal, false)
         AND n.event_dt IS NOT NULL
         AND coalesce(n.mapped_via, '') NOT IN ('n2s_operator_manual', 'n2s_evo_order_identity',
               'n2s_gt_order_identity', 'n2s_vivid_order_identity', 'n2s_sg_order_identity')
         AND left(em.occurs_at_local, 16) <> to_char(n.event_dt, 'YYYY-MM-DD"T"HH24:MI')
       ORDER BY n.event_dt
       LIMIT greatest(1, least(5000, p_limit))
    )
    SELECT c.*, x.n_alt, x.alt_id, x.alt_local,
           o.tevo_event_id AS crm_tevo, o.map_method AS crm_method, eo.occurs_at_local AS crm_local,
           EXISTS (SELECT 1 FROM public.n2s_autobuy_exec ex
                    WHERE ex.n2s_id = c.n2s_id
                      AND (ex.buy_order_id IS NOT NULL OR ex.lease_until > now())) AS buy_in_flight
      FROM cand c
      CROSS JOIN LATERAL (
        SELECT count(*) AS n_alt, min(e2.id) AS alt_id, min(e2.occurs_at_local) AS alt_local
          FROM public.events e2
         WHERE e2.venue_id = c.venue_id
           AND e2.id <> c.old_tevo
           AND left(e2.occurs_at_local, 16) = c.want_min
           AND public.event_mapper_norm_name(e2.name) = c.nm) x
      LEFT JOIN public.s4kcs_orders o ON o.s4k_order_id = c.n2s_order_key
      LEFT JOIN public.events eo ON eo.id = o.tevo_event_id
     WHERE x.n_alt >= 1
  LOOP
    out_n2s_id := rr.n2s_id; out_order := rr.order_number; out_event_dt := rr.event_dt;
    out_old_tevo := rr.old_tevo; out_old_local := rr.old_local;
    out_new_tevo := CASE WHEN rr.n_alt = 1 THEN rr.alt_id END;
    out_new_local := CASE WHEN rr.n_alt = 1 THEN rr.alt_local END;
    out_crm_old_tevo := rr.crm_tevo;

    IF rr.n_alt > 1 THEN
      out_action := 'decline_ambiguous';
    ELSIF rr.buy_in_flight THEN
      out_action := 'decline_autobuy_in_flight';
    ELSIF NOT p_apply THEN
      out_action := 'would_correct';
    ELSE
      UPDATE public.n2s_items
         SET tevo_event_id = rr.alt_id, mapped_via = 'n2s_performance_corrected'
       WHERE n2s_id = rr.n2s_id AND tevo_event_id = rr.old_tevo;
      GET DIAGNOSTICS v_n = ROW_COUNT;

      v_crm := 0;
      IF v_n > 0 AND rr.crm_tevo IS NOT NULL AND rr.crm_tevo <> rr.alt_id
         AND left(rr.crm_local, 16) IS DISTINCT FROM rr.want_min
         AND coalesce(rr.crm_method, '') !~ '^(order_id_|catalog_identity|night_corrected_order_id_)' THEN
        UPDATE public.s4kcs_orders
           SET tevo_event_id = rr.alt_id, map_method = 'n2s_event_dt_corrected',
               map_confidence = 0.97, mapped_at = now()
         WHERE s4k_order_id = rr.n2s_order_key AND tevo_event_id = rr.crm_tevo;
        GET DIAGNOSTICS v_crm = ROW_COUNT;
      END IF;

      IF v_n > 0 THEN
        INSERT INTO public.n2s_performance_correction_log
               (n2s_id, order_number, event_dt, old_tevo_id, old_local, old_mapped_via,
                new_tevo_id, new_local, crm_old_tevo_id, crm_updated)
        VALUES (rr.n2s_id, rr.order_number, rr.event_dt, rr.old_tevo, rr.old_local, rr.mapped_via,
                rr.alt_id, rr.alt_local, rr.crm_tevo, v_crm > 0);
        out_action := CASE WHEN v_crm > 0 THEN 'corrected_n2s_and_crm' ELSE 'corrected_n2s' END;
      ELSE
        out_action := 'skipped_row_changed';
      END IF;
    END IF;
    RETURN NEXT;
  END LOOP;
END $function$;

REVOKE ALL ON FUNCTION public.n2s_fix_wrong_performance(boolean, integer) FROM PUBLIC, anon, authenticated;
COMMENT ON FUNCTION public.n2s_fix_wrong_performance(boolean, integer) IS
  'Re-point open N2S rows mapped to another performance of the same show/venue than their own '
  'event_dt (exactly one same-name event at the same venue at event_dt), plus the same order''s '
  'CRM-book row. p_apply=false = dry run. Logged in n2s_performance_correction_log. Mig 20261113210000.';

-- The rows wrong today (3 on 2026-11-13).
SELECT out_order, out_old_tevo, out_new_tevo, out_action FROM public.n2s_fix_wrong_performance(true, 5000);

-- And from now on: every 10 minutes, after the mapper passes at :07/:08.
DO $cron$
BEGIN
  IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'n2s_fix_wrong_performance_10min') THEN
    PERFORM cron.unschedule('n2s_fix_wrong_performance_10min');
  END IF;
  PERFORM cron.schedule('n2s_fix_wrong_performance_10min', '9-59/10 * * * *',
                        'SELECT count(*) FROM public.n2s_fix_wrong_performance(true, 500);');
END
$cron$;

COMMIT;

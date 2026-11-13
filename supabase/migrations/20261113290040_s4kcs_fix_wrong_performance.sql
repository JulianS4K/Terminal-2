-- Migration 20261113290040 · level:secondary-sales · lane:A1 (CRM book) · writes:s4kcs_orders(tevo_event_id,map_method,market ids),s4kcs_performance_correction_log,cron:s4kcs_fix_wrong_performance_30min · reads:events,gotickets_sales,vivid_orders,tickpick_orders,seatgeek_orders,n2s_items,manual_sub_buy · pre:20261113270000
-- A1 · CRM book (s4kcs_orders): re-point future orders mapped to the wrong performance, using the
-- show time from our own order books. Operator 2026-11-13: "Repair + review list".
--
-- WHY. A read-only audit (2026-11-13) of future s4kcs_orders found 138 orders on a different night
-- from a same-name event at the same venue; 52 are proven wrong by our own GoTickets / Vivid /
-- TickPick / SeatGeek books. Two causes, opposite directions:
--   · the previous night's late show: s4kcs_map_events joins on the CRM date only and takes
--     min(tevo_event_id); those rows are fill-only and never revisited;
--   · the next night's show: the aq_tier fallback guesses 12:00/19:00 and its ±6 h window catches
--     date-only hub rows stored as the next day 00:00.
-- The audit also compared the CRM event_date with the local show date from those books on ~36k
-- orders: equal in all but 18 (TBD playoff placeholders, rescheduled shows). So the CRM date is
-- the LOCAL show date, and s4kcs_fix_wrong_night()'s premise ("some markets send the UTC date")
-- does not hold: as written it would fix 4 of the 52, one onto the wrong show, and keep 21 as
-- "incumbent right". It stays unscheduled; this function supersedes it.
--
-- THE FIX. s4kcs_fix_wrong_performance(p_apply, p_limit) looks at future rows, except mappings that
-- came from a marketplace's own order record (map_method order_id_*, catalog_identity,
-- night_corrected_order_id_*) and rows with a manual sub buy (manual_sub_buy.sale_order_number).
--   Rule 'time': the order's show time from our own books — gotickets_sales.event_time_local,
--     vivid_orders.event_date (local wall clock stored as UTC), tickpick raw event_date (local),
--     seatgeek sg_event_date + sg_event_time, n2s_items.event_dt — when every book that has the
--     order agrees on one minute, and that minute is on the CRM date. 23:59 / 00:00 are TBD
--     placeholders and are ignored. If the mapped event starts at another minute and EXACTLY ONE
--     event at the same TEvo venue with the same normalised name (event_mapper_norm_name) starts
--     at that minute, re-point to it.
--   Rule 'day': no book time (mostly StubHub / Gametime). If the mapped event is one day off the
--     CRM date, is 'shown', and EXACTLY ONE same-name event at the same venue is on the CRM date,
--     re-point to it. Two or more (matinee + evening) → review list; nothing guessed.
-- A re-point also clears the per-event marketplace ids derived from the old event (gt/tdev/
-- vivid/sh/sg/tm/tp/paciolan ids, aq_short_event_id, market_ids_via), so the 15-minute linkers
-- (cron id_spine_tick_15min) re-derive them for the right performance — those linkers are
-- fill-only and would otherwise keep the wrong night's ids, which the sub finder reads.
-- Every change is logged in s4kcs_performance_correction_log. p_apply=false is a dry run; rows it
-- cannot fix come back as review_* (the review list):
--   select * from s4kcs_fix_wrong_performance(false, 50000) where out_action like 'review%';
-- Nothing here touches the shared matchers (s4kcs_map_events, event_mapper_*, match_to_aq_event_id).
-- Runs once now, then at :17 and :47 (≈7 s on prod for ~20k future rows).

BEGIN;

CREATE TABLE IF NOT EXISTS public.s4kcs_performance_correction_log (
  id              bigserial PRIMARY KEY,
  source          text        NOT NULL,
  s4k_order_id    text        NOT NULL,
  crm_date        date,
  rule            text        NOT NULL,
  book_time       text,
  book_source     text,
  old_tevo_id     bigint,
  old_local       text,
  old_map_method  text,
  new_tevo_id     bigint,
  new_local       text,
  corrected_at    timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.s4kcs_performance_correction_log ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.s4kcs_performance_correction_log FROM anon, authenticated;
CREATE INDEX IF NOT EXISTS s4kcs_perf_corr_log_order_idx
  ON public.s4kcs_performance_correction_log (s4k_order_id);

CREATE OR REPLACE FUNCTION public.s4kcs_fix_wrong_performance(p_apply boolean DEFAULT false,
                                                             p_limit integer DEFAULT 500)
 RETURNS TABLE(out_source text, out_order text, out_crm_date date, out_rule text,
               out_book_time text, out_book_source text,
               out_old_tevo bigint, out_old_local text, out_old_method text,
               out_new_tevo bigint, out_new_local text, out_action text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE rr record; v_n int; v_done int := 0;
BEGIN
  IF current_user NOT IN ('postgres', 'service_role', 'supabase_admin') THEN
    RAISE EXCEPTION 's4kcs_fix_wrong_performance: caller % not authorized', current_user
      USING ERRCODE = '42501';
  END IF;

  FOR rr IN
    WITH base AS (
      SELECT o.source, o.s4k_order_id, o.event_date, o.map_method, o.tevo_event_id AS cur,
             e.occurs_at_local AS cur_loc, e.venue_id, e.state AS cur_state,
             public.event_mapper_norm_name(e.name) AS nm
        FROM public.s4kcs_orders o
        JOIN public.events e ON e.id = o.tevo_event_id
       WHERE o.event_date >= current_date
         AND coalesce(o.map_method, '') !~ '^(order_id_|catalog_identity|night_corrected_order_id_)'
    ), bt AS (
      SELECT b.*, t.n_times, t.book_min, t.book_src
        FROM base b
        LEFT JOIN LATERAL (
          SELECT count(DISTINCT x.m) AS n_times, min(x.m) AS book_min,
                 string_agg(DISTINCT x.src, ',') AS book_src
            FROM (
              SELECT 'gotickets_sales' AS src, to_char(g.event_time_local, 'YYYY-MM-DD"T"HH24:MI') AS m
                FROM public.gotickets_sales g
               WHERE b.source = 'GoTickets'
                 AND g.gt_sale_id = (CASE WHEN b.s4k_order_id ~ '^[0-9]{1,18}$'
                                          THEN b.s4k_order_id::bigint END)
              UNION ALL
              SELECT 'vivid_orders', to_char(v.event_date AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI')
                FROM public.vivid_orders v
               WHERE b.source = 'Vivid Seats' AND v.vivid_order_id = b.s4k_order_id
              UNION ALL
              SELECT 'tickpick_orders', left(t.raw->>'event_date', 16)
                FROM public.tickpick_orders t
               WHERE b.source = 'TickPick' AND t.tp_order_id = b.s4k_order_id
                 AND t.raw->>'event_date' ~ '^\d{4}-\d\d-\d\dT\d\d:\d\d'
              UNION ALL
              SELECT 'seatgeek_orders', to_char(s.sg_event_date, 'YYYY-MM-DD') || 'T' || left(s.sg_event_time, 5)
                FROM public.seatgeek_orders s
               WHERE b.source = 'SeatGeek' AND s.sg_order_id = b.s4k_order_id
                 AND s.sg_event_date IS NOT NULL AND s.sg_event_time ~ '^\d\d:\d\d'
              UNION ALL
              SELECT 'n2s_items', to_char(n.event_dt, 'YYYY-MM-DD"T"HH24:MI')
                FROM public.n2s_items n
               WHERE n.event_dt IS NOT NULL
                 AND (n.order_number = b.s4k_order_id OR n.n2s_order_key = b.s4k_order_id)
            ) x
           WHERE right(x.m, 5) NOT IN ('23:59', '00:00')   -- TBD placeholders, not a show time
        ) t ON true
    ), cand AS (
      SELECT bt.*,
             CASE
               WHEN bt.n_times > 1 THEN 'review_book_times_disagree'
               WHEN bt.n_times = 1 AND left(bt.book_min, 10) <> bt.event_date::text
                    THEN 'review_book_day_not_crm_day'
               WHEN bt.n_times = 1 AND left(bt.cur_loc, 16) = bt.book_min THEN 'ok'
               WHEN bt.n_times = 1 THEN 'time'
               WHEN left(bt.cur_loc, 10) = bt.event_date::text THEN 'ok'
               WHEN left(bt.cur_loc, 10) !~ '^\d{4}-\d\d-\d\d$' THEN 'review_mapped_event_no_date'
               WHEN abs(left(bt.cur_loc, 10)::date - bt.event_date) <> 1 THEN 'review_mapped_day_far'
               WHEN bt.cur_state IS DISTINCT FROM 'shown' THEN 'review_mapped_event_not_shown'
               ELSE 'day'
             END AS rule
        FROM bt
    )
    SELECT c.source, c.s4k_order_id, c.event_date, c.map_method, c.cur, left(c.cur_loc, 16) AS cur_loc,
           c.book_min, c.book_src, c.rule, a.n_alt, a.alt_id, a.alt_loc,
           EXISTS (SELECT 1 FROM public.manual_sub_buy m
                    WHERE m.sale_order_number = c.s4k_order_id) AS has_sub_buy
      FROM cand c
      LEFT JOIN LATERAL (
        SELECT count(*) AS n_alt, min(e2.id) AS alt_id, min(left(e2.occurs_at_local, 16)) AS alt_loc
          FROM public.events e2
         WHERE e2.venue_id = c.venue_id
           AND e2.id <> c.cur
           AND coalesce(e2.state, '') <> 'ignored'
           AND left(e2.occurs_at_local, 10) = CASE WHEN c.rule = 'time' THEN left(c.book_min, 10)
                                                   ELSE c.event_date::text END
           AND (c.rule <> 'time' OR left(e2.occurs_at_local, 16) = c.book_min)
           AND public.event_mapper_norm_name(e2.name) = c.nm
      ) a ON c.rule IN ('time', 'day')
     WHERE c.rule <> 'ok'
     ORDER BY c.event_date, c.s4k_order_id
  LOOP
    out_source := rr.source; out_order := rr.s4k_order_id; out_crm_date := rr.event_date;
    out_rule := rr.rule; out_book_time := rr.book_min; out_book_source := rr.book_src;
    out_old_tevo := rr.cur; out_old_local := rr.cur_loc; out_old_method := rr.map_method;
    out_new_tevo := NULL; out_new_local := NULL;

    IF rr.rule LIKE 'review%' THEN
      out_action := rr.rule;
    ELSIF rr.n_alt = 0 THEN
      out_action := CASE WHEN rr.rule = 'time' THEN 'no_event_at_book_time'   -- e.g. TEvo time off by minutes
                         ELSE 'review_no_same_name_event_on_crm_day' END;
    ELSIF rr.n_alt > 1 THEN
      out_action := 'review_several_shows_on_crm_day';
    ELSIF rr.has_sub_buy THEN
      out_new_tevo := rr.alt_id; out_new_local := rr.alt_loc;
      out_action := 'review_manual_sub_buy_exists';
    ELSE
      out_new_tevo := rr.alt_id; out_new_local := rr.alt_loc;
      out_action := 'would_correct';
      IF p_apply AND v_done < greatest(1, p_limit) THEN
        UPDATE public.s4kcs_orders
           SET tevo_event_id = rr.alt_id,
               map_method = 'perf_corrected_' || rr.rule, map_confidence = 0.97, mapped_at = now(),
               aq_short_event_id = NULL,
               gt_event_id = NULL, gt_mapped_via = NULL, gt_mapped_at = NULL,
               tdev_id = NULL, tdev_mapped_via = NULL, tdev_mapped_at = NULL,
               vivid_event_id = NULL, sh_event_id = NULL, sg_event_id = NULL, tm_event_id = NULL,
               tp_event_id = NULL, paciolan_event_id = NULL,
               market_ids_via = NULL, market_ids_at = NULL
         WHERE source = rr.source AND s4k_order_id = rr.s4k_order_id AND tevo_event_id = rr.cur;
        GET DIAGNOSTICS v_n = ROW_COUNT;
        IF v_n > 0 THEN
          INSERT INTO public.s4kcs_performance_correction_log
                 (source, s4k_order_id, crm_date, rule, book_time, book_source,
                  old_tevo_id, old_local, old_map_method, new_tevo_id, new_local)
          VALUES (rr.source, rr.s4k_order_id, rr.event_date, rr.rule, rr.book_min, rr.book_src,
                  rr.cur, rr.cur_loc, rr.map_method, rr.alt_id, rr.alt_loc);
          v_done := v_done + 1;
          out_action := 'corrected';
        ELSE
          out_action := 'skipped_row_changed';
        END IF;
      END IF;
    END IF;
    RETURN NEXT;
  END LOOP;
END $function$;

REVOKE ALL ON FUNCTION public.s4kcs_fix_wrong_performance(boolean, integer) FROM PUBLIC, anon, authenticated;
COMMENT ON FUNCTION public.s4kcs_fix_wrong_performance(boolean, integer) IS
  'Re-point future CRM-book orders mapped to the wrong performance: to the one same-name event at '
  'the same venue at the show time our own order books give (rule time), else, with no book time, '
  'to the one same-name event on the CRM date when the mapped event is a day off (rule day). '
  'p_apply=false = dry run; review_* rows are the review list. Logged in '
  's4kcs_performance_correction_log. Mig 20261113290040.';

COMMENT ON FUNCTION public.s4kcs_fix_wrong_night(boolean, integer) IS
  'DO NOT SCHEDULE. Built on "some markets send the CRM date in UTC", which a 2026-11-13 audit of '
  '~36k orders disproved (the CRM date is the local show date). Superseded by '
  's4kcs_fix_wrong_performance (mig 20261113290040).';

-- The rows wrong today (dry run on prod 2026-11-13: ~110 would be corrected).
SELECT out_action, count(*) FROM public.s4kcs_fix_wrong_performance(true, 5000) GROUP BY 1;

-- And from now on, twice an hour, after the CRM mapper (:07) and the linkers' :15 tick.
DO $cron$
BEGIN
  IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 's4kcs_fix_wrong_performance_30min') THEN
    PERFORM cron.unschedule('s4kcs_fix_wrong_performance_30min');
  END IF;
  PERFORM cron.schedule('s4kcs_fix_wrong_performance_30min', '17,47 * * * *',
                        'SELECT count(*) FROM public.s4kcs_fix_wrong_performance(true, 500);');
END
$cron$;

COMMIT;

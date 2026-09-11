-- ============================================================================
-- Migration 20260911200100 — our purchase books map through THE event mapper (first switched caller)
-- Migration 20260911200100 · level:data-collection · lane:A1 · writes:gotickets_purchases,seatgeek_purchases,cron_policy,cron.job
--
-- Lane:     A1 (data plane) serving D0's deals surface
-- Touches:  gotickets_purchases (W: tevo_event_id/mapped_via/map_score), seatgeek_purchases (W: same),
--           v_event_mapper_needs (REPLACE — adds both purchase books), cron_policy (W), cron.job (W)
-- Pre-reqs: 20260911200000 (event_mapper_resolve + cold path), 20260911160500 (the purchase books —
--           applied in prod 2026-09-11; file on branch claude/underpriced-listing-detector-8hdzzb),
--           20260911161000 (our_purchases_map v1 + map_score — applied in prod; same branch)
--
-- NOT APPLIED. Authored 2026-09-11. Supersedes the UNAPPLIED 20260911161100_our_purchases_map_evo.sql
-- (same branch): its per-table matching SQL becomes one call per row into event_mapper_resolve(),
-- and its cold path is now the SHARED one in 20260911200000 (which also serves s4kcs / N2S /
-- TickPick / Vivid needs — one TEvo venue pull per venue instead of one per surface).
--
-- Starting point: 633 GoTickets purchases, 579 mapped by mig 161000, 54 left (KANBAN D0-DEALS-1).
-- Read-only replay of the resolver over those 54 on 2026-09-11 (rule 1, on prod rows):
--   7 map now — the two "Boston Red Sox at Seattle Mariners" twins → the NON-rescheduled game
--   (3318381); "(Rescheduled from 5/24)" Cardinals → the rescheduled twin (3101899); the
--   Pirates Cowboy-Hat game → 3157083 not the rescheduled 3157006; BNP Session 9 → 3366806 and
--   Session 10 → 3366809; "WWE Friday Night Smackdown" → "WWE RAW and SmackDown" (single
--   candidate, 0.5 floor). 47 need the cold path: 17 World Cup matches, 8 Broadway, 3 college FB,
--   the Hammerstein / Winter Garden-NY / Pacha venue strings, and the two TBD rows (never mapped
--   by design). Their venues have NO mirror event on those days — that is what the shared
--   venue-events pull is for; whether TEvo still lists a past date is learned on the first run.
--
-- ROLLBACK: cron.unschedule('our_purchases_map_hourly'); DELETE FROM cron_policy WHERE jobname='our_purchases_map_hourly';
--   re-apply our_purchases_map() from mig 20260911161000; re-apply v_event_mapper_needs from 20260911200000.
-- ============================================================================

ALTER TABLE public.seatgeek_purchases  ADD COLUMN IF NOT EXISTS map_score numeric;
ALTER TABLE public.gotickets_purchases ADD COLUMN IF NOT EXISTS map_score numeric;

-- ── 1. Needs union now includes both purchase books ─────────────────────────
CREATE OR REPLACE VIEW public.v_event_mapper_needs AS
  SELECT 's4kcs_orders'::text AS surface, o.s4k_order_id AS row_key, lower(o.source) AS source,
         NULL::bigint AS source_event_id, o.event_name, NULL::text AS performer,
         o.venue_name, o.venue_city, o.venue_state, o.event_date AS local_date, NULL::timestamptz AS event_time_utc
    FROM public.s4kcs_orders o
   WHERE o.tevo_event_id IS NULL AND o.event_date >= current_date - 30
  UNION ALL
  SELECT 'n2s_items', n.n2s_id::text, lower(n.marketplace), NULL, n.event_name, NULL,
         n.venue, NULL, NULL, n.event_dt::date, NULL
    FROM public.n2s_items n
   WHERE n.tevo_event_id IS NULL AND coalesce(n.is_terminal, false) = false AND n.event_dt IS NOT NULL
  UNION ALL
  SELECT 'tickpick_orders', t.tp_order_id, 'tickpick', NULL, t.event_name, NULL,
         NULL, NULL, NULL, t.event_date::date, t.event_date
    FROM public.tickpick_orders t
   WHERE t.tevo_event_id IS NULL AND t.event_date >= now() - interval '90 days'
  UNION ALL
  SELECT 'vivid_orders', v.vivid_order_id, 'vivid', NULL, v.event_name, NULL,
         NULL, NULL, NULL, v.event_date::date, v.event_date
    FROM public.vivid_orders v
   WHERE v.tevo_event_id IS NULL AND v.event_date >= now() - interval '90 days'
  UNION ALL
  SELECT 'gotickets_purchases', g.gt_purchase_id::text, 'gotickets', g.gt_event_id, g.event_name,
         g.performers->0->>'name', g.venue_name, g.venue_city, g.venue_state,
         g.event_time_local::date, g.event_time_utc
    FROM public.gotickets_purchases g
   WHERE g.tevo_event_id IS NULL AND g.event_time_local IS NOT NULL
  UNION ALL
  SELECT 'seatgeek_purchases', s.order_id, 'seatgeek', s.sg_event_id, s.event_name, NULL,
         s.event_location, NULL, NULL, s.event_start::date, NULL
    FROM public.seatgeek_purchases s
   WHERE s.tevo_event_id IS NULL AND s.event_start IS NOT NULL;
COMMENT ON VIEW public.v_event_mapper_needs IS
  'Every unmapped marketplace row (surface, row_key, resolver inputs) the shared cold path feeds on: s4kcs / N2S / TickPick / Vivid (mig 20260911200000) + our GoTickets & SeatGeek purchase books (mig 20260911200100).';

-- ── 2. The applier: one resolver call per unmapped purchase ─────────────────
CREATE OR REPLACE FUNCTION public.our_purchases_map()
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $fn$
DECLARE v_gt jsonb; v_sg jsonb; v_gt_n int := 0; v_sg_n int := 0;
BEGIN
  IF current_user NOT IN ('service_role', 'postgres', 'supabase_admin') THEN
    RAISE EXCEPTION 'forbidden: %', current_user USING ERRCODE = '42501';
  END IF;
  PERFORM set_config('statement_timeout', '150000', true);

  WITH u AS (
    SELECT p.gt_purchase_id, r.tevo_event_id, r.method, r.score
      FROM public.gotickets_purchases p
      JOIN LATERAL public.event_mapper_resolve('gotickets', p.gt_event_id, p.event_name, p.performers->0->>'name',
             p.venue_name, p.venue_city, p.venue_state, p.event_time_local::date, p.event_time_utc, true, 0.5) r ON true
     WHERE p.tevo_event_id IS NULL
  ), up AS (
    UPDATE public.gotickets_purchases p
       SET tevo_event_id = u.tevo_event_id, mapped_via = u.method, map_score = u.score, updated_at = now()
      FROM u WHERE u.gt_purchase_id = p.gt_purchase_id
    RETURNING u.method
  )
  SELECT coalesce(sum(m.n), 0)::int, coalesce(jsonb_object_agg(m.method, m.n), '{}'::jsonb)
    INTO v_gt_n, v_gt
    FROM (SELECT method, count(*) AS n FROM up GROUP BY method) m;

  WITH u AS (
    SELECT p.order_id, r.tevo_event_id, r.method, r.score
      FROM public.seatgeek_purchases p
      JOIN LATERAL public.event_mapper_resolve('seatgeek', p.sg_event_id, p.event_name, NULL,
             p.event_location, NULL, NULL, p.event_start::date, NULL, true, 0.5) r ON true
     WHERE p.tevo_event_id IS NULL
  ), up AS (
    UPDATE public.seatgeek_purchases p
       SET tevo_event_id = u.tevo_event_id, mapped_via = u.method, map_score = u.score, updated_at = now()
      FROM u WHERE u.order_id = p.order_id
    RETURNING u.method
  )
  SELECT coalesce(sum(m.n), 0)::int, coalesce(jsonb_object_agg(m.method, m.n), '{}'::jsonb)
    INTO v_sg_n, v_sg
    FROM (SELECT method, count(*) AS n FROM up GROUP BY method) m;

  RETURN jsonb_build_object(
    'gt_mapped_now', v_gt_n, 'gt_by', v_gt,
    'sg_mapped_now', v_sg_n, 'sg_by', v_sg,
    'gt_unmapped', (SELECT count(*) FROM public.gotickets_purchases WHERE tevo_event_id IS NULL),
    'sg_unmapped', (SELECT count(*) FROM public.seatgeek_purchases WHERE tevo_event_id IS NULL));
END $fn$;
REVOKE ALL ON FUNCTION public.our_purchases_map() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.our_purchases_map() TO service_role;
COMMENT ON FUNCTION public.our_purchases_map() IS
  'Fill tevo_event_id on unmapped GoTickets / SeatGeek purchases with ONE event_mapper_resolve() call per row (mapped_via = resolver method, map_score = its score). Ambiguous stays unmapped; the shared cold path (event_mapper_deep_*) brings the venue/events in. A1 mig 20260911200100 (v1: 161000).';

-- ── 3. Hourly applier (the purchase pollers land rows every 30 min) ─────────
INSERT INTO public.cron_policy (jobname, peak_hours_et, peak_min_interval_min, offpeak_min_interval_min, work_check_sql, daily_max_fires, notes)
VALUES ('our_purchases_map_hourly',
        ARRAY[0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23], 55, 55,
        'SELECT EXISTS (SELECT 1 FROM public.gotickets_purchases WHERE tevo_event_id IS NULL UNION ALL SELECT 1 FROM public.seatgeek_purchases WHERE tevo_event_id IS NULL)',
        24, 'Map freshly pulled purchases through event_mapper_resolve(); skips when nothing is unmapped. mig 20260911200100')
ON CONFLICT (jobname) DO UPDATE
  SET work_check_sql = excluded.work_check_sql, notes = excluded.notes, updated_at = now();

DO $cron$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    PERFORM cron.unschedule('our_purchases_map_hourly')
      WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'our_purchases_map_hourly');
    PERFORM cron.schedule('our_purchases_map_hourly', '27 * * * *', $body$
      DO $b$ BEGIN IF NOT public.cron_should_fire('our_purchases_map_hourly') THEN RETURN; END IF;
        PERFORM public.our_purchases_map();
      END $b$;$body$);
  END IF;
END;
$cron$;

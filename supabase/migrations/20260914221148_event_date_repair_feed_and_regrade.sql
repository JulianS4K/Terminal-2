-- Migration 20260914221148 · reconstructed from prod · writes: see body
--
-- Recorded 2026-11-17 (branch triage): applied on prod as "event_date_repair_feed_and_regrade" (version 20260914221148) but present in no
-- file in git. Body is prod's own supabase_migrations.schema_migrations.statements for that row,
-- statements separated by ';'. Recording only — it is already applied; do not re-apply.

UPDATE public.gotickets_deals_feed f
   SET event_date = public.deal_event_datetime(sgc.sg_datetime_utc, ge.event_time_utc, e.occurs_at_local)::date
  FROM public.events e
  LEFT JOIN public.sg_events_canonical sgc ON sgc.tevo_event_id = e.id
  LEFT JOIN public.gotickets_event ge      ON ge.tevo_event_id = e.id
 WHERE e.id = f.tevo_event_id
   AND f.event_date IS DISTINCT FROM
       public.deal_event_datetime(sgc.sg_datetime_utc, ge.event_time_utc, e.occurs_at_local)::date;

DELETE FROM public.gotickets_deal_outcome o
 USING public.events e
 WHERE e.id = o.tevo_event_id
   AND public.deal_event_datetime(
         (SELECT sgc.sg_datetime_utc FROM public.sg_events_canonical sgc WHERE sgc.tevo_event_id = e.id),
         (SELECT ge.event_time_utc  FROM public.gotickets_event ge      WHERE ge.tevo_event_id = e.id),
         e.occurs_at_local)::date >= current_date;
;

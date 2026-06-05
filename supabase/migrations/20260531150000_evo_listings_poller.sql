-- ============================================================
-- MIG-B — EVO per-event listings poller (band-driven), + SG strand-fix column.
-- A1 2026-05-31 (cadence redesign Part A2/A4).
--
-- EVO listings move from 5 coarse windowed crons to ONE per-event tick that fires
-- collect-listings?event_id=X at each event's horizon-band interval. Per-event clock
-- lives in evo_listings_poll_state, stamped synchronously on fire (no matview lag →
-- no double-pull). Tracked set = chat-tracked OR watched OR owned-inventory.
-- ============================================================
CREATE TABLE IF NOT EXISTS public.evo_listings_poll_state (
  event_id bigint PRIMARY KEY REFERENCES public.events(id) ON DELETE CASCADE,
  last_polled_listings_at timestamptz,
  listings_polls_today int NOT NULL DEFAULT 0,
  budget_day date NOT NULL DEFAULT current_date
);
CREATE INDEX IF NOT EXISTS idx_evo_poll_state_due ON public.evo_listings_poll_state (last_polled_listings_at NULLS FIRST);
REVOKE ALL ON TABLE public.evo_listings_poll_state FROM anon;

CREATE OR REPLACE FUNCTION public.evo_listings_poll_tick(p_max int DEFAULT 30)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public','pg_temp'
AS $function$
DECLARE r RECORD; v_n int := 0;
BEGIN
  IF p_max <= 0 THEN RETURN 0; END IF;
  FOR r IN
    WITH ev AS (
      SELECT e.id,
             EXTRACT(epoch FROM (e.occurs_at_local::timestamptz - now()))/3600.0 AS hte,
             ps.last_polled_listings_at
      FROM public.events e
      LEFT JOIN public.evo_listings_poll_state ps ON ps.event_id = e.id
      WHERE e.occurs_at_local IS NOT NULL
        AND e.occurs_at_local::timestamptz > now() - interval '3 hours'
        AND ( e.is_chat_tracked = true
              OR EXISTS (SELECT 1 FROM public.watch_sources w WHERE w.event_id = e.id)
              OR EXISTS (SELECT 1 FROM public.latest_event_metrics m
                         WHERE m.event_id = e.id AND m.owned_tickets_count > 0) )
    ),
    due AS (
      SELECT ev.id, ev.last_polled_listings_at
      FROM ev
      JOIN LATERAL public.collector_band('EVO','listings', ev.hte) c ON true
      WHERE ev.last_polled_listings_at IS NULL
         OR ev.last_polled_listings_at < now() - make_interval(mins => c.required_min)
    )
    SELECT id FROM due ORDER BY last_polled_listings_at NULLS FIRST LIMIT p_max
  LOOP
    PERFORM public._cron_invoke_edge_fn(
      'https://hzrizjeaxlqcxfrtczpq.supabase.co/functions/v1/collect-listings?event_id=' || r.id::text,
      '{}'::jsonb);
    INSERT INTO public.evo_listings_poll_state(event_id, last_polled_listings_at, listings_polls_today, budget_day)
      VALUES (r.id, now(), 1, current_date)
      ON CONFLICT (event_id) DO UPDATE SET
        last_polled_listings_at = now(),
        listings_polls_today = CASE WHEN evo_listings_poll_state.budget_day < current_date
                                    THEN 1 ELSE evo_listings_poll_state.listings_polls_today + 1 END,
        budget_day = current_date;
    v_n := v_n + 1;
  END LOOP;
  RETURN v_n;
END $function$;
REVOKE ALL ON FUNCTION public.evo_listings_poll_tick(int) FROM anon, PUBLIC;

-- SG strand-fix: "fired" (provisional) distinct from "polled" (confirmed on HTTP 200).
ALTER TABLE public.sg_event_priority_state
  ADD COLUMN IF NOT EXISTS last_fired_listings_at timestamptz;

-- Migration 20261113290000 · level:secondary-sales · lane:D0 · writes:sub_finder_config,sub_finder_td_wanted,sub_finder_settle · reads:sub_finder_order · pre:20261113260000
--
-- SUB FINDER: TicketsData can search for orders that already have a cover.
--
-- Until now TicketsData (StubHub, Vivid and the other markets we do not read ourselves) was
-- asked only for an order that EVO, GoTickets and SeatGeek found nothing for. An order with a
-- poor cover (a different zone, a loss) never saw what those other markets had.
--
-- sub_finder_config.td_scope chooses which orders ask TicketsData:
--   'no_cover'        only orders with no cover at all (the behaviour so far; the default)
--   'not_one_to_one'  also orders whose best cover is not gate 1 (same seats, profitable)
--   'all'             every order
-- It only matters while td_enabled is on. The limits are unchanged: at most
-- td_max_events_per_job events per job, td_concurrency in flight. Each event asked costs
-- 12 credits + 1 report, so a wider scope spends more. Events with a no-cover order are
-- asked first when a job has more events than the limit.
--
-- An order that already has a cover keeps showing it while TicketsData is asked (it is not
-- put back to 'pending'), so nothing is delayed: the first match and any automatic buy have
-- already run. When the answer lands the order is matched again and the TicketsData covers
-- are merged with the ones it had. If the search fails the order keeps its covers.
--
-- sub_finder_settle is patched in place; each patch fails loudly if its anchor is not there
-- exactly once, and the whole block does nothing on a second run.
--
-- rollback: UPDATE public.sub_finder_config SET td_scope = 'no_cover' WHERE id = true;
--           (to remove: re-apply sub_finder_settle from 20261113260000 and its predecessors,
--            DROP FUNCTION public.sub_finder_td_wanted(text, text, jsonb),
--            ALTER TABLE public.sub_finder_config DROP COLUMN td_scope.)

ALTER TABLE public.sub_finder_config
  ADD COLUMN IF NOT EXISTS td_scope text NOT NULL DEFAULT 'no_cover';

DO $chk$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'sub_finder_config_td_scope_check') THEN
    ALTER TABLE public.sub_finder_config
      ADD CONSTRAINT sub_finder_config_td_scope_check
      CHECK (td_scope IN ('no_cover', 'not_one_to_one', 'all'));
  END IF;
END
$chk$;

-- Does this order ask TicketsData, under the chosen scope?
CREATE OR REPLACE FUNCTION public.sub_finder_td_wanted(p_scope text, p_state text, p_best jsonb)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
SET search_path = public, pg_temp
AS $function$
  SELECT CASE
    WHEN p_state = 'no_cover' THEN true
    WHEN p_state <> 'cover'   THEN false
    WHEN p_scope = 'all'      THEN true
    WHEN p_scope = 'not_one_to_one' THEN coalesce((p_best ->> 'gate')::int, 9) > 1
    ELSE false END
$function$;

REVOKE ALL ON FUNCTION public.sub_finder_td_wanted(text, text, jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.sub_finder_td_wanted(text, text, jsonb) TO service_role;

DO $patch$
DECLARE
  v_def text := pg_get_functiondef('public.sub_finder_settle(uuid)'::regprocedure);
  v_pairs text[][] := ARRAY[
    -- which events to ask: count the no-cover orders too, to ask those events first
    [$o$FROM (SELECT tevo_event_id, count(*) AS n FROM public.sub_finder_order$o$,
     $n$FROM (SELECT tevo_event_id, count(*) AS n, count(*) FILTER (WHERE state = 'no_cover') AS n0 FROM public.sub_finder_order$n$],
    [$o$WHERE job_id = p_job_id AND state = 'no_cover' GROUP BY 1) e$o$,
     $n$WHERE job_id = p_job_id AND public.sub_finder_td_wanted(c.td_scope, state, best) GROUP BY 1) e$n$],
    [$o$ORDER BY e.n DESC, e.tevo_event_id LIMIT c.td_max_events_per_job$o$,
     $n$ORDER BY e.n0 DESC, e.n DESC, e.tevo_event_id LIMIT c.td_max_events_per_job$n$],
    -- which orders get a TicketsData state
    [$o$WHERE o.job_id = p_job_id AND o.state = 'no_cover';$o$,
     $n$WHERE o.job_id = p_job_id AND public.sub_finder_td_wanted(c.td_scope, o.state, o.best);$n$],
    -- only an order with no cover waits as 'pending'; one with a cover keeps showing it
    [$o$WHERE job_id = p_job_id AND td_state = 'queued';$o$,
     $n$WHERE job_id = p_job_id AND td_state = 'queued' AND state = 'no_cover';$n$],
    -- the answer landed: an order that already had a cover is matched again
    [$o$UPDATE public.sub_finder_order SET td_state = 'searched'$o$,
     $n$UPDATE public.sub_finder_order SET td_state = 'searched', rematch = rematch OR state = 'cover'$n$],
    [$o$WHERE job_id = p_job_id AND state = 'pending' AND td_state IN ('searched', 'failed')) THEN$o$,
     $n$WHERE job_id = p_job_id AND ((state = 'pending' AND td_state IN ('searched', 'failed'))
                                         OR (rematch AND state = 'cover' AND td_state = 'searched'))) THEN$n$],
    -- no credentials: an order that had a cover keeps it
    [$o$UPDATE public.sub_finder_order SET td_state = 'failed', state = 'no_cover', updated_at = now()$o$,
     $n$UPDATE public.sub_finder_order SET td_state = 'failed', state = CASE WHEN state = 'pending' THEN 'no_cover' ELSE state END, updated_at = now()$n$]
  ];
  i integer;
BEGIN
  IF position('sub_finder_td_wanted' IN v_def) > 0 THEN
    RETURN;                                             -- already patched
  END IF;
  FOR i IN 1 .. array_length(v_pairs, 1) LOOP
    IF (length(v_def) - length(replace(v_def, v_pairs[i][1], ''))) / length(v_pairs[i][1]) <> 1 THEN
      RAISE EXCEPTION 'sub_finder_settle: anchor % was not found exactly once', i;
    END IF;
    v_def := replace(v_def, v_pairs[i][1], v_pairs[i][2]);
  END LOOP;
  EXECUTE v_def;
END
$patch$;

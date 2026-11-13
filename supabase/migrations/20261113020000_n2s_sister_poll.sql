-- Migration 20261113020000 · level:secondary-sales · lane:D7 · writes:n2s_sister_poll_state,settings,n2s_ts_or_null,n2s_sister_pull,n2s_pipeline_tick · reads:sub_finder_order,sub_finder_config,events,collector_cadence,n2s_mkt_pull · pre:20261112030000
--
-- N2S's poller also polls the SISTER flow's events, from the moment an order enters that bucket.
--
-- Operator 2026-11-13: the sub finder API and the manual sub buy serve orders that were already
-- ACCEPTED but whose tickets have a problem, "a sister to n2s but not the same thing"; then
-- "expand [the] poller to include these events once they come into this bucket".
--
-- WHY. The sub finder matches against the n2s_*_current lists, which only N2S's own pulls fill,
-- and N2S pulls only events with an open N2S order. The terminal's fleet listing polls are
-- paused (20260927043400) and the pinned poller (20261023051000) lands in the terminal tables,
-- which the sub finder does not read. So an accepted order whose event N2S was not working kept
-- the covers of its first lookup (sub_finder_config.refresh_pull is off).
--
-- WHAT. Every minute, inside n2s_pipeline_tick, right after N2S's own pulls:
--   * the bucket = events of sub-finder orders still being watched (sub_finder_order.watching).
--     A watch ends by the sub finder's own rules, unchanged: the event passed, the order was
--     fulfilled / cancelled / rejected, or the same order was looked up again.
--   * each event is pulled through the SAME path N2S uses (n2s_pull_events: EVO, GoTickets,
--     SeatGeek; GETs only) on the collector_cadence band for how far out it is, the bands the
--     terminal's pollers use. EVO listings: within 3 days every 5 min, 7 days 15 min, 14 days
--     30 min (60 off-peak), 30 days 1 h, 60 days 4 h, 180 days 12 h, beyond that daily.
--     GoTickets and SeatGeek ride on the EVO band (GoTickets' own far-out bands are 6/24/48 h).
--   * n2s_sister_poll_state keeps each event's clock. N2S keeps its own request log and current
--     lists for 1 hour only (20260927042100), so they cannot pace a 4–24 h band. An event N2S
--     itself pulled within its band is not pulled again. When nothing could be fired (no market
--     mapping, or another poller hit the event within 60 s) it is tried again after the band or
--     5 minutes, whichever is shorter.
--   * at most settings 'n2s_sister_poll_max' events per tick (20), soonest event first. '0'
--     turns this off; it is also off while the sub finder or its refresh is off.
-- The sub finder's refresh already re-matches a watched order when its event lands newer
-- listings, so nothing in the sub finder changes and its refresh_pull stays off.
--
-- RULE 2: no new upstream call or write path; n2s_pull_events is the existing GET-only puller.
-- n2s_pull_events also calls n2s_td_enqueue for open N2S events. TicketsData is retired
-- (integration_policy 'ticketsdata_retired'), so that does nothing; if it is ever re-enabled,
-- that enqueue is bounded by its own once-per-30-minutes rule per event and platform.
--
-- The tick is md5-guarded against its prod text (checked 2026-11-13; the anchor occurs once).
--
-- rollback: UPDATE public.settings SET value = '0' WHERE key = 'n2s_sister_poll_max';  (off)
--           full: re-create n2s_pipeline_tick without the 'sister_pull' stage (its text before
--           this migration has md5 5caa7845e1686a06e3e4012cbf4b9a51), then
--           DROP FUNCTION public.n2s_sister_pull(); DROP FUNCTION public.n2s_ts_or_null(text);
--           DROP TABLE public.n2s_sister_poll_state; DELETE FROM public.settings WHERE key = 'n2s_sister_poll_max';

-- ── the per-event clock ────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.n2s_sister_poll_state (
  tevo_event_id  bigint      PRIMARY KEY,
  band           text,
  required_min   integer,
  last_tried_at  timestamptz,
  last_pulled_at timestamptz,
  pulls          integer     NOT NULL DEFAULT 0
);
ALTER TABLE public.n2s_sister_poll_state ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.n2s_sister_poll_state FROM PUBLIC, anon, authenticated;
COMMENT ON TABLE public.n2s_sister_poll_state IS
  'When N2S last pulled each sister-flow event (sub finder orders still being watched) and on which collector_cadence band. Rows for events that left the bucket are dropped after a day. 20261113020000.';

-- ── the switch ─────────────────────────────────────────────────────────────
INSERT INTO public.settings (key, value, updated_at)
VALUES ('n2s_sister_poll_max', '20', now())
ON CONFLICT (key) DO NOTHING;

-- ── a start time that never throws ─────────────────────────────────────────
-- events.occurs_at_local is text, with an offset or without one (then read as UTC, which is
-- never later than the real start for US venues: the band is at worst a step tighter).
CREATE OR REPLACE FUNCTION public.n2s_ts_or_null(p text)
 RETURNS timestamptz
 LANGUAGE plpgsql
 IMMUTABLE
 SET search_path TO 'public', 'pg_temp'
 SET "TimeZone" TO 'UTC'
AS $function$
BEGIN
  RETURN NULLIF(btrim(p), '')::timestamptz;
EXCEPTION WHEN OTHERS THEN
  RETURN NULL;
END
$function$;
REVOKE ALL ON FUNCTION public.n2s_ts_or_null(text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.n2s_ts_or_null(text) TO service_role;

-- ── the pull ───────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.n2s_sister_pull()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  c       public.sub_finder_config%ROWTYPE;
  v_max   integer;
  g       record;
  p       record;
  v_due   bigint[] := '{}';
  v_evo   integer := 0;
  v_gt    integer := 0;
  v_sg    integer := 0;
BEGIN
  v_max := COALESCE((SELECT NULLIF(regexp_replace(s.value, '\D', '', 'g'), '')::integer
                       FROM public.settings s WHERE s.key = 'n2s_sister_poll_max'), 20);
  IF v_max <= 0 THEN
    RETURN jsonb_build_object('skipped', 'off');
  END IF;
  SELECT * INTO c FROM public.sub_finder_config LIMIT 1;
  IF NOT FOUND OR NOT c.enabled OR NOT c.refresh_enabled THEN
    RETURN jsonb_build_object('skipped', 'sub_finder_off');
  END IF;

  -- forget events that left the bucket a day ago
  DELETE FROM public.n2s_sister_poll_state s
   WHERE s.last_tried_at < now() - interval '1 day'
     AND NOT EXISTS (SELECT 1 FROM public.sub_finder_order o
                      WHERE o.watching AND o.tevo_event_id = s.tevo_event_id);

  FOR g IN
    WITH bucket AS (               -- events of sister-flow orders still being watched
      SELECT o.tevo_event_id AS eid, min(o.event_date) AS event_date
        FROM public.sub_finder_order o
       WHERE o.watching AND o.tevo_event_id IS NOT NULL
       GROUP BY o.tevo_event_id),
    timed AS (
      SELECT b.eid,
             COALESCE((SELECT public.n2s_ts_or_null(e.occurs_at_local) FROM public.events e WHERE e.id = b.eid),
                      b.event_date::timestamp AT TIME ZONE 'UTC') AS starts_at
        FROM bucket b),
    banded AS (
      SELECT t.eid, t.starts_at, cb.band, cb.required_min, ps.last_tried_at,
             GREATEST(ps.last_pulled_at,
                      (SELECT max(q.fired_at) FROM public.n2s_mkt_pull q
                        WHERE q.source = 'evo' AND q.mkt_event_id = t.eid)) AS last_pull
        FROM timed t
        CROSS JOIN LATERAL public.collector_band(
                 'EVO', 'listings',
                 GREATEST(extract(epoch FROM t.starts_at - now()) / 3600.0, 0)::numeric) cb
        LEFT JOIN public.n2s_sister_poll_state ps ON ps.tevo_event_id = t.eid
       WHERE t.starts_at IS NOT NULL),
    due AS (
      SELECT d.* FROM banded d
       WHERE (d.last_pull IS NULL OR d.last_pull < now() - make_interval(mins => d.required_min))
         AND (d.last_tried_at IS NULL
              OR d.last_tried_at < now() - make_interval(mins => LEAST(d.required_min, 5)))
       ORDER BY d.starts_at
       LIMIT v_max)
    SELECT due.band, due.required_min, array_agg(due.eid) AS evs
      FROM due GROUP BY due.band, due.required_min
  LOOP
    SELECT * INTO p FROM public.n2s_pull_events(g.evs, interval '1 minute');
    v_evo := v_evo + COALESCE(p.evo_fired, 0);
    v_gt  := v_gt  + COALESCE(p.gt_fired, 0);
    v_sg  := v_sg  + COALESCE(p.sg_queued, 0);
    v_due := v_due || g.evs;
    INSERT INTO public.n2s_sister_poll_state AS s (tevo_event_id, band, required_min, last_tried_at)
    SELECT x, g.band, g.required_min, now() FROM unnest(g.evs) AS x
    ON CONFLICT (tevo_event_id) DO UPDATE
      SET band = EXCLUDED.band, required_min = EXCLUDED.required_min, last_tried_at = now();
  END LOOP;

  -- the clock moves only for events a pull actually went out for (fired_at defaults to now())
  IF cardinality(v_due) > 0 THEN
    UPDATE public.n2s_sister_poll_state s
       SET last_pulled_at = now(), pulls = s.pulls + 1
     WHERE s.tevo_event_id = ANY (v_due)
       AND EXISTS (SELECT 1 FROM public.n2s_mkt_pull q
                    WHERE q.tevo_event_id = s.tevo_event_id AND q.fired_at >= now());
  END IF;

  RETURN jsonb_build_object('events', cardinality(v_due), 'evo_fired', v_evo,
                            'gt_fired', v_gt, 'sg_queued', v_sg);
END
$function$;

COMMENT ON FUNCTION public.n2s_sister_pull() IS
  'Pulls the sister flow''s watched events (sub finder orders) into the n2s_*_current lists through n2s_pull_events, on the collector_cadence EVO band for how far out each event is. Called by n2s_pipeline_tick. Off with settings n2s_sister_poll_max = 0. 20261113020000.';

REVOKE ALL ON FUNCTION public.n2s_sister_pull() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.n2s_sister_pull() TO service_role;

-- ── the tick calls it, right after N2S's own pulls ─────────────────────────
DO $do$
DECLARE d text;
BEGIN
  d := pg_get_functiondef('public.n2s_pipeline_tick(integer)'::regprocedure);
  IF md5(d) <> '5caa7845e1686a06e3e4012cbf4b9a51' THEN
    RAISE EXCEPTION 'n2s_pipeline_tick drifted from the text this migration was checked on — re-derive it';
  END IF;
  d := replace(d, $r$  v_stage := 'cover_queue_refresh';$r$,
$r$  -- 20261113020000: the sister flow's watched events (sub finder: accepted orders with
  -- ticket problems), pulled into the same n2s_*_current lists on the collector_cadence bands
  v_stage := 'sister_pull';
  IF clock_timestamp() - v_start < make_interval(secs => p_budget_seconds) THEN
    BEGIN
      v_out := v_out || jsonb_build_object('sister', public.n2s_sister_pull());
    EXCEPTION WHEN OTHERS THEN
      v_errors := v_errors || jsonb_build_object('stage', v_stage, 'err', SQLERRM);
    END;
  END IF;

  v_stage := 'cover_queue_refresh';$r$);
  IF position($r$v_stage := 'sister_pull';$r$ in d) = 0 THEN
    RAISE EXCEPTION 'n2s_pipeline_tick anchor not found — re-derive this migration';
  END IF;
  EXECUTE d;
END $do$;

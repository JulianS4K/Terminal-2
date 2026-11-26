-- Migration 20261126023000 · level:data-collection · lane:a1 (AXS watch cadence) · writes:axs_watch_settle_one()(replaced) · reads:primary_poll_config
--
-- ============================================================================
-- Migration 20261126023000 — the phase instant must clear due_slack, or every
--   event is re-read in a tight loop
--
-- Lane:     a1 (AXS watch cadence)
-- Touches:  axs_watch_settle_one() (REPLACED; only the next_poll_at arithmetic changes).
-- pre:      20261125214500 (which introduced the phase, and this defect).
--
-- READ-ONLY UPSTREAM (RULE 2): nothing here calls a market. It changes when the
-- existing reader is next told to read.
--
-- ── THE DEFECT, WHICH I INTRODUCED IN 20261125214500 ──────────────────────
-- That migration gave each event a stable phase and set next_poll_at to the first
-- phase-congruent instant AFTER now(). primary_poll_due, however, calls an event due
-- when next_poll_at <= now() + due_slack, and due_slack is 60 seconds. So:
--
--   1. next_poll_at = P, the event's phase instant.
--   2. The read is handed out up to 60 s EARLY, at about P - 60.
--   3. It settles while now() is still short of P, so the "first instant after now()"
--      is P AGAIN — only tens of seconds away, still inside the slack window.
--   4. Due again at once. Repeat until now() passes P, then it parks for a full interval.
--
-- The loop therefore runs about due_slack / read_duration times per event per cycle,
-- which means A FASTER UPSTREAM MAKES IT WORSE. Measured on prod: 39.6% of reads were
-- duplicates over three hours while TicketsData was answering in ~20 s, rising to 76.1%
-- in the hour after it recovered to ~5 s. 414 reads/h for 88 events on 30/60/90-minute
-- bands, against the ~90/h the bands ask for — 4.6x.
--
-- Caught in the act at 02:20Z: events 1541392 and 1570687, read 13 and 19 seconds
-- earlier, both had next_poll_at already 2 and 11 seconds in the PAST. Both were
-- phase-aligned (next_poll_at mod band = the event's phase), which is the loop exiting
-- on the read that finally crossed P.
--
-- Left alone it would also have closed the TicketsData daily gate: 414 reads/h projects
-- to 9,936/day, and the gate is credits * 1.276 < daily_cap, i.e. 12,678 > 10,706 — so
-- the catalogue feed would have starved again, as it did at 17:10Z on 11-25, this time
-- because of duplicate reads rather than the old flat 7,500 limit.
--
-- ── THE FIX ───────────────────────────────────────────────────────────────
-- Anchor the search at now() + due_slack instead of now(), so the chosen instant is
-- strictly outside the window in which primary_poll_due would call it due again:
--
--   v_base := extract(epoch FROM now()) + due_slack
--   v_next := floor((v_base - v_phase) / v_sec) * v_sec + v_phase
--   IF v_next <= v_base THEN v_next := v_next + v_sec
--
-- next_poll_at > now() + due_slack always holds afterwards, so an event cannot be
-- instantly re-due. The even spacing the phase exists for is untouched: reads still land
-- within due_slack of each event's own phase instant, they simply stop looping onto it.
-- The guard reads due_slack from primary_poll_config rather than hardcoding 60 s, so
-- changing that setting cannot reopen the loop.
--
-- ⚠ NOT FIXED HERE, still open: primary_poll_due's last clause,
--     OR (live.every < t.poll_interval AND t.poll_attempt_at + live.every <= now() + due_slack)
-- bypasses next_poll_at wherever the shared box-office ladder is faster than the AXS
-- band. 67 of 88 events are in that state (ladder 30 min against band 60 min), so the
-- operator's three bands are not fully in force. That is a separate, pre-existing defect
-- and cannot cause this loop (it cannot fire inside 15 seconds); it needs its own call.
-- ============================================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.axs_watch_settle_one(
         p_event_id text, p_status_code integer, p_content jsonb,
         p_timed_out boolean DEFAULT false, p_error_msg text DEFAULT NULL,
         p_charge boolean DEFAULT true, p_via text DEFAULT 'TicketsData')
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_cfg public.axs_watch_config%ROWTYPE;
  t record; body jsonb; parsed jsonb; v_ok boolean; v_outcome text; v_error text; v_tevo bigint;
  v_via text := coalesce(nullif(p_via, ''), 'TicketsData');
  v_every interval; v_sec bigint; v_phase bigint; v_next numeric; v_slack numeric; v_base numeric;
BEGIN
  SELECT * INTO v_cfg FROM public.axs_watch_config;
  body := p_content->'body';
  parsed := NULL; v_error := NULL;
  IF coalesce(p_timed_out, false) OR p_error_msg IS NOT NULL THEN
    v_ok := false; v_outcome := 'timeout'; v_error := left(coalesce(p_error_msg, 'timed out'), 200);
  ELSIF p_status_code IN (400, 404, 410, 422) THEN
    v_ok := false; v_outcome := 'not_axs'; v_error := 'HTTP ' || p_status_code || ': AXS does not sell this event through ' || v_via;
  ELSIF p_status_code IS DISTINCT FROM 200 THEN
    v_ok := false; v_outcome := 'upstream_error'; v_error := 'HTTP ' || coalesce(p_status_code::text, '?') || ' from ' || v_via;
  ELSIF body->>'status' = 'expired' THEN
    v_ok := false; v_outcome := 'expired'; v_error := 'expired: the event is over on AXS';
  ELSIF jsonb_typeof(body->'event') = 'object' AND coalesce(body->>'status', '') IN ('ok', 'success') AND coalesce(body->>'exit_code', '0') = '0' THEN
    parsed := public.axs_watch_parse(body);
    v_ok := true; v_outcome := CASE WHEN jsonb_array_length(parsed->'listings') = 0 THEN 'empty' ELSE 'ok' END;
  ELSE
    v_ok := false; v_outcome := 'unparsed';
    v_error := left(coalesce(body->>'error', body->>'message', p_content->>'error', v_via || ' answered without an event'), 200);
  END IF;

  v_tevo := NULL;
  SELECT * INTO t FROM public.primary_poll_event e WHERE e.source = 'axs' AND e.source_event_id = p_event_id;
  IF FOUND THEN
    v_tevo := t.tevo_event_id;
    PERFORM public.primary_poll_ingest('axs', jsonb_build_array(jsonb_strip_nulls(jsonb_build_object(
              'id', t.source_event_id, 'name', t.name, 'local_date', t.event_date::text,
              'local_time', to_char(t.start_local_time, 'HH24:MI'), 'start_utc', t.start_utc, 'timezone', t.timezone,
              'venue', t.venue_name, 'city', t.venue_city, 'state', t.venue_state, 'url', t.ticket_url,
              'offer_id', coalesce(parsed->>'offer_id', t.offer_id),
              'order_min', parsed->>'order_min', 'order_max', parsed->>'order_max',
              'total_available', parsed->>'total_available', 'price_min', parsed->>'price_min', 'price_max', parsed->>'price_max',
              'ok', v_ok, 'error', v_error)) || jsonb_build_object('listings', coalesce(parsed->'listings', '[]'::jsonb))));

    -- The cadence: the event's proximity band, scaled, SET rather than floored — the ingest
    -- above has just written the shared ladder's interval, and this replaces it. next_poll_at
    -- is recomputed on this event's own stable phase, so due times spread across the whole
    -- interval instead of landing on six marks an hour.
    -- THE BASE IS now() + due_slack, NOT now() (mig 20261126023000): primary_poll_due calls an
    -- event due at next_poll_at <= now() + due_slack, so anchoring at now() could land the next
    -- instant inside that window and the event would be handed out again immediately, over and
    -- over, until the clock crossed it. That loop cost 76% of all reads.
    v_every := coalesce(public.axs_watch_cadence_every(t.start_utc, t.event_date), interval '1 hour');
    v_sec   := greatest(extract(epoch FROM v_every)::bigint, 1);
    v_phase := (hashtext(p_event_id)::bigint & 2147483647) % v_sec;
    v_slack := coalesce((SELECT extract(epoch FROM c.due_slack) FROM public.primary_poll_config c), 0);
    v_base  := extract(epoch FROM now()) + greatest(v_slack, 0);
    v_next  := floor((v_base - v_phase) / v_sec) * v_sec + v_phase;
    IF v_next <= v_base THEN v_next := v_next + v_sec; END IF;
    UPDATE public.primary_poll_event e
       SET poll_interval = v_every,
           next_poll_at  = to_timestamp(v_next)
     WHERE e.source = 'axs' AND e.source_event_id = p_event_id;

    -- An event that says it is not on sale keeps its own, slower rule, and so wins over
    -- the band above: this branch runs after it, as it did before the consolidation.
    IF v_outcome = 'unparsed' AND v_error ~* 'not (currently |yet )?on sale|not on sale yet|no tickets are currently available|coming soon' THEN
      UPDATE public.primary_poll_event e
         SET poll_interval = v_cfg.not_on_sale_every, next_poll_at = now() + v_cfg.not_on_sale_every * (0.75 + random() * 0.5)
       WHERE e.source = 'axs' AND e.source_event_id = p_event_id;
    END IF;
  END IF;
  IF p_status_code = 200 AND coalesce(p_charge, true) THEN
    PERFORM public.td_charge_credit(1, v_tevo, 'AXS', '/fetch', p_status_code, nullif(p_content->>'quota_remaining', '')::integer);
  END IF;
  RETURN jsonb_build_object(
           'outcome', v_outcome, 'error', v_error,
           'response_s', nullif(coalesce(body->>'elapsed_seconds', p_content->>'response_s'), '')::numeric,
           'listings', CASE WHEN parsed IS NOT NULL THEN jsonb_array_length(parsed->'listings') END,
           'quota_remaining', nullif(p_content->>'quota_remaining', '')::bigint);
END $function$;

COMMIT;

-- Migration 20260927030200 · level:secondary-sales · lane:D7 · writes:n2s_mkt_pull,n2s_mkt_drain,n2s_pull_events,n2s_pipeline_tick · reads:gotickets_event,sg_events_canonical,aq_event_map · pre:20260927030000
--
-- Already applied to prod · via MCP 2026-09-27 03:02 UTC under operator direction
-- ("Keep them both independent, have the crm system poll the 3 marketplaces
-- independently of the terminal data" + "reset the other event queues timer so
-- it doesnt trigger a rate limit"), after a rolled-back dry run (2 real GT
-- responses → 287/267 rows; 3 EVO / 2 GT / 2 SG fired for 3 live events).
--
-- N2S fires AND lands its own GoTickets/SeatGeek requests instead of going
-- through the terminal queues (gt_listings_inflight / sg_broker_pending, drained
-- by crons 629/639). Each fire resets the terminal's per-event poll timer.
-- In-window orders are re-polled every 2 minutes (was once: the sweep waited 20).
-- Superseded in part by 20260927041700 (own storage, EVO direct).
-- ============================================================================

-- N2S's own marketplace queue: GoTickets + SeatGeek requests fired AND landed by
-- the N2S tick, never through the terminal queues (gt_listings_inflight /
-- sg_broker_pending, drained by crons 629 / 639). Each fire still resets the
-- terminal's per-event poll timer (gt_listings_poll_state /
-- sg_event_priority_state), so the terminal does not re-poll the same event
-- straight after and trip a rate limit.

CREATE TABLE IF NOT EXISTS public.n2s_mkt_pull (
  request_id     bigint PRIMARY KEY,
  source         text NOT NULL CHECK (source IN ('gotickets', 'seatgeek')),
  tevo_event_id  bigint NOT NULL,
  mkt_event_id   bigint NOT NULL,
  fired_at       timestamptz NOT NULL DEFAULT now(),
  resolved_at    timestamptz,
  status_code    integer,
  rows_persisted integer
);
CREATE INDEX IF NOT EXISTS n2s_mkt_pull_open_idx ON public.n2s_mkt_pull (fired_at) WHERE resolved_at IS NULL;
CREATE INDEX IF NOT EXISTS n2s_mkt_pull_event_idx ON public.n2s_mkt_pull (source, mkt_event_id, fired_at DESC);
ALTER TABLE public.n2s_mkt_pull ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.n2s_mkt_pull FROM PUBLIC, anon, authenticated;
COMMENT ON TABLE public.n2s_mkt_pull IS
  'N2S-owned GoTickets/SeatGeek listing requests: fired by n2s_pull_events, landed by n2s_mkt_drain in the N2S tick. Independent of the terminal queues.';

CREATE OR REPLACE FUNCTION public.n2s_mkt_drain()
 RETURNS TABLE(gt_landed integer, sg_landed integer, rows_persisted integer, expired integer)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE r RECORD; v_gt int := 0; v_sg int := 0; v_rows int := 0; v_n int; v_ct int; v_exp int := 0;
BEGIN
  FOR r IN
    SELECT p.request_id, p.source, p.tevo_event_id, p.mkt_event_id, p.fired_at,
           h.status_code, h.content
      FROM public.n2s_mkt_pull p
      JOIN net._http_response h ON h.id = p.request_id
     WHERE p.resolved_at IS NULL
     ORDER BY p.fired_at
     FOR UPDATE OF p SKIP LOCKED
  LOOP
    v_n := 0; v_ct := NULL;
    BEGIN
      IF r.source = 'gotickets' THEN
        v_gt := v_gt + 1;
        IF r.status_code = 200 AND r.content IS NOT NULL THEN
          v_ct := jsonb_array_length(COALESCE((r.content::jsonb) -> 'listings', '[]'::jsonb));
          IF v_ct > 0 THEN
            INSERT INTO public.gotickets_listings_snapshots
              (tevo_event_id, gt_event_id, captured_at, gt_listing_id, section, section_id, row,
               quantity, display_price, all_in_price, service_fee, face_value, stock_type,
               in_hand_date, general_admission, splits, notes)
            SELECT r.tevo_event_id, r.mkt_event_id, r.fired_at, l."id", l.section, l."sectionId", l.row,
                   l.quantity, l."displayPrice", l."allInPrice", l."serviceFee", l."faceValue", l."stockType",
                   NULLIF(l."inHandDate", '')::date, l."generalAdmission",
                   ARRAY(SELECT jsonb_array_elements_text(COALESCE(l."validSplitQuantities", '[]'::jsonb))::int),
                   l.notes
              FROM jsonb_to_recordset((r.content::jsonb) -> 'listings') AS l(
                "id" bigint, section text, "sectionId" bigint, row text, quantity int,
                "displayPrice" numeric, "allInPrice" numeric, "serviceFee" numeric, "faceValue" numeric,
                "stockType" text, "inHandDate" text, "generalAdmission" boolean,
                "validSplitQuantities" jsonb, notes text)
            ON CONFLICT (gt_event_id, captured_at, gt_listing_id) DO NOTHING;
            GET DIAGNOSTICS v_n = ROW_COUNT;
          END IF;
        END IF;
        -- same per-event bookkeeping the terminal drain does, so its cold /
        -- quarantine logic sees our results too
        UPDATE public.gt_listings_poll_state ps SET
          last_status = r.status_code,
          consecutive_empty = CASE
            WHEN r.status_code = 200 AND COALESCE(v_ct,0) > 0 THEN 0
            WHEN r.status_code = 200 THEN ps.consecutive_empty + 1
            ELSE ps.consecutive_empty END,
          cold_until = CASE
            WHEN r.status_code = 200 AND COALESCE(v_ct,0) > 0 THEN NULL
            WHEN r.status_code = 200 AND ps.consecutive_empty + 1 >= 2 THEN now() + interval '6 hours'
            ELSE ps.cold_until END,
          quarantined_until = CASE
            WHEN r.status_code = 402 THEN now() + interval '7 days'
            WHEN r.status_code = 404 THEN now() + interval '30 days'
            WHEN r.status_code = 200 THEN NULL
            ELSE ps.quarantined_until END
         WHERE ps.gt_event_id = r.mkt_event_id;
      ELSE
        v_sg := v_sg + 1;
        IF r.status_code = 200 AND jsonb_typeof((r.content::jsonb) -> 'listings') = 'array' THEN
          INSERT INTO public.seatgeek_listings_snapshots (
            tevo_event_id, sg_event_id, captured_at,
            sglid, display_id, retail_price_all_in, broadcast_price,
            deal_quality_score, quantity, splits, section, row,
            is_broker_owned, is_b2b, is_instant_download, is_sro,
            has_limited_view, is_wheelchair_acc, ada_details,
            delivery_method, in_hand_date, market_source, stock_type,
            seller_notes, endpoint, content_hash, raw, aq_short_event_id)
          SELECT r.tevo_event_id, r.mkt_event_id, now(),
            NULLIF(l->>'sglid','')::bigint, l->>'id',
            NULLIF(l->>'pf','')::numeric, NULLIF(l->>'bp','')::numeric,
            NULLIF(l->>'ds','')::numeric, NULLIF(l->>'q','')::int,
            l->'sp', l->>'s', l->>'r',
            NULLIF(l->>'bo','')::boolean, NULLIF(l->>'is_b2b','')::boolean,
            NULLIF(l->>'idl','')::boolean, NULLIF(l->>'sro','')::boolean,
            NULLIF(l->>'lv','')::boolean, NULLIF(l->>'wa','')::boolean,
            l->>'ada', l->>'dm', NULLIF(l->>'ihd','')::date,
            l->>'m', l->>'st', l->>'pn',
            '/listings',
            md5(r.mkt_event_id::text || ':' || (l->>'id') || ':' || (l->>'bp') || ':' || (l->>'q')),
            l,
            (SELECT a.aq_short_event_id FROM public.aq_event_map a
              WHERE a.sg_event_id = r.mkt_event_id ORDER BY a.aq_short_event_id LIMIT 1)
            FROM jsonb_array_elements((r.content::jsonb) -> 'listings') AS l
           WHERE l->>'id' IS NOT NULL
          ON CONFLICT DO NOTHING;
          GET DIAGNOSTICS v_n = ROW_COUNT;
        END IF;
      END IF;
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'n2s_mkt_drain: % request % (event %) failed: %',
        r.source, r.request_id, r.mkt_event_id, SQLERRM;
      v_n := -1;
    END;

    UPDATE public.n2s_mkt_pull
       SET resolved_at = now(), status_code = r.status_code, rows_persisted = v_n
     WHERE request_id = r.request_id;
    v_rows := v_rows + GREATEST(v_n, 0);
  END LOOP;

  -- a request with no response after 5 minutes will not get one
  UPDATE public.n2s_mkt_pull SET resolved_at = now(), rows_persisted = -1
   WHERE resolved_at IS NULL AND fired_at < now() - interval '5 minutes';
  GET DIAGNOSTICS v_exp = ROW_COUNT;

  DELETE FROM public.n2s_mkt_pull WHERE fired_at < now() - interval '3 days';

  RETURN QUERY SELECT v_gt, v_sg, v_rows, v_exp;
END $function$;
REVOKE ALL ON FUNCTION public.n2s_mkt_drain() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.n2s_mkt_drain() TO service_role;

DO $$ BEGIN
  IF md5(pg_get_functiondef('public.n2s_pull_events'::regproc)) <> '0157d7896e415808ec678285c0946af5' THEN
    RAISE EXCEPTION 'n2s_pull_events drifted from the reviewed body — refusing';
  END IF;
END $$;

CREATE OR REPLACE FUNCTION public.n2s_pull_events(p_events bigint[], p_refresh_after interval DEFAULT '00:05:00'::interval)
 RETURNS TABLE(evo_fired integer, gt_fired integer, sg_queued integer, td_queued integer, evo_skipped_fresh integer, gt_skipped_fresh integer, evo_skipped_unknown integer)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE
  r RECORD; v_token text; v_req bigint; v_eid bigint;
  v_evo int := 0; v_gt int := 0; v_sg int := 0; v_td int := 0;
  v_evo_skip int := 0; v_gt_skip int := 0; v_evo_unknown int := 0;
BEGIN
  IF p_events IS NULL OR cardinality(p_events) = 0 THEN
    RETURN QUERY SELECT 0, 0, 0, 0, 0, 0, 0; RETURN;
  END IF;

  -- ── EVO (unchanged): collect-listings edge function per event ──
  SELECT count(*) INTO v_evo_unknown
    FROM unnest(p_events) AS e
   WHERE NOT EXISTS (SELECT 1 FROM public.events ev WHERE ev.id = e);

  SELECT count(*) INTO v_evo_skip
    FROM unnest(p_events) AS e
   WHERE EXISTS (SELECT 1 FROM public.events ev WHERE ev.id = e)
     AND (EXISTS (SELECT 1 FROM public.listings_snapshots s
                   WHERE s.event_id = e AND s.captured_at >= now() - p_refresh_after)
          OR EXISTS (SELECT 1 FROM public.evo_listings_poll_state ps
                      WHERE ps.event_id = e
                        AND ps.last_polled_listings_at >= now() - p_refresh_after));

  FOR v_eid IN
    SELECT e FROM unnest(p_events) AS e
     WHERE EXISTS (SELECT 1 FROM public.events ev WHERE ev.id = e)
       AND NOT EXISTS (SELECT 1 FROM public.listings_snapshots s
                        WHERE s.event_id = e AND s.captured_at >= now() - p_refresh_after)
       AND NOT EXISTS (SELECT 1 FROM public.evo_listings_poll_state ps
                        WHERE ps.event_id = e
                          AND ps.last_polled_listings_at >= now() - p_refresh_after)
  LOOP
    PERFORM public._cron_invoke_edge_fn(
      'https://hzrizjeaxlqcxfrtczpq.supabase.co/functions/v1/collect-listings?event_id='
        || v_eid::text, '{}'::jsonb);
    INSERT INTO public.evo_listings_poll_state(
             event_id, last_polled_listings_at, listings_polls_today, budget_day)
    VALUES (v_eid, now(), 1, current_date)
    ON CONFLICT (event_id) DO UPDATE SET
      last_polled_listings_at = now(),
      listings_polls_today = CASE WHEN evo_listings_poll_state.budget_day < current_date
                                  THEN 1 ELSE evo_listings_poll_state.listings_polls_today + 1 END,
      budget_day = current_date;
    v_evo := v_evo + 1;
  END LOOP;

  -- ── GoTickets: fired into OUR queue (n2s_mkt_pull), landed by n2s_mkt_drain.
  -- Skips an event polled by anyone within p_refresh_after (the shared timer),
  -- and resets that timer when we fire so the terminal does not re-poll it.
  v_token := public._gotickets_pro_token();
  IF v_token IS NOT NULL AND btrim(v_token) <> '' THEN
    SELECT count(*) INTO v_gt_skip
      FROM public.gotickets_event g
      LEFT JOIN public.gt_listings_poll_state ps ON ps.gt_event_id = g.gt_event_id
     WHERE g.tevo_event_id = ANY(p_events)
       AND (ps.quarantined_until IS NULL OR ps.quarantined_until < now())
       AND ps.last_polled_listings_at >= now() - p_refresh_after;

    FOR r IN
      SELECT g.gt_event_id, g.tevo_event_id
        FROM public.gotickets_event g
        LEFT JOIN public.gt_listings_poll_state ps ON ps.gt_event_id = g.gt_event_id
       WHERE g.tevo_event_id = ANY(p_events)
         AND (ps.quarantined_until IS NULL OR ps.quarantined_until < now())
         AND (ps.last_polled_listings_at IS NULL
              OR ps.last_polled_listings_at < now() - p_refresh_after)
         AND NOT EXISTS (SELECT 1 FROM public.n2s_mkt_pull q
                          WHERE q.source = 'gotickets' AND q.mkt_event_id = g.gt_event_id
                            AND q.resolved_at IS NULL)
    LOOP
      SELECT net.http_get(
        url := 'https://gotickets.com/rest/pro/api/events/' || r.gt_event_id::text || '/listings',
        headers := jsonb_build_object('X-Broker-Api-Token', v_token, 'Accept', 'application/json'),
        timeout_milliseconds := 30000) INTO v_req;
      INSERT INTO public.n2s_mkt_pull(request_id, source, tevo_event_id, mkt_event_id)
      VALUES (v_req, 'gotickets', r.tevo_event_id, r.gt_event_id);
      INSERT INTO public.gt_listings_poll_state(
               gt_event_id, last_polled_listings_at, listings_polls_today, budget_day)
      VALUES (r.gt_event_id, now(), 1, current_date)
      ON CONFLICT (gt_event_id) DO UPDATE SET
        last_polled_listings_at = now(),
        listings_polls_today = CASE WHEN gt_listings_poll_state.budget_day < current_date
                                    THEN 1 ELSE gt_listings_poll_state.listings_polls_today + 1 END,
        budget_day = current_date;
      v_gt := v_gt + 1;
    END LOOP;
  END IF;

  -- ── SeatGeek: register hub-resolved events (the snapshot FK needs a
  -- canonical row) without firing anything, then fire into OUR queue and reset
  -- the shared per-event timer.
  BEGIN
    PERFORM * FROM public.sg_listings_pull_on_demand(p_events, 0, p_refresh_after);
    v_token := public.get_app_secret('SEATGEEK_API_TOKEN');
    IF v_token IS NOT NULL AND v_token <> '' THEN
      FOR r IN
        WITH want AS (SELECT DISTINCT x AS tevo_event_id FROM unnest(p_events) AS x),
        resolved AS (
          SELECT w.tevo_event_id,
                 COALESCE(
                   (SELECT c.sg_event_id FROM public.sg_events_canonical c
                     WHERE c.tevo_event_id = w.tevo_event_id ORDER BY c.sg_event_id LIMIT 1),
                   (SELECT a.sg_event_id FROM public.aq_event_map a
                     WHERE a.tevo_event_id = w.tevo_event_id AND a.sg_event_id IS NOT NULL
                     ORDER BY a.sg_event_id LIMIT 1)) AS sg_event_id
            FROM want w)
        SELECT rs.tevo_event_id, rs.sg_event_id
          FROM resolved rs
         WHERE rs.sg_event_id IS NOT NULL
           AND EXISTS (SELECT 1 FROM public.sg_events_canonical c WHERE c.sg_event_id = rs.sg_event_id)
           AND NOT EXISTS (SELECT 1 FROM public.sg_event_priority_state ps
                            WHERE ps.sg_event_id = rs.sg_event_id
                              AND ps.last_polled_listings_at >= now() - p_refresh_after)
           AND NOT EXISTS (SELECT 1 FROM public.sg_broker_pending b
                            WHERE b.scope = 'listings' AND b.sg_event_id = rs.sg_event_id
                              AND b.fired_at >= now() - p_refresh_after)
           AND NOT EXISTS (SELECT 1 FROM public.n2s_mkt_pull q
                            WHERE q.source = 'seatgeek' AND q.mkt_event_id = rs.sg_event_id
                              AND (q.resolved_at IS NULL OR q.fired_at >= now() - p_refresh_after))
      LOOP
        SELECT net.http_get(
          url := 'https://brokerdata.seatgeek.com/listings?token=' || v_token
                 || '&event_id=' || r.sg_event_id::text,
          timeout_milliseconds := 30000) INTO v_req;
        INSERT INTO public.n2s_mkt_pull(request_id, source, tevo_event_id, mkt_event_id)
        VALUES (v_req, 'seatgeek', r.tevo_event_id, r.sg_event_id);
        UPDATE public.sg_event_priority_state
           SET last_polled_listings_at = now(),
               listings_polls_today    = listings_polls_today + 1
         WHERE sg_event_id = r.sg_event_id;
        v_sg := v_sg + 1;
      END LOOP;
    END IF;
  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'n2s_pull_events: seatgeek failed: %', SQLERRM;
  END;

  BEGIN
    SELECT events_enqueued INTO v_td FROM public.n2s_td_enqueue(cardinality(p_events));
  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'n2s_pull_events: ticketsdata enqueue failed: %', SQLERRM;
    v_td := 0;
  END;

  RETURN QUERY SELECT v_evo, v_gt, v_sg, COALESCE(v_td,0),
                      v_evo_skip, v_gt_skip, v_evo_unknown;
END $function$;

-- tick: land our responses first, then pull; re-poll in-window orders every 2 min
DO $$
DECLARE
  v_def text := pg_get_functiondef('public.n2s_pipeline_tick'::regproc);
  v_old text := '      PERFORM * FROM public.n2s_pull_all_sources();';
  v_new text := '      PERFORM * FROM public.n2s_mkt_drain();' || E'\n'
             || '      PERFORM * FROM public.n2s_pull_all_sources(p_refresh_after => interval ''2 minutes'', p_sweep_after => interval ''2 minutes'', p_uncovered_only => false);';
BEGIN
  IF md5(v_def) <> '4788b06168aad45d6ff13931587e1f38' THEN
    RAISE EXCEPTION 'n2s_pipeline_tick drifted from the reviewed body — refusing';
  END IF;
  IF (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 THEN
    RAISE EXCEPTION 'n2s_pipeline_tick: pull_all_sources call not found exactly once';
  END IF;
  EXECUTE replace(v_def, v_old, v_new);
END $$;

-- rollback: restore n2s_pull_events body md5 0157d7896e415808ec678285c0946af5
-- (fires into gt_listings_inflight / sg_listings_pull_on_demand), remove the
-- n2s_mkt_drain call and the pull_all_sources parameters from the tick.

-- Migration 20260927041700 · level:secondary-sales · lane:D7 · writes:n2s_evo_current,n2s_gt_current,n2s_sg_current,n2s_mkt_pull,n2s_mkt_drain,n2s_pull_events,n2s_cover_queue_refresh,n2s_cover_candidates · reads:events,gotickets_event,sg_events_canonical,aq_event_map,settings · pre:20260927040300
--
-- Already applied to prod · via MCP 2026-09-27 04:17 UTC under operator direction
-- ("We have to separate n2s polling and retention from the regular terminal
-- polling and retention, have them only share the timer to prevent rate
-- limits"), after rolled-back dry runs with LIVE read-only EVO/GoTickets GETs:
-- EVO-only candidates 23 → 36 (0 lost), SeatGeek 0 → 32, orders covered 12 → 18.
-- The signed EVO request was first proven with one synchronous GET (200, 87
-- groups for an event the terminal had seen 75 of in the last hour).
--
-- RULE 2: every upstream call here is a GET (EVO /v9/ticket_groups, GoTickets
-- /events/{id}/listings, SeatGeek /listings). No write endpoint is touched.
-- ============================================================================

-- N2S polling + retention separated from the terminal's. N2S fires its own
-- EVO / GoTickets / SeatGeek requests (n2s_mkt_pull), lands each response as
-- the FULL current list for that event (n2s_evo_current / n2s_gt_current /
-- n2s_sg_current), and the cover search reads only those. Nothing N2S does
-- writes the terminal snapshot tables any more. The two share one thing: the
-- per-event poll timers (evo_listings_poll_state / gt_listings_poll_state /
-- sg_event_priority_state) — N2S resets them when it fires and skips an event
-- anyone polled within 60 s, so the two never double-hit a source.

CREATE TABLE IF NOT EXISTS public.n2s_evo_current (
  event_id             bigint NOT NULL,
  tevo_ticket_group_id bigint NOT NULL,
  section              text,
  "row"                text,
  quantity             integer,
  retail_price         numeric,
  splits               integer[],
  is_owned             boolean NOT NULL DEFAULT false,
  is_ancillary         boolean NOT NULL DEFAULT false,
  public_notes         text,
  view_type            text,
  pulled_at            timestamptz NOT NULL,
  PRIMARY KEY (event_id, tevo_ticket_group_id)
);
ALTER TABLE public.n2s_evo_current ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.n2s_evo_current FROM PUBLIC, anon, authenticated;
COMMENT ON TABLE public.n2s_evo_current IS
  'N2S-owned: full current EVO ticket-group list per event, replaced on every N2S EVO response. Separate from the terminal''s change-only listings_snapshots.';

CREATE TABLE IF NOT EXISTS public.n2s_gt_current (
  tevo_event_id bigint NOT NULL,
  gt_event_id   bigint NOT NULL,
  gt_listing_id bigint NOT NULL,
  section       text,
  section_id    bigint,
  "row"         text,
  quantity      integer,
  all_in_price  numeric,
  splits        integer[],
  notes         text,
  pulled_at     timestamptz NOT NULL,
  PRIMARY KEY (tevo_event_id, gt_listing_id)
);
ALTER TABLE public.n2s_gt_current ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.n2s_gt_current FROM PUBLIC, anon, authenticated;
COMMENT ON TABLE public.n2s_gt_current IS
  'N2S-owned: full current GoTickets listing list per event, replaced on every N2S GoTickets response. Separate from the terminal''s gotickets_listings_snapshots.';

COMMENT ON TABLE public.n2s_sg_current IS
  'N2S-owned: full current SeatGeek listing list per event, replaced on every N2S SeatGeek response. Separate from the terminal''s change-only seatgeek_listings_snapshots.';

-- the interim "full=1 via collect-listings" anchor is superseded
DROP TABLE IF EXISTS public.n2s_evo_full_pulls;

ALTER TABLE public.n2s_mkt_pull DROP CONSTRAINT IF EXISTS n2s_mkt_pull_source_check;
ALTER TABLE public.n2s_mkt_pull ADD CONSTRAINT n2s_mkt_pull_source_check
  CHECK (source IN ('evo', 'gotickets', 'seatgeek'));
COMMENT ON TABLE public.n2s_mkt_pull IS
  'N2S-owned EVO/GoTickets/SeatGeek listing requests: fired by n2s_pull_events, landed by n2s_mkt_drain into n2s_*_current. Independent of the terminal queues and snapshot tables.';

DO $$ BEGIN
  IF md5(pg_get_functiondef('public.n2s_mkt_drain'::regproc)) <> '0911e12c9081a7528d69a8e00b5a3223' THEN
    RAISE EXCEPTION 'n2s_mkt_drain drifted — refusing'; END IF;
  IF md5(pg_get_functiondef('public.n2s_pull_events'::regproc)) <> 'b418965684fbd660aa5e8c0a03495b86' THEN
    RAISE EXCEPTION 'n2s_pull_events drifted — refusing'; END IF;
  IF md5(pg_get_functiondef('public.n2s_cover_queue_refresh'::regproc)) <> '948dd98c2bfee6be6ad4d7d9de0d8078' THEN
    RAISE EXCEPTION 'n2s_cover_queue_refresh drifted — refusing'; END IF;
  IF md5(pg_get_functiondef('public.n2s_cover_candidates'::regproc)) <> '02ae347b95a1f835d0abf11920d2e880' THEN
    RAISE EXCEPTION 'n2s_cover_candidates drifted — refusing'; END IF;
END $$;

-- ── land responses: each one REPLACES that event's N2S current list ────────
CREATE OR REPLACE FUNCTION public.n2s_mkt_drain()
 RETURNS TABLE(gt_landed integer, sg_landed integer, rows_persisted integer, expired integer)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  r RECORD; v_gt int := 0; v_sg int := 0; v_rows int := 0; v_n int; v_ct int; v_exp int := 0;
  v_s4k bigint := COALESCE((SELECT NULLIF(regexp_replace(s.value::text, '\D', '', 'g'), '')::bigint
                              FROM public.settings s WHERE s.key = 's4k_brokerage_id'), 1768);
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
      IF r.source = 'evo' THEN
        IF r.status_code = 200 AND jsonb_typeof((r.content::jsonb) -> 'ticket_groups') = 'array' THEN
          DELETE FROM public.n2s_evo_current WHERE event_id = r.tevo_event_id;
          INSERT INTO public.n2s_evo_current (
            event_id, tevo_ticket_group_id, section, "row", quantity, retail_price, splits,
            is_owned, is_ancillary, public_notes, view_type, pulled_at)
          SELECT DISTINCT ON ((g->>'id')::bigint)
                 r.tevo_event_id, (g->>'id')::bigint, g->>'section', g->>'row',
                 COALESCE(NULLIF(g->>'available_quantity','')::int, 0),
                 NULLIF(g->>'retail_price','')::numeric,
                 CASE WHEN jsonb_typeof(g->'splits') = 'array'
                      THEN ARRAY(SELECT e::int FROM jsonb_array_elements_text(g->'splits') AS e
                                  WHERE e ~ '^[0-9]+$') END,
                 COALESCE(NULLIF(g #>> '{office,brokerage,id}','')::bigint = v_s4k, false),
                 (COALESCE(g->>'type', 'event') <> 'event'
                  OR COALESCE(g->>'section','') ~* '(vip lounge|hospitality|premium lounge|club lounge|\ysuite\y|meet.{0,4}greet)'),
                 NULLIF(btrim(left(g->>'public_notes', 500)), ''),
                 NULLIF(btrim(left(g->>'view_type', 80)), ''),
                 now()
            FROM jsonb_array_elements((r.content::jsonb) -> 'ticket_groups') AS g
           WHERE g->>'id' ~ '^[0-9]+$';
          GET DIAGNOSTICS v_n = ROW_COUNT;
        END IF;

      ELSIF r.source = 'gotickets' THEN
        v_gt := v_gt + 1;
        IF r.status_code = 200 AND r.content IS NOT NULL THEN
          v_ct := jsonb_array_length(COALESCE((r.content::jsonb) -> 'listings', '[]'::jsonb));
          DELETE FROM public.n2s_gt_current WHERE tevo_event_id = r.tevo_event_id;
          INSERT INTO public.n2s_gt_current (
            tevo_event_id, gt_event_id, gt_listing_id, section, section_id, "row",
            quantity, all_in_price, splits, notes, pulled_at)
          SELECT DISTINCT ON (l."id")
                 r.tevo_event_id, r.mkt_event_id, l."id", l.section, l."sectionId", l.row,
                 l.quantity, l."allInPrice",
                 ARRAY(SELECT jsonb_array_elements_text(COALESCE(l."validSplitQuantities", '[]'::jsonb))::int),
                 l.notes, now()
            FROM jsonb_to_recordset(COALESCE((r.content::jsonb) -> 'listings', '[]'::jsonb)) AS l(
                   "id" bigint, section text, "sectionId" bigint, row text, quantity int,
                   "allInPrice" numeric, "validSplitQuantities" jsonb, notes text)
           WHERE l."id" IS NOT NULL;
          GET DIAGNOSTICS v_n = ROW_COUNT;
        END IF;
        -- shared per-event state: the terminal's cold / quarantine logic sees our results too
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
          DELETE FROM public.n2s_sg_current WHERE tevo_event_id = r.tevo_event_id;
          INSERT INTO public.n2s_sg_current (
            tevo_event_id, sg_event_id, display_id, sglid, section, "row", quantity,
            retail_price_all_in, splits, is_broker_owned, has_limited_view, seller_notes, pulled_at)
          SELECT DISTINCT ON (l->>'id')
                 r.tevo_event_id, r.mkt_event_id, l->>'id', NULLIF(l->>'sglid','')::bigint,
                 l->>'s', l->>'r', NULLIF(l->>'q','')::int, NULLIF(l->>'pf','')::numeric,
                 l->'sp', NULLIF(l->>'bo','')::boolean, NULLIF(l->>'lv','')::boolean,
                 l->>'pn', now()
            FROM jsonb_array_elements((r.content::jsonb) -> 'listings') AS l
           WHERE l->>'id' IS NOT NULL;
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

  -- retention: N2S keeps only the current list per event, for a day
  DELETE FROM public.n2s_mkt_pull    WHERE fired_at  < now() - interval '3 days';
  DELETE FROM public.n2s_evo_current WHERE pulled_at < now() - interval '1 day';
  DELETE FROM public.n2s_gt_current  WHERE pulled_at < now() - interval '1 day';
  DELETE FROM public.n2s_sg_current  WHERE pulled_at < now() - interval '1 day';

  RETURN QUERY SELECT v_gt, v_sg, v_rows, v_exp;
END $function$;
REVOKE ALL ON FUNCTION public.n2s_mkt_drain() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.n2s_mkt_drain() TO service_role;

-- ── fire: N2S's own requests; the per-event timers are the only shared thing ─
CREATE OR REPLACE FUNCTION public.n2s_pull_events(p_events bigint[], p_refresh_after interval DEFAULT '00:05:00'::interval)
 RETURNS TABLE(evo_fired integer, gt_fired integer, sg_queued integer, td_queued integer, evo_skipped_fresh integer, gt_skipped_fresh integer, evo_skipped_unknown integer)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE
  r RECORD; v_tok text; v_sec text; v_q text; v_req bigint;
  v_evo int := 0; v_gt int := 0; v_sg int := 0; v_td int := 0;
  v_evo_known int := 0; v_gt_cand int := 0; v_evo_unknown int := 0;
  -- another poller hit this event this recently -> skip (rate-limit guard)
  v_shared interval := interval '60 seconds';
BEGIN
  IF p_events IS NULL OR cardinality(p_events) = 0 THEN
    RETURN QUERY SELECT 0, 0, 0, 0, 0, 0, 0; RETURN;
  END IF;

  SELECT count(*) FILTER (WHERE NOT EXISTS (SELECT 1 FROM public.events ev WHERE ev.id = e)),
         count(*) FILTER (WHERE EXISTS (SELECT 1 FROM public.events ev WHERE ev.id = e))
    INTO v_evo_unknown, v_evo_known
    FROM unnest(p_events) AS e;

  -- ── EVO: signed GET /v9/ticket_groups (read-only), one call = whole event ──
  v_tok := public.get_app_secret('TEVO_API_TOKEN');
  v_sec := public.get_app_secret('TEVO_SECRET');
  IF COALESCE(v_tok, '') <> '' AND COALESCE(v_sec, '') <> '' THEN
    FOR r IN
      SELECT DISTINCT e AS eid FROM unnest(p_events) AS e
       WHERE EXISTS (SELECT 1 FROM public.events ev WHERE ev.id = e)
         AND NOT EXISTS (SELECT 1 FROM public.n2s_mkt_pull q
                          WHERE q.source = 'evo' AND q.mkt_event_id = e
                            AND (q.resolved_at IS NULL OR q.fired_at >= now() - p_refresh_after))
         AND NOT EXISTS (SELECT 1 FROM public.evo_listings_poll_state ps
                          WHERE ps.event_id = e AND ps.last_polled_listings_at >= now() - v_shared)
    LOOP
      v_q := 'event_id=' || r.eid::text;
      SELECT net.http_get(
        url := 'https://api.ticketevolution.com/v9/ticket_groups?' || v_q,
        headers := jsonb_build_object(
          'X-Token', v_tok,
          'X-Signature', encode(extensions.hmac('GET api.ticketevolution.com/v9/ticket_groups?' || v_q, v_sec, 'sha256'), 'base64'),
          'Accept', 'application/vnd.ticketevolution.api+json; version=9'),
        timeout_milliseconds := 30000) INTO v_req;
      INSERT INTO public.n2s_mkt_pull(request_id, source, tevo_event_id, mkt_event_id)
      VALUES (v_req, 'evo', r.eid, r.eid);
      INSERT INTO public.evo_listings_poll_state(
               event_id, last_polled_listings_at, listings_polls_today, budget_day)
      VALUES (r.eid, now(), 1, current_date)
      ON CONFLICT (event_id) DO UPDATE SET
        last_polled_listings_at = now(),
        listings_polls_today = CASE WHEN evo_listings_poll_state.budget_day < current_date
                                    THEN 1 ELSE evo_listings_poll_state.listings_polls_today + 1 END,
        budget_day = current_date;
      v_evo := v_evo + 1;
    END LOOP;
  END IF;

  -- ── GoTickets ──
  v_tok := public._gotickets_pro_token();
  IF COALESCE(btrim(v_tok), '') <> '' THEN
    SELECT count(*) INTO v_gt_cand
      FROM public.gotickets_event g
      LEFT JOIN public.gt_listings_poll_state ps ON ps.gt_event_id = g.gt_event_id
     WHERE g.tevo_event_id = ANY(p_events)
       AND (ps.quarantined_until IS NULL OR ps.quarantined_until < now());

    FOR r IN
      SELECT g.gt_event_id, g.tevo_event_id
        FROM public.gotickets_event g
        LEFT JOIN public.gt_listings_poll_state ps ON ps.gt_event_id = g.gt_event_id
       WHERE g.tevo_event_id = ANY(p_events)
         AND (ps.quarantined_until IS NULL OR ps.quarantined_until < now())
         AND (ps.last_polled_listings_at IS NULL OR ps.last_polled_listings_at < now() - v_shared)
         AND NOT EXISTS (SELECT 1 FROM public.n2s_mkt_pull q
                          WHERE q.source = 'gotickets' AND q.mkt_event_id = g.gt_event_id
                            AND (q.resolved_at IS NULL OR q.fired_at >= now() - p_refresh_after))
    LOOP
      SELECT net.http_get(
        url := 'https://gotickets.com/rest/pro/api/events/' || r.gt_event_id::text || '/listings',
        headers := jsonb_build_object('X-Broker-Api-Token', v_tok, 'Accept', 'application/json'),
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

  -- ── SeatGeek: register hub-resolved events (fires nothing: p_max_events = 0),
  -- then fire our own request per event ──
  BEGIN
    PERFORM * FROM public.sg_listings_pull_on_demand(p_events, 0, p_refresh_after);
    v_tok := public.get_app_secret('SEATGEEK_API_TOKEN');
    IF COALESCE(v_tok, '') <> '' THEN
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
                              AND ps.last_polled_listings_at >= now() - v_shared)
           AND NOT EXISTS (SELECT 1 FROM public.sg_broker_pending b
                            WHERE b.scope = 'listings' AND b.sg_event_id = rs.sg_event_id
                              AND b.fired_at >= now() - v_shared)
           AND NOT EXISTS (SELECT 1 FROM public.n2s_mkt_pull q
                            WHERE q.source = 'seatgeek' AND q.mkt_event_id = rs.sg_event_id
                              AND (q.resolved_at IS NULL OR q.fired_at >= now() - p_refresh_after))
      LOOP
        SELECT net.http_get(
          url := 'https://brokerdata.seatgeek.com/listings?token=' || v_tok
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
                      GREATEST(v_evo_known - v_evo, 0), GREATEST(v_gt_cand - v_gt, 0), v_evo_unknown;
END $function$;
-- pipeline-only: it fires marketplace requests with our tokens
REVOKE ALL ON FUNCTION public.n2s_pull_events(bigint[], interval) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.n2s_pull_events(bigint[], interval) TO service_role;
REVOKE ALL ON FUNCTION public.n2s_pull_all_sources(integer, interval, interval, boolean, integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.n2s_pull_all_sources(integer, interval, interval, boolean, integer) TO service_role;

-- ── view quality: read the N2S current lists ──
CREATE OR REPLACE FUNCTION public.n2s_cover_queue_refresh()
 RETURNS TABLE(rows_written integer, orders_covered integer, total_cover_cost numeric)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_n int := 0;
BEGIN
  DELETE FROM public.n2s_cover_queue;

  INSERT INTO public.n2s_cover_queue (
    n2s_id, order_number, s4k_source, n2s_status, fail_reason, timer_expired,
    event_name, event_date, venue, tevo_event_id, section, order_row, quantity,
    sold_ea, sub_source, sub_listing_id, sub_section, sub_row, sub_qty,
    sub_avail, sub_ea, sub_total, cover_cost, rows_closer, buy_url,
    captured_at, cover_rank, fifo_position, refreshed_at,
    cover_gate, cover_label, order_zone, sub_zone)
  SELECT c.n2s_id, c.order_number, c.s4k_source, c.n2s_status, c.fail_reason,
         c.timer_expired, c.event_name, c.event_date, c.venue, c.tevo_event_id,
         c.section, c.order_row, c.quantity, c.sold_ea, c.sub_source,
         c.sub_listing_id, c.sub_section, c.sub_row, c.sub_qty, c.sub_avail,
         c.sub_ea, c.sub_total, c.cover_cost, c.rows_closer, c.buy_url,
         c.captured_at, c.cover_rank, c.fifo_position, now(),
         c.cover_gate, c.cover_label, c.order_zone, c.sub_zone
    FROM public.n2s_covers() c;

  GET DIAGNOSTICS v_n = ROW_COUNT;
  -- view quality: baseline every covered row to 'unknown', then correct
  -- the two sources that actually publish a signal. See n2s_view_of().
  UPDATE public.n2s_cover_queue q SET sub_view = 'unknown'
   WHERE q.sub_listing_id IS NOT NULL;

  UPDATE public.n2s_cover_queue q
     SET sub_notes = s.notes,
         sub_view  = public.n2s_view_of(s.notes, s.lv)
    FROM (
      -- one primary-key lookup per covered row in the N2S current lists
      SELECT q2.n2s_id, x.notes, x.lv
        FROM public.n2s_cover_queue q2
        CROSS JOIN LATERAL (
          (SELECT g.notes, NULL::boolean AS lv
             FROM public.n2s_gt_current g
            WHERE q2.sub_source = 'gotickets'
              AND g.tevo_event_id = q2.tevo_event_id
              AND g.gt_listing_id::text = q2.sub_listing_id
            LIMIT 1)
          UNION ALL
          (SELECT sc.seller_notes, sc.has_limited_view
             FROM public.n2s_sg_current sc
            WHERE q2.sub_source = 'seatgeek'
              AND sc.tevo_event_id = q2.tevo_event_id
              AND sc.sglid::text   = q2.sub_listing_id
            LIMIT 1)
        ) x
       WHERE q2.sub_listing_id IS NOT NULL
         AND q2.sub_source IN ('gotickets', 'seatgeek')
    ) s
   WHERE s.n2s_id = q.n2s_id;

  -- and into the LABEL, so a consumer that only reads cover_label still
  -- sees it. Safe to append unconditionally: the refresh DELETEs the whole
  -- queue and rebuilds it every run, so the suffix cannot accumulate.
  UPDATE public.n2s_cover_queue q
     SET cover_label = q.cover_label || ' obstructed view'
   WHERE q.sub_view = 'obstructed' AND q.cover_label IS NOT NULL;

  RETURN QUERY
    SELECT v_n,
           (SELECT count(*)::int FROM public.n2s_cover_queue),
           (SELECT round(COALESCE(sum(cover_cost), 0), 2) FROM public.n2s_cover_queue);
END $function$;

-- ── cover search: read ONLY the N2S current lists ──
DO $$
DECLARE
  v_def text := pg_get_functiondef('public.n2s_cover_candidates'::regproc);
  v_a int; v_b int;
  v_cte text := $x$  p_evo AS (SELECT DISTINCT c.event_id AS eid FROM public.n2s_evo_current c
                WHERE c.event_id IN (SELECT eid FROM ev)
                  AND c.pulled_at >= now() - p_max_listing_age),
  p_gtc AS (SELECT DISTINCT c.tevo_event_id AS eid FROM public.n2s_gt_current c
                WHERE c.tevo_event_id IN (SELECT eid FROM ev)
                  AND c.pulled_at >= now() - p_max_listing_age),
  p_sgc AS (SELECT DISTINCT c.tevo_event_id AS eid FROM public.n2s_sg_current c
                WHERE c.tevo_event_id IN (SELECT eid FROM ev)
                  AND c.pulled_at >= now() - p_max_listing_age),
$x$;
  v_l text := $x$  l AS (
    SELECT 'tevo'::text AS src, t.tevo_ticket_group_id::text AS lid, t.event_id AS eid,
           t.section AS sec, t."row" AS rw, t.quantity AS q, t.retail_price AS ea,
           'https://core.ticketevolution.com/buy/event/' || t.event_id::text
             || '/tickets/' || t.tevo_ticket_group_id::text AS url,
           t.pulled_at AS captured_at, t.splits
      FROM p_evo p JOIN public.n2s_evo_current t ON t.event_id = p.eid
     WHERE NOT t.is_owned AND NOT t.is_ancillary
       AND (p_sub_sources IS NULL OR 'tevo' = ANY(p_sub_sources))
    UNION ALL
    SELECT 'gotickets', g.gt_listing_id::text, g.tevo_event_id,
           g.section, g."row", g.quantity, g.all_in_price,
           'https://pro.gotickets.com/tickets/' || g.gt_event_id
             || '/?sortBy=price&sortDirection=asc&sections=' || g.section_id,
           g.pulled_at, g.splits
      FROM p_gtc p JOIN public.n2s_gt_current g ON g.tevo_event_id = p.eid
     WHERE (p_sub_sources IS NULL OR 'gotickets' = ANY(p_sub_sources))
    UNION ALL
    SELECT 'seatgeek', sc.sglid::text, sc.tevo_event_id,
           sc.section, sc."row", sc.quantity, sc.retail_price_all_in,
           CASE WHEN COALESCE(c.sg_url,'') <> '' AND COALESCE(sc.display_id,'') <> ''
                THEN c.sg_url || '#listing=' || sc.display_id ELSE NULL::text END,
           sc.pulled_at,
           CASE WHEN jsonb_typeof(sc.splits) = 'array'
                THEN ARRAY(SELECT e::int FROM jsonb_array_elements_text(sc.splits) AS e
                            WHERE e ~ '^[0-9]+$')
                ELSE NULL::int[] END
      FROM p_sgc p JOIN public.n2s_sg_current sc ON sc.tevo_event_id = p.eid
      LEFT JOIN public.sg_events_canonical c ON c.sg_event_id = sc.sg_event_id
     WHERE NOT sc.is_broker_owned
       AND (p_sub_sources IS NULL OR 'seatgeek' = ANY(p_sub_sources))
$x$;
BEGIN
  v_a := position('  p_tevo AS (' in v_def);
  v_b := position('  td_cur AS (' in v_def);
  IF v_a = 0 OR v_b <= v_a THEN RAISE EXCEPTION 'n2s_cover_candidates: source-CTE region not found'; END IF;
  v_def := substring(v_def from 1 for v_a - 1) || v_cte || substring(v_def from v_b);

  v_a := position('  l AS (' in v_def);
  v_b := position(E'    UNION ALL\n    SELECT ''ticketsdata:''' in v_def);
  IF v_a = 0 OR v_b <= v_a THEN RAISE EXCEPTION 'n2s_cover_candidates: l region not found'; END IF;
  v_def := substring(v_def from 1 for v_a - 1) || v_l || substring(v_def from v_b);

  IF v_def ~ '(public\.listings_snapshots|gotickets_listings_snapshots|seatgeek_listings_snapshots|n2s_evo_full_pulls)' THEN
    RAISE EXCEPTION 'n2s_cover_candidates still references a terminal snapshot table';
  END IF;
  EXECUTE v_def;
END $$;

-- rollback: re-apply 20260927040300's n2s_mkt_drain / n2s_pull_events /
-- n2s_cover_queue_refresh / n2s_cover_candidates bodies and GRANT EXECUTE on
-- n2s_pull_events / n2s_pull_all_sources back to authenticated.

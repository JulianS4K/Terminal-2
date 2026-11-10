-- Migration 20261110070000 · level:secondary-sales · lane:D7 · writes:n2s_autobuy_config,n2s_tickpick_seen,n2s_tickpick_confirm_by,n2s_tickpick_watch_tick,n2s_gt_order_dryrun_capture,n2s_evo_order_dryrun_capture,n2s_autobuy_enqueue_trg · reads:n2s_cover_queue,n2s_items,n2s_tickpick_seen,vault.decrypted_secrets · pre:20261110060000
--
-- N2S auto-buy LIVE: TickPick becomes a sell market (an EVO sub covering a TickPick sale).
--
-- Operator 2026-11-10: "add tickpick to auto-accept markets", then "build tickpick now" once the
-- watch (20261110040000) showed N2S's TickPick sales ARE visible to our TickPick seller login
-- while open: 3 of 3 that night, listed Unconfirmed until their confirm deadline, then gone (404).
-- The accept itself is sale_accept_client.py (POST /1.0/orders/{n}/confirmation, pinned by
-- SALE_ACCEPT_WRITES); the worker also re-reads the sale right before buying (still Unconfirmed
-- on our login) and right after accepting (no longer Unconfirmed, not Canceled / Busted).
-- No HTTP write is added to any SQL here: the watch below stays GET only.
--
--   1. TickPick's confirm deadline in UTC. TickPick gives confirmation_deadline in the event's
--      local time with no offset, plus event_timezone as an abbreviation (EST / CST / MST / PST
--      / EDT ...), event_date (local) and event_date_utc. n2s_tickpick_confirm_by() reads the
--      deadline in the US zone named by the abbreviation and only when that zone also turns
--      event_date into event_date_utc; anything else is NULL (never a guess). Checked on the
--      three sales of 2026-11-09: 00:50:16, 01:55:29 and 02:24:51 UTC, each about 5 minutes
--      before the order stopped being listed.
--   2. n2s_tickpick_watch_tick() now stores event_timezone, event_date_utc and confirm_by.
--   3. The dry run (both capture functions) now includes sales made on TickPick, whose token
--      works again (tickpick_token_refresh, 20261110020000).
--   4. n2s_autobuy_enqueue_trg(): s4k_source 'TickPick' → sell market 'tickpick'; its allotted
--      time is the sale's own deadline once the watch has seen it, else 540 s (the shortest
--      window seen is 600 s). Every other guard is unchanged (the event more than 24 h out and
--      not today, caps, one live run, profit, a fresh price read, time to confirm the sub).
--   5. live_sell_markets: + 'tickpick'.
--
-- rollback: UPDATE n2s_autobuy_config SET live_sell_markets = ARRAY['evo','gotickets','seatgeek','vivid'];
--           then re-create the three functions from 20261029170000 / 20261110000000 / 20261110040000
--           (the added columns and n2s_tickpick_confirm_by are harmless to keep).

ALTER TABLE public.n2s_tickpick_seen
  ADD COLUMN IF NOT EXISTS event_timezone text,
  ADD COLUMN IF NOT EXISTS event_date_utc text,
  ADD COLUMN IF NOT EXISTS confirm_by     timestamptz;

CREATE OR REPLACE FUNCTION public.n2s_tickpick_confirm_by(p_deadline text, p_tz text, p_event_local text,
                                                          p_event_utc text)
 RETURNS timestamptz
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'pg_catalog'
AS $function$
DECLARE
  v_zones text[] := CASE upper(btrim(COALESCE(p_tz, '')))
                      WHEN 'EST' THEN ARRAY['America/New_York']     WHEN 'EDT' THEN ARRAY['America/New_York']
                      WHEN 'CST' THEN ARRAY['America/Chicago']      WHEN 'CDT' THEN ARRAY['America/Chicago']
                      WHEN 'MST' THEN ARRAY['America/Denver', 'America/Phoenix']
                      WHEN 'MDT' THEN ARRAY['America/Denver']
                      WHEN 'PST' THEN ARRAY['America/Los_Angeles']  WHEN 'PDT' THEN ARRAY['America/Los_Angeles']
                      WHEN 'AKST' THEN ARRAY['America/Anchorage']   WHEN 'AKDT' THEN ARRAY['America/Anchorage']
                      WHEN 'HST' THEN ARRAY['Pacific/Honolulu'] END;
  v_out timestamptz;
BEGIN
  IF v_zones IS NULL OR p_deadline IS NULL OR p_event_local IS NULL OR p_event_utc IS NULL THEN
    RETURN NULL;
  END IF;
  SELECT min(p_deadline::timestamp AT TIME ZONE z) INTO v_out
    FROM unnest(v_zones) z
   WHERE (p_event_local::timestamp AT TIME ZONE z) = (p_event_utc::timestamp AT TIME ZONE 'UTC');
  RETURN v_out;
EXCEPTION WHEN OTHERS THEN
  RETURN NULL;   -- unparseable text: unknown, never a guess
END $function$;

REVOKE ALL ON FUNCTION public.n2s_tickpick_confirm_by(text, text, text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.n2s_tickpick_confirm_by(text, text, text, text) TO service_role;

CREATE OR REPLACE FUNCTION public.n2s_tickpick_watch_tick()
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  tok   text;
  r     extensions.http_response;
  j     jsonb;
  o     RECORD;
  n_seen int := 0;
  n_id   int := 0;
BEGIN
  SELECT decrypted_secret INTO tok FROM vault.decrypted_secrets WHERE name = 'TICKPICK_API_TOKEN';
  IF tok IS NULL THEN RETURN 'no_token'; END IF;
  PERFORM set_config('http.timeout_msec', '20000', true);

  -- 1. Everything the account shows unconfirmed right now.
  BEGIN
    r := extensions.http(('GET', 'https://api.tickpick.com/1.0/orders?status=unconfirmed',
           ARRAY[extensions.http_header('Authorization', 'Bearer ' || tok)], NULL, NULL)::extensions.http_request);
    IF r.status = 200 AND r.content ~ '^\s*\[' THEN
      j := r.content::jsonb;
      INSERT INTO public.n2s_tickpick_seen AS s
             (order_number, seller_status, order_status, confirmation_deadline, purchase_date, event_name, event_date,
              section, row_name, quantity, wholesale_price, event_timezone, event_date_utc, confirm_by)
      SELECT e->>'order_number', e->>'seller_status', e->>'order_status', e->>'confirmation_deadline', e->>'purchase_date',
             e->>'event_name', e->>'event_date', e->>'section', e->>'row', NULLIF(e->>'quantity','')::int,
             NULLIF(e->>'wholesale_price','')::numeric, e->>'event_timezone', e->>'event_date_utc',
             public.n2s_tickpick_confirm_by(e->>'confirmation_deadline', e->>'event_timezone',
                                            e->>'event_date', e->>'event_date_utc')
        FROM jsonb_array_elements(j) e
       WHERE e->>'order_number' IS NOT NULL
      ON CONFLICT (order_number) DO UPDATE
         SET last_seen_at = now(), seen_count = s.seen_count + 1,
             seller_status = excluded.seller_status, order_status = excluded.order_status,
             confirmation_deadline = COALESCE(excluded.confirmation_deadline, s.confirmation_deadline),
             event_timezone = COALESCE(excluded.event_timezone, s.event_timezone),
             event_date_utc = COALESCE(excluded.event_date_utc, s.event_date_utc),
             confirm_by     = COALESCE(excluded.confirm_by, s.confirm_by);
      GET DIAGNOSTICS n_seen = ROW_COUNT;
    END IF;
  EXCEPTION WHEN OTHERS THEN
    n_seen := -1;   -- timeout / parse error: try again next minute
  END;

  -- 2. Each open N2S TickPick sale, by its order number (at most once a minute per order).
  FOR o IN
    SELECT i.n2s_id, i.n2s_order_key AS order_number
      FROM public.n2s_items i
     WHERE i.n2s_id > 0 AND lower(COALESCE(i.s4k_source, '')) LIKE 'tickpick%'
       AND i.n2s_order_key IS NOT NULL AND i.alert_at > now() - interval '20 minutes'
       AND NOT EXISTS (SELECT 1 FROM public.n2s_tickpick_byid_log l
                        WHERE l.order_number = i.n2s_order_key AND l.polled_at > now() - interval '50 seconds')
     ORDER BY i.alert_at DESC
     LIMIT 5
  LOOP
    BEGIN
      r := extensions.http(('GET', 'https://api.tickpick.com/1.0/orders/' || o.order_number,
             ARRAY[extensions.http_header('Authorization', 'Bearer ' || tok)], NULL, NULL)::extensions.http_request);
      j := CASE WHEN r.content ~ '^\s*\{' THEN r.content::jsonb END;
      INSERT INTO public.n2s_tickpick_byid_log (order_number, n2s_id, http, seller_status, order_status)
      VALUES (o.order_number, o.n2s_id, r.status, j->>'seller_status', j->>'order_status');
    EXCEPTION WHEN OTHERS THEN
      INSERT INTO public.n2s_tickpick_byid_log (order_number, n2s_id, http) VALUES (o.order_number, o.n2s_id, -1);
    END;
    n_id := n_id + 1;
  END LOOP;
  RETURN format('unconfirmed_rows=%s byid_polls=%s', n_seen, n_id);
END $function$;

REVOKE ALL ON FUNCTION public.n2s_tickpick_watch_tick() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.n2s_tickpick_watch_tick() TO service_role;

CREATE OR REPLACE FUNCTION public.n2s_gt_order_dryrun_capture(p_per_order_cap numeric DEFAULT 2000, p_daily_cap numeric DEFAULT 15000, p_gates integer[] DEFAULT '{1,2}'::integer[])
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  r RECORD;
  v_reasons text[];
  v_day_start timestamptz :=
    date_trunc('day', now() AT TIME ZONE 'America/New_York') AT TIME ZONE 'America/New_York';
  v_spend numeric;
  v_view text;
  v_n int := 0;
BEGIN
  FOR r IN
    SELECT q.*, i.is_terminal, i.event_dt, i.timer_expires_at, i.timer_expired, i.alert_at,
           ge.gt_event_id,
           g.all_in_price AS live_price, g.quantity AS live_qty, g.splits AS live_splits,
           g.pulled_at AS live_pulled_at, g.notes AS live_notes
      FROM public.n2s_cover_queue q
      JOIN public.n2s_items i ON i.n2s_id = q.n2s_id
      LEFT JOIN LATERAL (SELECT e.gt_event_id FROM public.gotickets_event e
                          WHERE e.tevo_event_id = q.tevo_event_id LIMIT 1) ge ON true
      LEFT JOIN LATERAL (SELECT c.* FROM public.n2s_gt_current c
                          WHERE c.tevo_event_id = q.tevo_event_id
                            AND c.gt_listing_id::text = q.sub_listing_id
                          ORDER BY c.pulled_at DESC LIMIT 1) g ON true
     WHERE q.sub_source = 'gotickets'
       AND q.sub_listing_id IS NOT NULL
       AND q.sub_ea IS NOT NULL
       -- non-PED only (operator 2026-10-28)
       AND q.n2s_id > 0
       AND COALESCE(i.status, '') NOT IN ('n2b', 'n2b_closed')
       -- sold on a marketplace whose API token works (operator 2026-10-28; TickPick 20261110070000)
       AND lower(COALESCE(q.s4k_source, '')) LIKE ANY (ARRAY['evo%', 'gotickets%', 'seatgeek%', 'vivid%', 'tickpick%'])
       AND NOT EXISTS (SELECT 1 FROM public.n2s_gt_order_dryrun d
                        WHERE d.n2s_id = q.n2s_id
                          AND d.sub_listing_id = q.sub_listing_id
                          AND d.quoted_ea = q.sub_ea)
     ORDER BY q.fifo_position NULLS LAST, q.n2s_id
  LOOP
    v_reasons := '{}';
    v_view := CASE WHEN r.live_notes IS NULL THEN 'unknown'
                   ELSE public.n2s_view_of(r.live_notes, NULL) END;

    SELECT COALESCE(sum(d.quoted_total), 0) INTO v_spend
      FROM public.n2s_gt_order_dryrun d
     WHERE d.decision = 'would_buy' AND d.captured_at >= v_day_start;

    IF NOT (COALESCE(r.cover_gate, 0) = ANY (p_gates))  THEN v_reasons := array_append(v_reasons, 'gate_moves_buyer'); END IF;
    IF v_view = 'obstructed'                            THEN v_reasons := array_append(v_reasons, 'obstructed_view'); END IF;
    IF r.gt_event_id IS NULL                            THEN v_reasons := array_append(v_reasons, 'no_gt_event_id'); END IF;
    IF r.live_price IS NULL THEN
      v_reasons := array_append(v_reasons, 'listing_gone');
    ELSE
      IF r.live_price > r.sub_ea                        THEN v_reasons := array_append(v_reasons, 'price_up'); END IF;
      IF COALESCE(r.live_qty, 0) < COALESCE(r.sub_qty, 1) THEN v_reasons := array_append(v_reasons, 'qty_unavailable'); END IF;
      IF cardinality(r.live_splits) > 0
         AND NOT (COALESCE(r.sub_qty, 1) = ANY (r.live_splits)) THEN v_reasons := array_append(v_reasons, 'split_not_allowed'); END IF;
    END IF;
    IF COALESCE(r.is_terminal, false)                   THEN v_reasons := array_append(v_reasons, 'order_closed'); END IF;
    IF NOT public.n2s_timer_open(r.timer_expires_at, r.timer_expired, r.alert_at)
                                                        THEN v_reasons := array_append(v_reasons, 'timer_closed'); END IF;
    IF NOT public.n2s_event_live(r.event_dt, r.tevo_event_id, interval '0')
                                                        THEN v_reasons := array_append(v_reasons, 'event_started'); END IF;
    IF COALESCE(r.sub_total, 0) > p_per_order_cap       THEN v_reasons := array_append(v_reasons, 'over_order_cap'); END IF;
    IF v_spend + COALESCE(r.sub_total, 0) > p_daily_cap THEN v_reasons := array_append(v_reasons, 'over_daily_cap'); END IF;
    IF EXISTS (SELECT 1 FROM public.n2s_gt_order_dryrun d
                WHERE d.n2s_id = r.n2s_id AND d.decision = 'would_buy')
                                                        THEN v_reasons := array_append(v_reasons, 'already_bought'); END IF;
    -- 20261029170000: level mismatch, one listing per order, time budget for the seller to accept our buy
    v_reasons := v_reasons || public.n2s_dryrun_extra_reasons(r.n2s_id, 'gotickets', r.sub_listing_id,
                                                              r.section, r.sub_section, r.timer_expires_at);

    INSERT INTO public.n2s_gt_order_dryrun (
      n2s_id, order_number, s4k_source, event_name, event_date, tevo_event_id,
      gt_event_id, sold_section, sold_row, sold_qty, sold_ea,
      sub_listing_id, sub_section, sub_row, sub_qty, quoted_ea, quoted_total,
      cover_cost, cover_gate, cover_label,
      live_price_ea, live_qty, live_splits, live_pulled_at, sub_view,
      seconds_left, decision, skip_reasons, per_order_cap, daily_cap, day_spend_before, payload)
    VALUES (
      r.n2s_id, r.order_number, r.s4k_source, r.event_name, r.event_date, r.tevo_event_id,
      r.gt_event_id, r.section, r.order_row, r.quantity, r.sold_ea,
      r.sub_listing_id, r.sub_section, r.sub_row, r.sub_qty, r.sub_ea, r.sub_total,
      r.cover_cost, r.cover_gate, r.cover_label,
      r.live_price, r.live_qty, r.live_splits, r.live_pulled_at, v_view,
      GREATEST(0, extract(epoch FROM (r.timer_expires_at - now())))::int,
      CASE WHEN cardinality(v_reasons) = 0 THEN 'would_buy' ELSE 'skip' END,
      v_reasons, p_per_order_cap, p_daily_cap, v_spend,
      jsonb_build_object(
        '_dry_run',           true,
        '_not_sent',          'Dry run only. Nothing calls GoTickets (20261021180000).',
        'endpoint',           'POST https://gotickets.com/rest/pro/api/orders',
        'eventId',            r.gt_event_id,
        'listingId',          r.sub_listing_id,
        'quantity',           r.sub_qty,
        'expectedTotal',      NULL,
        'paymentMethodToken', NULL,
        'deliveryMethodId',   NULL,
        'emailAddress',       NULL,
        'phoneNumber',        NULL,
        'billingAddress',     NULL,
        'recipient',          NULL,
        'buyerNotes',         'N2S cover for ' || COALESCE(r.s4k_source, '?') || ' order ' || r.order_number,
        '_reference',         jsonb_build_object(
            'quoted_ea', r.sub_ea, 'quoted_total', r.sub_total,
            'cover_cost', r.cover_cost, 'buy_url', r.buy_url)))
    ON CONFLICT ON CONSTRAINT n2s_gt_order_dryrun_once DO NOTHING;

    v_n := v_n + 1;
  END LOOP;
  RETURN v_n;
END $function$;

CREATE OR REPLACE FUNCTION public.n2s_evo_order_dryrun_capture(p_per_order_cap numeric DEFAULT 2000, p_daily_cap numeric DEFAULT 15000, p_gates integer[] DEFAULT '{1}'::integer[])
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  r RECORD;
  v_reasons text[];
  v_day_start timestamptz :=
    date_trunc('day', now() AT TIME ZONE 'America/New_York') AT TIME ZONE 'America/New_York';
  v_spend numeric;
  v_view text;
  v_n int := 0;
BEGIN
  FOR r IN
    SELECT q.*, i.is_terminal, i.event_dt, i.timer_expires_at, i.timer_expired, i.alert_at,
           e.retail_price AS live_price, e.quantity AS live_qty, e.splits AS live_splits,
           e.pulled_at AS live_pulled_at, e.public_notes AS live_notes, e.is_owned
      FROM public.n2s_cover_queue q
      JOIN public.n2s_items i ON i.n2s_id = q.n2s_id
      LEFT JOIN LATERAL (SELECT c.* FROM public.n2s_evo_current c
                          WHERE c.event_id = q.tevo_event_id
                            AND c.tevo_ticket_group_id::text = q.sub_listing_id
                          ORDER BY c.pulled_at DESC LIMIT 1) e ON true
     WHERE q.sub_source = 'tevo'
       AND q.sub_listing_id IS NOT NULL
       AND q.sub_ea IS NOT NULL
       AND q.n2s_id > 0
       AND COALESCE(i.status, '') NOT IN ('n2b', 'n2b_closed')
       AND lower(COALESCE(q.s4k_source, '')) LIKE ANY (ARRAY['evo%', 'gotickets%', 'seatgeek%', 'vivid%', 'tickpick%'])
       AND NOT EXISTS (SELECT 1 FROM public.n2s_gt_order_dryrun d
                        WHERE d.n2s_id = q.n2s_id
                          AND d.sub_listing_id = q.sub_listing_id
                          AND d.quoted_ea = q.sub_ea)
     ORDER BY q.fifo_position NULLS LAST, q.n2s_id
  LOOP
    v_reasons := '{}';
    v_view := CASE WHEN r.live_notes IS NULL THEN 'unknown'
                   ELSE public.n2s_view_of(r.live_notes, NULL) END;

    SELECT COALESCE(sum(d.quoted_total), 0) INTO v_spend
      FROM public.n2s_gt_order_dryrun d
     WHERE d.decision = 'would_buy' AND d.captured_at >= v_day_start;

    IF NOT (COALESCE(r.cover_gate, 0) = ANY (p_gates))  THEN v_reasons := array_append(v_reasons, 'gate_moves_buyer'); END IF;
    IF v_view = 'obstructed'                            THEN v_reasons := array_append(v_reasons, 'obstructed_view'); END IF;
    IF COALESCE(r.is_owned, false)                      THEN v_reasons := array_append(v_reasons, 'our_own_listing'); END IF;
    IF r.live_price IS NULL THEN
      v_reasons := array_append(v_reasons, 'listing_gone');
    ELSE
      IF r.live_price > r.sub_ea                        THEN v_reasons := array_append(v_reasons, 'price_up'); END IF;
      IF COALESCE(r.live_qty, 0) < COALESCE(r.sub_qty, 1) THEN v_reasons := array_append(v_reasons, 'qty_unavailable'); END IF;
      IF cardinality(r.live_splits) > 0
         AND NOT (COALESCE(r.sub_qty, 1) = ANY (r.live_splits)) THEN v_reasons := array_append(v_reasons, 'split_not_allowed'); END IF;
    END IF;
    IF COALESCE(r.is_terminal, false)                   THEN v_reasons := array_append(v_reasons, 'order_closed'); END IF;
    IF NOT public.n2s_timer_open(r.timer_expires_at, r.timer_expired, r.alert_at)
                                                        THEN v_reasons := array_append(v_reasons, 'timer_closed'); END IF;
    IF NOT public.n2s_event_live(r.event_dt, r.tevo_event_id, interval '0')
                                                        THEN v_reasons := array_append(v_reasons, 'event_started'); END IF;
    IF COALESCE(r.sub_total, 0) > p_per_order_cap       THEN v_reasons := array_append(v_reasons, 'over_order_cap'); END IF;
    IF v_spend + COALESCE(r.sub_total, 0) > p_daily_cap THEN v_reasons := array_append(v_reasons, 'over_daily_cap'); END IF;
    IF EXISTS (SELECT 1 FROM public.n2s_gt_order_dryrun d
                WHERE d.n2s_id = r.n2s_id AND d.decision = 'would_buy')
                                                        THEN v_reasons := array_append(v_reasons, 'already_bought'); END IF;
    -- 20261029170000: level mismatch, one listing per order, time budget for the seller to accept our buy
    v_reasons := v_reasons || public.n2s_dryrun_extra_reasons(r.n2s_id, 'tevo', r.sub_listing_id,
                                                              r.section, r.sub_section, r.timer_expires_at);

    INSERT INTO public.n2s_gt_order_dryrun (
      sub_source, n2s_id, order_number, s4k_source, event_name, event_date, tevo_event_id,
      gt_event_id, sold_section, sold_row, sold_qty, sold_ea,
      sub_listing_id, sub_section, sub_row, sub_qty, quoted_ea, quoted_total,
      cover_cost, cover_gate, cover_label,
      live_price_ea, live_qty, live_splits, live_pulled_at, sub_view,
      seconds_left, decision, skip_reasons, per_order_cap, daily_cap, day_spend_before, payload)
    VALUES (
      'tevo', r.n2s_id, r.order_number, r.s4k_source, r.event_name, r.event_date, r.tevo_event_id,
      NULL, r.section, r.order_row, r.quantity, r.sold_ea,
      r.sub_listing_id, r.sub_section, r.sub_row, r.sub_qty, r.sub_ea, r.sub_total,
      r.cover_cost, r.cover_gate, r.cover_label,
      r.live_price, r.live_qty, r.live_splits, r.live_pulled_at, v_view,
      GREATEST(0, extract(epoch FROM (r.timer_expires_at - now())))::int,
      CASE WHEN cardinality(v_reasons) = 0 THEN 'would_buy' ELSE 'skip' END,
      v_reasons, p_per_order_cap, p_daily_cap, v_spend,
      jsonb_build_object(
        '_dry_run',  true,
        '_not_sent', 'Dry run only. Nothing calls TEvo (20261028220000).',
        'endpoint',  'POST https://api.ticketevolution.com/v9/orders',
        'orders',    jsonb_build_array(jsonb_build_object(
            'ticket_group', jsonb_build_object('id', r.sub_listing_id, 'price', r.sub_ea),
            'quantity',     r.sub_qty,
            'seller_id',    NULL,
            'external_notes', 'N2S cover for ' || COALESCE(r.s4k_source, '?') || ' order ' || r.order_number)),
        '_reference', jsonb_build_object(
            'quoted_ea', r.sub_ea, 'quoted_total', r.sub_total,
            'cover_cost', r.cover_cost, 'buy_url', r.buy_url)))
    ON CONFLICT ON CONSTRAINT n2s_gt_order_dryrun_once DO NOTHING;

    v_n := v_n + 1;
  END LOOP;
  RETURN v_n;
END $function$;

REVOKE EXECUTE ON FUNCTION public.n2s_gt_order_dryrun_capture(numeric, numeric, integer[]) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.n2s_evo_order_dryrun_capture(numeric, numeric, integer[]) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.n2s_autobuy_enqueue_trg()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  c          public.n2s_autobuy_config%ROWTYPE;
  i          public.n2s_items%ROWTYPE;
  r          text[] := '{}';
  v_market   text;
  v_qty      int;
  v_price    numeric;
  v_sub      numeric;
  v_sold     numeric;
  v_cut      int;
  v_cut_src  text;
  v_confirm  timestamptz;
  v_spend    numeric;
  v_buys     int;
  v_fail     int;
  v_proj      numeric;
  v_tz_today date := (now() AT TIME ZONE 'America/New_York')::date;
  v_state    text;
BEGIN
  -- FOR UPDATE serializes enqueues: concurrent would_buys queue here, so each sees the spend
  -- the others committed and two buys can never both pass the daily / project cap.
  SELECT * INTO c FROM public.n2s_autobuy_config WHERE id FOR UPDATE;
  SELECT * INTO i FROM public.n2s_items WHERE n2s_id = NEW.n2s_id;
  IF EXISTS (SELECT 1 FROM public.n2s_autobuy_exec WHERE n2s_id = NEW.n2s_id) THEN
    RETURN NULL;                                         -- one attempt per sale; never a retry
  END IF;

  v_market := CASE WHEN lower(NEW.s4k_source) LIKE 'evo%' THEN 'evo'
                   WHEN lower(NEW.s4k_source) LIKE 'gotickets%' THEN 'gotickets'
                   WHEN lower(NEW.s4k_source) LIKE 'seatgeek%' THEN 'seatgeek'
                   WHEN lower(NEW.s4k_source) LIKE 'vivid%' THEN 'vivid'
                   WHEN lower(NEW.s4k_source) LIKE 'tickpick%' THEN 'tickpick' END;
  v_qty   := NEW.sub_qty;
  v_price := COALESCE(NEW.live_price_ea, NEW.quoted_ea);
  v_sub   := round(v_price * v_qty, 2);
  v_sold  := round(NEW.sold_ea * NEW.sold_qty, 2);

  IF v_market = 'tickpick' THEN
    -- 20261110070000: TickPick states each sale's own confirm deadline (10 min for a same-day
    -- event, 60 min later out, 2026-11-10). Use it once n2s_tickpick_watch_tick has seen the
    -- sale; until then 9 min, under the shortest window seen.
    SELECT extract(epoch FROM s.confirm_by - i.alert_at)::int INTO v_cut
      FROM public.n2s_tickpick_seen s WHERE s.order_number = i.n2s_order_key AND s.confirm_by IS NOT NULL;
    v_cut_src := CASE WHEN v_cut IS NULL THEN 'tickpick default (deadline not seen yet)'
                      ELSE 'tickpick confirmation_deadline' END;
    v_cut := COALESCE(v_cut, 540);
  ELSE
    -- allotted time: the market's median auto-reject (≥ 3 samples), else the CRM's 15 minutes
    SELECT median_cutoff_s, 'median of ' || samples || ' market rejects' INTO v_cut, v_cut_src
      FROM public.v_n2s_market_cutoff WHERE market = v_market AND samples >= 3;
    IF v_cut IS NULL THEN v_cut := c.default_cutoff_s; v_cut_src := 'default (no market data)'; END IF;
  END IF;
  v_confirm := i.alert_at + make_interval(secs => v_cut - c.accept_buffer_s);

  SELECT COALESCE(sum(sub_total_usd) FILTER (WHERE state IN ('shadow_buy', 'live_buy', 'awaiting_approval', 'approved')), 0),
         count(*) FILTER (WHERE state IN ('shadow_buy', 'live_buy', 'awaiting_approval', 'approved')),
         count(*) FILTER (WHERE state = 'blocked' AND 'circuit_breaker' <> ALL (reasons)
                            AND reasons && ARRAY['sub_rejected', 'sub_unconfirmed', 'buy_failed'])
    INTO v_spend, v_buys, v_fail
    FROM public.n2s_autobuy_exec
   WHERE mode = c.mode AND (created_at AT TIME ZONE 'America/New_York')::date = v_tz_today;

  -- Project spend: every buy ever committed in this mode, any market.
  SELECT COALESCE(sum(sub_total_usd), 0) INTO v_proj
    FROM public.n2s_autobuy_exec
   WHERE mode = c.mode AND state IN ('shadow_buy', 'live_buy', 'awaiting_approval', 'approved');

  IF c.mode = 'off' OR c.kill_switch THEN
    v_state := 'off';
  ELSE
    IF v_market IS NULL THEN r := r || 'sell_market_no_token'::text; END IF;
    IF NEW.sub_source NOT IN ('gotickets', 'tevo') THEN r := r || 'sub_source_not_buyable'::text; END IF;
    -- 20261109200000: soft launch buys only from the sources listed in buy_sources (EVO).
    IF NEW.sub_source <> ALL (c.buy_sources) THEN r := r || 'sub_source_disabled'::text; END IF;
    -- 20261110000000: live mode = an EVO sub covering an EVO sale, only while live runs remain.
    IF c.mode = 'live' THEN
      IF v_market IS NULL OR v_market <> ALL (c.live_sell_markets) THEN r := r || 'sell_market_not_live'::text; END IF;
      IF NEW.sub_source <> 'tevo' THEN r := r || 'sub_source_not_live'::text; END IF;
      IF c.live_runs_used >= c.live_runs_allowed THEN r := r || 'live_runs_used_up'::text; END IF;
    END IF;
    IF i.event_dt IS NULL THEN
      r := r || 'event_time_unknown'::text;
    ELSE
      -- event_dt is venue-local; read as UTC it is never later than the real start for US venues.
      IF (i.event_dt AT TIME ZONE 'UTC') < now() + c.min_event_lead THEN r := r || 'event_within_24h'::text; END IF;
      IF i.event_dt::date <= v_tz_today THEN r := r || 'same_day_event'::text; END IF;
    END IF;
    IF v_sub IS NULL OR v_qty IS NULL OR v_qty <= 0 THEN r := r || 'no_price'::text; END IF;
    IF v_sub > c.per_order_cap_usd THEN r := r || 'over_per_order_cap'::text; END IF;
    IF v_spend + v_sub > c.daily_cap_usd THEN r := r || 'over_daily_cap'::text; END IF;
    IF v_buys >= c.max_buys_per_day THEN r := r || 'max_buys_today'::text; END IF;
    IF v_fail >= c.max_failures_per_day THEN r := r || 'circuit_breaker'::text; END IF;
    IF EXISTS (SELECT 1 FROM public.n2s_autobuy_exec x
                WHERE x.tevo_event_id = NEW.tevo_event_id AND x.mode = c.mode
                  AND x.state IN ('shadow_buy', 'live_buy', 'awaiting_approval', 'approved')
                  AND (x.created_at AT TIME ZONE 'America/New_York')::date = v_tz_today) THEN
      r := r || 'event_already_bought_today'::text;
    END IF;
    IF EXISTS (SELECT 1 FROM public.n2s_autobuy_exec x
                WHERE x.sub_source = NEW.sub_source AND x.sub_listing_id = NEW.sub_listing_id
                  AND x.state IN ('shadow_buy', 'live_buy', 'awaiting_approval', 'approved')) THEN
      r := r || 'listing_already_used'::text;
    END IF;
    IF v_sold IS NULL OR v_sub >= v_sold THEN r := r || 'not_profitable'::text; END IF;
    IF NEW.live_price_ea IS NOT NULL AND NEW.quoted_ea IS NOT NULL AND NEW.live_price_ea > NEW.quoted_ea THEN
      r := r || 'price_rose'::text;
    END IF;
    IF NEW.live_pulled_at IS NULL OR NEW.captured_at - NEW.live_pulled_at > make_interval(secs => c.max_read_age_s) THEN
      r := r || 'stale_live_read'::text;
    END IF;
    IF i.alert_at IS NULL OR v_confirm - now() < make_interval(secs => c.min_confirm_window_s) THEN
      r := r || 'not_enough_time_for_market'::text;
    END IF;
    IF c.project_stopped THEN
      r := r || 'stopped_pending_review'::text;
    ELSIF v_sub IS NOT NULL AND v_proj + v_sub > c.project_cap_usd THEN
      -- Stop only when the cap is what blocks a buy that would otherwise go through; a sub
      -- already blocked by another guard (e.g. a $1,800 one over the order cap) must not freeze buying.
      IF cardinality(r) = 0 THEN
        UPDATE public.n2s_autobuy_config SET project_stopped = true, project_stopped_at = now(), updated_at = now(),
               project_stopped_reason = format('dryrun %s: $%s would take project spend from $%s past the $%s cap',
                                           NEW.dryrun_id, v_sub, v_proj, c.project_cap_usd)
         WHERE id;
      END IF;
      r := r || 'over_project_cap'::text;
    END IF;
    v_state := CASE WHEN cardinality(r) > 0 THEN 'blocked'
                    WHEN v_sub > c.approval_over_usd THEN 'awaiting_approval'
                    WHEN c.mode = 'live' THEN 'live_buy'
                    ELSE 'shadow_buy' END;
  END IF;

  INSERT INTO public.n2s_autobuy_exec
         (n2s_id, dryrun_id, mode, state, reasons, sell_market, order_number, sub_source, sub_listing_id,
          tevo_event_id, event_name, event_dt_local, qty, sub_total_usd, sold_total_usd, margin_usd, alert_at,
          cutoff_s, cutoff_source, sub_confirm_by, sale_deadline, spend_today_before, project_spent_before)
  VALUES (NEW.n2s_id, NEW.dryrun_id, c.mode, v_state, r, v_market, NEW.order_number, NEW.sub_source,
          NEW.sub_listing_id, NEW.tevo_event_id, NEW.event_name, i.event_dt, v_qty, v_sub, v_sold,
          v_sold - v_sub, i.alert_at, v_cut, v_cut_src, v_confirm,
          i.alert_at + make_interval(secs => v_cut), v_spend, v_proj)
  ON CONFLICT DO NOTHING;
  -- reaching the project cap exactly also stops buying until the operator reviews
  IF v_state IN ('shadow_buy', 'live_buy', 'awaiting_approval')
     AND v_proj + v_sub >= c.project_cap_usd THEN
    UPDATE public.n2s_autobuy_config SET project_stopped = true, project_stopped_at = now(), updated_at = now(),
           project_stopped_reason = format('Project spend reached $%s of the $%s cap (dryrun %s)',
                                       v_proj + v_sub, c.project_cap_usd, NEW.dryrun_id)
     WHERE id;
  END IF;
  RETURN NULL;
EXCEPTION WHEN OTHERS THEN
  RAISE WARNING 'n2s_autobuy_enqueue_trg: % (dryrun %)', SQLERRM, NEW.dryrun_id;  -- never break the dry run
  RETURN NULL;
END $function$;

REVOKE ALL ON FUNCTION public.n2s_autobuy_enqueue_trg() FROM PUBLIC, anon, authenticated;

ALTER TABLE public.n2s_autobuy_config DROP CONSTRAINT IF EXISTS n2s_autobuy_config_live_sell_markets_check;
ALTER TABLE public.n2s_autobuy_config ADD CONSTRAINT n2s_autobuy_config_live_sell_markets_check
  CHECK (live_sell_markets <@ ARRAY['evo', 'gotickets', 'seatgeek', 'vivid', 'tickpick']);
UPDATE public.n2s_autobuy_config
   SET live_sell_markets = ARRAY['evo', 'gotickets', 'seatgeek', 'vivid', 'tickpick'], updated_at = now()
 WHERE id;

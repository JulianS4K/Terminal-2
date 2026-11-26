-- Migration 20261126013000 · level:data-collection · lane:a1 (box-office poll ingest) · writes:primary_poll_event(+failed_reads),primary_poll_config(+purge_after_failures),primary_poll_ingest()(replaced) · reads:primary_poll_listing
--
-- ============================================================================
-- Migration 20261126013000 — a failed read leaves the capture alone; two in a
--   row discard it
--
-- Lane:     a1 (box-office poll ingest)
-- Touches:  primary_poll_event (+failed_reads), primary_poll_config
--           (+purge_after_failures), primary_poll_ingest() (REPLACED).
-- pre:      none hard; built on the form live since mig 20261124230030.
--
-- READ-ONLY UPSTREAM (RULE 2): nothing here calls a market.
--
-- ── WHAT THE OPERATOR SET ─────────────────────────────────────────────────
-- Operator 2026-11-26: "no destroy inventory if 2 reads fail back to back".
-- So: one failed read keeps the last good capture; the second consecutive
-- failure discards it. The threshold is primary_poll_config.purge_after_failures
-- (2), so it can be tuned without touching this function — set it to 1 for the
-- old behaviour, or to a large number to keep a capture through any outage.
--
-- ── THE BUG THIS FIXES, AND WHAT IT COST TONIGHT ──────────────────────────
-- primary_poll_ingest deleted an event's stored listings UNCONDITIONALLY, before
-- the `IF v_ok THEN` branch decided whether there was anything to put back, and
-- then set listing_count = 0 on failure. A failed read therefore did not leave
-- inventory stale — it destroyed the last known good capture.
--
-- That is survivable while an upstream is either up or down. It is pathological
-- while one is INTERMITTENT, because it ratchets: a good read restores an event,
-- the next bad read wipes it, and the store walks toward zero instead of toward
-- stale. Measured on prod tonight while AXS was flapping at a 33-67% failure
-- rate: primary_poll_listing for axs fell 46,030 -> 16,079 rows in 32 minutes
-- (-65%), events with listings 84 -> 32, and the push-out 86 -> 32 events.
--
-- Nothing was gained by the delete. v_primary_poll_listings_feed is the only
-- reader of primary_poll_listing (checked: one view, and routers/primary_poll_feed.py
-- reads only that view), and it already requires poll_status = 'ok', so a failed
-- event's listings are never served whether they are kept or not. Keeping them
-- cannot leak stale inventory to a consumer; it only stops the store collapsing.
--
-- ── WHY TWO AND NOT NEVER ─────────────────────────────────────────────────
-- The vendor (TicketsData) states that AXS "might be suddenly down and then up"
-- inside a 24-hour window and that they pass its errors through unchanged. A
-- single failure is therefore usually a blip and the capture is still the best
-- picture we have. Two consecutive failures spans at least one full cadence
-- interval (30-90 minutes under axs_watch_cadence), by which point the stored
-- seats are no longer a reasonable claim about what is on sale, so they go.
--
-- ── HOW THE COUNT WORKS ───────────────────────────────────────────────────
-- primary_poll_event.failed_reads counts CONSECUTIVE failed reads and is reset to
-- 0 by any successful one. The purge fires when failed_reads reaches
-- purge_after_failures. listing_count is only zeroed when the rows are actually
-- removed, so the column and the table stay consistent — a monitor counting
-- listing_count > 0 is counting events that really do hold a capture.
-- ============================================================================

BEGIN;

ALTER TABLE public.primary_poll_event
  ADD COLUMN IF NOT EXISTS failed_reads integer NOT NULL DEFAULT 0;
COMMENT ON COLUMN public.primary_poll_event.failed_reads IS
  'Consecutive failed reads; reset to 0 by any successful read. At primary_poll_config.purge_after_failures the stored listings are discarded (mig 20261126013000).';

ALTER TABLE public.primary_poll_config
  ADD COLUMN IF NOT EXISTS purge_after_failures integer NOT NULL DEFAULT 2
    CHECK (purge_after_failures >= 1);
COMMENT ON COLUMN public.primary_poll_config.purge_after_failures IS
  'How many consecutive failed reads discard an event''s stored listings (mig 20261126013000, operator "no destroy inventory if 2 reads fail back to back"). 1 = discard on the first failure (the old behaviour); a large value keeps a capture through any outage.';

CREATE OR REPLACE FUNCTION public.primary_poll_ingest(p_source text, p_events jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  e jsonb; v_id text; v_ok boolean; v_n integer; v_median numeric; v_qty integer; v_every interval;
  v_events integer := 0; v_ok_n integer := 0; v_failed integer := 0; v_listings integer := 0;
  v_fails integer; v_purge_at integer; v_purged integer := 0; v_kept integer := 0;
BEGIN
  IF coalesce(p_source, '') = '' OR jsonb_typeof(p_events) IS DISTINCT FROM 'array' THEN
    RAISE EXCEPTION 'primary_poll_ingest: a source and an array of events are required';
  END IF;
  SELECT c.purge_after_failures INTO v_purge_at FROM public.primary_poll_config c;
  v_purge_at := coalesce(v_purge_at, 2);
  FOR e IN SELECT x FROM jsonb_array_elements(p_events) x LOOP
    v_id := e->>'id';
    CONTINUE WHEN coalesce(v_id, '') = '' OR coalesce(e->>'name', '') = '';
    v_ok := coalesce((e->>'ok')::boolean, false);
    INSERT INTO public.primary_poll_event AS t (source, source_event_id, name, event_date, start_local_time, start_utc,
        timezone, venue_name, venue_city, venue_state, ticket_url, offer_id, order_min, order_max, total_available,
        price_min, price_max, poll_attempt_at)
    VALUES (p_source, v_id, e->>'name',
        CASE WHEN e->>'local_date' ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' THEN (e->>'local_date')::date END,
        CASE WHEN e->>'local_time' ~ '^[0-9]{2}:[0-9]{2}' THEN (e->>'local_time')::time END,
        nullif(e->>'start_utc', '')::timestamptz, e->>'timezone', e->>'venue', e->>'city', e->>'state', e->>'url',
        e->>'offer_id', (e->>'order_min')::integer, (e->>'order_max')::integer, (e->>'total_available')::integer,
        (e->>'price_min')::numeric, (e->>'price_max')::numeric, now())
    ON CONFLICT (source, source_event_id) DO UPDATE SET
        name = EXCLUDED.name, event_date = EXCLUDED.event_date, start_local_time = EXCLUDED.start_local_time,
        start_utc = EXCLUDED.start_utc, timezone = EXCLUDED.timezone, venue_name = EXCLUDED.venue_name,
        venue_city = EXCLUDED.venue_city, venue_state = EXCLUDED.venue_state, ticket_url = EXCLUDED.ticket_url,
        offer_id = EXCLUDED.offer_id, order_min = EXCLUDED.order_min, order_max = EXCLUDED.order_max,
        total_available = EXCLUDED.total_available, price_min = EXCLUDED.price_min, price_max = EXCLUDED.price_max,
        last_seen_at = now(), poll_attempt_at = now();
    v_events := v_events + 1;
    IF v_ok THEN
      -- a good read replaces the capture wholesale, so the old rows go here and NOT before this branch
      -- (mig 20261126013000: that unconditional delete is what let a failed read destroy the capture)
      DELETE FROM public.primary_poll_listing l WHERE l.source = p_source AND l.source_event_id = v_id;
      INSERT INTO public.primary_poll_listing (source, source_event_id, listing_id, market, section, seat_row, seat_low,
          seat_high, seats, quantity, allowed_quantities, max_per_order, price, fee, all_in_price, price_includes_tax,
          area, ticket_type, delivery, ada, obstructed, aisle, general_admission, tax, order_fee, price_estimated)
      SELECT DISTINCT ON (l->>'id') p_source, v_id, l->>'id', l->>'market', l->>'section', l->>'row', l->>'seat_low',
             l->>'seat_high', CASE WHEN jsonb_typeof(l->'seats') = 'array' THEN l->'seats' END, (l->>'qty')::integer,
             CASE WHEN jsonb_typeof(l->'allowed_quantities') = 'array' THEN l->'allowed_quantities' END,
             (l->>'max_per_order')::integer, (l->>'price')::numeric, (l->>'fee')::numeric, (l->>'all_in')::numeric,
             (l->>'price_includes_tax')::boolean, l->>'area', l->>'ticket_type', l->>'delivery', (l->>'ada')::boolean,
             coalesce((l->>'obstructed')::boolean, false), (l->>'aisle')::boolean, (l->>'ga')::boolean,
             (l->>'tax')::numeric, (l->>'order_fee')::numeric, coalesce((l->>'price_estimated')::boolean, false)
        FROM jsonb_array_elements(coalesce(e->'listings', '[]'::jsonb)) l
       WHERE coalesce(l->>'id', '') <> ''
       ORDER BY l->>'id';
      -- over the listings that are sent: the median of what a buyer pays for a ticket, and the tickets listed.
      -- With the date they set the cadence. No listings is a quantity of 0; listings that carry no quantity
      -- leave it unknown (null), which moves nothing.
      SELECT count(*), round((percentile_cont(0.5) WITHIN GROUP (ORDER BY coalesce(l.all_in_price, l.price)))::numeric, 2),
             CASE WHEN count(*) = 0 THEN 0 ELSE sum(l.quantity)::integer END
        INTO v_n, v_median, v_qty
        FROM public.primary_poll_listing l
       WHERE l.source = p_source AND l.source_event_id = v_id AND NOT l.obstructed;
      SELECT public.primary_poll_interval(t.event_date, v_median, v_qty) INTO v_every
        FROM public.primary_poll_event t WHERE t.source = p_source AND t.source_event_id = v_id;
      UPDATE public.primary_poll_event t
         SET poll_status = 'ok', poll_ok_at = now(), poll_error = NULL, listing_count = v_n, median_price = v_median,
             listed_quantity = v_qty, poll_interval = v_every, failed_reads = 0,
             next_poll_at = public.primary_poll_next(v_every, t.next_poll_at)
       WHERE t.source = p_source AND t.source_event_id = v_id;
      -- a listing over its order limit gets its pieces, which the feed sends in its place (mig 20261124230030).
      -- Like the history below, it never costs the feed a read: if it fails, the listings go out unsplit.
      BEGIN
        PERFORM public.primary_poll_split_event(p_source, v_id);
      EXCEPTION WHEN OTHERS THEN
        RAISE WARNING 'primary_poll_split_event(%, %) failed: %', p_source, v_id, SQLERRM;
      END;
      -- the book as read, its figures and the day's row are kept (mig 20261124203030). The history never costs
      -- the feed a read: if keeping it fails, the read stands and the failure is a warning in the database log.
      BEGIN
        PERFORM public.primary_poll_keep_history(p_source, v_id);
      EXCEPTION WHEN OTHERS THEN
        RAISE WARNING 'primary_poll_keep_history(%, %) failed: %', p_source, v_id, SQLERRM;
      END;
      v_ok_n := v_ok_n + 1; v_listings := v_listings + v_n;
    ELSE
      -- a failed poll is tried again at the event's own cadence, in a window no longer than retry_after
      SELECT least(public.primary_poll_interval(t.event_date, t.median_price, t.listed_quantity),
                   (SELECT c.retry_after FROM public.primary_poll_config c)),
             t.failed_reads + 1
        INTO v_every, v_fails
        FROM public.primary_poll_event t WHERE t.source = p_source AND t.source_event_id = v_id;
      v_fails := coalesce(v_fails, 1);
      -- THE CAPTURE SURVIVES ONE FAILURE. At purge_after_failures consecutive failures it is no longer a
      -- reasonable claim about what is on sale, so it goes. The feed never served it either way: it requires
      -- poll_status = 'ok' (mig 20261126013000).
      IF v_fails >= v_purge_at THEN
        DELETE FROM public.primary_poll_listing l WHERE l.source = p_source AND l.source_event_id = v_id;
        v_purged := v_purged + 1;
      ELSE
        v_kept := v_kept + 1;
      END IF;
      UPDATE public.primary_poll_event t
         SET poll_status = 'failed', poll_error = left(coalesce(e->>'error', 'poll failed'), 300),
             listing_count = CASE WHEN v_fails >= v_purge_at THEN 0 ELSE t.listing_count END,
             failed_reads = v_fails,
             poll_interval = v_every, next_poll_at = public.primary_poll_next(v_every, t.next_poll_at)
       WHERE t.source = p_source AND t.source_event_id = v_id;
      v_failed := v_failed + 1;
    END IF;
  END LOOP;
  RETURN jsonb_strip_nulls(jsonb_build_object('events', v_events, 'ok', v_ok_n, 'failed', v_failed,
           'listings', v_listings, 'capture_kept', nullif(v_kept, 0), 'capture_purged', nullif(v_purged, 0)));
END $function$;

COMMIT;

-- Migration 20261124043030 · level:secondary-sales · lane:D0 · writes:sub_finder_health()(replaced) · reads:primary_poll_source,primary_poll_event,v_primary_poll_events_feed (where they exist) · pre:20261116210000,20261124041030
--
-- THE HEALTH CHECK ALSO SAYS HOW THE BOX OFFICES WE READ ARE DOING.
-- Operator 2026-11-24: "add health of both sources to the api out health section".
--
-- GET /api/v1/subs/health gains one check a box office that has ever been read: today
--   box_office_sitickets     SI Tickets at Sports Illustrated Stadium
--   box_office_timberwolves  the Timberwolves' own ticket site
-- and one more by itself the day another team's site lists games (the Lynx, the six other team sites).
--
--   ok        the reader closed a pull in the last 25 minutes (it wakes every 10) and every event it can
--             read is being sent
--   degraded  the last pull is older than that, or some events that used to be readable could not be read at
--             their last try (their listings are not being sent)
--   down      no pull for an hour, or no event of the box office can be read at all: a site that refuses us
--             shows here
--   off       the box office has no event on sale (a team out of season). Off never lowers the overall status
--
-- It carries events (not yet started), events_with_listings, events_failing and events_never_readable (a series
-- or a package with no listing page: SI Tickets has two). Like every check it counts in the overall status.
--
-- The box-office tables ship in 20261123171030 and later, which may not be present where this is built (the
-- sub finder's scenario tests), so the check is reached through to_regclass and EXECUTE, as the MLB one is.
-- Everything else in the function is as 20261116210000 left it. It still names no table of ours in its answer.
--
-- rollback: re-apply public.sub_finder_health(bigint) from 20261116210000.

CREATE OR REPLACE FUNCTION public.sub_finder_health(p_key_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  a        jsonb := public.sub_finder_access(p_key_id);
  c        public.sub_finder_config%ROWTYPE;
  m        public.manual_sub_buy_config%ROWTYPE;
  v_now    timestamptz := now();
  v_checks jsonb := '[]'::jsonb;
  v_at     timestamptz;
  v_age    numeric;
  v_st     text;
  v_n      bigint;
  v_n2     bigint;
  v_old    numeric;
  v_http   integer;
  v_ms     integer;
  v_items  integer;
  v_live   boolean;
  v_box    record;
BEGIN
  IF NOT coalesce((a->>'find')::boolean, false) THEN
    RETURN jsonb_build_object('error', 'forbidden', 'detail', 'the sub finder is not enabled for this key');
  END IF;
  SELECT * INTO c FROM public.sub_finder_config;
  SELECT * INTO m FROM public.manual_sub_buy_config;

  -- 1. our reader of the CRM's Need-to-Sub feed: the last read that came back whole
  SELECT max(l.fetched_at) FILTER (WHERE l.status = 200 AND l.error IS NULL),
         (array_agg(l.status ORDER BY l.id DESC))[1],
         (array_agg(l.ms ORDER BY l.id DESC) FILTER (WHERE l.status = 200 AND l.error IS NULL))[1],
         (array_agg(l.items ORDER BY l.id DESC) FILTER (WHERE l.status = 200 AND l.error IS NULL))[1]
    INTO v_at, v_http, v_ms, v_items
    FROM (SELECT * FROM public.n2s_crm_direct_log ORDER BY id DESC LIMIT 200) l;
  v_age := round(extract(epoch FROM v_now - v_at));
  v_checks := v_checks || jsonb_build_object(
    'name', 'crm_feed', 'what', 'S4K reading your Need-to-Sub feed (GET /n2s/items on the CRM)',
    'status', public.sub_finder_health_grade(v_age, 300, 1200),
    'last_at', v_at, 'age_seconds', v_age, 'ok_within_seconds', 300, 'down_after_seconds', 1200,
    -- your API's answer to our most recent try (null = no answer), and how the last good read went
    'last_attempt_http', v_http, 'last_read_took_ms', v_ms, 'last_read_items', v_items);

  -- 2. our copy of the CRM's order book, which an order is checked against before a buy
  SELECT max(o.last_seen_at) INTO v_at FROM public.s4kcs_orders o;
  v_age := round(extract(epoch FROM v_now - v_at));
  v_checks := v_checks || jsonb_build_object(
    'name', 'order_book', 'what', 'S4K''s copy of your order book, which an order is checked against before a buy',
    'status', public.sub_finder_health_grade(v_age, 1800, 7200),
    'last_at', v_at, 'age_seconds', v_age, 'ok_within_seconds', 1800, 'down_after_seconds', 7200);

  -- 3. this caller's lookups: nothing stuck unanswered, and the watched orders still being re-checked
  SELECT count(*), round(extract(epoch FROM v_now - min(j.created_at)))
    INTO v_n, v_old
    FROM public.sub_finder_job j WHERE j.key_id = p_key_id AND j.status <> 'done';
  SELECT count(*), max(o.refreshed_at) INTO v_n2, v_at
    FROM public.sub_finder_order o WHERE o.key_id = p_key_id AND o.watching;
  v_age := round(extract(epoch FROM v_now - v_at));
  v_st := CASE WHEN v_old > 3600 THEN 'down'
               WHEN v_old > 900 THEN 'degraded'
               WHEN v_n2 > 0 THEN public.sub_finder_health_grade(v_age, 600, 3600)
               ELSE 'ok' END;
  v_checks := v_checks || jsonb_build_object(
    'name', 'lookups', 'what', 'your sub lookups: answering new ones and re-checking the orders still open',
    'status', v_st,
    'last_at', v_at, 'age_seconds', v_age, 'ok_within_seconds', 600, 'down_after_seconds', 3600,
    'lookups_unanswered', v_n, 'oldest_unanswered_seconds', v_old, 'orders_watched', v_n2);

  -- 4. buys the CRM asks for. One buy at a time; a buy left unfinished or of unknown outcome
  --    stops all buying until S4K has checked it, which is what "down" means here.
  SELECT count(*) FILTER (WHERE b.state = 'requested'),
         round(extract(epoch FROM v_now - min(b.created_at) FILTER (WHERE b.state = 'requested'))),
         count(*) FILTER (WHERE b.state = 'unknown')
    INTO v_n, v_old, v_n2
    FROM public.manual_sub_buy b WHERE b.state IN ('requested', 'buying', 'unknown');
  v_st := CASE WHEN NOT coalesce((a->>'buy')::boolean, false) OR NOT coalesce(m.enabled, false) THEN 'off'
               WHEN coalesce(m.kill_switch, false) OR v_n2 > 0 THEN 'down'
               WHEN v_old > 3600 THEN 'down'
               WHEN v_old > 600 THEN 'degraded'
               ELSE 'ok' END;
  v_checks := v_checks || jsonb_build_object(
    'name', 'buying', 'what', 'buys you ask for (POST .../buy)',
    'status', v_st,
    'detail', CASE WHEN v_st = 'off' THEN 'buying is switched off at S4K'
                   WHEN coalesce(m.kill_switch, false) OR v_n2 > 0
                   THEN 'buying is stopped until S4K has checked a buy that did not finish cleanly'
                   WHEN v_st <> 'ok' THEN 'a buy has been waiting longer than it should' END,
    'buys_waiting', v_n, 'oldest_waiting_seconds', v_old, 'buys_to_check', v_n2,
    'automatic_buying', CASE WHEN coalesce(c.auto_buy_enabled, false) THEN 'on' ELSE 'off' END,
    'ok_within_seconds', 600, 'down_after_seconds', 3600);

  -- 5. GoTickets offers
  SELECT count(*), round(extract(epoch FROM v_now - min(g.created_at)))
    INTO v_n, v_old
    FROM public.sub_finder_gt_offer g WHERE g.state IN ('requested', 'sending');
  SELECT count(*) INTO v_n2 FROM public.sub_finder_gt_offer g WHERE g.state = 'unknown' AND g.live;
  v_st := CASE WHEN NOT coalesce((a->>'offer')::boolean, false) THEN 'off'
               WHEN v_old > 3600 THEN 'down'
               WHEN v_old > 600 OR v_n2 > 0 THEN 'degraded'
               ELSE 'ok' END;
  v_checks := v_checks || jsonb_build_object(
    'name', 'offers', 'what', 'offers of replacement seats to GoTickets customers (POST .../offer-sub)',
    'status', v_st,
    'detail', CASE WHEN v_st = 'off' THEN 'offers are switched off at S4K'
                   WHEN v_n2 > 0 THEN 'an offer was sent and its outcome is not known yet'
                   WHEN v_st <> 'ok' THEN 'an offer has been waiting longer than it should' END,
    'offers_waiting', v_n, 'oldest_waiting_seconds', v_old, 'offers_to_check', v_n2,
    'buy_after_accept', CASE WHEN coalesce(c.gt_offer_auto_buy, false) THEN 'on' ELSE 'off' END,
    'ok_within_seconds', 600, 'down_after_seconds', 3600);

  -- 6. the hourly read of the EVO balances and GoTickets gift cards (GET /balances)
  SELECT max(r.taken_at) INTO v_at
    FROM (SELECT * FROM public.account_balance_run ORDER BY run_id DESC LIMIT 50) r WHERE r.error IS NULL;
  v_age := round(extract(epoch FROM v_now - v_at));
  v_checks := v_checks || jsonb_build_object(
    'name', 'balances', 'what', 'the hourly read of S4K''s EVO balances and GoTickets gift cards (GET /balances)',
    'status', public.sub_finder_health_grade(v_age, 7200, 21600),
    'last_at', v_at, 'age_seconds', v_age, 'ok_within_seconds', 7200, 'down_after_seconds', 21600);

  -- 7. the MLB schedule feed, where it is installed. Clubs are re-read in turn, so the newest
  --    good read is recent whenever the reader is alive; "off" until the feed itself is served.
  IF to_regclass('public.mlb_ticket_sync') IS NOT NULL THEN
    EXECUTE $q$SELECT max(s.last_ok_at),
                      count(*) FILTER (WHERE s.last_error_at > coalesce(s.last_ok_at, '-infinity')
                                         AND s.last_error_at > now() - interval '1 day')
                 FROM public.mlb_ticket_sync s$q$
      INTO v_at, v_n;
    v_live := to_regclass('public.v_mlb_schedule_feed') IS NOT NULL;
    v_age := round(extract(epoch FROM v_now - v_at));
    v_checks := v_checks || jsonb_build_object(
      'name', 'mlb_schedule', 'what', 'the MLB schedule with ticket links (GET /mlb/schedule)',
      'status', CASE WHEN NOT v_live THEN 'off' ELSE public.sub_finder_health_grade(v_age, 93600, 259200) END,
      'detail', CASE WHEN NOT v_live THEN 'the schedule is being collected and is not served yet' END,
      'last_at', v_at, 'age_seconds', v_age, 'ok_within_seconds', 93600, 'down_after_seconds', 259200,
      'clubs_failing', v_n);
  END IF;

  -- 8. the box offices we read ourselves (GET /primary/events, /primary/listings), where they are
  --    installed: one check a box office that has ever been read. A worker closes a pull at every wake
  --    (10 minutes), so the age of the last one says whether the reader is alive; the events say whether
  --    the site still answers. A box office with nothing on sale is off.
  IF to_regclass('public.primary_poll_source') IS NOT NULL AND to_regclass('public.v_primary_poll_events_feed') IS NOT NULL THEN
    FOR v_box IN EXECUTE $q$
      SELECT s.source, s.finished_at,
             count(v.event_id) FILTER (WHERE v.listings_withheld IS DISTINCT FROM 'event_started') AS events,
             count(v.event_id) FILTER (WHERE v.listings_available) AS served,
             count(v.event_id) FILTER (WHERE v.listings_withheld IN ('poll_failed', 'poll_stale', 'not_polled')
                                         AND e.poll_ok_at IS NOT NULL) AS failing,
             count(v.event_id) FILTER (WHERE v.listings_withheld IN ('poll_failed', 'poll_stale', 'not_polled')
                                         AND e.poll_ok_at IS NULL) AS unreadable
        FROM public.primary_poll_source s
        LEFT JOIN public.v_primary_poll_events_feed v ON v.source = s.source
        LEFT JOIN public.primary_poll_event e ON e.source = v.source AND e.source_event_id = v.event_id
       GROUP BY s.source, s.finished_at
       ORDER BY s.source$q$
    LOOP
      v_age := round(extract(epoch FROM v_now - v_box.finished_at));
      v_st := CASE WHEN v_box.events = 0 THEN 'off'
                   WHEN v_box.served = 0 THEN 'down'
                   WHEN public.sub_finder_health_grade(v_age, 1500, 3600) <> 'ok' THEN public.sub_finder_health_grade(v_age, 1500, 3600)
                   WHEN v_box.failing > 0 THEN 'degraded'
                   ELSE 'ok' END;
      v_checks := v_checks || jsonb_build_object(
        'name', 'box_office_' || v_box.source,
        'what', 'the ' || v_box.source || ' box office, read by S4K (GET /primary/events and /primary/listings, source=' || v_box.source || ')',
        'status', v_st,
        'detail', CASE WHEN v_st = 'off' THEN 'this box office has no event on sale'
                       WHEN v_box.served = 0 THEN 'no event of this box office could be read: no listings are being sent'
                       WHEN v_st = 'degraded' AND v_box.failing > 0 THEN 'some events could not be read at their last try: their listings are not being sent'
                       WHEN v_st <> 'ok' THEN 'the box office has not been read lately' END,
        'last_at', v_box.finished_at, 'age_seconds', v_age, 'ok_within_seconds', 1500, 'down_after_seconds', 3600,
        -- events not yet started; the ones whose listings are being sent; the ones that stopped being
        -- readable; the ones that never were (a series or a package with no listing page)
        'events', v_box.events, 'events_with_listings', v_box.served, 'events_failing', v_box.failing,
        'events_never_readable', v_box.unreadable);
    END LOOP;
  END IF;

  RETURN jsonb_build_object(
    -- the worst of the checks that are not switched off
    'status', (SELECT CASE WHEN bool_or(e->>'status' = 'down') THEN 'down'
                           WHEN bool_or(e->>'status' = 'degraded') THEN 'degraded'
                           ELSE 'ok' END
                 FROM jsonb_array_elements(v_checks) e),
    'statuses', jsonb_build_object(
      'ok', 'working, and its last good run is recent',
      'degraded', 'working late, or something is waiting on S4K',
      'down', 'not working: its last good run is older than down_after_seconds, or it is stopped',
      'off', 'switched off at S4K on purpose; it does not lower the overall status'),
    'checks', (SELECT jsonb_agg(jsonb_strip_nulls(e) ORDER BY o) FROM jsonb_array_elements(v_checks) WITH ORDINALITY x(e, o)),
    'checked_at', v_now);
END
$function$;

REVOKE ALL ON FUNCTION public.sub_finder_health(bigint) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.sub_finder_health(bigint) TO service_role;

NOTIFY pgrst, 'reload schema';

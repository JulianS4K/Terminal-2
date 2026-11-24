-- Migration 20261124190000 · level:data-collection · lane:A1 (data plane; routed to this session by the operator) + D0 (the primary feed gains a source) · writes:axs_watch_config(new),axs_watch_venue(new),axs_watch_poll(new),axs_watch_audit(new),axs_watch_rule_ok()(new),axs_watch_fill()(new),axs_watch_parse()(new),axs_watch_budget()(new),axs_watch_tick()(new),primary_poll_event(rows, source 'axs'),primary_poll_listing(rows),ticketsdata_credit_usage(rows via td_charge_credit),cron jobs axs_watch_tick_1m + axs_watch_fill_daily(new) · reads:axs_export_event,net._http_response,primary_poll_config,primary_poll_cadence · pre:20261123194030 (cadence), 20261103090000 (AXS export), 20260630160000 (td_charge_credit)
--
-- AXS WATCH: 200 AXS-SOLD EVENTS READ THROUGH TICKETSDATA ON THE BOX-OFFICE CADENCE, WITHIN THE CREDIT POOL.
-- Operator 2026-11-24: "make an axs one that allows for 200 events to run on axs and use up to 250k credits",
-- after "give me a list of 100 upcoming events from the venues ... where axs is primary", "add the next 100",
-- "for sports remove anything not major league", "assuming we auto fill this list as events pass how would we
-- do it, also how do we poll these events in cascade so we dont stress system under the timbervolws cadance".
--
-- WHAT IT IS. The Timberwolves poller reads a team's own site in a browser at no cost (core/primary_poll_browser.py).
-- AXS pages are bot-guarded, so AXS events are read through TicketsData's `/fetch?platform=axs`, which runs a
-- browser on their side: one credit and about 40 seconds a read (5,753 reads June–November: median 40 s, p90 55 s,
-- p99 84 s). This migration adds a second kind of poller for the same feed, driven from the database:
--
--   axs_watch_venue   the venues watched and how many of their events each may hold (the quota). Seeded with the
--                     ten venues of the operator's list and today's split (55 Crypto.com Arena, 40 Toyota Center,
--                     35 T-Mobile Arena, 25 Red Rocks, 14 RodeoHouston, 10 PeoplesBank Arena, 7 MGM Grand Garden,
--                     6 Target Center, 6 Greek Theatre, 2 Soldier Field = 200).
--   axs_watch_fill()  nightly (and on apply): retires watched events that have passed, left AXS or stopped being
--                     AXS-sold, then refills each venue to its quota from the AXS export (axs_export_event), soonest
--                     first: live, upcoming, AXS-sold (`axs_ticketed`: AXS itself or an AXS-powered team shop such as
--                     the Rockets' `nba` ticketer), with a page URL, and passing the rules: never a parking, suite,
--                     package, pass, season, membership or deposit entry, never the Timberwolves or Lynx (the browser
--                     worker reads those), and a sports event only when it names a major-league team
--                     (axs_watch_config.sports_keep_regex). The watched events are rows of primary_poll_event with
--                     source 'axs', so GET /primary/events and /primary/listings serve them like the other box offices
--                     (routers/primary_poll_feed.py). The EVO event comes from the export's own match
--                     (tevo_match_method 'axs_export'); the box-office mapper (primary_poll_map) and the spine (event_xmap_tick)
--                     do not read this source — both join venue_primary_box_office, which has no 'axs' row; AXS is in the spine
--                     through the export — and the events are not announced to the mapper.
--   axs_watch_tick()  every minute, the cascade:
--                       1. settles the responses that have landed: the body is read into listings (axs_watch_parse),
--                          the event goes through primary_poll_ingest() like a Timberwolves read — ok with its
--                          listings, or failed with the reason, which deletes them — and the credit is logged
--                          (td_charge_credit, platform 'AXS'); a request with no response after stale_after is a
--                          failed poll;
--                       2. fires the events that are due (primary_poll_due: the shared cadence ladder — 10 minutes on
--                          the day, 30 minutes within two days, otherwise an hour, moved by price and quantity, each
--                          at a random slot — mig 20261123194030), most overdue first, never more than max_in_flight
--                          requests at once (4: at 40 s a read that is about 350 reads an hour, twice what 200 events
--                          need on an ordinary day), and never more than the day's share of the credit pool.
--   The budget (axs_watch_budget): the pool is read from TicketsData's own `quota_remaining` on the last response
--   (the real counter; it reset to 249,999 on 2026-11-18); the day's cap is (pool − reserve_credits) ÷ days until the
--   next reset (cycle_reset_day), or daily_cap_override when the operator pins one. Over the cap only the events on a hot cadence (hot_every, 30 minutes or faster) are
--   still read, and only up to hot_overrun_pct more. A bad day cannot empty the month, and the month cannot exceed
--   the pool: 250,000 is the ceiling (monthly_credits), what is spent is what 200 events need — about 4,000 to 5,500
--   reads a day, 120k–165k a month. More events (raise a quota, add a venue) is what spends more.
--   Upstream trouble slows the cascade by itself: three of the last ten settled reads failing upstream (5xx, timeout,
--   lost) holds the drainer to one request in flight until they clear.
--
-- Read-only towards AXS and TicketsData (RULE 2): `net.http_get` only, the credentials read inside SQL from the
-- vault (get_app_secret), never returned or stored; no listing, price or inventory can be influenced. The AXS
-- snapshot tables of the paused 2026 collector (axs_event_snapshots and so on, 8.9 GB of raw bodies) are not
-- written: a read keeps its listings only, replaced on the next read, as the other box offices do.
--
-- To pause: UPDATE public.axs_watch_config SET enabled = false;   to change the mix: axs_watch_venue, then
-- SELECT public.axs_watch_fill();   to see the budget: SELECT public.axs_watch_budget();
--
-- rollback: SELECT cron.unschedule('axs_watch_tick_1m'); SELECT cron.unschedule('axs_watch_fill_daily');
--           DELETE FROM public.primary_poll_event WHERE source = 'axs';
--           DROP FUNCTION public.axs_watch_tick(), public.axs_watch_budget(), public.axs_watch_parse(jsonb),
--                         public.axs_watch_fill(boolean), public.axs_watch_rule_ok(text, text);
--           DROP TABLE public.axs_watch_poll, public.axs_watch_audit, public.axs_watch_venue, public.axs_watch_config.

CREATE TABLE IF NOT EXISTS public.axs_watch_config (
  id                   boolean PRIMARY KEY DEFAULT true CHECK (id),       -- one row
  enabled              boolean NOT NULL DEFAULT true,
  target_events        integer NOT NULL DEFAULT 200 CHECK (target_events >= 0),       -- the list's size; venue quotas fill it
  monthly_credits      integer NOT NULL DEFAULT 250000 CHECK (monthly_credits > 0),   -- the TicketsData pool: the ceiling
  reserve_credits      integer NOT NULL DEFAULT 5000 CHECK (reserve_credits >= 0),    -- kept for the export sync and manual reads
  cycle_reset_day      smallint NOT NULL DEFAULT 18 CHECK (cycle_reset_day BETWEEN 1 AND 28),   -- the pool refilled on 2026-11-18
  max_in_flight        smallint NOT NULL DEFAULT 4 CHECK (max_in_flight BETWEEN 1 AND 20),
  fire_timeout_ms      integer NOT NULL DEFAULT 100000 CHECK (fire_timeout_ms BETWEEN 10000 AND 300000),
  stale_after          interval NOT NULL DEFAULT interval '12 minutes',  -- a request with no response by then is a failed poll
  daily_cap_override   integer CHECK (daily_cap_override >= 0),         -- set: the day's cap is this, not the pool's share
  hot_every            interval NOT NULL DEFAULT interval '30 minutes',  -- over the daily cap, only events read this often or faster
  hot_overrun_pct      smallint NOT NULL DEFAULT 10 CHECK (hot_overrun_pct BETWEEN 0 AND 100),
  upstream_errors_max  smallint NOT NULL DEFAULT 3 CHECK (upstream_errors_max >= 1),  -- of the last ten settled reads: then one in flight
  far_out_days         integer CHECK (far_out_days > 0),                 -- optional slower rung: events further out than this ...
  far_out_every        interval CHECK (far_out_every >= interval '1 hour'),   -- ... are read this often instead of the ladder's hour
  sports_keep_regex    text NOT NULL DEFAULT '(lakers|clippers|\mla kings\M|los angeles kings|sparks|rockets|golden knights|vegas aces|raiders|chicago bears|chicago fire)',
  exclude_regex        text NOT NULL DEFAULT '(parking|suite|package|\mpass\M|vanguards|unrivaled|hoopfest|globetrotters|timberwolves|\mlynx\M|season|membership|deposit)',
  updated_at           timestamptz NOT NULL DEFAULT now()
);
INSERT INTO public.axs_watch_config (id) VALUES (true) ON CONFLICT (id) DO NOTHING;

CREATE TABLE IF NOT EXISTS public.axs_watch_venue (
  axs_venue_id  bigint PRIMARY KEY,                 -- axs_export_event.venue_id
  venue_name    text NOT NULL,
  quota         integer NOT NULL CHECK (quota >= 0), -- how many of its upcoming events are watched at once
  enabled       boolean NOT NULL DEFAULT true,
  note          text,
  set_by        text NOT NULL DEFAULT 'operator',
  set_at        timestamptz NOT NULL DEFAULT now()
);
INSERT INTO public.axs_watch_venue (axs_venue_id, venue_name, quota, note) VALUES
  (101242, 'Crypto.com Arena',              55, 'operator list 2026-11-24: Lakers, Kings, concerts, family shows'),
  (101329, 'Toyota Center',                 40, 'operator list 2026-11-24: Rockets (AXS-powered nba shop) + concerts'),
  (101949, 'T-Mobile Arena',                35, 'operator list 2026-11-24: Golden Knights + concerts'),
  (101164, 'Red Rocks Amphitheatre',        25, 'operator list 2026-11-24: concerts'),
  (126512, 'RODEOHOUSTON - Reliant Stadium', 14, 'operator list 2026-11-24: the 2027 rodeo concerts'),
  (101620, 'PeoplesBank Arena',             10, 'operator list 2026-11-24: concerts + family shows (no AHL)'),
  (101076, 'MGM Grand Garden Arena',         7, 'operator list 2026-11-24: concerts'),
  (101260, 'Target Center',                  6, 'operator list 2026-11-24: concerts only; the Timberwolves and Lynx are read by the browser worker'),
  (101546, 'Greek Theatre',                  6, 'operator list 2026-11-24: concerts'),
  (101238, 'Soldier Field',                  2, 'operator 2026-11-24 "add soldier concerts": Zach Bryan; the stadium is otherwise Ticketmaster')
ON CONFLICT (axs_venue_id) DO NOTHING;

-- one row per request to TicketsData: the in-flight ledger and the record of how each read went
CREATE TABLE IF NOT EXISTS public.axs_watch_poll (
  request_id      bigint PRIMARY KEY,               -- pg_net's id
  axs_event_id    text NOT NULL,
  fired_at        timestamptz NOT NULL DEFAULT now(),
  checked_at      timestamptz,
  status_code     integer,
  outcome         text CHECK (outcome IN ('ok', 'empty', 'expired', 'not_axs', 'upstream_error', 'timeout', 'lost', 'unparsed')),
  response_s      numeric,                           -- TicketsData's own elapsed seconds for the read
  listings        integer,
  quota_remaining bigint,                            -- the pool after this read, as TicketsData reports it
  error           text
);
CREATE INDEX IF NOT EXISTS axs_watch_poll_pending_idx ON public.axs_watch_poll (fired_at) WHERE checked_at IS NULL;
CREATE INDEX IF NOT EXISTS axs_watch_poll_fired_idx   ON public.axs_watch_poll (fired_at);
CREATE INDEX IF NOT EXISTS axs_watch_poll_event_idx   ON public.axs_watch_poll (axs_event_id, fired_at);

CREATE TABLE IF NOT EXISTS public.axs_watch_audit (
  id            bigserial PRIMARY KEY,
  at            timestamptz NOT NULL DEFAULT now(),
  run_id        uuid NOT NULL,
  action        text NOT NULL CHECK (action IN ('add', 'retire', 'short')),
  axs_event_id  text,
  venue         text,
  note          text
);
CREATE INDEX IF NOT EXISTS axs_watch_audit_at_idx ON public.axs_watch_audit (at);

ALTER TABLE public.axs_watch_config ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.axs_watch_venue  ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.axs_watch_poll   ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.axs_watch_audit  ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.axs_watch_config, public.axs_watch_venue, public.axs_watch_poll, public.axs_watch_audit FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.axs_watch_config, public.axs_watch_venue, public.axs_watch_poll, public.axs_watch_audit TO service_role;

-- Does an AXS export row belong on the list? Never an excluded entry; a sports event only when it names a major-league team.
CREATE OR REPLACE FUNCTION public.axs_watch_rule_ok(p_category text, p_title text)
 RETURNS boolean
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT coalesce(p_title, '') <> ''
     AND p_title !~* (SELECT c.exclude_regex FROM public.axs_watch_config c)
     AND (coalesce(p_category, '') <> 'Sports' OR p_title ~* (SELECT c.sports_keep_regex FROM public.axs_watch_config c))
$function$;

-- The list: retire what has passed or left, refill each venue to its quota from the export, stamp the run so the feed
-- serves exactly the watched events. p_apply = false reports what it would do.
CREATE OR REPLACE FUNCTION public.axs_watch_fill(p_apply boolean DEFAULT true)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_run uuid := gen_random_uuid();
  v_cfg public.axs_watch_config%ROWTYPE;
  v     record;
  v_have integer; v_room integer; v_need integer; v_added integer; v_retired integer := 0; v_total_added integer := 0;
  v_short jsonb := '[]'::jsonb;
BEGIN
  IF NOT pg_try_advisory_xact_lock(hashtext('axs_watch_fill')) THEN
    RETURN jsonb_build_object('skipped', 'another axs_watch_fill is running');
  END IF;
  SELECT * INTO v_cfg FROM public.axs_watch_config;

  -- 1. retire: the event has passed, the export no longer lists it or no longer says AXS sells it, or three reads
  --    in a row said AXS does not sell it (not_axs) or it is over (expired)
  DROP TABLE IF EXISTS _aw_retire;
  CREATE TEMP TABLE _aw_retire ON COMMIT DROP AS
  SELECT t.source_event_id, t.venue_name,
         CASE WHEN e.axs_event_id IS NULL THEN 'not_in_export'
              WHEN e.gone_at IS NOT NULL OR e.removed_utc IS NOT NULL THEN 'gone'
              WHEN NOT coalesce(e.axs_ticketed, false) THEN 'not_axs_sold'
              WHEN coalesce(e.event_date_utc, t.start_utc, (t.event_date + 1)::timestamptz) < now() - interval '6 hours' THEN 'passed'
              ELSE 'not_axs_or_expired' END AS why
    FROM public.primary_poll_event t
    LEFT JOIN public.axs_export_event e ON e.axs_event_id::text = t.source_event_id
   WHERE t.source = 'axs'
     AND (e.axs_event_id IS NULL OR e.gone_at IS NOT NULL OR e.removed_utc IS NOT NULL OR NOT coalesce(e.axs_ticketed, false)
          OR coalesce(e.event_date_utc, t.start_utc, (t.event_date + 1)::timestamptz) < now() - interval '6 hours'
          OR (SELECT count(*) = 3 AND bool_and(w.outcome IN ('not_axs', 'expired'))
                FROM (SELECT w.outcome FROM public.axs_watch_poll w
                       WHERE w.axs_event_id = t.source_event_id AND w.checked_at IS NOT NULL
                       ORDER BY w.fired_at DESC LIMIT 3) w));
  SELECT count(*) INTO v_retired FROM _aw_retire;
  IF p_apply THEN
    INSERT INTO public.axs_watch_audit (run_id, action, axs_event_id, venue, note)
    SELECT v_run, 'retire', r.source_event_id, r.venue_name, r.why FROM _aw_retire r;
    DELETE FROM public.primary_poll_event t USING _aw_retire r WHERE t.source = 'axs' AND t.source_event_id = r.source_event_id;
    -- the export's match arriving later than the row: fill-only, as the mapper does for the other sources
    UPDATE public.primary_poll_event t
       SET tevo_event_id = e.tevo_event_id, tevo_match_method = 'axs_export', tevo_matched_at = now()
      FROM public.axs_export_event e
     WHERE t.source = 'axs' AND t.tevo_event_id IS NULL
       AND e.axs_event_id::text = t.source_event_id AND e.tevo_event_id IS NOT NULL;
  END IF;

  -- 2. refill each venue to its quota, soonest first, within the list's size
  FOR v IN SELECT * FROM public.axs_watch_venue WHERE enabled ORDER BY quota DESC, axs_venue_id LOOP
    SELECT count(*) INTO v_have
      FROM public.primary_poll_event t JOIN public.axs_export_event e ON e.axs_event_id::text = t.source_event_id
     WHERE t.source = 'axs' AND e.venue_id = v.axs_venue_id
       AND NOT EXISTS (SELECT 1 FROM _aw_retire r WHERE r.source_event_id = t.source_event_id);
    SELECT v_cfg.target_events - count(*) INTO v_room
      FROM public.primary_poll_event t WHERE t.source = 'axs'
       AND NOT EXISTS (SELECT 1 FROM _aw_retire r WHERE r.source_event_id = t.source_event_id);
    v_need := least(greatest(v.quota - v_have, 0), greatest(v_room, 0));
    CONTINUE WHEN v_need = 0;
    DROP TABLE IF EXISTS _aw_pick;
    CREATE TEMP TABLE _aw_pick ON COMMIT DROP AS
    SELECT e.axs_event_id, e.event_title, e.event_date_local, e.event_date_utc, e.event_timezone, e.venue_name, e.venue_city,
           e.venue_state, e.event_url, e.tevo_event_id
      FROM public.axs_export_event e
     WHERE e.venue_id = v.axs_venue_id
       AND e.gone_at IS NULL AND e.removed_utc IS NULL AND coalesce(e.axs_ticketed, false)
       AND e.event_date_utc > now() AND e.event_url IS NOT NULL
       AND public.axs_watch_rule_ok(e.major_category, e.event_title)
       AND NOT EXISTS (SELECT 1 FROM public.primary_poll_event t WHERE t.source = 'axs' AND t.source_event_id = e.axs_event_id::text
                          AND NOT EXISTS (SELECT 1 FROM _aw_retire r WHERE r.source_event_id = t.source_event_id))
       AND NOT EXISTS (SELECT 1 FROM _aw_retire r WHERE r.source_event_id = e.axs_event_id::text)
       -- not an event TicketsData has said three times (in the 14 days the ledger keeps) that AXS does not sell or that is over
       AND (SELECT count(*) FROM public.axs_watch_poll w WHERE w.axs_event_id = e.axs_event_id::text AND w.outcome IN ('not_axs', 'expired')) < 3
     ORDER BY e.event_date_utc, e.axs_event_id
     LIMIT v_need;
    SELECT count(*) INTO v_added FROM _aw_pick;
    IF v_added < v_need THEN
      v_short := v_short || jsonb_build_object('venue', v.venue_name, 'quota', v.quota, 'short_by', v_need - v_added);
      IF p_apply THEN
        INSERT INTO public.axs_watch_audit (run_id, action, venue, note)
        VALUES (v_run, 'short', v.venue_name, format('quota %s, %s eligible upcoming events short', v.quota, v_need - v_added));
      END IF;
    END IF;
    IF p_apply AND v_added > 0 THEN
      INSERT INTO public.primary_poll_event (source, source_event_id, name, event_date, start_local_time, start_utc, timezone,
          venue_name, venue_city, venue_state, ticket_url, tevo_event_id, tevo_match_method, tevo_matched_at, announced_at)
      SELECT 'axs', p.axs_event_id::text, p.event_title,
             CASE WHEN p.event_date_local ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}' THEN left(p.event_date_local, 10)::date END,
             CASE WHEN p.event_date_local ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}' THEN substr(p.event_date_local, 12, 5)::time END,
             p.event_date_utc, p.event_timezone, p.venue_name, p.venue_city, p.venue_state, p.event_url,
             p.tevo_event_id, CASE WHEN p.tevo_event_id IS NOT NULL THEN 'axs_export' END,
             CASE WHEN p.tevo_event_id IS NOT NULL THEN now() END,
             now()                       -- the mapper is not asked: the export's own match is the AXS match
        FROM _aw_pick p
      ON CONFLICT (source, source_event_id) DO NOTHING;
      INSERT INTO public.axs_watch_audit (run_id, action, axs_event_id, venue, note)
      SELECT v_run, 'add', p.axs_event_id::text, p.venue_name, left(p.event_date_local, 16) || ' ' || p.event_title FROM _aw_pick p;
    END IF;
    v_total_added := v_total_added + v_added;
  END LOOP;

  -- 3. the run: the feed serves the watched events and no other; the ledger forgets old requests
  IF p_apply THEN
    PERFORM public.primary_poll_run_done('axs', replace(v_run::text, '-', ''),
              coalesce((SELECT jsonb_agg(t.source_event_id) FROM public.primary_poll_event t WHERE t.source = 'axs'), '[]'::jsonb));
    DELETE FROM public.axs_watch_poll WHERE fired_at < now() - interval '14 days';
    DELETE FROM public.axs_watch_audit WHERE at < now() - interval '90 days';
  END IF;

  RETURN jsonb_build_object('run', v_run, 'apply', p_apply, 'retired', v_retired, 'added', v_total_added,
           'watched', CASE WHEN p_apply THEN (SELECT count(*) FROM public.primary_poll_event t WHERE t.source = 'axs')
                           ELSE (SELECT count(*) FROM public.primary_poll_event t WHERE t.source = 'axs') - v_retired + v_total_added END,
           'short', v_short);
END $function$;

-- A TicketsData AXS body (the `body` of the response) as the feed takes it: listings = contiguous blocks of seats on
-- sale, one per section, row, seat type, price and offer; a general-admission price level without seat items is one
-- listing for its available amount. Prices are the price level's base in cents (the facility fee AXS folds into it
-- included); AXS's service fee is in the body's fee lookup tables and is not computed here (fee null). Also the
-- event-level figures the feed carries.
CREATE OR REPLACE FUNCTION public.axs_watch_parse(p_body jsonb)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
  WITH offers AS (
    SELECT o FROM jsonb_array_elements(CASE WHEN jsonb_typeof(p_body->'inventory'->'offer_search'->0->'offers') = 'array'
                                            THEN p_body->'inventory'->'offer_search'->0->'offers' ELSE '[]'::jsonb END) o),
  book AS (                                   -- the price book: offer x price level
    SELECT op->>'offerID' AS offer_id, max(op->>'offerType') AS offer_type, max(op->>'offerName') AS offer_name,
           min(nullif(op->>'min', '')::integer) AS order_min, max(nullif(op->>'max', '')::integer) AS order_max,
           pl->>'priceLevelID' AS pl_id, max(pl->>'label') AS pl_label,
           round(max(nullif(pr->>'base', '')::numeric) / 100, 2) AS price,
           max(nullif(pl->'availability'->>'amount', '')::integer) AS avail,
           bool_or(coalesce((zp->>'isSoldOut')::boolean, false)) AS sold_out
      FROM jsonb_array_elements(CASE WHEN jsonb_typeof(p_body->'inventory'->'inventory_v4'->0->'offerPrices') = 'array'
                                     THEN p_body->'inventory'->'inventory_v4'->0->'offerPrices' ELSE '[]'::jsonb END) op
      CROSS JOIN LATERAL jsonb_array_elements(CASE WHEN jsonb_typeof(op->'zonePrices') = 'array' THEN op->'zonePrices' ELSE '[]'::jsonb END) zp
      CROSS JOIN LATERAL jsonb_array_elements(CASE WHEN jsonb_typeof(zp->'priceLevels') = 'array' THEN zp->'priceLevels' ELSE '[]'::jsonb END) pl
      LEFT JOIN LATERAL jsonb_array_elements(CASE WHEN jsonb_typeof(pl->'prices') = 'array' THEN pl->'prices' ELSE '[]'::jsonb END) pr ON true
     GROUP BY op->>'offerID', pl->>'priceLevelID'),
  seats AS (                                  -- every seat on sale, priced from the book
    SELECT o->>'offerID' AS offer_id, it->>'sectionLabel' AS section, it->>'rowLabel' AS seat_row, it->>'seatType' AS seat_type,
           it->>'priceLevelID' AS pl_id, coalesce((it->>'isGASection')::boolean, false) AS ga, it->>'number' AS seat,
           CASE WHEN it->>'number' ~ '^[0-9]+$' THEN (it->>'number')::integer END AS seat_no,
           coalesce(b.price, round(nullif(it->>'originalPrice', '')::numeric, 2)) AS price,
           CASE WHEN lower(coalesce(b.offer_type, '')) LIKE '%resale%' THEN 'resale' ELSE 'primary' END AS market,
           b.order_max, coalesce(it->>'neighborhoodPrintDescription', it->>'neighborhoodLabel') AS area,
           it->>'statusCodeLabel' AS status_label
      FROM offers CROSS JOIN LATERAL jsonb_array_elements(CASE WHEN jsonb_typeof(o->'items') = 'array' THEN o->'items' ELSE '[]'::jsonb END) it
      LEFT JOIN book b ON b.offer_id = o->>'offerID' AND b.pl_id = it->>'priceLevelID'),
  islands AS (
    SELECT s.*, CASE WHEN s.seat_no IS NOT NULL
                     THEN s.seat_no - row_number() OVER (PARTITION BY s.offer_id, s.section, s.seat_row, s.seat_type, s.price, s.market, s.ga
                                                         ORDER BY s.seat_no) END AS grp
      FROM seats s),
  blocks AS (
    SELECT offer_id, section, seat_row, seat_type, price, market, ga, max(area) AS area, max(order_max) AS order_max,
           min(seat_no) AS seat_from, max(seat_no) AS seat_to, count(*)::integer AS qty,
           jsonb_agg(seat ORDER BY seat_no NULLS LAST, seat) AS seats,
           bool_or(coalesce(status_label, '') ~* 'ada|wheelchair|accessible') AS ada
      FROM islands
     GROUP BY offer_id, section, seat_row, seat_type, price, market, ga, grp),
  ga_levels AS (                              -- general admission sold by amount, with no seat items for the level
    SELECT b.offer_id, b.pl_id, b.pl_label, b.price, b.avail, b.order_max,
           CASE WHEN lower(coalesce(b.offer_type, '')) LIKE '%resale%' THEN 'resale' ELSE 'primary' END AS market
      FROM book b
     WHERE coalesce(b.avail, 0) > 0 AND NOT b.sold_out AND b.price IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM seats s WHERE s.offer_id = b.offer_id AND s.pl_id = b.pl_id)),
  listings AS (
    SELECT jsonb_build_object(
             'id', abs(hashtextextended(concat_ws('|', b.offer_id, b.section, b.seat_row, b.seat_from, b.seat_to, b.seat_type, b.market), 0))::text,
             'market', b.market, 'section', b.section, 'row', b.seat_row,
             'seat_low', CASE WHEN b.seat_from IS NOT NULL THEN b.seat_from::text ELSE b.seats->>0 END,
             'seat_high', CASE WHEN b.seat_to IS NOT NULL THEN b.seat_to::text ELSE b.seats->>-1 END,
             'seats', b.seats, 'qty', b.qty, 'max_per_order', b.order_max, 'price', b.price,
             'area', b.area, 'ticket_type', b.seat_type, 'ada', b.ada, 'ga', b.ga) AS l,
           b.price, b.qty
      FROM blocks b
    UNION ALL
    SELECT jsonb_build_object(
             'id', 'ga-' || g.offer_id || '-' || g.pl_id, 'market', g.market, 'section', g.pl_label, 'qty', g.avail,
             'max_per_order', g.order_max, 'price', g.price, 'ticket_type', 'GA', 'ga', true) AS l,
           g.price, g.avail
      FROM ga_levels g)
  SELECT jsonb_build_object(
           'listings', coalesce((SELECT jsonb_agg(l.l ORDER BY l.l->>'section', l.l->>'row', l.l->>'id') FROM listings l), '[]'::jsonb),
           'price_min', (SELECT min(price) FROM listings),
           'price_max', (SELECT max(price) FROM listings),
           'total_available', (SELECT coalesce(sum(qty), 0) FROM listings),
           'order_min', (SELECT min(order_min) FROM book WHERE coalesce(offer_type, 'Single') = 'Single'),
           'order_max', (SELECT max(order_max) FROM book WHERE coalesce(offer_type, 'Single') = 'Single'),
           'offer_id', nullif(p_body->'onsale'->>'offer_id', ''),
           'on_sale_now', (p_body->'onsale'->'status'->>'onSaleNow')::boolean)
$function$;

-- The credit budget today: the pool TicketsData last reported, the days to the next reset, the day's cap and what
-- this poller has fired today (UTC).
CREATE OR REPLACE FUNCTION public.axs_watch_budget()
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  WITH cfg AS (SELECT * FROM public.axs_watch_config),
  reading AS (SELECT u.quota_remaining, u.called_at
                FROM public.ticketsdata_credit_usage u
               WHERE u.quota_remaining IS NOT NULL AND u.called_at > now() - interval '6 hours'
               ORDER BY u.called_at DESC LIMIT 1),
  reset AS (SELECT CASE WHEN extract(day FROM current_date) < cfg.cycle_reset_day
                        THEN make_date(extract(year FROM current_date)::int, extract(month FROM current_date)::int, cfg.cycle_reset_day)
                        ELSE (make_date(extract(year FROM current_date)::int, extract(month FROM current_date)::int, cfg.cycle_reset_day) + interval '1 month')::date END AS next_reset
              FROM cfg),
  pool AS (SELECT coalesce((SELECT r.quota_remaining FROM reading r),
                           cfg.monthly_credits - (SELECT coalesce(sum(u.credits), 0) FROM public.ticketsdata_credit_usage u
                                                   WHERE u.called_at >= (reset.next_reset - interval '1 month'))) AS remaining,
                  (SELECT r.called_at FROM reading r) AS read_at
             FROM cfg, reset),
  today AS (SELECT count(*) AS fired FROM public.axs_watch_poll w WHERE w.fired_at >= date_trunc('day', now() AT TIME ZONE 'UTC') AT TIME ZONE 'UTC')
  SELECT jsonb_build_object(
           'pool_remaining', pool.remaining, 'pool_read_at', pool.read_at,
           'next_reset', reset.next_reset, 'days_left', greatest(reset.next_reset - current_date, 1),
           'daily_cap', coalesce(cfg.daily_cap_override,
                                 greatest(floor((pool.remaining - cfg.reserve_credits)::numeric / greatest(reset.next_reset - current_date, 1))::integer, 0)),
           'fired_today', today.fired,
           'in_flight', (SELECT count(*) FROM public.axs_watch_poll w WHERE w.checked_at IS NULL AND w.fired_at > now() - cfg.stale_after),
           'enabled', cfg.enabled)
    FROM cfg, reset, pool, today
$function$;

-- One minute of the cascade: settle what has landed, then fire what is due within the slots and the budget.
CREATE OR REPLACE FUNCTION public.axs_watch_tick()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'net', 'extensions', 'pg_temp'
AS $function$
DECLARE
  v_cfg public.axs_watch_config%ROWTYPE;
  v_budget jsonb; v_cap integer; v_fired_today integer; v_in_flight integer; v_slots integer; v_errors integer;
  v_fired integer := 0; v_settled integer := 0; v_lost integer := 0;
  w record; t record; c jsonb; body jsonb; parsed jsonb; v_ok boolean; v_outcome text; v_error text; v_rid bigint; v_tevo bigint;
  v_due jsonb;
BEGIN
  IF NOT pg_try_advisory_xact_lock(hashtext('axs_watch_tick')) THEN
    RETURN jsonb_build_object('skipped', 'another axs_watch_tick is running');
  END IF;
  SELECT * INTO v_cfg FROM public.axs_watch_config;

  -- 1. settle: every pending request whose response has landed
  FOR w IN SELECT p.request_id, p.axs_event_id, r.status_code, r.content, r.timed_out, r.error_msg
             FROM public.axs_watch_poll p JOIN net._http_response r ON r.id = p.request_id
            WHERE p.checked_at IS NULL
            ORDER BY p.fired_at
  LOOP
    c := public.safe_jsonb(w.content);
    body := c->'body';
    parsed := NULL; v_error := NULL;
    IF coalesce(w.timed_out, false) OR w.error_msg IS NOT NULL THEN
      v_ok := false; v_outcome := 'timeout'; v_error := left(coalesce(w.error_msg, 'timed out'), 200);
    ELSIF w.status_code IN (400, 404, 410, 422) THEN
      v_ok := false; v_outcome := 'not_axs'; v_error := 'HTTP ' || w.status_code || ': AXS does not sell this event through TicketsData';
    ELSIF w.status_code IS DISTINCT FROM 200 THEN
      v_ok := false; v_outcome := 'upstream_error'; v_error := 'HTTP ' || coalesce(w.status_code::text, '?') || ' from TicketsData';
    ELSIF body->>'status' = 'expired' THEN
      v_ok := false; v_outcome := 'expired'; v_error := 'expired: the event is over on AXS';
    ELSIF jsonb_typeof(body->'event') = 'object' AND coalesce(body->>'status', '') IN ('ok', 'success') AND coalesce(body->>'exit_code', '0') = '0' THEN
      parsed := public.axs_watch_parse(body);
      v_ok := true; v_outcome := CASE WHEN jsonb_array_length(parsed->'listings') = 0 THEN 'empty' ELSE 'ok' END;
    ELSE
      v_ok := false; v_outcome := 'unparsed';
      v_error := left(coalesce(body->>'error', body->>'message', c->>'error', 'TicketsData answered without an event'), 200);
    END IF;

    v_tevo := NULL;
    SELECT * INTO t FROM public.primary_poll_event e WHERE e.source = 'axs' AND e.source_event_id = w.axs_event_id;
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
      -- the optional slower rung for events far out: the feed's age limit follows next_poll_at, so it is moved too
      IF v_cfg.far_out_every IS NOT NULL AND v_cfg.far_out_days IS NOT NULL AND t.event_date > current_date + v_cfg.far_out_days THEN
        UPDATE public.primary_poll_event e
           SET poll_interval = greatest(e.poll_interval, v_cfg.far_out_every),
               next_poll_at = public.primary_poll_next(greatest(e.poll_interval, v_cfg.far_out_every), e.next_poll_at)
         WHERE e.source = 'axs' AND e.source_event_id = w.axs_event_id AND e.poll_interval < v_cfg.far_out_every;
      END IF;
    END IF;
    IF w.status_code = 200 THEN                 -- a credit is spent on a 200, whatever the body said
      PERFORM public.td_charge_credit(1, v_tevo, 'AXS', '/fetch', w.status_code, nullif(c->>'quota_remaining', '')::integer);
    END IF;
    UPDATE public.axs_watch_poll p
       SET checked_at = now(), status_code = w.status_code, outcome = v_outcome, error = v_error,
           response_s = nullif(coalesce(body->>'elapsed_seconds', c->>'response_s'), '')::numeric,
           listings = CASE WHEN parsed IS NOT NULL THEN jsonb_array_length(parsed->'listings') END,
           quota_remaining = nullif(c->>'quota_remaining', '')::bigint
     WHERE p.request_id = w.request_id;
    v_settled := v_settled + 1;
  END LOOP;

  -- a request with no response by stale_after never will have one (pg_net gave up): a failed poll, retried on the cadence
  FOR w IN SELECT p.request_id, p.axs_event_id FROM public.axs_watch_poll p
            WHERE p.checked_at IS NULL AND p.fired_at < now() - v_cfg.stale_after
              AND NOT EXISTS (SELECT 1 FROM net._http_response r WHERE r.id = p.request_id)
  LOOP
    SELECT * INTO t FROM public.primary_poll_event e WHERE e.source = 'axs' AND e.source_event_id = w.axs_event_id;
    IF FOUND THEN
      PERFORM public.primary_poll_ingest('axs', jsonb_build_array(jsonb_strip_nulls(jsonb_build_object(
                'id', t.source_event_id, 'name', t.name, 'local_date', t.event_date::text,
                'local_time', to_char(t.start_local_time, 'HH24:MI'), 'start_utc', t.start_utc, 'timezone', t.timezone,
                'venue', t.venue_name, 'city', t.venue_city, 'state', t.venue_state, 'url', t.ticket_url, 'offer_id', t.offer_id,
                'ok', false, 'error', 'lost: no response from TicketsData')) || '{"listings": []}'::jsonb));
    END IF;
    UPDATE public.axs_watch_poll p SET checked_at = now(), outcome = 'lost', error = 'no response within stale_after' WHERE p.request_id = w.request_id;
    v_lost := v_lost + 1;
  END LOOP;

  IF NOT v_cfg.enabled THEN
    RETURN jsonb_build_object('settled', v_settled, 'lost', v_lost, 'fired', 0, 'paused', true);
  END IF;

  -- 2. the slots: in flight, the upstream's health, the budget
  v_budget := public.axs_watch_budget();
  v_cap := (v_budget->>'daily_cap')::integer;
  v_fired_today := (v_budget->>'fired_today')::integer;
  v_in_flight := (v_budget->>'in_flight')::integer;
  SELECT count(*) FILTER (WHERE x.outcome IN ('upstream_error', 'timeout', 'lost')) INTO v_errors
    FROM (SELECT p.outcome FROM public.axs_watch_poll p WHERE p.checked_at IS NOT NULL ORDER BY p.checked_at DESC LIMIT 10) x;
  v_slots := v_cfg.max_in_flight - v_in_flight;
  IF v_errors >= v_cfg.upstream_errors_max THEN v_slots := least(v_slots, 1 - v_in_flight); END IF;
  IF v_slots <= 0 THEN
    RETURN jsonb_build_object('settled', v_settled, 'lost', v_lost, 'fired', 0, 'in_flight', v_in_flight,
                              'upstream_errors', v_errors, 'daily_cap', v_cap, 'fired_today', v_fired_today);
  END IF;

  -- 3. fire the due events, most overdue first; over the cap only the hot ones, up to the overrun
  v_due := public.primary_poll_due('axs', coalesce((SELECT jsonb_agg(e.source_event_id) FROM public.primary_poll_event e
                                                      WHERE e.source = 'axs' AND e.ticket_url IS NOT NULL), '[]'::jsonb));
  FOR t IN SELECT e.source_event_id, e.ticket_url, e.tevo_event_id, e.poll_interval, e.event_date
             FROM public.primary_poll_event e
            WHERE e.source = 'axs' AND e.ticket_url IS NOT NULL
              AND e.source_event_id IN (SELECT jsonb_array_elements_text(v_due))
              AND NOT EXISTS (SELECT 1 FROM public.axs_watch_poll p WHERE p.axs_event_id = e.source_event_id AND p.checked_at IS NULL)
              AND (e.event_date IS NULL OR e.event_date >= current_date - 1)
            ORDER BY e.next_poll_at NULLS FIRST, e.event_date NULLS LAST, e.source_event_id
            LIMIT v_slots
  LOOP
    IF v_fired_today + v_fired >= v_cap THEN
      -- over the day's share: only an event on a hot cadence, and only up to the overrun
      CONTINUE WHEN t.poll_interval IS NULL OR t.poll_interval > v_cfg.hot_every;
      CONTINUE WHEN v_fired_today + v_fired >= v_cap + (v_cap * v_cfg.hot_overrun_pct) / 100;
    END IF;
    SELECT net.http_get(
      url := 'https://ticketsdata.com/fetch',
      params := jsonb_build_object(
        'username',  public.get_app_secret(p_name => 'TICKETSDATA_USERNAME'),
        'password',  public.get_app_secret(p_name => 'TICKETSDATA_PASSWORD'),
        'event_url', t.ticket_url, 'platform', 'axs'),
      timeout_milliseconds := v_cfg.fire_timeout_ms) INTO v_rid;
    INSERT INTO public.axs_watch_poll (request_id, axs_event_id) VALUES (v_rid, t.source_event_id);
    v_fired := v_fired + 1;
  END LOOP;

  RETURN jsonb_build_object('settled', v_settled, 'lost', v_lost, 'fired', v_fired, 'in_flight', v_in_flight + v_fired,
                            'upstream_errors', v_errors, 'daily_cap', v_cap, 'fired_today', v_fired_today + v_fired,
                            'pool_remaining', v_budget->'pool_remaining');
END $function$;

REVOKE ALL ON FUNCTION public.axs_watch_rule_ok(text, text), public.axs_watch_fill(boolean), public.axs_watch_parse(jsonb),
  public.axs_watch_budget(), public.axs_watch_tick() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.axs_watch_rule_ok(text, text), public.axs_watch_fill(boolean), public.axs_watch_parse(jsonb),
  public.axs_watch_budget(), public.axs_watch_tick() TO service_role;

-- the crons: the cascade every minute; the list refilled nightly after the AXS export sync and the spine's chunks (02:20Z)
SELECT cron.schedule('axs_watch_tick_1m', '* * * * *',
  $cmd$BEGIN; SET LOCAL statement_timeout = '50s'; SELECT public.axs_watch_tick(); COMMIT;$cmd$);
SELECT cron.schedule('axs_watch_fill_daily', '20 3 * * *',
  $cmd$BEGIN; SET LOCAL statement_timeout = '120s'; SELECT public.axs_watch_fill(true); COMMIT;$cmd$);

-- the first fill: applying this is the operator's start
SELECT public.axs_watch_fill(true);

NOTIFY pgrst, 'reload schema';

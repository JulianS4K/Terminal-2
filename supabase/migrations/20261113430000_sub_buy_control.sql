-- Migration 20261113430000 · level:secondary-sales · lane:D0 · writes:sub_buy_control,manual_sub_buy,manual_sub_buy_changed_trg,sub_buy_lock,sub_buy_evo_inflight,sub_buy_spent_today,sub_buy_gate,manual_sub_buy_claim,n2s_autobuy_live_claim,sub_finder_buy_result_json,sub_finder_buys · reads:n2s_autobuy_exec,n2s_autobuy_result_json,sub_finder_order,sub_finder_config,events · pre:20261113320000,20261113410000
--
-- ONE CONTROL OVER BOTH BUYERS, and ONE FEED of what they bought.
--
-- Two workers buy substitute tickets: the sub finder's (manual_sub_buy: the automatic
-- one-to-one buy, a CRM key's buy, seats a GoTickets customer accepted, an operator's buy) and
-- the N2S auto-buyer (n2s_autobuy_exec, lane D7). Each keeps its own switches and ceilings;
-- nothing sat above both. Operator 2026-11-13: "do 3 but retain n2s buy conditions" (one buyer).
--
-- The limit on buys sent together is the one each worker already has and keeps: one buy at a
-- time, one per tick (15 seconds). The operator confirmed that is the limit ("that's the limit
-- not 3"). Nothing here changes it, and NOTHING HERE IS IN FORCE WHEN APPLIED:
--
--   1. sub_buy_control (one row), every setting off:
--        enforce (false)             master switch for the two below; while false they are ignored.
--        stop                        no NEW buy by either buyer. Buys already placed are still
--                                    followed to their result.
--        daily_ceiling_usd           both buyers, both markets, per New York day. NULL = none.
--        evo_inflight_max (NULL)     optional, off: at most this many EVO buys, from BOTH
--                                    buyers, waiting for their seller to confirm; the next one
--                                    waits. evo_inflight_minutes (60): an unanswered buy stops
--                                    counting after this long. Kept because of the one burst
--                                    on record (2026-10-01: 15 EVO buys in 14 seconds on one
--                                    event, before these workers existed; sellers rejected 9).
--      Each buyer's own switches, ceilings, runs and kill switch are untouched and still apply.
--   2. manual_sub_buy_claim() (full definition): honours the control. With an in-flight limit
--      set, an EVO buy over it stays 'requested'; a GoTickets buy behind it may go.
--   3. n2s_autobuy_live_claim() (lane D7's function, patched as D7 asked in bot_chat 6687): one
--      anchor, in the branch that hands out a buy, guarded by production's md5. Poll steps and
--      everything else are unchanged. The advisory lock is taken after N2S's own FOR UPDATE on
--      n2s_autobuy_config, the same order manual_sub_buy_claim() uses, so the two claims see
--      each other's buys and cannot deadlock.
--   4. manual_sub_buy.changed_at: moves whenever a buy changes in a way a reader would see
--      (updated_at cannot be used: it dates the spend).
--   5. sub_finder_buys(key, updated_since, limit, offset) (GET /api/v1/subs/buys): every purchase
--      either buyer placed, one sync feed. /autobuys is unchanged.
--
-- Nothing here calls a market. Functions of ours are shipped whole (MIGRATION_CONVENTIONS 6a).
--
-- rollback: UPDATE public.sub_buy_control SET enforce = false, evo_inflight_max = NULL WHERE id = true;
--           (the state this ships in: every check passes; the claims behave as before.)

-- ── 1. the control ─────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.sub_buy_control (
  id                   boolean PRIMARY KEY DEFAULT true CHECK (id),
  enforce              boolean NOT NULL DEFAULT false,
  stop                 boolean NOT NULL DEFAULT false,
  stop_reason          text,
  daily_ceiling_usd    numeric CHECK (daily_ceiling_usd IS NULL OR daily_ceiling_usd >= 0),
  evo_inflight_max     integer CHECK (evo_inflight_max IS NULL OR evo_inflight_max >= 1),
  evo_inflight_minutes integer NOT NULL DEFAULT 60 CHECK (evo_inflight_minutes >= 1),
  updated_at           timestamptz NOT NULL DEFAULT now()
);
INSERT INTO public.sub_buy_control DEFAULT VALUES ON CONFLICT DO NOTHING;
ALTER TABLE public.sub_buy_control ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.sub_buy_control FROM PUBLIC, anon, authenticated;
COMMENT ON TABLE public.sub_buy_control IS
  'One row over both sub buyers (manual_sub_buy and n2s_autobuy_exec), all off as shipped: behind `enforce` a shared stop and a shared daily ceiling; and an optional EVO in-flight limit. 20261113430000.';

-- Both claims take this after their own config row lock, never before.
CREATE OR REPLACE FUNCTION public.sub_buy_lock()
 RETURNS void
 LANGUAGE sql
AS $$ SELECT pg_advisory_xact_lock(20261113430000) $$;

-- EVO buys, from both buyers, that a seller has not answered yet.
CREATE OR REPLACE FUNCTION public.sub_buy_evo_inflight()
 RETURNS integer
 LANGUAGE sql
 STABLE
 SECURITY DEFINER
 SET search_path = public, pg_temp
AS $$
  SELECT ((SELECT count(*) FROM public.manual_sub_buy b
            WHERE b.market = 'evo'
              AND (b.state = 'buying'
                OR (b.state = 'bought' AND b.final_at IS NULL
                    AND b.updated_at > now() - make_interval(mins => k.evo_inflight_minutes))))
        + (SELECT count(*) FROM public.n2s_autobuy_exec e
            WHERE e.mode = 'live' AND e.sub_source = 'tevo'
              AND (e.phase = 'buying'
                OR (e.phase = 'buy_sent'
                    AND e.live_started_at > now() - make_interval(mins => k.evo_inflight_minutes)))))::integer
    FROM public.sub_buy_control k
$$;

-- What both buyers have committed today (New York day), on every market.
-- The sub finder's side counts a buy the way its own daily ceiling does; the N2S side counts
-- what the market charged, else what the buy was priced at with tax (D7's rule, bot_chat 6687).
CREATE OR REPLACE FUNCTION public.sub_buy_spent_today()
 RETURNS numeric
 LANGUAGE sql
 STABLE
 SECURITY DEFINER
 SET search_path = public, pg_temp
AS $$
  SELECT (SELECT COALESCE(sum(COALESCE(b.bought_total_usd, round(b.max_price_ea * b.qty, 2))), 0)
            FROM public.manual_sub_buy b
           WHERE b.state IN ('buying', 'bought', 'unknown')
             AND (b.updated_at AT TIME ZONE 'America/New_York')::date = (now() AT TIME ZONE 'America/New_York')::date)
       + (SELECT COALESCE(sum(COALESCE(e.buy_total_usd, e.sub_total_usd + COALESCE(e.est_tax_usd, 0))), 0)
            FROM public.n2s_autobuy_exec e
           WHERE e.mode = 'live'
             AND e.phase IN ('buying', 'buy_sent', 'sub_accepted', 'accepted', 'buy_unknown', 'accept_failed', 'accept_unknown')
             AND (e.live_started_at AT TIME ZONE 'America/New_York')::date = (now() AT TIME ZONE 'America/New_York')::date)
$$;

-- May a NEW buy of p_total_usd on p_market ('evo' / 'tevo' / 'gotickets') go out now?
-- NULL = yes; otherwise why not. Takes the shared lock, so call it after your own config lock.
CREATE OR REPLACE FUNCTION public.sub_buy_gate(p_market text, p_total_usd numeric)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path = public, pg_temp
AS $$
DECLARE
  k public.sub_buy_control%ROWTYPE;
BEGIN
  PERFORM public.sub_buy_lock();
  SELECT * INTO k FROM public.sub_buy_control WHERE id;
  IF NOT FOUND THEN RETURN NULL; END IF;
  IF k.enforce AND k.stop THEN RETURN 'shared_stop'; END IF;
  IF lower(p_market) IN ('evo', 'tevo') AND k.evo_inflight_max IS NOT NULL
     AND public.sub_buy_evo_inflight() >= k.evo_inflight_max THEN
    RETURN 'evo_inflight_full';
  END IF;
  -- a buy with no known total cannot be shown to fit under the ceiling
  IF k.enforce AND k.daily_ceiling_usd IS NOT NULL
     AND (p_total_usd IS NULL OR public.sub_buy_spent_today() + p_total_usd > k.daily_ceiling_usd) THEN
    RETURN 'over_shared_ceiling';
  END IF;
  RETURN NULL;
END
$$;

REVOKE ALL ON FUNCTION public.sub_buy_lock(), public.sub_buy_evo_inflight(), public.sub_buy_spent_today(),
                       public.sub_buy_gate(text, numeric) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.sub_buy_lock(), public.sub_buy_evo_inflight(), public.sub_buy_spent_today(),
                          public.sub_buy_gate(text, numeric) TO service_role;

-- ── 2. the sub finder's claim ──────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.manual_sub_buy_claim()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  c        public.manual_sub_buy_config%ROWTYPE;
  b        public.manual_sub_buy%ROWTYPE;
  v_total  numeric;
  v_spent  numeric;
  v_today  date := (now() AT TIME ZONE 'America/New_York')::date;
  v_gate   text;
  r        text[] := '{}';
BEGIN
  -- FOR UPDATE serializes claims, so two workers see each other's spend and never share a row.
  SELECT * INTO c FROM public.manual_sub_buy_config WHERE id FOR UPDATE;

  -- A row left in 'buying' past its lease means a worker died around the buy: the outcome is
  -- unknown. It is NEVER handed out again (that could buy twice); everything stops for a person.
  UPDATE public.manual_sub_buy
     SET state = 'unknown', reasons = reasons || 'worker_lost_mid_buy'::text, updated_at = now(),
         lease_token = NULL
   WHERE state = 'buying' AND lease_until < now();
  IF FOUND THEN
    UPDATE public.manual_sub_buy_config
       SET kill_switch = true, kill_reason = 'a buy was left unfinished: check EVO and GoTickets', updated_at = now()
     WHERE id;
    RETURN NULL;
  END IF;

  IF NOT c.enabled OR c.kill_switch THEN RETURN NULL; END IF;
  IF EXISTS (SELECT 1 FROM public.manual_sub_buy WHERE state IN ('buying', 'unknown')) THEN
    RETURN NULL;                                        -- one at a time; nothing while one is unresolved
  END IF;

  -- 20261113430000: the control over both buyers (sub_buy_control). Asked with no amount first:
  -- that answers the shared stop and whether EVO is at its in-flight limit. A waiting buy
  -- stays 'requested' and is looked at again on the next tick.
  v_gate := public.sub_buy_gate('evo', 0);
  IF v_gate = 'shared_stop' THEN RETURN NULL; END IF;

  SELECT * INTO b FROM public.manual_sub_buy
   WHERE state = 'requested' AND (market <> 'evo' OR v_gate IS DISTINCT FROM 'evo_inflight_full')
   ORDER BY created_at, buy_id LIMIT 1 FOR UPDATE SKIP LOCKED;
  IF NOT FOUND THEN RETURN NULL; END IF;

  v_total := round(b.max_price_ea * b.qty, 2);
  SELECT COALESCE(sum(COALESCE(bought_total_usd, round(max_price_ea * qty, 2))), 0) INTO v_spent
    FROM public.manual_sub_buy
   WHERE state IN ('bought', 'unknown') AND (updated_at AT TIME ZONE 'America/New_York')::date = v_today
     AND market = b.market;                             -- each market spends against its own ceiling
  IF b.market = 'gotickets' AND NOT c.gt_enabled THEN r := r || 'gotickets_buy_off'::text; END IF;
  IF v_total > (CASE b.market WHEN 'gotickets' THEN coalesce(c.gt_per_order_cap_usd, c.per_order_cap_usd)
                              ELSE c.per_order_cap_usd END)
    THEN r := r || 'over_order_cap'::text; END IF;
  IF v_spent + v_total > (CASE b.market WHEN 'gotickets' THEN coalesce(c.gt_daily_cap_usd, c.daily_cap_usd)
                                        ELSE c.daily_cap_usd END)
    THEN r := r || 'over_daily_cap'::text; END IF;
  IF public.sub_buy_gate(b.market, v_total) = 'over_shared_ceiling'
    THEN r := r || 'over_shared_ceiling'::text; END IF;  -- both buyers' spend today, every market
  IF cardinality(r) > 0 THEN
    UPDATE public.manual_sub_buy SET state = 'stopped', reasons = r, updated_at = now() WHERE buy_id = b.buy_id;
    RETURN NULL;
  END IF;

  UPDATE public.manual_sub_buy
     SET state = 'buying', lease_token = gen_random_uuid(),
         lease_until = now() + make_interval(secs => c.lease_s), updated_at = now(),
         max_total_usd = public.manual_sub_buy_total_ceiling(b)
   WHERE buy_id = b.buy_id
  RETURNING * INTO b;

  RETURN jsonb_build_object(
    'row', to_jsonb(b),
    'cfg', jsonb_build_object('evo_buyer_office_id', c.evo_buyer_office_id,
                              'evo_email_address_id', c.evo_email_address_id,
                              'tax_quote', c.tax_quote,
                              'gt_buyer_email', c.gt_buyer_email, 'gt_buyer_phone', c.gt_buyer_phone,
                              'gt_billing_address', c.gt_billing_address, 'gt_recipient', c.gt_recipient,
                              'gt_gift_card_ids', to_jsonb(c.gt_gift_card_ids),
                              -- the first run is a test: ask, store the answer, change nothing else
                              'tax_quote_test', c.tax_quote_test AND NOT c.tax_quote
                                AND NOT EXISTS (SELECT 1 FROM public.manual_sub_buy q WHERE q.quote_raw IS NOT NULL)));
END $function$;

-- ── 3. the N2S claim: one anchor, in the branch that hands out a buy ───────
DO $do$
DECLARE
  d text := pg_get_functiondef('public.n2s_autobuy_live_claim()'::regprocedure);
  a text := $a$    IF FOUND THEN
      v_act := 'buy';$a$;
BEGIN
  IF position('sub_buy_gate' IN d) > 0 THEN RETURN; END IF;        -- already applied
  IF md5(d) <> '356ae3e7f3088fab5693db2a1d1cf6d8' THEN
    RAISE EXCEPTION 'n2s_autobuy_live_claim drifted from 20261113400000: re-derive this migration with lane D7';
  END IF;
  IF (length(d) - length(replace(d, a, ''))) / length(a) <> 1 THEN
    RAISE EXCEPTION 'n2s_autobuy_live_claim: the hand-out anchor was not found exactly once';
  END IF;
  EXECUTE replace(d, a, $n$    IF FOUND THEN
      -- 20261113430000 (D0, reviewed by D7): one stop, one daily ceiling and one EVO in-flight
      -- limit over both buyers (sub_buy_control). A buy that may not go now is not handed out:
      -- the row is untouched, no live run is spent, and it is looked at again on the next tick.
      IF public.sub_buy_gate(e.sub_source, COALESCE(e.buy_total_usd, e.sub_total_usd + COALESCE(e.est_tax_usd, 0))) IS NOT NULL THEN
        RETURN NULL;
      END IF;
      v_act := 'buy';$n$);
END
$do$;

-- ── 4. when a buy last changed ─────────────────────────────────────────────
ALTER TABLE public.manual_sub_buy ADD COLUMN IF NOT EXISTS changed_at timestamptz;
UPDATE public.manual_sub_buy
   SET changed_at = greatest(created_at, updated_at, coalesce(final_at, updated_at))
 WHERE changed_at IS NULL;
ALTER TABLE public.manual_sub_buy ALTER COLUMN changed_at SET DEFAULT now();
ALTER TABLE public.manual_sub_buy ALTER COLUMN changed_at SET NOT NULL;
COMMENT ON COLUMN public.manual_sub_buy.changed_at IS
  'When anything a reader of the buy would see last changed (state, outcome, order, seats, totals, reasons). updated_at dates the spend and is not moved by a seller''s confirmation. 20261113430000.';

CREATE OR REPLACE FUNCTION public.manual_sub_buy_changed_trg()
 RETURNS trigger
 LANGUAGE plpgsql
AS $$
BEGIN
  IF (NEW.state, NEW.outcome, NEW.buy_order_id, NEW.buy_state, NEW.seller_state, NEW.order_state,
      NEW.order_total_usd, NEW.bought_total_usd, NEW.seats, NEW.bought_section, NEW.bought_row,
      NEW.reasons, NEW.rejection_reason)
     IS DISTINCT FROM
     (OLD.state, OLD.outcome, OLD.buy_order_id, OLD.buy_state, OLD.seller_state, OLD.order_state,
      OLD.order_total_usd, OLD.bought_total_usd, OLD.seats, OLD.bought_section, OLD.bought_row,
      OLD.reasons, OLD.rejection_reason) THEN
    NEW.changed_at := now();
  END IF;
  RETURN NEW;
END
$$;
CREATE OR REPLACE TRIGGER manual_sub_buy_changed BEFORE UPDATE ON public.manual_sub_buy
  FOR EACH ROW EXECUTE FUNCTION public.manual_sub_buy_changed_trg();

-- ── 5. one feed of what both buyers bought ─────────────────────────────────
-- A sub finder purchase in the shape n2s_autobuy_result_json() gives an N2S one.
CREATE OR REPLACE FUNCTION public.sub_finder_buy_result_json(b public.manual_sub_buy)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SECURITY DEFINER
 SET search_path = public, pg_temp
AS $$
  SELECT jsonb_build_object(
    'buyer',               'sub_finder',
    'buy_ref',             b.market || '-' || b.buy_order_id,
    'bought_on',           b.market,
    'bought_order_number', b.buy_order_id,
    'for_order', jsonb_build_object(
        'order_number', b.sale_order_number,
        'ref',          coalesce(lower(b.sale_site), 'unknown') || '-' || b.sale_order_number,
        'sold_on',      b.sale_site,
        'section',      o.section,
        'row',          o.seat_row,
        'qty',          coalesce(o.qty, b.qty),
        'sold_total_usd', round(b.sold_ea * b.qty, 2),
        'state',        NULL),
    'status', CASE WHEN b.state = 'unknown' THEN 'check_manually'
                   WHEN b.state = 'bought' AND b.outcome = 'confirmed' THEN 'went_through'
                   WHEN b.state IN ('buying', 'bought') THEN 'pending'
                   ELSE 'stopped' END,
    'went_through', b.state = 'bought' AND b.outcome = 'confirmed',
    'phase',        b.state,
    'reasons',      to_jsonb(b.reasons),
    'event', jsonb_build_object('name', b.event_name, 'local_start', ev.occurs_at_local,
                                'start_utc', NULL, 'venue', o.venue,
                                'tevo_event_id', b.tevo_event_id, 'gotickets_event_id', b.gt_event_id),
    'bought', jsonb_build_object('listing_id', b.ticket_group_id::text, 'section', b.bought_section,
                                 'row', b.bought_row, 'qty', b.qty, 'seats', b.seats,
                                 'state', coalesce(b.order_state, b.buy_state)),
    'totals', jsonb_build_object(
        'quoted_usd',  coalesce(b.quote_total_usd, round(b.bought_price_ea * b.qty, 2)),
        'charged_usd', coalesce(b.order_total_usd, b.bought_total_usd),
        'sold_usd',    round(b.sold_ea * b.qty, 2),
        'margin_usd',  round(b.sold_ea * b.qty - coalesce(b.order_total_usd, b.bought_total_usd, b.quote_total_usd,
                                                         b.bought_price_ea * b.qty), 2)),
    'bought_at',  b.created_at,
    'updated_at', b.changed_at)
  FROM (SELECT 1) one
  LEFT JOIN LATERAL (SELECT so.section, so.seat_row, so.qty, so.venue FROM public.sub_finder_order so
                      WHERE so.order_number = b.sale_order_number
                      ORDER BY so.updated_at DESC LIMIT 1) o ON true
  LEFT JOIN public.events ev ON ev.id = b.tevo_event_id;
$$;

CREATE OR REPLACE FUNCTION public.sub_finder_buys(
  p_key_id bigint, p_updated_since timestamptz DEFAULT NULL, p_limit integer DEFAULT 200, p_offset integer DEFAULT 0)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SECURITY DEFINER
 SET search_path = public, pg_temp
AS $$
DECLARE
  c       public.sub_finder_config;
  v_now   timestamptz := now();
  v_limit integer := least(greatest(coalesce(p_limit, 200), 1), 1000);
  v_off   integer := greatest(coalesce(p_offset, 0), 0);
BEGIN
  SELECT * INTO c FROM public.sub_finder_config;
  IF NOT coalesce(c.enabled, false) OR NOT (p_key_id = ANY (c.key_ids)) OR NOT (p_key_id = ANY (c.autobuys_key_ids)) THEN
    RETURN jsonb_build_object('error', 'forbidden', 'detail', 'this key may not read buy results');
  END IF;
  RETURN (
    WITH f AS (
      SELECT e.live_updated_at AS at, 1 AS src, e.exec_id AS id
        FROM public.n2s_autobuy_exec e
       WHERE e.mode = 'live' AND e.buy_order_id IS NOT NULL
         AND (p_updated_since IS NULL OR e.live_updated_at >= p_updated_since)
      UNION ALL
      SELECT b.changed_at, 2, b.buy_id
        FROM public.manual_sub_buy b
       WHERE b.buy_order_id IS NOT NULL
         AND (p_updated_since IS NULL OR b.changed_at >= p_updated_since)
    ), page AS (
      SELECT * FROM f ORDER BY at, src, id LIMIT v_limit OFFSET v_off
    )
    SELECT jsonb_build_object(
      'count', (SELECT count(*) FROM page), 'total', (SELECT count(*) FROM f),
      'limit', v_limit, 'offset', v_off,
      'items', (SELECT coalesce(jsonb_agg(
                         CASE p.src
                           WHEN 1 THEN (SELECT public.n2s_autobuy_result_json(e) || jsonb_build_object('buyer', 'n2s_auto')
                                          FROM public.n2s_autobuy_exec e WHERE e.exec_id = p.id)
                           ELSE (SELECT public.sub_finder_buy_result_json(b)
                                   FROM public.manual_sub_buy b WHERE b.buy_id = p.id) END
                         ORDER BY p.at, p.src, p.id), '[]'::jsonb) FROM page p),
      'generated_at', to_char(v_now AT TIME ZONE 'utc', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"')));
END
$$;

REVOKE ALL ON FUNCTION public.sub_finder_buy_result_json(public.manual_sub_buy),
                       public.sub_finder_buys(bigint, timestamptz, integer, integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.sub_finder_buy_result_json(public.manual_sub_buy),
                          public.sub_finder_buys(bigint, timestamptz, integer, integer) TO service_role;

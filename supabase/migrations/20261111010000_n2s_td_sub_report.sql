-- Migration 20261111010000 · level:secondary-sales · lane:D7 · writes:n2s_td_sub_report,n2s_td_sub_report_capture,n2s_td_sub_report_trg · reads:n2s_cover_queue,n2s_items,n2s_autobuy_config,n2s_evo_current,events · pre:20261111000000
--
-- N2S: REPORT-ONLY subs from every secondary market TicketsData reads.
--
-- Operator 2026-11-11: "add ticket data API all secondary marketplaces", report only.
-- The cover feed already carries TicketsData listings (sub_source 'ticketsdata:<platform>':
-- StubHub, Vivid, Gametime, TickPick, Viagogo, Ticketmaster, ...), but both dry-run captures
-- read only 'gotickets' and 'tevo' rows, so an order whose best cover sits on another market
-- was never evaluated. This adds a third capture for those rows.
--
-- ⚠ NOTHING HERE CAN BUY. Rows land in their OWN table, n2s_td_sub_report, never in
-- n2s_gt_order_dryrun: n2s_autobuy_enqueue_trg fires on every would_buy inserted there, and a
-- TicketsData row must not reach the live worker, spend the shared daily cap, or mark an order
-- 'already_bought' against a later EVO sub. No function here calls any market; TicketsData
-- itself is GET only (RULE 2 holds).
--
-- Rules (same as the EVO capture where they apply):
--   gate_moves_buyer        cover gate not in p_gates (1 = Index, same section)
--   obstructed_view         the cover's view reads obstructed
--   listing_stale           TicketsData last saw the listing more than p_max_age ago. TD is a
--                           change feed with no delisting marker: a listing can be gone, so
--                           every would_buy is "verify, then buy by hand"
--   possibly_our_own_listing  we own an EVO listing for the event in the same section, row and
--                           quantity (our inventory is cross-listed on these markets)
--   order_closed / timer_closed / event_started
--   event_within_lead / same_day_event   n2s_autobuy_config.min_event_lead / allow_same_day,
--                           lead measured from the event's real start (as 20261111000000)
--   not_profitable          sub total >= what the order sold for
--   over_order_cap          sub total above n2s_autobuy_config.per_order_cap_usd
--   listing_taken           another order already has a would_buy on this listing here
--   level_mismatch / row_letter_mismatch / not_enough_time   from n2s_dryrun_extra_reasons()
-- Unlike the buy dry runs there is no sell-market filter: a person can accept the sale on any
-- market. PED orders (n2s_id <= 0) stay out, as in the other captures.
--
-- rollback: DROP TRIGGER n2s_td_sub_report_after_refresh ON public.n2s_cover_queue;
--           DROP FUNCTION public.n2s_td_sub_report_trg(), public.n2s_td_sub_report_capture(integer[], interval);
--           DROP TABLE public.n2s_td_sub_report;

-- CREATE TRIGGER briefly locks n2s_cover_queue against the 15 s refresh; fail fast instead.
SET LOCAL lock_timeout = '5s';

CREATE TABLE IF NOT EXISTS public.n2s_td_sub_report (
  report_id           bigserial PRIMARY KEY,
  captured_at         timestamptz NOT NULL DEFAULT now(),
  n2s_id              bigint      NOT NULL,
  order_number        text,
  s4k_source          text,
  event_name          text,
  event_date          date,
  event_start_utc     timestamptz,
  tevo_event_id       bigint,
  sold_section        text,
  sold_row            text,
  sold_qty            integer,
  sold_ea             numeric,
  platform            text        NOT NULL,
  sub_listing_id      text        NOT NULL,
  sub_section         text,
  sub_row             text,
  sub_qty             integer,
  quoted_ea           numeric     NOT NULL,
  quoted_total        numeric,
  profit              numeric,
  cover_gate          integer,
  cover_label         text,
  sub_view            text,
  listing_captured_at timestamptz,
  listing_age_s       integer,
  seconds_left        integer,
  decision            text        NOT NULL CHECK (decision IN ('would_buy', 'skip')),
  skip_reasons        text[]      NOT NULL DEFAULT '{}',
  buy_url             text,
  CONSTRAINT n2s_td_sub_report_once UNIQUE (n2s_id, sub_listing_id, quoted_ea)
);

CREATE INDEX IF NOT EXISTS n2s_td_sub_report_captured_idx ON public.n2s_td_sub_report (captured_at DESC);
CREATE INDEX IF NOT EXISTS n2s_td_sub_report_listing_idx
  ON public.n2s_td_sub_report (platform, sub_listing_id) WHERE decision = 'would_buy';

ALTER TABLE public.n2s_td_sub_report ENABLE ROW LEVEL SECURITY;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE schemaname = 'public'
                  AND tablename = 'n2s_td_sub_report' AND policyname = 'n2s_td_sub_report_sel') THEN
    CREATE POLICY n2s_td_sub_report_sel ON public.n2s_td_sub_report FOR SELECT TO authenticated USING (true);
  END IF;
END $$;
REVOKE ALL ON public.n2s_td_sub_report FROM PUBLIC, anon;

COMMENT ON TABLE public.n2s_td_sub_report IS
  'N2S REPORT ONLY (20261111010000): covers found on the secondary markets TicketsData reads '
  '(sub_source ticketsdata:<platform>). would_buy = passes the auto-buy rules and is worth buying '
  'BY HAND after checking the listing still exists. Nothing reads this table to place an order.';

CREATE OR REPLACE FUNCTION public.n2s_td_sub_report_capture(p_gates integer[] DEFAULT '{1}'::integer[],
                                                            p_max_age interval DEFAULT interval '30 minutes')
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  c          public.n2s_autobuy_config%ROWTYPE;
  r          RECORD;
  v_reasons  text[];
  v_platform text;
  v_start    timestamptz;
  v_sold     numeric;
  v_today    date := (now() AT TIME ZONE 'America/New_York')::date;
  v_n        int := 0;
BEGIN
  SELECT * INTO c FROM public.n2s_autobuy_config WHERE id;

  FOR r IN
    SELECT q.*, i.is_terminal, i.event_dt, i.timer_expires_at, i.timer_expired, i.alert_at
      FROM public.n2s_cover_queue q
      JOIN public.n2s_items i ON i.n2s_id = q.n2s_id
     WHERE q.sub_source LIKE 'ticketsdata:%'
       AND q.sub_listing_id IS NOT NULL
       AND q.sub_ea IS NOT NULL
       AND q.n2s_id > 0
       AND COALESCE(i.status, '') NOT IN ('n2b', 'n2b_closed')
       AND NOT EXISTS (SELECT 1 FROM public.n2s_td_sub_report d
                        WHERE d.n2s_id = q.n2s_id
                          AND d.sub_listing_id = q.sub_listing_id
                          AND d.quoted_ea = q.sub_ea)
     ORDER BY q.fifo_position NULLS LAST, q.n2s_id
  LOOP
    v_reasons  := '{}';
    v_platform := split_part(r.sub_source, ':', 2);
    v_sold     := round(r.sold_ea * r.quantity, 2);

    -- The event's real start, as n2s_autobuy_enqueue_trg reads it (20261111000000).
    BEGIN
      SELECT NULLIF(e.occurs_at_local, '')::timestamptz INTO v_start FROM public.events e WHERE e.id = r.tevo_event_id;
    EXCEPTION WHEN OTHERS THEN
      v_start := NULL;
    END;
    v_start := COALESCE(v_start, r.event_dt AT TIME ZONE 'UTC');

    IF NOT (COALESCE(r.cover_gate, 0) = ANY (p_gates))  THEN v_reasons := array_append(v_reasons, 'gate_moves_buyer'); END IF;
    IF r.sub_view = 'obstructed'                        THEN v_reasons := array_append(v_reasons, 'obstructed_view'); END IF;
    IF r.captured_at IS NULL OR r.captured_at < now() - p_max_age
                                                        THEN v_reasons := array_append(v_reasons, 'listing_stale'); END IF;
    IF EXISTS (SELECT 1 FROM public.n2s_evo_current o
                WHERE o.event_id = r.tevo_event_id AND o.is_owned AND o.quantity = r.sub_qty
                  AND public.seat_section_norm(o.section) = public.seat_section_norm(r.sub_section)
                  AND upper(btrim(COALESCE(o."row", ''))) = upper(btrim(COALESCE(r.sub_row, ''))))
                                                        THEN v_reasons := array_append(v_reasons, 'possibly_our_own_listing'); END IF;
    IF COALESCE(r.is_terminal, false)                   THEN v_reasons := array_append(v_reasons, 'order_closed'); END IF;
    IF NOT public.n2s_timer_open(r.timer_expires_at, r.timer_expired, r.alert_at)
                                                        THEN v_reasons := array_append(v_reasons, 'timer_closed'); END IF;
    IF NOT public.n2s_event_live(r.event_dt, r.tevo_event_id, interval '0')
                                                        THEN v_reasons := array_append(v_reasons, 'event_started'); END IF;
    IF v_start IS NULL THEN
      v_reasons := array_append(v_reasons, 'event_time_unknown');
    ELSE
      IF v_start < now() + c.min_event_lead             THEN v_reasons := array_append(v_reasons, 'event_within_lead'); END IF;
      IF NOT c.allow_same_day
         AND COALESCE(r.event_dt::date, (v_start AT TIME ZONE 'America/New_York')::date) <= v_today
                                                        THEN v_reasons := array_append(v_reasons, 'same_day_event'); END IF;
    END IF;
    IF v_sold IS NULL OR COALESCE(r.sub_total, 0) >= v_sold
                                                        THEN v_reasons := array_append(v_reasons, 'not_profitable'); END IF;
    IF COALESCE(r.sub_total, 0) > c.per_order_cap_usd   THEN v_reasons := array_append(v_reasons, 'over_order_cap'); END IF;
    IF EXISTS (SELECT 1 FROM public.n2s_td_sub_report d
                WHERE d.decision = 'would_buy' AND d.platform = v_platform
                  AND d.sub_listing_id = r.sub_listing_id AND d.n2s_id <> r.n2s_id)
                                                        THEN v_reasons := array_append(v_reasons, 'listing_taken'); END IF;
    -- level mismatch, single/double-letter rows, time for a seller to accept (its listing_taken
    -- arm reads the buy dry-run log, where no ticketsdata row ever lands)
    v_reasons := v_reasons || public.n2s_dryrun_extra_reasons(r.n2s_id, r.sub_source, r.sub_listing_id,
                                                              r.section, r.sub_section, r.timer_expires_at);

    INSERT INTO public.n2s_td_sub_report (
      n2s_id, order_number, s4k_source, event_name, event_date, event_start_utc, tevo_event_id,
      sold_section, sold_row, sold_qty, sold_ea,
      platform, sub_listing_id, sub_section, sub_row, sub_qty, quoted_ea, quoted_total, profit,
      cover_gate, cover_label, sub_view, listing_captured_at, listing_age_s, seconds_left,
      decision, skip_reasons, buy_url)
    VALUES (
      r.n2s_id, r.order_number, r.s4k_source, r.event_name, r.event_date, v_start, r.tevo_event_id,
      r.section, r.order_row, r.quantity, r.sold_ea,
      v_platform, r.sub_listing_id, r.sub_section, r.sub_row, r.sub_qty, r.sub_ea, r.sub_total,
      v_sold - r.sub_total,
      r.cover_gate, r.cover_label, r.sub_view, r.captured_at,
      extract(epoch FROM (now() - r.captured_at))::int,
      GREATEST(0, extract(epoch FROM (r.timer_expires_at - now())))::int,
      CASE WHEN cardinality(v_reasons) = 0 THEN 'would_buy' ELSE 'skip' END,
      v_reasons, r.buy_url)
    ON CONFLICT ON CONSTRAINT n2s_td_sub_report_once DO NOTHING;

    v_n := v_n + 1;
  END LOOP;
  RETURN v_n;
END $function$;

REVOKE ALL ON FUNCTION public.n2s_td_sub_report_capture(integer[], interval) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.n2s_td_sub_report_capture(integer[], interval) TO service_role;

-- Own trigger function and own trigger: n2s_gt_order_dryrun_trg() is left untouched, and a
-- failure here can never stop the cover-queue refresh or the buy dry runs.
CREATE OR REPLACE FUNCTION public.n2s_td_sub_report_trg()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
  BEGIN
    PERFORM public.n2s_td_sub_report_capture('{1}', interval '30 minutes');
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'n2s_td_sub_report_capture failed: % (%)', SQLERRM, SQLSTATE;
  END;
  RETURN NULL;
END $function$;

REVOKE ALL ON FUNCTION public.n2s_td_sub_report_trg() FROM PUBLIC, anon, authenticated;

DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'n2s_td_sub_report_after_refresh'
                  AND tgrelid = 'public.n2s_cover_queue'::regclass) THEN
    CREATE TRIGGER n2s_td_sub_report_after_refresh
      AFTER INSERT ON public.n2s_cover_queue
      FOR EACH STATEMENT
      EXECUTE FUNCTION public.n2s_td_sub_report_trg();
  END IF;
END $$;

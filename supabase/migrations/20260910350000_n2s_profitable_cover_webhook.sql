-- ============================================================================
-- Migration 20260910350000 — push profitable covers out the moment they exist
--
-- Lane:     D0 (orders surface)
-- Touches:  n2s_cover_push (NEW table), n2s_cover_push_queue() (NEW),
--           n2s_cover_push_drain() (NEW), one cron job.
-- Pre-reqs: 20260910340000
--
-- Operator direction 2026-09-10: "when an order comes in and is mapped and you
-- poll for subs and you get results and those results are profitable, we need
-- to push the ordernumber, section row and qty of the subs, and the buy url
-- out via api ... or webhook ... whichever is better at sending info in real
-- time."
--
-- ── WEBHOOK, NOT AN API, AND WHY ──────────────────────────────────────────
-- An API endpoint is PULL: the consumer's latency is its poll interval, and it
-- pays for a constant stream of empty requests to stay timely. A webhook is
-- PUSH: it fires when the fact exists. Since the whole pipeline upstream of
-- this is already event-driven (order arrives -> mapped -> polled -> matched),
-- a webhook is the only part that keeps that property end to end.
--
-- The pull half already exists and is deliberately NOT replaced:
-- GET /api/broker/n2s-covers?profitable=true returns the same book. That is
-- the reconciliation path for when the receiver was down — push for latency,
-- pull for truth, which is the standard pairing and the reason this migration
-- does not try to make the webhook perfectly reliable on its own.
--
-- ── RULE 2 ────────────────────────────────────────────────────────────────
-- This is the first outbound POST in the N2S path, so it is worth being exact:
-- it targets an OPERATOR-CONFIGURED endpoint, never a ticket marketplace. It
-- sends our own data out; it creates no order, hold, price or inventory
-- anywhere upstream.
--
-- ⚠ THE HOST IS CHECKED AT RUNTIME, NOT JUST IN CI. scripts/check_readonly.py
-- can only scan literals, and this URL arrives from a vault secret — so a
-- mistyped or malicious secret could aim a POST at a broker host and the
-- static gate would never see it. n2s_cover_push_queue() therefore refuses to
-- fire at any FORBIDDEN_HOSTS entry and raises instead. That list is
-- duplicated here on purpose: the CI copy cannot protect a runtime value.
--
-- ── IDEMPOTENCY ───────────────────────────────────────────────────────────
-- A cover is identified by (n2s_id, sub_source, sub_listing_id, sub_qty,
-- sub_ea). The unique index on (n2s_id, fingerprint) means a cover is pushed
-- ONCE and a no-op refresh re-sends nothing, while a genuine change — the FIFO
-- allocator moving the order to a different listing, or the price moving —
-- produces a new fingerprint and a new push, because that is a new actionable
-- fact rather than a duplicate.
--
-- Inert until configured: with N2S_COVER_WEBHOOK_URL unset the queue returns 0
-- and touches nothing, so this ships safely and starts working the moment the
-- secret is set.
-- ============================================================================

-- ── SECRET WHITELIST — READ THIS BEFORE APPROVING ─────────────────────────
-- ⚠ THIS TOUCHES A SECURITY CONTROL. get_app_secret() does not merely fetch a
-- vault value: it enforces a caller check AND a hard whitelist of names, and
-- raises 42501 for anything not on it. A webhook URL is not on that list, so
-- without this the queue below would raise EVERY MINUTE from cron — the same
-- shape of failure as the uncatalogued-event crash earlier today.
--
-- The change is strictly ADDITIVE and deliberately narrow:
--   * two names appended: N2S_COVER_WEBHOOK_URL, N2S_COVER_WEBHOOK_TOKEN
--   * every existing name retained, verbatim
--   * the current_user assert is retained EXACTLY as-is — it is the control
--     that stops anon/authenticated reading secrets at all, and nothing here
--     may relax it
-- Neither new name is a marketplace credential; they address an endpoint the
-- operator owns. Flagged rather than buried because widening a secret
-- whitelist is the kind of edit that should never pass review unnoticed.
CREATE OR REPLACE FUNCTION public.get_app_secret(p_name text)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'vault'
AS $function$
DECLARE v_value text;
BEGIN
  IF current_user NOT IN ('service_role', 'postgres', 'supabase_admin') THEN
    RAISE EXCEPTION 'get_app_secret: caller % not authorized', current_user USING ERRCODE = '42501';
  END IF;
  IF p_name NOT IN (
    'SEATDATA_API_KEY','TEVO_API_TOKEN','TEVO_SECRET','SEATGEEK_API_TOKEN',
    'TICKPICK_API_TOKEN','VIVID_API_TOKEN','APPSCRIPT_INGEST_SECRET',
    'TICKETSDATA_USERNAME','TICKETSDATA_PASSWORD','TWITTERAPI_IO_KEY',
    'WA_GATEWAY_URL','WA_GATEWAY_KEY',
    'crm.s4kcs.com',
    'crm.s4kcs.com/n2s',
    -- TicketsData SECOND account, for the N2S cover lane only. Its quota is
    -- ADDITIVE to TICKETSDATA_USERNAME/PASSWORD, never a slice of it.
    'TICKETSDATA_N2S_USERNAME','TICKETSDATA_N2S_PASSWORD',
    -- Outbound destination for the profitable-cover webhook. Operator-owned
    -- endpoint; not a marketplace credential. See 20260910350000.
    'N2S_COVER_WEBHOOK_URL','N2S_COVER_WEBHOOK_TOKEN'
  ) THEN
    RAISE EXCEPTION 'secret % is not in the app whitelist', p_name USING ERRCODE = '42501';
  END IF;
  SELECT decrypted_secret INTO v_value FROM vault.decrypted_secrets WHERE name = p_name LIMIT 1;
  RETURN v_value;
END $function$;

CREATE TABLE IF NOT EXISTS public.n2s_cover_push (
  id           bigserial PRIMARY KEY,
  n2s_id       bigint      NOT NULL,
  fingerprint  text        NOT NULL,
  payload      jsonb       NOT NULL,
  request_id   bigint,
  fired_at     timestamptz NOT NULL DEFAULT now(),
  resolved_at  timestamptz,
  status_code  integer,
  error_msg    text,
  attempts     integer     NOT NULL DEFAULT 1
);

-- The idempotency contract. Same cover => same fingerprint => one row.
CREATE UNIQUE INDEX IF NOT EXISTS n2s_cover_push_fp_idx
  ON public.n2s_cover_push(n2s_id, fingerprint);
CREATE INDEX IF NOT EXISTS n2s_cover_push_unresolved_idx
  ON public.n2s_cover_push(fired_at) WHERE resolved_at IS NULL;

COMMENT ON TABLE public.n2s_cover_push IS
  'Outbox for profitable-cover webhooks. One row per (n2s_id, cover '
  'fingerprint); the unique index is what stops a re-push on every refresh. '
  'See migration 20260910350000.';

CREATE OR REPLACE FUNCTION public.n2s_cover_push_queue(p_max integer DEFAULT 25)
RETURNS TABLE(pushed integer, skipped_already_sent integer, configured boolean)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE
  v_url   text := public.get_app_secret('N2S_COVER_WEBHOOK_URL');
  v_token text := public.get_app_secret('N2S_COVER_WEBHOOK_TOKEN');
  v_host  text;
  v_bad   text;
  r RECORD; v_req bigint; v_fp text; v_payload jsonb;
  v_pushed int := 0; v_skipped int := 0;
BEGIN
  IF v_url IS NULL OR btrim(v_url) = '' THEN
    RETURN QUERY SELECT 0, 0, false; RETURN;
  END IF;

  -- ⚠ RUNTIME RULE 2 GUARD. The static audit cannot see a vault value, so the
  -- forbidden-host list is enforced here as well. Raise rather than skip: a
  -- webhook aimed at a marketplace is a misconfiguration to fix loudly, not a
  -- condition to tolerate quietly.
  v_host := lower(COALESCE(substring(v_url from '^[a-z]+://([^/?#]+)'), ''));
  FOREACH v_bad IN ARRAY ARRAY[
    'api.ticketevolution.com','api.sandbox.ticketevolution.com',
    'brokerdata.seatgeek.com','sellerdirect-api.seatgeek.com',
    'api.tickpick.com','brokers.vividseats.com','gotickets.com',
    'seatdata.io','ticketsdata.com','broadway.com','rest.bandsintown.com',
    'crm.s4kcs.com','axs.com','evenue.net']
  LOOP
    IF position(v_bad IN v_host) > 0 THEN
      RAISE EXCEPTION
        'n2s_cover_push_queue: refusing to POST to upstream host % (RULE 2)', v_host;
    END IF;
  END LOOP;

  FOR r IN
    SELECT v.n2s_id, v.order_number, v.n2s_order_key, v.s4k_source,
           v.event_name, v.event_date, v.venue, v.tevo_event_id,
           v.section, v.order_row, v.quantity, v.sold_ea,
           v.sub_source, v.sub_listing_id, v.sub_section, v.sub_row,
           v.sub_qty, v.sub_avail, v.sub_ea, v.sub_total, v.cover_cost,
           v.buy_url
      FROM public.v_n2s_orders v
     WHERE v.has_cover
       AND v.cover_cost < 0            -- profitable only, per the directive
     ORDER BY v.cover_cost
     LIMIT p_max
  LOOP
    v_fp := r.n2s_id || '|' || COALESCE(r.sub_source, '') || '|'
            || COALESCE(r.sub_listing_id, '') || '|'
            || COALESCE(r.sub_qty::text, '') || '|' || COALESCE(r.sub_ea::text, '');

    IF EXISTS (SELECT 1 FROM public.n2s_cover_push p
                WHERE p.n2s_id = r.n2s_id AND p.fingerprint = v_fp) THEN
      v_skipped := v_skipped + 1;
      CONTINUE;
    END IF;

    v_payload := jsonb_build_object(
      'event',            'n2s.profitable_cover',
      'n2s_id',           r.n2s_id,
      'order_number',     r.order_number,
      'order_key',        r.n2s_order_key,
      'marketplace',      r.s4k_source,
      'event_name',       r.event_name,
      'event_date',       r.event_date,
      'venue',            r.venue,
      'tevo_event_id',    r.tevo_event_id,
      'sold',             jsonb_build_object(
                            'section', r.section, 'row', r.order_row,
                            'quantity', r.quantity, 'price_each', r.sold_ea),
      'sub',              jsonb_build_object(
                            'source', r.sub_source,
                            'listing_id', r.sub_listing_id,
                            'section', r.sub_section,
                            'row', r.sub_row,
                            'quantity', r.sub_qty,
                            'lot_size', r.sub_avail,
                            'price_each', r.sub_ea,
                            'total', r.sub_total,
                            'buy_url', r.buy_url),
      -- cover_cost is outlay minus revenue, so profit is its negation. Sent
      -- pre-negated so the consumer cannot get the sign backwards.
      'profit',           round(-r.cover_cost, 2),
      'pushed_at',        now());

    SELECT net.http_post(
      url := v_url,
      body := v_payload,
      headers := CASE WHEN COALESCE(btrim(v_token), '') = ''
                      THEN jsonb_build_object('Content-Type', 'application/json')
                      ELSE jsonb_build_object('Content-Type', 'application/json',
                                              'Authorization', 'Bearer ' || v_token)
                 END,
      timeout_milliseconds := 15000
    ) INTO v_req;

    INSERT INTO public.n2s_cover_push(n2s_id, fingerprint, payload, request_id)
    VALUES (r.n2s_id, v_fp, v_payload, v_req)
    ON CONFLICT (n2s_id, fingerprint) DO NOTHING;

    v_pushed := v_pushed + 1;
  END LOOP;

  RETURN QUERY SELECT v_pushed, v_skipped, true;
END $function$;

REVOKE ALL ON FUNCTION public.n2s_cover_push_queue(integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.n2s_cover_push_queue(integer) TO service_role;

-- Resolve what pg_net has answered. A non-2xx is recorded rather than retried
-- blindly: the pull endpoint is the catch-up path, and a receiver returning
-- 500 in a loop should not be hammered by a one-minute cron.
CREATE OR REPLACE FUNCTION public.n2s_cover_push_drain()
RETURNS TABLE(resolved integer, delivered integer, failed integer)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE v_res int := 0; v_ok int := 0; v_bad int := 0;
BEGIN
  WITH done AS (
    UPDATE public.n2s_cover_push p
       SET resolved_at = now(),
           status_code = x.status_code,
           error_msg   = CASE WHEN x.status_code BETWEEN 200 AND 299
                              THEN NULL ELSE left(x.content, 500) END
      FROM net._http_response x
     WHERE x.id = p.request_id AND p.resolved_at IS NULL
    RETURNING p.status_code
  )
  SELECT count(*)::int,
         count(*) FILTER (WHERE status_code BETWEEN 200 AND 299)::int,
         count(*) FILTER (WHERE status_code IS NULL
                             OR status_code NOT BETWEEN 200 AND 299)::int
    INTO v_res, v_ok, v_bad
    FROM done;

  RETURN QUERY SELECT COALESCE(v_res,0), COALESCE(v_ok,0), COALESCE(v_bad,0);
END $function$;

REVOKE ALL ON FUNCTION public.n2s_cover_push_drain() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.n2s_cover_push_drain() TO service_role;

-- Runs on the minute like the rest of the N2S chain, immediately after the
-- cover queue is rebuilt, so a profitable cover leaves the building in the
-- same minute it is computed.
SELECT cron.schedule(
  'n2s_cover_push_1min',
  '* * * * *',
  $cron$
  SELECT public.n2s_cover_push_drain();
  SELECT public.n2s_cover_push_queue(25);
  $cron$
);

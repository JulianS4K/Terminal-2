-- 20260527050000_ticketsdata_complete_foundation.sql
--
-- TicketsData integration — complete data layer.
-- Supersedes 20260526090000 (authored in prior A1 session, never applied — DO NOT APPLY that file).
-- Incorporates D0 session schema (PR #378, branch claude/resume-d0-chat-itUGb) plus A1 additions.
--
-- TicketsData (ticketsdata.com) — 9-marketplace ticket inventory API.
-- Phase 1: StubHub (SH) + VividSeats (VD). GT/TP deferred to phase 2 (no direct IDs in aq_event_map).
-- Auth: username + password as query params (stored in vault as TICKETSDATA_USERNAME/PASSWORD).
-- Plan: Starter — 10k credits/mo (333/day hard cap), 5 req/sec, 1 credit per /fetch or /events call.
-- Latency: 2–25s per /fetch → async via pg_net (same pattern as sg_broker_pending).
--
-- TABLES:
--   ticketsdata_event_xref         — watchlist registry, one row per (event_id, platform)
--   td_pull_queue                  — async fetch queue (mirrors sg_broker_pending pattern)
--   ticketsdata_credit_usage       — per-call audit log (replaces ledger approach; daily view aggregates)
--   ticketsdata_listings_snapshots — time-series listing snapshots, content-deduped
--
-- VIEWS:
--   v_ticketsdata_credit_usage_daily — daily rollup with quota_remaining_min
--
-- FUNCTIONS (all SECURITY DEFINER, REVOKE ALL FROM anon, public):
--   ticketsdata_normalize_listings(platform, content) — 4 platform schemas → one offer shape
--   td_credits_today()      — sum of credits charged today
--   td_budget_ok()          — true when today's credits < 333
--   td_charge_credit(...)   — log one API call to credit_usage
--
-- RULE 0: If plan changes, update the 333 cap in td_budget_ok() to match the new daily allowance.
--
-- VAULT REQUIREMENT:
--   TICKETSDATA_USERNAME and TICKETSDATA_PASSWORD must exist in vault.secrets.
--   Both were created 2026-05-26. get_app_secret whitelist updated in 20260527040000.
--
-- ROLLBACK:
--   DROP VIEW IF EXISTS public.v_ticketsdata_credit_usage_daily;
--   DROP FUNCTION IF EXISTS public.ticketsdata_normalize_listings,
--     public.td_credits_today, public.td_budget_ok, public.td_charge_credit CASCADE;
--   DROP TABLE IF EXISTS public.ticketsdata_listings_snapshots, public.td_pull_queue,
--     public.ticketsdata_credit_usage, public.ticketsdata_event_xref CASCADE;


-- ─────────────────────────────────────────────────────────────────────────────
-- 1. ticketsdata_event_xref
--    One row per (event_id, platform) in the watchlist. event_url is constructed
--    at insert time for SH/VD (direct ID from aq_event_map). GT/TP remain NULL
--    until /events discovery is run (phase 2).
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.ticketsdata_event_xref (
  event_id          bigint  NOT NULL,
  platform          text    NOT NULL CHECK (platform IN ('SH','VD','GT','TP')),
  aq_short_event_id text,                                 -- canonical key from aq_event_map
  event_url         text,                                 -- target URL; NULL = not yet discovered
  td_event_id       text,                                 -- their internal event ID (from /events, optional)
  active            boolean     NOT NULL DEFAULT true,
  always_on         boolean     NOT NULL DEFAULT false,   -- Knicks / operator-pinned events
  rank_score        numeric(8,4),                         -- from latest_event_metrics at last refresh
  last_enqueued_at  timestamptz,
  last_fetched_at   timestamptz,
  enqueues_today    int         NOT NULL DEFAULT 0,       -- reset each morning by td_watchlist_refresh
  match_method      text        NOT NULL DEFAULT 'direct_id',  -- direct_id | events_api | manual
  meta              jsonb       NOT NULL DEFAULT '{}'::jsonb,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (event_id, platform)
);

CREATE INDEX IF NOT EXISTS idx_td_xref_active_rank
  ON public.ticketsdata_event_xref (rank_score DESC NULLS LAST)
  WHERE active = true;

CREATE INDEX IF NOT EXISTS idx_td_xref_active_platform
  ON public.ticketsdata_event_xref (platform, active)
  WHERE active = true AND event_url IS NOT NULL;

REVOKE ALL ON public.ticketsdata_event_xref FROM anon, authenticated;
ALTER TABLE public.ticketsdata_event_xref ENABLE ROW LEVEL SECURITY;
CREATE POLICY td_xref_service_only ON public.ticketsdata_event_xref
  FOR ALL TO service_role USING (true);


-- ─────────────────────────────────────────────────────────────────────────────
-- 2. td_pull_queue
--    One row per pending/completed async fetch. request_id is the pg_net
--    request identifier; td_normalize_drain JOINs net._http_response on
--    h.id = request_id to retrieve status_code + content.
--    event_url stored at enqueue time (no creds — API URL is constructed at fire).
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.td_pull_queue (
  id            bigserial   PRIMARY KEY,
  event_id      bigint      NOT NULL,
  platform      text        NOT NULL CHECK (platform IN ('SH','VD','GT','TP')),
  event_url     text        NOT NULL,               -- target marketplace URL (no creds)
  interval_tag  text,                               -- '12pm'|'4pm'|'8pm'|'11pm'
  request_id    bigint,                             -- pg_net request ID (set at fire)
  fired_at      timestamptz,
  resolved_at   timestamptz,
  status_code   int,
  credits_used  int         NOT NULL DEFAULT 0,
  retry_count   int         NOT NULL DEFAULT 0,
  error_msg     text,
  rows_inserted int,
  created_at    timestamptz NOT NULL DEFAULT now()
);

-- Drain lookup: unresolved rows with a fired request
CREATE INDEX IF NOT EXISTS idx_td_queue_unresolved
  ON public.td_pull_queue (fired_at)
  WHERE resolved_at IS NULL AND request_id IS NOT NULL;

-- Enqueue lookup: unfired rows
CREATE INDEX IF NOT EXISTS idx_td_queue_unfired
  ON public.td_pull_queue (created_at)
  WHERE fired_at IS NULL;

-- Pileup guard: unresolved check per (event, platform)
CREATE INDEX IF NOT EXISTS idx_td_queue_event_platform_active
  ON public.td_pull_queue (event_id, platform)
  WHERE resolved_at IS NULL;

REVOKE ALL ON public.td_pull_queue FROM anon, authenticated;
ALTER TABLE public.td_pull_queue ENABLE ROW LEVEL SECURITY;
CREATE POLICY td_queue_service_only ON public.td_pull_queue
  FOR ALL TO service_role USING (true);


-- ─────────────────────────────────────────────────────────────────────────────
-- 3. ticketsdata_credit_usage
--    One row per API call. Replaces the ticketsdata_credit_ledger counter approach
--    with a fine-grained audit log. td_credits_today() SUMs from this table.
--    quota_remaining echoes the value returned by the API in each response —
--    watch the minimum daily value for plan-exhaustion early warning.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.ticketsdata_credit_usage (
  id              bigserial   PRIMARY KEY,
  called_at       timestamptz NOT NULL DEFAULT now(),
  event_id        bigint,
  platform        text,
  endpoint        text        NOT NULL DEFAULT '/fetch',  -- '/fetch' | '/events'
  credits         int         NOT NULL DEFAULT 1,
  status_code     int,
  quota_remaining int,                                    -- from API response (top-level field)
  error_msg       text
);

-- Index on date for fast td_credits_today() aggregation
CREATE INDEX IF NOT EXISTS idx_td_credit_usage_day
  ON public.ticketsdata_credit_usage (((called_at AT TIME ZONE 'UTC')::date));

REVOKE ALL ON public.ticketsdata_credit_usage FROM anon, authenticated;
ALTER TABLE public.ticketsdata_credit_usage ENABLE ROW LEVEL SECURITY;
CREATE POLICY td_credit_service_only ON public.ticketsdata_credit_usage
  FOR ALL TO service_role USING (true);


-- ─────────────────────────────────────────────────────────────────────────────
-- 4. ticketsdata_listings_snapshots
--    One row per listing per fetch. Content-deduped via UNIQUE on
--    (event_id, platform, content_hash) so re-fetching the same listing does
--    not create phantom rows. is_parking stored for UI filtering (not discarded).
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.ticketsdata_listings_snapshots (
  id              bigserial   PRIMARY KEY,
  event_id        bigint      NOT NULL,
  platform        text        NOT NULL,
  captured_at     timestamptz NOT NULL DEFAULT now(),
  td_listing_id   text,
  section         text,
  row             text,
  quantity        int,
  list_price      numeric,
  price_with_fees numeric,
  is_parking      boolean     NOT NULL DEFAULT false,
  content_hash    text        NOT NULL,   -- md5(raw::text)
  raw             jsonb,
  CONSTRAINT ticketsdata_listings_dedup
    UNIQUE (event_id, platform, content_hash)
);

CREATE INDEX IF NOT EXISTS idx_td_ls_event_platform_cap
  ON public.ticketsdata_listings_snapshots (event_id, platform, captured_at DESC);

-- TTL sweep index — prune rows older than 30 days
CREATE INDEX IF NOT EXISTS idx_td_ls_captured_at
  ON public.ticketsdata_listings_snapshots (captured_at);

REVOKE ALL ON public.ticketsdata_listings_snapshots FROM anon, authenticated;
ALTER TABLE public.ticketsdata_listings_snapshots ENABLE ROW LEVEL SECURITY;
CREATE POLICY td_ls_service_only ON public.ticketsdata_listings_snapshots
  FOR ALL TO service_role USING (true);


-- ─────────────────────────────────────────────────────────────────────────────
-- 5. v_ticketsdata_credit_usage_daily
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE VIEW public.v_ticketsdata_credit_usage_daily AS
SELECT
  (called_at AT TIME ZONE 'UTC')::date                              AS day,
  endpoint,
  count(*)                                                          AS calls,
  sum(credits)                                                      AS credits_used,
  min(quota_remaining) FILTER (WHERE quota_remaining IS NOT NULL)   AS quota_remaining_min,
  max(quota_remaining) FILTER (WHERE quota_remaining IS NOT NULL)   AS quota_remaining_max
FROM public.ticketsdata_credit_usage
GROUP BY 1, 2;

-- REVOKE not needed on views — underlying table denies anon/authenticated.


-- ─────────────────────────────────────────────────────────────────────────────
-- 6. ticketsdata_normalize_listings(p_platform, p_content)
--    Parses the raw /fetch response body into a normalized offer shape.
--    All four platform-specific schemas handled in one function.
--
--    Response envelope (all platforms): {status, platform, body, response_s, quota_remaining}
--    quota_remaining is top-level; platform data is under 'body'.
--
--    Field paths per platform (D0 empirically confirmed for SH; others from D0's live tests):
--      SH  → body.items[]         {listingId, section, row, availableTickets, rawPrice, priceWithFees}
--      VD  → body.items.offers[]  {listingId, section, row, availableTickets, rawPrice, rawPriceWithFees}
--      GT  → body[]               {listing_id, section_name, row, quantity, price:{prefee,total} in CENTS}
--      TP  → body.items.offers[]  {listing_id, section_name|section_id, row, quantity, price, fees:{...}}
--
--    ⚠️ VALIDATE VD + GT + TP body paths against D0's ticketsdata_client.py live responses
--       before these platforms go live. SH paths are 200-tested. GT prices are in CENTS ÷ 100.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.ticketsdata_normalize_listings(
  p_platform text,
  p_content  jsonb
)
RETURNS TABLE (
  td_listing_id   text,
  section         text,
  "row"           text,
  quantity        int,
  list_price      numeric,
  price_with_fees numeric,
  is_parking      boolean,
  raw             jsonb
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
BEGIN
  CASE p_platform

    -- ── StubHub ─────────────────────────────────────────────────────────────
    WHEN 'SH' THEN
      RETURN QUERY
      SELECT
        (item->>'listingId')::text,
        item->>'section',
        item->>'row',
        (item->>'availableTickets')::int,
        (item->>'rawPrice')::numeric,
        (item->>'priceWithFees')::numeric,
        false::boolean,
        item
      FROM jsonb_array_elements(p_content->'body'->'items') AS item;

    -- ── VividSeats ───────────────────────────────────────────────────────────
    WHEN 'VD' THEN
      RETURN QUERY
      SELECT
        (offer->>'listingId')::text,
        offer->>'section',
        offer->>'row',
        (offer->>'availableTickets')::int,
        (offer->>'rawPrice')::numeric,
        (offer->>'rawPriceWithFees')::numeric,
        false::boolean,
        offer
      FROM jsonb_array_elements(p_content->'body'->'items'->'offers') AS offer;

    -- ── Gametime ─────────────────────────────────────────────────────────────
    -- Prices are in CENTS — divide by 100 to get dollars.
    -- ticket_type = 'parking' or 'PARKING' flags parking listings.
    WHEN 'GT' THEN
      RETURN QUERY
      SELECT
        (item->>'listing_id')::text,
        item->>'section_name',
        item->>'row',
        (item->>'quantity')::int,
        (((item->'price'->>'prefee')::numeric) / 100.0),
        (((item->'price'->>'total')::numeric)  / 100.0),
        (lower(COALESCE(item->>'ticket_type', '')) = 'parking')::boolean,
        item
      FROM jsonb_array_elements(p_content->'body') AS item;

    -- ── TickPick ─────────────────────────────────────────────────────────────
    WHEN 'TP' THEN
      RETURN QUERY
      SELECT
        (offer->>'listing_id')::text,
        COALESCE(offer->>'section_name', offer->>'section_id'),
        offer->>'row',
        (offer->>'quantity')::int,
        (offer->>'price')::numeric,
        -- Total = price + service fee + facility fee + delivery fee
        (  COALESCE((offer->>'price')::numeric,                      0)
         + COALESCE((offer->'fees'->>'service')::numeric,            0)
         + COALESCE((offer->'fees'->>'facility')::numeric,           0)
         + COALESCE((offer->'fees'->>'delivery')::numeric,           0)
        ),
        COALESCE((offer->>'is_parking')::boolean, false),
        offer
      FROM jsonb_array_elements(p_content->'body'->'items'->'offers') AS offer;

    ELSE
      RAISE EXCEPTION 'ticketsdata_normalize_listings: unknown platform %', p_platform;

  END CASE;
END $$;

REVOKE ALL ON FUNCTION public.ticketsdata_normalize_listings(text, jsonb) FROM anon, public;
COMMENT ON FUNCTION public.ticketsdata_normalize_listings(text, jsonb) IS
  'Parses raw TicketsData /fetch response into normalized offer rows. '
  'VD/GT/TP body paths should be validated against live responses (D0 ticketsdata_client.py on claude/resume-d0-chat-itUGb).';


-- ─────────────────────────────────────────────────────────────────────────────
-- 7. td_credits_today() — today's total credits charged (UTC day)
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.td_credits_today()
RETURNS integer
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
  SELECT COALESCE(
    SUM(credits)::int,
    0
  )
  FROM public.ticketsdata_credit_usage
  WHERE (called_at AT TIME ZONE 'UTC')::date = CURRENT_DATE;
$$;

REVOKE ALL ON FUNCTION public.td_credits_today() FROM anon, public;


-- ─────────────────────────────────────────────────────────────────────────────
-- 8. td_budget_ok() — true if today's credit spend is under the daily cap
--    RULE 0: if plan changes (Starter → Pro), update the 333 cap here.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.td_budget_ok()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
  SELECT public.td_credits_today() < 333;  -- STARTER PLAN HARD CAP: 10k/mo ÷ 30d
$$;

REVOKE ALL ON FUNCTION public.td_budget_ok() FROM anon, public;


-- ─────────────────────────────────────────────────────────────────────────────
-- 9. td_charge_credit(...) — log one API call to ticketsdata_credit_usage
--    Called by td_normalize_drain after a successful 200 response.
--    All parameters after p_n are optional context for the audit trail.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.td_charge_credit(
  p_n              integer  DEFAULT 1,
  p_event_id       bigint   DEFAULT NULL,
  p_platform       text     DEFAULT NULL,
  p_endpoint       text     DEFAULT '/fetch',
  p_status_code    integer  DEFAULT NULL,
  p_quota_remaining integer DEFAULT NULL
)
RETURNS void
LANGUAGE sql
VOLATILE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
  INSERT INTO public.ticketsdata_credit_usage
    (credits, event_id, platform, endpoint, status_code, quota_remaining)
  VALUES
    (p_n, p_event_id, p_platform, p_endpoint, p_status_code, p_quota_remaining);
$$;

REVOKE ALL ON FUNCTION public.td_charge_credit(integer, bigint, text, text, integer, integer)
  FROM anon, public;

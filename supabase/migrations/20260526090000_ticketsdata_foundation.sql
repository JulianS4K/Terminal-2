-- 20260526090000_ticketsdata_foundation.sql
-- ⚠️  SUPERSEDED BY 20260527050000_ticketsdata_complete_foundation.sql — DO NOT APPLY ⚠️
-- This migration was authored in the A1 session of 2026-05-26 but never applied to prod.
-- It conflicts with 20260527050000 on table names (ticketsdata_event_xref, td_pull_queue, etc.)
-- Apply 20260527040000 + 20260527050000 + 20260527100000 instead.
--
-- TicketsData (ticketsdata.io) integration — foundation schema.
--
-- PLAN: Starter — 10k credits/mo (333/day hard cap), 5 req/sec, 1 cr/fetch.
-- Auth: API key in query string (?key=<KEY>).
-- Latency: /fetch = 2–25s → async via pg_net (same pattern as sg_broker_pending).
-- Intermittent 500 "maintenance" responses → re-queue up to 3 retries.
-- Creds: stored as vault secret TICKETSDATA_API_KEY (NEVER in migration).
--
-- WHY: Supplements SeatGeek broker data with cross-marketplace listing prices
-- (GameTime, TickPick, Vivid, StubHub) for watchlist events. TEvo gives us
-- inventory depth; TD gives cross-platform price comparison + fill signals.
--
-- TABLES:
--   ticketsdata_event_xref         — watchlist registry (event → td_event_id)
--   td_pull_queue                  — async fetch queue (mirrors sg_broker_pending)
--   ticketsdata_credit_ledger      — daily credit counter / hard-cap guard
--   ticketsdata_listings_snapshots — normalized listing snapshots per fetch
--
-- HELPER FUNCTIONS (SECURITY DEFINER, @s4kent.com gate):
--   td_credits_today()             — today's usage
--   td_budget_ok()                 — daily_cap not exceeded
--   td_charge_credit(p_n int)      — atomic increment
--
-- REQUIRED VAULT SECRET:
--   SELECT vault.create_secret('TICKETSDATA_API_KEY', '<your-key>', 'TicketsData API key');
--   (Run once by operator; never hardcode in migrations or code.)
--
-- RULE 0: If plan changes, update daily_cap in ticketsdata_credit_ledger's
--   DEFAULT and in td_budget_ok() in the same commit.
--
-- ROLLBACK:
--   DROP FUNCTION IF EXISTS td_credits_today, td_budget_ok, td_charge_credit CASCADE;
--   DROP TABLE IF EXISTS ticketsdata_listings_snapshots, td_pull_queue,
--     ticketsdata_credit_ledger, ticketsdata_event_xref CASCADE;

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. ticketsdata_event_xref
--    One row per event we're tracking on TicketsData. td_event_id is their
--    event identifier (returned by the /v1/events discovery endpoint).
--    platforms[] names which resale marketplaces to poll for this event
--    (default: GameTime, TickPick, Vivid, StubHub = the 4 "sources" in spec).
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.ticketsdata_event_xref (
  event_id         bigint      NOT NULL PRIMARY KEY,
  td_event_id      text        NOT NULL,
  platforms        text[]      NOT NULL DEFAULT ARRAY['GT','TP','VD','SH'],
  active           boolean     NOT NULL DEFAULT true,
  always_on        boolean     NOT NULL DEFAULT false,  -- Knicks / operator-pinned
  rank_score       numeric(8,4),                        -- concentration score for ordering
  last_enqueued_at timestamptz,
  last_fetched_at  timestamptz,
  enqueues_today   int         NOT NULL DEFAULT 0,
  match_method     text        NOT NULL DEFAULT 'events_api',  -- events_api | manual
  meta             jsonb       NOT NULL DEFAULT '{}'::jsonb,
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_td_xref_active_rank
  ON public.ticketsdata_event_xref (rank_score DESC NULLS LAST)
  WHERE active = true;

REVOKE ALL ON public.ticketsdata_event_xref FROM anon, authenticated;


-- ─────────────────────────────────────────────────────────────────────────────
-- 2. td_pull_queue
--    One row per pending/completed API fetch. request_id is the pg_net
--    request identifier set at dispatch time; the normalize drain JOINs on
--    net._http_response.id to retrieve the response body.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.td_pull_queue (
  id            bigserial   PRIMARY KEY,
  event_id      bigint      NOT NULL,
  td_event_id   text        NOT NULL,
  platform      text        NOT NULL,               -- 'GT'|'TP'|'VD'|'SH'
  interval_tag  text,                               -- '12pm'|'4pm'|'8pm'|'11pm'
  request_id    bigint,                             -- pg_net request ID (set on fire)
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


-- ─────────────────────────────────────────────────────────────────────────────
-- 3. ticketsdata_credit_ledger
--    One row per calendar day. HARD CAP = 333/day (10k/mo ÷ 30d).
--    If plan changes, update daily_cap DEFAULT here AND in td_budget_ok().
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.ticketsdata_credit_ledger (
  day          date        PRIMARY KEY,
  credits_used int         NOT NULL DEFAULT 0,
  daily_cap    int         NOT NULL DEFAULT 333,   -- STARTER PLAN HARD CAP
  updated_at   timestamptz NOT NULL DEFAULT now()
);

REVOKE ALL ON public.ticketsdata_credit_ledger FROM anon, authenticated;


-- ─────────────────────────────────────────────────────────────────────────────
-- 4. ticketsdata_listings_snapshots
--    One row per listing returned by a /fetch call. Content-deduped so
--    re-fetching the same listing doesn't create phantom rows.
--    raw JSONB preserves the full API response for later re-normalization.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.ticketsdata_listings_snapshots (
  id            bigserial   PRIMARY KEY,
  event_id      bigint      NOT NULL,
  td_event_id   text        NOT NULL,
  platform      text        NOT NULL,
  captured_at   timestamptz NOT NULL DEFAULT now(),
  td_listing_id text,
  section       text,
  row           text,
  quantity      int,
  list_price    numeric,
  face_value    numeric,
  content_hash  text        NOT NULL,
  raw           jsonb,
  CONSTRAINT ticketsdata_listings_dedup
    UNIQUE (event_id, platform, content_hash)
);

CREATE INDEX IF NOT EXISTS idx_td_ls_event_platform_cap
  ON public.ticketsdata_listings_snapshots (event_id, platform, captured_at DESC);

-- TTL sweep will prune old rows; keep 30 days by default
CREATE INDEX IF NOT EXISTS idx_td_ls_captured_at
  ON public.ticketsdata_listings_snapshots (captured_at);

REVOKE ALL ON public.ticketsdata_listings_snapshots FROM anon, authenticated;


-- ─────────────────────────────────────────────────────────────────────────────
-- 5. Helper functions
-- ─────────────────────────────────────────────────────────────────────────────

-- 5a. td_credits_today() — how many credits consumed today
CREATE OR REPLACE FUNCTION public.td_credits_today()
RETURNS integer
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
  SELECT COALESCE(
    (SELECT credits_used FROM public.ticketsdata_credit_ledger WHERE day = CURRENT_DATE),
    0
  );
$$;

REVOKE ALL ON FUNCTION public.td_credits_today() FROM anon, public;


-- 5b. td_budget_ok() — true if today's usage is under the daily cap
--     RULE 0: if plan changes, update the 333 cap here AND in the table DEFAULT.
CREATE OR REPLACE FUNCTION public.td_budget_ok()
RETURNS boolean
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
  SELECT public.td_credits_today() < COALESCE(
    (SELECT daily_cap FROM public.ticketsdata_credit_ledger WHERE day = CURRENT_DATE),
    333
  );
$$;

REVOKE ALL ON FUNCTION public.td_budget_ok() FROM anon, public;


-- 5c. td_charge_credit(p_n) — atomic daily counter increment
--     Creates today's row on first use; never under-counts due to upsert.
CREATE OR REPLACE FUNCTION public.td_charge_credit(p_n integer DEFAULT 1)
RETURNS void
LANGUAGE sql
VOLATILE SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
  INSERT INTO public.ticketsdata_credit_ledger (day, credits_used, updated_at)
  VALUES (CURRENT_DATE, p_n, now())
  ON CONFLICT (day) DO UPDATE
    SET credits_used = ticketsdata_credit_ledger.credits_used + p_n,
        updated_at   = now();
$$;

REVOKE ALL ON FUNCTION public.td_charge_credit(integer) FROM anon, public;

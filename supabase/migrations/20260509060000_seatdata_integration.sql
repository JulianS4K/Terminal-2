-- SeatData integration — second pricing source alongside TEvo.
-- Applied to prod 2026-05-09; this file captures it for git parity.
--
-- Why: TEvo gives us the live tickets-for-sale book (listings + retail
-- ask). SeatData adds two complementary primitives:
--   1. SOLD-LISTINGS HISTORY — actual transaction prices over time
--      (`/v0.3/salesdata/get`). TEvo doesn't expose sold data; we've
--      been inferring it from inventory deltas, which is approximate.
--   2. CROSS-MARKET FILL RATE — SeatData's event_stats time series
--      includes `listing_fill_rate` (sold / total ever listed) and
--      multi-marketplace get-in. Useful as a cross-check on TEvo-only
--      pricing signals.
--
-- Plan: BASIC TIER, hard-capped to prevent runaway charges. Three
-- endpoints consume billed pulls:
--   /v0.3/salesdata/get               1 pull/event
--   /v0.1.1/listings/get              1 pull/event (free when no refresh)
--   /v1/events/{id}/stats             1 pull/event (free on freshness rule)
-- Everything else (search, account, usage, daily CSV, async event-add)
-- is free at any subscription tier.
--
-- Budget enforcement:
--   * Daily cap   : 100 paid pulls / 24h rolling window
--   * Monthly cap : 2000 paid pulls / billing month
--   * Both caps are HARD-CODED at the DB level. Going over requires
--     bumping the values explicitly in this migration AND in
--     seatdata_client.py — two-key change so accidents are unlikely.
--   * Per RULE 0: if we move plans, both numbers + this comment
--     must be updated in the same commit.
--
-- Schema additions:
--   seatdata_event_xref          - TEvo event_id <-> SeatData event_id mapping
--   seatdata_pull_budget         - daily counter + cap, reset by date
--   seatdata_sales_snapshots     - history from /v0.3/salesdata/get
--   seatdata_listings_snapshots  - history from /v0.1.1/listings/get
--   seatdata_event_stats         - history from /v1/events/{id}/stats
--   seatdata_pull_log            - audit trail of every call (paid+free)
--
-- Functions:
--   seatdata_check_budget(p_endpoint text)
--     -> JSONB { allowed bool, used int, daily_cap int, monthly_used int,
--                monthly_cap int, reason text|null }
--   seatdata_increment_budget(p_endpoint text)
--     -> void (idempotent atomic increment for paid endpoints)

BEGIN;

-- 1. xref between TEvo events and SeatData events. One TEvo event -> one
--    SeatData event_id. Like event_xref for ESPN.
CREATE TABLE IF NOT EXISTS seatdata_event_xref (
  tevo_event_id     bigint PRIMARY KEY,
  sd_event_id       bigint NOT NULL,
  sd_tm_event_id    text,
  sd_std_event_id   bigint,
  sd_std_venue_id   bigint,
  matched_at        timestamptz NOT NULL DEFAULT NOW(),
  match_method      text NOT NULL DEFAULT 'manual',  -- manual | auto_name_date_venue | auto_tm_id
  match_confidence  numeric,
  meta              jsonb DEFAULT '{}'::jsonb,
  last_paid_pull_at timestamptz,
  last_refresh_ts   timestamptz
);
CREATE INDEX IF NOT EXISTS idx_sd_xref_sd_event ON seatdata_event_xref(sd_event_id);

-- 2. Pull budget counter. One row per UTC date. Service role increments
--    atomically before each paid call.
CREATE TABLE IF NOT EXISTS seatdata_pull_budget (
  day             date PRIMARY KEY,
  paid_pulls      int NOT NULL DEFAULT 0,
  free_calls      int NOT NULL DEFAULT 0,
  daily_cap       int NOT NULL DEFAULT 100,    -- BASIC PLAN HARD CAP
  monthly_cap     int NOT NULL DEFAULT 2000,   -- BASIC PLAN HARD CAP
  updated_at      timestamptz NOT NULL DEFAULT NOW()
);

-- 3. Sales snapshots — store every row returned by /v0.3/salesdata/get.
--    SeatData returns historical sold listings; we dedupe via content_hash
--    so re-pulling the same event over time only adds genuinely new rows.
CREATE TABLE IF NOT EXISTS seatdata_sales_snapshots (
  id              bigserial PRIMARY KEY,
  tevo_event_id   bigint NOT NULL,
  sd_event_id     bigint NOT NULL,
  pulled_at       timestamptz NOT NULL DEFAULT NOW(),
  sale_timestamp  timestamptz NOT NULL,           -- from response.timestamp (unix epoch -> ts)
  quantity        int,
  price           numeric,
  zone            text,
  section         text,
  row             text,
  content_hash    text NOT NULL,
  CONSTRAINT seatdata_sales_dedup UNIQUE (tevo_event_id, content_hash)
);
CREATE INDEX IF NOT EXISTS idx_sd_sales_event_ts
  ON seatdata_sales_snapshots(tevo_event_id, sale_timestamp);

-- 4. Listings snapshots — from /v0.1.1/listings/get. Each pull is a full
--    state snapshot; we store one row per (pull_id, listing_id).
CREATE TABLE IF NOT EXISTS seatdata_listings_snapshots (
  id              bigserial PRIMARY KEY,
  tevo_event_id   bigint NOT NULL,
  sd_event_id     bigint NOT NULL,
  pulled_at       timestamptz NOT NULL DEFAULT NOW(),
  refresh_ts      timestamptz,                    -- from response.last_refresh_timestamp
  has_refreshed   boolean,                        -- false = unchanged since last pull (free)
  sd_listing_id   bigint NOT NULL,
  active          boolean,
  zone            text,
  section         text,
  row             text,
  quantity_start  int,
  quantity        int,
  price           numeric,
  content_hash    text NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_sd_listings_event_pull
  ON seatdata_listings_snapshots(tevo_event_id, pulled_at);
CREATE INDEX IF NOT EXISTS idx_sd_listings_listing
  ON seatdata_listings_snapshots(sd_listing_id, pulled_at);

-- 5. Event stats snapshots — from /v1/events/{id}/stats. The response
--    embeds zones inline; we flatten to one row per snapshot AND store
--    the zones JSON for full fidelity.
CREATE TABLE IF NOT EXISTS seatdata_event_stats (
  id                    bigserial PRIMARY KEY,
  tevo_event_id         bigint NOT NULL,
  sd_event_id           bigint NOT NULL,
  pulled_at             timestamptz NOT NULL DEFAULT NOW(),
  snapshot_ts           timestamptz NOT NULL,            -- response.data[].timestamp
  total_listings_all    int,
  total_listings_active int,
  listing_fill_rate     numeric,                          -- sold / total ever listed
  avg_price             numeric,
  median_price          numeric,
  get_in                numeric,
  get_in_qty2plus       numeric,
  zones                 jsonb,                            -- per-zone breakdown
  content_hash          text NOT NULL,
  CONSTRAINT seatdata_stats_dedup UNIQUE (tevo_event_id, snapshot_ts)
);
CREATE INDEX IF NOT EXISTS idx_sd_stats_event_ts
  ON seatdata_event_stats(tevo_event_id, snapshot_ts);

-- 6. Pull log — audit trail of every call. Helps debug billing surprises
--    and catches misconfigured retry loops.
CREATE TABLE IF NOT EXISTS seatdata_pull_log (
  id              bigserial PRIMARY KEY,
  called_at       timestamptz NOT NULL DEFAULT NOW(),
  endpoint        text NOT NULL,                  -- e.g. 'v0.3/salesdata/get'
  tevo_event_id   bigint,
  sd_event_id     bigint,
  was_charged     boolean NOT NULL,
  http_status     int,
  rows_returned   int,
  error_message   text,
  request_meta    jsonb DEFAULT '{}'::jsonb
);
CREATE INDEX IF NOT EXISTS idx_sd_log_called_at ON seatdata_pull_log(called_at DESC);
CREATE INDEX IF NOT EXISTS idx_sd_log_event ON seatdata_pull_log(tevo_event_id, called_at);

-- 7. Budget check function. Returns whether a paid call is allowed,
--    plus the current usage so the client can surface "X / 100 today".
CREATE OR REPLACE FUNCTION public.seatdata_check_budget(p_endpoint text DEFAULT 'paid')
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
  v_today date := (NOW() AT TIME ZONE 'UTC')::date;
  v_row seatdata_pull_budget%ROWTYPE;
  v_monthly_used int;
  v_monthly_cap int;
  v_daily_cap int;
BEGIN
  -- Ensure today's row exists
  INSERT INTO seatdata_pull_budget(day) VALUES (v_today)
  ON CONFLICT (day) DO NOTHING;

  SELECT * INTO v_row FROM seatdata_pull_budget WHERE day = v_today FOR SHARE;

  v_daily_cap := v_row.daily_cap;
  v_monthly_cap := v_row.monthly_cap;

  -- Sum monthly usage from same-month rows
  SELECT COALESCE(SUM(paid_pulls), 0) INTO v_monthly_used
  FROM seatdata_pull_budget
  WHERE date_trunc('month', day) = date_trunc('month', v_today);

  IF v_row.paid_pulls >= v_daily_cap THEN
    RETURN jsonb_build_object(
      'allowed', false, 'used', v_row.paid_pulls, 'daily_cap', v_daily_cap,
      'monthly_used', v_monthly_used, 'monthly_cap', v_monthly_cap,
      'reason', 'daily_cap_exhausted'
    );
  END IF;

  IF v_monthly_used >= v_monthly_cap THEN
    RETURN jsonb_build_object(
      'allowed', false, 'used', v_row.paid_pulls, 'daily_cap', v_daily_cap,
      'monthly_used', v_monthly_used, 'monthly_cap', v_monthly_cap,
      'reason', 'monthly_cap_exhausted'
    );
  END IF;

  RETURN jsonb_build_object(
    'allowed', true, 'used', v_row.paid_pulls, 'daily_cap', v_daily_cap,
    'monthly_used', v_monthly_used, 'monthly_cap', v_monthly_cap,
    'reason', NULL
  );
END $$;

GRANT EXECUTE ON FUNCTION public.seatdata_check_budget(text) TO authenticated, service_role;

-- 8. Increment budget on a successful paid pull. Atomic.
CREATE OR REPLACE FUNCTION public.seatdata_increment_budget(p_endpoint text, p_was_charged boolean)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  v_today date := (NOW() AT TIME ZONE 'UTC')::date;
BEGIN
  INSERT INTO seatdata_pull_budget(day) VALUES (v_today)
  ON CONFLICT (day) DO NOTHING;

  IF p_was_charged THEN
    UPDATE seatdata_pull_budget
    SET paid_pulls = paid_pulls + 1, updated_at = NOW()
    WHERE day = v_today;
  ELSE
    UPDATE seatdata_pull_budget
    SET free_calls = free_calls + 1, updated_at = NOW()
    WHERE day = v_today;
  END IF;
END $$;

GRANT EXECUTE ON FUNCTION public.seatdata_increment_budget(text, boolean) TO service_role;

-- 9. Convenience view: latest snapshot per linked event for the broker
--    terminal to glance at.
CREATE OR REPLACE VIEW public.seatdata_event_latest AS
SELECT
  x.tevo_event_id,
  x.sd_event_id,
  x.last_paid_pull_at,
  (SELECT jsonb_build_object(
     'snapshot_ts', s.snapshot_ts,
     'avg_price', s.avg_price, 'median_price', s.median_price,
     'get_in', s.get_in, 'get_in_qty2plus', s.get_in_qty2plus,
     'fill_rate', s.listing_fill_rate,
     'total_listings_active', s.total_listings_active,
     'total_listings_all', s.total_listings_all
   ) FROM seatdata_event_stats s
   WHERE s.tevo_event_id = x.tevo_event_id
   ORDER BY s.snapshot_ts DESC LIMIT 1) AS latest_stats,
  (SELECT COUNT(*) FROM seatdata_sales_snapshots ss
   WHERE ss.tevo_event_id = x.tevo_event_id) AS sales_rows,
  (SELECT MAX(sale_timestamp) FROM seatdata_sales_snapshots ss
   WHERE ss.tevo_event_id = x.tevo_event_id) AS last_sale_at
FROM seatdata_event_xref x;

GRANT SELECT ON public.seatdata_event_latest TO authenticated, service_role;

COMMIT;

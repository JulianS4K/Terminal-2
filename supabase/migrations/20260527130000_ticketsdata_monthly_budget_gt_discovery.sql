-- 20260527130000_ticketsdata_monthly_budget_gt_discovery.sql
--
-- Comprehensive TicketsData subsystem update. Supersedes partial fixes in 120000.
--
-- CONFIRMED BUGS FIXED (from live test responses 2026-05-27):
--   VD path:  p_content->'body'->'items'->'offers'  →  p_content->'items'->'offers'
--             VD response has NO 'body' wrapper (reqs 244938-244942 confirmed).
--   GT price: remove /100.0 — GT /fetch prices are in DOLLARS (prefee=69=$69, reqs 244943-244947).
--   SH price: rawPrice fix already in 20260527120000 — carried forward here.
--
-- CHANGES:
--   1.  td_normalize_section(text)      — strip word prefixes from VD section strings
--                                          "Bleacher 237" → "237", "Grandstand Infield 420A" → "420A"
--   2.  Drop TP from platform check     — TP permanently blocked (CDN/bot-protection confirmed dead)
--   3.  owned_tickets + median_retail_price on ticketsdata_event_xref
--   4.  td_gt_performers table          — GT performer URL registry for /events discovery
--   5.  td_api_platform()               — remove TP
--   6.  ticketsdata_normalize_listings()— fix VD path, fix GT prices, add section normalization
--   7.  td_credits_this_month()         — monthly credit counter (replaces td_credits_today)
--   8.  td_monthly_budget_ok()          — < 9000/month hard cap (replaces td_budget_ok)
--   9.  td_watchlist_refresh()          — populate owned_tickets/median_retail_price; remove TP loop
--  10.  td_enqueue_peak(p_platform)     — per-platform scoped; monthly budget; priority ordering
--  11.  td_pull_drain()                 — monthly budget gate
--  12.  td_normalize_drain()            — monthly budget gate
--  13.  td_pending_sweep()              — remove TP deactivation
--  14.  td_gt_discover()               — fires GT /events per performer (daily 9:15 UTC)
--  15.  td_gt_discover_drain()         — parses /events responses → upserts xref with seo_url
--  16.  Cron changes: drop td_enqueue_peak, add 3 per-platform staggered crons
--                     add td_gt_discover + td_gt_discover_drain daily crons
--  17.  cron_policy: remove td_enqueue_peak, add SH/VD/GT + discover entries
--  18.  Re-enable all TD crons (cron_policy.enabled = true)
--
-- MONTHLY BUDGET: 9,000 production credits/month (Starter plan 10,000 − 1,000 test reserve).
--   Resets on the 1st of each calendar month UTC.
--   td_monthly_budget_ok() = td_credits_this_month() < 9000.
--
-- STAGGERED CRON SCHEDULE:
--   td_enqueue_peak_sh  '0 15,18,21,0 * * *'    (11am/2pm/5pm/8pm ET)
--   td_enqueue_peak_vd  '45 15,18,21,0 * * *'   (11:45am/2:45pm/5:45pm/8:45pm ET)
--   td_enqueue_peak_gt  '30 16,19,22,1 * * *'   (12:30pm/3:30pm/6:30pm/9:30pm ET)
--   td_gt_discover      '15 9 * * *'             (9:15 UTC, right after watchlist refresh)
--   td_gt_discover_drain '20 9 * * *'            (9:20 UTC, 5 min after discover fires)
--
-- GT DISCOVERY SEED: 4 confirmed MLB performer slugs (validated 2026-05-27):
--   mlbnyy = Yankees · mlbnym = Mets · mlbphi = Phillies · mlbtor = Blue Jays
--   Operator can INSERT additional rows into td_gt_performers to cover more teams.


-- ─────────────────────────────────────────────────────────────────────────────
-- 1. td_normalize_section — strip leading word prefix from section strings
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.td_normalize_section(p_section text)
RETURNS text
LANGUAGE sql
IMMUTABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
  -- Strips word prefixes from VD section strings like "Bleacher 237" → "237",
  -- "Grandstand Infield 420A" → "420A". Returns the input unchanged if it has
  -- no word+space prefix (e.g. "237", "101B", "GA" stay as-is).
  -- GT sections are already clean numbers so this is a no-op for GT.
  SELECT CASE
    WHEN p_section IS NULL         THEN NULL
    WHEN trim(p_section) ~ '^.*\s+\d'
    THEN regexp_replace(trim(p_section), '^.*\s+(\d+[A-Za-z]*)$', '\1')
    ELSE trim(p_section)
  END;
$$;

REVOKE ALL ON FUNCTION public.td_normalize_section(text) FROM anon, public;
COMMENT ON FUNCTION public.td_normalize_section(text) IS
  'Strips leading word prefix from section strings: "Bleacher 237"→"237", '
  '"Grandstand Infield 420A"→"420A". No-op for already-numeric sections.';


-- ─────────────────────────────────────────────────────────────────────────────
-- 2. Drop TP from platform constraint (TP permanently dead — CDN block confirmed)
-- ─────────────────────────────────────────────────────────────────────────────
DELETE FROM public.ticketsdata_event_xref WHERE platform = 'TP';

ALTER TABLE public.ticketsdata_event_xref
  DROP CONSTRAINT IF EXISTS ticketsdata_event_xref_platform_check;

ALTER TABLE public.ticketsdata_event_xref
  ADD CONSTRAINT ticketsdata_event_xref_platform_check
  CHECK (platform IN ('SH', 'VD', 'GT', 'TM'));


-- ─────────────────────────────────────────────────────────────────────────────
-- 3. Add owned_tickets + median_retail_price to ticketsdata_event_xref
--    Used for enqueue priority ordering (owned_tickets DESC, median_retail_price DESC)
-- ─────────────────────────────────────────────────────────────────────────────
ALTER TABLE public.ticketsdata_event_xref
  ADD COLUMN IF NOT EXISTS owned_tickets        integer,
  ADD COLUMN IF NOT EXISTS median_retail_price  numeric(10, 2);

COMMENT ON COLUMN public.ticketsdata_event_xref.owned_tickets IS
  'From event_metrics.owned_tickets_count at last td_watchlist_refresh. '
  'Used for enqueue priority ordering.';
COMMENT ON COLUMN public.ticketsdata_event_xref.median_retail_price IS
  'From event_metrics.retail_median at last td_watchlist_refresh. '
  'Used for enqueue priority ordering when owned_tickets is equal.';


-- ─────────────────────────────────────────────────────────────────────────────
-- 4. td_gt_performers — GT performer URL registry for /events discovery
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.td_gt_performers (
  id                           serial        PRIMARY KEY,
  performer_url                text          NOT NULL UNIQUE,
  performer_slug               text,
  team_name                    text,
  active                       boolean       NOT NULL DEFAULT true,
  -- pg_net request ID from last td_gt_discover() call; cleared by td_gt_discover_drain()
  pending_discover_request_id  bigint,
  last_discovered_at           timestamptz,
  created_at                   timestamptz   NOT NULL DEFAULT now(),
  updated_at                   timestamptz   NOT NULL DEFAULT now()
);

ALTER TABLE public.td_gt_performers ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.td_gt_performers FROM anon, authenticated;
CREATE POLICY "service_role only" ON public.td_gt_performers TO service_role USING (true);

-- Seed confirmed MLB performer slugs (all validated via /events probe 2026-05-27)
-- Add more rows (INSERT INTO td_gt_performers) to expand GT coverage.
INSERT INTO public.td_gt_performers (performer_url, performer_slug, team_name)
VALUES
  ('https://gametime.co/new-york-yankees-tickets/performers/mlbnyy',     'mlbnyy', 'New York Yankees'),
  ('https://gametime.co/new-york-mets-tickets/performers/mlbnym',        'mlbnym', 'New York Mets'),
  ('https://gametime.co/philadelphia-phillies-tickets/performers/mlbphi', 'mlbphi', 'Philadelphia Phillies'),
  ('https://gametime.co/toronto-blue-jays-tickets/performers/mlbtor',    'mlbtor', 'Toronto Blue Jays')
ON CONFLICT (performer_url) DO NOTHING;


-- ─────────────────────────────────────────────────────────────────────────────
-- 5. td_api_platform — remove TP (dead platform)
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.td_api_platform(p_code text)
RETURNS text
LANGUAGE sql
IMMUTABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
  SELECT CASE p_code
    WHEN 'SH' THEN 'stubhub'
    WHEN 'VD' THEN 'vividseats'
    WHEN 'GT' THEN 'gametime'
    WHEN 'TM' THEN 'ticketmaster'
    ELSE LOWER(p_code)
  END;
$$;

REVOKE ALL ON FUNCTION public.td_api_platform(text) FROM anon, public;
COMMENT ON FUNCTION public.td_api_platform(text) IS
  'Maps internal platform code to TicketsData API platform string. '
  'SH/VD/GT confirmed working 2026-05-27. TP removed (permanent CDN block).';


-- ─────────────────────────────────────────────────────────────────────────────
-- 6. ticketsdata_normalize_listings — full rebuild with all path + price fixes
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

    -- ── StubHub ──────────────────────────────────────────────────────────────
    -- Confirmed response (reqs 244933-244937 2026-05-27):
    --   body.items[]: listingId, section, row, availableTickets, rawPrice,
    --                 ticketClassName (for parking inference)
    -- SH sections: clean numbers only ("237","412") — td_normalize_section is a no-op.
    WHEN 'SH' THEN
      RETURN QUERY
      SELECT
        (item->>'listingId')::text,
        public.td_normalize_section(item->>'section'),
        item->>'row',
        (item->>'availableTickets')::int,
        (item->>'rawPrice')::numeric,
        (item->>'rawPrice')::numeric,   -- SH has no priceWithFees field
        (lower(COALESCE(item->>'ticketClassName', '')) LIKE '%parking%')::boolean,
        item
      FROM jsonb_array_elements(p_content->'body'->'items') AS item;

    -- ── VividSeats ────────────────────────────────────────────────────────────
    -- FIXED 2026-05-27: no 'body' wrapper in real VD responses (reqs 244938-244942).
    --   Actual structure: {status_code, event_id, items:{offers:[],...}, quota_remaining}
    --   OLD (broken): p_content->'body'->'items'->'offers'
    --   NEW (correct): p_content->'items'->'offers'
    -- VD sections: "Word(s) NNN" format ("Bleacher 237","Grandstand Infield 420A")
    --   td_normalize_section strips the word prefix.
    WHEN 'VD' THEN
      RETURN QUERY
      SELECT
        (offer->>'listingId')::text,
        public.td_normalize_section(offer->>'section'),
        offer->>'row',
        (offer->>'availableTickets')::int,
        (offer->>'rawPrice')::numeric,
        (offer->>'rawPriceWithFees')::numeric,
        false::boolean,
        offer
      FROM jsonb_array_elements(p_content->'items'->'offers') AS offer;

    -- ── GameTime ──────────────────────────────────────────────────────────────
    -- Confirmed response (reqs 244943-244947 2026-05-27):
    --   body is a direct array (no items wrapper).
    -- FIXED 2026-05-27: prices are in DOLLARS not cents (prefee=69=$69, total=80=$80).
    --   D0 annotated as cents (/100); live test shows face_value=36.75=$36.75 → dollars.
    --   OLD (broken): (/100.0) divisor on both prices
    --   NEW (correct): no divisor
    -- GT sections: already clean numbers ("412","101B") — td_normalize_section is a no-op.
    WHEN 'GT' THEN
      RETURN QUERY
      SELECT
        (item->>'listing_id')::text,
        public.td_normalize_section(item->>'section_name'),
        item->>'row',
        (item->>'quantity')::int,
        (item->'price'->>'prefee')::numeric,
        (item->'price'->>'total')::numeric,
        (lower(COALESCE(item->>'ticket_type', '')) = 'parking')::boolean,
        item
      FROM jsonb_array_elements(p_content->'body') AS item;

    -- ── Ticketmaster — STUB (url discovery blocked; xref rows active=false) ───
    WHEN 'TM' THEN
      RAISE NOTICE 'ticketsdata_normalize_listings: TM field paths TBD — returning 0 rows';
      RETURN;

    ELSE
      RAISE EXCEPTION 'ticketsdata_normalize_listings: unknown platform %', p_platform;

  END CASE;
END $$;

REVOKE ALL ON FUNCTION public.ticketsdata_normalize_listings(text, jsonb) FROM anon, public;
COMMENT ON FUNCTION public.ticketsdata_normalize_listings(text, jsonb) IS
  'Parses raw TicketsData /fetch JSON into normalized listing rows. '
  'SH: body.items[] · rawPrice (no priceWithFees field in real responses). '
  'VD: items.offers[] (FIXED: no body wrapper — reqs 244938-244942 2026-05-27). '
  'GT: body[] direct array · prices in DOLLARS (FIXED: not cents — reqs 244943-244947). '
  'Section normalization via td_normalize_section() strips VD word prefixes. '
  'TP removed; TM stub pending URL discovery.';


-- ─────────────────────────────────────────────────────────────────────────────
-- 7. td_credits_this_month() — monthly credit counter
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.td_credits_this_month()
RETURNS integer
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
  SELECT COALESCE(SUM(credits), 0)::integer
  FROM public.ticketsdata_credit_usage
  WHERE date_trunc('month', called_at AT TIME ZONE 'UTC')
      = date_trunc('month', CURRENT_TIMESTAMP AT TIME ZONE 'UTC');
$$;

REVOKE ALL ON FUNCTION public.td_credits_this_month() FROM anon, public;
COMMENT ON FUNCTION public.td_credits_this_month() IS
  'Total TicketsData credits consumed in the current calendar month (UTC). '
  'Starter plan quota resets on the 1st UTC. Used by td_monthly_budget_ok().';


-- ─────────────────────────────────────────────────────────────────────────────
-- 8. td_monthly_budget_ok() — hard cap 9,000 credits/month
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.td_monthly_budget_ok()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
  SELECT public.td_credits_this_month() < 9000;
  -- Hard cap: 9,000 production credits/month (10,000 plan − 1,000 test reserve).
  -- RULE: if plan upgrades, update this threshold and add a comment to the migration.
$$;

REVOKE ALL ON FUNCTION public.td_monthly_budget_ok() FROM anon, public;
COMMENT ON FUNCTION public.td_monthly_budget_ok() IS
  'Returns true if monthly production budget (9,000 credits) not yet exhausted. '
  'All TD enqueue + pull functions gate on this. '
  'td_credits_this_month() < 9000.  Cap: 9k prod / 1k test / 10k plan total.';


-- ─────────────────────────────────────────────────────────────────────────────
-- 9. td_watchlist_refresh — full rebuild: owned_tickets, TP removed
--    Join path for owned_tickets/median_retail_price:
--      xref.aq_short_event_id → aq_event_map.sg_event_id
--      → seatgeek_event_metrics.sg_event_id (via tevo_event_id join)
--      → event_metrics.owned_tickets_count + retail_median
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.td_watchlist_refresh()
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
  r       RECORD;
  v_count int := 0;
  v_now   timestamptz := clock_timestamp();
BEGIN
  IF NOT public.cron_should_fire('td_watchlist_refresh') THEN RETURN 0; END IF;

  -- Reset per-day enqueue counters (new UTC day)
  UPDATE public.ticketsdata_event_xref
  SET enqueues_today = 0, updated_at = v_now
  WHERE enqueues_today > 0;

  -- Deactivate past events — platform-scoped (each platform uses a different event_id namespace)

  UPDATE public.ticketsdata_event_xref SET active = false, updated_at = v_now
  WHERE active = true AND platform = 'SH'
    AND event_id IN (
      SELECT aem.sh_event_id FROM public.aq_event_map aem
      JOIN public.sg_events_canonical sgc ON sgc.sg_event_id = aem.sg_event_id
      WHERE sgc.sg_datetime_utc < v_now - interval '2 hours' AND aem.sh_event_id IS NOT NULL);

  UPDATE public.ticketsdata_event_xref SET active = false, updated_at = v_now
  WHERE active = true AND platform = 'VD'
    AND event_id IN (
      SELECT aem.vivid_event_id FROM public.aq_event_map aem
      JOIN public.sg_events_canonical sgc ON sgc.sg_event_id = aem.sg_event_id
      WHERE sgc.sg_datetime_utc < v_now - interval '2 hours' AND aem.vivid_event_id IS NOT NULL);

  UPDATE public.ticketsdata_event_xref SET active = false, updated_at = v_now
  WHERE active = true AND platform = 'GT'
    AND event_id IN (
      SELECT sgc.sg_event_id FROM public.sg_events_canonical sgc
      WHERE sgc.sg_datetime_utc < v_now - interval '2 hours');

  UPDATE public.ticketsdata_event_xref SET active = false, updated_at = v_now
  WHERE active = true AND platform = 'TM'
    AND event_id IN (
      SELECT aem.tm_event_id FROM public.aq_event_map aem
      JOIN public.sg_events_canonical sgc ON sgc.sg_event_id = aem.sg_event_id
      WHERE sgc.sg_datetime_utc < v_now - interval '2 hours' AND aem.tm_event_id IS NOT NULL);

  -- ── StubHub (SH) — direct URL from sh_event_id ───────────────────────────
  FOR r IN
    SELECT aem.sh_event_id AS event_id, aem.aq_short_event_id, aem.performer, aem.event_name
    FROM public.aq_event_map aem
    JOIN public.sg_events_canonical sgc ON sgc.sg_event_id = aem.sg_event_id
    WHERE aem.sh_event_id IS NOT NULL
      AND sgc.sg_datetime_utc > v_now
      AND sgc.sg_datetime_utc < v_now + interval '60 days'
    ORDER BY sgc.sg_datetime_utc ASC
    LIMIT 100
  LOOP
    INSERT INTO public.ticketsdata_event_xref
      (event_id, platform, aq_short_event_id, event_url, active, always_on, match_method, updated_at)
    VALUES (
      r.event_id, 'SH', r.aq_short_event_id,
      'https://www.stubhub.com/x/event/' || r.event_id::text || '/',
      true,
      (COALESCE(r.performer,'') ILIKE '%knicks%' OR COALESCE(r.event_name,'') ILIKE '%knicks%'),
      'direct_id', v_now)
    ON CONFLICT (event_id, platform) DO UPDATE
      SET active     = true,
          always_on  = (COALESCE(r.performer,'') ILIKE '%knicks%' OR COALESCE(r.event_name,'') ILIKE '%knicks%'),
          event_url  = EXCLUDED.event_url,
          updated_at = v_now;
    v_count := v_count + 1;
  END LOOP;

  -- ── VividSeats (VD) — direct URL from vivid_event_id ─────────────────────
  FOR r IN
    SELECT aem.vivid_event_id AS event_id, aem.aq_short_event_id, aem.performer, aem.event_name
    FROM public.aq_event_map aem
    JOIN public.sg_events_canonical sgc ON sgc.sg_event_id = aem.sg_event_id
    WHERE aem.vivid_event_id IS NOT NULL
      AND sgc.sg_datetime_utc > v_now
      AND sgc.sg_datetime_utc < v_now + interval '60 days'
    ORDER BY sgc.sg_datetime_utc ASC
    LIMIT 100
  LOOP
    INSERT INTO public.ticketsdata_event_xref
      (event_id, platform, aq_short_event_id, event_url, active, always_on, match_method, updated_at)
    VALUES (
      r.event_id, 'VD', r.aq_short_event_id,
      'https://www.vividseats.com/production/' || r.event_id::text,
      true,
      (COALESCE(r.performer,'') ILIKE '%knicks%' OR COALESCE(r.event_name,'') ILIKE '%knicks%'),
      'direct_id', v_now)
    ON CONFLICT (event_id, platform) DO UPDATE
      SET active     = true,
          always_on  = (COALESCE(r.performer,'') ILIKE '%knicks%' OR COALESCE(r.event_name,'') ILIKE '%knicks%'),
          event_url  = EXCLUDED.event_url,
          updated_at = v_now;
    v_count := v_count + 1;
  END LOOP;

  -- ── Ticketmaster (TM) — inactive stub (tm_event_id is TEvo internal, not TM URL ID) ──
  FOR r IN
    SELECT aem.tm_event_id AS event_id, aem.aq_short_event_id, aem.performer, aem.event_name
    FROM public.aq_event_map aem
    JOIN public.sg_events_canonical sgc ON sgc.sg_event_id = aem.sg_event_id
    WHERE aem.tm_event_id IS NOT NULL
      AND sgc.sg_datetime_utc > v_now
      AND sgc.sg_datetime_utc < v_now + interval '60 days'
    ORDER BY sgc.sg_datetime_utc ASC
    LIMIT 100
  LOOP
    INSERT INTO public.ticketsdata_event_xref
      (event_id, platform, aq_short_event_id, event_url, active, always_on, match_method, updated_at)
    VALUES (
      r.event_id, 'TM', r.aq_short_event_id, NULL, false,
      (COALESCE(r.performer,'') ILIKE '%knicks%' OR COALESCE(r.event_name,'') ILIKE '%knicks%'),
      'pending_discovery', v_now)
    ON CONFLICT (event_id, platform) DO UPDATE
      SET always_on  = (COALESCE(r.performer,'') ILIKE '%knicks%' OR COALESCE(r.event_name,'') ILIKE '%knicks%'),
          updated_at = v_now;  -- preserve operator-set event_url + active
    v_count := v_count + 1;
  END LOOP;

  -- ── Update owned_tickets + median_retail_price for all active rows ─────────
  -- Join: xref.aq_short_event_id → aq_event_map.sg_event_id
  --       → seatgeek_event_metrics.sg_event_id (latest)
  --       → event_metrics.event_id (= tevo_event_id)
  UPDATE public.ticketsdata_event_xref x
  SET owned_tickets       = em_data.owned_tickets_count,
      median_retail_price = em_data.retail_median,
      updated_at          = v_now
  FROM public.aq_event_map aem
  CROSS JOIN LATERAL (
    SELECT em.owned_tickets_count, em.retail_median
    FROM public.event_metrics em
    JOIN public.seatgeek_event_metrics sgm ON sgm.tevo_event_id = em.event_id
    WHERE sgm.sg_event_id = aem.sg_event_id
    ORDER BY em.captured_at DESC
    LIMIT 1
  ) em_data
  WHERE aem.aq_short_event_id = x.aq_short_event_id
    AND x.active = true;

  RETURN v_count;
END $$;

REVOKE ALL ON FUNCTION public.td_watchlist_refresh() FROM anon, public;
COMMENT ON FUNCTION public.td_watchlist_refresh() IS
  'Daily watchlist upsert (9 UTC): SH+VD active (direct_id); GT activated by td_gt_discover_drain; '
  'TM inactive stub (URL discovery pending). TP removed 2026-05-27. '
  'Populates owned_tickets + median_retail_price for enqueue priority ordering.';


-- ─────────────────────────────────────────────────────────────────────────────
-- 10. td_enqueue_peak — per-platform scoped, monthly budget, priority ordering
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.td_enqueue_peak(
  p_platform     text    DEFAULT NULL,   -- 'SH'|'VD'|'GT'|'TM'|NULL (all active)
  p_interval_tag text    DEFAULT 'manual'
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
  r         RECORD;
  v_count   int := 0;
  v_now     timestamptz := clock_timestamp();
  v_jobname text;
BEGIN
  v_jobname := CASE
    WHEN p_platform IS NOT NULL THEN 'td_enqueue_peak_' || lower(p_platform)
    ELSE 'td_enqueue_peak'
  END;

  IF NOT public.cron_should_fire(v_jobname) THEN RETURN 0; END IF;

  IF NOT public.td_monthly_budget_ok() THEN
    RAISE NOTICE 'td_enqueue_peak(%): monthly credit budget exhausted, skipping', COALESCE(p_platform, 'all');
    RETURN 0;
  END IF;

  FOR r IN
    SELECT x.event_id, x.platform, x.event_url, x.always_on
    FROM public.ticketsdata_event_xref x
    JOIN public.sg_events_canonical sgc ON sgc.sg_event_id = (
      SELECT aem.sg_event_id FROM public.aq_event_map aem
      WHERE aem.aq_short_event_id = x.aq_short_event_id
      LIMIT 1)
    WHERE x.active            = true
      AND x.event_url         IS NOT NULL
      AND x.enqueues_today    < 4
      AND (p_platform IS NULL OR x.platform = p_platform)
      AND (x.always_on = true OR sgc.sg_datetime_utc < v_now + interval '7 days')
      -- Pileup guard: skip if unresolved pending row already exists
      AND NOT EXISTS (
        SELECT 1 FROM public.td_pull_queue q
        WHERE q.event_id  = x.event_id
          AND q.platform  = x.platform
          AND q.resolved_at IS NULL)
    ORDER BY
      x.always_on            DESC,
      x.owned_tickets        DESC NULLS LAST,
      x.median_retail_price  DESC NULLS LAST,
      x.last_enqueued_at     NULLS FIRST
    LIMIT 40   -- 40 per per-platform call; monthly budget gates total spend
  LOOP
    INSERT INTO public.td_pull_queue
      (event_id, platform, event_url, interval_tag, created_at)
    VALUES (r.event_id, r.platform, r.event_url, p_interval_tag, v_now);

    UPDATE public.ticketsdata_event_xref
    SET last_enqueued_at = v_now,
        enqueues_today   = enqueues_today + 1,
        updated_at       = v_now
    WHERE (event_id, platform) = (r.event_id, r.platform);

    v_count := v_count + 1;
  END LOOP;

  RETURN v_count;
END $$;

REVOKE ALL ON FUNCTION public.td_enqueue_peak(text, text) FROM anon, public;
COMMENT ON FUNCTION public.td_enqueue_peak(text, text) IS
  'Push (event×platform) pairs to td_pull_queue. '
  'p_platform scopes to one platform (SH/VD/GT) when called by staggered crons. '
  'Priority: always_on → owned_tickets DESC → median_retail_price DESC. '
  'Monthly budget gate. 40 pairs max per call. 4 enqueues/day per (event,platform).';


-- ─────────────────────────────────────────────────────────────────────────────
-- 11. td_pull_drain — monthly budget gate (replaces daily td_budget_ok)
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.td_pull_drain(
  p_max integer DEFAULT 5
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'extensions', 'pg_temp'
AS $$
DECLARE
  r        RECORD;
  v_user   text;
  v_pass   text;
  v_req_id bigint;
  v_count  int := 0;
BEGIN
  IF NOT public.cron_should_fire('td_pull_drain') THEN RETURN 0; END IF;

  IF NOT public.td_monthly_budget_ok() THEN
    RAISE NOTICE 'td_pull_drain: monthly credit budget exhausted, skipping';
    RETURN 0;
  END IF;

  v_user := public.get_app_secret('TICKETSDATA_USERNAME');
  v_pass := public.get_app_secret('TICKETSDATA_PASSWORD');

  IF v_user IS NULL OR v_pass IS NULL THEN
    RAISE EXCEPTION 'td_pull_drain: TICKETSDATA creds missing from vault';
  END IF;

  FOR r IN
    SELECT id, event_id, platform, event_url
    FROM public.td_pull_queue
    WHERE fired_at IS NULL
    ORDER BY created_at ASC
    LIMIT p_max
  LOOP
    -- Use params jsonb for proper URL encoding — NEVER log this URL (contains creds)
    SELECT net.http_get(
      url     := 'https://ticketsdata.com/fetch',
      params  := jsonb_build_object(
                   'platform',  public.td_api_platform(r.platform),
                   'event_url', r.event_url,
                   'username',  v_user,
                   'password',  v_pass
                 ),
      headers := '{}'::jsonb,
      timeout_milliseconds := 35000
    ) INTO v_req_id;

    UPDATE public.td_pull_queue
    SET request_id = v_req_id,
        fired_at   = clock_timestamp()
    WHERE id = r.id;

    v_count := v_count + 1;
  END LOOP;

  RETURN v_count;
END $$;

REVOKE ALL ON FUNCTION public.td_pull_drain(integer) FROM anon, public;
COMMENT ON FUNCTION public.td_pull_drain(integer) IS
  'Fire net.http_get for unfired td_pull_queue rows (FIFO). '
  'Default 5/fire = 5/sec burst (Starter plan cap). Monthly budget gate. '
  'Creds via vault; request URL never logged.';


-- ─────────────────────────────────────────────────────────────────────────────
-- 12. td_normalize_drain — monthly budget gate (replaces daily td_budget_ok)
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.td_normalize_drain(
  p_max integer DEFAULT 50
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'extensions', 'pg_temp'
AS $$
DECLARE
  r          RECORD;
  listing    RECORD;
  v_sc       int;
  v_quota    int;
  v_hash     text;
  v_count    int := 0;
  v_inserted int := 0;
BEGIN
  IF NOT public.cron_should_fire('td_normalize_drain') THEN RETURN 0; END IF;

  FOR r IN
    SELECT
      p.id, p.event_id, p.platform, p.event_url, p.interval_tag, p.retry_count,
      h.status_code AS http_sc,
      h.content     AS raw_content
    FROM public.td_pull_queue p
    JOIN net._http_response h ON h.id = p.request_id
    WHERE p.resolved_at IS NULL AND p.request_id IS NOT NULL
    ORDER BY p.fired_at ASC
    LIMIT p_max
  LOOP
    BEGIN
      -- VD uses "status_code" not "status" at top level; pg_net http_sc is the fallback
      v_sc    := COALESCE((r.raw_content::jsonb->>'status')::int,
                          (r.raw_content::jsonb->>'status_code')::int,
                          r.http_sc);
      v_quota := (r.raw_content::jsonb->>'quota_remaining')::int;

      IF v_sc = 200 THEN
        v_inserted := 0;
        FOR listing IN
          SELECT * FROM public.ticketsdata_normalize_listings(r.platform, r.raw_content::jsonb)
        LOOP
          v_hash := md5(listing.raw::text);
          INSERT INTO public.ticketsdata_listings_snapshots
            (event_id, platform, td_listing_id, section, row, quantity,
             list_price, price_with_fees, is_parking, content_hash, raw)
          VALUES
            (r.event_id, r.platform, listing.td_listing_id, listing.section,
             listing.row, listing.quantity, listing.list_price,
             listing.price_with_fees, listing.is_parking, v_hash, listing.raw)
          ON CONFLICT (event_id, platform, content_hash) DO NOTHING;
          v_inserted := v_inserted + 1;
        END LOOP;

        UPDATE public.td_pull_queue
        SET resolved_at   = clock_timestamp(), status_code = 200,
            credits_used  = 1, rows_inserted = v_inserted
        WHERE id = r.id;

        PERFORM public.td_charge_credit(1, r.event_id, r.platform, '/fetch', 200, v_quota);

        UPDATE public.ticketsdata_event_xref
        SET last_fetched_at = clock_timestamp(), updated_at = clock_timestamp()
        WHERE (event_id, platform) = (r.event_id, r.platform);

      ELSIF v_sc IN (429, 503) AND r.retry_count < 2 THEN
        INSERT INTO public.td_pull_queue
          (event_id, platform, event_url, interval_tag, retry_count)
        VALUES (r.event_id, r.platform, r.event_url, r.interval_tag, r.retry_count + 1);
        UPDATE public.td_pull_queue
        SET resolved_at = clock_timestamp(), status_code = v_sc,
            error_msg   = CASE v_sc WHEN 429 THEN 'rate_limited_requeued'
                                              ELSE 'service_unavailable_requeued' END
        WHERE id = r.id;

      ELSIF v_sc = 504 AND r.retry_count < 1 THEN
        INSERT INTO public.td_pull_queue
          (event_id, platform, event_url, interval_tag, retry_count)
        VALUES (r.event_id, r.platform, r.event_url, r.interval_tag, r.retry_count + 1);
        UPDATE public.td_pull_queue
        SET resolved_at = clock_timestamp(), status_code = 504, error_msg = 'timeout_requeued'
        WHERE id = r.id;

      ELSIF v_sc = 402 THEN
        UPDATE public.cron_policy
        SET enabled    = false,
            notes      = notes || ' [DISABLED 402 quota_exhausted ' || now()::date::text || ']',
            updated_at = now()
        WHERE jobname IN ('td_pull_drain','td_normalize_drain',
                          'td_enqueue_peak_sh','td_enqueue_peak_vd','td_enqueue_peak_gt');
        UPDATE public.td_pull_queue
        SET resolved_at = clock_timestamp(), status_code = 402,
            error_msg   = 'quota_exhausted — td crons disabled'
        WHERE id = r.id;
        RAISE NOTICE 'td_normalize_drain: 402 quota exhausted — TD crons disabled';
        EXIT;

      ELSIF v_sc = 403 THEN
        UPDATE public.ticketsdata_event_xref
        SET active = false, meta = meta || jsonb_build_object('403_at', now()),
            updated_at = clock_timestamp()
        WHERE (event_id, platform) = (r.event_id, r.platform);
        UPDATE public.td_pull_queue
        SET resolved_at = clock_timestamp(), status_code = 403,
            error_msg = 'access_denied — xref deactivated'
        WHERE id = r.id;

      ELSIF v_sc = 404 THEN
        UPDATE public.ticketsdata_event_xref
        SET active = false, meta = meta || jsonb_build_object('404_at', now()),
            updated_at = clock_timestamp()
        WHERE (event_id, platform) = (r.event_id, r.platform);
        UPDATE public.td_pull_queue
        SET resolved_at = clock_timestamp(), status_code = 404,
            error_msg = 'event_not_found — xref deactivated'
        WHERE id = r.id;

      ELSIF v_sc = 401 THEN
        UPDATE public.td_pull_queue
        SET resolved_at = clock_timestamp(), status_code = 401,
            error_msg = 'invalid_credentials'
        WHERE id = r.id;
        RAISE EXCEPTION 'td_normalize_drain: 401 invalid credentials — check TICKETSDATA vault secrets';

      ELSE
        UPDATE public.td_pull_queue
        SET resolved_at = clock_timestamp(), status_code = v_sc,
            error_msg   = left(r.raw_content, 500)
        WHERE id = r.id;

      END IF;

      v_count := v_count + 1;

    EXCEPTION
      WHEN query_canceled THEN
        RAISE NOTICE 'td_normalize_drain: query_canceled at row % — exiting gracefully', r.id;
        EXIT;
      WHEN OTHERS THEN
        UPDATE public.td_pull_queue
        SET resolved_at = clock_timestamp(), status_code = -1, error_msg = left(SQLERRM, 500)
        WHERE id = r.id;
    END;
  END LOOP;

  RETURN v_count;
END $$;

REVOKE ALL ON FUNCTION public.td_normalize_drain(integer) FROM anon, public;
COMMENT ON FUNCTION public.td_normalize_drain(integer) IS
  'Drain net._http_response into ticketsdata_listings_snapshots. '
  'Handles VD status_code (not status) via COALESCE fallback. '
  'Monthly budget gate. 200→snapshots; 429/503→re-queue; 402→disable crons; '
  '401→RAISE; 403/404→deactivate xref.';


-- ─────────────────────────────────────────────────────────────────────────────
-- 13. td_pending_sweep — remove TP deactivation query
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.td_pending_sweep()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
  v_now timestamptz := clock_timestamp();
BEGIN
  IF NOT public.cron_should_fire('td_pending_sweep') THEN RETURN; END IF;

  -- Prune resolved rows older than 7 days
  DELETE FROM public.td_pull_queue
  WHERE resolved_at IS NOT NULL AND created_at < v_now - interval '7 days';

  -- Reset stuck rows: fired but not resolved after 1 hour
  UPDATE public.td_pull_queue
  SET resolved_at = v_now, status_code = -1,
      error_msg   = 'timeout_sweep — pg_net request unresolved after 1h'
  WHERE fired_at IS NOT NULL AND resolved_at IS NULL
    AND fired_at < v_now - interval '1 hour';

  -- Deactivate past events (platform-scoped)
  UPDATE public.ticketsdata_event_xref SET active = false, updated_at = v_now
  WHERE active = true AND platform = 'SH'
    AND event_id IN (
      SELECT aem.sh_event_id FROM public.aq_event_map aem
      JOIN public.sg_events_canonical sgc ON sgc.sg_event_id = aem.sg_event_id
      WHERE sgc.sg_datetime_utc < v_now - interval '2 hours' AND aem.sh_event_id IS NOT NULL);

  UPDATE public.ticketsdata_event_xref SET active = false, updated_at = v_now
  WHERE active = true AND platform = 'VD'
    AND event_id IN (
      SELECT aem.vivid_event_id FROM public.aq_event_map aem
      JOIN public.sg_events_canonical sgc ON sgc.sg_event_id = aem.sg_event_id
      WHERE sgc.sg_datetime_utc < v_now - interval '2 hours' AND aem.vivid_event_id IS NOT NULL);

  UPDATE public.ticketsdata_event_xref SET active = false, updated_at = v_now
  WHERE active = true AND platform = 'GT'
    AND event_id IN (
      SELECT sgc.sg_event_id FROM public.sg_events_canonical sgc
      WHERE sgc.sg_datetime_utc < v_now - interval '2 hours');

  UPDATE public.ticketsdata_event_xref SET active = false, updated_at = v_now
  WHERE active = true AND platform = 'TM'
    AND event_id IN (
      SELECT aem.tm_event_id FROM public.aq_event_map aem
      JOIN public.sg_events_canonical sgc ON sgc.sg_event_id = aem.sg_event_id
      WHERE sgc.sg_datetime_utc < v_now - interval '2 hours' AND aem.tm_event_id IS NOT NULL);

END $$;

REVOKE ALL ON FUNCTION public.td_pending_sweep() FROM anon, public;
COMMENT ON FUNCTION public.td_pending_sweep() IS
  'Hourly cleanup: prune 7d+ resolved rows, reset stuck requests, deactivate past events. '
  'Platform-scoped deactivation. TP removed 2026-05-27.';


-- ─────────────────────────────────────────────────────────────────────────────
-- 14. td_gt_discover — fire GT /events requests per active performer
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.td_gt_discover()
RETURNS integer   -- count of /events requests fired
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'extensions', 'pg_temp'
AS $$
DECLARE
  r        RECORD;
  v_user   text;
  v_pass   text;
  v_req_id bigint;
  v_count  int := 0;
BEGIN
  IF NOT public.cron_should_fire('td_gt_discover') THEN RETURN 0; END IF;

  IF NOT public.td_monthly_budget_ok() THEN
    RAISE NOTICE 'td_gt_discover: monthly credit budget exhausted, skipping';
    RETURN 0;
  END IF;

  v_user := public.get_app_secret('TICKETSDATA_USERNAME');
  v_pass := public.get_app_secret('TICKETSDATA_PASSWORD');

  IF v_user IS NULL OR v_pass IS NULL THEN
    RAISE EXCEPTION 'td_gt_discover: TICKETSDATA creds missing from vault';
  END IF;

  FOR r IN
    SELECT id, performer_url
    FROM public.td_gt_performers
    WHERE active = true
      AND (pending_discover_request_id IS NULL
           OR last_discovered_at IS NULL
           OR last_discovered_at < clock_timestamp() - interval '22 hours')
    ORDER BY id
  LOOP
    SELECT net.http_get(
      url     := 'https://ticketsdata.com/events',
      params  := jsonb_build_object(
                   'platform',      'gametime',
                   'performer_url', r.performer_url,
                   'username',      v_user,
                   'password',      v_pass
                 ),
      headers := '{}'::jsonb,
      timeout_milliseconds := 35000
    ) INTO v_req_id;

    UPDATE public.td_gt_performers
    SET pending_discover_request_id = v_req_id,
        updated_at                  = clock_timestamp()
    WHERE id = r.id;

    v_count := v_count + 1;
  END LOOP;

  RETURN v_count;
END $$;

REVOKE ALL ON FUNCTION public.td_gt_discover() FROM anon, public;
COMMENT ON FUNCTION public.td_gt_discover() IS
  'Fires GT /events per active td_gt_performers entry. '
  'Stores pg_net request_id in pending_discover_request_id. '
  'Runs daily 9:15 UTC (right after td_watchlist_refresh). '
  'td_gt_discover_drain() processes responses at 9:20 UTC.';


-- ─────────────────────────────────────────────────────────────────────────────
-- 15. td_gt_discover_drain — parse /events responses → upsert ticketsdata_event_xref
--
--     GT /events response (confirmed 2026-05-27, reqs 244922-244924):
--       {status:200, body:{items:[{event:{id, seo_url, datetime_utc, name, ...}}]}}
--     Match: datetime_utc ±30min to sg_events_canonical.sg_datetime_utc (future only)
--     Key used: sg_event_id as event_id in xref (GT has no dedicated ID column in aq_event_map)
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.td_gt_discover_drain()
RETURNS integer   -- count of xref rows upserted
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'extensions', 'pg_temp'
AS $$
DECLARE
  r          RECORD;
  ev         RECORD;
  v_sg_id    bigint;
  v_aq_short text;
  v_count    int := 0;
BEGIN
  IF NOT public.cron_should_fire('td_gt_discover_drain') THEN RETURN 0; END IF;

  FOR r IN
    SELECT
      p.id   AS performer_id,
      h.status_code,
      h.content AS raw_content
    FROM public.td_gt_performers p
    JOIN net._http_response h ON h.id = p.pending_discover_request_id
    WHERE p.active = true
      AND p.pending_discover_request_id IS NOT NULL
    ORDER BY p.id
  LOOP
    IF r.status_code = 200 THEN
      FOR ev IN
        SELECT
          item->'event'->>'seo_url'                          AS seo_url,
          (item->'event'->>'datetime_utc')::timestamptz      AS dt_utc
        FROM jsonb_array_elements(r.raw_content::jsonb->'body'->'items') AS item
        WHERE item->'event'->>'seo_url' IS NOT NULL
          AND item->'event'->>'datetime_utc' IS NOT NULL
      LOOP
        -- Match to our event map: sg_events_canonical ±30min, future events only
        SELECT sgc.sg_event_id, aem.aq_short_event_id
        INTO   v_sg_id, v_aq_short
        FROM   public.sg_events_canonical sgc
        JOIN   public.aq_event_map aem ON aem.sg_event_id = sgc.sg_event_id
        WHERE  abs(extract(epoch FROM sgc.sg_datetime_utc - ev.dt_utc)) < 1800
          AND  sgc.sg_datetime_utc > clock_timestamp()
        ORDER BY abs(extract(epoch FROM sgc.sg_datetime_utc - ev.dt_utc))
        LIMIT 1;

        IF v_sg_id IS NOT NULL THEN
          INSERT INTO public.ticketsdata_event_xref
            (event_id, platform, aq_short_event_id, event_url, active, always_on, match_method, updated_at)
          VALUES (v_sg_id, 'GT', v_aq_short, ev.seo_url, true, false, 'events_api', clock_timestamp())
          ON CONFLICT (event_id, platform) DO UPDATE
            SET event_url    = EXCLUDED.event_url,
                active       = true,
                match_method = 'events_api',
                updated_at   = clock_timestamp()
            WHERE ticketsdata_event_xref.event_url  IS DISTINCT FROM EXCLUDED.event_url
               OR ticketsdata_event_xref.active     = false;

          v_count := v_count + 1;
        END IF;
      END LOOP;

      -- Charge 1 credit for the /events call (discovery endpoint = same cost as /fetch)
      PERFORM public.td_charge_credit(
        1, NULL, 'GT', '/events', 200,
        (r.raw_content::jsonb->>'quota_remaining')::int
      );
    END IF;

    -- Clear pending flag regardless of status (don't retry on errors in drain)
    UPDATE public.td_gt_performers
    SET pending_discover_request_id = NULL,
        last_discovered_at          = clock_timestamp(),
        updated_at                  = clock_timestamp()
    WHERE id = r.performer_id;

  END LOOP;

  RETURN v_count;
END $$;

REVOKE ALL ON FUNCTION public.td_gt_discover_drain() FROM anon, public;
COMMENT ON FUNCTION public.td_gt_discover_drain() IS
  'Processes GT /events responses from net._http_response. '
  'Matches events by datetime_utc ±30min to sg_events_canonical. '
  'Upserts seo_url as event_url in ticketsdata_event_xref (platform=GT, active=true). '
  'Charges 1 credit per /events call processed.';


-- ─────────────────────────────────────────────────────────────────────────────
-- 16. Cron schedule changes
-- ─────────────────────────────────────────────────────────────────────────────
DO $sched$ BEGIN

  -- Remove unified td_enqueue_peak (replaced by 3 per-platform crons)
  BEGIN PERFORM cron.unschedule('td_enqueue_peak'); EXCEPTION WHEN OTHERS THEN NULL; END;

  -- SH: 11am/2pm/5pm/8pm ET = 15/18/21/00 UTC
  PERFORM cron.schedule(
    'td_enqueue_peak_sh',
    '0 15,18,21,0 * * *',
    $cron$DO $b$ BEGIN
      PERFORM public.td_enqueue_peak('SH',
        CASE date_part('hour', now() AT TIME ZONE 'UTC')::int
          WHEN 15 THEN '11am_ET' WHEN 18 THEN '2pm_ET'
          WHEN 21 THEN '5pm_ET'  WHEN  0 THEN '8pm_ET' ELSE 'manual' END);
    END $b$;$cron$
  );

  -- VD: 11:45am/2:45pm/5:45pm/8:45pm ET = 15:45/18:45/21:45/00:45 UTC
  PERFORM cron.schedule(
    'td_enqueue_peak_vd',
    '45 15,18,21,0 * * *',
    $cron$DO $b$ BEGIN
      PERFORM public.td_enqueue_peak('VD',
        CASE date_part('hour', now() AT TIME ZONE 'UTC')::int
          WHEN 15 THEN '11am_ET' WHEN 18 THEN '2pm_ET'
          WHEN 21 THEN '5pm_ET'  WHEN  0 THEN '8pm_ET' ELSE 'manual' END);
    END $b$;$cron$
  );

  -- GT: 12:30pm/3:30pm/6:30pm/9:30pm ET = 16:30/19:30/22:30/01:30 UTC
  PERFORM cron.schedule(
    'td_enqueue_peak_gt',
    '30 16,19,22,1 * * *',
    $cron$DO $b$ BEGIN
      PERFORM public.td_enqueue_peak('GT',
        CASE date_part('hour', now() AT TIME ZONE 'UTC')::int
          WHEN 16 THEN '12:30pm_ET' WHEN 19 THEN '3:30pm_ET'
          WHEN 22 THEN '6:30pm_ET'  WHEN  1 THEN '9:30pm_ET' ELSE 'manual' END);
    END $b$;$cron$
  );

  -- GT discovery: 9:15 UTC daily (5 min after td_watchlist_refresh)
  PERFORM cron.schedule(
    'td_gt_discover',
    '15 9 * * *',
    $cron$DO $b$ BEGIN PERFORM public.td_gt_discover(); END $b$;$cron$
  );

  -- GT discover drain: 9:20 UTC daily (5 min after td_gt_discover fires)
  PERFORM cron.schedule(
    'td_gt_discover_drain',
    '20 9 * * *',
    $cron$DO $b$ BEGIN PERFORM public.td_gt_discover_drain(); END $b$;$cron$
  );

END $sched$;


-- ─────────────────────────────────────────────────────────────────────────────
-- 17. cron_policy — replace td_enqueue_peak entry; add SH/VD/GT + discover
-- ─────────────────────────────────────────────────────────────────────────────

-- Remove the old unified td_enqueue_peak policy row
DELETE FROM public.cron_policy WHERE jobname = 'td_enqueue_peak';

INSERT INTO public.cron_policy
  (jobname, peak_hours_et, peak_min_interval_min, offpeak_min_interval_min,
   daily_max_fires, work_check_sql, enabled, notes)
VALUES
  ('td_enqueue_peak_sh',
   '{}'::int[], 180, 180, 4,
   'SELECT public.td_monthly_budget_ok()',
   true,
   'TD enqueue SH — 11am/2pm/5pm/8pm ET (0 15,18,21,0 UTC). 40 events/fire. Monthly budget gate.'),

  ('td_enqueue_peak_vd',
   '{}'::int[], 180, 180, 4,
   'SELECT public.td_monthly_budget_ok()',
   true,
   'TD enqueue VD — 11:45am/2:45pm/5:45pm/8:45pm ET (45 15,18,21,0 UTC). 40 events/fire.'),

  ('td_enqueue_peak_gt',
   '{}'::int[], 180, 180, 4,
   'SELECT public.td_monthly_budget_ok()',
   true,
   'TD enqueue GT — 12:30pm/3:30pm/6:30pm/9:30pm ET (30 16,19,22,1 UTC). 40 events/fire.'),

  ('td_gt_discover',
   '{}'::int[], 1440, 1440, 1,
   'SELECT public.td_monthly_budget_ok()',
   true,
   'GT /events discovery — fires per performer in td_gt_performers. Daily 9:15 UTC.'),

  ('td_gt_discover_drain',
   '{}'::int[], 1440, 1440, 1,
   'SELECT true',
   true,
   'GT /events drain — upserts seo_url into ticketsdata_event_xref. Daily 9:20 UTC.')

ON CONFLICT (jobname) DO UPDATE
  SET peak_hours_et            = EXCLUDED.peak_hours_et,
      peak_min_interval_min    = EXCLUDED.peak_min_interval_min,
      offpeak_min_interval_min = EXCLUDED.offpeak_min_interval_min,
      daily_max_fires          = EXCLUDED.daily_max_fires,
      work_check_sql           = EXCLUDED.work_check_sql,
      enabled                  = true,
      notes                    = EXCLUDED.notes,
      updated_at               = now();

-- Update existing TD cron policies: switch work_check_sql to monthly + re-enable
UPDATE public.cron_policy
SET work_check_sql = 'SELECT public.td_monthly_budget_ok()',
    enabled        = true,
    notes          = notes || ' [updated to monthly budget 2026-05-27]',
    updated_at     = now()
WHERE jobname IN ('td_pull_drain', 'td_normalize_drain');

UPDATE public.cron_policy
SET enabled    = true,
    notes      = notes || ' [re-enabled 2026-05-27]',
    updated_at = now()
WHERE jobname IN ('td_watchlist_refresh', 'td_pending_sweep');

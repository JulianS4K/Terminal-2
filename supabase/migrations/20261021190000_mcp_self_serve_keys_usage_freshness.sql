-- Migration 20261021190000 · level:security · lane:D0 (MCP product; operator-directed 2026-10-21) · writes:mcp_api_keys(+cols),mcp_usage_daily(new),mcp_verify_key(),mcp_count_call(),mcp_self_issue_key(),mcp_my_keys(),mcp_data_freshness() · reads:auth.users,seatgeek_sales_snapshots,event_listing_snapshot_daily,latest_event_metrics,event_movers_agg,event_competitors_snapshot,reddit_news,prediction_markets,espn_event_snapshots,performer_metrics_daily,sg_market_chart,events · pre:20261008150000
--
-- ============================================================================
-- Migration 20261021190000 — /mcp as a product: self-serve keys, per-key
--   limits + daily usage, and a data-freshness feed
--
-- Lane:     D0 (terminal / MCP) · operator-directed 2026-10-21: "convert the
--           database into a MCP so people can plug into their bot and get real
--           time-ish information and trends" → self-serve signup, public market
--           + trends + prediction markets + sports/news/weather, every answer
--           carries an as-of, our book never leaves the internal tier.
-- Touches:  mcp_api_keys            (W: +owner_user_id, owner_email, rate_per_min,
--                                       daily_quota)
--           mcp_usage_daily         (W: new — one row per key per UTC day)
--           mcp_verify_key(text)    (W: replaced — now also returns the limits
--                                       and today's call count)
--           mcp_count_call(bigint,text)      (W: new, service_role)
--           mcp_self_issue_key(text)         (W: new, SECDEF, authenticated — the
--                                             self-serve path; one live external
--                                             key per account, ≤5 issues/day)
--           mcp_my_keys()                    (W: new, SECDEF, authenticated)
--           mcp_data_freshness()             (W: new, service_role — per-feed as-of)
-- Pre-reqs: 20261008150000 (mcp_api_keys + mcp_issue_key)
--
-- MODEL: anyone can sign in to the /developers page with Google (Supabase
--   Auth; no domain gate — that gate is the terminal app's, not Auth's) and
--   mint ONE live external key. The browser calls mcp_self_issue_key with its
--   session JWT; the function keys everything on auth.uid(), so no backend
--   route handles plaintext keys. The FastAPI /mcp server (service_role)
--   verifies keys with mcp_verify_key, enforces rate_per_min in-process and
--   daily_quota from calls_today, and stamps each request with mcp_count_call.
--   Internal keys are still issued by hand with mcp_issue_key.
--
-- SECURITY: §2.8 as corrected 2026-10-21 — grants are the gate. The two
--   authenticated-callable functions read only the caller's own rows
--   (auth.uid()); the plaintext key is returned once and stored as sha256.
--   mcp_usage_daily and the service functions are service_role-only.
-- ============================================================================

-- 1. Key columns -------------------------------------------------------------
ALTER TABLE public.mcp_api_keys
  ADD COLUMN IF NOT EXISTS owner_user_id uuid,
  ADD COLUMN IF NOT EXISTS owner_email   text,
  ADD COLUMN IF NOT EXISTS rate_per_min  integer NOT NULL DEFAULT 60,
  ADD COLUMN IF NOT EXISTS daily_quota   integer NOT NULL DEFAULT 2000;

CREATE INDEX IF NOT EXISTS mcp_api_keys_owner_live_idx
  ON public.mcp_api_keys (owner_user_id) WHERE revoked_at IS NULL;

-- 2. Usage -------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.mcp_usage_daily (
  key_id      bigint NOT NULL REFERENCES public.mcp_api_keys(id) ON DELETE CASCADE,
  day         date   NOT NULL,
  calls       integer NOT NULL DEFAULT 0,
  last_tool   text,
  updated_at  timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (key_id, day)
);
ALTER TABLE public.mcp_usage_daily ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.mcp_usage_daily FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT, UPDATE ON public.mcp_usage_daily TO service_role;
COMMENT ON TABLE public.mcp_usage_daily IS
  'Per-key, per-UTC-day request counts for the /mcp server (mig 20261021190000). Written by mcp_count_call; read by mcp_verify_key (quota) and mcp_my_keys (owner view).';

-- 3. Verify (replaced: new return shape) -------------------------------------
DROP FUNCTION IF EXISTS public.mcp_verify_key(text);
CREATE FUNCTION public.mcp_verify_key(p_key_hash text)
RETURNS TABLE(id bigint, label text, tier text, rate_per_min integer, daily_quota integer, calls_today integer)
LANGUAGE plpgsql
SET search_path TO 'public', 'pg_temp'
AS $func$
BEGIN
  UPDATE public.mcp_api_keys k SET last_used_at = now()
   WHERE k.key_hash = p_key_hash AND k.revoked_at IS NULL
     AND (k.last_used_at IS NULL OR k.last_used_at < now() - interval '1 minute');
  RETURN QUERY
    SELECT k.id, k.label, k.tier, k.rate_per_min, k.daily_quota,
           coalesce(u.calls, 0)
    FROM public.mcp_api_keys k
    LEFT JOIN public.mcp_usage_daily u
      ON u.key_id = k.id AND u.day = (now() AT TIME ZONE 'utc')::date
    WHERE k.key_hash = p_key_hash AND k.revoked_at IS NULL;
END
$func$;
REVOKE EXECUTE ON FUNCTION public.mcp_verify_key(text) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.mcp_verify_key(text) TO service_role;

-- 4. Count one request -------------------------------------------------------
CREATE OR REPLACE FUNCTION public.mcp_count_call(p_key_id bigint, p_tool text DEFAULT NULL)
RETURNS void
LANGUAGE sql
SET search_path TO 'public', 'pg_temp'
AS $func$
  INSERT INTO public.mcp_usage_daily AS u (key_id, day, calls, last_tool)
  VALUES (p_key_id, (now() AT TIME ZONE 'utc')::date, 1, p_tool)
  ON CONFLICT (key_id, day) DO UPDATE
    SET calls = u.calls + 1,
        last_tool = coalesce(EXCLUDED.last_tool, u.last_tool),
        updated_at = now();
$func$;
REVOKE EXECUTE ON FUNCTION public.mcp_count_call(bigint, text) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.mcp_count_call(bigint, text) TO service_role;

-- 5. Self-serve issue (authenticated; keyed on auth.uid()) -------------------
CREATE OR REPLACE FUNCTION public.mcp_self_issue_key(p_label text DEFAULT 'my bot')
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'extensions', 'pg_temp'
AS $func$
DECLARE
  v_uid   uuid := auth.uid();
  v_email text;
  v_key   text;
  v_label text := left(coalesce(nullif(btrim(p_label), ''), 'my bot'), 80);
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'sign in to create a key' USING ERRCODE = '42501';
  END IF;
  SELECT u.email INTO v_email FROM auth.users u
   WHERE u.id = v_uid AND u.email_confirmed_at IS NOT NULL;
  IF v_email IS NULL THEN
    RAISE EXCEPTION 'a confirmed email is required' USING ERRCODE = '42501';
  END IF;
  IF (SELECT count(*) FROM public.mcp_api_keys k
       WHERE k.owner_user_id = v_uid AND k.created_at > now() - interval '1 day') >= 5 THEN
    RAISE EXCEPTION 'key issue limit reached for today (5)' USING ERRCODE = '54000';
  END IF;

  -- one live external key per account: retire the previous one
  UPDATE public.mcp_api_keys SET revoked_at = now()
   WHERE owner_user_id = v_uid AND tier = 'external' AND revoked_at IS NULL;

  v_key := 's4k_ext_' || encode(gen_random_bytes(24), 'hex');
  INSERT INTO public.mcp_api_keys
    (label, tier, key_prefix, key_hash, created_by, owner_user_id, owner_email)
  VALUES
    (v_label, 'external', left(v_key, 12), encode(digest(v_key, 'sha256'), 'hex'),
     'self-serve', v_uid, v_email);

  RETURN jsonb_build_object(
    'key', v_key, 'key_prefix', left(v_key, 12), 'label', v_label,
    'tier', 'external', 'rate_per_min', 60, 'daily_quota', 2000);
END
$func$;
REVOKE EXECUTE ON FUNCTION public.mcp_self_issue_key(text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.mcp_self_issue_key(text) TO authenticated, service_role;

-- 6. Owner view --------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.mcp_my_keys()
RETURNS jsonb
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path TO 'public', 'pg_temp'
AS $func$
  SELECT coalesce(jsonb_agg(jsonb_build_object(
      'id', k.id, 'label', k.label, 'key_prefix', k.key_prefix, 'tier', k.tier,
      'created_at', k.created_at, 'revoked_at', k.revoked_at, 'last_used_at', k.last_used_at,
      'rate_per_min', k.rate_per_min, 'daily_quota', k.daily_quota,
      'calls_today', coalesce(u.calls, 0))
    ORDER BY k.created_at DESC), '[]'::jsonb)
  FROM public.mcp_api_keys k
  LEFT JOIN public.mcp_usage_daily u
    ON u.key_id = k.id AND u.day = (now() AT TIME ZONE 'utc')::date
  WHERE k.owner_user_id = auth.uid() AND auth.uid() IS NOT NULL;
$func$;
REVOKE EXECUTE ON FUNCTION public.mcp_my_keys() FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.mcp_my_keys() TO authenticated, service_role;

-- 7. Freshness feed (what "real-time-ish" means, per feed) -------------------
CREATE OR REPLACE FUNCTION public.mcp_data_freshness()
RETURNS jsonb
LANGUAGE sql
STABLE
SET search_path TO 'public', 'pg_temp'
AS $func$
  WITH f AS (
    SELECT 'seatgeek_sales' AS feed, 'SeatGeek market sales (all sellers)' AS description,
           max(pulled_at) AS as_of, count(*) FILTER (WHERE pulled_at > now() - interval '24 hours') AS rows_24h,
           'minutes' AS cadence FROM public.seatgeek_sales_snapshots
    UNION ALL
    SELECT 'listing_snapshot_daily', 'Per-event daily listing ladder (counts, get-in, median across sources)',
           max(captured_at), count(*) FILTER (WHERE captured_at > now() - interval '24 hours'), 'hours'
    FROM public.event_listing_snapshot_daily
    UNION ALL
    SELECT 'evo_getin_prices', 'TEvo get-in price + zone prices (listing pollers paused 2026-09-27)',
           max(captured_at), count(*) FILTER (WHERE captured_at > now() - interval '24 hours'), 'paused'
    FROM public.latest_event_metrics
    UNION ALL
    SELECT 'price_movers', 'Multi-source price change, recent vs prior window',
           max(computed_at), count(*) FILTER (WHERE computed_at > now() - interval '24 hours'), 'daily'
    FROM public.event_movers_agg
    UNION ALL
    SELECT 'competing_events', 'Competing events within 20 mi / ±24 h',
           max(refreshed_at), count(*) FILTER (WHERE refreshed_at > now() - interval '24 hours'), 'hours'
    FROM public.event_competitors_snapshot
    UNION ALL
    SELECT 'news', 'Reddit news ticker by league',
           max(pulled_at), count(*) FILTER (WHERE pulled_at > now() - interval '24 hours'), 'minutes'
    FROM public.reddit_news
    UNION ALL
    SELECT 'prediction_markets', 'Kalshi + Polymarket prices linked to events/teams',
           max(updated_at), count(*) FILTER (WHERE updated_at > now() - interval '24 hours'), 'minutes'
    FROM public.prediction_markets
    UNION ALL
    SELECT 'sports', 'ESPN game state, scores, odds, attendance',
           max(captured_at), count(*) FILTER (WHERE captured_at > now() - interval '24 hours'), 'minutes'
    FROM public.espn_event_snapshots
    UNION ALL
    SELECT 'performer_trend', 'Per-performer daily price/volume metrics',
           max(snapshot_date)::timestamptz, count(*) FILTER (WHERE snapshot_date >= current_date - 1), 'daily'
    FROM public.performer_metrics_daily
    UNION ALL
    SELECT 'market_chart', 'Daily top-selling events chart (SeatGeek-based, MA7)',
           max(chart_date)::timestamptz, count(*) FILTER (WHERE chart_date >= current_date - 1), 'daily'
    FROM public.sg_market_chart
    UNION ALL
    SELECT 'events', 'Event catalogue (future events)',
           max(last_seen), count(*) FILTER (WHERE occurs_at_local >= to_char(now(), 'YYYY-MM-DD')), 'hours'
    FROM public.events
  )
  SELECT jsonb_build_object(
    'generated_at', now(),
    'feeds', jsonb_agg(jsonb_build_object(
      'feed', feed, 'description', description, 'as_of', as_of,
      'age_minutes', CASE WHEN as_of IS NULL THEN NULL
                          ELSE round(extract(epoch FROM (now() - as_of)) / 60) END,
      'rows_24h', rows_24h, 'cadence', cadence) ORDER BY feed))
  FROM f;
$func$;
REVOKE EXECUTE ON FUNCTION public.mcp_data_freshness() FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.mcp_data_freshness() TO service_role;

-- Post-apply checks:
--   SELECT * FROM public.mcp_verify_key('nope');                       -- 0 rows
--   SELECT jsonb_array_length(public.mcp_data_freshness()->'feeds');   -- 11
--   SELECT proname, has_function_privilege('anon', p.oid, 'EXECUTE') anon,
--          has_function_privilege('authenticated', p.oid, 'EXECUTE') auth
--   FROM pg_proc p WHERE proname LIKE 'mcp_%';                          -- anon false everywhere;
--                                                                         -- auth true only for self_issue/my_keys

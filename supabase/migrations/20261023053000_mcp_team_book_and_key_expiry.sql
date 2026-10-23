-- Migration 20261023053000 · level:feature · lane:D0 (MCP) + A1 (read RPC) · writes:mcp_api_keys.expires_at(new col),mcp_verify_key()(replace),mcp_issue_key_ttl()(new),mcp_team_book()(new) · reads:v_s4kcs_orders,seatgeek_orders,event_metrics,events,listings_poll_pins · pre:20261023052000
--
-- ============================================================================
-- Migration 20261023053000 — MCP: our Knicks book (internal tier) + keys that expire
--
-- Operator 2026-10-23: "give me a 5 day public mcp to test · include crm knicks sales ·
-- include our own book for testing purposes".
--
--   mcp_api_keys.expires_at   NULL = never. mcp_verify_key ignores an expired key exactly
--                             like a revoked one (401).
--   mcp_issue_key_ttl(label, tier, created_by, ttl)  service-only; like mcp_issue_key with
--                             an expiry (1 h .. 30 d).
--   mcp_team_book(team, since, home_only, max_events)  service-only, INTERNAL tool only:
--                             per game our CRM sales (v_s4kcs_orders, price_per_ticket, no
--                             notes/PII; rejected/cancelled excluded) by marketplace,
--                             SeatGeek orders, owned inventory now vs the market, totals,
--                             the 25 latest orders, and which pins poll the team.
-- ============================================================================

SET LOCAL lock_timeout = '10s';

ALTER TABLE public.mcp_api_keys ADD COLUMN IF NOT EXISTS expires_at timestamptz;
COMMENT ON COLUMN public.mcp_api_keys.expires_at IS
  'Key stops authenticating after this instant (NULL = no expiry). Mig 20261023053000.';

CREATE OR REPLACE FUNCTION public.mcp_verify_key(p_key_hash text)
RETURNS TABLE(id bigint, label text, tier text, rate_per_min integer, daily_quota integer, calls_today integer)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  UPDATE public.mcp_api_keys k SET last_used_at = now()
   WHERE k.key_hash = p_key_hash AND k.revoked_at IS NULL
     AND (k.expires_at IS NULL OR k.expires_at > now())
     AND (k.last_used_at IS NULL OR k.last_used_at < now() - interval '1 minute');
  RETURN QUERY
    SELECT k.id, k.label, k.tier, k.rate_per_min, k.daily_quota,
           coalesce(u.calls, 0)
    FROM public.mcp_api_keys k
    LEFT JOIN public.mcp_usage_daily u
      ON u.key_id = k.id AND u.day = (now() AT TIME ZONE 'utc')::date
    WHERE k.key_hash = p_key_hash AND k.revoked_at IS NULL
      AND (k.expires_at IS NULL OR k.expires_at > now());
END
$$;

CREATE OR REPLACE FUNCTION public.mcp_issue_key_ttl(p_label text, p_tier text, p_created_by text, p_ttl interval)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions, pg_temp
AS $$
DECLARE
  v_key text;
  v_exp timestamptz;
BEGIN
  IF current_user NOT IN ('service_role','postgres','supabase_admin') THEN
    RAISE EXCEPTION 'forbidden: mcp_issue_key_ttl is service-only' USING ERRCODE='42501';
  END IF;
  IF p_tier NOT IN ('internal', 'external') THEN
    RAISE EXCEPTION 'tier must be internal or external' USING ERRCODE = '22023';
  END IF;
  IF coalesce(btrim(p_label), '') = '' THEN
    RAISE EXCEPTION 'label is required' USING ERRCODE = '22023';
  END IF;
  IF p_ttl IS NULL OR p_ttl < interval '1 hour' OR p_ttl > interval '30 days' THEN
    RAISE EXCEPTION 'ttl must be between 1 hour and 30 days' USING ERRCODE = '22023';
  END IF;
  v_key := 's4k_' || CASE p_tier WHEN 'internal' THEN 'int_' ELSE 'ext_' END
           || encode(gen_random_bytes(24), 'hex');
  v_exp := now() + p_ttl;
  INSERT INTO public.mcp_api_keys (label, tier, key_prefix, key_hash, created_by, expires_at)
  VALUES (btrim(p_label), p_tier, left(v_key, 12), encode(digest(v_key, 'sha256'), 'hex'),
          p_created_by, v_exp);
  RETURN jsonb_build_object('key', v_key, 'key_prefix', left(v_key, 12), 'tier', p_tier,
                            'expires_at', v_exp);
END
$$;
REVOKE ALL ON FUNCTION public.mcp_issue_key_ttl(text, text, text, interval) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.mcp_issue_key_ttl(text, text, text, interval) TO service_role;

CREATE OR REPLACE FUNCTION public.mcp_team_book(
  p_team        text,
  p_since       date    DEFAULT NULL,
  p_home_only   boolean DEFAULT false,
  p_max_events  integer DEFAULT 60)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
SET statement_timeout = '25s'
AS $$
DECLARE
  v_pid    bigint;
  v_name   text;
  v_since  date := coalesce(p_since, current_date - 60);
  v_max    integer := LEAST(GREATEST(coalesce(p_max_events, 60), 1), 120);
  v_events bigint[];
  v_out    jsonb;
BEGIN
  IF current_user NOT IN ('service_role','postgres','supabase_admin') THEN
    RAISE EXCEPTION 'forbidden: mcp_team_book is service-only' USING ERRCODE='42501';
  END IF;

  IF btrim(coalesce(p_team, '')) ~ '^\d+$' THEN
    v_pid := btrim(p_team)::bigint;
  ELSE
    SELECT e.primary_performer_id INTO v_pid
      FROM public.events e
     WHERE lower(e.primary_performer_name) = lower(btrim(p_team))
       AND e.occurs_at_local >= to_char(now(), 'YYYY-MM-DD')
     GROUP BY 1 ORDER BY count(*) DESC LIMIT 1;
  END IF;
  IF v_pid IS NULL THEN
    RETURN jsonb_build_object('error', 'team not found — pass the TEvo performer id or the exact team name');
  END IF;
  SELECT max(e.primary_performer_name) INTO v_name FROM public.events e WHERE e.primary_performer_id = v_pid;

  -- Home games use the (primary_performer_id, occurs_at_local) index; away games need the
  -- performer_ids scan over the date window.
  SELECT array_agg(id ORDER BY occ) INTO v_events FROM (
    SELECT e.id, e.occurs_at_local AS occ
      FROM public.events e
     WHERE left(e.occurs_at_local, 10) >= v_since::text
       AND (e.primary_performer_id = v_pid
            OR (NOT coalesce(p_home_only, false) AND v_pid::text = ANY (e.performer_ids::text[])))
     ORDER BY e.occurs_at_local LIMIT v_max) q;

  -- v_s4kcs_orders filtered on its COALESCEd tevo_event_id is a full scan; pre-select the
  -- order ids from the base table's tevo_event_id index and read the view once.
  WITH ord AS MATERIALIZED (
    SELECT o.tevo_event_id, o.source, o.quantity, o.price_per_ticket, o.purchase_date,
           o.event_date, o.event_name, o.order_status, o.section, o."row"
      FROM public.v_s4kcs_orders o
     WHERE o.s4k_order_id IN (SELECT s.s4k_order_id FROM public.s4kcs_orders s
                               WHERE s.tevo_event_id = ANY (v_events))
       AND o.tevo_event_id = ANY (v_events)
       AND o.order_status !~* '(reject|cancel)'
  ),
  crm AS (
    SELECT tevo_event_id,
           jsonb_build_object('orders', count(*), 'tickets', sum(quantity),
             'gross', round(sum(price_per_ticket * quantity), 2),
             'avg_per_ticket', round(sum(price_per_ticket * quantity) / nullif(sum(quantity), 0), 2),
             'last_purchase', max(purchase_date)) AS j
      FROM ord GROUP BY 1
  ),
  bm AS (
    SELECT tevo_event_id, jsonb_object_agg(source, jsonb_build_object('tickets', t, 'gross', gr)) AS j
      FROM (SELECT tevo_event_id, source, sum(quantity) AS t,
                   round(sum(price_per_ticket * quantity), 2) AS gr
              FROM ord GROUP BY 1, 2) x
     GROUP BY 1
  )
  SELECT jsonb_build_object(
    'team', jsonb_build_object('performer_id', v_pid, 'name', v_name),
    'since', v_since,
    'polling', (SELECT coalesce(jsonb_agg(jsonb_build_object('pin', p.pin_key, 'venue', p.venue_name,
                          'sources', p.sources, 'enabled', p.enabled, 'pinned_at', p.created_at)), '[]'::jsonb)
                  FROM public.listings_poll_pins p WHERE p.performer_id = v_pid),
    'games', (
      SELECT coalesce(jsonb_agg(g ORDER BY g->>'occurs_at_local'), '[]'::jsonb) FROM (
        SELECT jsonb_build_object(
          'event_id', e.id, 'name', e.name, 'occurs_at_local', e.occurs_at_local,
          'home', e.primary_performer_id = v_pid,
          'crm_sales', coalesce(crm.j, '{"orders": 0}'::jsonb)
                       || jsonb_build_object('by_marketplace', coalesce(bm.j, '{}'::jsonb)),
          'sg_orders', (SELECT jsonb_build_object('orders', count(*), 'tickets', sum(so.sale_quantity),
                           'gross', round(sum(so.payment_total), 2), 'last_order_at', max(so.created_at_sg))
                          FROM public.seatgeek_orders so
                         WHERE so.tevo_event_id = e.id AND coalesce(so.status, '') !~* '(reject|cancel)'),
          'owned_now', (SELECT jsonb_build_object('captured_at', m.captured_at,
                           'owned_tickets', m.owned_tickets_count, 'owned_listings', m.owned_groups_count,
                           'owned_median', m.owned_median_retail, 'owned_share', m.owned_share,
                           'market_median', m.retail_median, 'market_getin', m.getin_price,
                           'market_tickets', m.tickets_count)
                          FROM public.event_metrics m WHERE m.event_id = e.id
                         ORDER BY m.captured_at DESC LIMIT 1)
        ) AS g
          FROM public.events e
          LEFT JOIN crm ON crm.tevo_event_id = e.id
          LEFT JOIN bm  ON bm.tevo_event_id  = e.id
         WHERE e.id = ANY (v_events)
      ) gg),
    'totals', (SELECT jsonb_build_object('orders', count(*), 'tickets', sum(quantity),
                  'gross', round(sum(price_per_ticket * quantity), 2),
                  'avg_per_ticket', round(sum(price_per_ticket * quantity) / nullif(sum(quantity), 0), 2))
                 FROM ord),
    'recent_orders', (SELECT coalesce(jsonb_agg(r ORDER BY r->>'purchase_date' DESC NULLS LAST), '[]'::jsonb) FROM (
                       SELECT jsonb_build_object('purchase_date', purchase_date, 'event_date', event_date,
                                'event', event_name, 'marketplace', source, 'status', order_status,
                                'section', section, 'row', "row", 'quantity', quantity,
                                'price_per_ticket', round(price_per_ticket, 2)) AS r
                         FROM ord ORDER BY purchase_date DESC NULLS LAST LIMIT 25) q),
    'generated_at', now())
  INTO v_out;
  RETURN v_out;
END $$;
REVOKE ALL ON FUNCTION public.mcp_team_book(text, date, boolean, integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.mcp_team_book(text, date, boolean, integer) TO service_role;

-- VERIFY: SELECT public.mcp_team_book('16303') -> 'totals';
--         SELECT public.mcp_issue_key_ttl('test', 'internal', 'operator', interval '5 days');
-- ROLLBACK: re-apply mcp_verify_key from 20261021190000; the column and functions are additive.

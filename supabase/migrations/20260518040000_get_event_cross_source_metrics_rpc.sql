-- Migration 20260518040000 · lane:D0 (author) → A1 (apply) · writes:get_event_cross_source_metrics · reads:event_metrics,seatgeek_event_metrics,seatgeek_event_xref · pre:20260518030000 · auth:operator-approved 2026-05-17
--
-- D0 — surfaces the canonical TEvo-vs-SG side-by-side metrics in one
-- round-trip. Powers the new CROSS-SOURCE METRICS panel on the event
-- Overview tab.
--
-- Source columns per operator's metrics inventory "Cross-source alignment":
--   TEvo (event_metrics, latest row):
--     tickets_count, groups_count, retail_median, retail_p90,
--     getin_price, owned_median_retail, nonowned_median_retail
--   SG (seatgeek_event_metrics, latest row — populated by PR #204):
--     listings_all_count, listings_all_tickets, listings_all_median,
--     listings_all_p90, listings_all_min, listings_owned_median,
--     sold_price_median
--
-- The `rows` array is pre-aligned server-side so the FE renderer is a
-- dumb table loop — no field-name knowledge required client-side.
--
-- Both sides use DISTINCT ON (key) ORDER BY key, captured_at DESC
-- pattern for the latest snapshot per event. Bridge tevo↔sg via
-- seatgeek_event_xref.

CREATE OR REPLACE FUNCTION public.get_event_cross_source_metrics(p_event_id integer)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, extensions, pg_temp
AS $func$
DECLARE
  v_email       text;
  v_sg_event_id bigint;
  v_tevo        jsonb;
  v_sg          jsonb;
BEGIN
  v_email := coalesce(auth.jwt()->>'email', '');
  IF v_email NOT LIKE '%@s4kent.com' THEN
    RAISE EXCEPTION 'forbidden: % is not an @s4kent.com email', v_email USING ERRCODE = '42501';
  END IF;

  SELECT sg_event_id INTO v_sg_event_id
  FROM public.seatgeek_event_xref WHERE tevo_event_id = p_event_id LIMIT 1;

  -- TEvo side: latest event_metrics snapshot
  SELECT to_jsonb(t) INTO v_tevo
  FROM (
    SELECT DISTINCT ON (event_id)
      event_id, tickets_count, groups_count,
      retail_median, retail_p90, getin_price,
      owned_median_retail, nonowned_median_retail,
      captured_at
    FROM public.event_metrics
    WHERE event_id = p_event_id
    ORDER BY event_id, captured_at DESC
  ) t;

  -- SG side: latest seatgeek_event_metrics snapshot (PR #204 listings_all_* + listings_owned_*)
  IF v_sg_event_id IS NOT NULL THEN
    SELECT to_jsonb(s) INTO v_sg
    FROM (
      SELECT DISTINCT ON (sg_event_id)
        sg_event_id,
        listings_all_count, listings_all_tickets,
        listings_all_median, listings_all_p90, listings_all_min,
        listings_owned_median,
        sold_price_median,
        captured_at
      FROM public.seatgeek_event_metrics
      WHERE sg_event_id = v_sg_event_id
      ORDER BY sg_event_id, captured_at DESC
    ) s;
  END IF;

  RETURN jsonb_build_object(
    'event_id',    p_event_id,
    'sg_event_id', v_sg_event_id,
    'tevo',        v_tevo,
    'sg',          v_sg,
    -- Pre-aligned rows: FE renders directly without knowing column names.
    'rows', jsonb_build_array(
      jsonb_build_object('label', 'Listings count',
        'tevo', v_tevo->'groups_count',         'sg', v_sg->'listings_all_count',   'is_money', false),
      jsonb_build_object('label', 'Tickets count',
        'tevo', v_tevo->'tickets_count',        'sg', v_sg->'listings_all_tickets', 'is_money', false),
      jsonb_build_object('label', 'Ask median',
        'tevo', v_tevo->'retail_median',        'sg', v_sg->'listings_all_median',  'is_money', true),
      jsonb_build_object('label', 'Ask p90',
        'tevo', v_tevo->'retail_p90',           'sg', v_sg->'listings_all_p90',     'is_money', true),
      jsonb_build_object('label', 'Get-in / min',
        'tevo', v_tevo->'getin_price',          'sg', v_sg->'listings_all_min',     'is_money', true),
      jsonb_build_object('label', 'Owned-only median',
        'tevo', v_tevo->'owned_median_retail',  'sg', v_sg->'listings_owned_median','is_money', true),
      jsonb_build_object('label', 'Realized sale median',
        'tevo', null,                            'sg', v_sg->'sold_price_median',    'is_money', true)
    )
  );
END $func$;

REVOKE ALL ON FUNCTION public.get_event_cross_source_metrics(integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_event_cross_source_metrics(integer) TO anon, authenticated;

COMMENT ON FUNCTION public.get_event_cross_source_metrics(integer) IS
  'D0 event Overview — canonical TEvo-vs-SG side-by-side metrics in one round-trip. 7 pre-aligned rows. Uses listings_all_*/listings_owned_* from PR #204 (not deprecated cost_*). Email-gated.';

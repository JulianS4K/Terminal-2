-- Migration 20260707200100 · level:2 · lane:A1 · operator-directed (2026-07-07)
-- ============================================================================
-- SALE-DATE HAZARD + PRICE↔SELL-BY FRONTIER (v1) — read-only, display-only.
--
-- The headline coupled output: for a listing you hold, estimate WHEN it sells at
-- a given ask, and sweep asks into a frontier so staggered pricing is a decision
-- ("list at $X → ~Y% it clears by the event, p50 sell-by date Z"). Companion to
-- predict_event_clearing_price (mig 20260707200040). No write-back / no reprice.
--
-- Lane:     A1 (read-only model artifacts). Touches W: predict_listing_sale_date,
--           get_listing_price_frontier (both NEW fns). Touches R: events,
--           seatgeek_sales_snapshots, seatgeek_event_xref, seatdata_sales_snapshots,
--           listings_snapshots, section_metrics, predict_event_clearing_price.
-- Pre-reqs: 20260707200040 (predict_event_clearing_price).
--
-- MODEL — section-absorption queue with a Poisson hazard (normal-approx):
--   λ  = realized section sales/day (SG + SeatData, deduped, 30d), floored.
--        NB realized-channel-only (excludes TicketNetwork/Vivid/box office) so λ is a
--        LOWER bound and P(sell) is CONSERVATIVE. dte-acceleration lifts λ near the event.
--   k(P) = tickets priced ≤ ask P ahead of you in the section ladder (listings_snapshots),
--          i.e. your queue position. Higher ask ⇒ larger k ⇒ later, less-likely sale.
--   Time to clear k arrivals ~ Erlang(k, λ): mean=k/λ, sd=√k/λ. Normal-approx:
--     P(sell before event) = Φ((T_event − k/λ)/(√k/λ)),  Φ(z)≈1/(1+e^(−1.702 z))
--     p50 sell-by ≈ now + k/λ ;  p80 ≈ now + k/λ + 0.8416·√k/λ
--   Frontier: over the ask grid, report P(sell before event) + p50/p80 + expected_value(P)=
--   P·P(sell). recommended_ask is ANCHORED on the price model's fair clearing (NOT EV-max —
--   λ excludes the broker/TicketNetwork channel, so EV-max over SG+SeatData-only absorption
--   would under-recommend). clear_by_event_ask = highest ask still ≥50% to clear in time.
--   (Poisson→NegBinomial + a fitted, cross-channel-calibrated hazard is v3; v1 is directional.)
--
-- Idempotent (CREATE OR REPLACE). No cron. Read-only.
-- ============================================================================

-- ── 1. Single-ask sale-date hazard ───────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.predict_listing_sale_date(
  p_event_id bigint, p_section text, p_ask numeric)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $function$
DECLARE
  v_email text; v_res jsonb;
BEGIN
  v_email := coalesce(auth.jwt()->>'email','');
  IF v_email NOT LIKE '%@s4kent.com'
     AND current_user NOT IN ('service_role','postgres','supabase_admin') THEN
    RAISE EXCEPTION 'forbidden: % is not @s4kent.com', v_email USING ERRCODE='42501';
  END IF;

  WITH ev AS (
    SELECT (NULLIF(e.occurs_at_local,'')::timestamptz::date) AS event_date,
           greatest(0, (NULLIF(e.occurs_at_local,'')::timestamptz::date
                        - (now() AT TIME ZONE 'UTC')::date)) AS dte
    FROM public.events e WHERE e.id = p_event_id
  ),
  sg AS (
    SELECT count(*) n FROM (
      SELECT DISTINCT ss.sg_sale_id FROM public.seatgeek_sales_snapshots ss
      JOIN public.seatgeek_event_xref x ON x.sg_event_id = ss.sg_event_id
      WHERE x.tevo_event_id = p_event_id AND lower(btrim(ss.section)) = lower(btrim(p_section))
        AND ss.sale_at_utc >= now() - interval '30 days') q
  ),
  sd AS (
    SELECT count(*) n FROM (
      SELECT DISTINCT content_hash FROM public.seatdata_sales_snapshots
      WHERE tevo_event_id = p_event_id AND lower(btrim(section)) = lower(btrim(p_section))
        AND sale_timestamp >= now() - interval '30 days') q
  ),
  lam AS (
    -- base daily rate + mild dte-acceleration (sales quicken toward the event)
    SELECT greatest(0.02, (sg.n + sd.n) / 30.0)
           * (1 + 1.0 * greatest(0, (21 - ev.dte)) / 21.0) AS lambda
    FROM sg, sd, ev
  ),
  ladder AS (  -- queue position k = tickets priced ≤ ask in the section's live ladder
    SELECT max(cum) AS k FROM (
      SELECT sum(ls.quantity) OVER (ORDER BY ls.retail_price) AS cum, ls.retail_price
      FROM public.listings_snapshots ls
      JOIN (SELECT max(captured_at) c FROM public.listings_snapshots WHERE event_id = p_event_id) m
        ON ls.captured_at = m.c
      WHERE ls.event_id = p_event_id AND lower(btrim(ls.section)) = lower(btrim(p_section))
        AND coalesce(ls.is_ancillary,false) = false AND ls.retail_price <= p_ask
    ) z
  ),
  fallback_k AS (  -- if the section isn't in the live ladder, approximate from depth
    SELECT coalesce((SELECT k FROM ladder),
                    greatest(1, (SELECT round(tickets_count/2.0) FROM public.section_metrics sm
                                  WHERE sm.event_id = p_event_id AND lower(btrim(sm.section)) = lower(btrim(p_section))
                                  ORDER BY captured_at DESC LIMIT 1)),
                    1)::numeric AS k
  ),
  calc AS (
    SELECT ev.dte, ev.event_date, lam.lambda, fk.k,
           fk.k / lam.lambda AS mean_days,
           sqrt(fk.k) / lam.lambda AS sd_days
    FROM ev, lam, fallback_k fk
  )
  SELECT jsonb_build_object(
    'event_id', p_event_id, 'section', p_section, 'ask', p_ask,
    'dte_days', dte,
    'lambda_per_day', round(lambda::numeric, 3),
    'queue_rank_k', k,
    'expected_days_to_sell', round(mean_days::numeric, 1),
    'p50_sell_by', least(event_date, (now() AT TIME ZONE 'UTC')::date + ceil(mean_days)::int),
    'p80_sell_by', least(event_date, (now() AT TIME ZONE 'UTC')::date + ceil(mean_days + 0.8416*sd_days)::int),
    'p_sell_before_event_pct', round((100.0 / (1 + exp(-1.702 * (dte - mean_days) / NULLIF(sd_days,0))))::numeric, 1),
    'basis', 'poisson_absorption_normal_approx; λ=SG+SeatData realized only (conservative lower bound)'
  ) INTO v_res
  FROM calc;
  RETURN v_res;
END; $function$;
REVOKE ALL ON FUNCTION public.predict_listing_sale_date(bigint, text, numeric) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.predict_listing_sale_date(bigint, text, numeric) TO authenticated, service_role;
COMMENT ON FUNCTION public.predict_listing_sale_date(bigint, text, numeric) IS
  'Estimated sale date for a listing at ask P: section-absorption Poisson hazard '
  '(normal-approx) → p50/p80 sell-by + P(sell before event). λ is SG+SeatData realized '
  'only (conservative). Read-only, @s4kent.com-gated. A1 mig 20260707200100.';

-- ── 2. Price↔sell-by FRONTIER + recommended ask ──────────────────────────────
CREATE OR REPLACE FUNCTION public.get_listing_price_frontier(
  p_event_id bigint, p_section text)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $function$
DECLARE
  v_email text; v_res jsonb; v_lambda numeric; v_dte int; v_event_date date; v_fair numeric;
BEGIN
  v_email := coalesce(auth.jwt()->>'email','');
  IF v_email NOT LIKE '%@s4kent.com'
     AND current_user NOT IN ('service_role','postgres','supabase_admin') THEN
    RAISE EXCEPTION 'forbidden: % is not @s4kent.com', v_email USING ERRCODE='42501';
  END IF;

  SELECT greatest(0, (NULLIF(e.occurs_at_local,'')::timestamptz::date - (now() AT TIME ZONE 'UTC')::date)),
         NULLIF(e.occurs_at_local,'')::timestamptz::date
    INTO v_dte, v_event_date
  FROM public.events e WHERE e.id = p_event_id;

  -- λ once (SG + SeatData realized, 30d, floored + dte-accelerated)
  SELECT greatest(0.02, (
           (SELECT count(*) FROM (SELECT DISTINCT ss.sg_sale_id FROM public.seatgeek_sales_snapshots ss
              JOIN public.seatgeek_event_xref x ON x.sg_event_id=ss.sg_event_id
              WHERE x.tevo_event_id=p_event_id AND lower(btrim(ss.section))=lower(btrim(p_section))
                AND ss.sale_at_utc>=now()-interval '30 days') a)
         + (SELECT count(*) FROM (SELECT DISTINCT content_hash FROM public.seatdata_sales_snapshots
              WHERE tevo_event_id=p_event_id AND lower(btrim(section))=lower(btrim(p_section))
                AND sale_timestamp>=now()-interval '30 days') b)
         ) / 30.0) * (1 + 1.0*greatest(0,(21 - v_dte))/21.0)
    INTO v_lambda;

  -- v1.1 cross-channel uplift: SG selling-pressure velocity (v_sg_blindspot_movers).
  -- coalesce→0 keeps λ unchanged when the view is empty (SG-listings feed dark since
  -- 2026-06-26 → 0 rows now); auto-activates when that feed returns.
  v_lambda := v_lambda * (1 + coalesce((
      SELECT greatest(0, b.sales_velocity_pct) / 100.0 * 0.5
      FROM public.v_sg_blindspot_movers b
      JOIN public.seatgeek_event_xref x ON x.sg_event_id = b.sg_event_id
      WHERE x.tevo_event_id = p_event_id LIMIT 1), 0));

  -- Fair clearing from the price model (well-calibrated on realized PRICES). We anchor
  -- the recommended ask here, NOT on EV-max: λ excludes the broker/TicketNetwork channel,
  -- so an EV-max over SG+SeatData-only absorption would recommend an unrealistically low ask.
  v_fair := (public.predict_event_clearing_price(p_event_id, p_section) ->> 'expected_clearing')::numeric;

  WITH ladder AS (  -- the section's live ask ladder = candidate-ask grid + cumulative depth
    SELECT ls.retail_price AS ask,
           sum(ls.quantity) OVER (ORDER BY ls.retail_price) AS k
    FROM public.listings_snapshots ls
    JOIN (SELECT max(captured_at) c FROM public.listings_snapshots WHERE event_id=p_event_id) m
      ON ls.captured_at = m.c
    WHERE ls.event_id=p_event_id AND lower(btrim(ls.section))=lower(btrim(p_section))
      AND coalesce(ls.is_ancillary,false)=false
  ),
  grid AS ( SELECT ask, max(k) AS k FROM ladder GROUP BY ask ),
  kfair AS ( SELECT coalesce(max(k),0) + 0.5 AS k FROM ladder WHERE ask <= v_fair ),  -- queue rank at the fair ask
  hz AS (
    SELECT g.ask, g.k, g.k / v_lambda AS mean_days, sqrt(g.k) / v_lambda AS sd_days,
           1.0 / (1 + exp(-1.702 * (v_dte - g.k/v_lambda) / NULLIF(sqrt(g.k)/v_lambda,0))) AS p_before
    FROM grid g
  ),
  fr AS (
    SELECT ask, k, round(p_before::numeric,3) AS p_sell_before_event,
           least(v_event_date, (now() AT TIME ZONE 'UTC')::date + ceil(mean_days)::int) AS p50_sell_by,
           least(v_event_date, (now() AT TIME ZONE 'UTC')::date + ceil(mean_days + 0.8416*sd_days)::int) AS p80_sell_by,
           round((ask * p_before)::numeric, 2) AS expected_value
    FROM hz
  ),
  at_fair AS (  -- sell-by risk AT the recommended (fair-clearing) ask
    SELECT k.k,
           round((100.0/(1+exp(-1.702*(v_dte - k.k/v_lambda)/NULLIF(sqrt(k.k)/v_lambda,0))))::numeric,1) AS p_before_pct,
           least(v_event_date, (now() AT TIME ZONE 'UTC')::date + ceil(k.k/v_lambda)::int) AS p50_sell_by,
           least(v_event_date, (now() AT TIME ZONE 'UTC')::date + ceil(k.k/v_lambda + 0.8416*sqrt(k.k)/v_lambda)::int) AS p80_sell_by
    FROM kfair k
  )
  SELECT jsonb_build_object(
    'event_id', p_event_id, 'section', p_section,
    'dte_days', v_dte, 'lambda_per_day', round(v_lambda::numeric,3),
    'fair_clearing', round(v_fair::numeric,2),
    'recommended_ask', round(v_fair::numeric,2),   -- anchored on the price model
    'at_recommended', (SELECT jsonb_build_object(
        'ask', round(v_fair::numeric,2), 'queue_rank_k', k,
        'p_sell_before_event_pct', p_before_pct,
        'p50_sell_by', p50_sell_by, 'p80_sell_by', p80_sell_by) FROM at_fair),
    'clear_by_event_ask', (SELECT max(ask) FROM fr WHERE p_sell_before_event >= 0.5),  -- price to be ~sure it clears
    'max_ev_ask', (SELECT ask FROM fr ORDER BY expected_value DESC NULLS LAST LIMIT 1), -- reference only
    'frontier', coalesce((SELECT jsonb_agg(jsonb_build_object(
        'ask', ask, 'queue_rank_k', k,
        'p_sell_before_event', p_sell_before_event,
        'p50_sell_by', p50_sell_by, 'p80_sell_by', p80_sell_by,
        'expected_value', expected_value) ORDER BY ask) FROM fr), '[]'::jsonb),
    'basis', 'recommended_ask = model fair clearing; frontier shows sell-by RISK per ask. '
             'λ = SG+SeatData realized only (excludes the broker/TicketNetwork channel) → P(sell) is a '
             'CONSERVATIVE floor. Empty frontier = section not in the live ask ladder.'
  ) INTO v_res;
  RETURN v_res;
END; $function$;
REVOKE ALL ON FUNCTION public.get_listing_price_frontier(bigint, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_listing_price_frontier(bigint, text) TO authenticated, service_role;
COMMENT ON FUNCTION public.get_listing_price_frontier(bigint, text) IS
  'Price↔sell-by frontier for a section: over the live ask ladder, returns per-ask '
  'P(sell before event) + p50/p80 sell-by + expected_value (ask×P), the fair clearing '
  '(predict_event_clearing_price), and the expected-value-maximizing recommended_ask. '
  'Powers staggered pricing. Read-only, @s4kent.com-gated. A1 mig 20260707200100.';

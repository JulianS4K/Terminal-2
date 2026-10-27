-- Migration 20261027190000 · level:ops · lane:A1 (data plane — price forecaster) · writes:_price_form_mult()(new),predict_event_clearing_price()(patch in place) · reads:cast_price_ref,get_event_demand_context · pre:A1-ML-2 (KANBAN)
--
-- ============================================================================
-- price forecaster: cap stale priors (A1-ML-2) + team form (wins / losses)
--
-- WHAT WAS WRONG (MCP simulation 2026-10-27, Pistons at Knicks sec 225): expected_clearing
-- $371 with 9 realized sales at ~$203 and a section ask median of $333. The away-adjusted
-- prior was $2,104 — the section prior × road_draw_mult 5 (cast_price_ref says Detroit's away
-- median is 5× its overall, a stale / thin row). The MCP guard only re-anchors when there
-- are no sales, so this went out.
--
-- CHANGES (patched into the live function body; each replaced fragment is asserted first)
--   1. road_draw_mult capped at 1.5 (was 5) and taken only from a cast_price_ref row
--      refreshed in the last 30 days with ≥ 10 away events; home_performer_median (display)
--      likewise needs ≥ 10 home events and a 30-day refresh.
--   2. every prior signal (opponent section, away-adjusted, SeatData, performer history) is
--      clamped to ≤ 2× the live ask.
--   3. team form: _price_form_mult(demand_context) = 1 + 0.30·(home win% − .5)·g_h/(g_h+15)
--      + 0.15·(away win% − .5)·g_a/(g_a+15), clamped to 0.85–1.15 (g = games played, so the
--      first weeks barely move it). Applied at ≥ half strength even with realized sales (45 d
--      of sales mostly predate the current record); output gains `form_mult`.
--
-- ROLLBACK: re-apply predict_event_clearing_price from its previous migration (or invert
--           the replacements below); DROP FUNCTION _price_form_mult(jsonb).
-- ============================================================================

SET LOCAL lock_timeout = '10s';

CREATE OR REPLACE FUNCTION public._price_form_mult(p_ctx jsonb)
RETURNS numeric
LANGUAGE sql
IMMUTABLE
AS $$
  WITH t AS (
    SELECT v.coefficient,
           split_part(p_ctx -> v.side ->> 'record', '-', 1)::int AS wins,
           split_part(p_ctx -> v.side ->> 'record', '-', 2)::int AS losses
      FROM (VALUES ('home', 0.30), ('away', 0.15)) v(side, coefficient)
     WHERE (p_ctx -> v.side ->> 'record') ~ '^\d+-\d+'),
  c AS (SELECT sum(coefficient * (wins::numeric / nullif(wins + losses, 0) - 0.5)
                   * (wins + losses)::numeric / (wins + losses + 15)) AS adj
          FROM t WHERE wins + losses > 0)
  SELECT round(greatest(0.85, least(1.15, 1 + coalesce((SELECT adj FROM c), 0)))::numeric, 4)
$$;
REVOKE ALL ON FUNCTION public._price_form_mult(jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._price_form_mult(jsonb) TO service_role;

DO $patch$
DECLARE
  v_def text := pg_get_functiondef('public.predict_event_clearing_price(bigint,text)'::regprocedure);
  r     record;
BEGIN
  IF position('_price_form_mult' in v_def) > 0 THEN
    RAISE NOTICE 'predict_event_clearing_price already patched';
    RETURN;
  END IF;
  FOR r IN SELECT * FROM (VALUES
    -- 1. road draw: cap + freshness / sample gate
    ('greatest(1.0, least(5.0, cr.away_median_price / NULLIF(cr.overall_median_price,0))) AS mult',
     'greatest(1.0, least(1.5, cr.away_median_price / NULLIF(cr.overall_median_price,0))) AS mult'),
    ('FROM public.cast_price_ref cr, ev WHERE lower(cr.entity_name) = ev.away_name ORDER BY',
     'FROM public.cast_price_ref cr, ev WHERE lower(cr.entity_name) = ev.away_name AND cr.refreshed_at > now() - interval ''30 days'' AND coalesce(cr.away_events,0) >= 10 ORDER BY'),
    ('WHERE cr.tevo_performer_id = ev.primary_performer_id LIMIT 1) AS home_performer_median',
     'WHERE cr.tevo_performer_id = ev.primary_performer_id AND cr.refreshed_at > now() - interval ''30 days'' AND coalesce(cr.home_events,0) >= 10 LIMIT 1) AS home_performer_median'),
    -- 2. priors ≤ 2× the live ask
    ('opp_prior_med AS s_opp,',
     'CASE WHEN base_ask IS NOT NULL THEN least(opp_prior_med, 2 * base_ask) ELSE opp_prior_med END AS s_opp,'),
    ('THEN perf_prior_med * coalesce(road_mult,1.0) END AS s_awayadj',
     'THEN least(perf_prior_med * coalesce(road_mult,1.0), coalesce(2 * base_ask, perf_prior_med * coalesce(road_mult,1.0))) END AS s_awayadj'),
    ('THEN sd_med * (section_ask / NULLIF(event_ask,0)) END AS s_sd',
     'THEN least(sd_med * (section_ask / NULLIF(event_ask,0)), 2 * base_ask) END AS s_sd'),
    ('THEN hist_med * (section_ask / NULLIF(event_ask,0)) END AS s_hist',
     'THEN least(hist_med * (section_ask / NULLIF(event_ask,0)), 2 * base_ask) END AS s_hist'),
    -- 3. team form
    ($o$coalesce(est.clearing_blend, est.base_ask) * (1 + ((est.demand_ctx->>'demand_mult')::numeric - 1) * (4.0/(coalesce(est.realized_n,0)+4))) AS clearing FROM est)$o$,
     $n$coalesce(est.clearing_blend, est.base_ask) * (1 + (coalesce((est.demand_ctx->>'demand_mult')::numeric, 1) - 1) * (4.0/(coalesce(est.realized_n,0)+4)))
        * (1 + (public._price_form_mult(est.demand_ctx) - 1) * (0.5 + 0.5 * 4.0/(coalesce(est.realized_n,0)+4))) AS clearing,
      public._price_form_mult(est.demand_ctx) AS form_mult FROM est)$n$),
    ($o$'home_performer_median', round(home_performer_median::numeric, 2), 'demand_mult', demand_mult,$o$,
     $n$'home_performer_median', round(home_performer_median::numeric, 2), 'demand_mult', demand_mult, 'form_mult', form_mult,$n$)
  ) v(old, new) LOOP
    IF position(r.old in v_def) = 0 THEN
      RAISE EXCEPTION 'predict_event_clearing_price patch: fragment not found: %', left(r.old, 80);
    END IF;
    v_def := replace(v_def, r.old, r.new);
  END LOOP;
  EXECUTE v_def;
END $patch$;

-- VERIFY: SELECT predict_event_clearing_price(3465615, '225') -> 'expected_clearing', ... -> 'form_mult', ... -> 'road_draw_mult';

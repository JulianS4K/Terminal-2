-- Migration 20260708180040 · level:2 · lane:A1 · operator-directed (2026-07-08)
-- ============================================================================
-- FINAL-WEEK PRICE-DECAY CURVE + EVENT-PREDICTIONS RPC (read-only, display).
--
-- (1) clearing_dte_curve — how the clearing LEVEL drifts toward the event, by
--     category × days-to-event, normalized per event. Lets the forecaster project
--     the clearing price to a FUTURE day (rolling / event-day), not just "now".
--     Backtest (Phillies@Reds, predict from ≤5d ago): applying this curve drops
--     event-day MAPE ~28%→~14% and removes the +20% over-prediction bias. Measured
--     shape for games (level vs 22-60d): 60d+ 1.01 · 22-60d 1.00 · 8-21d 0.94 ·
--     4-7d 0.86 · 2-3d 0.81 · 0-1d 0.73 (n 300-1300/bucket).
-- (2) project_event_clearing_price(event,section,target_dte) — predict "now" ×
--     curve[target]/curve[now].
-- (3) get_event_predictions(event) — resolves our EVO-OWNED sections and returns,
--     per section, clearing at now / rolling(+4d) / event-day + the sell-by frontier.
--     Powers the event-page Predictions tab. Read-only; no reprice path.
--
-- Lane:  A1. Touches W (all NEW model-owned): clearing_dte_curve,
--        rebuild_clearing_dte_curve(interval), get_clearing_curve_level(text,int),
--        project_event_clearing_price(bigint,text,int), get_event_predictions(bigint),
--        cron clearing_dte_curve_weekly. Touches R: venue_section_price_daily, events,
--        performer_metadata, listings_snapshots, predict_event_clearing_price,
--        get_listing_price_frontier.
-- Pre-reqs: 20260707200040 (predict_event_clearing_price, price_dte_bucket),
--           20260707200100 (get_listing_price_frontier), 20260705153500 (venue_section_price_daily).
-- Idempotent (CREATE OR REPLACE + IF NOT EXISTS + cron upsert).
-- ============================================================================

-- ── 1. The curve table ───────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.clearing_dte_curve (
  category    text NOT NULL,       -- Sports|Concerts|Comedy|Theater|Other
  dte_bucket  text NOT NULL,       -- price_dte_bucket() label
  level_index numeric,             -- median per-event level, normalized to that category's 22-60d = 1.0
  n           integer,
  computed_at timestamptz DEFAULT now(),
  PRIMARY KEY (category, dte_bucket)
);
ALTER TABLE public.clearing_dte_curve ENABLE ROW LEVEL SECURITY;
GRANT SELECT ON public.clearing_dte_curve TO authenticated, service_role;
COMMENT ON TABLE public.clearing_dte_curve IS
  'Clearing-level curve by category × days-to-event, per-event-normalized to the 22-60d '
  'bucket. Projects clearing price to a future day (removes the final-week over-prediction). '
  'Rebuilt weekly from venue_section_price_daily. A1 mig 20260708180040.';

-- Builder: per-event level by (category, dte_bucket), normalized to the event's 22-60d, medianed.
CREATE OR REPLACE FUNCTION public.rebuild_clearing_dte_curve(p_window interval DEFAULT '45 days'::interval)
RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public','pg_temp'
AS $function$
DECLARE v_n integer;
BEGIN
  IF current_user NOT IN ('service_role','postgres','supabase_admin') THEN
    RAISE EXCEPTION 'forbidden: %', current_user USING ERRCODE='42501';
  END IF;
  WITH ev_day AS (
    SELECT d.event_id,
           CASE WHEN d.event_type='game' THEN 'Sports'
                WHEN pm.top_category_name IN ('Sports','Concerts','Comedy','Theater') THEN pm.top_category_name
                ELSE 'Other' END AS category,
           public.price_dte_bucket(d.days_to_event) AS bucket,
           percentile_cont(0.5) WITHIN GROUP (ORDER BY d.retail_median) AS med
    FROM public.venue_section_price_daily d
    LEFT JOIN public.performer_metadata pm ON pm.performer_id = d.performer_id
    WHERE d.days_to_event BETWEEN 0 AND 90 AND d.retail_median > 0
      AND d.snapshot_date >= (now() AT TIME ZONE 'utc')::date - (extract(day FROM p_window))::int
    GROUP BY d.event_id, 2, public.price_dte_bucket(d.days_to_event)
  ),
  ref AS (SELECT event_id, category, med AS ref_med FROM ev_day WHERE bucket='22-60d' AND med>0),
  norm AS (
    SELECT e.category, e.bucket, e.med/r.ref_med AS ratio
    FROM ev_day e JOIN ref r ON r.event_id=e.event_id AND r.category=e.category
  )
  INSERT INTO public.clearing_dte_curve (category, dte_bucket, level_index, n, computed_at)
  SELECT category, bucket, percentile_cont(0.5) WITHIN GROUP (ORDER BY ratio), count(*), now()
  FROM norm
  GROUP BY category, bucket
  HAVING count(*) >= 20
  ON CONFLICT (category, dte_bucket) DO UPDATE SET
    level_index=excluded.level_index, n=excluded.n, computed_at=excluded.computed_at;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n;
END; $function$;
REVOKE ALL ON FUNCTION public.rebuild_clearing_dte_curve(interval) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rebuild_clearing_dte_curve(interval) TO service_role;

SELECT cron.schedule('clearing_dte_curve_weekly', '25 8 * * 0', $cron$
DO $body$ BEGIN
  IF NOT public.cron_should_fire('clearing_dte_curve_weekly') THEN RETURN; END IF;
  PERFORM public.rebuild_clearing_dte_curve();
END $body$;
$cron$);
INSERT INTO public.cron_policy (jobname, peak_hours_et, peak_min_interval_min, offpeak_min_interval_min, daily_max_fires, enabled, notes)
VALUES ('clearing_dte_curve_weekly', ARRAY[]::int[], 10080, 10080, 1, true,
        'Clearing-level dte curve rebuild. Weekly Sun 08:25 UTC. A1 mig 20260708180040.')
ON CONFLICT (jobname) DO NOTHING;

-- ── 2. Curve level lookup (default 1.0 when curve empty/thin → no projection) ─
CREATE OR REPLACE FUNCTION public.get_clearing_curve_level(p_category text, p_dte integer)
RETURNS numeric
LANGUAGE sql STABLE SET search_path TO 'public','pg_temp'
AS $function$
  SELECT coalesce(
    (SELECT level_index FROM public.clearing_dte_curve
      WHERE category = p_category AND dte_bucket = public.price_dte_bucket(p_dte)),
    (SELECT level_index FROM public.clearing_dte_curve
      WHERE category = 'Other' AND dte_bucket = public.price_dte_bucket(p_dte)),
    1.0);
$function$;
REVOKE ALL ON FUNCTION public.get_clearing_curve_level(text,integer) FROM anon;
GRANT EXECUTE ON FUNCTION public.get_clearing_curve_level(text,integer) TO authenticated, service_role;

-- ── 3. Project the clearing price to a target days-to-event ──────────────────
CREATE OR REPLACE FUNCTION public.project_event_clearing_price(
  p_event_id bigint, p_section text, p_target_dte integer)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public','pg_temp'
AS $function$
DECLARE
  v_email text; v_now jsonb; v_cat text; v_dte int; v_ratio numeric; v_clr numeric;
BEGIN
  v_email := coalesce(auth.jwt()->>'email','');
  IF v_email NOT LIKE '%@s4kent.com'
     AND current_user NOT IN ('service_role','postgres','supabase_admin') THEN
    RAISE EXCEPTION 'forbidden: % is not @s4kent.com', v_email USING ERRCODE='42501';
  END IF;

  v_now := public.predict_event_clearing_price(p_event_id, p_section);
  v_cat := v_now->>'category';
  v_dte := (v_now->>'dte_days')::int;
  v_clr := (v_now->>'expected_clearing')::numeric;
  v_ratio := public.get_clearing_curve_level(v_cat, greatest(0,p_target_dte))
             / NULLIF(public.get_clearing_curve_level(v_cat, greatest(0,v_dte)),0);

  RETURN jsonb_build_object(
    'event_id', p_event_id, 'section', p_section,
    'from_dte', v_dte, 'target_dte', greatest(0,p_target_dte),
    'clearing_now', round(v_clr,2),
    'projected_clearing', round((v_clr * coalesce(v_ratio,1.0))::numeric, 2),
    'curve_ratio', round(coalesce(v_ratio,1.0)::numeric, 3),
    'category', v_cat
  );
END; $function$;
REVOKE ALL ON FUNCTION public.project_event_clearing_price(bigint,text,integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.project_event_clearing_price(bigint,text,integer) TO authenticated, service_role;
COMMENT ON FUNCTION public.project_event_clearing_price(bigint,text,integer) IS
  'Clearing price projected to p_target_dte = predict_event_clearing_price(now) × '
  'clearing_dte_curve[target]/[now]. Read-only, @s4kent.com-gated. A1 mig 20260708180040.';

-- ── 4. Event predictions for our EVO-owned sections (powers the Predictions tab) ─
CREATE OR REPLACE FUNCTION public.get_event_predictions(p_event_id bigint)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public','pg_temp'
AS $function$
DECLARE
  v_email text; v_cap timestamptz; v_dte int; v_cat text; v_rows jsonb := '[]'::jsonb;
  r record; v_now jsonb; v_fr jsonb; v_clr numeric; v_lvl_now numeric;
BEGIN
  v_email := coalesce(auth.jwt()->>'email','');
  IF v_email NOT LIKE '%@s4kent.com'
     AND current_user NOT IN ('service_role','postgres','supabase_admin') THEN
    RAISE EXCEPTION 'forbidden: % is not @s4kent.com', v_email USING ERRCODE='42501';
  END IF;

  SELECT (NULLIF(e.occurs_at_local,'')::timestamptz::date - (now() AT TIME ZONE 'utc')::date),
         CASE WHEN pm.top_category_name IN ('Sports','Concerts','Comedy','Theater')
              THEN pm.top_category_name ELSE 'Other' END
    INTO v_dte, v_cat
  FROM public.events e LEFT JOIN public.performer_metadata pm ON pm.performer_id=e.primary_performer_id
  WHERE e.id = p_event_id;

  -- latest owned capture for this event
  SELECT max(captured_at) INTO v_cap
  FROM public.listings_snapshots WHERE event_id = p_event_id AND is_owned;

  v_lvl_now := public.get_clearing_curve_level(v_cat, greatest(0, coalesce(v_dte,0)));

  IF v_cap IS NOT NULL THEN
    FOR r IN
      SELECT lower(btrim(section)) AS section, sum(quantity) AS qty, min(retail_price) AS our_ask
      FROM public.listings_snapshots
      WHERE event_id = p_event_id AND is_owned AND captured_at = v_cap
        AND coalesce(is_ancillary,false) = false
      GROUP BY lower(btrim(section))
      ORDER BY 1
    LOOP
      v_now := public.predict_event_clearing_price(p_event_id, r.section);
      v_fr  := public.get_listing_price_frontier(p_event_id, r.section);
      v_clr := (v_now->>'expected_clearing')::numeric;

      v_rows := v_rows || jsonb_build_object(
        'section', r.section, 'our_qty', r.qty, 'our_ask', r.our_ask,
        'clearing_now', round(v_clr,2),
        'clearing_rolling', round((v_clr
            * public.get_clearing_curve_level(v_cat, greatest(0, coalesce(v_dte,0)-4))
            / NULLIF(v_lvl_now,0))::numeric, 2),
        'clearing_event_day', round((v_clr
            * public.get_clearing_curve_level(v_cat, 0) / NULLIF(v_lvl_now,0))::numeric, 2),
        'lo', (v_now->>'lo')::numeric, 'hi', (v_now->>'hi')::numeric,
        'recommended_ask', (v_fr->>'recommended_ask')::numeric,
        'clear_by_event_ask', (v_fr->>'clear_by_event_ask')::numeric,
        'p_sell_before_event_pct', ((v_fr->'at_recommended')->>'p_sell_before_event_pct')::numeric,
        'p50_sell_by', (v_fr->'at_recommended')->>'p50_sell_by',
        'own_book_gap_pct', ((v_now->'demand_context'->'own_book_gap')->>'gap_pct')::numeric,
        'basis', v_now->>'basis'
      );
    END LOOP;
  END IF;

  RETURN jsonb_build_object(
    'event_id', p_event_id,
    'dte_days', v_dte,
    'category', v_cat,
    'owned_section_count', jsonb_array_length(v_rows),
    'curve_asof', (SELECT max(computed_at) FROM public.clearing_dte_curve),
    'rows', v_rows,
    'note', 'clearing at now / rolling(+4d) / event-day via clearing_dte_curve; frontier = sell-by. '
            'EVO-owned sections only (is_owned latest capture). Read-only.'
  );
END; $function$;
REVOKE ALL ON FUNCTION public.get_event_predictions(bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_event_predictions(bigint) TO authenticated, service_role;
COMMENT ON FUNCTION public.get_event_predictions(bigint) IS
  'Per EVO-owned section: clearing at now/rolling(+4d)/event-day + sell-by frontier + '
  'own-book gap. Powers the event-page Predictions tab. Read-only, @s4kent.com-gated. '
  'A1 mig 20260708180040.';

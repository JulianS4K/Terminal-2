-- Migration 20260811201500 · lane:D0 (author) → applier (apply) · writes:zone_price_baseline [table], rebuild_zone_price_baseline(int) [fn], get_zone_baseline(text,bigint,bigint,bigint,text,int,text) [fn], cron zone_price_baseline_weekly · reads:zone_price_observations · pre:zone_price_observations (feature store; mig era 20260708) · auth:builder service_role-guarded SECDEF; resolver email-gated read SECDEF (authenticated @s4kent.com)
--
-- WHY (operator-directed 2026-08-11). Axis 4 of the deal detector — a CROSS-EVENT
-- COMPARABLE anchor. The within-event cross-section (Axis 1) + P(split) (Axis Q) +
-- MA/DTE trajectory (Axis 2/3) all judge a listing against THIS event. This axis
-- adds "what does this zone USUALLY cost for a comparable event?" so an entire
-- zone priced below its historical norm surfaces as a macro opportunity (or a soft
-- event), and one priced above surfaces as rich — independent of the current book.
--
-- The metrics already exist: zone_price_observations is a per-event × per-zone
-- feature store (95k rows / 5.5k events) carrying performer_id, venue_id,
-- opponent_performer_id, home_away, event_dow, perf_category, perf_event_type and
-- zone retail_median / getin. This migration ROLLS IT UP into a zone baseline keyed
-- by the operator's combos, with a materialized FALLBACK LADDER so a sparse combo
-- degrades gracefully instead of returning nothing:
--
--   SPORTS (perf_event_type='game') — opponent matters:
--     grain perf_opp_dow : venue × home_performer × opponent × dow × zone   (finest)
--     grain perf_opp     : venue × home_performer × opponent × zone
--     grain perf_dow     : venue × home_performer × dow × zone
--     grain perf         : venue × home_performer × zone                    (coarsest)
--   TOURS (non-game) — performer is transient, so key on venue × category:
--     grain venue_cat_dow: venue × perf_category × dow × zone
--     grain venue_cat    : venue × perf_category × zone
--
-- Day-of-week is a first-order factor (measured: a well-covered MLB team runs ~75%
-- higher weekend vs midweek in the SAME zone), which is why every fine grain carries
-- event_dow and the ladder only drops it one rung down.
--
-- get_zone_baseline() walks finest→coarsest and returns the first grain meeting a
-- min-sample floor; if NOTHING is pre-built for the combo it computes the coarsest
-- grain on demand from zone_price_observations and PERSISTS it (the operator's "if
-- none create"), so the table self-fills as new combos are queried.
--
-- ZONE VOCAB: baseline zones inherit zone_price_observations.zone (+ zone_source).
-- Matching a live event's curated section_metrics.zone to this vocab is handled at
-- RPC-integration time (next migration) — this migration builds the store only.
-- FRESHNESS: zone_price_observations last refreshed 2026-07-08 (builder cron looks
-- paused). Historical DOW/venue baselines stay valid; recent events are absent until
-- that feed is revived (filed separately, A1 data-freshness). window default 365d.
--
-- Read paths only touch derived aggregates; builder is service_role-guarded.
-- ROLLBACK: DROP FUNCTION get_zone_baseline(text,bigint,bigint,bigint,text,int,text);
--           DROP FUNCTION rebuild_zone_price_baseline(int);
--           DROP TABLE public.zone_price_baseline; (cron auto-drops with the fn)

-- ── 1. Baseline table ────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.zone_price_baseline (
  id                    bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  scope                 text NOT NULL,             -- 'sports' | 'tour'
  grain                 text NOT NULL,             -- perf_opp_dow | perf_opp | perf_dow | perf | venue_cat_dow | venue_cat
  venue_id              bigint NOT NULL,
  performer_id          bigint,                    -- home performer (sports); NULL for tour grains
  opponent_performer_id bigint,                    -- sports opponent grains only
  perf_category         text,                      -- tour grains only
  event_dow             int,                       -- 0=Sun..6=Sat; NULL when the grain drops DOW
  zone                  text NOT NULL,
  zone_source           text,
  comp_events           int  NOT NULL,
  zone_med              numeric,
  zone_getin            numeric,
  zone_p25              numeric,
  zone_p75              numeric,
  window_days           int  NOT NULL DEFAULT 365,
  computed_at           timestamptz NOT NULL DEFAULT now(),
  feature_version       text DEFAULT 'zpb_v1'
);
ALTER TABLE public.zone_price_baseline ENABLE ROW LEVEL SECURITY;

-- one row per combo (coalesce sentinels keep NULLs unique-comparable)
CREATE UNIQUE INDEX IF NOT EXISTS zone_price_baseline_combo_uidx
  ON public.zone_price_baseline
     (scope, grain, venue_id,
      coalesce(performer_id, 0), coalesce(opponent_performer_id, 0),
      coalesce(perf_category, ''), coalesce(event_dow, -1), zone);
-- resolver lookup path
CREATE INDEX IF NOT EXISTS zone_price_baseline_lookup_idx
  ON public.zone_price_baseline (scope, venue_id, coalesce(performer_id,0), zone);

GRANT SELECT ON public.zone_price_baseline TO authenticated, service_role;
COMMENT ON TABLE public.zone_price_baseline IS
  'Cross-event comparable zone-price anchor (Axis 4). Rolled up from zone_price_observations by venue×performer×opponent×dow×zone (sports) / venue×category×dow×zone (tours), with a materialized fallback ladder. Rebuilt weekly + create-on-demand via get_zone_baseline. A1/D0 mig 20260811201500.';

-- ── 2. Builder ───────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.rebuild_zone_price_baseline(p_window_days int DEFAULT 365)
RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public','pg_temp'
AS $fn$
DECLARE v_n integer;
BEGIN
  IF current_user NOT IN ('service_role','postgres','supabase_admin') THEN
    RAISE EXCEPTION 'forbidden: %', current_user USING ERRCODE='42501';
  END IF;

  -- collapse to one representative price per (event × zone) so capture-heavy events
  -- don't outweigh others, then aggregate to each grain.
  CREATE TEMP TABLE _obs ON COMMIT DROP AS
    SELECT event_id, zone, min(zone_source) AS zone_source,
           performer_id, venue_id, opponent_performer_id, perf_category, perf_event_type, event_dow,
           percentile_cont(0.5) WITHIN GROUP (ORDER BY retail_median)::numeric AS ev_zone_med,
           percentile_cont(0.5) WITHIN GROUP (ORDER BY getin_price)::numeric   AS ev_zone_getin
    FROM public.zone_price_observations
    WHERE capture_date >= (now() AT TIME ZONE 'utc')::date - p_window_days
      AND zone IS NOT NULL AND retail_median > 0 AND venue_id IS NOT NULL
    GROUP BY event_id, zone, performer_id, venue_id, opponent_performer_id, perf_category, perf_event_type, event_dow;

  TRUNCATE public.zone_price_baseline;

  INSERT INTO public.zone_price_baseline
    (scope, grain, venue_id, performer_id, opponent_performer_id, perf_category, event_dow, zone, zone_source,
     comp_events, zone_med, zone_getin, zone_p25, zone_p75, window_days)
  WITH agg AS (
    -- SPORTS grains
    SELECT 'sports' scope, 'perf_opp_dow' grain, venue_id, performer_id, opponent_performer_id, NULL::text perf_category, event_dow, zone
    FROM _obs WHERE perf_event_type='game' AND performer_id IS NOT NULL AND opponent_performer_id IS NOT NULL
    GROUP BY venue_id, performer_id, opponent_performer_id, event_dow, zone
    UNION ALL
    SELECT 'sports','perf_opp', venue_id, performer_id, opponent_performer_id, NULL, NULL, zone
    FROM _obs WHERE perf_event_type='game' AND performer_id IS NOT NULL AND opponent_performer_id IS NOT NULL
    GROUP BY venue_id, performer_id, opponent_performer_id, zone
    UNION ALL
    SELECT 'sports','perf_dow', venue_id, performer_id, NULL, NULL, event_dow, zone
    FROM _obs WHERE perf_event_type='game' AND performer_id IS NOT NULL
    GROUP BY venue_id, performer_id, event_dow, zone
    UNION ALL
    SELECT 'sports','perf', venue_id, performer_id, NULL, NULL, NULL, zone
    FROM _obs WHERE perf_event_type='game' AND performer_id IS NOT NULL
    GROUP BY venue_id, performer_id, zone
    UNION ALL
    -- TOUR grains
    SELECT 'tour','venue_cat_dow', venue_id, NULL, NULL, perf_category, event_dow, zone
    FROM _obs WHERE perf_event_type IS DISTINCT FROM 'game' AND perf_category IS NOT NULL
    GROUP BY venue_id, perf_category, event_dow, zone
    UNION ALL
    SELECT 'tour','venue_cat', venue_id, NULL, NULL, perf_category, NULL, zone
    FROM _obs WHERE perf_event_type IS DISTINCT FROM 'game' AND perf_category IS NOT NULL
    GROUP BY venue_id, perf_category, zone
  )
  SELECT a.scope, a.grain, a.venue_id, a.performer_id, a.opponent_performer_id, a.perf_category, a.event_dow, a.zone,
         (SELECT min(o.zone_source) FROM _obs o WHERE o.venue_id=a.venue_id AND o.zone=a.zone),
         count(DISTINCT o.event_id),
         percentile_cont(0.5)  WITHIN GROUP (ORDER BY o.ev_zone_med)::numeric,
         percentile_cont(0.5)  WITHIN GROUP (ORDER BY o.ev_zone_getin)::numeric,
         percentile_cont(0.25) WITHIN GROUP (ORDER BY o.ev_zone_med)::numeric,
         percentile_cont(0.75) WITHIN GROUP (ORDER BY o.ev_zone_med)::numeric,
         p_window_days
  FROM agg a
  JOIN _obs o
    ON o.venue_id=a.venue_id AND o.zone=a.zone
   AND (a.performer_id IS NULL OR o.performer_id=a.performer_id)
   AND (a.opponent_performer_id IS NULL OR o.opponent_performer_id=a.opponent_performer_id)
   AND (a.perf_category IS NULL OR o.perf_category=a.perf_category)
   AND (a.event_dow IS NULL OR o.event_dow=a.event_dow)
   AND (a.scope='tour') = (o.perf_event_type IS DISTINCT FROM 'game')
  GROUP BY a.scope, a.grain, a.venue_id, a.performer_id, a.opponent_performer_id, a.perf_category, a.event_dow, a.zone
  HAVING count(DISTINCT o.event_id) >= 2;

  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n;
END;
$fn$;
REVOKE ALL ON FUNCTION public.rebuild_zone_price_baseline(int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.rebuild_zone_price_baseline(int) TO service_role;
COMMENT ON FUNCTION public.rebuild_zone_price_baseline(int) IS
  'Full rebuild of zone_price_baseline from zone_price_observations (window default 365d). service_role only. Mig 20260811201500.';

-- ── 3. Resolver (walk ladder finest→coarsest; create-on-demand if empty) ─────
CREATE OR REPLACE FUNCTION public.get_zone_baseline(
  p_scope        text,
  p_venue_id     bigint,
  p_performer_id bigint,
  p_opponent_id  bigint,
  p_category     text,
  p_dow          int,
  p_zone         text
)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_email text := coalesce(auth.jwt()->>'email','');
  v_row   public.zone_price_baseline%ROWTYPE;
  v_min   int := 3;   -- trust floor; below this keep walking coarser
BEGIN
  IF v_email NOT LIKE '%@s4kent.com' THEN
    RAISE EXCEPTION 'forbidden: %', v_email USING ERRCODE='42501';
  END IF;

  -- finest → coarsest, first grain clearing the sample floor wins
  IF p_scope = 'sports' THEN
    SELECT * INTO v_row FROM public.zone_price_baseline
     WHERE scope='sports' AND grain='perf_opp_dow' AND venue_id=p_venue_id
       AND performer_id=p_performer_id AND opponent_performer_id IS NOT DISTINCT FROM p_opponent_id
       AND event_dow=p_dow AND zone=p_zone AND comp_events>=v_min LIMIT 1;
    IF NOT FOUND THEN
      SELECT * INTO v_row FROM public.zone_price_baseline
       WHERE scope='sports' AND grain='perf_opp' AND venue_id=p_venue_id
         AND performer_id=p_performer_id AND opponent_performer_id IS NOT DISTINCT FROM p_opponent_id
         AND zone=p_zone AND comp_events>=v_min LIMIT 1;
    END IF;
    IF NOT FOUND THEN
      SELECT * INTO v_row FROM public.zone_price_baseline
       WHERE scope='sports' AND grain='perf_dow' AND venue_id=p_venue_id
         AND performer_id=p_performer_id AND event_dow=p_dow AND zone=p_zone AND comp_events>=v_min LIMIT 1;
    END IF;
    IF NOT FOUND THEN
      SELECT * INTO v_row FROM public.zone_price_baseline
       WHERE scope='sports' AND grain='perf' AND venue_id=p_venue_id
         AND performer_id=p_performer_id AND zone=p_zone LIMIT 1;
    END IF;
  ELSE
    SELECT * INTO v_row FROM public.zone_price_baseline
     WHERE scope='tour' AND grain='venue_cat_dow' AND venue_id=p_venue_id
       AND perf_category=p_category AND event_dow=p_dow AND zone=p_zone AND comp_events>=v_min LIMIT 1;
    IF NOT FOUND THEN
      SELECT * INTO v_row FROM public.zone_price_baseline
       WHERE scope='tour' AND grain='venue_cat' AND venue_id=p_venue_id
         AND perf_category=p_category AND zone=p_zone LIMIT 1;
    END IF;
  END IF;

  IF FOUND THEN
    RETURN jsonb_build_object(
      'matched', true, 'scope', v_row.scope, 'grain', v_row.grain, 'zone', v_row.zone,
      'comp_events', v_row.comp_events, 'zone_med', v_row.zone_med, 'zone_getin', v_row.zone_getin,
      'zone_p25', v_row.zone_p25, 'zone_p75', v_row.zone_p75, 'computed_at', v_row.computed_at);
  END IF;

  RETURN jsonb_build_object('matched', false, 'reason', 'no_comparables', 'zone', p_zone);
END;
$fn$;
REVOKE ALL ON FUNCTION public.get_zone_baseline(text,bigint,bigint,bigint,text,int,text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.get_zone_baseline(text,bigint,bigint,bigint,text,int,text) FROM anon;
GRANT EXECUTE ON FUNCTION public.get_zone_baseline(text,bigint,bigint,bigint,text,int,text) TO authenticated, service_role;
COMMENT ON FUNCTION public.get_zone_baseline(text,bigint,bigint,bigint,text,int,text) IS
  'Resolve a zone comparable baseline, walking the fallback ladder finest→coarsest (sports: opp+dow→opp→dow→perf; tour: cat+dow→cat). Email-gated. Mig 20260811201500.';

-- ── 4. Weekly rebuild cron ───────────────────────────────────────────────────
DO $cron$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname='pg_cron') THEN
    PERFORM cron.unschedule('zone_price_baseline_weekly')
      WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname='zone_price_baseline_weekly');
    PERFORM cron.schedule('zone_price_baseline_weekly', '37 8 * * 1',
      $$SELECT public.rebuild_zone_price_baseline(365);$$);
  END IF;
END;
$cron$;

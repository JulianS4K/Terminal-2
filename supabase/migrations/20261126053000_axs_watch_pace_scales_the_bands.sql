-- Migration 20261126053000 · level:data-collection · lane:a1 (AXS watch pacing) · writes:axs_watch_config(+cadence_scale_max,+cadence_scale_floor,cadence_scale),axs_watch_pace_apply()(replaced) · reads:axs_watch_poll,primary_poll_event
--
-- ============================================================================
-- Migration 20261126053000 — the hourly pacer moves the knob that still works
--
-- Lane:     a1 (AXS watch pacing)
-- Touches:  axs_watch_config (+cadence_scale_max, +cadence_scale_floor),
--           axs_watch_pace_apply() (REPLACED). No watchlist change — the operator
--           deferred the next batch of venues ("dont add to our watchlist yet").
-- pre:      20261126011500 (the three bands), 20261126044500 (the 208-event list).
--
-- READ-ONLY UPSTREAM (RULE 2): nothing here calls a market. It changes how often the
-- existing reader is told to read.
--
-- ── THE BUG ───────────────────────────────────────────────────────────────
-- axs_watch_pace_apply() runs hourly at :07 and is the watch's self-regulator: it
-- measures recent reads, works out how many an hour the reader can actually get through,
-- and slows the cadence down when demand outruns it. It sets far_out_every.
--
-- far_out_every stopped governing the cadence at 20261126011500, when the interval moved
-- to the three proximity bands in axs_watch_cadence read through
-- axs_watch_cadence_every(). Since then the pacer has run every hour, measured correctly,
-- and written its answer to a column nothing reads. The watch has had no working brake
-- for four hours and nobody would have noticed until it fell behind.
--
-- It surfaced immediately when 20261126044500 took the list from 88 events to 208:
--
--   axs_watch_cadence_demand() -> {"fits": false, "demand_per_hour": 195.0,
--                                  "usable_per_hour": 126, "pct_of_throughput": 154.8}
--
-- 155% of throughput. Not a budget problem — that is 43.8% of the daily credit cap — but
-- the reader cannot physically make 195 reads an hour while AXS is answering the way it
-- is tonight: 85 reads in the last 30 minutes, 44 of them ok, median 6.8s and p90 20.07s,
-- because a timed-out read burns its full ~20s deadline. usable_per_hour is computed from
-- those live measurements (axs_watch_pace()), so it fell from 274 to 126 on the flap and
-- will climb back on its own when AXS recovers.
--
-- ── THE FIX ───────────────────────────────────────────────────────────────
-- The pacer now also sets cadence_scale, which axs_watch_cadence_every() multiplies every
-- band by. One knob, measured from the same number the demand report uses, so the two
-- cannot disagree.
--
--   needed = cadence_scale * demand_per_hour / usable_per_hour      (when demand > usable)
--
-- Three properties that matter more than the arithmetic:
--
--   SELF-RESTORING. Because usable_per_hour is measured live, the scale comes back down
--   by itself as AXS recovers. A hand-set cadence_scale would have stayed wherever it was
--   put, reading 208 events needlessly slowly for days. That is the drift this repo keeps
--   getting bitten by, so the fix is a loop, not a constant.
--
--   HYSTERESIS. A change is only written when it moves the scale by more than 10%, so an
--   upstream that wobbles either side of the line does not rewrite the whole list's
--   next_poll_at every hour.
--
--   CLAMPED AT BOTH ENDS. cadence_scale_floor (1.0) stops it reading faster than the
--   operator's bands ever asked for, whatever the measurement says. cadence_scale_max
--   (4.0) stops a bad measurement — one pathological window, a stuck lease — from parking
--   the watch at a six-hour interval. At the clamp it stops and says so in pace_note
--   rather than pretending it fitted. Both clamps, and a final hard clamp in the function,
--   stay inside cadence_scale's own CHECK of [0.25, 8.0]: a scale the column would reject
--   makes the hourly job throw, which is how a brake goes missing unnoticed.
--
-- far_out_every keeps being written, unchanged, so nothing that still reads it breaks and
-- the rollback below is a one-line UPDATE.
--
-- ── ROLLBACK ──────────────────────────────────────────────────────────────
-- UPDATE public.axs_watch_config SET cadence_scale = 1.0, cadence_scale_max = 1.0;
--   (max = floor pins the pacer off; it will log 'at the clamp' and change nothing)
-- ============================================================================

BEGIN;

-- ── 1. the clamps ─────────────────────────────────────────────────────────
ALTER TABLE public.axs_watch_config
  -- Both bounds sit INSIDE cadence_scale's own domain, CHECK (>= 0.25 AND <= 8.0) from
  -- 20261125214500. A cadence_scale_max above 8.0 would have the pacer compute a legal
  -- scale and then fail the column's constraint — the hourly job would throw at :07 every
  -- hour and the watch would silently have no brake again, which is the exact bug this
  -- migration exists to fix. Caught by scenario s17 section F.
  ADD COLUMN IF NOT EXISTS cadence_scale_floor numeric NOT NULL DEFAULT 1.0
    CHECK (cadence_scale_floor >= 0.25 AND cadence_scale_floor <= 8.0),
  ADD COLUMN IF NOT EXISTS cadence_scale_max   numeric NOT NULL DEFAULT 4.0
    CHECK (cadence_scale_max >= 0.25 AND cadence_scale_max <= 8.0);
COMMENT ON COLUMN public.axs_watch_config.cadence_scale_floor IS
  'The fastest axs_watch_pace_apply() may set cadence_scale (mig 20261126053000). 1.0 = never faster than the operator''s bands.';
COMMENT ON COLUMN public.axs_watch_config.cadence_scale_max IS
  'The slowest axs_watch_pace_apply() may set cadence_scale (mig 20261126053000). Stops one bad measurement parking the watch at a multi-hour interval.';

DO $$ BEGIN
  IF (SELECT cadence_scale_floor > cadence_scale_max FROM public.axs_watch_config) THEN
    RAISE EXCEPTION 'cadence_scale_floor above cadence_scale_max';
  END IF;
END $$;

-- ── 2. the pacer sets the knob the cadence actually reads ─────────────────
CREATE OR REPLACE FUNCTION public.axs_watch_pace_apply()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_cfg public.axs_watch_config%ROWTYPE; v_pace jsonb; v_pick interval; v_demand numeric; v_note text; r record;
  v_usable numeric; v_band_demand numeric; v_want numeric; v_scale numeric; v_scaled boolean := false;
  v_clamped text := '';
BEGIN
  SELECT * INTO v_cfg FROM public.axs_watch_config;
  v_pace := public.axs_watch_pace();

  -- far_out_every: the legacy ladder knob. The live cadence is axs_watch_cadence /
  -- axs_watch_cadence_every() since 20261126011500 and does NOT read this; it is kept
  -- current for anything that still does.
  FOR r IN SELECT (key::text) AS label, value::numeric AS per_hour, make_interval(mins => split_part(key, ' ', 1)::integer) AS every
             FROM jsonb_each_text(v_pace->'demand_per_hour')
            ORDER BY every
  LOOP
    CONTINUE WHEN r.every < v_cfg.pace_min_every OR r.every > v_cfg.pace_max_every;
    v_pick := r.every; v_demand := r.per_hour;
    EXIT WHEN r.per_hour <= (v_pace->>'usable_per_hour')::numeric AND r.per_hour * 24 <= (v_pace->>'daily_cap')::numeric;
  END LOOP;

  -- cadence_scale: the knob the bands DO read. Measured from the same usable_per_hour
  -- that axs_watch_cadence_demand() reports, so the brake and the gauge agree.
  v_usable := (v_pace->>'usable_per_hour')::numeric;
  SELECT sum(3600.0 / nullif(extract(epoch FROM public.axs_watch_cadence_every(t.start_utc, t.event_date)), 0))
    INTO v_band_demand
    FROM public.primary_poll_event t
   WHERE t.source = 'axs' AND t.ticket_url IS NOT NULL;

  IF coalesce(v_usable, 0) > 0 AND coalesce(v_band_demand, 0) > 0 THEN
    -- v_band_demand is measured AT the current scale, so the ratio is a correction to it
    v_want := v_cfg.cadence_scale * v_band_demand / v_usable;
    -- the config clamps, then the column's own domain, so this can never write a value
    -- cadence_scale rejects however the config is later changed
    v_scale := round(greatest(least(v_want, v_cfg.cadence_scale_max), v_cfg.cadence_scale_floor), 2);
    v_scale := greatest(least(v_scale, 8.0), 0.25);
    IF v_want > v_cfg.cadence_scale_max THEN
      v_clamped := format('; wanted %s, clamped at cadence_scale_max %s — the list still outruns the reader',
                          round(v_want, 2), v_cfg.cadence_scale_max);
    ELSIF v_want < v_cfg.cadence_scale_floor THEN
      v_clamped := format('; wanted %s, held at cadence_scale_floor %s', round(v_want, 2), v_cfg.cadence_scale_floor);
    END IF;
    -- hysteresis: ignore a move of 10% or less so a wobbling upstream does not rewrite
    -- every event's next_poll_at once an hour
    IF abs(v_scale - v_cfg.cadence_scale) > 0.1 * v_cfg.cadence_scale THEN
      v_scaled := true;
    ELSE
      v_scale := v_cfg.cadence_scale;
    END IF;
  ELSE
    v_scale := v_cfg.cadence_scale;
  END IF;

  IF v_pick IS NULL AND NOT v_scaled THEN
    RETURN v_pace || jsonb_build_object('applied', false, 'cadence_scale', v_scale,
             'note', 'no rung between pace_min_every and pace_max_every, and cadence_scale unchanged');
  END IF;

  v_note := format('%s reads measured: settle %ss, response %ss, %ss a read, %s usable an hour (%s%% of %s); bands demand %s an hour at scale %s%s%s',
                   v_pace->>'reads_measured', v_pace->>'settle_p50_s', v_pace->>'response_p50_s', v_pace->>'s_per_read',
                   v_pace->>'usable_per_hour', v_pace->>'target_pct', v_pace->>'reads_per_hour',
                   round(coalesce(v_band_demand, 0), 1), v_scale,
                   CASE WHEN v_scaled THEN format(' (was %s)', v_cfg.cadence_scale) ELSE '' END,
                   v_clamped);

  UPDATE public.axs_watch_config
     SET far_out_every  = coalesce(v_pick, far_out_every),
         cadence_scale  = v_scale,
         pace_s_per_read = (v_pace->>'s_per_read')::numeric, pace_set_at = now(), pace_note = v_note,
         updated_at = CASE WHEN far_out_every IS DISTINCT FROM coalesce(v_pick, far_out_every)
                             OR cadence_scale IS DISTINCT FROM v_scale THEN now() ELSE updated_at END
   WHERE id;

  RETURN v_pace || jsonb_build_object('applied', true, 'picked', v_pick::text, 'picked_demand_per_hour', v_demand,
                                      'band_demand_per_hour', round(coalesce(v_band_demand, 0), 1),
                                      'cadence_scale', v_scale, 'cadence_scale_changed', v_scaled,
                                      'changed', v_cfg.far_out_every IS DISTINCT FROM v_pick, 'note', v_note);
END $function$;

-- ── 3. bring the scale into line now, rather than waiting for :07 ─────────
SELECT public.axs_watch_pace_apply();

COMMIT;

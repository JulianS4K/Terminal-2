-- ============================================================================
-- Migration 20260609200000 — wire the dormant TD /match mapper as the AQ fallback
--
-- ## Already applied to prod — applied via MCP apply_migration 2026-06-09
--   (operator-authorized: "use the td mapper to map when aq mapper fails" + "audit
--   and merge into main").
--
-- Lane:     xref+macro (A1 domain) — D0 operator-directed via bot_chat override.
-- Touches:  cron_policy (W), cron (W: td_match_fill_enqueue / td_match_drain /
--           td_match_apply_cron). Calls existing fns td_match_enqueue / td_match_drain
--           / td_match_apply (no fn changes). Fills aq_event_map (via td_match_apply).
-- Pre-reqs: td_match_enqueue/td_match_drain/td_match_apply (exist),
--           td_budget_ok + td_reports_budget_ok (internal gates), cron_should_fire.
--
-- WHY: the TD /match mapper resolves an event's cross-source IDs (sg/sh/vivid)
--   from a seed platform URL — the natural fallback when the AQ mapper leaves
--   them NULL. The functions exist but are NOT scheduled: td_match_queue has
--   NEVER fired (last_match_fired = NULL, 0 in 7d). This wires the 3-step loop:
--     enqueue (fill AQ gaps, seeded from an existing xref row, budget-gated)
--       -> drain (process /match responses into td_match_results)
--       -> apply (write confidence>=90 FILLs into aq_event_map).
--   /match is a READ lookup (GET) and is hard-capped by td_reports_budget_ok
--   (600/mo) + td_budget_ok, so spend is self-limiting; the enqueue cadence is
--   kept conservative on top of that.
--
-- SCOPE NOTE: td_match_enqueue('fill') only targets events that already have a
--   seed xref row but are missing OTHER cross-source IDs. Events with NO xref row
--   rely on the discovery crons (td_*_discover) — out of scope here.
--
-- ROLLBACK: cron.unschedule on the 3 jobnames; DELETE the cron_policy row.
-- ============================================================================

-- Adaptive gate policy for the (paid) enqueue step ---------------------------
INSERT INTO public.cron_policy
  (jobname, peak_hours_et, peak_min_interval_min, offpeak_min_interval_min, daily_max_fires, enabled, notes)
VALUES
  ('td_match_fill_enqueue',
   ARRAY[9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,0],
   120, 240, 12, true,
   'TD /match AQ-fallback enqueue: fill aq_event_map cross-source IDs (sg/sh/vivid) the AQ mapper left NULL, seeded from an existing xref row. Paid (report budget 600/mo) so kept conservative; td_reports_budget_ok/td_budget_ok hard-cap spend. Added 2026-06-09 (operator: use the TD mapper to map when the AQ mapper fails).')
ON CONFLICT (jobname) DO UPDATE
  SET peak_hours_et = EXCLUDED.peak_hours_et,
      peak_min_interval_min = EXCLUDED.peak_min_interval_min,
      offpeak_min_interval_min = EXCLUDED.offpeak_min_interval_min,
      daily_max_fires = EXCLUDED.daily_max_fires,
      enabled = true, notes = EXCLUDED.notes, updated_at = now();

-- 1) Enqueue /match for AQ-gap events (gated; small batch) -------------------
SELECT cron.schedule('td_match_fill_enqueue', '17 */2 * * *', $cron$
  DO $body$ BEGIN
    IF NOT public.cron_should_fire('td_match_fill_enqueue') THEN RETURN; END IF;
    PERFORM public.td_match_enqueue('fill', 3);
  END $body$;
$cron$);

-- 2) Drain /match responses into td_match_results (cheap; frequent) ----------
SELECT cron.schedule('td_match_drain', '*/5 * * * *', $cron$
  SELECT public.td_match_drain(25);
$cron$);

-- 3) Apply confidence>=90 FILLs into aq_event_map (DB-only; periodic) --------
SELECT cron.schedule('td_match_apply_cron', '9-59/20 * * * *', $cron$
  SELECT public.td_match_apply(90, true);
$cron$);

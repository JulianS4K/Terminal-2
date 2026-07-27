-- ============================================================================
-- Migration 20260609120000 — Coerce literal 'null' seat-map strings to SQL NULL
--
-- Data-quality fix (D0/D1 lane). The `backfill-event-configurations` edge fn
-- stored TEvo's absent seat-map URLs as the literal 4-char string 'null'
-- (it serialized a JSON null via `typeof x === "string"`, which is true for
-- the string "null"). As of 2026-06-09, ~5,225 of ~9,208 events held
-- seating_chart_large / seating_chart_medium = 'null' and 0 held true NULL.
--
-- No live broken-image bug exists today — every read path already defends:
--   * SQL: get_broker_event_detail / v_event_seating_chart and the search RPCs
--          gate on `<> 'null' AND ILIKE 'http%'`.
--   * Python: app.py _clean_opt_url() coerces null/none/undefined/'' -> None.
--   * JS: static/store/store.js cleanMapUrl() strips the same sentinels.
-- But the stored poison is latent: any new consumer rendering the raw column
-- without that guard emits <img src="null">. This migration removes the
-- poison at the source-of-truth so the guards are belt-and-suspenders.
--
-- The edge-fn write path is fixed in the same change set
-- (supabase/functions/backfill-event-configurations/index.ts: cleanMapUrl now
-- persists only genuine http(s) URLs, everything else -> null) so rows will
-- not re-poison after this runs.
--
-- RULE 1 compliance: data-only UPDATE on prod, authored as a file for A1 to
-- apply. No DDL, no cron/vault/auth/edge changes. Idempotent + bounded by a
-- WHERE so re-running is a no-op once clean.
-- ============================================================================

UPDATE public.events
SET
  seating_chart_large = NULLIF(NULLIF(NULLIF(NULLIF(seating_chart_large, 'null'), 'none'), 'undefined'), ''),
  seating_chart_medium = NULLIF(NULLIF(NULLIF(NULLIF(seating_chart_medium, 'null'), 'none'), 'undefined'), '')
WHERE seating_chart_large IN ('null', 'none', 'undefined', '')
   OR seating_chart_medium IN ('null', 'none', 'undefined', '');

-- Verify (run manually after apply):
--   SELECT
--     count(*) FILTER (WHERE seating_chart_large  = 'null') AS large_null_str,
--     count(*) FILTER (WHERE seating_chart_medium = 'null') AS medium_null_str,
--     count(*) FILTER (WHERE seating_chart_large IS NULL)   AS large_true_null,
--     count(*) FILTER (WHERE seating_chart_large LIKE 'http%') AS large_http
--   FROM public.events;
-- Expect: large_null_str = 0, medium_null_str = 0, http count unchanged.

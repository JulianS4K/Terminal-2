-- Migration 20260616205000 · lane:D0 · APPLIED LIVE 2026-06-16 by operator directive · writes: ticketsdata_event_xref.active (re-scope), cron.job (re-activate TD pull regime) · reads: aq_event_map · pre:20260616201700_td_pause_crons_budget_split, 20260616203500_cron_rebuild_phase1 · auth:operator-requested 2026-06-16 ("resume ticketsdata")
--
-- Resume TicketsData under the agreed scope. Re-scopes the active pull set and
-- re-activates the TD cron regime that was paused in 20260616201700.
--
-- SCOPE (owned signal = xref.owned_tickets, operator-chosen):
--   active = (owned_tickets>0 AND event within 30d) OR World Cup OR US Open
--   platforms: SH, VD, GT, TM   ·   TickPick (TP): dropped (active=false)
--   Result at apply: SH 165, VD 177, TM 114, GT 19 = 475 pairs.
-- BUDGET: still NOT enforced (180k/6k per 20260616201700); revisit later.
-- LEFT OFF intentionally: td_match_apply_cron (broken 71/71 — needs fix before
--   re-enable), all TP jobs, td_tier_enqueue_axs (AXS is a separate pool).
-- FOLLOW-UPS: (a) US Open is ~0 mappable today — needs td discovery to populate;
--   (b) TM "only pull if it gives data" — add prune-on-empty for TM pairs.
-- ─────────────────────────────────────────────────────────────────────────────

-- 1. Re-scope xref active flags.
WITH cls AS (
  SELECT x.event_id, x.platform,
    coalesce(
      (x.owned_tickets > 0 AND m.event_date <= now()+interval '30 days' AND m.event_date > now()-interval '2 hours')
      OR (m.event_name ILIKE '%world cup%' OR m.performer ILIKE '%world cup%' OR m.performer ILIKE '%FIFA%' OR m.event_name ILIKE '%FIFA%')
      OR ((m.event_name ILIKE '%us open%' OR m.performer ILIKE '%us open%') AND m.event_date > now()-interval '2 hours')
    , false) AS in_target
  FROM public.ticketsdata_event_xref x
  LEFT JOIN public.aq_event_map m ON m.aq_short_event_id = x.aq_short_event_id
  WHERE x.platform IN ('SH','VD','GT','TM','TP')
)
UPDATE public.ticketsdata_event_xref x
SET active = CASE WHEN x.platform='TP' THEN false ELSE cls.in_target END,
    enqueues_today = 0,
    updated_at = now()
FROM cls
WHERE x.event_id = cls.event_id AND x.platform = cls.platform
  AND x.active IS DISTINCT FROM (CASE WHEN x.platform='TP' THEN false ELSE cls.in_target END);

-- 2. Re-activate TD crons (NOT TickPick, NOT td_tier_enqueue_axs, NOT broken td_match_apply_cron).
DO $$
DECLARE r record;
BEGIN
  FOR r IN SELECT jobid FROM cron.job WHERE active=false AND jobname IN (
    'td_enqueue_peak_sh','td_enqueue_peak_vd','td_enqueue_peak_gt','td_enqueue_peak_tm',
    'td_tier_enqueue_sh','td_tier_enqueue_vd','td_tier_enqueue_gt','td_tier_enqueue_tm',
    'td_pull_drain','td_normalize_drain','td_pending_sweep',
    'td_match_drain','td_match_fill_enqueue',
    'td_gt_discover','td_gt_discover_drain','td_gt_automap_check',
    'td_tm_discover','td_tm_discover_drain',
    'td_watchlist_refresh','td-reconcile-knicks-finals-daily','sweep-old-td-listings'
  ) LOOP
    PERFORM cron.alter_job(r.jobid, active := true);
  END LOOP;
END $$;

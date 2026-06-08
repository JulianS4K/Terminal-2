-- Migration 20260608200000 · level:2 · operator-directed (2026-06-08)
-- writes: CREATE OR REPLACE public.seatdata_due_events(int);
--         cron.schedule('seatdata_poll_twice_daily', ...) — new URL caps.
-- reads:  event_metrics (owned), seatgeek_seller_listings (owned), events,
--         sg_market_chart (TOP-50 non-owned chart), seatdata_event_xref,
--         seatdata_search_attempts.
--
-- ============================================================
-- SeatData autopoll candidate redesign — two explicit tiers.
--
-- Operator directive 2026-06-08:
--   "pull sales for the next 25 events we own tickets for, then also pull
--    TOP 50 — SG SELLING, WE'RE NOT IN for those events daily when that
--    list updates."
--
-- TIER 1 (owned, 25): the next 25 UPCOMING events we hold inventory in
--   (TEvo owned_tickets_count > 0  OR  rows in our SG seller listings),
--   soonest-first. These pull SeatData sold comps (v0.3/salesdata/get).
--
-- TIER 2 (chart, top 40): the daily "TOP 50 — SG SELLING, WE'RE NOT IN"
--   Billboard chart (public.sg_market_chart, rebuilt 11:05 UTC by
--   rebuild_sg_market_chart). The chart is the canonical non-owned
--   leaderboard; we take its top ranks, mapped to a TEvo event id, and
--   pull the same sold comps so we can see where the market is moving
--   in names we're NOT exposed to.
--
-- WHY top 40 not top 50 (budget): each tier pulls 1 PAID salesdata call
-- per event per day. SeatData BASIC = 100/day but 2,000/MONTH. 25 + 50 =
-- 75/day → ~2,250/mo, over the monthly cap (would stall ~day 26). Trimming
-- the chart tier to 40 → 65/day → ~1,950/mo, inside the monthly cap with
-- full daily coverage. The monthly cap (seatdata_check_budget) remains the
-- hard backstop regardless. To change coverage, edit the `rank <= 40` line.
--
-- Chart rows without a tevo_event_id are skipped: the SeatData pipeline is
-- keyed on tevo_event_id (NOT NULL in seatdata_event_xref/_sales_snapshots).
-- An owned event that also charts is pulled once (owned tier wins; chart
-- excludes the owned-25 set).
--
-- Unchanged: the edge fn `seatdata-poll` does the per-event work (search-map
-- unmapped events, then paid salesdata pull, dedup into
-- seatdata_sales_snapshots). Staleness gates are also unchanged: unmapped
-- retried ≤1×/24h (seatdata_search_attempts guard); mapped refreshed when
-- last_paid_pull_at is NULL or older than 10h.
--
-- Cron caps bumped so two daily runs cover all 65: max_paid 30→35,
-- daily_cap 75→70, search limit 8→20 (40 chart events are unmapped on
-- first run and must be searched before they can be pulled).
--
-- PENDING OPERATOR APPLY: gated per CLAUDE.md §1.
-- ROLLBACK: restore the prior seatdata_due_events body (owned-only, no chart
--   tier, no 25-cap) and re-schedule the cron with the prior URL
--   (limit=8&max_paid=30&daily_cap=75&min_score=55).
-- ============================================================

CREATE OR REPLACE FUNCTION public.seatdata_due_events(p_limit integer DEFAULT 200)
 RETURNS TABLE(tevo_event_id bigint, name text, venue_name text, event_date text,
               venue_city text, venue_state text, sd_event_id bigint)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  WITH owned_ids AS (
    -- events we hold inventory in: latest TEvo owned count > 0, OR our SG seller book
    SELECT event_id AS tevo_event_id
    FROM (
      SELECT DISTINCT ON (event_id) event_id, owned_tickets_count
      FROM public.event_metrics
      WHERE captured_at > now() - interval '2 days'
      ORDER BY event_id, captured_at DESC
    ) m
    WHERE owned_tickets_count > 0
    UNION
    SELECT DISTINCT tevo_event_id
    FROM public.seatgeek_seller_listings
    WHERE tevo_event_id IS NOT NULL
  ),
  -- TIER 1 — next 25 upcoming events we own tickets for (soonest first)
  owned25 AS (
    SELECT e.id AS tevo_event_id,
           e.name, e.venue_name,
           left(e.occurs_at_local, 10)                              AS event_date,
           btrim(split_part(e.venue_location, ',', 1))              AS venue_city,
           nullif(btrim(split_part(e.venue_location, ',', 2)), '')  AS venue_state,
           e.occurs_at_local::timestamp                             AS occurs_ts,
           0                                                        AS tier
    FROM public.events e
    JOIN owned_ids o ON o.tevo_event_id = e.id
    WHERE e.state = 'shown'
      AND e.occurs_at_local::timestamp >= now()::timestamp
    ORDER BY e.occurs_at_local::timestamp
    LIMIT 25
  ),
  -- TIER 2 — the daily "TOP 50 — SG SELLING, WE'RE NOT IN" chart, trimmed to
  -- top 40 (monthly-budget fit). Mapped to a TEvo event; excludes owned-25.
  chart40 AS (
    SELECT e.id AS tevo_event_id,
           e.name, e.venue_name,
           left(e.occurs_at_local, 10)                              AS event_date,
           btrim(split_part(e.venue_location, ',', 1))              AS venue_city,
           nullif(btrim(split_part(e.venue_location, ',', 2)), '')  AS venue_state,
           e.occurs_at_local::timestamp                             AS occurs_ts,
           1                                                        AS tier
    FROM public.sg_market_chart c
    JOIN public.events e ON e.id = c.tevo_event_id
    WHERE c.chart_date = (SELECT max(chart_date) FROM public.sg_market_chart)
      AND c.rank <= 40
      AND c.tevo_event_id IS NOT NULL
      AND e.state = 'shown'
      AND e.occurs_at_local::timestamp >= now()::timestamp
      AND e.id NOT IN (SELECT tevo_event_id FROM owned25)
  ),
  candidates AS (
    SELECT * FROM owned25
    UNION ALL
    SELECT * FROM chart40
  )
  SELECT c.tevo_event_id, c.name, c.venue_name, c.event_date,
         c.venue_city, c.venue_state, x.sd_event_id
  FROM candidates c
  LEFT JOIN public.seatdata_event_xref x ON x.tevo_event_id = c.tevo_event_id
  WHERE (
    -- not yet mapped: try a search, but at most once / 24h
    (x.tevo_event_id IS NULL
      AND NOT EXISTS (SELECT 1 FROM public.seatdata_search_attempts a
                       WHERE a.tevo_event_id = c.tevo_event_id
                         AND a.attempted_at > now() - interval '24 hours'))
    OR
    -- mapped: refresh sold comps once last pull is > 10h old
    (x.tevo_event_id IS NOT NULL
      AND (x.last_paid_pull_at IS NULL OR x.last_paid_pull_at < now() - interval '10 hours'))
  )
  ORDER BY c.tier, c.occurs_ts          -- owned tier first, then chart by event date
  LIMIT greatest(1, least(p_limit, 500));
$function$;

COMMENT ON FUNCTION public.seatdata_due_events(integer) IS
  'SeatData autopoll candidates, two tiers: (1) next 25 upcoming owned events '
  '(event_metrics owned OR our SG seller book), (2) top 40 of the daily '
  'sg_market_chart ("TOP 50 — SG SELLING, WE''RE NOT IN"), TEvo-mapped, '
  'owned-25 excluded. 25+40=65 paid salesdata pulls/day, inside the SeatData '
  '2,000/mo cap. Staleness: unmapped ≤1 search/24h; mapped refresh > 10h.';

-- ---------- cron: same twice-daily 11:00/20:00 ET, bumped URL caps ----------
-- max_paid 30→35, daily_cap 75→70, search limit 8→20 (40 chart events need a
-- search-map on first run before they can be pulled). Gating (ET-hour + the
-- cron_policy.enabled flag) is identical to the prior body.
SELECT cron.schedule('seatdata_poll_twice_daily', '0 0,1,15,16 * * *', $cron$
  DO $cronbody$
    BEGIN
      IF extract(hour FROM (now() AT TIME ZONE 'America/New_York'))::int NOT IN (11, 20) THEN RETURN; END IF;
      IF NOT coalesce((SELECT enabled FROM public.cron_policy WHERE jobname = 'seatdata_poll_twice_daily'), false) THEN RETURN; END IF;
      PERFORM public._cron_invoke_edge_fn(
        'https://hzrizjeaxlqcxfrtczpq.supabase.co/functions/v1/seatdata-poll?limit=20&max_paid=35&daily_cap=70&min_score=55',
        '{}'::jsonb
      );
    END $cronbody$;
$cron$);

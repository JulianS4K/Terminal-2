-- Migration 20261006213000 · level:data-collection · lane:A1 (operator-routed to D0, "for events we have tickets, resume polling with go and evo and crons and retention cadences") · writes:v_listings_poll_scope_events,listings_poll_scope_policy,retention_policy,cron.job · reads:latest_event_metrics,event_listing_snapshot_daily,s4kcs_orders,n2s_items,seatgeek_orders,gotickets_purchases,seatgeek_sales_snapshots · pre:20260917030000,20260917040000,20260927043400
--
-- ============================================================================
-- Migration 20261006213000 — resume TEvo + GoTickets listing polls, scoped to
--                            events we hold tickets on (+ the existing scope)
--
-- Lane:     A1 data plane (listing pollers), operator-routed 2026-10-06.
-- Touches:  v_listings_poll_scope_events (W, replaced: + owned_inventory branch),
--           listings_poll_scope_policy 'default' (W: + 'owned_inventory'),
--           retention_policy gotickets_listings_snapshots (W: budget 90 → 180 s),
--           cron.job active (W: 321 evo_listings_poll_2min, 628
--           gt_listings_poll_2min, 629 gt_ingest_drain_1min → on).
-- Pre-reqs: 20260917030000 (poll scope policy + view; both pollers already
--           filter on it), 20260917040000 (public SG sales source),
--           20260927043400 (the pause this partially reverses)
--
-- OPERATOR DECISIONS 2026-10-06 (AskUserQuestion):
--   scope   "Owned + current scope" — events with our tickets PLUS the existing
--           order/sales scope (CRM, N2S, SG orders, GT purchases, public SG
--           sales). Keeping the order sources means newly bought inventory on
--           an event we sell is still picked up.
--   crons   "Resume 321+628+629, keep 15d" — TEvo poller (2 min, also fires
--           the GT leg per event into gt_listings_inflight) + dedicated GT
--           poller (2 min) + GT drain (1 min). Stay OFF: 627/630 deal
--           scanners, 639 SG on-demand, 330–334 discover sweeps (unscoped).
--   This partially reverses 20260927043400 ("N2S has sole priority on the
--   marketplace listing APIs") — operator's call; N2S crons are untouched.
--
-- OWNED SOURCE ('owned_inventory'):
--   latest_event_metrics.owned_tickets_count > 0 (our TEvo listings seen by the
--   poller) ∪ event_listing_snapshot_daily in the last 14 days with
--   evo_owned_tickets or sg_owned_tickets > 0. Both froze at the 09-27 pause,
--   so the set starts from what we held then; once the polls run, owned counts
--   refresh for every in-scope event and an event drops out when we no longer
--   hold tickets (and it has no order/sales source).
--   Sized 2026-10-06 (upcoming only): owned 3,476 · existing scope 2,508 ·
--   union 4,231 (was 2,504). listings_poll_tick(120) per 2 min → full pass
--   ≈ 70 min.
--
-- RETENTION (cron 635 retention_tick_hourly, unchanged schedule): keep_days
--   stays 15 for listings_snapshots and gotickets_listings_snapshots, keep_where
--   (deal_listing_spell evidence) unchanged. The GT sweep ends every run on its
--   90 s budget (last_deleted = one 50k batch; listings_snapshots clears 1.85M
--   in the same budget), so its budget goes to 180 s to keep pace once the GT
--   firehose is back. VACUUM 623 + weekly reindex 655–658 unchanged.
--
-- NOTE: cron.alter_job makes pg_cron reload its job table; on 2026-10-06 that
--   paused the scheduler ~2.5 min before it caught up on its own.
--
-- PARTIALLY applied to prod · via MCP 2026-10-06 19:35 UTC: the VIEW only.
--   The two UPDATEs + cron.alter_job hung on the MCP destructive-statement
--   confirmation (never reached Postgres); the operator runs them from the SQL
--   editor. Until the policy UPDATE lands, the owned branch is inert (gated
--   on 'owned_inventory' = ANY(sources)), so applying the view alone changes
--   nothing. Re-running this whole file is idempotent.
--
-- rollback: SELECT cron.alter_job(<321|628|629>, active := false); set
--   listings_poll_scope_policy.sources back to the five 09-17 sources; re-apply
--   the view from 20260917040000; budget_seconds back to 90.
-- ============================================================================

CREATE OR REPLACE VIEW public.v_listings_poll_scope_events AS
 WITH RECURSIVE pol AS (
         SELECT listings_poll_scope_policy.sources
           FROM listings_poll_scope_policy
          WHERE listings_poll_scope_policy.key = 'default'::text
        ), sg_pub AS (
         SELECT min(s.tevo_event_id) AS id
           FROM seatgeek_sales_snapshots s
          WHERE s.tevo_event_id IS NOT NULL
        UNION ALL
         SELECT ( SELECT min(s.tevo_event_id) AS min
                   FROM seatgeek_sales_snapshots s
                  WHERE s.tevo_event_id > sg_pub.id) AS min
           FROM sg_pub
          WHERE sg_pub.id IS NOT NULL
        )
 SELECT o.tevo_event_id
   FROM s4kcs_orders o,
    pol
  WHERE o.tevo_event_id IS NOT NULL AND ('s4kcs_orders'::text = ANY (pol.sources))
UNION
 SELECT n.tevo_event_id
   FROM n2s_items n,
    pol
  WHERE n.tevo_event_id IS NOT NULL AND ('n2s_items'::text = ANY (pol.sources))
UNION
 SELECT s.tevo_event_id
   FROM seatgeek_orders s,
    pol
  WHERE s.tevo_event_id IS NOT NULL AND ('seatgeek_orders'::text = ANY (pol.sources))
UNION
 SELECT p.tevo_event_id
   FROM gotickets_purchases p,
    pol
  WHERE p.tevo_event_id IS NOT NULL AND ('gotickets_purchases'::text = ANY (pol.sources))
UNION
 SELECT sg_pub.id AS tevo_event_id
   FROM sg_pub,
    pol
  WHERE sg_pub.id IS NOT NULL AND ('seatgeek_sales_snapshots'::text = ANY (pol.sources))
UNION
 SELECT m.event_id AS tevo_event_id
   FROM latest_event_metrics m,
    pol
  WHERE m.owned_tickets_count > 0 AND ('owned_inventory'::text = ANY (pol.sources))
UNION
 SELECT d.event_id AS tevo_event_id
   FROM event_listing_snapshot_daily d,
    pol
  WHERE d.snapshot_date >= (CURRENT_DATE - 14)
    AND (COALESCE(d.evo_owned_tickets, 0) > 0 OR COALESCE(d.sg_owned_tickets, 0) > 0)
    AND ('owned_inventory'::text = ANY (pol.sources));

UPDATE public.listings_poll_scope_policy
   SET sources = array_append(sources, 'owned_inventory'),
       note = note || ' + 2026-10-06 operator "for events we have tickets, resume polling" → owned_inventory source (latest_event_metrics.owned_tickets_count > 0 ∪ event_listing_snapshot_daily evo/sg owned > 0, last 14 d); polls 321/628/629 resumed (mig 20261006213000).',
       updated_at = now()
 WHERE key = 'default'
   AND NOT ('owned_inventory' = ANY (sources));

UPDATE public.retention_policy
   SET budget_seconds = 180,
       notes = notes || ' 2026-10-06: budget 90 → 180 s — the sweep ended every run on its budget after one 50k batch; GT polling resumed (mig 20261006213000).'
 WHERE table_name = 'gotickets_listings_snapshots'
   AND budget_seconds < 180;

SELECT cron.alter_job(jobid, active := true)
  FROM cron.job
 WHERE jobname IN ('evo_listings_poll_2min', 'gt_listings_poll_2min', 'gt_ingest_drain_1min')
   AND NOT active;

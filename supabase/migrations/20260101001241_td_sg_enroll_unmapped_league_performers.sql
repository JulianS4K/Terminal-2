-- Migration 20260703141000 · lane:A1 (data plane — SeatGeek event-mapping allowlist)
--   writes on run: td_sg_performers (INSERT performers of unmapped league events, ON CONFLICT reactivate)
--   reads: event_xref, events, aq_event_map
--   spends: nothing at apply. The daily td_sg_discover cron then spends ~1 TD credit
--           per enrolled performer to /events-search SeatGeek (GET-only, budget-gated).
--   pre: 20260606170000 (td_sg_performers / td_sg_discover), 20260703140000 (target expansion)
--   auth: operator directive 2026-07-03 (julian@s4kent.com — "map them all, start with
--         soonest events and go up")
--
-- ## Applied to prod 2026-07-03 via MCP (idempotent + reversible). Codification.
--
-- WHY ────────────────────────────────────────────────────────────────────────
-- After the target expansion (mig 20260703140000), 383 upcoming league-scope events
-- (mostly NFL — season opens August — plus a few west-coast MLB, WNBA, WTA, US Open)
-- have NO SeatGeek anchor (sg_event_id NULL) and so can't be StubHub/Vivid-mapped:
-- the sg_match_map_tick /match filler anchors on aq_event_map.sg_event_id.
--
-- td_sg_discover only searches performers on the td_sg_performers allowlist. This
-- enrolls the 48 distinct performers behind those unmapped events (SeatGeek slug
-- built the same way as mig 20260609130000). Discovery then gives their events an
-- sg_event_id → auto_match_sg_canonical_v3 links to TEvo → backfill_aq_maps anchors
-- the hub → sg_match_map_tick fills sh/vivid. That matcher already orders non-owned
-- candidates by event_date ASC, so mapping proceeds SOONEST-FIRST automatically.
--
-- THROUGHPUT NOTE: sh/vivid fill is gated by TD /match — serialized (one per 10-min
-- tick, 429 guard) and report-capped (td_match_cron_budget_ok: <300 reports/month,
-- 50% of the 600 automated cap). So the ~383 backlog fills over weeks at the default
-- cap, soonest-first; raise the cap to go faster (operator decision). Discovery
-- itself (/events, this migration's driver) is only credit-gated, not report-capped.
-- ─────────────────────────────────────────────────────────────────────────────

INSERT INTO public.td_sg_performers (tevo_performer_id, performer_name, performer_url, active)
SELECT DISTINCT ON (e.primary_performer_id)
  e.primary_performer_id, e.primary_performer_name,
  'https://seatgeek.com/' || trim(both '-' from regexp_replace(lower(e.primary_performer_name),'[^a-z0-9]+','-','g')) || '-tickets',
  true
FROM public.event_xref ex
JOIN public.events e ON e.id = ex.tevo_event_id
JOIN public.aq_event_map aem ON aem.tevo_event_id = ex.tevo_event_id
WHERE ex.espn_league IN ('MLB','NFL','WNBA','NHL','f1','MLS','wta')
  AND aem.event_date > now()
  AND aem.event_name NOT ILIKE '%parking%'
  AND aem.sh_event_id IS NULL AND aem.vivid_event_id IS NULL AND aem.sg_event_id IS NULL
  AND e.primary_performer_id IS NOT NULL
ON CONFLICT (tevo_performer_id) DO UPDATE SET active=true, updated_at=now();

-- ROLLBACK: DELETE FROM public.td_sg_performers WHERE performer_url LIKE 'https://seatgeek.com/%-tickets'
--   AND created_at::date = '2026-07-03' AND <the enrolled set>;  (or set active=false)

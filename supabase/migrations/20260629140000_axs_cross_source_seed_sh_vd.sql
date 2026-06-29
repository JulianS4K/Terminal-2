-- Migration 20260629140000 · lane:A1 (DB + ingest/cron — AXS↔TicketsData cross-source) · writes:ticketsdata_event_xref (UPSERT SH+VD rows for AXS-tracked events) · reads:axs_events, axs_probe, aq_event_map · pre:20260629120000 (manual_opt_in exemption) · auth:operator-approved 2026-06-29 (julian@s4kent.com — "for axs map to other sources and pull for all of those excluding sg")
--
-- WHY ------------------------------------------------------------------------
-- Operator wants the events we track via the AXS native pipeline ALSO pulled from
-- our other ticketing sources, EXCLUDING SeatGeek. The unified multi-source
-- listings pull is TicketsData (platforms SH/VD/GT/TM/TP via ticketsdata_event_xref
-- + the td enqueue crons). SeatGeek is NOT a TicketsData platform (it has its own
-- sg_* broker pipeline), so it is excluded by construction here.
--
-- This migration covers the events that can be enrolled WITHOUT any SeatGeek
-- involvement and WITHOUT an API call: the AXS candidates (active + probe verdict
-- axs_ok + future-dated + canonically mapped) that ALREADY carry a StubHub and/or
-- VividSeats id in aq_event_map (the cross-source hub). For SH/VD the per-platform
-- event_url is directly constructible from the numeric id, so we seed the xref
-- rows straight away. Count at authoring: 155 future mapped candidates, of which 48
-- have an SH/VD id (43 SH, 48 VD); 37 SH + 38 VD xref rows already existed but were
-- active-only (NOT manual_opt_in), so they relied on td_target_events() venue
-- membership and would be dropped if their venue left the allowlist.
--
-- WHAT -----------------------------------------------------------------------
-- UPSERT one ticketsdata_event_xref row per (SH id, VD id) with manual_opt_in=true
-- so today's td_apply_targets() exemption (mig 20260629120000) keeps them tracked
-- regardless of td_target_events() membership. New rows get the standard
-- constructible URL; existing rows are flipped active=true + manual_opt_in=true
-- (their event_url is preserved, never clobbered).
--
-- GT/TM/TP and the 107 candidates with NO sibling id are NOT handled here: GT/TM/TP
-- event_urls are not constructible from a numeric id (need TD discovery/hex), and
-- the 107 id-less events require a cross-source match — the only working matcher
-- (TD /match) is SeatGeek-URL-anchored, which is the open "excluding sg" decision.
--
-- SAFETY ---------------------------------------------------------------------
-- Zero API/credit cost (no pulls fired here; enqueue happens on the next td tier
-- cron tick). SG never touched. Budget headroom ample (~5.8k/6k daily, ~170k/180k
-- monthly; AXS×SH/VD adds <100 pulls/day). manual_opt_in=true makes the set sticky;
-- post-event cleanup still happens via td_pending_sweep (SH/VD, 2h post-event) and
-- the dte>=0 enqueue gate, and dead URLs self-deactivate on 403/404 in
-- td_normalize_drain. ON CONFLICT DO UPDATE never overwrites an existing event_url.
--
-- ROLLBACK -------------------------------------------------------------------
--   UPDATE public.ticketsdata_event_xref x SET active=false, manual_opt_in=false, updated_at=now()
--   WHERE x.platform IN ('SH','VD') AND x.match_method='axs_cross_source';
--   (or DELETE the rows whose meta->>'seed'='axs_cross_source' that had no prior existence)

WITH cand AS (
  SELECT DISTINCT aem.aq_short_event_id, aem.sh_event_id, aem.vivid_event_id
  FROM public.axs_events ax
  JOIN public.axs_probe p   ON p.axs_event_id = ax.axs_event_id AND p.status = 'axs_ok'
  JOIN public.aq_event_map aem ON aem.aq_short_event_id = ax.aq_short_event_id
  WHERE ax.active = true AND aem.event_date > now()
)
INSERT INTO public.ticketsdata_event_xref
  (event_id, platform, aq_short_event_id, event_url, active, manual_opt_in, match_method, meta, updated_at)
SELECT c.sh_event_id, 'SH', c.aq_short_event_id,
       'https://www.stubhub.com/x/event/' || c.sh_event_id::text || '/',
       true, true, 'axs_cross_source',
       jsonb_build_object('seed','axs_cross_source','seeded_at', now()), now()
FROM cand c WHERE c.sh_event_id IS NOT NULL
UNION ALL
SELECT c.vivid_event_id, 'VD', c.aq_short_event_id,
       'https://www.vividseats.com/production/' || c.vivid_event_id::text,
       true, true, 'axs_cross_source',
       jsonb_build_object('seed','axs_cross_source','seeded_at', now()), now()
FROM cand c WHERE c.vivid_event_id IS NOT NULL
ON CONFLICT (event_id, platform) DO UPDATE
  SET active = true, manual_opt_in = true, updated_at = now();

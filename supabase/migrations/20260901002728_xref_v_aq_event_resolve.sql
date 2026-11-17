-- Migration 20260901002728 · reconstructed from prod · writes: see body
--
-- Recorded 2026-11-17 (branch triage): applied on prod as "xref_v_aq_event_resolve" (version 20260901002728) but present in no
-- file in git. Body is prod's own supabase_migrations.schema_migrations.statements for that row,
-- statements separated by ';'. Recording only — it is already applied; do not re-apply.


-- ============================================================================
-- Migration — v_aq_event_resolve: one canonical source-id -> hub -> tevo lookup
--
-- Lane:     xref+macro
-- Touches:  (view only) aq_event_map (R), ticketsdata_event_xref (R)
-- Pre-reqs: xref_aq_register_tevo_linked_events
--
-- Operator directive 2026-09-01: all listing sources should refer to the
-- mapping table for their respective source ids -- via a resolver, without
-- altering the source tables.
--
-- WHY A VIEW AND NOT A COLUMN
-- TicketsData is the only source that never drifts (13,843/13,843) because it
-- carries aq_short_event_id, the hub key PROJECT_BIBLE §0 prescribes. Giving
-- every other source that column is the textbook fix, but it means ALTER plus
-- backfill on gotickets_listings_snapshots (381M rows), listings_snapshots
-- (167M) and the seatgeek_* pair (38M) -- hours of write load and considerable
-- bloat for a lookup the hub can already answer in 17,424 rows. This view gives
-- the same resolution path at zero migration risk; the snapshot tables keep
-- their denormalised tevo_event_id as a fast path, and this becomes the thing
-- that keeps them honest.
--
-- USE
--   SELECT tevo_event_id, aq_short_event_id
--     FROM public.v_aq_event_resolve
--    WHERE source = 'gotickets' AND source_event_id = '12345';
--
-- source_event_id is TEXT throughout, because axs_event_id is text on the hub
-- while the rest are bigint -- a single column has to hold both, and casting
-- the caller's value is cheaper than making every consumer pick a column.
--
-- 'ticketsdata' resolves through ticketsdata_event_xref rather than a hub
-- column: TD is per-platform (its 'GT' means GAMETIME, not GoTickets) and it
-- already joins the hub on aq_short_event_id at 100%, so it needs no column of
-- its own. Its rows carry the platform code in `source` as ticketsdata:<CODE>
-- so a caller can tell Gametime from Ticketmaster from TickPick.
-- ============================================================================

CREATE OR REPLACE VIEW public.v_aq_event_resolve AS
  SELECT 'tevo'::text AS source, a.tevo_event_id::text AS source_event_id,
         a.aq_short_event_id, a.tevo_event_id, a.event_name, a.venue_name, a.event_date
    FROM public.aq_event_map a WHERE a.tevo_event_id IS NOT NULL
UNION ALL
  SELECT 'seatgeek', a.sg_event_id::text,
         a.aq_short_event_id, a.tevo_event_id, a.event_name, a.venue_name, a.event_date
    FROM public.aq_event_map a WHERE a.sg_event_id IS NOT NULL
UNION ALL
  SELECT 'stubhub', a.sh_event_id::text,
         a.aq_short_event_id, a.tevo_event_id, a.event_name, a.venue_name, a.event_date
    FROM public.aq_event_map a WHERE a.sh_event_id IS NOT NULL
UNION ALL
  SELECT 'vivid', a.vivid_event_id::text,
         a.aq_short_event_id, a.tevo_event_id, a.event_name, a.venue_name, a.event_date
    FROM public.aq_event_map a WHERE a.vivid_event_id IS NOT NULL
UNION ALL
  SELECT 'ticketmaster', a.tm_event_id::text,
         a.aq_short_event_id, a.tevo_event_id, a.event_name, a.venue_name, a.event_date
    FROM public.aq_event_map a WHERE a.tm_event_id IS NOT NULL
UNION ALL
  SELECT 'seatdata', a.sd_event_id::text,
         a.aq_short_event_id, a.tevo_event_id, a.event_name, a.venue_name, a.event_date
    FROM public.aq_event_map a WHERE a.sd_event_id IS NOT NULL
UNION ALL
  SELECT 'axs', a.axs_event_id,
         a.aq_short_event_id, a.tevo_event_id, a.event_name, a.venue_name, a.event_date
    FROM public.aq_event_map a WHERE a.axs_event_id IS NOT NULL
UNION ALL
  SELECT 'gotickets', a.gotickets_event_id::text,
         a.aq_short_event_id, a.tevo_event_id, a.event_name, a.venue_name, a.event_date
    FROM public.aq_event_map a WHERE a.gotickets_event_id IS NOT NULL
UNION ALL
  SELECT 'ticketsdata:' || x.platform, x.event_id::text,
         a.aq_short_event_id, a.tevo_event_id, a.event_name, a.venue_name, a.event_date
    FROM public.ticketsdata_event_xref x
    JOIN public.aq_event_map a ON a.aq_short_event_id = x.aq_short_event_id
   WHERE x.event_id IS NOT NULL;

COMMENT ON VIEW public.v_aq_event_resolve IS
  'Canonical source-id -> aq_short_event_id -> tevo_event_id lookup, so every listing source resolves through the AQ hub instead of trusting its own denormalised tevo_event_id. Query as: WHERE source = ''gotickets'' AND source_event_id = ''12345''. source_event_id is text because axs_event_id is text on the hub while the others are bigint. TicketsData rows resolve via ticketsdata_event_xref and carry the platform code (ticketsdata:GT etc) because TD ids are per-platform -- note TD ''GT'' means GAMETIME, not GoTickets.';

GRANT SELECT ON public.v_aq_event_resolve TO service_role;
;

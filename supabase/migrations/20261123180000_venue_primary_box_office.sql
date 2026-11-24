-- Migration 20261123180000 · level:data-collection · lane:A1 (data plane — mapping program) · writes:venue_primary_box_office(new),v_event_xmap(replaced when present: + primary_box_office) · reads:event_xmap,events · pre:20261118003000
--
-- MAPPING PROGRAM — WHICH BOX OFFICE IS PRIMARY AT A VENUE.
--
-- Operator 2026-11-23: "map to other sites too, list these 2 sources as the primary for their respective venues."
-- The two box offices we poll ourselves (PR #1180: `sitickets` = SI Tickets at Sports Illustrated Stadium, Harrison NJ,
-- TEvo venue 7054; `timberwolves` = tickets.timberwolves.com (Jump) at Target Center, Minneapolis, TEvo venue 1534)
-- are the primary sellers at those venues. Ticketmaster agrees by its own data: every Ticketmaster row for a
-- Timberwolves home game is a resale page (channel 'secondary', mig 20261122040000), none a box-office sale.
--
-- What this migration does:
--   `venue_primary_box_office` (TEvo venue -> the primary box office's source code, label, host): a small, operator-
--   seeded table the mapper owns; two rows now. A venue not in it has no known primary (Ticketmaster's channel on
--   its own rows still says whether TM sells a given event first-hand).
--   `v_event_xmap` gains `primary_box_office` (the venue's primary source code) as its last column, so every cluster
--   at those venues says who sells it first-hand beside the TickPick / Vivid / SeatGeek / GoTickets / AXS /
--   Ticketmaster ids it already carries. When `primary_poll_event` becomes a spine source (PR #1180's table; the
--   mapper's follow-up), its id joins the same row.
--
-- Apply: `BEGIN;` / `COMMIT;` stripped; away from :47 (the spine). Harness: tests/sql/event_xmap (section K).

BEGIN;
SET LOCAL lock_timeout = '10s';

CREATE TABLE IF NOT EXISTS public.venue_primary_box_office (
  tevo_venue_id bigint PRIMARY KEY,
  source        text NOT NULL,                        -- the source code the rows carry (primary_poll_event.source)
  label         text NOT NULL,                        -- the box office as people call it
  host          text,                                 -- where the tickets are sold
  venue_name    text,
  note          text,
  set_by        text NOT NULL DEFAULT 'operator',
  set_at        timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE public.venue_primary_box_office IS 'Which box office sells a venue''s events first-hand (operator-seeded; the mapper owns it). Read by v_event_xmap.primary_box_office. Mig 20261123180000.';
INSERT INTO public.venue_primary_box_office (tevo_venue_id, source, label, host, venue_name, note) VALUES
  (7054, 'sitickets',    'SI Tickets',                  'sitickets.com',          'Sports Illustrated Stadium', 'operator 2026-11-23; ex Red Bull Arena, Harrison NJ; polled by PR #1180'),
  (1534, 'timberwolves', 'Minnesota Timberwolves (Jump)', 'tickets.timberwolves.com', 'Target Center',           'operator 2026-11-23; Minneapolis MN; polled by PR #1180; Ticketmaster rows here are all resale pages')
ON CONFLICT (tevo_venue_id) DO NOTHING;
REVOKE ALL ON public.venue_primary_box_office FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.venue_primary_box_office TO service_role;

-- the spine view, where the spine exists (the Discovery harness has no spine): rebuilt with primary_box_office last
DO $spine$
BEGIN
  IF to_regclass('public.event_xmap') IS NULL THEN RETURN; END IF;
  EXECUTE 'DROP VIEW IF EXISTS public.v_event_xmap';
  EXECUTE $v$
    CREATE VIEW public.v_event_xmap AS
    SELECT x.xmap_id AS internal_event_id, x.xmap_id, x.local_day, x.start_local, x.name, x.venue_name, x.venue_city, x.venue_state, x.tevo_venue_id, x.sources, x.seed_source,
           x.tevo_event_id, e.name AS evo_name,
           x.espn_event_id, g2.name AS espn_name, g2.espn_league,
           tm.tm_event_id, tm.name AS ticketmaster_name,
           x.tp_event_id, tp.name AS tickpick_name,
           x.vivid_event_id, vv.name AS vivid_name,
           x.gt_event_id, gt.name AS gotickets_name,
           x.axs_event_id, coalesce(ax.event_title_clean, ax.event_title) AS axs_name,
           x.sg_event_id, sg.sg_event_name AS seatgeek_name,
           x.mlb_schedule_id, CASE WHEN g.schedule_id IS NOT NULL THEN g.away_name || ' at ' || g.home_name END AS mlb_name,
           x.methods, x.updated_at,
           tm.seller AS ticketmaster_seller, tm.channel AS ticketmaster_channel,
           pb.source AS primary_box_office
      FROM public.event_xmap x
      LEFT JOIN public.events e ON e.id = x.tevo_event_id
      LEFT JOIN public.espn_ticket_game g2 ON g2.espn_event_id = x.espn_event_id::text
      LEFT JOIN public.tm_discovery_event tm ON tm.tm_seq = x.tm_event_seq
      LEFT JOIN public.tickpick_catalog_event tp ON tp.tp_event_id = x.tp_event_id
      LEFT JOIN public.vivid_catalog_event vv ON vv.vivid_event_id = x.vivid_event_id
      LEFT JOIN public.gotickets_event gt ON gt.gt_event_id = x.gt_event_id
      LEFT JOIN public.axs_export_event ax ON ax.axs_event_id = x.axs_event_id
      LEFT JOIN public.sg_events_canonical sg ON sg.sg_event_id = x.sg_event_id
      LEFT JOIN public.mlb_ticket_game g ON g.schedule_id = x.mlb_schedule_id
      LEFT JOIN public.venue_primary_box_office pb ON pb.tevo_venue_id = x.tevo_venue_id$v$;
  EXECUTE 'COMMENT ON VIEW public.v_event_xmap IS ''One row per cross-source event: the internal key, every source''''s id and name, the Ticketmaster seller / channel, and the venue''''s primary box office. Migs 20261117130000 … 20261123180000.''';
  EXECUTE 'REVOKE ALL ON public.v_event_xmap FROM anon, authenticated';
  EXECUTE 'GRANT SELECT ON public.v_event_xmap TO service_role';
END
$spine$;

COMMIT;

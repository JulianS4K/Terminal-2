-- Migration 20261102260000 · level:data-collection · lane:A1 (AXS ingest) · writes:event_axs_primary(new),axs_primary_tag_refresh()(new),v_axs_primary_events(new),cron axs_primary_tag_hourly(new) · reads:events,aq_event_map,axs_events,axs_catalog,td_match_results,sg_events_canonical,axs_primary_signal,axs_venue_catalog · pre:20261102250000
--
-- ============================================================================
-- Tag events as AXS-primary and keep the list current (operator 2026-11-02: "use that AXS to tag
-- events as AXS primary, then create a list that self-updates").
--
-- An AXS event id alone does NOT make an event AXS-primary: AXS also lists events it only resells
-- (AXS marketplace, the primary sold elsewhere — operator 2026-11-02). Primary needs proof.
-- event_axs_primary — one row per UPCOMING TEvo event with any AXS evidence (or a contrary seller),
-- first rule that fires wins:
--   'confirmed'  AXS is the primary seller: SeatGeek's primary-ticketer field says AXS; OR our AXS
--                pull shows primary inventory (primary seats, or GA admission price levels); OR the
--                AXS artist feed flags it axs_ticketed; OR TicketsData /match returns an axs.com link
--                in its primary slot; OR >= 30 % of its last-hour GoTickets/EVO listings are
--                AXS-transfer (>= 50 rows)
--   'axs_resale' our AXS pull shows resale seats only — AXS is reselling, not the primary seller
--   'not_axs'    SeatGeek names another primary seller (Ticketmaster, SeatGeek Open, Paciolan, TDC …)
--                — an AXS id we hold for it is then an AXS resale page
--   'probable'   at a venue axs_venue_catalog scores 'axs' (with or without an AXS id) and nothing
--                contradicts it
--   'axs_listed' we hold an AXS id, but the venue is not an AXS venue and nothing proves primary —
--                most likely AXS resale
--   An event at a 'mixed' venue is only tagged on its own evidence. basis says which rule fired.
-- v_axs_primary_events — the list: upcoming confirmed + probable, soonest first, with AXS id / URL
--   and AQ id (axs_listed / axs_resale / not_axs stay in the table, out of the list).
-- axs_primary_tag_refresh() — hourly at :27, just after axs_aq_link_tick (:21) has filled new AXS
--   ids, so a newly found id upgrades its event within the hour; past events leave the table.
-- Reads stored data only. The tag lives in its own table; events is not altered.
-- Rollback: SELECT cron.unschedule('axs_primary_tag_hourly'); DROP VIEW v_axs_primary_events;
--   DROP FUNCTION axs_primary_tag_refresh(); DROP TABLE event_axs_primary;
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.event_axs_primary (
  tevo_event_id     bigint      PRIMARY KEY,
  status            text        NOT NULL CHECK (status IN ('confirmed', 'probable', 'axs_listed', 'axs_resale', 'not_axs')),
  basis             text        NOT NULL,
  axs_event_id      text,
  event_url         text,
  aq_short_event_id text,
  event_name        text,
  venue_id          bigint,
  venue_name        text,
  venue_location    text,
  occurs_at_local   text,
  venue_verdict     text,
  seatgeek_seller   text,
  delivery_share    numeric,
  first_tagged_at   timestamptz NOT NULL DEFAULT now(),
  status_changed_at timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS event_axs_primary_status_idx ON public.event_axs_primary (status, occurs_at_local);
CREATE INDEX IF NOT EXISTS event_axs_primary_aq_idx ON public.event_axs_primary (aq_short_event_id) WHERE aq_short_event_id IS NOT NULL;
COMMENT ON TABLE public.event_axs_primary IS
  'Upcoming events tagged AXS-primary (confirmed / probable) or not (SeatGeek names another seller), with the AXS event id when known. Refreshed hourly by axs_primary_tag_refresh() (mig 20261102260000).';
ALTER TABLE public.event_axs_primary ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.event_axs_primary FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.event_axs_primary TO service_role;

CREATE OR REPLACE FUNCTION public.axs_primary_tag_refresh()
RETURNS jsonb LANGUAGE plpgsql SET search_path = public, pg_temp AS $$
DECLARE
  v_rows   int;
  v_gone   int;
  v_counts jsonb;
BEGIN
  DROP TABLE IF EXISTS _axs_ids, _axs_tag;

  -- every AXS id we hold for a TEvo event, best source first
  CREATE TEMP TABLE _axs_ids ON COMMIT DROP AS
  SELECT DISTINCT ON (tevo_event_id) tevo_event_id, axs_event_id, src
    FROM (
      SELECT m.tevo_event_id, m.axs_event_id, 'aq_event_map' AS src, 1 AS pri
        FROM public.aq_event_map m WHERE m.tevo_event_id IS NOT NULL AND m.axs_event_id IS NOT NULL
      UNION ALL
      SELECT a.tevo_event_id, a.axs_event_id, 'axs_events', 2
        FROM public.axs_events a
       WHERE a.tevo_event_id IS NOT NULL AND coalesce(a.is_axs_primary, true)
         AND coalesce(a.probe_status, 'axs_ok') <> 'not_axs'
      UNION ALL
      SELECT c.tevo_event_id, c.axs_event_id, 'axs_catalog:' || c.source, 3
        FROM public.axs_catalog c WHERE c.tevo_event_id IS NOT NULL AND coalesce(c.axs_ticketed, true)
      UNION ALL
      SELECT r.tevo_event_id,
             substring(coalesce(r.tm_url, '') || ' ' || coalesce(r.matches_raw::text, '') FROM 'axs\.com/events/(\d+)'),
             'td_match', 4
        FROM public.td_match_results r
       WHERE r.tevo_event_id IS NOT NULL
         AND (coalesce(r.tm_url, '') || ' ' || coalesce(r.matches_raw::text, '')) ~ 'axs\.com/events/\d+'
    ) s
   ORDER BY tevo_event_id, pri;

  CREATE TEMP TABLE _axs_tag ON COMMIT DROP AS
  WITH ev AS (
    SELECT e.id, e.name, e.venue_id, e.venue_name, e.venue_location, e.occurs_at_local
      FROM public.events e
     WHERE e.occurs_at_local ~ '^\d{4}-\d\d-\d\d' AND left(e.occurs_at_local, 10) >= current_date::text
       AND coalesce(e.state, 'shown') <> 'ignored'
       AND coalesce(e.name, '') !~* 'parking|shuttle'
       AND public.axs_is_us_location(e.venue_location)
       AND (EXISTS (SELECT 1 FROM public.axs_venue_catalog v WHERE v.tevo_venue_id = e.venue_id AND v.verdict IN ('axs', 'mixed'))
            OR EXISTS (SELECT 1 FROM _axs_ids i WHERE i.tevo_event_id = e.id)
            OR EXISTS (SELECT 1 FROM public.axs_primary_signal p WHERE p.tevo_event_id = e.id AND p.axs_share >= 0.30)
            OR EXISTS (SELECT 1 FROM public.sg_events_canonical g WHERE g.tevo_event_id = e.id
                          AND g.raw_event_jsonb->'integrated'->>'provider_name' = 'AXS'))),
  sg AS (
    SELECT DISTINCT ON (g.tevo_event_id) g.tevo_event_id, g.raw_event_jsonb->'integrated'->>'provider_name' AS seller,
           substring(g.raw_event_jsonb->'integrated'->>'provider_id' FROM '(\d+)$') AS sg_axs_id
      FROM public.sg_events_canonical g
     WHERE g.tevo_event_id IS NOT NULL AND g.raw_event_jsonb->'integrated'->>'provider_name' IS NOT NULL
     ORDER BY g.tevo_event_id, (g.raw_event_jsonb->'integrated'->>'provider_name' = 'AXS') DESC, g.updated_at DESC),
  pull AS (   -- latest AXS pull per event: primary inventory vs resale only
    SELECT DISTINCT ON (s.tevo_event_id) s.tevo_event_id,
           (coalesce(s.seats_primary, 0) > 0 OR s.ga_price_levels IS NOT NULL) AS pull_primary,
           (coalesce(s.seats_primary, 0) = 0 AND s.ga_price_levels IS NULL AND coalesce(s.seats_resale, 0) > 0) AS pull_resale_only
      FROM public.axs_event_snapshots s
     WHERE s.tevo_event_id IS NOT NULL
     ORDER BY s.tevo_event_id, s.id DESC)
  SELECT ev.*, i.axs_event_id AS known_id, i.src, sg.seller, sg.sg_axs_id,
         coalesce(pull.pull_primary, false) AS pull_primary, coalesce(pull.pull_resale_only, false) AS pull_resale_only,
         EXISTS (SELECT 1 FROM public.axs_catalog c WHERE c.tevo_event_id = ev.id AND c.axs_ticketed) AS axs_ticketed,
         EXISTS (SELECT 1 FROM public.td_match_results r WHERE r.tevo_event_id = ev.id
                    AND (coalesce(r.tm_url, '') || ' ' || coalesce(r.matches_raw::text, '')) ~ 'axs\.com/events/\d+') AS td_primary,
         v.verdict AS venue_verdict, v.verdict_basis,
         p.axs_share, p.gt_rows + p.evo_rows AS signal_rows,
         (SELECT min(m.aq_short_event_id) FROM public.aq_event_map m WHERE m.tevo_event_id = ev.id) AS aq_id
    FROM ev
    LEFT JOIN _axs_ids i ON i.tevo_event_id = ev.id
    LEFT JOIN sg ON sg.tevo_event_id = ev.id
    LEFT JOIN public.axs_venue_catalog v ON v.tevo_venue_id = ev.venue_id
    LEFT JOIN public.axs_primary_signal p ON p.tevo_event_id = ev.id
    LEFT JOIN pull ON pull.tevo_event_id = ev.id;

  INSERT INTO public.event_axs_primary AS t
         (tevo_event_id, status, basis, axs_event_id, event_url, aq_short_event_id, event_name, venue_id,
          venue_name, venue_location, occurs_at_local, venue_verdict, seatgeek_seller, delivery_share, updated_at)
  SELECT x.id, x.status, x.basis, x.axs_id,
         CASE WHEN x.axs_id IS NOT NULL THEN 'https://www.axs.com/events/' || x.axs_id END,
         x.aq_id, x.name, x.venue_id, x.venue_name, x.venue_location, x.occurs_at_local,
         x.venue_verdict, x.seller, x.axs_share, now()
    FROM (
      SELECT t.*,
             coalesce(t.known_id, CASE WHEN t.seller = 'AXS' THEN t.sg_axs_id END) AS axs_id,
             CASE
               WHEN t.seller = 'AXS' OR t.pull_primary OR t.axs_ticketed OR t.td_primary THEN 'confirmed'
               WHEN t.axs_share >= 0.30 AND t.signal_rows >= 50 THEN 'confirmed'
               WHEN t.pull_resale_only THEN 'axs_resale'
               WHEN t.seller IS NOT NULL THEN 'not_axs'
               WHEN t.venue_verdict = 'axs' THEN 'probable'
               WHEN t.known_id IS NOT NULL THEN 'axs_listed'
             END AS status,
             CASE
               WHEN t.seller = 'AXS' THEN 'seatgeek_seller:AXS'
               WHEN t.pull_primary THEN 'axs_pull:primary_inventory'
               WHEN t.axs_ticketed THEN 'axs_artist:axs_ticketed'
               WHEN t.td_primary THEN 'td_match:primary_link'
               WHEN t.axs_share >= 0.30 AND t.signal_rows >= 50
                 THEN format('delivery %s%% of %s rows', round(100 * t.axs_share), t.signal_rows)
               WHEN t.pull_resale_only THEN 'axs_pull:resale_only'
               WHEN t.seller IS NOT NULL
                 THEN 'seatgeek_seller:' || t.seller || CASE WHEN t.known_id IS NOT NULL THEN ' (AXS id is a resale page)' ELSE '' END
               WHEN t.venue_verdict = 'axs'
                 THEN 'axs_venue:' || coalesce(t.verdict_basis, 'axs') || CASE WHEN t.known_id IS NOT NULL THEN ' +axs_id:' || t.src ELSE '' END
               WHEN t.known_id IS NOT NULL THEN 'axs_id:' || t.src || ' (primary unproven)'
             END AS basis
        FROM _axs_tag t) x
   WHERE x.status IS NOT NULL
  ON CONFLICT (tevo_event_id) DO UPDATE
     SET status = EXCLUDED.status, basis = EXCLUDED.basis,
         axs_event_id = coalesce(EXCLUDED.axs_event_id, t.axs_event_id),
         event_url = coalesce(EXCLUDED.event_url, t.event_url),
         aq_short_event_id = coalesce(EXCLUDED.aq_short_event_id, t.aq_short_event_id),
         event_name = EXCLUDED.event_name, venue_id = EXCLUDED.venue_id, venue_name = EXCLUDED.venue_name,
         venue_location = EXCLUDED.venue_location, occurs_at_local = EXCLUDED.occurs_at_local,
         venue_verdict = EXCLUDED.venue_verdict, seatgeek_seller = EXCLUDED.seatgeek_seller,
         delivery_share = EXCLUDED.delivery_share,
         status_changed_at = CASE WHEN t.status IS DISTINCT FROM EXCLUDED.status THEN now() ELSE t.status_changed_at END,
         updated_at = now();
  GET DIAGNOSTICS v_rows = ROW_COUNT;

  -- past events, and events that lost all evidence, leave the table
  DELETE FROM public.event_axs_primary t
   WHERE left(t.occurs_at_local, 10) < current_date::text
      OR t.updated_at < now();   -- not touched by this run (rows written above carry now())
  GET DIAGNOSTICS v_gone = ROW_COUNT;

  SELECT jsonb_object_agg(status, n) INTO v_counts
    FROM (SELECT status, count(*) n FROM public.event_axs_primary GROUP BY 1) c;
  RETURN jsonb_build_object('tagged', v_rows, 'removed', v_gone, 'by_status', v_counts);
END $$;
REVOKE ALL ON FUNCTION public.axs_primary_tag_refresh() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.axs_primary_tag_refresh() TO service_role;

CREATE OR REPLACE VIEW public.v_axs_primary_events WITH (security_invoker = true) AS
SELECT t.occurs_at_local, t.event_name, t.venue_name, t.venue_location, t.status, t.basis,
       t.axs_event_id, t.event_url, t.aq_short_event_id, t.tevo_event_id, t.venue_id,
       t.seatgeek_seller, t.delivery_share, t.first_tagged_at, t.status_changed_at
  FROM public.event_axs_primary t
 WHERE t.status IN ('confirmed', 'probable')
 ORDER BY t.occurs_at_local;
REVOKE ALL ON public.v_axs_primary_events FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.v_axs_primary_events TO service_role;

SELECT cron.schedule('axs_primary_tag_hourly', '27 * * * *', $c$
DO $body$ BEGIN
  IF NOT public.cron_should_fire('axs_primary_tag_hourly') THEN RETURN; END IF;
  PERFORM public.axs_primary_tag_refresh();
END $body$;
$c$);

SELECT public.axs_primary_tag_refresh();

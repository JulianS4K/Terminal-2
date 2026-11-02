-- Migration 20261102190000 · level:data-collection · lane:A1 (AXS ingest) · writes:axs_venue_catalog(new),axs_venue_catalog_refresh()(new),v_axs_venue_catalog(new),td_sg_performers(INSERT on refresh),cron axs_venue_catalog_refresh_daily(new),cron td_sg_discover_hourly(new),cron td_sg_discover_drain_hourly(new) · reads:axs_venues,axs_events,axs_event_snapshots,sg_events_canonical,events,gotickets_listings_snapshots,listings_snapshots · pre:20261102180000
--
-- ============================================================================
-- AXS VENUE catalogue + the loop that keeps the AXS EVENT catalogue (mig 20261102180000) growing.
-- Operator 2026-11-02: "build the venue catalogue, check the venue names against existing AXS data,
-- then build a self-updating AXS event catalogue."
--
-- WHICH VENUES ARE AXS — three kinds of evidence, strongest first:
--   1. AXS's own venue record. Every AXS event we pulled carries the venue object with
--      `axs_ticketed` (20 venues; 17 true). Names checked 2026-11-02: 20/20 match the AXS.com
--      directory scrape (axs_venues) exactly after normalisation, and 20/20 have a same-name,
--      same-city venue in `events`.
--   2. Resale delivery type: share of GoTickets AXS_TRANSFER + EVO Flash_seats listings
--      (only for venues we poll; T-Mobile Arena 76 %, Toyota Center 62 %, Crypto.com Arena 27 %).
--   3. SeatGeek's primary-ticketer field (integrated.provider_name) on events at the venue —
--      AXS / TICKETMASTER / OPEN (SeatGeek's own) / PACIOLAN / TDC. Empty on most team home
--      games, so it decides concert / theatre venues, not arenas whose tenant sells its own.
--   Seeded once from a TicketsData sweep (find_events on SeatGeek for the next performer at each
--   of the 2,417 venues whose name is in the AXS.com directory — seed paste, not in git), then
--   kept current from sg_events_canonical, matched by SeatGeek venue id (sg_venue_ids).
--
-- VERDICT (axs_venue_catalog.verdict)
--   axs           AXS's venue record says axs_ticketed, OR delivery share >= 30 % over >= 500 rows,
--                 OR >= 60 % of the SeatGeek events that name a seller name AXS
--   ticketmaster / seatgeek / other   >= 60 % of named-seller events name that seller
--   mixed         sellers named but no one >= 60 %
--   unknown       no evidence yet
--
-- SELF-UPDATING EVENT CATALOGUE
--   axs_venue_catalog_refresh() (daily) re-scores venues, then enrols the performers of upcoming
--   events at 'axs' / 'mixed' venues into td_sg_performers. td_sg_discover (hourly, 15 performers,
--   budget-gated by td_budget_ok, each performer re-checked weekly — existing pipeline, never
--   scheduled until now) fetches their SeatGeek events through TicketsData /events (1 credit each),
--   and td_sg_discover_drain writes them, seller field included, into sg_events_canonical.
--   axs_catalog_refresh (hourly, mig 20261102180000) turns every AXS-sold one into an AXS URL.
--   Cost ceiling: 15 credits/hour = 360/day; td_budget_ok() stops it below 10,000 credits left.
--   Nothing here calls AXS. All three crons are GET-only reads of TicketsData / local SQL.
-- Rollback: SELECT cron.unschedule(j) FROM unnest(ARRAY['axs_venue_catalog_refresh_daily',
--   'td_sg_discover_hourly','td_sg_discover_drain_hourly']) j; DROP VIEW v_axs_venue_catalog;
--   DROP FUNCTION axs_venue_catalog_refresh(); DROP TABLE axs_venue_catalog;
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.axs_venue_catalog (
  tevo_venue_id      bigint      PRIMARY KEY,
  venue_name         text,
  venue_location     text,
  axs_directory_name text,
  axs_venue_id       text,
  axs_page           text,
  axs_ticketed       boolean,
  sg_venue_ids       bigint[]    NOT NULL DEFAULT '{}',
  seed_axs           integer     NOT NULL DEFAULT 0,
  seed_ticketmaster  integer     NOT NULL DEFAULT 0,
  seed_seatgeek      integer     NOT NULL DEFAULT 0,
  seed_other         integer     NOT NULL DEFAULT 0,
  seed_none          integer     NOT NULL DEFAULT 0,
  seeded_at          timestamptz,
  sg_axs             integer     NOT NULL DEFAULT 0,
  sg_ticketmaster    integer     NOT NULL DEFAULT 0,
  sg_seatgeek        integer     NOT NULL DEFAULT 0,
  sg_other           integer     NOT NULL DEFAULT 0,
  sg_none            integer     NOT NULL DEFAULT 0,
  delivery_rows      integer     NOT NULL DEFAULT 0,
  delivery_axs_rows  integer     NOT NULL DEFAULT 0,
  verdict            text        NOT NULL DEFAULT 'unknown'
                       CHECK (verdict IN ('axs', 'ticketmaster', 'seatgeek', 'other', 'mixed', 'unknown')),
  verdict_basis      text,
  refreshed_at       timestamptz
);
CREATE INDEX IF NOT EXISTS axs_venue_catalog_verdict_idx ON public.axs_venue_catalog (verdict);
CREATE INDEX IF NOT EXISTS axs_venue_catalog_sg_venue_idx ON public.axs_venue_catalog USING gin (sg_venue_ids);
COMMENT ON TABLE public.axs_venue_catalog IS
  'Which venues sell through AXS. One row per TEvo venue whose name is in the AXS.com directory (axs_venues) or that has AXS evidence; verdict from AXS''s own venue record, resale delivery type and SeatGeek''s primary-ticketer field. seed_* = one-off TicketsData sweep 2026-11-02; sg_* = live from sg_events_canonical (mig 20261102190000).';
ALTER TABLE public.axs_venue_catalog ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.axs_venue_catalog FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.axs_venue_catalog TO service_role;

CREATE OR REPLACE FUNCTION public.axs_venue_catalog_refresh(p_delivery_window interval DEFAULT interval '3 hours')
RETURNS jsonb LANGUAGE plpgsql SET search_path = public, pg_temp AS $$
DECLARE
  v_axs_rec  int;
  v_enrolled int;
  v_counts   jsonb;
BEGIN
  -- 1. AXS's own venue record, from the latest pull of each tracked AXS event
  WITH rec AS (
    SELECT DISTINCT ON (ev.venue_id)
           ev.venue_id, ev.venue_name, ev.venue_location,
           s.raw->'event'->'venue'->>'venue_id' AS axs_venue_id,
           s.raw->'event'->'venue'->>'axs_page' AS axs_page,
           (s.raw->'event'->'venue'->>'axs_ticketed')::boolean AS axs_ticketed
      FROM public.axs_events a
      JOIN public.axs_event_snapshots s ON s.id = a.last_snapshot_id
      JOIN public.events ev ON ev.id = a.tevo_event_id
     WHERE s.raw->'event'->'venue' ? 'venue_id'
     ORDER BY ev.venue_id, s.id DESC)
  INSERT INTO public.axs_venue_catalog AS c (tevo_venue_id, venue_name, venue_location, axs_venue_id, axs_page, axs_ticketed)
  SELECT venue_id, venue_name, venue_location, axs_venue_id, axs_page, axs_ticketed FROM rec
  ON CONFLICT (tevo_venue_id) DO UPDATE
     SET axs_venue_id = EXCLUDED.axs_venue_id, axs_page = EXCLUDED.axs_page,
         axs_ticketed = EXCLUDED.axs_ticketed,
         venue_name = coalesce(c.venue_name, EXCLUDED.venue_name),
         venue_location = coalesce(c.venue_location, EXCLUDED.venue_location);
  GET DIAGNOSTICS v_axs_rec = ROW_COUNT;

  -- 2. live SeatGeek seller counts, by SeatGeek venue id (events from a year back onward)
  UPDATE public.axs_venue_catalog
     SET sg_axs = 0, sg_ticketmaster = 0, sg_seatgeek = 0, sg_other = 0, sg_none = 0
   WHERE sg_axs + sg_ticketmaster + sg_seatgeek + sg_other + sg_none > 0;
  WITH ev AS (
    SELECT (g.raw_event_jsonb->'venue'->>'id')::bigint AS sg_venue_id,
           CASE WHEN g.raw_event_jsonb->'integrated'->>'provider_name' IS NULL THEN 'none'
                WHEN g.raw_event_jsonb->'integrated'->>'provider_name' = 'AXS' THEN 'axs'
                WHEN g.raw_event_jsonb->'integrated'->>'provider_name' = 'TICKETMASTER' THEN 'ticketmaster'
                WHEN g.raw_event_jsonb->'integrated'->>'provider_name' = 'OPEN' THEN 'seatgeek'
                ELSE 'other' END AS seller
      FROM public.sg_events_canonical g
     WHERE g.raw_event_jsonb->'venue' ? 'id'
       AND (g.raw_event_jsonb->'venue'->>'id') ~ '^\d+$'
       AND (g.sg_event_date IS NULL OR g.sg_event_date >= current_date - 365)),
  per AS (
    SELECT c.tevo_venue_id,
           count(*) FILTER (WHERE ev.seller = 'axs')          AS a,
           count(*) FILTER (WHERE ev.seller = 'ticketmaster') AS t,
           count(*) FILTER (WHERE ev.seller = 'seatgeek')     AS s,
           count(*) FILTER (WHERE ev.seller = 'other')        AS o,
           count(*) FILTER (WHERE ev.seller = 'none')         AS n
      FROM public.axs_venue_catalog c
      JOIN ev ON ev.sg_venue_id = ANY (c.sg_venue_ids)
     GROUP BY 1)
  UPDATE public.axs_venue_catalog c
     SET sg_axs = per.a, sg_ticketmaster = per.t, sg_seatgeek = per.s, sg_other = per.o, sg_none = per.n
    FROM per
   WHERE per.tevo_venue_id = c.tevo_venue_id;

  -- 3. resale delivery type over the recent window (captured_at-indexed scans)
  WITH gt AS (
    SELECT tevo_event_id AS eid, count(*) n, count(*) FILTER (WHERE stock_type = 'AXS_TRANSFER') a
      FROM public.gotickets_listings_snapshots
     WHERE captured_at > now() - p_delivery_window AND tevo_event_id IS NOT NULL GROUP BY 1),
  evo AS (
    SELECT event_id AS eid, count(*) n, count(*) FILTER (WHERE format = 'Flash_seats') a
      FROM public.listings_snapshots
     WHERE captured_at > now() - p_delivery_window GROUP BY 1),
  per AS (
    SELECT e.venue_id, sum(coalesce(gt.n, 0) + coalesce(evo.n, 0)) n, sum(coalesce(gt.a, 0) + coalesce(evo.a, 0)) a
      FROM gt FULL JOIN evo ON evo.eid = gt.eid
      JOIN public.events e ON e.id = coalesce(gt.eid, evo.eid)
     GROUP BY 1)
  UPDATE public.axs_venue_catalog c
     SET delivery_rows = per.n, delivery_axs_rows = per.a
    FROM per WHERE per.venue_id = c.tevo_venue_id AND per.n > 0;

  -- 4. verdict
  UPDATE public.axs_venue_catalog c
     SET (verdict, verdict_basis, refreshed_at) = (
       SELECT CASE
                WHEN c.axs_ticketed THEN 'axs'
                WHEN c.delivery_rows >= 500 AND c.delivery_axs_rows >= 0.30 * c.delivery_rows THEN 'axs'
                WHEN x.named = 0 THEN 'unknown'
                WHEN x.a >= 0.6 * x.named THEN 'axs'
                WHEN x.t >= 0.6 * x.named THEN 'ticketmaster'
                WHEN x.s >= 0.6 * x.named THEN 'seatgeek'
                WHEN x.o >= 0.6 * x.named THEN 'other'
                ELSE 'mixed' END,
              CASE
                WHEN c.axs_ticketed THEN 'axs_venue_record'
                WHEN c.delivery_rows >= 500 AND c.delivery_axs_rows >= 0.30 * c.delivery_rows
                  THEN format('delivery %s%% of %s rows', round(100.0 * c.delivery_axs_rows / c.delivery_rows), c.delivery_rows)
                WHEN x.named = 0 THEN NULL
                ELSE format('seatgeek seller: axs %s, tm %s, sg %s, other %s, none %s', x.a, x.t, x.s, x.o, x.n) END,
              now()
         FROM (SELECT c.seed_axs + c.sg_axs AS a, c.seed_ticketmaster + c.sg_ticketmaster AS t,
                      c.seed_seatgeek + c.sg_seatgeek AS s, c.seed_other + c.sg_other AS o,
                      c.seed_none + c.sg_none AS n,
                      c.seed_axs + c.sg_axs + c.seed_ticketmaster + c.sg_ticketmaster
                        + c.seed_seatgeek + c.sg_seatgeek + c.seed_other + c.sg_other AS named) x);

  -- 5. keep the event catalogue growing: performers of upcoming events at AXS / mixed venues
  WITH perf AS (
    SELECT DISTINCT ON (e.primary_performer_id) e.primary_performer_id, e.primary_performer_name
      FROM public.events e
      JOIN public.axs_venue_catalog c ON c.tevo_venue_id = e.venue_id AND c.verdict IN ('axs', 'mixed')
     WHERE e.primary_performer_id IS NOT NULL AND e.primary_performer_name IS NOT NULL
       AND e.occurs_at_local ~ '^\d{4}-\d\d-\d\dT' AND e.occurs_at_local::timestamptz > now()
       AND coalesce(e.state, 'shown') <> 'ignored')
  INSERT INTO public.td_sg_performers (tevo_performer_id, performer_name, performer_url)
  SELECT primary_performer_id, primary_performer_name,
         'https://seatgeek.com/' || trim(both '-' FROM regexp_replace(lower(primary_performer_name), '[^a-z0-9]+', '-', 'g')) || '-tickets'
    FROM perf
  ON CONFLICT (tevo_performer_id) DO NOTHING;
  GET DIAGNOSTICS v_enrolled = ROW_COUNT;

  SELECT jsonb_object_agg(verdict, n) INTO v_counts
    FROM (SELECT verdict, count(*) n FROM public.axs_venue_catalog GROUP BY 1) x;
  RETURN jsonb_build_object('axs_venue_records', v_axs_rec, 'performers_enrolled', v_enrolled, 'verdicts', v_counts);
END $$;
REVOKE ALL ON FUNCTION public.axs_venue_catalog_refresh(interval) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.axs_venue_catalog_refresh(interval) TO service_role;

CREATE OR REPLACE VIEW public.v_axs_venue_catalog WITH (security_invoker = true) AS
SELECT c.tevo_venue_id, c.venue_name, c.venue_location, c.verdict, c.verdict_basis,
       c.axs_directory_name, c.axs_venue_id, c.axs_page, c.axs_ticketed,
       c.seed_axs + c.sg_axs AS axs_events, c.seed_ticketmaster + c.sg_ticketmaster AS ticketmaster_events,
       c.seed_seatgeek + c.sg_seatgeek AS seatgeek_events, c.seed_other + c.sg_other AS other_events,
       c.seed_none + c.sg_none AS no_seller_events,
       round(c.delivery_axs_rows::numeric / nullif(c.delivery_rows, 0), 3) AS delivery_axs_share,
       (SELECT count(*) FROM public.axs_catalog ac
          JOIN public.events e ON e.id = ac.tevo_event_id
         WHERE e.venue_id = c.tevo_venue_id AND ac.event_date >= current_date) AS catalogued_upcoming,
       c.refreshed_at
  FROM public.axs_venue_catalog c;
REVOKE ALL ON public.v_axs_venue_catalog FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.v_axs_venue_catalog TO service_role;

SELECT cron.schedule('axs_venue_catalog_refresh_daily', '41 6 * * *', $c$
DO $body$ BEGIN
  IF NOT public.cron_should_fire('axs_venue_catalog_refresh_daily') THEN RETURN; END IF;
  PERFORM public.axs_venue_catalog_refresh();
END $body$;
$c$);

SELECT cron.schedule('td_sg_discover_hourly', '13 * * * *', $c$
DO $body$ BEGIN
  IF NOT public.cron_should_fire('td_sg_discover_hourly') THEN RETURN; END IF;
  PERFORM public.td_sg_discover(15);
END $body$;
$c$);

SELECT cron.schedule('td_sg_discover_drain_hourly', '29 * * * *', $c$
DO $body$ BEGIN
  IF NOT public.cron_should_fire('td_sg_discover_drain_hourly') THEN RETURN; END IF;
  PERFORM public.td_sg_discover_drain();
END $body$;
$c$);

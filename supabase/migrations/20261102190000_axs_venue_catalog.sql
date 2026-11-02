-- Migration 20261102190000 · level:data-collection · lane:A1 (AXS ingest) · writes:axs_venue_catalog(new),axs_confirmed_venues(new),axs_venue_catalog_refresh()(new),v_axs_venue_catalog(new),td_sg_performers(INSERT on refresh),cron axs_venue_catalog_refresh_daily(new),cron td_sg_discover_hourly(new),cron td_sg_discover_drain_hourly(new) · reads:axs_venues,axs_events,axs_event_snapshots,sg_events_canonical,events,gotickets_listings_snapshots,listings_snapshots · pre:20261102180000
--
-- ============================================================================
-- AXS VENUE catalogue + the loop that keeps the AXS EVENT catalogue (mig 20261102180000) growing.
-- Operator 2026-11-02: "build the venue catalogue, check the venue names against existing AXS data,
-- then build a self-updating AXS event catalogue."
--
-- WHICH VENUES ARE AXS — four kinds of evidence, strongest first:
--   0. The operator's confirmed list (axs_confirmed_venues, 128 names, 2026-11-02): 98 names resolve
--      to 87 TEvo venues (60 exact name, 38 reviewed aliases / former names, e.g. STAPLES Center →
--      Crypto.com Arena, Microsoft Theater → Peacock Theater); the other 30 (The O2, Tokyo Dome,
--      golf courses, parking lots…) are kept and re-tried by exact name on every refresh.
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
-- VERDICT (axs_venue_catalog.verdict) — AXS sells per EVENT, not per building: on the operator's
-- list, Crypto.com Arena shows 10 Ticketmaster vs 5 AXS events on SeatGeek (the Lakers sell via
-- Ticketmaster), Rocket Arena's Cavaliers via SeatGeek. So any AXS evidence keeps a venue in.
--   axs           on the confirmed list, OR AXS's venue record says axs_ticketed, OR delivery share
--                 >= 30 % over >= 500 rows, OR >= 60 % of named-seller SeatGeek events name AXS
--   mixed         some SeatGeek events name AXS, others another seller
--   ticketmaster / seatgeek / other   no AXS event; >= 60 % of named-seller events name that seller
--   mixed (no AXS) sellers named, none >= 60 % — left out of the AXS list
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
-- (axs_confirmed_venues is dropped with the rest.)
-- Rollback: SELECT cron.unschedule(j) FROM unnest(ARRAY['axs_venue_catalog_refresh_daily',
--   'td_sg_discover_hourly','td_sg_discover_drain_hourly']) j; DROP VIEW v_axs_venue_catalog;
--   DROP FUNCTION axs_venue_catalog_refresh(); DROP TABLE axs_venue_catalog, axs_confirmed_venues;
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

CREATE TABLE IF NOT EXISTS public.axs_confirmed_venues (
  venue_name     text        PRIMARY KEY,
  tevo_venue_ids bigint[]    NOT NULL DEFAULT '{}',
  source         text        NOT NULL DEFAULT 'operator 2026-11-02',
  added_at       timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE public.axs_confirmed_venues IS
  'Operator-confirmed AXS venues (names as AXS shows them). tevo_venue_ids: reviewed matches; empty = not in our events yet, re-tried by exact normalised name in axs_venue_catalog_refresh() (mig 20261102190000).';
ALTER TABLE public.axs_confirmed_venues ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.axs_confirmed_venues FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.axs_confirmed_venues TO service_role;
INSERT INTO public.axs_confirmed_venues (venue_name, tevo_venue_ids) VALUES
  ('Crypto.com Arena', '{1480}'),
  ('The Greek Theatre', '{603}'),
  ('Red Rocks Amphitheatre', '{1290}'),
  ('Peacock Theater', '{4930}'),
  ('Dignity Health Sports Park Main Stadium', '{2566}'),
  ('West Hall at LACC', '{}'),
  ('Galaxy Park at Dignity Health Sports Park', '{}'),
  ('T-Mobile Arena', '{32725}'),
  ('Vegas Golden Knights', '{32725}'),
  ('The Country Club', '{}'),
  ('RODEOHOUSTON - NRG Stadium', '{2223}'),
  ('Toyota Stadium', '{3640}'),
  ('Target Center', '{1534}'),
  ('City National Arena', '{}'),
  ('Michelob ULTRA Arena at Mandalay Bay Resort & Casino', '{3571}'),
  ('Fair Grounds Race Course & Slots', '{}'),
  ('Dignity Health Sports Park', '{2566}'),
  ('TPC Scottsdale', '{1901}'),
  ('Rocket Arena', '{614}'),
  ('Tokyo Dome', '{}'),
  ('The O2', '{}'),
  ('T-Mobile Center', '{4603}'),
  ('College Park Center', '{18876}'),
  ('Toyota Center', '{2786}'),
  ('Blue Federal Credit Union Arena', '{2847}'),
  ('RODEOHOUSTON - Reliant Stadium', '{2223}'),
  ('The Roxy', '{1352}'),
  ('The Novo', '{5835}'),
  ('Greek Theatre', '{603}'),
  ('Mission Ballroom', '{34177}'),
  ('The United Theater on Broadway', '{31629}'),
  ('Santa Barbara Bowl', '{1388}'),
  ('The Theater at Virgin Hotels Las Vegas', '{633}'),
  ('Microsoft Theater', '{4930}'),
  ('The Mountain Winery', '{1956}'),
  ('Fonda Theatre', '{651}'),
  ('Gas South Arena', '{617}'),
  ('Showbox SoDo', '{5085}'),
  ('First Avenue', '{496}'),
  ('The National', '{5177}'),
  ('Michelob ULTRA Arena', '{3571}'),
  ('MGM Grand Garden Arena', '{996}'),
  ('The Theatre at Ace Hotel', '{}'),
  ('Rock & Brews', '{}'),
  ('Roadrunner', '{41454}'),
  ('Westville Music Bowl', '{2363}'),
  ('Royal Oak Music Theatre', '{1357}'),
  ('The HALL at Live!', '{35102}'),
  ('Under the K Bridge Park', '{48392}'),
  ('Masonic Temple Theatre', '{939}'),
  ('Ryman Auditorium', '{1366}'),
  ('Oxnard Performing Arts Center', '{}'),
  ('Mechanics Bank Theater', '{}'),
  ('Pechanga Arena San Diego', '{8000}'),
  ('St. Augustine Amphitheatre', '{5369}'),
  ('Keswick Theatre', '{780}'),
  ('Saban Theatre', '{1751}'),
  ('Forest Hills Stadium', '{520}'),
  ('The Orion Amphitheater', '{42016}'),
  ('Mechanics Bank Arena', '{}'),
  ('Empire Polo Club', '{1949}'),
  ('Empire Polo Club, Coachella Music Festival', '{1949}'),
  ('Miller High Life Theatre', '{2840}'),
  ('PeoplesBank Arena', '{640}'),
  ('Brookside at the Rose Bowl', '{}'),
  ('Webster Hall', '{2791}'),
  ('Utilita Arena Birmingham', '{}'),
  ('Rose Bowl Stadium', '{1342}'),
  ('Shrine Auditorium', '{1422}'),
  ('South Hall at LACC & Gilbert Lindsay Plaza', '{}'),
  ('Opry House', '{596}'),
  ('1STBANK Center', '{}'),
  ('Maverik Center', '{426}'),
  ('Broadmoor World Arena', '{33334}'),
  ('Xcite Center at Parx Casino', '{47933}'),
  ('Texas Trust CU Theatre', '{2119}'),
  ('Resorts World Theatre', '{2326}'),
  ('Flushing Meadows Corona Park', '{33317}'),
  ('Park West', '{1199}'),
  ('Dignity Health Theater', '{45502}'),
  ('Gothic Theatre', '{2040}'),
  ('Masonic Cathedral Theatre', '{}'),
  ('Gersten Pavilion', '{7572}'),
  ('Smith Field', '{}'),
  ('Pinehurst Resort & Country Club', '{}'),
  ('The Canyon at OPAC', '{31263}'),
  ('The Midland Theatre', '{1005}'),
  ('U.S. Bank Stadium', '{32930}'),
  ('Grand Garden Arena', '{996}'),
  ('Bellco Theatre', '{}'),
  ('El Rey Theatre', '{442}'),
  ('The Shed', '{}'),
  ('Turner Hall Ballroom', '{5039}'),
  ('Vivarium', '{46361}'),
  ('Terminal West', '{28994}'),
  ('Music Hall of Williamsburg', '{4853}'),
  ('Clemson Memorial Stadium', '{}'),
  ('Soldier Field', '{1444}'),
  ('The Riverside Theater', '{1322}'),
  ('Fiddler''s Green Amphitheatre', '{3039}'),
  ('San Jose Civic', '{31465}'),
  ('Toyota Arena', '{5575}'),
  ('VGK Event Parking', '{32725}'),
  ('Indian Wells Tennis Garden', '{67555,3751}'),
  ('Indian Wells Tennis Garden Parking', '{}'),
  ('Indian Wells Tennis Garden - Parking', '{}'),
  ('Players Era', '{}'),
  ('Rocket Mortgage FieldHouse', '{614}'),
  ('STAPLES Center', '{1480}'),
  ('John Paul Jones Arena', '{4054}'),
  ('Knoxville Civic Coliseum', '{33438}'),
  ('Terminal 5', '{4954}'),
  ('Jacobs Pavilion', '{2640}'),
  ('Devon Park', '{5542}'),
  ('USA Softball Hall of Fame Stadium', '{}'),
  ('The Rooftop at Pier 17', '{33710}'),
  ('Desert Diamond Arena', '{2763}'),
  ('Georgia Theatre', '{1842}'),
  ('Oakmont Country Club', '{}'),
  ('The Los Angeles Country Club', '{}'),
  ('Erin Hills', '{}'),
  ('The Thunderdome', '{}'),
  ('Pompano Beach Amphitheater', '{1247}'),
  ('Michigan Stadium', '{1002}'),
  ('Joan C. Edwards Stadium', '{932}'),
  ('BOK Center', '{5118}'),
  ('NRG Stadium', '{2223}'),
  ('Arlington Theatre', '{64}')
ON CONFLICT (venue_name) DO UPDATE SET tevo_venue_ids = EXCLUDED.tevo_venue_ids
  WHERE cardinality(public.axs_confirmed_venues.tevo_venue_ids) = 0;

CREATE OR REPLACE FUNCTION public.axs_venue_catalog_refresh(p_delivery_window interval DEFAULT interval '3 hours')
RETURNS jsonb LANGUAGE plpgsql SET search_path = public, pg_temp AS $$
DECLARE
  v_axs_rec  int;
  v_enrolled int;
  v_counts   jsonb;
BEGIN
  -- 0. confirmed list: re-try unmatched names by exact normalised name, then make sure every
  --    confirmed venue has a catalogue row
  UPDATE public.axs_confirmed_venues cv
     SET tevo_venue_ids = m.ids
    FROM (SELECT cv2.venue_name, array_agg(DISTINCT e.venue_id) AS ids
            FROM public.axs_confirmed_venues cv2
            JOIN public.events e
              ON regexp_replace(regexp_replace(lower(e.venue_name), '^the ', ''), '[^a-z0-9]+', '', 'g')
               = regexp_replace(regexp_replace(lower(cv2.venue_name), '^the ', ''), '[^a-z0-9]+', '', 'g')
           WHERE cardinality(cv2.tevo_venue_ids) = 0
           GROUP BY 1) m
   WHERE m.venue_name = cv.venue_name;
  INSERT INTO public.axs_venue_catalog (tevo_venue_id, venue_name, venue_location)
  SELECT DISTINCT ON (e.venue_id) e.venue_id, e.venue_name, e.venue_location
    FROM public.axs_confirmed_venues cv
    CROSS JOIN LATERAL unnest(cv.tevo_venue_ids) AS v(id)
    JOIN public.events e ON e.venue_id = v.id
   ORDER BY e.venue_id, e.occurs_at_local DESC
  ON CONFLICT (tevo_venue_id) DO NOTHING;

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
                WHEN x.confirmed THEN 'axs'
                WHEN c.axs_ticketed THEN 'axs'
                WHEN c.delivery_rows >= 500 AND c.delivery_axs_rows >= 0.30 * c.delivery_rows THEN 'axs'
                WHEN x.named = 0 THEN 'unknown'
                WHEN x.a >= 0.6 * x.named THEN 'axs'
                WHEN x.a > 0 THEN 'mixed'
                WHEN x.t >= 0.6 * x.named THEN 'ticketmaster'
                WHEN x.s >= 0.6 * x.named THEN 'seatgeek'
                WHEN x.o >= 0.6 * x.named THEN 'other'
                ELSE 'mixed' END,
              CASE
                WHEN x.confirmed THEN 'operator_confirmed'
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
                        + c.seed_seatgeek + c.sg_seatgeek + c.seed_other + c.sg_other AS named,
                      EXISTS (SELECT 1 FROM public.axs_confirmed_venues cv
                               WHERE c.tevo_venue_id = ANY (cv.tevo_venue_ids)) AS confirmed) x);

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

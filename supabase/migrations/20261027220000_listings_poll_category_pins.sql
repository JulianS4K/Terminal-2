-- Migration 20261027220000 · level:ops · lane:A1 (data plane — collectors) · writes:listings_poll_category_pins(new),collector_cadence(5 upd + 8 new rows),v_listings_poll_pinned_events(replace, +cadence_scope),pinned_listings_poll_tick()(patch) · reads:events,listings_poll_pins,listings_poll_league_pins,performer_espn_team_xref · pre:20261023051000
--
-- Operator 2026-10-27: expand listings polling scope — NCAA football, Broadway musicals + plays,
-- concerts/comedy at arenas — and slow events more than 30 days out to daily to make room.
--
-- Capacity (measured 2026-10-27): pinned_listings_poll_tick(70, 55, 8) every 2 min tops out at
-- ~50 k EVO / ~40 k GT polls a day; the ~4,960 pinned events used ~41 k / ~31 k. Nothing overdue.
--
-- 1. collector_cadence 'listings', events > 30 days out → daily (EVO d31_60 240→1440, d61p 720→1440;
--    GT d31_60 360→1440). Frees ~4.6 k EVO + ~1.5 k GT polls/day. Only the pinned tick reads these
--    rows today (the fleet pollers 321/628/355 are off); a fleet resume inherits the slower bands.
-- 2. collector_cadence scope 'listings_slow' (EVO + GT): 60 min < 3 d, 120 min < 7 d, 480 min < 30 d,
--    3 days beyond. Category pins use it — whole categories are too wide for the team-pin cadence
--    (Broadway alone is ~7,100 performances; at 'listings' cadence it would need ~90 k polls/day).
--    SG keeps its non-owned 'listings' bands (already daily).
-- 3. listings_poll_category_pins: (event_types, optional venue_location pattern, venue rule).
--    venue_rule 'league_venues' = only venues that host an enabled league pin's games (arenas and
--    stadiums; venue capacity is filled for 187 of 6,740 venues, so it can't drive the cut).
--    Seeds: ncaa_football (ncaa--2), broadway (musicals+plays, New York NY), arena_concerts_comedy.
-- 4. v_listings_poll_pinned_events + cadence_scope; team/league pins win over category pins.
-- 5. pinned_listings_poll_tick: EVO + GT bands use v.cadence_scope (asserted patch of the live body).
SET LOCAL lock_timeout = '10s';

UPDATE public.collector_cadence SET peak_interval_min = 1440, offpeak_interval_min = 1440, updated_at = now(),
       notes = coalesce(notes || ' ', '') || '2026-10-27: >30 d out → daily (operator, polling scope expansion).'
 WHERE scope = 'listings' AND ((source = 'EVO' AND band IN ('d31_60','d61p')) OR (source = 'GT' AND band = 'd31_60'))
   AND offpeak_interval_min < 1440;

INSERT INTO public.collector_cadence (source, scope, band, min_hours, max_hours, peak_interval_min, offpeak_interval_min, owned_kind, sort_order, notes)
SELECT s.source, 'listings_slow', b.band, b.min_h, b.max_h, b.mins, b.mins, 'any', b.ord,
       'Category pins (mig 20261027220000): whole categories poll slower than team pins.'
  FROM (VALUES ('EVO'), ('GT')) s(source)
 CROSS JOIN (VALUES ('le3d', 0, 72, 60, 0), ('le7d', 72, 168, 120, 1),
                    ('d8_30', 168, 720, 480, 2), ('d31p', 720, NULL, 4320, 3)) b(band, min_h, max_h, mins, ord)
ON CONFLICT (source, scope, band, owned_kind) DO NOTHING;

CREATE TABLE IF NOT EXISTS public.listings_poll_category_pins (
  pin_key        text        PRIMARY KEY,
  event_types    text[]      NOT NULL,
  location_like  text,
  venue_rule     text        NOT NULL DEFAULT 'any' CHECK (venue_rule IN ('any', 'league_venues')),
  sources        text[]      NOT NULL DEFAULT ARRAY['evo','gt','sg'] CHECK (sources <@ ARRAY['evo','gt','sg']),
  cadence_scope  text        NOT NULL DEFAULT 'listings_slow' CHECK (cadence_scope IN ('listings', 'listings_slow')),
  enabled        boolean     NOT NULL DEFAULT true,
  note           text,
  created_at     timestamptz NOT NULL DEFAULT now(),
  updated_at     timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE public.listings_poll_category_pins IS
  'Operator-pinned event categories (events.event_type) for listing polls, at the slower listings_slow cadence (mig 20261027220000).';
ALTER TABLE public.listings_poll_category_pins ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.listings_poll_category_pins FROM anon, authenticated;

INSERT INTO public.listings_poll_category_pins (pin_key, event_types, location_like, venue_rule, note) VALUES
  ('ncaa_football', ARRAY['ncaa--2'], NULL, 'any',
   'Operator 2026-10-27: expand polling scope — NCAA football.'),
  ('broadway', ARRAY['musicals','plays'], 'New York, NY%', 'any',
   'Operator 2026-10-27: expand polling scope — Broadway musicals + plays (New York venues).'),
  ('arena_concerts_comedy',
   ARRAY['rock-pop','comedy','country-folk','alternative-rock','rap-hip-hop','r-b-urban-soul','hard-rock-metal',
         'dance-electronic','indie-music','latin','jazz-blues','classical','family'],
   NULL, 'league_venues',
   'Operator 2026-10-27: expand polling scope — top concerts / comedy, cut to venues that host a pinned league team (arenas, stadiums).')
ON CONFLICT (pin_key) DO NOTHING;

CREATE OR REPLACE VIEW public.v_listings_poll_pinned_events
WITH (security_invoker = true) AS
SELECT DISTINCT ON (tevo_event_id) tevo_event_id, pin_key, sources, occurs_at, hours_to_event, sg_owned, cadence_scope
  FROM (
    SELECT e.id AS tevo_event_id, p.pin_key, p.sources,
           e.occurs_at_local::timestamptz AS occurs_at,
           EXTRACT(epoch FROM (e.occurs_at_local::timestamptz - now())) / 3600.0 AS hours_to_event,
           p.sg_owned_cadence AS sg_owned, 'listings'::text AS cadence_scope, 0 AS tier
      FROM public.listings_poll_pins p
      JOIN public.events e ON e.primary_performer_id = p.performer_id
                          AND (p.venue_name IS NULL OR e.venue_name = p.venue_name)
     WHERE p.enabled
       AND e.occurs_at_local ~ '^\d{4}-\d\d-\d\dT'
       AND e.occurs_at_local::timestamptz > now() - interval '3 hours'
       AND coalesce(e.state, 'shown') <> 'ignored'
    UNION ALL
    SELECT e.id, 'league:' || lp.league, lp.sources,
           e.occurs_at_local::timestamptz,
           EXTRACT(epoch FROM (e.occurs_at_local::timestamptz - now())) / 3600.0,
           lp.sg_owned_cadence, 'listings'::text, 0
      FROM public.listings_poll_league_pins lp
      JOIN public.performer_espn_team_xref x ON upper(x.espn_league) = lp.league
      JOIN public.events e ON e.primary_performer_id = x.tevo_performer_id
     WHERE lp.enabled
       AND e.occurs_at_local ~ '^\d{4}-\d\d-\d\dT'
       AND e.occurs_at_local::timestamptz > now() - interval '3 hours'
       AND coalesce(e.state, 'shown') <> 'ignored'
    UNION ALL
    SELECT e.id, 'category:' || cp.pin_key, cp.sources,
           e.occurs_at_local::timestamptz,
           EXTRACT(epoch FROM (e.occurs_at_local::timestamptz - now())) / 3600.0,
           false, cp.cadence_scope, 1
      FROM public.listings_poll_category_pins cp
      JOIN public.events e ON e.event_type = ANY (cp.event_types)
     WHERE cp.enabled
       AND (cp.location_like IS NULL OR e.venue_location LIKE cp.location_like)
       AND (cp.venue_rule = 'any' OR e.venue_id IN (
             SELECT le.venue_id
               FROM public.listings_poll_league_pins lp2
               JOIN public.performer_espn_team_xref x2 ON upper(x2.espn_league) = lp2.league
               JOIN public.events le ON le.primary_performer_id = x2.tevo_performer_id
              WHERE lp2.enabled))
       AND e.occurs_at_local ~ '^\d{4}-\d\d-\d\dT'
       AND e.occurs_at_local::timestamptz > now() - interval '3 hours'
       AND coalesce(e.state, 'shown') <> 'ignored'
  ) u
 ORDER BY tevo_event_id, tier, sg_owned DESC, pin_key;
REVOKE ALL ON public.v_listings_poll_pinned_events FROM anon, authenticated;

DO $patch$
DECLARE
  v_def text := pg_get_functiondef('public.pinned_listings_poll_tick(integer,integer,integer)'::regprocedure);
  r     record;
BEGIN
  IF position('v.cadence_scope' in v_def) > 0 THEN
    RAISE NOTICE 'pinned_listings_poll_tick already uses cadence_scope';
    RETURN;
  END IF;
  FOR r IN SELECT * FROM (VALUES
    ($o$public.collector_band('EVO', 'listings', v.hours_to_event)$o$,
     $n$public.collector_band('EVO', v.cadence_scope, v.hours_to_event)$n$),
    ($o$public.collector_band('GT', 'listings', v.hours_to_event)$o$,
     $n$public.collector_band('GT', v.cadence_scope, v.hours_to_event)$n$)
  ) f(old, new) LOOP
    IF position(r.old in v_def) = 0 THEN
      RAISE EXCEPTION 'pinned_listings_poll_tick patch: fragment not found: %', r.old;
    END IF;
    v_def := replace(v_def, r.old, r.new);
  END LOOP;
  EXECUTE v_def;
END $patch$;

-- VERIFY:
--   SELECT split_part(pin_key, ':', 1), cadence_scope, count(*) FROM v_listings_poll_pinned_events GROUP BY 1, 2;
--   SELECT * FROM collector_band('EVO', 'listings_slow', 10);   -- le3d, 60
--   after an hour: SELECT count(*) FROM evo_listings_poll_state s JOIN v_listings_poll_pinned_events v
--     ON v.tevo_event_id = s.event_id WHERE v.pin_key LIKE 'category:%' AND s.last_polled_listings_at > now() - interval '1 hour';
-- ROLLBACK: UPDATE listings_poll_category_pins SET enabled = false;  (cadence rows: restore 240/720/360)

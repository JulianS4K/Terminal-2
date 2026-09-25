-- ============================================================================
-- Venue coordinates for maps (mig 20260924230000). Runs after
-- test_checkout_attribution.sql in the same DB; reuses the f1 fixtures.
-- ============================================================================
\set ON_ERROR_STOP on

INSERT INTO public.exos_events(id,org_id,name,slug,status,total_tickets,tickets_sold) VALUES
  ('f1000000-0000-0000-0000-0000000000e7','f1000000-0000-0000-0000-000000000001','F1 Draft','f1-draft','draft',0,0);

SET ROLE service_role;
SELECT public.exos_upsert_event_geo('f1000000-0000-0000-0000-0000000000e1','Elsewhere, 599 Johnson Ave, Brooklyn','ok',
  'ChIJelsewhere', 40.7063, -73.9232, '599 Johnson Ave, Brooklyn, NY 11237, USA');
SELECT public.exos_upsert_event_geo('f1000000-0000-0000-0000-0000000000e7','Somewhere','ok','ChIJdraft', 40.7, -73.9, 'x');
SELECT public.exos_upsert_event_geo('f1000000-0000-0000-0000-0000000000e2','Old Venue','ok','ChIJold', 40.8, -73.95, 'y');
RESET ROLE;
UPDATE public.exos_event_geo SET geocoded_at = now() - interval '31 days' WHERE event_id = 'f1000000-0000-0000-0000-0000000000e2';

-- G1-G2. The public view shows fresh pins for published events only.
DO $$
BEGIN
  ASSERT (SELECT count(*) FROM public.exos_public_event_geo WHERE event_id='f1000000-0000-0000-0000-0000000000e1') = 1, 'G1: fresh pin visible';
  ASSERT (SELECT count(*) FROM public.exos_public_event_geo WHERE event_id='f1000000-0000-0000-0000-0000000000e7') = 0, 'G1: draft hidden';
  ASSERT (SELECT count(*) FROM public.exos_public_event_geo WHERE event_id='f1000000-0000-0000-0000-0000000000e2') = 0, 'G2: 31-day-old pin hidden';
  RAISE NOTICE 'OK  G1-G2 public view: published + fresh only';
END $$;

-- G3. Refresh sees the stale row; expiry drops its coordinates but keeps the Place ID.
SET ROLE service_role;
DO $$
DECLARE n int;
BEGIN
  ASSERT EXISTS (SELECT 1 FROM public.exos_event_geo_due() WHERE event_id='f1000000-0000-0000-0000-0000000000e2' AND place_id='ChIJold'),
         'G3: stale row is due for refresh';
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_event_geo_due() WHERE event_id='f1000000-0000-0000-0000-0000000000e1'), 'G3: fresh row not due';
  n := public.exos_expire_event_geo();
  ASSERT n = 1, 'G3: exactly the stale row expires, got ' || n;
  RAISE NOTICE 'OK  G3 refresh queue + 30-day expiry';
END $$;
RESET ROLE;
DO $$
BEGIN
  ASSERT (SELECT lat IS NULL AND lng IS NULL AND place_id = 'ChIJold' FROM public.exos_event_geo
           WHERE event_id='f1000000-0000-0000-0000-0000000000e2'), 'G3: coords gone, place_id kept';
END $$;

-- G4. A transient error on the same address keeps the pin (only the error is
--     recorded); a failing NEW address clears it.
SET ROLE service_role;
SELECT public.exos_upsert_event_geo('f1000000-0000-0000-0000-0000000000e1','Elsewhere, 599 Johnson Ave, Brooklyn','error',
  NULL, 1, 1, NULL, 'OVER_QUERY_LIMIT');
RESET ROLE;
DO $$
BEGIN
  ASSERT (SELECT lat = 40.7063 AND status = 'ok' AND error = 'OVER_QUERY_LIMIT' FROM public.exos_event_geo
           WHERE event_id='f1000000-0000-0000-0000-0000000000e1'), 'G4: transient error keeps the pin';
  ASSERT EXISTS (SELECT 1 FROM public.exos_public_event_geo WHERE event_id='f1000000-0000-0000-0000-0000000000e1'), 'G4: still on the map';
END $$;
SET ROLE service_role;
SELECT public.exos_upsert_event_geo('f1000000-0000-0000-0000-0000000000e1','New Venue, Queens','error',
  NULL, NULL, NULL, NULL, 'REQUEST_DENIED');
RESET ROLE;
DO $$
BEGIN
  ASSERT (SELECT lat IS NULL AND place_id IS NULL AND status = 'error' FROM public.exos_event_geo
           WHERE event_id='f1000000-0000-0000-0000-0000000000e1'), 'G4: failed new address drops the old pin';
  RAISE NOTICE 'OK  G4 transient errors keep pins; a new failing address clears them';
END $$;

-- G5. Buyers can read the view, not the table, and can't write anything.
SET ROLE anon;
DO $$
BEGIN
  PERFORM 1 FROM public.exos_public_event_geo LIMIT 1;
  BEGIN
    PERFORM 1 FROM public.exos_event_geo LIMIT 1;
    RAISE EXCEPTION 'G5: anon read the base table';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  BEGIN
    PERFORM public.exos_upsert_event_geo('f1000000-0000-0000-0000-0000000000e1','x','ok');
    RAISE EXCEPTION 'G5: anon wrote a geocode';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  RAISE NOTICE 'OK  G5 anon: view only';
END $$;
RESET ROLE;

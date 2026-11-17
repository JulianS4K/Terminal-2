-- Migration 20260909000500 · level:data-collection · lane:A1 · writes:cross_source_venue_map · reads:none · pre:20260908235500
--
-- Already applied to prod · via MCP 2026-09-08 under operator direction. All 11
-- ids verified against GET /v9/venues/<id> BEFORE seeding — every id, name, city
-- and state matches the decoded URL. After seeding, all 33 non-parking spellings
-- of these venues resolve, and "Allen County War Memorial Coliseum" correctly
-- keeps its own venue 27 rather than colliding with LA Memorial Coliseum.
--
-- Eleven more TEvo venue ids from operator console URLs — the college-football
-- tail that was the largest remaining block.
--
--   1673  Vaught Hemingway Stadium                        Oxford MS
--    810  LA Memorial Coliseum                            Los Angeles CA
--    485  Faurot Field at Memorial Stadium                Columbia MO
--   1775  Casino Del Sol Stadium                          Tucson AZ
--   2026  Frank Howard Field at Clemson Memorial Stadium  Clemson SC
--   2789  Bill Snyder Family Stadium                      Manhattan KS
--   1285  Donald W. Reynolds Razorback Stadium            Fayetteville AR
--   1826  Saban Field at Bryant-Denny Stadium             Tuscaloosa AL
--   1784  Gerald J. Ford Stadium                          Dallas TX
--   1363  SHI Stadium                                     Piscataway NJ
--   1365  Ryan Field                                      Evanston IL
--
-- TYPE INCONSISTENCY AGAIN: venue_id arrives as a STRING for 1673 and 2789, and
-- as an integer for the other nine, in the same batch of URLs. Read it as text
-- and cast (also noted in mig 20260908234500).
--
-- ALIASES ARE MOSTLY TEvo'S OWN. Nine of these venues publish `keywords` that
-- name exactly the spellings our CRM uses, fetched during verification:
--     810  "LA Memorial Coliseum, Los Angeles Memorial Coliseum"
--    1285  "Razorback Stadium"
--    1775  "Arizona Stadium"
--    1784  "Gerald Ford Stadium, Gerald J Ford Stadium"
--    1826  "Bryant Denny Stadium, Bryant-Denny Stadium"
--    2789  "Bill Snyder Family Football Stadium"
--    1363  "High Point Solutions Stadium"
-- Where TEvo's canonical name is the SPONSORED one and ours is the plain one
-- (Saban Field at Bryant-Denny, Frank Howard Field at Clemson Memorial, Donald
-- W. Reynolds Razorback), no prefix or canonical form can bridge the gap — the
-- names diverge at the front — so those need explicit aliases. Two venues need
-- none at all: Vaught Hemingway (the hyphenated form canonicalises identically)
-- and Ryan Field.
--
-- Parking spellings are excluded, per mig 20260908230000.
--
-- RESULT: 895 CRM orders mapped across the following passes, audited at 0 date
-- mismatches and 0 parking leaks. Future CRM order coverage 83.5% -> 87.0%,
-- event coverage 72.7% -> 75.9%.
--
-- REVERSIBLE: DELETE FROM public.cross_source_venue_map
--   WHERE tevo_venue_id IN (1673,810,485,1775,2026,2789,1285,1826,1784,1363,1365);

INSERT INTO public.cross_source_venue_map
      (tevo_venue_id, tevo_venue_name, city, state, country, crm_aliases)
VALUES
  (1673, 'Vaught Hemingway Stadium', 'Oxford', 'MS', 'US', '[]'::jsonb),
  ( 810, 'LA Memorial Coliseum', 'Los Angeles', 'CA', 'US',
    '["Los Angeles Memorial Coliseum"]'::jsonb),
  ( 485, 'Faurot Field at Memorial Stadium', 'Columbia', 'MO', 'US',
    '["Faurot Field (Memorial Stadium)","Faurot Field - Columbia, MO"]'::jsonb),
  (1775, 'Casino Del Sol Stadium', 'Tucson', 'AZ', 'US',
    '["Arizona Stadium"]'::jsonb),
  (2026, 'Frank Howard Field at Clemson Memorial Stadium', 'Clemson', 'SC', 'US',
    '["Clemson Memorial Stadium"]'::jsonb),
  (2789, 'Bill Snyder Family Stadium', 'Manhattan', 'KS', 'US',
    '["Bill Snyder Family Football Stadium","Wagner Field At Bill Snyder Family Stadium"]'::jsonb),
  (1285, 'Donald W. Reynolds Razorback Stadium', 'Fayetteville', 'AR', 'US',
    '["Razorback Stadium","Razorback Stadium - Fayetteville, AR"]'::jsonb),
  (1826, 'Saban Field at Bryant-Denny Stadium', 'Tuscaloosa', 'AL', 'US',
    '["Bryant Denny Stadium","Bryant-Denny Stadium","Bryant-Denny Stadium - Tuscaloosa, AL"]'::jsonb),
  (1784, 'Gerald J. Ford Stadium', 'Dallas', 'TX', 'US',
    '["Gerald Ford Stadium","Gerald J Ford Stadium","Gerald Ford Stadium - Dallas, TX"]'::jsonb),
  (1363, 'SHI Stadium', 'Piscataway', 'NJ', 'US',
    '["High Point Solutions Stadium"]'::jsonb),
  (1365, 'Ryan Field', 'Evanston', 'IL', 'US', '[]'::jsonb)
ON CONFLICT (tevo_venue_id) DO UPDATE
  SET crm_aliases = EXCLUDED.crm_aliases,
      city = COALESCE(public.cross_source_venue_map.city, EXCLUDED.city),
      state = COALESCE(public.cross_source_venue_map.state, EXCLUDED.state),
      updated_at = now();

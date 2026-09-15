-- Operator-supplied TEvo venue ids + one GoTickets performer id, and the finding they exposed:
-- OUR MIRROR OF TEVO IS INCOMPLETE. This is not a naming problem and not a mapping problem.
--
-- Context. A venue report produced earlier today named a set of CRM venues as "not in EVO". The
-- operator answered with TEvo core links proving otherwise, so the first thing to correct is my
-- own claim: those venues ARE in TEvo. What I measured was that they did not match anything in
-- `events` or `cross_source_venue_map` at 0.75 trigram similarity, which is a different sentence.
-- "Not matched at threshold" is not "not in the catalogue", and reporting one as the other sends
-- people looking for the wrong defect.
--
-- But checking the supplied ids against the mirror produced something worse than a naming gap:
--
--   event 3214790  Northwestern Medicine Field at Martin Stadium   venue 34465   NOT in events
--   event 3390444  Ching Athletics Complex                         venue 43534   NOT in events
--   event 3204527  Acrisure Bounce House                           venue  4665   NOT in events
--   event 3354666  Maverik Stadium                                 venue  2404   NOT in events
--   event 3402399  Kansas Jayhawks Football (performer 15694)                    NOT in events
--   event 3490180  McKale Center                                   venue   947   NOT in events
--   event 3413401  Value City Arena at The Schottenstein Center    venue 33304   present
--
-- Six of seven events the operator linked from TEvo's own UI are absent from `public.events`.
-- Four of the six venues hold ZERO events in the mirror. McKale Center is the instructive one:
-- venue 947 has 22 future events mirrored, yet event 3490180 at that same venue is missing -- so
-- coverage is partial per venue, not all-or-nothing, which rules out "the venue is simply not
-- tracked" as a complete explanation.
--
-- WHAT THIS MEANS FOR EVERY "UNMAPPED" NUMBER QUOTED TODAY. 6,799 future TEvo events carry no
-- GoTickets id -- but that counts only events we HAVE. Events TEvo lists and we never ingested are
-- invisible to every census in this session, including the venue and event CSVs. The denominators
-- are understated by an unmeasured amount.
--
-- NOT FIXED HERE, and deliberately so. Ingest is a collector concern: `events` is written by
-- tevo_venue_events_harvest, evo_event_backfill_process, nascar_ingest_process and
-- tournament_pull_process, all of which consume payloads fetched elsewhere. Widening what gets
-- fetched is an operator call about upstream API budget, not something to infer from four links.
-- (Note for whoever picks it up: `evo_discover_new_events` is NOT the stub its repo copy suggests
--  -- the live body does carry net.http_get -- but it does not INSERT INTO events either.)
--
-- WHAT IS FIXED HERE. The crosswalk rows, so that when those events are ingested they resolve
-- immediately instead of failing venue resolution again, and so CRM's spellings stop missing:
--
--   * 4 venues seeded into cross_source_venue_map with the operator's tevo_venue_id
--   * crm_aliases extended on 2 venues that were already present but whose CRM/Vivid spellings
--     ("McKale Center - Tucson, AZ") append the city and so fell under the 0.75 bar
--   * GoTickets performer 48359 recorded for TEvo performer 102612 "Mubadala Citi DC Open"
--
-- The DC Open cannot be event-mapped yet and that is the same root cause: GoTickets holds 14
-- future DC Open events, our mirror holds 0 (performer 102612's 13 mirrored events all fall in
-- 2026-07-25..2026-08-02, already past), while the CRM orders are for 2027. There is nothing on
-- the TEvo side to map TO. The performer id is stored now so the link exists the moment the 2027
-- events arrive.
--
-- NAMING TRAP, since this file touches both: `td_gt_performers` is GAMETIME, not GoTickets -- its
-- rows are gametime.co URLs. The GoTickets performer id therefore goes in performer_external_ids
-- with source='gotickets', not there. PROJECT_BIBLE warns about exactly this collision.
--
-- All three statements are idempotent and were applied by hand on 2026-09-15 under operator
-- direction; this file is the audit record and the replay path.

INSERT INTO public.performer_external_ids
  (performer_id, source, external_id, external_name, meta, set_at)
VALUES (102612, 'gotickets', '48359', 'Mubadala Citi DC Open',
        jsonb_build_object('url','https://pro.gotickets.com/search?performerId=48359',
                           'provenance','operator-supplied 2026-09-15',
                           'migration','20260915170000'),
        now())
ON CONFLICT DO NOTHING;

INSERT INTO public.cross_source_venue_map
  (tevo_venue_id, tevo_venue_name, tevo_venue_location, city, state, country,
   crm_aliases, gotickets_aliases, id_provenance, created_at, updated_at)
SELECT s.tevo_venue_id, s.tevo_venue_name, s.city||', '||s.state, s.city, s.state, 'US',
       jsonb_build_array(s.tevo_venue_name, s.crm_alias), '[]'::jsonb,
       jsonb_build_object('tevo_venue_id','operator-supplied TEvo core link 2026-09-15'),
       now(), now()
FROM (VALUES
  (34465, 'Northwestern Medicine Field at Martin Stadium', 'Evanston', 'IL', 'Martin Stadium - Evanston'),
  (43534, 'Ching Athletics Complex', 'Honolulu', 'HI', 'Clarence T.C. Ching Athletics Complex'),
  ( 4665, 'Acrisure Bounce House', 'Orlando', 'FL', 'Acrisure Bounce House (formerly FBC Mortgage Stadium)'),
  ( 2404, 'Maverik Stadium', 'Logan', 'UT', 'Merlin Olsen Field At Maverik Stadium')
) AS s(tevo_venue_id, tevo_venue_name, city, state, crm_alias)
WHERE NOT EXISTS (SELECT 1 FROM public.cross_source_venue_map v
                   WHERE v.tevo_venue_id = s.tevo_venue_id);

UPDATE public.cross_source_venue_map v
   SET crm_aliases = (
         SELECT jsonb_agg(DISTINCT a) FROM (
           SELECT jsonb_array_elements_text(
                    CASE WHEN jsonb_typeof(v.crm_aliases)='array' THEN v.crm_aliases ELSE '[]'::jsonb END) a
           UNION SELECT unnest(x.al)
         ) q),
       updated_at = now()
  FROM (VALUES
    (947::bigint,   ARRAY['McKale Center - Tucson, AZ']),
    (33304::bigint, ARRAY['Value City Arena at Schottenstein Center - Columbus, OH'])
  ) x(vid, al)
 WHERE v.tevo_venue_id = x.vid;

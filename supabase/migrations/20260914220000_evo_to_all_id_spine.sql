-- EVO -> all: give the hub a real ID spine, so matching stops going through names.
--
-- WHY. Every mapper we have runs INWARD: a marketplace row is matched to a TEvo event, mostly
-- by (venue name, local day, name overlap). Nothing runs OUTWARD, and nothing matches on ids
-- even where both sides publish them. The measured consequences, 2026-09-14:
--   * the hub holds 15,110 rows with a tevo_event_id; ALL 15,110 join the TEvo mirror and ALL
--     carry events.venue_id, 14,776 a primary_performer_id — yet the hub stores neither. Every
--     venue comparison re-derives from a STRING what a join already knows.
--   * sg_events_canonical.raw_event_jsonb carries a venue id on 8,295 rows and a performers
--     array on 8,270 — and sg_venue_id, the column meant to hold it, is filled on 114. The
--     ids were being parsed and thrown away.
--   * outward coverage is thin where it matters: of those 15,110 hub rows, seatgeek 11,579,
--     gotickets 6,610, vivid 5,680, stubhub 5,422, ticketmaster 4,259, tickpick 43.
--
-- WHAT THIS DOES. Four things, cheapest first — no new tables, because the repo already has
-- the two xrefs this needs and the standing rule is populate, don't add a seventh surface:
--   1. aq_event_map gains tevo_venue_id / tevo_performer_id, filled by a pure join against
--      events. No matching, no heuristics, no API: 100% coverage by construction.
--   2. sg_events_canonical.sg_venue_id is backfilled from the raw payload it was already
--      pulling and discarding.
--   3. performer_external_ids (which already has exactly the right shape — (performer_id,
--      source) unique AND (source, external_id) unique, i.e. 1:1 per source, i.e.
--      unique-or-decline enforced by the schema) is populated with the marketplace sources.
--   4. cross_source_venue_map keeps its existing deriver, which now has far more evidence.
--
-- THE PERFORMER RULE, and why it is majority + name and not unanimity. SeatGeek and TEvo do
-- not model "the performer" the same way, and the disagreement is systematic, not noise:
--   * SG marks the resident orchestra primary for every date at that hall; TEvo marks the
--     guest artist or the programme. SG performer 5301 "Los Angeles Philharmonic" pairs with
--     FOURTEEN different TEvo performers (Yuja Wang, Dudamel, Debussy, Joe Hisaishi, …).
--   * home/away flips the primary: SG 8 "New York Yankees" pairs with both the Yankees and
--     NYC FC (same stadium), SG 30 "Arizona Diamondbacks" with the D-backs and the Royals.
--   * TEvo uses the TOURNAMENT as performer where SG uses the club: NYC FC, Minnesota United,
--     Orlando City, Philadelphia Union and Nashville SC ALL pair with TEvo 71274 "Leagues Cup".
--     That is many-to-one and is not an identity at all.
-- So: the winning TEvo performer must hold >= 80% of the evidence AND its name must overlap
-- the source's >= 0.5. Measured over 5,854 evidence rows / 320 distinct SG performers:
-- 306 clear the majority bar, 279 clear both. The 25 the name guard rejects are almost
-- entirely things that are not performers — "Foley's Premium Hospitality" -> Notre Dame
-- Football, "UMCU All Star Lounge" -> Michigan Wolverines, "Saratoga Turf Terrace Dining" ->
-- Saratoga Horse Racing, "Arizona Cardinals Pregame Party" -> Arizona Cardinals — plus support
-- acts read as headliners ("Mac Ayres" -> Teddy Swims) and tour names ("Christmas Together" ->
-- Cece Winans). One honest false reject: "Johnny Blue Skies" IS Sturgill Simpson. Declining an
-- alias costs a row; accepting a hospitality package costs a wrong mapping, so the guard stays.

-- ---------------------------------------------------------------- 1. the hub's ID spine
ALTER TABLE public.aq_event_map ADD COLUMN IF NOT EXISTS tevo_venue_id     bigint;
ALTER TABLE public.aq_event_map ADD COLUMN IF NOT EXISTS tevo_performer_id bigint;
CREATE INDEX IF NOT EXISTS idx_aq_event_map_tevo_venue
  ON public.aq_event_map (tevo_venue_id, event_date) WHERE tevo_venue_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_aq_event_map_tevo_performer
  ON public.aq_event_map (tevo_performer_id) WHERE tevo_performer_id IS NOT NULL;

COMMENT ON COLUMN public.aq_event_map.tevo_venue_id IS
  'events.venue_id for this row''s tevo_event_id. A join, not a match — 100% derivable (mig 20260914220000).';
COMMENT ON COLUMN public.aq_event_map.tevo_performer_id IS
  'events.primary_performer_id for this row''s tevo_event_id (mig 20260914220000).';

-- Pure join. Re-runnable, fill-only where the mirror disagrees with nothing.
CREATE OR REPLACE FUNCTION public.event_mapper_anchor_ids()
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $fn$
DECLARE v_v int; v_p int; v_vs int; v_ps int;
BEGIN
  IF current_user NOT IN ('service_role', 'postgres', 'supabase_admin') THEN
    RAISE EXCEPTION 'forbidden: %', current_user USING ERRCODE = '42501';
  END IF;
  PERFORM set_config('statement_timeout', '120000', true);

  UPDATE public.aq_event_map a SET tevo_venue_id = e.venue_id
    FROM public.events e
   WHERE e.id = a.tevo_event_id AND e.venue_id IS NOT NULL
     AND a.tevo_venue_id IS DISTINCT FROM e.venue_id;
  GET DIAGNOSTICS v_v = ROW_COUNT;

  UPDATE public.aq_event_map a SET tevo_performer_id = e.primary_performer_id
    FROM public.events e
   WHERE e.id = a.tevo_event_id AND e.primary_performer_id IS NOT NULL
     AND a.tevo_performer_id IS DISTINCT FROM e.primary_performer_id;
  GET DIAGNOSTICS v_p = ROW_COUNT;

  -- and carry the AQ short ids across from the two AQ maps, fill-only
  UPDATE public.aq_event_map a SET venue_short_id = m.venue_short_id
    FROM public.cross_source_venue_map m
   WHERE m.tevo_venue_id = a.tevo_venue_id AND m.venue_short_id IS NOT NULL AND a.venue_short_id IS NULL;
  GET DIAGNOSTICS v_vs = ROW_COUNT;

  UPDATE public.aq_event_map a SET performer_short_id = p.performer_short_id
    FROM public.aq_performer_map p
   WHERE p.tevo_performer_id = a.tevo_performer_id AND p.performer_short_id IS NOT NULL AND a.performer_short_id IS NULL;
  GET DIAGNOSTICS v_ps = ROW_COUNT;

  RETURN jsonb_build_object('tevo_venue_id', v_v, 'tevo_performer_id', v_p,
                            'venue_short_id', v_vs, 'performer_short_id', v_ps);
END $fn$;

REVOKE ALL ON FUNCTION public.event_mapper_anchor_ids() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.event_mapper_anchor_ids() TO service_role;

-- ---------------------------------------------------------------- 2. stop discarding SG's ids
-- sg_events_canonical has parsed the SeatGeek payload all along and kept the venue id on 114
-- rows out of 8,295 that carry one. event_mapper_surface_sql already coalesces to the raw
-- field at read time, so the mapper was covered — but venue_xref_derive_from_events reads the
-- COLUMN, which is why the SeatGeek leg of the venue xref only ever saw a sliver of evidence.
UPDATE public.sg_events_canonical c
   SET sg_venue_id = (c.raw_event_jsonb->'venue'->>'id')::bigint
 WHERE c.sg_venue_id IS NULL AND c.raw_event_jsonb->'venue'->>'id' ~ '^[0-9]+$';

-- ---------------------------------------------------------------- 3. performer ids per source
-- Writes into performer_external_ids, which already enforces 1:1 per source in BOTH directions
-- (PK (performer_id, source) + unique (source, external_id, league)). That schema IS the
-- unique-or-decline rule, so a many-to-one like the Leagues Cup case cannot be written even by
-- accident — but the guards below stop it long before the constraint has to.
--
-- Evidence comes only from rows we have ALREADY mapped: the source event and the TEvo event
-- are the same event, so their primary performers are the same performer. That is the whole
-- derivation; the guards exist because the two catalogues disagree about what "primary" means.
CREATE OR REPLACE FUNCTION public.performer_xref_derive_from_events(p_apply boolean DEFAULT false)
RETURNS TABLE(source text, external_id text, external_name text, tevo_performer_id bigint,
              tevo_performer_name text, evidence int, share numeric, name_overlap numeric, action text)
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $fn$
BEGIN
  IF current_user NOT IN ('service_role', 'postgres', 'supabase_admin') THEN
    RAISE EXCEPTION 'forbidden: %', current_user USING ERRCODE = '42501';
  END IF;
  PERFORM set_config('statement_timeout', '120000', true);

  DROP TABLE IF EXISTS _pairs;
  CREATE TEMP TABLE _pairs ON COMMIT DROP AS
    -- SeatGeek: raw performers array, the one flagged primary
    SELECT 'seatgeek'::text AS src, (p->>'id') AS ext_id, (p->>'name') AS ext_name,
           e.primary_performer_id AS tevo_pid, e.primary_performer_name AS tevo_pname
      FROM public.sg_events_canonical c
      JOIN public.events e ON e.id = c.tevo_event_id
      CROSS JOIN LATERAL jsonb_array_elements(coalesce(c.raw_event_jsonb->'performers', '[]'::jsonb)) p
     WHERE c.tevo_event_id IS NOT NULL AND e.primary_performer_id IS NOT NULL
       AND (p->>'primary') = 'true' AND (p->>'id') ~ '^[0-9]+$'
    UNION ALL
    -- tickets.dev: the catalogue's own performer id. This is the anchor that covers the
    -- marketplaces which publish NO performer id of their own (gotickets, vivid, stubhub,
    -- ticketmaster, tickpick) — once a tdev performer id is bound to a TEvo performer, every
    -- catalogue event carries that performer regardless of which marketplace it came from.
    SELECT 'tickets_dev', (p->>'performerId'), (p->>'name'),
           e.primary_performer_id, e.primary_performer_name
      FROM public.tickets_dev_event t
      CROSS JOIN LATERAL jsonb_array_elements(coalesce(t.performers, '[]'::jsonb)) p
      JOIN public.tickets_dev_source_id s ON s.tdev_id = t.tdev_id
      JOIN public.aq_event_map a
        ON (s.marketplace = 'vividseats'   AND a.vivid_event_id::text     = s.source_event_id)
        OR (s.marketplace = 'gotickets'    AND a.gotickets_event_id::text = s.source_event_id)
        OR (s.marketplace = 'stubhub'      AND a.sh_event_id::text        = s.source_event_id)
        OR (s.marketplace = 'ticketmaster' AND a.tm_event_id::text        = s.source_event_id)
      JOIN public.events e ON e.id = a.tevo_event_id
     WHERE (p->>'master')::boolean IS TRUE AND (p->>'performerId') ~ '^[0-9]+$'
       AND a.tevo_event_id IS NOT NULL AND e.primary_performer_id IS NOT NULL;

  DROP TABLE IF EXISTS _judged;
  CREATE TEMP TABLE _judged ON COMMIT DROP AS
  WITH tally AS (
    SELECT src, ext_id, max(ext_name) AS ext_name, tevo_pid, max(tevo_pname) AS tevo_pname,
           count(*) AS n, sum(count(*)) OVER (PARTITION BY src, ext_id) AS tot,
           row_number() OVER (PARTITION BY src, ext_id ORDER BY count(*) DESC, tevo_pid) AS rk
      FROM _pairs GROUP BY src, ext_id, tevo_pid),
  best AS (
    SELECT t.src, t.ext_id, t.ext_name, t.tevo_pid, t.tevo_pname, t.n,
           round(t.n::numeric / t.tot, 3) AS shr,
           round(public.event_mapper_overlap(public.event_mapper_norm_name(t.ext_name),
                                             public.event_mapper_norm_name(t.tevo_pname)), 3) AS ovl
      FROM tally t WHERE t.rk = 1)
  SELECT b.src, b.ext_id, b.ext_name, b.tevo_pid, b.tevo_pname, b.n, b.shr, b.ovl,
         CASE WHEN b.shr < 0.8 THEN 'decline_split'
              WHEN b.ovl < 0.5 THEN 'decline_name'
              -- both directions of performer_external_ids are unique, so a slot already taken
              -- by a different id (or a different performer) is a decline, never an overwrite
              WHEN EXISTS (SELECT 1 FROM public.performer_external_ids x
                            WHERE x.performer_id = b.tevo_pid AND x.source = b.src
                              AND x.external_id IS DISTINCT FROM b.ext_id) THEN 'decline_taken'
              WHEN EXISTS (SELECT 1 FROM public.performer_external_ids x
                            WHERE x.source = b.src AND x.external_id = b.ext_id
                              AND x.performer_id IS DISTINCT FROM b.tevo_pid) THEN 'decline_reverse'
              WHEN EXISTS (SELECT 1 FROM public.performer_external_ids x
                            WHERE x.performer_id = b.tevo_pid AND x.source = b.src
                              AND x.external_id = b.ext_id) THEN 'already'
              ELSE 'write' END AS act
    FROM best b;

  IF p_apply THEN
    INSERT INTO public.performer_external_ids (performer_id, source, external_id, external_name, meta, set_at)
    SELECT j.tevo_pid, j.src, j.ext_id, j.ext_name,
           jsonb_build_object('derived_by', 'performer_xref_derive_from_events',
                              'evidence', j.n, 'share', j.shr, 'name_overlap', j.ovl), now()
      FROM _judged j WHERE j.act = 'write'
    ON CONFLICT DO NOTHING;
    UPDATE _judged SET act = 'written' WHERE act = 'write';
  END IF;

  RETURN QUERY
  SELECT j.src, j.ext_id, j.ext_name, j.tevo_pid, j.tevo_pname, j.n::int, j.shr, j.ovl, j.act
    FROM _judged j ORDER BY j.src, j.n DESC;
END $fn$;

REVOKE ALL ON FUNCTION public.performer_xref_derive_from_events(boolean) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.performer_xref_derive_from_events(boolean) TO service_role;

COMMENT ON FUNCTION public.performer_xref_derive_from_events(boolean) IS
  'Derives (source, performer id) -> tevo_performer_id from events we already mapped. Majority >= 0.8 AND name overlap >= 0.5, unique in both directions. Dry run by default (mig 20260914220000).';

-- ---------------------------------------------------------------- 4. register the sources
-- canonical_external_ids.source_key is FK'd to data_sources, and a trigger on
-- performer_external_ids mirrors every row into it — so an unregistered source_key fails the
-- INSERT rather than silently creating an orphan. That FK is the reason these rows exist.
--
-- 'seatgeek' is NOT the same source as the existing 'sg_broker': sg_broker's external_id is an
-- md5 of the performer name (brokerdata's own opaque key), while SeatGeek's platform ids are
-- small integers (1508 = Ray LaMontagne). Two id spaces, two source keys; merging them would
-- make both unique constraints meaningless.
INSERT INTO public.data_sources (source_key, display_name, kind, host, auth_method, read_only, added_at, notes) VALUES
 ('seatgeek',    'SeatGeek (platform catalogue)',            'catalog', 'api.seatgeek.com',     'public',           true, now(),
  'SeatGeek''s PUBLIC numeric performer/venue ids, as carried in sg_events_canonical.raw_event_jsonb. A different id space from sg_broker, whose external_id is an md5 of the performer name.'),
 ('tickets_dev', 'Tickets.dev (cross-marketplace catalogue)', 'catalog', 'api.tickets.dev',     'api_key_header',   true, now(),
  'GET /v1/events only — free, never billed, not rate limited. Cross-marketplace event + performer identity for sources that publish no id of their own. /v1/capture is never called. Key in vault as ''tickets.dev''.'),
 ('gotickets',   'GoTickets',                                'pricing', 'gotickets.com',        'access_id_secret', true, now(),
  'Catalogue + listings + sales. Publishes venue_id on purchases; no performer id (performer is a NAME on gotickets_event).'),
 ('tickpick',    'TickPick',                                 'pricing', 'api.tickpick.com',     'api_key_header',   true, now(),
  'Orders carry raw venue.id. event_date IS a true UTC instant (see PROJECT_BIBLE §3).'),
 ('vividseats',  'Vivid Seats',                              'pricing', 'www.vividseats.com',   'api_key_header',   true, now(),
  'Orders carry productionId as the event id. Publishes NO venue id and no performer id. event_date is LOCAL wall time labelled +00 (see PROJECT_BIBLE §3).'),
 ('stubhub',     'StubHub',                                  'pricing', 'api.stubhub.com',      'none',             true, now(),
  'We hold StubHub EVENT ids only, learned through the tickets.dev catalogue. No direct integration.'),
 ('ticketmaster','Ticketmaster',                             'pricing', 'app.ticketmaster.com', 'none',             true, now(),
  'Event ids only, via tickets.dev. NOTE: ids are alphanumeric, so aq_event_map.tm_event_id (bigint) can only carry the all-digit half.')
ON CONFLICT (source_key) DO NOTHING;

-- ---------------------------------------------------------------- 5. venue ids per source
-- The pre-existing venue_xref_derive_from_events() fills cross_source_venue_map and is saturated
-- on its own evidence (a live run filled 4 rows). This is the ID-first companion: it pairs the
-- SOURCE's venue id with events.venue_id on every mapped row and writes the agreement into
-- canonical_external_ids — the project's general (entity_kind, tevo_id, source_key) cross
-- reference, already home to the espn / sg_broker / seatdata linkages and simply never fed the
-- marketplace ids. No new table: the one that should hold this already existed.
--
-- The majority bar is 0.9, HIGHER than the performer deriver's 0.8, because a venue does not
-- legitimately split the way a "primary performer" does. A split here means a complex — a
-- stadium and its lots, a tennis centre and its show courts — which must decline, not pick.
--
-- The OUT parameters are named out_*: naming one `source_key` made the INSERT's ON CONFLICT
-- target resolve to the plpgsql variable instead of the column (42702). Renaming an OUT
-- parameter needs a DROP; CREATE OR REPLACE cannot do it.
DROP FUNCTION IF EXISTS public.venue_xref_derive_by_id(boolean);

CREATE FUNCTION public.venue_xref_derive_by_id(p_apply boolean DEFAULT false)
RETURNS TABLE(out_source text, out_external_id text, out_external_name text, out_tevo_venue_id bigint,
              out_tevo_venue_name text, out_evidence int, out_share numeric, out_action text)
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $fn$
BEGIN
  IF current_user NOT IN ('service_role', 'postgres', 'supabase_admin') THEN
    RAISE EXCEPTION 'forbidden: %', current_user USING ERRCODE = '42501';
  END IF;
  PERFORM set_config('statement_timeout', '120000', true);

  DROP TABLE IF EXISTS _vpairs;
  CREATE TEMP TABLE _vpairs ON COMMIT DROP AS
    SELECT 'seatgeek'::text AS src, c.sg_venue_id::text AS ext_id, c.sg_venue_name AS ext_name,
           e.venue_id AS tevo_vid, e.venue_name AS tevo_vname
      FROM public.sg_events_canonical c JOIN public.events e ON e.id = c.tevo_event_id
     WHERE c.tevo_event_id IS NOT NULL AND c.sg_venue_id IS NOT NULL AND e.venue_id IS NOT NULL
    UNION ALL
    SELECT 'tickpick', (o.raw->'venue'->>'id'), o.raw->'venue'->>'name', e.venue_id, e.venue_name
      FROM public.tickpick_orders o JOIN public.events e ON e.id = o.tevo_event_id
     WHERE o.tevo_event_id IS NOT NULL AND o.raw->'venue'->>'id' ~ '^[0-9]+$' AND e.venue_id IS NOT NULL
    UNION ALL
    SELECT 'gotickets', g.venue_id::text, g.venue_name, e.venue_id, e.venue_name
      FROM public.gotickets_purchases g JOIN public.events e ON e.id = g.tevo_event_id
     WHERE g.tevo_event_id IS NOT NULL AND g.venue_id IS NOT NULL AND e.venue_id IS NOT NULL;

  DROP TABLE IF EXISTS _vjudged;
  CREATE TEMP TABLE _vjudged ON COMMIT DROP AS
  WITH tally AS (
    SELECT src, ext_id, max(ext_name) AS ext_name, tevo_vid, max(tevo_vname) AS tevo_vname,
           count(*) AS n, sum(count(*)) OVER (PARTITION BY src, ext_id) AS tot,
           row_number() OVER (PARTITION BY src, ext_id ORDER BY count(*) DESC, tevo_vid) AS rk
      FROM _vpairs GROUP BY src, ext_id, tevo_vid),
  best AS (SELECT t.src, t.ext_id, t.ext_name, t.tevo_vid, t.tevo_vname, t.n,
                  round(t.n::numeric / t.tot, 3) AS shr
             FROM tally t WHERE t.rk = 1)
  SELECT b.src, b.ext_id, b.ext_name, b.tevo_vid, b.tevo_vname, b.n, b.shr,
         CASE WHEN b.shr < 0.9 THEN 'decline_split'
              WHEN EXISTS (SELECT 1 FROM public.canonical_external_ids x
                            WHERE x.entity_kind = 'venue' AND x.tevo_id = b.tevo_vid AND x.source_key = b.src
                              AND x.external_id IS DISTINCT FROM b.ext_id) THEN 'decline_taken'
              WHEN EXISTS (SELECT 1 FROM public.canonical_external_ids x
                            WHERE x.entity_kind = 'venue' AND x.source_key = b.src AND x.external_id = b.ext_id
                              AND x.tevo_id IS DISTINCT FROM b.tevo_vid) THEN 'decline_reverse'
              WHEN EXISTS (SELECT 1 FROM public.canonical_external_ids x
                            WHERE x.entity_kind = 'venue' AND x.tevo_id = b.tevo_vid AND x.source_key = b.src
                              AND x.external_id = b.ext_id) THEN 'already'
              ELSE 'write' END AS act
    FROM best b;

  IF p_apply THEN
    INSERT INTO public.canonical_external_ids AS t (entity_kind, tevo_id, source_key, external_id,
                                               external_name, match_method, match_confidence, matched_at, meta)
    SELECT 'venue', j.tevo_vid, j.src, j.ext_id, j.ext_name, 'venue_xref_derive_by_id', j.shr, now(),
           jsonb_build_object('evidence', j.n, 'share', j.shr)
      FROM _vjudged j WHERE j.act = 'write'
    ON CONFLICT (entity_kind, tevo_id, source_key) DO NOTHING;

    -- keep the existing wide xref in step, fill-only, never overwriting a different id
    UPDATE public.cross_source_venue_map m SET sg_venue_id = j.ext_id::bigint, updated_at = now()
      FROM _vjudged j WHERE j.act = 'write' AND j.src = 'seatgeek'
       AND m.tevo_venue_id = j.tevo_vid AND m.sg_venue_id IS NULL
       AND NOT EXISTS (SELECT 1 FROM public.cross_source_venue_map o WHERE o.sg_venue_id = j.ext_id::bigint);
    UPDATE public.cross_source_venue_map m SET tickpick_venue_id = j.ext_id::bigint, updated_at = now()
      FROM _vjudged j WHERE j.act = 'write' AND j.src = 'tickpick'
       AND m.tevo_venue_id = j.tevo_vid AND m.tickpick_venue_id IS NULL
       AND NOT EXISTS (SELECT 1 FROM public.cross_source_venue_map o WHERE o.tickpick_venue_id = j.ext_id::bigint);
    UPDATE public.cross_source_venue_map m SET gotickets_venue_id = j.ext_id::bigint, updated_at = now()
      FROM _vjudged j WHERE j.act = 'write' AND j.src = 'gotickets'
       AND m.tevo_venue_id = j.tevo_vid AND m.gotickets_venue_id IS NULL
       AND NOT EXISTS (SELECT 1 FROM public.cross_source_venue_map o WHERE o.gotickets_venue_id = j.ext_id::bigint);

    UPDATE _vjudged SET act = 'written' WHERE act = 'write';
  END IF;

  RETURN QUERY SELECT j.src, j.ext_id, j.ext_name, j.tevo_vid, j.tevo_vname, j.n::int, j.shr, j.act
                 FROM _vjudged j ORDER BY j.src, j.n DESC;
END $fn$;

REVOKE ALL ON FUNCTION public.venue_xref_derive_by_id(boolean) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.venue_xref_derive_by_id(boolean) TO service_role;

COMMENT ON FUNCTION public.venue_xref_derive_by_id(boolean) IS
  'Derives (source, venue id) -> tevo venue id from events already mapped, into canonical_external_ids + cross_source_venue_map. Majority >= 0.9, unique both ways. Dry run by default (mig 20260914220000).';

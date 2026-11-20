-- Migration 20261117140000 · level:data-collection · lane:A1 (data plane — mapping program) · writes:tickpick_catalog_venue(tevo_venue_id fill-only),vivid_catalog_venue(tevo_venue_id fill-only),tickpick_catalog_audit,vivid_catalog_audit,catalog_venue_norm()(new),catalog_venue_kept()(new),catalog_venue_pair()(new),tickpick_catalog_map()(redefined),vivid_catalog_map()(redefined),v_catalog_venue_pairs(new view),cron:catalog_venue_pair_hourly(new) · reads:events,tickpick_catalog_venue,tickpick_catalog_event,vivid_catalog_venue,vivid_catalog_event,axs_export_event · pre:20261117130000
--
-- MAPPING PROGRAM — VENUE PAIRING FOR THE CATALOGUE MAPPERS.
--
-- Operator 2026-11-17: "focus on venue pairing first". A catalogue event can only be mapped by rule when its venue is
-- paired with a TEvo venue, and the pairing was the ceiling: TickPick had 3,337 of 6,022 venues with upcoming events
-- paired, Vivid 2,714 of 12,359 — 22k TickPick and 208k Vivid upcoming events sat at unpaired venues. The one name rule
-- so far (name_state, mig 20261117080000) needs the exact lower-cased name; the catalogues spell venues differently
-- ("Harrahs Cabaret at Harrahs Las Vegas" / "Harrah's Cabaret At Harrah's Las Vegas", "KA Theatre at MGM Grand Hotel
-- and Casino" / "KA Theatre at MGM Grand", "Majestic Theatre Dallas" / "Majestic Theatre - Dallas"), and Vivid lists a
-- separate "<venue> Parking" venue for most houses.
--
-- catalog_venue_pair(source, apply) pairs the unpaired venues of one catalogue (TickPick or Vivid) that have upcoming
-- events, in this order of trust, each rule only where it names exactly one TEvo venue (measured on prod 2026-11-17,
-- read-only, before authoring — the samples of every rule kept were right; eq_state WITH the city stripped paired
-- "Palace Theatre - San Francisco" to Los Angeles and "Tampa Convention Center" to Miami Beach and was dropped):
--   pair_eq_city   normalised names equal, same city and state. The normaliser (catalog_venue_norm) lower-cases,
--                  reads & as and, drops apostrophes and punctuation, spells theatre/centre the American way, drops
--                  the / at / of / in / on / hotel / casino / resort / complex / and / parking, and the city's and
--                  state's own words ("Comedy Cellar - Las Vegas" and "Comedy Cellar at Rio Las Vegas" lose las vegas).
--                  Prod: 183 TickPick + 2,758 Vivid venues (2.5k + 91k events).
--   pair_sibling   the other catalogue's paired venue, or AXS's own TEvo venue (axs_export_event.tevo_venue_id), with
--                  the same normalised name in the same city, all naming one TEvo venue. Prod: 38 + 601 venues.
--   pair_eq_state  normalised names equal WITHOUT the city stripped, two or more words, one TEvo venue in the state —
--                  the catalogue places the venue in a neighbouring town ("Canadian Tire Centre", Ottawa / Kanata).
--   pair_parking   a "<venue> Parking" venue takes the pairing of its base venue (same catalogue, same city), whether
--                  paired before or in this run.
--   pair_affix     one normalised name is the other with words added at the front or the back ("Boca Black Box" /
--                  "Boca Black Box Center for the Arts", "Hayes Theater" / "Helen Hayes Theatre"), the shorter two or
--                  more words and eight or more letters — AND corroborated: at least one of the venue's upcoming events
--                  fits an EVO event at the candidate on the same local day. Uncorroborated, the affix rule paired
--                  "Gaslamp Quarter - The Yellow Door Comedy Club" to "Gaslamp Quarter" and "Improv Comedy Club - DC"
--                  to "Comedy Club DC"; with it, only the candidate the events agree with.
--   pair_cooccur   no name relation needed: the TEvo venue in the same city whose EVO events fit the venue's events
--                  (same local day, names equal or one containing the other) on two or more days with no other venue
--                  fitting any, or on three or more days with three times the runner-up ("Microtorium" / "Micro
--                  Wrestling Federation at the Microtorium", "Metropolitan Opera House" / "Metropolitan Opera at
--                  Lincoln Center"). One shared day proved nothing ("Penn Plaza" / "Madison Square Garden") and never
--                  pairs. Prod sample: one in ten of the venues no name rule reached.
-- A rule with two or more candidates pairs nothing (the venue judge, mig 20261117120000, or the operator decides).
-- Writes are FILL-ONLY: a venue already paired is never touched; every pairing is a 'venue_xref' row in the
-- catalogue's audit table naming the method and the TEvo venue, reversible from there. Product venues' events
-- (parking, tailgate, shuttle, VIP, package) never corroborate. v_catalog_venue_pairs shows every pairing with both
-- names for review.
--
-- THE MAPPERS TAKE THE PAIRINGS. tickpick_catalog_map / vivid_catalog_map (last defined in mig 20261117120000) kept
-- 'manual' and 'llm_judge' rows as set and resolved every other venue themselves each run; they now keep every
-- 'pair_%' row too (catalog_venue_kept), at the trust level of the venue judge: above a venue learned from matched
-- events, below manual / aq_venue_map / cross_source / name_state. The pairer runs at :33, before the mappers (:41,
-- :43), so a venue paired in one hour maps its events the same hour. RULE 2: nothing upstream is called.

BEGIN;
SET LOCAL lock_timeout = '10s';

-- ───────────────────────── 1. helpers ─────────────────────────
CREATE OR REPLACE FUNCTION public.catalog_venue_norm(p_name text, p_city text, p_state text, p_strip_city boolean DEFAULT true)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
AS $function$
  SELECT coalesce((
    SELECT string_agg(CASE t WHEN 'theatre' THEN 'theater' WHEN 'centre' THEN 'center' WHEN 'ctr' THEN 'center'
                             WHEN 'amphitheatre' THEN 'amphitheater' WHEN 'amph' THEN 'amphitheater' WHEN 'pac' THEN 'performing arts center' ELSE t END, ' ' ORDER BY o)
      FROM unnest(string_to_array(regexp_replace(replace(replace(replace(lower(coalesce(p_name, '')), '&', ' and '), '''', ''), '’', ''), '[^a-z0-9]+', ' ', 'g'), ' ')) WITH ORDINALITY u(t, o)
     WHERE t <> ''
       AND t NOT IN ('the', 'at', 'of', 'in', 'on', 'hotel', 'casino', 'resort', 'complex', 'and', 'parking')
       AND (NOT p_strip_city OR t <> ALL (string_to_array(lower(coalesce(p_city, '')), ' ')))
       AND t <> lower(coalesce(p_state, ''))), '')
$function$;
COMMENT ON FUNCTION public.catalog_venue_norm(text, text, text, boolean) IS
  'A venue name as the pairer compares it (mig 20261117140000): lower-cased, & as and, no apostrophes or punctuation, theatre/centre spelt theater/center, without the / at / of / in / on / hotel / casino / resort / complex / and / parking and (unless p_strip_city is false) the city''s and state''s own words.';

CREATE OR REPLACE FUNCTION public.catalog_venue_kept(p_method text)
 RETURNS boolean
 LANGUAGE sql
 IMMUTABLE
AS $function$
  SELECT coalesce(p_method IN ('manual', 'llm_judge') OR p_method LIKE 'pair\_%', false)
$function$;
COMMENT ON FUNCTION public.catalog_venue_kept(text) IS
  'True for a catalogue venue pairing the mappers keep as set and never overwrite: manual, the venue judge''s (llm_judge), the pairer''s (pair_*). Mig 20261117140000.';

-- ───────────────────────── 2. the pairer ─────────────────────────
CREATE OR REPLACE FUNCTION public.catalog_venue_pair(p_source text, p_apply boolean DEFAULT true)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
 SET client_min_messages TO 'warning'
AS $function$
DECLARE
  v_run   uuid := gen_random_uuid();
  v_out   jsonb := '{}'::jsonb;
  v_tbl   text;   -- the catalogue's venue table
  v_key   text;   -- its venue id column
  v_evt   text;   -- the catalogue's event table
  v_aud   text;   -- its audit table
  v_sib   text;   -- the other catalogue's venue table
  v_sibk  text;
  v_live  text;   -- the event filter of the catalogue
  v_to    date := current_date + 365;
  v_n     int;
  v_t     timestamptz := clock_timestamp();
  v_ms    jsonb := '{}'::jsonb;
BEGIN
  IF p_source = 'tickpick' THEN
    v_tbl := 'tickpick_catalog_venue'; v_key := 'tp_venue_id'; v_evt := 'tickpick_catalog_event'; v_aud := 'tickpick_catalog_audit';
    v_sib := 'vivid_catalog_venue'; v_sibk := 'vivid_venue_id';
    v_live := $f$c.status IS DISTINCT FROM 'canceled' AND c.merged_into IS NULL AND c.date_confirmed$f$;
  ELSIF p_source = 'vivid' THEN
    v_tbl := 'vivid_catalog_venue'; v_key := 'vivid_venue_id'; v_evt := 'vivid_catalog_event'; v_aud := 'vivid_catalog_audit';
    v_sib := 'tickpick_catalog_venue'; v_sibk := 'tp_venue_id';
    v_live := 'true';
  ELSE
    RAISE EXCEPTION 'catalog_venue_pair: unknown source %', p_source;
  END IF;
  -- one run per catalogue at a time
  IF NOT pg_try_advisory_xact_lock(hashtext('catalog_venue_pair:' || p_source)) THEN
    RETURN jsonb_build_object('skipped', 'another catalog_venue_pair(' || p_source || ') is running');
  END IF;

  -- 0. TEvo venues on upcoming events, with the city and state from venue_location and both spellings of the name
  DROP TABLE IF EXISTS _vp_tv;
  CREATE TEMP TABLE _vp_tv ON COMMIT DROP AS
  SELECT s.venue_id, s.nm, s.city, s.st,
         public.catalog_venue_norm(s.nm, s.city, s.st, true) AS norm,
         public.catalog_venue_norm(s.nm, s.city, s.st, false) AS norm_full
    FROM (SELECT e.venue_id, min(e.venue_name) AS nm,
                 lower(trim(regexp_replace(min(e.venue_location), ',\s*[^,]*$', ''))) AS city,
                 upper(trim(regexp_replace(min(e.venue_location), '^.*,\s*', ''))) AS st
            FROM public.events e
           WHERE e.venue_id IS NOT NULL AND e.venue_location LIKE '%,%' AND e.state IS DISTINCT FROM 'ignored'
             AND e.occurs_at_local >= to_char(now() - interval '1 day', 'YYYY-MM-DD')
           GROUP BY e.venue_id) s
   WHERE coalesce(s.st, '') <> '';
  CREATE INDEX ON _vp_tv (st, city, norm);
  CREATE INDEX ON _vp_tv (st, norm_full);
  CREATE INDEX ON _vp_tv (venue_id);
  ANALYZE _vp_tv;

  -- 1. the catalogue's unpaired venues with upcoming events
  DROP TABLE IF EXISTS _vp_u;
  CREATE TEMP TABLE _vp_u (id bigint PRIMARY KEY, name text, city text, st text, ev int, norm text, norm_full text, is_parking boolean) ON COMMIT DROP;
  EXECUTE format($q$
    INSERT INTO _vp_u
    SELECT v.%2$I, v.name, lower(trim(v.city)), upper(trim(v.state)), count(*),
           public.catalog_venue_norm(v.name, v.city, v.state, true), public.catalog_venue_norm(v.name, v.city, v.state, false),
           lower(v.name) ~ '\mparking\M'
      FROM public.%1$I v
      JOIN public.%3$I c ON c.%2$I = v.%2$I
     WHERE v.tevo_venue_id IS NULL AND coalesce(v.name, '') <> '' AND coalesce(v.state, '') <> ''
       AND coalesce(v.country, 'US') IN ('US', 'CA', 'MX')
       AND c.event_date BETWEEN current_date AND $1 AND %4$s
     GROUP BY v.%2$I, v.name, v.city, v.state$q$, v_tbl, v_key, v_evt, v_live) USING v_to;
  CREATE INDEX ON _vp_u (st, city, norm);
  ANALYZE _vp_u;
  v_out := v_out || jsonb_build_object('source', p_source, 'unpaired_in', (SELECT count(*) FROM _vp_u), 'unpaired_events_in', (SELECT coalesce(sum(ev), 0) FROM _vp_u));

  DROP TABLE IF EXISTS _vp_pick;
  CREATE TEMP TABLE _vp_pick (id bigint PRIMARY KEY, tevo_venue_id bigint NOT NULL, method text NOT NULL, note text) ON COMMIT DROP;
  DROP TABLE IF EXISTS _vp_amb;
  CREATE TEMP TABLE _vp_amb (id bigint, rule text, n int) ON COMMIT DROP;

  -- R1. equal normalised names in the same city
  INSERT INTO _vp_pick
  SELECT u.id, min(t.venue_id), 'pair_eq_city', min(t.nm)
    FROM _vp_u u JOIN _vp_tv t ON t.st = u.st AND t.city = u.city AND t.norm = u.norm
   WHERE u.norm <> ''
   GROUP BY u.id HAVING count(DISTINCT t.venue_id) = 1;
  INSERT INTO _vp_amb
  SELECT u.id, 'eq_city', count(DISTINCT t.venue_id)
    FROM _vp_u u JOIN _vp_tv t ON t.st = u.st AND t.city = u.city AND t.norm = u.norm
   WHERE u.norm <> '' GROUP BY u.id HAVING count(DISTINCT t.venue_id) > 1;
  v_ms := v_ms || jsonb_build_object('eq_city', (extract(epoch FROM clock_timestamp() - v_t) * 1000)::int); v_t := clock_timestamp();

  -- R2. the other catalogue's pairing, or AXS's own TEvo venue, for the same normalised name in the same city
  DROP TABLE IF EXISTS _vp_sib;
  CREATE TEMP TABLE _vp_sib (via text, name text, city text, st text, tevo_venue_id bigint, norm text) ON COMMIT DROP;
  EXECUTE format($q$
    INSERT INTO _vp_sib
    SELECT %1$L || ' venue ' || v.%3$I, v.name, lower(trim(v.city)), upper(trim(v.state)), v.tevo_venue_id,
           public.catalog_venue_norm(v.name, v.city, v.state, true)
      FROM public.%2$I v WHERE v.tevo_venue_id IS NOT NULL AND coalesce(v.state, '') <> ''$q$,
    CASE WHEN p_source = 'tickpick' THEN 'vivid' ELSE 'tickpick' END, v_sib, v_sibk);
  INSERT INTO _vp_sib
  SELECT 'axs venue "' || s.venue_name || '"', s.venue_name, lower(trim(s.venue_city)), upper(trim(s.venue_state)), s.tevo_venue_id,
         public.catalog_venue_norm(s.venue_name, s.venue_city, s.venue_state, true)
    FROM (SELECT a.venue_name, a.venue_city, a.venue_state, a.tevo_venue_id
            FROM public.axs_export_event a
           WHERE a.tevo_venue_id IS NOT NULL AND a.gone_at IS NULL AND coalesce(a.venue_state, '') <> '' AND coalesce(a.venue_name, '') <> ''
           GROUP BY 1, 2, 3, 4) s;
  CREATE INDEX ON _vp_sib (st, city, norm);
  INSERT INTO _vp_pick
  SELECT u.id, min(s.tevo_venue_id), 'pair_sibling', min(s.via)
    FROM _vp_u u JOIN _vp_sib s ON s.st = u.st AND s.city = u.city AND s.norm = u.norm
   WHERE u.norm <> '' AND NOT EXISTS (SELECT 1 FROM _vp_pick p WHERE p.id = u.id)
   GROUP BY u.id HAVING count(DISTINCT s.tevo_venue_id) = 1;
  INSERT INTO _vp_amb
  SELECT u.id, 'sibling', count(DISTINCT s.tevo_venue_id)
    FROM _vp_u u JOIN _vp_sib s ON s.st = u.st AND s.city = u.city AND s.norm = u.norm
   WHERE u.norm <> '' AND NOT EXISTS (SELECT 1 FROM _vp_pick p WHERE p.id = u.id)
   GROUP BY u.id HAVING count(DISTINCT s.tevo_venue_id) > 1;
  v_ms := v_ms || jsonb_build_object('sibling', (extract(epoch FROM clock_timestamp() - v_t) * 1000)::int); v_t := clock_timestamp();

  -- R3. equal names with the city kept, two or more words, one TEvo venue in the state (a neighbouring-town listing)
  INSERT INTO _vp_pick
  SELECT u.id, min(t.venue_id), 'pair_eq_state', min(t.nm) || ' (' || min(t.city) || ')'
    FROM _vp_u u JOIN _vp_tv t ON t.st = u.st AND t.norm_full = u.norm_full
   WHERE u.norm_full ~ ' ' AND NOT EXISTS (SELECT 1 FROM _vp_pick p WHERE p.id = u.id)
   GROUP BY u.id HAVING count(DISTINCT t.venue_id) = 1;
  v_ms := v_ms || jsonb_build_object('eq_state', (extract(epoch FROM clock_timestamp() - v_t) * 1000)::int); v_t := clock_timestamp();

  -- R4. a parking venue takes its base venue's pairing (same catalogue, same city; paired before or in this run)
  DROP TABLE IF EXISTS _vp_base;
  CREATE TEMP TABLE _vp_base (city text, st text, norm text, tevo_venue_id bigint, via text) ON COMMIT DROP;
  EXECUTE format($q$
    INSERT INTO _vp_base
    SELECT lower(trim(v.city)), upper(trim(v.state)), public.catalog_venue_norm(v.name, v.city, v.state, true), v.tevo_venue_id, 'venue ' || v.%2$I || ' (' || v.method || ')'
      FROM public.%1$I v
     WHERE v.tevo_venue_id IS NOT NULL AND coalesce(v.state, '') <> '' AND lower(v.name) !~ '\mparking\M'$q$, v_tbl, v_key);
  INSERT INTO _vp_base
  SELECT u.city, u.st, u.norm, p.tevo_venue_id, 'venue ' || u.id || ' (' || p.method || ', this run)'
    FROM _vp_pick p JOIN _vp_u u ON u.id = p.id WHERE NOT u.is_parking;
  CREATE INDEX ON _vp_base (st, city, norm);
  INSERT INTO _vp_pick
  SELECT u.id, min(b.tevo_venue_id), 'pair_parking', 'parking of ' || min(b.via)
    FROM _vp_u u JOIN _vp_base b ON b.st = u.st AND b.city = u.city AND b.norm = u.norm
   WHERE u.is_parking AND u.norm <> '' AND NOT EXISTS (SELECT 1 FROM _vp_pick p WHERE p.id = u.id)
   GROUP BY u.id HAVING count(DISTINCT b.tevo_venue_id) = 1;
  v_ms := v_ms || jsonb_build_object('parking', (extract(epoch FROM clock_timestamp() - v_t) * 1000)::int); v_t := clock_timestamp();

  -- the events the two corroborating rules compare: the venue's upcoming events (next 120 days, products left out) and
  -- the EVO events of the TEvo venues in the same cities, both with a cheap normalised name
  DROP TABLE IF EXISTS _vp_ue;
  CREATE TEMP TABLE _vp_ue (id bigint, day date, nn text) ON COMMIT DROP;
  EXECUTE format($q$
    INSERT INTO _vp_ue
    SELECT DISTINCT c.%2$I, c.event_date, lower(trim(regexp_replace(c.name, '[^A-Za-z0-9]+', ' ', 'g')))
      FROM public.%1$I c
      JOIN _vp_u u ON u.id = c.%2$I
     WHERE c.event_date BETWEEN current_date AND current_date + 120 AND %3$s
       AND NOT EXISTS (SELECT 1 FROM _vp_pick p WHERE p.id = u.id)
       AND c.name !~* '(parking|tailgate|shuttle|package|hospitality|\mvip\M|suites?\M)'$q$, v_evt, v_key, v_live);
  CREATE INDEX ON _vp_ue (id, day);
  ANALYZE _vp_ue;
  DROP TABLE IF EXISTS _vp_ev;
  CREATE TEMP TABLE _vp_ev ON COMMIT DROP AS
  SELECT t.venue_id, t.st, t.city, left(e.occurs_at_local, 10)::date AS day, lower(trim(regexp_replace(e.name, '[^A-Za-z0-9]+', ' ', 'g'))) AS nn
    FROM public.events e
    JOIN _vp_tv t ON t.venue_id = e.venue_id
   WHERE EXISTS (SELECT 1 FROM _vp_u u WHERE u.st = t.st AND u.city = t.city AND NOT EXISTS (SELECT 1 FROM _vp_pick p WHERE p.id = u.id))
     AND e.occurs_at_local >= to_char(now(), 'YYYY-MM-DD') AND e.occurs_at_local < to_char(now() + interval '121 days', 'YYYY-MM-DD')
     AND e.state IS DISTINCT FROM 'ignored'
     AND e.name !~* '(parking|tailgate|shuttle|package|hospitality|\mvip\M|suites?\M)';
  CREATE INDEX ON _vp_ev (st, city, day);
  CREATE INDEX ON _vp_ev (venue_id, day);
  ANALYZE _vp_ev;
  -- the days on which a venue's events fit a TEvo venue's events (same local day; names equal or one within the other)
  DROP TABLE IF EXISTS _vp_fit;
  CREATE TEMP TABLE _vp_fit ON COMMIT DROP AS
  SELECT ue.id, ev.venue_id, count(DISTINCT ue.day) AS days
    FROM _vp_ue ue
    JOIN _vp_u u ON u.id = ue.id
    JOIN _vp_ev ev ON ev.st = u.st AND ev.city = u.city AND ev.day = ue.day
   WHERE ue.nn <> '' AND ev.nn <> ''
     AND (ue.nn = ev.nn OR (length(ue.nn) >= 8 AND position(ue.nn IN ev.nn) > 0) OR (length(ev.nn) >= 8 AND position(ev.nn IN ue.nn) > 0))
   GROUP BY ue.id, ev.venue_id;
  CREATE INDEX ON _vp_fit (id, venue_id);
  v_ms := v_ms || jsonb_build_object('event_fits', (extract(epoch FROM clock_timestamp() - v_t) * 1000)::int); v_t := clock_timestamp();

  -- R5. one name is the other with words added at the front or the back; corroborated by the events
  DROP TABLE IF EXISTS _vp_afx;
  CREATE TEMP TABLE _vp_afx ON COMMIT DROP AS
  SELECT u.id, t.venue_id, t.nm, coalesce(f.days, 0) AS days
    FROM _vp_u u
    JOIN _vp_tv t ON t.st = u.st AND t.city = u.city AND t.norm <> u.norm
         AND ((length(u.norm) >= 8 AND u.norm ~ ' ' AND (t.norm LIKE u.norm || ' %' OR t.norm LIKE '% ' || u.norm))
           OR (length(t.norm) >= 8 AND t.norm ~ ' ' AND (u.norm LIKE t.norm || ' %' OR u.norm LIKE '% ' || t.norm)))
    LEFT JOIN _vp_fit f ON f.id = u.id AND f.venue_id = t.venue_id
   WHERE NOT EXISTS (SELECT 1 FROM _vp_pick p WHERE p.id = u.id);
  INSERT INTO _vp_pick
  SELECT a.id, min(a.venue_id), 'pair_affix', min(a.nm) || ' (' || min(a.days) || ' shared event day' || CASE WHEN min(a.days) = 1 THEN '' ELSE 's' END || ')'
    FROM _vp_afx a WHERE a.days >= 1
   GROUP BY a.id HAVING count(*) = 1;
  INSERT INTO _vp_amb
  SELECT a.id, 'affix', count(*) FROM _vp_afx a
   WHERE NOT EXISTS (SELECT 1 FROM _vp_pick p WHERE p.id = a.id)
   GROUP BY a.id;
  v_ms := v_ms || jsonb_build_object('affix', (extract(epoch FROM clock_timestamp() - v_t) * 1000)::int); v_t := clock_timestamp();

  -- R6. the events alone: the TEvo venue in the city the venue's events keep landing on
  INSERT INTO _vp_pick
  SELECT r.id, r.venue_id, 'pair_cooccur', t.nm || ' (' || r.days || ' shared event days, runner-up ' || r.second || ')'
    FROM (SELECT f.id, f.venue_id, f.days,
                 coalesce(lead(f.days) OVER (PARTITION BY f.id ORDER BY f.days DESC, f.venue_id), 0) AS second,
                 row_number() OVER (PARTITION BY f.id ORDER BY f.days DESC, f.venue_id) AS rn
            FROM _vp_fit f
           WHERE NOT EXISTS (SELECT 1 FROM _vp_pick p WHERE p.id = f.id)) r
    JOIN _vp_tv t ON t.venue_id = r.venue_id
   WHERE r.rn = 1 AND ((r.days >= 2 AND r.second = 0) OR (r.days >= 3 AND r.second * 3 <= r.days));
  v_ms := v_ms || jsonb_build_object('cooccur', (extract(epoch FROM clock_timestamp() - v_t) * 1000)::int); v_t := clock_timestamp();

  -- 3. apply: fill-only, audited
  IF p_apply THEN
    EXECUTE format($q$
      WITH upd AS (
        UPDATE public.%1$I v SET tevo_venue_id = p.tevo_venue_id, method = p.method, derived_at = now()
          FROM _vp_pick p WHERE v.%2$I = p.id AND v.tevo_venue_id IS NULL
        RETURNING v.%2$I AS id, p.tevo_venue_id, p.method, p.note)
      INSERT INTO public.%3$I (run_id, action, target, target_key, note)
      SELECT $1, 'venue_xref', %1$L, u.id::text, format('tevo_venue %%s via %%s: %%s', u.tevo_venue_id, u.method, u.note) FROM upd u$q$,
      v_tbl, v_key, v_aud) USING v_run;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    v_out := v_out || jsonb_build_object('written', v_n);
  END IF;

  v_out := v_out || jsonb_build_object(
    'paired', (SELECT count(*) FROM _vp_pick),
    'paired_events', (SELECT coalesce(sum(u.ev), 0) FROM _vp_pick p JOIN _vp_u u ON u.id = p.id),
    'by_method', (SELECT coalesce(jsonb_object_agg(m, n), '{}'::jsonb) FROM (SELECT p.method AS m, count(*) AS n FROM _vp_pick p GROUP BY 1) s),
    'events_by_method', (SELECT coalesce(jsonb_object_agg(m, n), '{}'::jsonb) FROM (SELECT p.method AS m, sum(u.ev) AS n FROM _vp_pick p JOIN _vp_u u ON u.id = p.id GROUP BY 1) s),
    'ambiguous', (SELECT coalesce(jsonb_object_agg(r, n), '{}'::jsonb) FROM (SELECT a.rule AS r, count(DISTINCT a.id) AS n FROM _vp_amb a WHERE NOT EXISTS (SELECT 1 FROM _vp_pick p WHERE p.id = a.id) GROUP BY 1) s),
    'still_unpaired', (SELECT count(*) FROM _vp_u u WHERE NOT EXISTS (SELECT 1 FROM _vp_pick p WHERE p.id = u.id)),
    'still_unpaired_events', (SELECT coalesce(sum(u.ev), 0) FROM _vp_u u WHERE NOT EXISTS (SELECT 1 FROM _vp_pick p WHERE p.id = u.id)),
    'sample', (SELECT coalesce(jsonb_agg(u.name || ' => ' || p.note || ' [' || p.method || ']'), '[]'::jsonb)
                 FROM (SELECT * FROM _vp_pick ORDER BY method, id LIMIT 24) p JOIN _vp_u u ON u.id = p.id),
    'ms', v_ms);
  RETURN jsonb_build_object('run_id', v_run, 'applied', p_apply) || v_out;
END $function$;
COMMENT ON FUNCTION public.catalog_venue_pair(text, boolean) IS
  'Pairs a catalogue''s (tickpick | vivid) unpaired venues with TEvo venues: equal normalised names in the city, the other catalogue''s or AXS''s pairing of the same name, equal names across the state, parking venues after their base venue, an affixed name corroborated by a shared event day, or the venue whose EVO events the catalogue''s events keep fitting. One candidate or nothing; fill-only; audited (venue_xref). Mig 20261117140000.';
REVOKE ALL ON FUNCTION public.catalog_venue_pair(text, boolean), public.catalog_venue_norm(text, text, text, boolean), public.catalog_venue_kept(text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.catalog_venue_pair(text, boolean), public.catalog_venue_norm(text, text, text, boolean), public.catalog_venue_kept(text) TO service_role;

-- ───────────────────────── 3. review view ─────────────────────────
CREATE OR REPLACE VIEW public.v_catalog_venue_pairs AS
SELECT 'tickpick' AS source, v.tp_venue_id AS venue_id, v.name, v.city, v.state, v.tevo_venue_id, t.venue_name AS tevo_name, t.venue_location AS tevo_location, v.method, v.events, v.derived_at
  FROM public.tickpick_catalog_venue v
  LEFT JOIN LATERAL (SELECT e.venue_name, e.venue_location FROM public.events e WHERE e.venue_id = v.tevo_venue_id ORDER BY e.occurs_at_local DESC LIMIT 1) t ON true
 WHERE v.tevo_venue_id IS NOT NULL
UNION ALL
SELECT 'vivid', v.vivid_venue_id, v.name, v.city, v.state, v.tevo_venue_id, t.venue_name, t.venue_location, v.method, v.events, v.derived_at
  FROM public.vivid_catalog_venue v
  LEFT JOIN LATERAL (SELECT e.venue_name, e.venue_location FROM public.events e WHERE e.venue_id = v.tevo_venue_id ORDER BY e.occurs_at_local DESC LIMIT 1) t ON true
 WHERE v.tevo_venue_id IS NOT NULL;
COMMENT ON VIEW public.v_catalog_venue_pairs IS 'Every catalogue venue pairing with both names, for review (filter by method, e.g. method LIKE ''pair_%''). Mig 20261117140000.';
REVOKE ALL ON public.v_catalog_venue_pairs FROM anon, authenticated;
GRANT SELECT ON public.v_catalog_venue_pairs TO service_role;

-- ───────────────────────── 4. the mappers keep the pairer's venues ─────────────────────────
CREATE OR REPLACE FUNCTION public.tickpick_catalog_map(p_apply boolean DEFAULT true)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
 SET client_min_messages TO 'warning'
AS $function$
DECLARE
  v_run uuid := gen_random_uuid();
  v_out jsonb := '{}'::jsonb;
  v_n   int;
BEGIN
  -- 0. candidates: upcoming, dated, at venues in the US, Canada or Mexico (mig 20261117080000)
  DROP TABLE IF EXISTS _tc_cand;
  CREATE TEMP TABLE _tc_cand ON COMMIT DROP AS
  SELECT c.tp_event_id, c.name, c.performers, c.tp_venue_id, c.event_date, c.event_utc, c.time_confirmed,
         c.tevo_event_id AS cur_tevo, c.tevo_match_method AS cur_method
    FROM public.tickpick_catalog_event c
   WHERE c.status IS DISTINCT FROM 'canceled' AND c.merged_into IS NULL AND c.date_confirmed
     AND c.event_date BETWEEN current_date - 1 AND current_date + 400
     AND coalesce(c.venue_country, 'US') IN ('US', 'CA', 'MX');
  CREATE INDEX ON _tc_cand (tp_event_id);
  v_out := v_out || jsonb_build_object('candidates', (SELECT count(*) FROM _tc_cand));

  -- 1. verify the matched: still that event, on that day?
  DROP TABLE IF EXISTS _tc_drop;
  CREATE TEMP TABLE _tc_drop ON COMMIT DROP AS
  SELECT x.tp_event_id, x.cur_tevo, x.cur_method,
         CASE WHEN e.id IS NULL THEN 'event_gone'
              WHEN e.state = 'ignored' THEN 'event_ignored'
              ELSE 'day_moved' END AS why
    FROM _tc_cand x
    LEFT JOIN public.events e ON e.id = x.cur_tevo
   WHERE x.cur_tevo IS NOT NULL
     AND (e.id IS NULL OR e.state = 'ignored' OR left(e.occurs_at_local, 10) IS DISTINCT FROM to_char(x.event_date, 'YYYY-MM-DD'));
  v_out := v_out || jsonb_build_object('dropped', (SELECT count(*) FROM _tc_drop));
  IF p_apply THEN
    INSERT INTO public.tickpick_catalog_audit (run_id, tp_event_id, action, target, target_key, old_tevo, note)
    SELECT v_run, d.tp_event_id, 'drop', 'tickpick_catalog_event', d.tp_event_id::text, d.cur_tevo, d.why || ' (' || coalesce(d.cur_method, '?') || ')' FROM _tc_drop d;
    UPDATE public.tickpick_catalog_event c SET tevo_event_id = NULL, tevo_match_method = NULL, tevo_matched_at = NULL
      FROM _tc_drop d WHERE d.tp_event_id = c.tp_event_id;
  END IF;
  UPDATE _tc_cand x SET cur_tevo = NULL, cur_method = NULL FROM _tc_drop d WHERE d.tp_event_id = x.tp_event_id;

  DROP TABLE IF EXISTS _tc_pick;
  CREATE TEMP TABLE _tc_pick (tp_event_id bigint PRIMARY KEY, tevo_event_id bigint NOT NULL, method text NOT NULL) ON COMMIT DROP;

  -- 2. identity: the hub's tp_event_id; our own orders already mapped — same local day AND the name still fits
  INSERT INTO _tc_pick (tp_event_id, tevo_event_id, method)
  SELECT DISTINCT ON (x.tp_event_id) x.tp_event_id, a.tevo_event_id, 'hub_identity'
    FROM _tc_cand x
    JOIN public.aq_event_map a ON a.tp_event_id = x.tp_event_id AND a.tevo_event_id IS NOT NULL
    JOIN public.events e ON e.id = a.tevo_event_id AND e.state IS DISTINCT FROM 'ignored'
   WHERE x.cur_tevo IS NULL AND left(e.occurs_at_local, 10) = to_char(x.event_date, 'YYYY-MM-DD')
     AND public.tickpick_catalog_name_fits(x.name, x.performers, e.name, e.primary_performer_name)
   ORDER BY x.tp_event_id, (a.aq_source = 'aq_curated') DESC, a.imported_at DESC NULLS LAST
  ON CONFLICT DO NOTHING;
  INSERT INTO _tc_pick (tp_event_id, tevo_event_id, method)
  SELECT x.tp_event_id, o.tevo, 'order_identity'
    FROM _tc_cand x
    JOIN (SELECT (o.raw->'event'->>'event_id')::bigint AS tp, o.tevo_event_id AS tevo, count(*) AS n
            FROM public.tickpick_orders o
           WHERE o.tevo_event_id IS NOT NULL AND (o.raw->'event'->>'event_id') ~ '^\d+$'
           GROUP BY 1, 2) o ON o.tp = x.tp_event_id
    JOIN public.events e ON e.id = o.tevo AND e.state IS DISTINCT FROM 'ignored'
   WHERE x.cur_tevo IS NULL AND left(e.occurs_at_local, 10) = to_char(x.event_date, 'YYYY-MM-DD')
     AND public.tickpick_catalog_name_fits(x.name, x.performers, e.name, e.primary_performer_name)
     AND NOT EXISTS (SELECT 1 FROM public.tickpick_orders o2
                      WHERE (o2.raw->'event'->>'event_id') ~ '^\d+$' AND (o2.raw->'event'->>'event_id')::bigint = x.tp_event_id
                        AND o2.tevo_event_id IS NOT NULL AND o2.tevo_event_id <> o.tevo)
  ON CONFLICT DO NOTHING;
  v_out := v_out || jsonb_build_object('identity', (SELECT count(*) FROM _tc_pick));

  -- 3. venues: manual -> aq_venue_map -> cross_source (unanimous) -> name + state (mig 20261117080000) -> venue judge (mig 20261117120000) / pairer (mig 20261117140000) -> learned
  DROP TABLE IF EXISTS _cat_tv;
  CREATE TEMP TABLE _cat_tv ON COMMIT DROP AS SELECT * FROM public.catalog_tevo_venues_by_name();
  CREATE INDEX ON _cat_tv (nm, st);
  DROP TABLE IF EXISTS _tc_venue;
  CREATE TEMP TABLE _tc_venue ON COMMIT DROP AS
  WITH known AS (
    SELECT v.tp_venue_id, v.tevo_venue_id, 'manual' AS method, 1 AS pri
      FROM public.tickpick_catalog_venue v WHERE v.method = 'manual' AND v.tevo_venue_id IS NOT NULL
    UNION ALL
    SELECT m.tickpick_venue_id, m.tevo_venue_id, 'aq_venue_map', 2
      FROM public.aq_venue_map m WHERE m.tickpick_venue_id IS NOT NULL AND m.tevo_venue_id IS NOT NULL
    UNION ALL
    SELECT c.tickpick_venue_id, min(c.tevo_venue_id), 'cross_source', 3
      FROM public.cross_source_venue_map c
     WHERE c.tickpick_venue_id IS NOT NULL AND c.tevo_venue_id IS NOT NULL
     GROUP BY c.tickpick_venue_id HAVING count(DISTINCT c.tevo_venue_id) = 1
    UNION ALL
    SELECT v.tp_venue_id, t.tevo_venue_id, 'name_state', 4
      FROM public.tickpick_catalog_venue v
      JOIN _cat_tv t ON t.nm = lower(trim(v.name)) AND t.st = upper(trim(v.state))
     WHERE coalesce(v.country, 'US') IN ('US', 'CA', 'MX') AND coalesce(v.state, '') <> ''
    UNION ALL
    SELECT v.tp_venue_id, v.tevo_venue_id, v.method, 5             -- the venue judge's (mig 20261117120000) and the pairer's (mig 20261117140000) pairings, kept as set
      FROM public.tickpick_catalog_venue v WHERE v.method <> 'manual' AND public.catalog_venue_kept(v.method) AND v.tevo_venue_id IS NOT NULL
    UNION ALL
    SELECT s.tp_venue_id, s.tv, 'matched_events', 6
      FROM (SELECT x.tp_venue_id, e.venue_id AS tv, count(*) AS n,
                   row_number() OVER (PARTITION BY x.tp_venue_id ORDER BY count(*) DESC, e.venue_id) AS rn
              FROM _tc_cand x
              LEFT JOIN _tc_pick p ON p.tp_event_id = x.tp_event_id
              JOIN public.events e ON e.id = coalesce(p.tevo_event_id, x.cur_tevo)
             WHERE x.tp_venue_id IS NOT NULL AND e.venue_id IS NOT NULL
             GROUP BY x.tp_venue_id, e.venue_id) s
     WHERE s.rn = 1
  )
  SELECT DISTINCT ON (k.tp_venue_id) k.tp_venue_id, k.tevo_venue_id, k.method
    FROM known k ORDER BY k.tp_venue_id, k.pri;
  CREATE INDEX ON _tc_venue (tp_venue_id);
  v_out := v_out || jsonb_build_object('venues_resolved', (SELECT count(*) FROM _tc_venue),
                                       'venues_by_method', (SELECT coalesce(jsonb_object_agg(method, n), '{}'::jsonb) FROM (SELECT method, count(*) n FROM _tc_venue GROUP BY 1) s));

  -- 4a. the EVO events the fits can see, once: upcoming, not ignored, indexed by venue and local day
  --     (mig 20261117090000: joining public.events by venue + left(occurs_at_local, 10) made the planner walk every
  --      event of the day and filter the venue afterwards — 377k rows thrown away for 757 pairs on a 60-day window)
  DROP TABLE IF EXISTS _cat_ev;
  CREATE TEMP TABLE _cat_ev ON COMMIT DROP AS
  SELECT e.id, e.venue_id, left(e.occurs_at_local, 10) AS day, e.name, e.primary_performer_name, e.occurs_at_local
    FROM public.events e
   WHERE e.occurs_at_local >= to_char(now() - interval '2 days', 'YYYY-MM-DD')
     AND e.state IS DISTINCT FROM 'ignored' AND e.venue_id IS NOT NULL;
  CREATE INDEX ON _cat_ev (venue_id, day);
  ANALYZE _cat_ev;

  -- 4. venue + local day (+ name, + time)
  DROP TABLE IF EXISTS _tc_fit;
  CREATE TEMP TABLE _tc_fit ON COMMIT DROP AS
  SELECT x.tp_event_id, e.id AS tevo_event_id, x.time_confirmed,
         (x.time_confirmed AND x.event_utc IS NOT NULL
          AND abs(extract(epoch FROM public.tevo_event_utc(e.occurs_at_local, e.venue_id) - x.event_utc)) <= 60) AS same_minute
    FROM _tc_cand x
    JOIN _tc_venue v ON v.tp_venue_id = x.tp_venue_id
    JOIN _cat_ev e ON e.venue_id = v.tevo_venue_id AND e.day = to_char(x.event_date, 'YYYY-MM-DD')
   WHERE x.cur_tevo IS NULL
     AND NOT EXISTS (SELECT 1 FROM _tc_pick p WHERE p.tp_event_id = x.tp_event_id)
     AND public.tickpick_catalog_name_fits(x.name, x.performers, e.name, e.primary_performer_name);
  DROP TABLE IF EXISTS _tc_claimed;
  CREATE TEMP TABLE _tc_claimed ON COMMIT DROP AS
  SELECT x.cur_tevo AS tevo_event_id FROM _tc_cand x WHERE x.cur_tevo IS NOT NULL
  UNION
  SELECT p.tevo_event_id FROM _tc_pick p
  UNION
  SELECT c.tevo_event_id FROM public.tickpick_catalog_event c
   WHERE c.tevo_event_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM _tc_drop d WHERE d.tp_event_id = c.tp_event_id);
  WITH per AS (
    SELECT f.tp_event_id,
           count(*) AS n_fit,
           min(f.tevo_event_id) AS one_fit,
           count(*) FILTER (WHERE f.same_minute) AS n_minute,
           min(f.tevo_event_id) FILTER (WHERE f.same_minute) AS one_minute
      FROM _tc_fit f
     WHERE NOT EXISTS (SELECT 1 FROM _tc_claimed c WHERE c.tevo_event_id = f.tevo_event_id)
     GROUP BY f.tp_event_id
  ),
  pick AS (
    SELECT p.tp_event_id,
           CASE WHEN p.n_fit = 1 THEN p.one_fit WHEN p.n_minute = 1 THEN p.one_minute END AS tevo_event_id,
           CASE WHEN p.n_fit = 1 THEN 'venue_day_name' WHEN p.n_minute = 1 THEN 'venue_time_name' END AS method
      FROM per p
  ),
  uniq AS (
    SELECT p.* FROM pick p
     WHERE p.tevo_event_id IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM pick q WHERE q.tevo_event_id = p.tevo_event_id AND q.tp_event_id <> p.tp_event_id)
  )
  INSERT INTO _tc_pick (tp_event_id, tevo_event_id, method)
  SELECT u.tp_event_id, u.tevo_event_id, u.method FROM uniq u
  ON CONFLICT DO NOTHING;
  v_out := v_out || jsonb_build_object(
    'picked', (SELECT count(*) FROM _tc_pick),
    'by_method', (SELECT coalesce(jsonb_object_agg(m, n), '{}'::jsonb) FROM (SELECT method m, count(*) n FROM _tc_pick GROUP BY 1) s),
    'ambiguous', (SELECT count(DISTINCT f.tp_event_id) FROM _tc_fit f WHERE NOT EXISTS (SELECT 1 FROM _tc_pick p WHERE p.tp_event_id = f.tp_event_id)),
    'unmatched', (SELECT count(*) FROM _tc_cand x WHERE x.cur_tevo IS NULL AND NOT EXISTS (SELECT 1 FROM _tc_pick p WHERE p.tp_event_id = x.tp_event_id)),
    'no_venue', (SELECT count(*) FROM _tc_cand x WHERE x.cur_tevo IS NULL AND NOT EXISTS (SELECT 1 FROM _tc_venue v WHERE v.tp_venue_id = x.tp_venue_id)));

  IF p_apply THEN
    UPDATE public.tickpick_catalog_event c
       SET tevo_event_id = p.tevo_event_id, tevo_match_method = p.method, tevo_matched_at = now()
      FROM _tc_pick p WHERE p.tp_event_id = c.tp_event_id;
    INSERT INTO public.tickpick_catalog_audit (run_id, tp_event_id, action, target, target_key, new_tevo, note)
    SELECT v_run, p.tp_event_id, 'match', 'tickpick_catalog_event', p.tp_event_id::text, p.tevo_event_id, p.method FROM _tc_pick p;

    WITH cnt AS (
      SELECT c.tp_venue_id, count(*) AS n
        FROM public.tickpick_catalog_event c JOIN public.events e ON e.id = c.tevo_event_id
        JOIN _tc_venue v ON v.tp_venue_id = c.tp_venue_id AND v.tevo_venue_id = e.venue_id
       GROUP BY c.tp_venue_id
    ),
    u AS (
      INSERT INTO public.tickpick_catalog_venue AS v (tp_venue_id, tevo_venue_id, method, events, derived_at)
      SELECT t.tp_venue_id, t.tevo_venue_id, t.method, coalesce(cnt.n, 0), now()
        FROM _tc_venue t LEFT JOIN cnt ON cnt.tp_venue_id = t.tp_venue_id
      ON CONFLICT (tp_venue_id) DO UPDATE
        SET tevo_venue_id = EXCLUDED.tevo_venue_id, method = EXCLUDED.method, events = EXCLUDED.events, derived_at = now()
        WHERE NOT public.catalog_venue_kept(v.method)
          AND (v.tevo_venue_id IS DISTINCT FROM EXCLUDED.tevo_venue_id OR v.method IS DISTINCT FROM EXCLUDED.method
               OR v.events IS DISTINCT FROM EXCLUDED.events)
      RETURNING v.tp_venue_id, v.tevo_venue_id, v.method, v.events)
    INSERT INTO public.tickpick_catalog_audit (run_id, action, target, target_key, note)
    SELECT v_run, 'venue_xref', 'tickpick_catalog_venue', u.tp_venue_id::text, format('tevo_venue %s via %s (%s events)', u.tevo_venue_id, u.method, u.events) FROM u;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    v_out := v_out || jsonb_build_object('venues_written', v_n);

    -- 5. hub: the TickPick id on the hub rows of matched EVO events (fill-only; one TickPick id per EVO event)
    WITH tp AS (
      SELECT c.tevo_event_id, min(c.tp_event_id) AS tp_event_id
        FROM public.tickpick_catalog_event c
       WHERE c.tevo_event_id IS NOT NULL AND c.event_date >= current_date - 1
       GROUP BY c.tevo_event_id HAVING count(*) = 1
    ),
    tgt AS (   -- mig 20261117110000: a hub row another transaction holds is skipped, not waited for
      SELECT a.aq_short_event_id, tp.tp_event_id, tp.tevo_event_id
        FROM public.aq_event_map a JOIN tp ON tp.tevo_event_id = a.tevo_event_id
       WHERE a.tp_event_id IS NULL
         AND NOT EXISTS (SELECT 1 FROM public.aq_event_map o WHERE o.tp_event_id = tp.tp_event_id AND o.tevo_event_id IS DISTINCT FROM tp.tevo_event_id)
       FOR UPDATE OF a SKIP LOCKED
    ),
    u AS (
      UPDATE public.aq_event_map a SET tp_event_id = t.tp_event_id
        FROM tgt t
       WHERE a.aq_short_event_id = t.aq_short_event_id
       RETURNING a.aq_short_event_id, a.tevo_event_id, t.tp_event_id)
    INSERT INTO public.tickpick_catalog_audit (run_id, tp_event_id, action, target, target_key, new_tevo)
    SELECT v_run, u.tp_event_id, 'hub_tp', 'aq_event_map', u.aq_short_event_id, u.tevo_event_id FROM u;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    v_out := v_out || jsonb_build_object('hub_tp_filled', v_n);

    -- 6. orders: by id, fill-only; disagreements audited, never re-pointed
    WITH u AS (
      UPDATE public.tickpick_orders o
         SET tevo_event_id = c.tevo_event_id, matched_via = 'tp_catalog_id', match_confidence = 1.0, matched_at = now()
        FROM public.tickpick_catalog_event c
       WHERE o.tevo_event_id IS NULL AND o.event_date >= now() - interval '1 day' AND (o.raw->'event'->>'event_id') ~ '^\d+$'
         AND c.tp_event_id = (o.raw->'event'->>'event_id')::bigint AND c.tevo_event_id IS NOT NULL
       RETURNING o.tp_order_id, c.tp_event_id, c.tevo_event_id)
    INSERT INTO public.tickpick_catalog_audit (run_id, tp_event_id, action, target, target_key, new_tevo)
    SELECT v_run, u.tp_event_id, 'order_tevo', 'tickpick_orders', u.tp_order_id, u.tevo_event_id FROM u;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    v_out := v_out || jsonb_build_object('orders_filled', v_n);
    INSERT INTO public.tickpick_catalog_audit (run_id, tp_event_id, action, target, target_key, old_tevo, new_tevo, note)
    SELECT v_run, c.tp_event_id, 'order_disagree', 'tickpick_orders', o.tp_order_id, o.tevo_event_id, c.tevo_event_id, coalesce(o.matched_via, '?')
      FROM public.tickpick_orders o
      JOIN public.tickpick_catalog_event c ON (o.raw->'event'->>'event_id') ~ '^\d+$' AND c.tp_event_id = (o.raw->'event'->>'event_id')::bigint
     WHERE o.tevo_event_id IS NOT NULL AND c.tevo_event_id IS NOT NULL AND o.tevo_event_id <> c.tevo_event_id
       AND o.event_date >= now() - interval '1 day'
       AND NOT EXISTS (SELECT 1 FROM public.tickpick_catalog_audit a
                        WHERE a.action = 'order_disagree' AND a.target_key = o.tp_order_id AND a.new_tevo = c.tevo_event_id);
    GET DIAGNOSTICS v_n = ROW_COUNT;
    v_out := v_out || jsonb_build_object('orders_disagree_new', v_n);

    -- 7. the venue xref: aq_venue_map.tickpick_venue_id (UNIQUE), fill-only, once two matched events corroborate the pairing
    WITH tgt AS (   -- mig 20261117110000: skip locked rows here too
      SELECT m.venue_short_id, m.tevo_venue_id, v.tp_venue_id
        FROM public.aq_venue_map m JOIN public.tickpick_catalog_venue v ON v.tevo_venue_id = m.tevo_venue_id
       WHERE m.tickpick_venue_id IS NULL AND v.tevo_venue_id IS NOT NULL
         AND (v.method = 'manual' OR coalesce(v.events, 0) >= 2)
         AND NOT EXISTS (SELECT 1 FROM public.aq_venue_map o WHERE o.tickpick_venue_id = v.tp_venue_id)
         AND NOT EXISTS (SELECT 1 FROM public.tickpick_catalog_venue w WHERE w.tevo_venue_id = v.tevo_venue_id AND w.tp_venue_id <> v.tp_venue_id)
       FOR UPDATE OF m SKIP LOCKED
    ),
    u AS (
      UPDATE public.aq_venue_map m SET tickpick_venue_id = t.tp_venue_id
        FROM tgt t WHERE m.venue_short_id = t.venue_short_id
       RETURNING m.venue_short_id, m.tevo_venue_id, t.tp_venue_id)
    INSERT INTO public.tickpick_catalog_audit (run_id, action, target, target_key, note)
    SELECT v_run, 'venue_map', 'aq_venue_map', u.venue_short_id, 'tickpick_venue ' || u.tp_venue_id || ' on tevo_venue ' || u.tevo_venue_id FROM u;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    v_out := v_out || jsonb_build_object('venue_map_filled', v_n);
  END IF;

  RETURN jsonb_build_object('run_id', v_run, 'applied', p_apply) || v_out;
END $function$;

CREATE OR REPLACE FUNCTION public.vivid_catalog_map(p_apply boolean DEFAULT true)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
 SET client_min_messages TO 'warning'
AS $function$
DECLARE
  v_run uuid := gen_random_uuid();
  v_out jsonb := '{}'::jsonb;
  v_n   int;
BEGIN
  -- one writer of vivid_catalog_event at a time: the minute tick (vivid_catalog_tick) skips its minute while this runs
  PERFORM pg_advisory_xact_lock(hashtext('vivid_catalog'));

  -- 0. candidates: upcoming, local day known, at venues in the US, Canada or Mexico (mig 20261117080000)
  DROP TABLE IF EXISTS _vc_cand;
  CREATE TEMP TABLE _vc_cand ON COMMIT DROP AS
  SELECT c.vivid_event_id, c.name, c.performers, c.vivid_venue_id, c.event_date, c.time_known,
         CASE WHEN c.time_known AND c.timezone IS NOT NULL AND c.timezone IN (SELECT name FROM pg_timezone_names)
              THEN c.event_local AT TIME ZONE c.timezone END AS event_utc,
         c.tevo_event_id AS cur_tevo, c.tevo_match_method AS cur_method
    FROM public.vivid_catalog_event c
   WHERE c.event_date BETWEEN current_date - 1 AND current_date + 400
     AND coalesce(c.venue_country, 'US') IN ('US', 'CA', 'MX');
  CREATE INDEX ON _vc_cand (vivid_event_id);
  v_out := v_out || jsonb_build_object('candidates', (SELECT count(*) FROM _vc_cand));

  -- 1. verify the matched
  DROP TABLE IF EXISTS _vc_drop;
  CREATE TEMP TABLE _vc_drop ON COMMIT DROP AS
  SELECT x.vivid_event_id, x.cur_tevo, x.cur_method,
         CASE WHEN e.id IS NULL THEN 'event_gone' WHEN e.state = 'ignored' THEN 'event_ignored' ELSE 'day_moved' END AS why
    FROM _vc_cand x LEFT JOIN public.events e ON e.id = x.cur_tevo
   WHERE x.cur_tevo IS NOT NULL
     AND (e.id IS NULL OR e.state = 'ignored' OR left(e.occurs_at_local, 10) IS DISTINCT FROM to_char(x.event_date, 'YYYY-MM-DD'));
  v_out := v_out || jsonb_build_object('dropped', (SELECT count(*) FROM _vc_drop));
  IF p_apply THEN
    INSERT INTO public.vivid_catalog_audit (run_id, vivid_event_id, action, target, target_key, old_tevo, note)
    SELECT v_run, d.vivid_event_id, 'drop', 'vivid_catalog_event', d.vivid_event_id::text, d.cur_tevo, d.why || ' (' || coalesce(d.cur_method, '?') || ')' FROM _vc_drop d;
    UPDATE public.vivid_catalog_event c SET tevo_event_id = NULL, tevo_match_method = NULL, tevo_matched_at = NULL
      FROM _vc_drop d WHERE d.vivid_event_id = c.vivid_event_id;
  END IF;
  UPDATE _vc_cand x SET cur_tevo = NULL, cur_method = NULL FROM _vc_drop d WHERE d.vivid_event_id = x.vivid_event_id;

  DROP TABLE IF EXISTS _vc_pick;
  CREATE TEMP TABLE _vc_pick (vivid_event_id bigint PRIMARY KEY, tevo_event_id bigint NOT NULL, method text NOT NULL) ON COMMIT DROP;

  -- 2. identity: the hub's vivid_event_id; our Vivid orders already mapped — same local day AND the name still fits
  INSERT INTO _vc_pick (vivid_event_id, tevo_event_id, method)
  SELECT DISTINCT ON (x.vivid_event_id) x.vivid_event_id, a.tevo_event_id, 'hub_identity'
    FROM _vc_cand x
    JOIN public.aq_event_map a ON a.vivid_event_id = x.vivid_event_id AND a.tevo_event_id IS NOT NULL
    JOIN public.events e ON e.id = a.tevo_event_id AND e.state IS DISTINCT FROM 'ignored'
   WHERE x.cur_tevo IS NULL AND left(e.occurs_at_local, 10) = to_char(x.event_date, 'YYYY-MM-DD')
     AND public.tickpick_catalog_name_fits(x.name, x.performers, e.name, e.primary_performer_name)
   ORDER BY x.vivid_event_id, (a.aq_source = 'aq_curated') DESC, a.imported_at DESC NULLS LAST
  ON CONFLICT DO NOTHING;
  INSERT INTO _vc_pick (vivid_event_id, tevo_event_id, method)
  SELECT x.vivid_event_id, o.tevo, 'order_identity'
    FROM _vc_cand x
    JOIN (SELECT (o.raw->>'productionId')::bigint AS pid, o.tevo_event_id AS tevo
            FROM public.vivid_orders o
           WHERE o.tevo_event_id IS NOT NULL AND (o.raw->>'productionId') ~ '^\d+$'
           GROUP BY 1, 2) o ON o.pid = x.vivid_event_id
    JOIN public.events e ON e.id = o.tevo AND e.state IS DISTINCT FROM 'ignored'
   WHERE x.cur_tevo IS NULL AND left(e.occurs_at_local, 10) = to_char(x.event_date, 'YYYY-MM-DD')
     AND public.tickpick_catalog_name_fits(x.name, x.performers, e.name, e.primary_performer_name)
     AND NOT EXISTS (SELECT 1 FROM public.vivid_orders o2
                      WHERE (o2.raw->>'productionId') ~ '^\d+$' AND (o2.raw->>'productionId')::bigint = x.vivid_event_id
                        AND o2.tevo_event_id IS NOT NULL AND o2.tevo_event_id <> o.tevo)
  ON CONFLICT DO NOTHING;
  v_out := v_out || jsonb_build_object('identity', (SELECT count(*) FROM _vc_pick));

  -- 3. venues: manual -> name + state (mig 20261117080000) -> venue judge (mig 20261117120000) / pairer (mig 20261117140000) -> learned from matches
  DROP TABLE IF EXISTS _cat_tv;
  CREATE TEMP TABLE _cat_tv ON COMMIT DROP AS SELECT * FROM public.catalog_tevo_venues_by_name();
  CREATE INDEX ON _cat_tv (nm, st);
  DROP TABLE IF EXISTS _vc_venue;
  CREATE TEMP TABLE _vc_venue ON COMMIT DROP AS
  WITH known AS (
    SELECT v.vivid_venue_id, v.tevo_venue_id, 'manual' AS method, 1 AS pri
      FROM public.vivid_catalog_venue v WHERE v.method = 'manual' AND v.tevo_venue_id IS NOT NULL
    UNION ALL
    SELECT v.vivid_venue_id, t.tevo_venue_id, 'name_state', 2
      FROM public.vivid_catalog_venue v
      JOIN _cat_tv t ON t.nm = lower(trim(v.name)) AND t.st = upper(trim(v.state))
     WHERE coalesce(v.country, 'US') IN ('US', 'CA', 'MX') AND coalesce(v.state, '') <> ''
    UNION ALL
    SELECT v.vivid_venue_id, v.tevo_venue_id, v.method, 3          -- the venue judge's (mig 20261117120000) and the pairer's (mig 20261117140000) pairings, kept as set
      FROM public.vivid_catalog_venue v WHERE v.method <> 'manual' AND public.catalog_venue_kept(v.method) AND v.tevo_venue_id IS NOT NULL
    UNION ALL
    SELECT s.vivid_venue_id, s.tv, 'matched_events', 4
      FROM (SELECT x.vivid_venue_id, e.venue_id AS tv, count(*) AS n,
                   row_number() OVER (PARTITION BY x.vivid_venue_id ORDER BY count(*) DESC, e.venue_id) AS rn
              FROM _vc_cand x
              LEFT JOIN _vc_pick p ON p.vivid_event_id = x.vivid_event_id
              JOIN public.events e ON e.id = coalesce(p.tevo_event_id, x.cur_tevo)
             WHERE x.vivid_venue_id IS NOT NULL AND e.venue_id IS NOT NULL
             GROUP BY x.vivid_venue_id, e.venue_id) s
     WHERE s.rn = 1
  )
  SELECT DISTINCT ON (k.vivid_venue_id) k.vivid_venue_id, k.tevo_venue_id, k.method FROM known k ORDER BY k.vivid_venue_id, k.pri;
  CREATE INDEX ON _vc_venue (vivid_venue_id);
  v_out := v_out || jsonb_build_object('venues_resolved', (SELECT count(*) FROM _vc_venue),
                                       'venues_by_method', (SELECT coalesce(jsonb_object_agg(method, n), '{}'::jsonb) FROM (SELECT method, count(*) n FROM _vc_venue GROUP BY 1) s));

  -- 4a. the EVO events the fits can see, once: upcoming, not ignored, indexed by venue and local day
  --     (mig 20261117090000: joining public.events by venue + left(occurs_at_local, 10) made the planner walk every
  --      event of the day and filter the venue afterwards — 377k rows thrown away for 757 pairs on a 60-day window)
  DROP TABLE IF EXISTS _cat_ev;
  CREATE TEMP TABLE _cat_ev ON COMMIT DROP AS
  SELECT e.id, e.venue_id, left(e.occurs_at_local, 10) AS day, e.name, e.primary_performer_name, e.occurs_at_local
    FROM public.events e
   WHERE e.occurs_at_local >= to_char(now() - interval '2 days', 'YYYY-MM-DD')
     AND e.state IS DISTINCT FROM 'ignored' AND e.venue_id IS NOT NULL;
  CREATE INDEX ON _cat_ev (venue_id, day);
  ANALYZE _cat_ev;

  -- 4. venue + local day (+ name, + minute)
  DROP TABLE IF EXISTS _vc_fit;
  CREATE TEMP TABLE _vc_fit ON COMMIT DROP AS
  SELECT x.vivid_event_id, e.id AS tevo_event_id,
         (x.event_utc IS NOT NULL AND abs(extract(epoch FROM public.tevo_event_utc(e.occurs_at_local, e.venue_id) - x.event_utc)) <= 60) AS same_minute
    FROM _vc_cand x
    JOIN _vc_venue v ON v.vivid_venue_id = x.vivid_venue_id
    JOIN _cat_ev e ON e.venue_id = v.tevo_venue_id AND e.day = to_char(x.event_date, 'YYYY-MM-DD')
   WHERE x.cur_tevo IS NULL
     AND NOT EXISTS (SELECT 1 FROM _vc_pick p WHERE p.vivid_event_id = x.vivid_event_id)
     AND public.tickpick_catalog_name_fits(x.name, x.performers, e.name, e.primary_performer_name);
  DROP TABLE IF EXISTS _vc_claimed;
  CREATE TEMP TABLE _vc_claimed ON COMMIT DROP AS
  SELECT x.cur_tevo AS tevo_event_id FROM _vc_cand x WHERE x.cur_tevo IS NOT NULL
  UNION SELECT p.tevo_event_id FROM _vc_pick p
  UNION SELECT c.tevo_event_id FROM public.vivid_catalog_event c
         WHERE c.tevo_event_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM _vc_drop d WHERE d.vivid_event_id = c.vivid_event_id);
  WITH per AS (
    SELECT f.vivid_event_id, count(*) AS n_fit, min(f.tevo_event_id) AS one_fit,
           count(*) FILTER (WHERE f.same_minute) AS n_minute, min(f.tevo_event_id) FILTER (WHERE f.same_minute) AS one_minute
      FROM _vc_fit f
     WHERE NOT EXISTS (SELECT 1 FROM _vc_claimed c WHERE c.tevo_event_id = f.tevo_event_id)
     GROUP BY f.vivid_event_id),
  pick AS (
    SELECT p.vivid_event_id,
           CASE WHEN p.n_fit = 1 THEN p.one_fit WHEN p.n_minute = 1 THEN p.one_minute END AS tevo_event_id,
           CASE WHEN p.n_fit = 1 THEN 'venue_day_name' WHEN p.n_minute = 1 THEN 'venue_time_name' END AS method
      FROM per p),
  uniq AS (
    SELECT p.* FROM pick p
     WHERE p.tevo_event_id IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM pick q WHERE q.tevo_event_id = p.tevo_event_id AND q.vivid_event_id <> p.vivid_event_id))
  INSERT INTO _vc_pick (vivid_event_id, tevo_event_id, method)
  SELECT u.vivid_event_id, u.tevo_event_id, u.method FROM uniq u
  ON CONFLICT DO NOTHING;
  v_out := v_out || jsonb_build_object(
    'picked', (SELECT count(*) FROM _vc_pick),
    'by_method', (SELECT coalesce(jsonb_object_agg(m, n), '{}'::jsonb) FROM (SELECT method m, count(*) n FROM _vc_pick GROUP BY 1) s),
    'ambiguous', (SELECT count(DISTINCT f.vivid_event_id) FROM _vc_fit f WHERE NOT EXISTS (SELECT 1 FROM _vc_pick p WHERE p.vivid_event_id = f.vivid_event_id)),
    'unmatched', (SELECT count(*) FROM _vc_cand x WHERE x.cur_tevo IS NULL AND NOT EXISTS (SELECT 1 FROM _vc_pick p WHERE p.vivid_event_id = x.vivid_event_id)),
    'no_venue', (SELECT count(*) FROM _vc_cand x WHERE x.cur_tevo IS NULL AND NOT EXISTS (SELECT 1 FROM _vc_venue v WHERE v.vivid_venue_id = x.vivid_venue_id)));

  IF p_apply THEN
    UPDATE public.vivid_catalog_event c
       SET tevo_event_id = p.tevo_event_id, tevo_match_method = p.method, tevo_matched_at = now()
      FROM _vc_pick p WHERE p.vivid_event_id = c.vivid_event_id;
    INSERT INTO public.vivid_catalog_audit (run_id, vivid_event_id, action, target, target_key, new_tevo, note)
    SELECT v_run, p.vivid_event_id, 'match', 'vivid_catalog_event', p.vivid_event_id::text, p.tevo_event_id, p.method FROM _vc_pick p;

    WITH cnt AS (
      SELECT c.vivid_venue_id, count(*) AS n
        FROM public.vivid_catalog_event c JOIN public.events e ON e.id = c.tevo_event_id
        JOIN _vc_venue v ON v.vivid_venue_id = c.vivid_venue_id AND v.tevo_venue_id = e.venue_id
       GROUP BY c.vivid_venue_id),
    u AS (
      INSERT INTO public.vivid_catalog_venue AS v (vivid_venue_id, tevo_venue_id, method, events, derived_at)
      SELECT t.vivid_venue_id, t.tevo_venue_id, t.method, coalesce(cnt.n, 0), now()
        FROM _vc_venue t LEFT JOIN cnt ON cnt.vivid_venue_id = t.vivid_venue_id
      ON CONFLICT (vivid_venue_id) DO UPDATE
        SET tevo_venue_id = EXCLUDED.tevo_venue_id, method = EXCLUDED.method, events = EXCLUDED.events, derived_at = now()
        WHERE NOT public.catalog_venue_kept(v.method)
          AND (v.tevo_venue_id IS DISTINCT FROM EXCLUDED.tevo_venue_id OR v.method IS DISTINCT FROM EXCLUDED.method OR v.events IS DISTINCT FROM EXCLUDED.events)
      RETURNING v.vivid_venue_id, v.tevo_venue_id, v.method, v.events)
    INSERT INTO public.vivid_catalog_audit (run_id, action, target, target_key, note)
    SELECT v_run, 'venue_xref', 'vivid_catalog_venue', u.vivid_venue_id::text, format('tevo_venue %s via %s (%s events)', u.tevo_venue_id, u.method, u.events) FROM u;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    v_out := v_out || jsonb_build_object('venues_written', v_n);

    -- 5. hub: vivid_event_id on the matched events' rows (fill-only; one Vivid id per EVO event)
    WITH vv AS (
      SELECT c.tevo_event_id, min(c.vivid_event_id) AS vivid_event_id
        FROM public.vivid_catalog_event c
       WHERE c.tevo_event_id IS NOT NULL AND c.event_date >= current_date - 1
       GROUP BY c.tevo_event_id HAVING count(*) = 1),
    tgt AS (   -- mig 20261117110000: a hub row another transaction holds is skipped, not waited for
      SELECT a.aq_short_event_id, vv.vivid_event_id, vv.tevo_event_id
        FROM public.aq_event_map a JOIN vv ON vv.tevo_event_id = a.tevo_event_id
       WHERE a.vivid_event_id IS NULL
         AND NOT EXISTS (SELECT 1 FROM public.aq_event_map o WHERE o.vivid_event_id = vv.vivid_event_id AND o.tevo_event_id IS DISTINCT FROM vv.tevo_event_id)
       FOR UPDATE OF a SKIP LOCKED
    ),
    u AS (
      UPDATE public.aq_event_map a SET vivid_event_id = t.vivid_event_id
        FROM tgt t
       WHERE a.aq_short_event_id = t.aq_short_event_id
       RETURNING a.aq_short_event_id, a.tevo_event_id, t.vivid_event_id)
    INSERT INTO public.vivid_catalog_audit (run_id, vivid_event_id, action, target, target_key, new_tevo)
    SELECT v_run, u.vivid_event_id, 'hub_vivid', 'aq_event_map', u.aq_short_event_id, u.tevo_event_id FROM u;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    v_out := v_out || jsonb_build_object('hub_vivid_filled', v_n);

    -- 6. orders: by productionId, fill-only; disagreements audited, never re-pointed
    WITH u AS (
      UPDATE public.vivid_orders o
         SET tevo_event_id = c.tevo_event_id
        FROM public.vivid_catalog_event c
       WHERE o.tevo_event_id IS NULL AND o.event_date >= now() - interval '1 day' AND (o.raw->>'productionId') ~ '^\d+$'
         AND c.vivid_event_id = (o.raw->>'productionId')::bigint AND c.tevo_event_id IS NOT NULL
       RETURNING o.vivid_order_id, c.vivid_event_id, c.tevo_event_id)
    INSERT INTO public.vivid_catalog_audit (run_id, vivid_event_id, action, target, target_key, new_tevo, note)
    SELECT v_run, u.vivid_event_id, 'order_tevo', 'vivid_orders', u.vivid_order_id, u.tevo_event_id, 'vivid_catalog_id' FROM u;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    v_out := v_out || jsonb_build_object('orders_filled', v_n);
    INSERT INTO public.vivid_catalog_audit (run_id, vivid_event_id, action, target, target_key, old_tevo, new_tevo)
    SELECT v_run, c.vivid_event_id, 'order_disagree', 'vivid_orders', o.vivid_order_id, o.tevo_event_id, c.tevo_event_id
      FROM public.vivid_orders o
      JOIN public.vivid_catalog_event c ON (o.raw->>'productionId') ~ '^\d+$' AND c.vivid_event_id = (o.raw->>'productionId')::bigint
     WHERE o.tevo_event_id IS NOT NULL AND c.tevo_event_id IS NOT NULL AND o.tevo_event_id <> c.tevo_event_id
       AND o.event_date >= now() - interval '1 day'
       AND NOT EXISTS (SELECT 1 FROM public.vivid_catalog_audit a
                        WHERE a.action = 'order_disagree' AND a.target_key = o.vivid_order_id AND a.new_tevo = c.tevo_event_id);
    GET DIAGNOSTICS v_n = ROW_COUNT;
    v_out := v_out || jsonb_build_object('orders_disagree_new', v_n);
  END IF;

  RETURN jsonb_build_object('run_id', v_run, 'applied', p_apply) || v_out;
END $function$;

-- ───────────────────────── 5. cron ─────────────────────────
-- hourly at :33, before the catalogue mappers (:41 TickPick, :43 Vivid): a venue paired this hour maps its events
-- this hour. Both catalogues in one job; each call pairs only what is still unpaired, so after the first pass a run
-- is a few seconds.
DO $cron$
BEGIN
  IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'catalog_venue_pair_hourly') THEN PERFORM cron.unschedule('catalog_venue_pair_hourly'); END IF;
  PERFORM cron.schedule('catalog_venue_pair_hourly', '33 * * * *',
                        $j$BEGIN; SET LOCAL statement_timeout = '600s'; SELECT public.catalog_venue_pair('tickpick'); SELECT public.catalog_venue_pair('vivid'); COMMIT;$j$);
END
$cron$;

COMMIT;

-- VERIFY:
--   SELECT public.catalog_venue_pair('tickpick', false);          -- dry run: counts per rule, the ambiguous, a sample; nothing written
--   SELECT public.catalog_venue_pair('vivid', false);
--   -- the first live pass is the :33 cron (600 s); then:
--   SELECT method, count(*) FROM v_catalog_venue_pairs WHERE method LIKE 'pair_%' GROUP BY 1 ORDER BY 1;
--   SELECT source, name, city, state, tevo_name, tevo_location, method FROM v_catalog_venue_pairs WHERE method LIKE 'pair_%' ORDER BY random() LIMIT 40;
--   SELECT at, target, target_key, note FROM vivid_catalog_audit WHERE action = 'venue_xref' AND note LIKE '%pair_%' ORDER BY id DESC LIMIT 20;
--   -- to reverse one: UPDATE vivid_catalog_venue SET tevo_venue_id = NULL, method = NULL WHERE vivid_venue_id = <id>;  (the mapper will not re-pair it by rule; the pairer may — set method = 'manual' with the right id, or leave it NULL and it is re-offered)

-- Migration 20261118002000 · level:data-collection · lane:A1 (data plane — mapping program) · writes:catalog_venue_pair()(replaced: 'tm' as a third source, text ids, every other catalogue a sibling),v_catalog_venue_pairs(replaced: ticketmaster rows, venue_id text),cron:catalog_venue_pair_hourly(rescheduled: + tm) · reads:tm_venue_xref,tm_discovery_event,tickpick_catalog_*,vivid_catalog_*,axs_export_event,events · pre:20261117180000
--
-- MAPPING PROGRAM — TICKETMASTER VENUES GO THROUGH THE VENUE PAIRER.
--
-- Operator 2026-11-18: "Also map tm venues to venue mapper." The Discovery match (mig 20261117180000) pairs a TM venue
-- only by an equal normalised name in its city (norm_city) or by learning from two matched events (matched_events);
-- 101 of 284 TM venues were left unpaired after the first page. The venue pairer (mig 20261117140000) has the six
-- rules — eq_city, sibling, eq_state, parking, affix, cooccur — and the discipline (one candidate or nothing,
-- fill-only, audited, the mappers keep `pair_%` rows). This migration makes Ticketmaster its third source.
--
-- What changes in `catalog_venue_pair(p_source, p_apply)`:
--   - `p_source = 'tm'`: the venue table is `tm_venue_xref` (key `tm_venue_id`, TEXT), the events are
--     `tm_discovery_event` (date `local_date`; products and cancelled events left out), the audit is
--     `tm_discovery_audit`. The pairer's working tables carry the venue id as text for every source (the two
--     catalogues' bigint ids are cast), the date column is named per source.
--   - R2 (sibling) now reads EVERY other catalogue's pairing, not one: TickPick and Vivid lean on each other and on
--     Ticketmaster, Ticketmaster on both — plus AXS, as before.
--   - Nothing else moves: same rules, same thresholds, same fill-only write (`tevo_venue_id IS NULL`), so a TM venue
--     the Discovery match already paired (norm_city / matched_events) is never touched, and the match's own two
--     writes are fill-only too, so a `pair_%` row stands. `tm_discovery_match` reads `tm_venue_xref` where
--     `tevo_venue_id IS NOT NULL` and so takes the pairer's venues up on its next run.
--   - `v_catalog_venue_pairs` shows 'ticketmaster' rows (venue_id is text now, for the TM ids).
--   - cron `catalog_venue_pair_hourly` (:33) runs tickpick, vivid, then tm.
--
-- Apply: `BEGIN;` / `COMMIT;` stripped; away from :33. Harness: tests/sql/venue_pairing (section G).

BEGIN;
SET LOCAL lock_timeout = '10s';

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
  v_date  text;   -- the event table's local date column
  v_sibs  text[]; -- the other catalogues' venue tables: label, table, key per row (mig 20261118002000)
  v_sib   text;
  v_live  text;   -- the event filter of the catalogue
  v_to    date := current_date + 365;
  v_n     int;
  v_t     timestamptz := clock_timestamp();
  v_ms    jsonb := '{}'::jsonb;
BEGIN
  IF p_source = 'tickpick' THEN
    v_tbl := 'tickpick_catalog_venue'; v_key := 'tp_venue_id'; v_evt := 'tickpick_catalog_event'; v_aud := 'tickpick_catalog_audit'; v_date := 'event_date';
    v_live := $f$c.status IS DISTINCT FROM 'canceled' AND c.merged_into IS NULL AND c.date_confirmed$f$;
  ELSIF p_source = 'vivid' THEN
    v_tbl := 'vivid_catalog_venue'; v_key := 'vivid_venue_id'; v_evt := 'vivid_catalog_event'; v_aud := 'vivid_catalog_audit'; v_date := 'event_date';
    v_live := 'true';
  ELSIF p_source = 'tm' THEN
    -- Ticketmaster (mig 20261118002000): the Discovery venue xref; its events are the Discovery catalogue; ids are text
    v_tbl := 'tm_venue_xref'; v_key := 'tm_venue_id'; v_evt := 'tm_discovery_event'; v_aud := 'tm_discovery_audit'; v_date := 'local_date';
    v_live := $f$NOT c.is_product AND coalesce(c.status_code, 'onsale') NOT IN ('cancelled', 'canceled')$f$;
  ELSE
    RAISE EXCEPTION 'catalog_venue_pair: unknown source %', p_source;
  END IF;
  -- the other catalogues' pairings serve as siblings (R2)
  SELECT array_agg(s.spec) INTO v_sibs
    FROM (VALUES ('tickpick', 'tickpick venue %s|tickpick_catalog_venue|tp_venue_id'), ('vivid', 'vivid venue %s|vivid_catalog_venue|vivid_venue_id'),
                 ('tm', 'ticketmaster venue %s|tm_venue_xref|tm_venue_id')) s(src, spec)
   WHERE s.src <> p_source;
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
  CREATE TEMP TABLE _vp_u (id text PRIMARY KEY, name text, city text, st text, ev int, norm text, norm_full text, is_parking boolean) ON COMMIT DROP;
  EXECUTE format($q$
    INSERT INTO _vp_u
    SELECT v.%2$I::text, v.name, lower(trim(v.city)), upper(trim(v.state)), count(*),
           public.catalog_venue_norm(v.name, v.city, v.state, true), public.catalog_venue_norm(v.name, v.city, v.state, false),
           lower(v.name) ~ '\mparking\M'
      FROM public.%1$I v
      JOIN public.%3$I c ON c.%2$I = v.%2$I
     WHERE v.tevo_venue_id IS NULL AND coalesce(v.name, '') <> '' AND coalesce(v.state, '') <> ''
       AND coalesce(v.country, 'US') IN ('US', 'CA', 'MX')
       AND c.%5$I BETWEEN current_date AND $1 AND %4$s
     GROUP BY v.%2$I, v.name, v.city, v.state$q$, v_tbl, v_key, v_evt, v_live, v_date) USING v_to;
  CREATE INDEX ON _vp_u (st, city, norm);
  ANALYZE _vp_u;
  v_out := v_out || jsonb_build_object('source', p_source, 'unpaired_in', (SELECT count(*) FROM _vp_u), 'unpaired_events_in', (SELECT coalesce(sum(ev), 0) FROM _vp_u));

  DROP TABLE IF EXISTS _vp_pick;
  CREATE TEMP TABLE _vp_pick (id text PRIMARY KEY, tevo_venue_id bigint NOT NULL, method text NOT NULL, note text) ON COMMIT DROP;
  DROP TABLE IF EXISTS _vp_amb;
  CREATE TEMP TABLE _vp_amb (id text, rule text, n int) ON COMMIT DROP;

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
  FOREACH v_sib IN ARRAY v_sibs LOOP
    EXECUTE format($q$
      INSERT INTO _vp_sib
      SELECT format(%1$L, v.%3$I), v.name, lower(trim(v.city)), upper(trim(v.state)), v.tevo_venue_id,
             public.catalog_venue_norm(v.name, v.city, v.state, true)
        FROM public.%2$I v WHERE v.tevo_venue_id IS NOT NULL AND coalesce(v.state, '') <> ''$q$,
      split_part(v_sib, '|', 1), split_part(v_sib, '|', 2), split_part(v_sib, '|', 3));
  END LOOP;
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
  CREATE TEMP TABLE _vp_ue (id text, day date, nn text) ON COMMIT DROP;
  EXECUTE format($q$
    INSERT INTO _vp_ue
    SELECT DISTINCT c.%2$I::text, c.%4$I, lower(trim(regexp_replace(c.name, '[^A-Za-z0-9]+', ' ', 'g')))
      FROM public.%1$I c
      JOIN _vp_u u ON u.id = c.%2$I::text
     WHERE c.%4$I BETWEEN current_date AND current_date + 120 AND %3$s
       AND NOT EXISTS (SELECT 1 FROM _vp_pick p WHERE p.id = u.id)
       AND c.name !~* '(parking|tailgate|shuttle|package|hospitality|\mvip\M|suites?\M)'$q$, v_evt, v_key, v_live, v_date);
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
          FROM _vp_pick p WHERE v.%2$I::text = p.id AND v.tevo_venue_id IS NULL
        RETURNING v.%2$I::text AS id, p.tevo_venue_id, p.method, p.note)
      INSERT INTO public.%3$I (run_id, action, target, target_key, note)
      SELECT $1, 'venue_xref', %1$L, u.id, format('tevo_venue %%s via %%s: %%s', u.tevo_venue_id, u.method, u.note) FROM upd u$q$,
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
END $function$;COMMENT ON FUNCTION public.catalog_venue_pair(text, boolean) IS
  'Pairs a catalogue''s (tickpick | vivid | tm) unpaired venues with TEvo venues: equal normalised names in the city, another catalogue''s or AXS''s pairing of the same name, equal names across the state, parking venues after their base venue, an affixed name corroborated by a shared event day, or the venue whose EVO events the catalogue''s events keep fitting. One candidate or nothing; fill-only; audited (venue_xref). Migs 20261117140000 / 20261118002000.';

-- ───────────────────────── the review view, with Ticketmaster ─────────────────────────
DROP VIEW IF EXISTS public.v_catalog_venue_pairs;
CREATE VIEW public.v_catalog_venue_pairs AS
SELECT 'tickpick' AS source, v.tp_venue_id::text AS venue_id, v.name, v.city, v.state, v.tevo_venue_id, t.venue_name AS tevo_name, t.venue_location AS tevo_location, v.method, v.events, v.derived_at
  FROM public.tickpick_catalog_venue v
  LEFT JOIN LATERAL (SELECT e.venue_name, e.venue_location FROM public.events e WHERE e.venue_id = v.tevo_venue_id ORDER BY e.occurs_at_local DESC LIMIT 1) t ON true
 WHERE v.tevo_venue_id IS NOT NULL
UNION ALL
SELECT 'vivid', v.vivid_venue_id::text, v.name, v.city, v.state, v.tevo_venue_id, t.venue_name, t.venue_location, v.method, v.events, v.derived_at
  FROM public.vivid_catalog_venue v
  LEFT JOIN LATERAL (SELECT e.venue_name, e.venue_location FROM public.events e WHERE e.venue_id = v.tevo_venue_id ORDER BY e.occurs_at_local DESC LIMIT 1) t ON true
 WHERE v.tevo_venue_id IS NOT NULL
UNION ALL
SELECT 'ticketmaster', v.tm_venue_id, v.name, v.city, v.state, v.tevo_venue_id, t.venue_name, t.venue_location, v.method, v.events, v.derived_at
  FROM public.tm_venue_xref v
  LEFT JOIN LATERAL (SELECT e.venue_name, e.venue_location FROM public.events e WHERE e.venue_id = v.tevo_venue_id ORDER BY e.occurs_at_local DESC LIMIT 1) t ON true
 WHERE v.tevo_venue_id IS NOT NULL;
COMMENT ON VIEW public.v_catalog_venue_pairs IS 'Every catalogue venue pairing (TickPick, Vivid, Ticketmaster) with both names, for review (filter by method, e.g. method LIKE ''pair_%''). Migs 20261117140000 / 20261118002000.';
REVOKE ALL ON public.v_catalog_venue_pairs FROM anon, authenticated;
GRANT SELECT ON public.v_catalog_venue_pairs TO service_role;

-- ───────────────────────── the cron: Ticketmaster after the two catalogues ─────────────────────────
DO $cron$
BEGIN
  IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'catalog_venue_pair_hourly') THEN PERFORM cron.unschedule('catalog_venue_pair_hourly'); END IF;
  PERFORM cron.schedule('catalog_venue_pair_hourly', '33 * * * *',
                        $j$BEGIN; SET LOCAL statement_timeout = '600s'; SELECT public.catalog_venue_pair('tickpick'); SELECT public.catalog_venue_pair('vivid'); SELECT public.catalog_venue_pair('tm'); COMMIT;$j$);
END
$cron$;

COMMIT;

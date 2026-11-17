-- Migration 20261117080000 · level:data-collection · lane:A1 (data plane — mapping program) · writes:event_mapper_identity() fn (TickPick + Vivid catalogue identity),event_mapper_surface_sql() fn (tickpick_orders passes its event id, venue, city, state),tickpick_catalog_map() fn (name+state venue seeding, US/CA/MX focus),vivid_catalog_map() fn (same),v_event_catalogues(new view) · reads:events,tickpick_catalog_*,vivid_catalog_*,gotickets_event,sg_events_canonical,axs_export_event,mlb_ticket_game · pre:20261117070000
--
-- MAPPING PROGRAM — THE CATALOGUES IN THE RESOLVER (operator 2026-11-17: "update mapper to include it", "incorporate
-- tickpick into event matcher also", "we should have seatgeek, axs, tickpick, evo, gotickets, and vivid event
-- catalogues and mapper integration by the end of build, focusing on USA and Canada and Mexico and MLB/ticket.com").
--
-- WHERE THE SIX STAND. EVO is the spine (`events`, the TEvo mirror). SeatGeek (`sg_events_canonical`), GoTickets
--   (`gotickets_event`) and AXS (`axs_export_event` + `axs_catalog`) are catalogues with their own mappers and
--   resolver surfaces. TickPick (mig 20261117040000) and Vivid (mig 20261117070000) are catalogues since today, each
--   with its own mapper, but the SHARED resolver did not know them: event_mapper_identity('tickpick', id) and
--   ('vivid', id) looked only at the hub, and the tickpick_orders surface handed the resolver no event id at all
--   (source_event_id NULL) although every TickPick order carries one. MLB / tickets.com is the primary-market anchor
--   (mig 20261117000000, its mapper pending apply).
--
-- WHAT THIS DOES.
--   1. event_mapper_identity: for 'tickpick' and 'vivid' the catalogue is asked first (tickpick_catalog_event /
--      vivid_catalog_event .tevo_event_id, methods identity_tickpick_catalog / identity_vivid_catalog), the hub second.
--      Every resolver surface that passes a TickPick or Vivid id — our order books, the N2S items, the CRM mirror
--      when it learns ids — now resolves through the catalogues' verified matches in stage 0.
--   2. event_mapper_surface_sql('tickpick_orders'): source_event_id = raw event id, venue name / city / state from the
--      order's venue block (they were NULL). Nothing else in the function changes (body otherwise prod's).
--   3. Venue pairing by name: both catalogue mappers gain a 'name_state' venue source — the catalogue venue's name,
--      lower-cased and trimmed, equal to a TEvo venue's name on an upcoming event, in the same state (TEvo's state is
--      the suffix of venue_location), when exactly one TEvo venue matches. Measured 2026-11-17: 2,012 of 8,664 US
--      Vivid venues and 2,524 of 3,680 US TickPick venues pair this way, none ambiguous — against 87 and 258 paired
--      before. Order of trust: manual → (TickPick: aq_venue_map → cross_source) → name_state → learned from matches.
--   4. Focus: candidates are events at venues in US, CA or MX (TickPick's venue_country / Vivid's countryCode).
--   5. v_event_catalogues: one row per catalogue (evo, seatgeek, gotickets, axs, tickpick, vivid, mlb) — upcoming
--      events in the three countries, how many are mapped to EVO, the share, and how fresh the catalogue is. The
--      readout for "where do the six stand".
-- RULE 2: nothing upstream is called. No DDL on shared tables.
-- Rollback: the previous bodies are prod's as of 2026-11-17 (event_mapper_identity md5 4a0c5e7a9ea5a9a810b632ede102905c,
--   event_mapper_surface_sql md5 466f7498f98d4c6a207af3023e6e0427; the two mappers from migs 20261117040000 / 070000).

BEGIN;
SET LOCAL lock_timeout = '10s';

-- ───────────────────────── 1. identity: the catalogues first ─────────────────────────
CREATE OR REPLACE FUNCTION public.event_mapper_identity(p_source text, p_source_event_id bigint)
 RETURNS TABLE(tevo_event_id bigint, method text)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE v_src text := lower(trim(coalesce(p_source, ''))); v_tevo bigint; v_meth text;
BEGIN
  IF current_user NOT IN ('service_role', 'postgres', 'supabase_admin') THEN
    RAISE EXCEPTION 'forbidden: %', current_user USING ERRCODE = '42501';
  END IF;
  IF p_source_event_id IS NULL THEN RETURN; END IF;

  IF v_src IN ('tevo', 'evo') THEN
    tevo_event_id := p_source_event_id; method := 'identity_tevo'; RETURN NEXT; RETURN;
  ELSIF v_src IN ('gotickets', 'gt') THEN
    SELECT g.tevo_event_id INTO v_tevo FROM public.gotickets_event g
     WHERE g.gt_event_id = p_source_event_id AND g.tevo_event_id IS NOT NULL LIMIT 1;
    IF v_tevo IS NOT NULL THEN v_meth := 'identity_gotickets_event'; END IF;
    IF v_tevo IS NULL THEN
      SELECT a.tevo_event_id INTO v_tevo FROM public.aq_event_map a
       WHERE a.gotickets_event_id = p_source_event_id AND a.tevo_event_id IS NOT NULL
       ORDER BY (a.aq_source = 'aq_curated') DESC, a.imported_at DESC LIMIT 1;
      IF v_tevo IS NOT NULL THEN v_meth := 'identity_hub'; END IF;
    END IF;
  ELSIF v_src IN ('seatgeek', 'sg') THEN
    SELECT c.tevo_event_id INTO v_tevo FROM public.sg_events_canonical c
     WHERE c.sg_event_id = p_source_event_id AND c.tevo_event_id IS NOT NULL LIMIT 1;
    IF v_tevo IS NOT NULL THEN v_meth := 'identity_sg_canonical'; END IF;
    IF v_tevo IS NULL THEN
      SELECT a.tevo_event_id INTO v_tevo FROM public.aq_event_map a
       WHERE a.sg_event_id = p_source_event_id AND a.tevo_event_id IS NOT NULL
       ORDER BY (a.aq_source = 'aq_curated') DESC, a.imported_at DESC LIMIT 1;
      IF v_tevo IS NOT NULL THEN v_meth := 'identity_hub'; END IF;
    END IF;
  ELSIF v_src IN ('tickpick', 'tp') THEN
    -- mig 20261117080000: the TickPick catalogue's verified match first, the hub second
    SELECT c.tevo_event_id INTO v_tevo FROM public.tickpick_catalog_event c
     WHERE c.tp_event_id = p_source_event_id AND c.tevo_event_id IS NOT NULL LIMIT 1;
    IF v_tevo IS NOT NULL THEN v_meth := 'identity_tickpick_catalog'; END IF;
    IF v_tevo IS NULL THEN
      SELECT a.tevo_event_id INTO v_tevo FROM public.aq_event_map a
       WHERE a.tp_event_id = p_source_event_id AND a.tevo_event_id IS NOT NULL
       ORDER BY (a.aq_source = 'aq_curated') DESC, a.imported_at DESC LIMIT 1;
      IF v_tevo IS NOT NULL THEN v_meth := 'identity_hub'; END IF;
    END IF;
  ELSIF v_src IN ('vivid', 'vividseats', 'vivid seats') THEN
    -- mig 20261117080000: the Vivid catalogue (its eventId = the productionId on our orders) first, the hub second
    SELECT c.tevo_event_id INTO v_tevo FROM public.vivid_catalog_event c
     WHERE c.vivid_event_id = p_source_event_id AND c.tevo_event_id IS NOT NULL LIMIT 1;
    IF v_tevo IS NOT NULL THEN v_meth := 'identity_vivid_catalog'; END IF;
    IF v_tevo IS NULL THEN
      SELECT a.tevo_event_id INTO v_tevo FROM public.aq_event_map a
       WHERE a.vivid_event_id = p_source_event_id AND a.tevo_event_id IS NOT NULL
       ORDER BY (a.aq_source = 'aq_curated') DESC, a.imported_at DESC LIMIT 1;
      IF v_tevo IS NOT NULL THEN v_meth := 'identity_hub'; END IF;
    END IF;
  ELSIF v_src IN ('stubhub', 'sh', 'ticketmaster', 'tm', 'seatdata', 'sd') THEN
    SELECT a.tevo_event_id INTO v_tevo FROM public.aq_event_map a
     WHERE a.tevo_event_id IS NOT NULL
       AND ((v_src IN ('stubhub', 'sh')                      AND a.sh_event_id    = p_source_event_id)
         OR (v_src IN ('ticketmaster', 'tm')                 AND a.tm_event_id    = p_source_event_id)
         OR (v_src IN ('seatdata', 'sd')                     AND a.sd_event_id    = p_source_event_id))
     ORDER BY (a.aq_source = 'aq_curated') DESC, a.imported_at DESC LIMIT 1;
    IF v_tevo IS NOT NULL THEN v_meth := 'identity_hub'; END IF;
  END IF;

  IF v_tevo IS NOT NULL THEN
    tevo_event_id := v_tevo; method := v_meth; RETURN NEXT;
  END IF;
  RETURN;
END $function$;

-- ───────────────────────── 2. the tickpick_orders surface passes what the order carries ─────────────────────────
CREATE OR REPLACE FUNCTION public.event_mapper_surface_sql(p_surface text, p_horizon_days integer DEFAULT 180)
 RETURNS TABLE(select_sql text, update_sql text, key_type text)
 LANGUAGE plpgsql
 IMMUTABLE
AS $function$
BEGIN
  -- select_sql yields: row_key, source, source_event_id, event_name, performer, venue_name, venue_city,
  --                    venue_state, local_date, event_time_utc, previous (current tevo), ord (recency),
  --                    source_venue_id (the source's own venue id when it publishes one — mig 20260911220000),
  --                    source_performer_id (the source's own performer id — mig 20260914220000; SeatGeek only today)
  -- update_sql takes $1 row_key (text, cast inside), $2 tevo, $3 method, $4 score; fill-only.
  CASE p_surface
    WHEN 'gotickets_purchases' THEN
      select_sql := $q$SELECT gt_purchase_id::text AS row_key, 'gotickets'::text AS source, gt_event_id AS source_event_id, event_name,
                              performers->0->>'name' AS performer, venue_name, venue_city, venue_state, event_time_local::date AS local_date,
                              event_time_utc, tevo_event_id AS previous, updated_at AS ord, venue_id AS source_venue_id, NULL::text AS source_performer_id FROM public.gotickets_purchases WHERE event_time_local IS NOT NULL$q$;
      update_sql := $q$UPDATE public.gotickets_purchases SET tevo_event_id = $2, mapped_via = $3, map_score = $4, updated_at = now() WHERE gt_purchase_id = $1::bigint AND tevo_event_id IS NULL$q$;
    WHEN 'seatgeek_purchases' THEN
      select_sql := $q$SELECT order_id AS row_key, 'seatgeek'::text AS source, sg_event_id AS source_event_id, event_name, NULL::text AS performer,
                              event_location AS venue_name, NULL::text AS venue_city, NULL::text AS venue_state, event_start::date AS local_date,
                              NULL::timestamptz AS event_time_utc, tevo_event_id AS previous, updated_at AS ord, NULL::bigint AS source_venue_id, NULL::text AS source_performer_id FROM public.seatgeek_purchases WHERE event_start IS NOT NULL$q$;
      update_sql := $q$UPDATE public.seatgeek_purchases SET tevo_event_id = $2, mapped_via = $3, map_score = $4, updated_at = now() WHERE order_id = $1 AND tevo_event_id IS NULL$q$;
    WHEN 's4kcs_orders' THEN
      select_sql := $q$SELECT s4k_order_id AS row_key, lower(source) AS source, NULL::bigint AS source_event_id, event_name, NULL::text AS performer,
                              venue_name, venue_city, venue_state, event_date AS local_date, NULL::timestamptz AS event_time_utc,
                              tevo_event_id AS previous, coalesce(mapped_at, pulled_at) AS ord, NULL::bigint AS source_venue_id, NULL::text AS source_performer_id FROM public.s4kcs_orders WHERE event_date >= current_date - 7$q$;
      update_sql := $q$UPDATE public.s4kcs_orders SET tevo_event_id = $2, map_method = $3, map_confidence = $4, mapped_at = now() WHERE s4k_order_id = $1 AND tevo_event_id IS NULL$q$;
    WHEN 'n2s_items' THEN
      select_sql := $q$SELECT n2s_id::text AS row_key, lower(marketplace) AS source, NULL::bigint AS source_event_id, event_name, NULL::text AS performer,
                              venue AS venue_name, NULL::text AS venue_city, NULL::text AS venue_state, event_dt::date AS local_date, NULL::timestamptz AS event_time_utc,
                              tevo_event_id AS previous, n2s_updated_at AS ord, NULL::bigint AS source_venue_id, NULL::text AS source_performer_id FROM public.n2s_items WHERE NOT coalesce(is_terminal, false) AND event_dt IS NOT NULL$q$;
      update_sql := $q$UPDATE public.n2s_items SET tevo_event_id = $2, mapped_via = $3 WHERE n2s_id = $1::bigint AND tevo_event_id IS NULL$q$;
    WHEN 'tickpick_orders' THEN
      -- mig 20261117080000: the order's raw event block carries TickPick's event id (= the TicketNetwork id the
      -- TickPick catalogue is keyed on) and the venue with city and state; the surface handed the resolver none of
      -- them, so stage 0 (identity) and stage 1 (venue + day) could never fire here. Now source_event_id resolves
      -- through tickpick_catalog_event / aq_event_map.tp_event_id, and the venue reaches the venue rules.
      select_sql := $q$SELECT tp_order_id AS row_key, 'tickpick'::text AS source,
                              CASE WHEN raw->'event'->>'event_id' ~ '^[0-9]+$' THEN (raw->'event'->>'event_id')::bigint END AS source_event_id,
                              event_name, NULL::text AS performer,
                              nullif(trim(coalesce(raw->'event'->'venue'->>'name', raw->'venue'->>'name', '')), '') AS venue_name,
                              nullif(trim(coalesce(raw->'event'->'venue'->>'city', raw->'venue'->>'city', '')), '') AS venue_city,
                              nullif(trim(coalesce(raw->'event'->'venue'->>'state', raw->'venue'->>'state', '')), '') AS venue_state,
                              event_date::date AS local_date, event_date AS event_time_utc,
                              tevo_event_id AS previous, ordered_at AS ord, CASE WHEN raw->'venue'->>'id' ~ '^[0-9]+$' THEN (raw->'venue'->>'id')::bigint END AS source_venue_id, NULL::text AS source_performer_id FROM public.tickpick_orders WHERE event_date >= now() - interval '90 days'$q$;
      update_sql := $q$UPDATE public.tickpick_orders SET tevo_event_id = $2, matched_via = $3, match_confidence = $4, matched_at = now() WHERE tp_order_id = $1 AND tevo_event_id IS NULL$q$;
    WHEN 'vivid_orders' THEN
      -- mig 20260911230000: Vivid's raw payload carries BOTH a venue string and its own event id
      -- (productionId) on 100% of the book; the surface threw both away, so rules 0 and 1 could never
      -- fire here and only the weakest rule (name+day) ever hit. Now:
      --   source_event_id = productionId  → rule 0 identity through aq_event_map.vivid_event_id
      --                                     (the same column n2s_vivid_order_identity already uses)
      --   venue_name/city/state = raw 'venue' split on its " - City, ST" suffix, with &amp;
      --                           decoded ("AT&amp;T Stadium" never matched the mirror's
      --                           "AT&T Stadium"). The split is GREEDY (mig 20260914210000):
      --                           the generated suffix is always LAST, and 26 of 448 distinct
      --                           venue strings carry a " - " inside the venue name itself,
      --                           which a non-greedy split tore in half.
      --   event_time_utc = NULL, DELIBERATELY. vivid_orders.event_date stores the LOCAL wall time
      --     labelled +00 (the XML's <eventDate> verbatim), so handing it to rule 2 as a real instant
      --     put the ±24 h window 4–7 h off and picked the PREVIOUS evening's show: dry run 2026-09-11
      --     bound Hamilton 9/12 → the 9/11 performance and two Harry Potter dates the same way, plus
      --     a "Grounds Passes" row → "Session 8". Rule 2 stays off for Vivid until the venue timezone
      --     is applied to that column. Rule 4 anchors at local noon/19:00 as usual.
      select_sql := $q$SELECT vivid_order_id AS row_key, 'vivid'::text AS source,
                              CASE WHEN raw->>'productionId' ~ '^[0-9]+$' THEN (raw->>'productionId')::bigint END AS source_event_id,
                              event_name, NULL::text AS performer,
                              replace(coalesce((regexp_match(raw->>'venue', '^(.*)\s+-\s+[^,]+,\s*[A-Za-z]{2}$'))[1],
                                               nullif(trim(coalesce(raw->>'venue', '')), '')), '&amp;', '&') AS venue_name,
                              (regexp_match(raw->>'venue', '^.*\s+-\s+([^,]+),\s*[A-Za-z]{2}$'))[1] AS venue_city,
                              (regexp_match(raw->>'venue', '^.*\s+-\s+[^,]+,\s*([A-Za-z]{2})$'))[1] AS venue_state,
                              event_date::date AS local_date, NULL::timestamptz AS event_time_utc,
                              tevo_event_id AS previous, ordered_at AS ord, NULL::bigint AS source_venue_id, NULL::text AS source_performer_id
                         FROM public.vivid_orders WHERE event_date >= now() - interval '90 days'$q$;
      update_sql := $q$UPDATE public.vivid_orders SET tevo_event_id = $2 WHERE vivid_order_id = $1 AND tevo_event_id IS NULL$q$;
    WHEN 'gotickets_event' THEN
      select_sql := format($q$SELECT gt_event_id::text AS row_key, 'gotickets'::text AS source, gt_event_id AS source_event_id, name AS event_name, performer,
                              venue_name, venue_city, venue_state, NULL::date AS local_date, event_time_utc, tevo_event_id AS previous,
                              coalesce(mapped_at, updated_at) AS ord, NULL::bigint AS source_venue_id, NULL::text AS source_performer_id FROM public.gotickets_event
                        WHERE status = 'AS_SCHEDULED' AND event_time_utc > now() AND event_time_utc < now() + make_interval(days => %s)
                          -- mig 20260911219000: only rows whose venue the TEvo mirror (future events) or the venue map
                          -- already knows — 138k future catalogue rows, most at venues TEvo never lists (hashed IN-lists)
                          AND lower(trim(venue_name)) IN (
                                SELECT lower(trim(e.venue_name)) FROM public.events e
                                 WHERE left(e.occurs_at_local, 10) >= current_date::text AND e.venue_name IS NOT NULL
                                UNION SELECT lower(trim(m.tevo_venue_name)) FROM public.cross_source_venue_map m WHERE m.tevo_venue_name IS NOT NULL
                                UNION SELECT lower(trim(x)) FROM public.cross_source_venue_map m, jsonb_array_elements_text(m.gotickets_aliases) x
                                 WHERE jsonb_typeof(m.gotickets_aliases) = 'array')$q$,
                        greatest(1, coalesce(p_horizon_days, 180)));
      -- BOTH-WAYS GUARD (mig 20260915260000). "tevo_event_id IS NULL" only stops this writer
      -- OVERWRITING a mapping; it does nothing about a SECOND GoTickets row claiming a TEvo event
      -- that another row already holds. Measured 2026-09-15: TEvo events claimed by more than one
      -- GoTickets row went 134 -> 201 -> 212 in a single afternoon, and the timestamps place it
      -- here -- our pipeline wrote at 19:34:21 and a cron routed through this template wrote the
      -- same TEvo events onto different GoTickets rows at 19:35:00, 39 seconds later.
      update_sql := $q$UPDATE public.gotickets_event SET tevo_event_id = $2, mapped_via = $3, map_score = $4, mapped_at = now(), updated_at = now() WHERE gt_event_id = $1::bigint AND tevo_event_id IS NULL AND NOT EXISTS (SELECT 1 FROM public.gotickets_event g2 WHERE g2.tevo_event_id = $2 AND g2.gt_event_id <> $1::bigint)$q$;
    WHEN 'sg_events_canonical' THEN
      -- mig 20260914220000: sg_event_date is a UTC DATE, not a local one — the same landmine
      -- PROJECT_BIBLE §3 already records for tickpick_orders.event_date, on a surface nobody
      -- had checked. Measured over 8,888 mapped rows: it equals the UTC date on 8,868 (99.8%)
      -- and is ONE DAY AHEAD of the TEvo local day on 2,253 (25.3%) — every evening US event.
      -- Handing that to the resolver as local_date meant rule 1 (venue + same local day) simply
      -- could not fire on a quarter of the book, and since mig 20260912051500 rule 2 refuses a
      -- different local day too, so those rows fell through to the weakest rules or declined.
      -- SeatGeek ships the real thing in the payload: raw_event_jsonb->>'datetime_local', present
      -- on 8,270 of 8,298 raw rows. Day-accuracy against the TEvo mirror over 5,712 mapped rows
      -- with a raw local time: 3,375 (59%) with the column, 5,353 (94%) with the raw field.
      -- source_performer_id is SeatGeek's own primary performer id, which canonical_external_ids
      -- now resolves to a tevo_performer_id — it is what breaks a venue+day tie WITHOUT a name.
      select_sql := $q$SELECT sg_event_id::text AS row_key, 'seatgeek'::text AS source, sg_event_id AS source_event_id, sg_event_name AS event_name, NULL::text AS performer,
                              sg_venue_name AS venue_name, sg_venue_city AS venue_city, sg_venue_state AS venue_state,
                              coalesce(nullif(left(raw_event_jsonb->>'datetime_local', 10), '')::date, sg_event_date) AS local_date,
                              sg_datetime_utc AS event_time_utc,
                              tevo_event_id AS previous, coalesce(matched_at, updated_at) AS ord,
                              coalesce(sg_venue_id, CASE WHEN raw_event_jsonb->'venue'->>'id' ~ '^[0-9]+$' THEN (raw_event_jsonb->'venue'->>'id')::bigint END) AS source_venue_id,
                              (SELECT p->>'id' FROM jsonb_array_elements(coalesce(raw_event_jsonb->'performers', '[]'::jsonb)) p
                                WHERE p->>'primary' = 'true' AND p->>'id' ~ '^[0-9]+$' LIMIT 1) AS source_performer_id
                         FROM public.sg_events_canonical
                        WHERE sg_event_date >= current_date AND coalesce(sg_category, '') NOT IN ('Parking', 'parking')$q$;
      update_sql := $q$UPDATE public.sg_events_canonical SET tevo_event_id = $2, match_method = $3, match_confidence = $4, matched_at = now(), updated_at = now() WHERE sg_event_id = $1::bigint AND tevo_event_id IS NULL$q$;
    ELSE
      RAISE EXCEPTION 'event_mapper: unknown surface % (gotickets_purchases | seatgeek_purchases | s4kcs_orders | n2s_items | tickpick_orders | vivid_orders | gotickets_event | sg_events_canonical)', p_surface;
  END CASE;
  key_type := 'text';
  RETURN NEXT;
END $function$;

-- ───────────────────────── 3. the TEvo venues by name and state, for both catalogue mappers ─────────────────────────
-- One row per (name, state) that exactly one TEvo venue carries on an upcoming event; the state is the suffix of
-- venue_location ("Los Angeles, CA" -> CA). A name shared by several TEvo venues in one state is left out.
CREATE OR REPLACE FUNCTION public.catalog_tevo_venues_by_name()
 RETURNS TABLE(nm text, st text, tevo_venue_id bigint)
 LANGUAGE sql
 STABLE
AS $function$
  SELECT s.nm, s.st, min(s.venue_id)
    FROM (SELECT DISTINCT e.venue_id, lower(trim(e.venue_name)) AS nm,
                 upper(btrim(reverse(split_part(reverse(coalesce(e.venue_location, '')), ',', 1)))) AS st
            FROM public.events e
           WHERE e.occurs_at_local >= to_char(now() - interval '1 day', 'YYYY-MM-DD')
             AND e.venue_id IS NOT NULL AND coalesce(e.venue_name, '') <> '') s
   GROUP BY s.nm, s.st
  HAVING count(DISTINCT s.venue_id) = 1;
$function$;
COMMENT ON FUNCTION public.catalog_tevo_venues_by_name() IS
  'TEvo venues on upcoming events keyed by lower-cased name + state (venue_location suffix), only where that pair names exactly one TEvo venue. The name_state venue source of the catalogue mappers. Mig 20261117080000.';
REVOKE ALL ON FUNCTION public.catalog_tevo_venues_by_name() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.catalog_tevo_venues_by_name() TO service_role;

-- ───────────────────────── 3a. tickpick_catalog_map: name_state venues, US/CA/MX ─────────────────────────
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

  -- 3. venues: manual -> aq_venue_map -> cross_source (unanimous) -> name + state (mig 20261117080000) -> learned
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
    SELECT s.tp_venue_id, s.tv, 'matched_events', 5
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

  -- 4. venue + local day (+ name, + time)
  DROP TABLE IF EXISTS _tc_fit;
  CREATE TEMP TABLE _tc_fit ON COMMIT DROP AS
  SELECT x.tp_event_id, e.id AS tevo_event_id, x.time_confirmed,
         (x.time_confirmed AND x.event_utc IS NOT NULL
          AND abs(extract(epoch FROM public.tevo_event_utc(e.occurs_at_local, e.venue_id) - x.event_utc)) <= 60) AS same_minute
    FROM _tc_cand x
    JOIN _tc_venue v ON v.tp_venue_id = x.tp_venue_id
    JOIN public.events e ON e.venue_id = v.tevo_venue_id
                        AND left(e.occurs_at_local, 10) = to_char(x.event_date, 'YYYY-MM-DD')
                        AND e.state IS DISTINCT FROM 'ignored'
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
        WHERE v.method IS DISTINCT FROM 'manual'
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
    u AS (
      UPDATE public.aq_event_map a SET tp_event_id = tp.tp_event_id
        FROM tp
       WHERE a.tevo_event_id = tp.tevo_event_id AND a.tp_event_id IS NULL
         AND NOT EXISTS (SELECT 1 FROM public.aq_event_map o WHERE o.tp_event_id = tp.tp_event_id AND o.tevo_event_id IS DISTINCT FROM tp.tevo_event_id)
       RETURNING a.aq_short_event_id, a.tevo_event_id, tp.tp_event_id)
    INSERT INTO public.tickpick_catalog_audit (run_id, tp_event_id, action, target, target_key, new_tevo)
    SELECT v_run, u.tp_event_id, 'hub_tp', 'aq_event_map', u.aq_short_event_id, u.tevo_event_id FROM u;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    v_out := v_out || jsonb_build_object('hub_tp_filled', v_n);

    -- 6. orders: by id, fill-only; disagreements audited, never re-pointed
    WITH u AS (
      UPDATE public.tickpick_orders o
         SET tevo_event_id = c.tevo_event_id, matched_via = 'tp_catalog_id', match_confidence = 1.0, matched_at = now()
        FROM public.tickpick_catalog_event c
       WHERE o.tevo_event_id IS NULL AND (o.raw->'event'->>'event_id') ~ '^\d+$'
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
    WITH u AS (
      UPDATE public.aq_venue_map m SET tickpick_venue_id = v.tp_venue_id
        FROM public.tickpick_catalog_venue v
       WHERE v.tevo_venue_id = m.tevo_venue_id AND m.tickpick_venue_id IS NULL AND v.tevo_venue_id IS NOT NULL
         AND (v.method = 'manual' OR coalesce(v.events, 0) >= 2)
         AND NOT EXISTS (SELECT 1 FROM public.aq_venue_map o WHERE o.tickpick_venue_id = v.tp_venue_id)
         AND NOT EXISTS (SELECT 1 FROM public.tickpick_catalog_venue w WHERE w.tevo_venue_id = v.tevo_venue_id AND w.tp_venue_id <> v.tp_venue_id)
       RETURNING m.venue_short_id, m.tevo_venue_id, v.tp_venue_id)
    INSERT INTO public.tickpick_catalog_audit (run_id, action, target, target_key, note)
    SELECT v_run, 'venue_map', 'aq_venue_map', u.venue_short_id, 'tickpick_venue ' || u.tp_venue_id || ' on tevo_venue ' || u.tevo_venue_id FROM u;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    v_out := v_out || jsonb_build_object('venue_map_filled', v_n);
  END IF;

  RETURN jsonb_build_object('run_id', v_run, 'applied', p_apply) || v_out;
END $function$;

-- ───────────────────────── 3b. vivid_catalog_map: name_state venues, US/CA/MX ─────────────────────────
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

  -- 3. venues: manual -> name + state (mig 20261117080000) -> learned from matches
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
    SELECT s.vivid_venue_id, s.tv, 'matched_events', 3
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

  -- 4. venue + local day (+ name, + minute)
  DROP TABLE IF EXISTS _vc_fit;
  CREATE TEMP TABLE _vc_fit ON COMMIT DROP AS
  SELECT x.vivid_event_id, e.id AS tevo_event_id,
         (x.event_utc IS NOT NULL AND abs(extract(epoch FROM public.tevo_event_utc(e.occurs_at_local, e.venue_id) - x.event_utc)) <= 60) AS same_minute
    FROM _vc_cand x
    JOIN _vc_venue v ON v.vivid_venue_id = x.vivid_venue_id
    JOIN public.events e ON e.venue_id = v.tevo_venue_id
                        AND left(e.occurs_at_local, 10) = to_char(x.event_date, 'YYYY-MM-DD')
                        AND e.state IS DISTINCT FROM 'ignored'
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
        WHERE v.method IS DISTINCT FROM 'manual'
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
    u AS (
      UPDATE public.aq_event_map a SET vivid_event_id = vv.vivid_event_id
        FROM vv
       WHERE a.tevo_event_id = vv.tevo_event_id AND a.vivid_event_id IS NULL
         AND NOT EXISTS (SELECT 1 FROM public.aq_event_map o WHERE o.vivid_event_id = vv.vivid_event_id AND o.tevo_event_id IS DISTINCT FROM vv.tevo_event_id)
       RETURNING a.aq_short_event_id, a.tevo_event_id, vv.vivid_event_id)
    INSERT INTO public.vivid_catalog_audit (run_id, vivid_event_id, action, target, target_key, new_tevo)
    SELECT v_run, u.vivid_event_id, 'hub_vivid', 'aq_event_map', u.aq_short_event_id, u.tevo_event_id FROM u;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    v_out := v_out || jsonb_build_object('hub_vivid_filled', v_n);

    -- 6. orders: by productionId, fill-only; disagreements audited, never re-pointed
    WITH u AS (
      UPDATE public.vivid_orders o
         SET tevo_event_id = c.tevo_event_id
        FROM public.vivid_catalog_event c
       WHERE o.tevo_event_id IS NULL AND (o.raw->>'productionId') ~ '^\d+$'
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

-- ───────────────────────── 5. where the six stand ─────────────────────────
CREATE OR REPLACE VIEW public.v_event_catalogues
WITH (security_invoker = true) AS
WITH c AS (
  SELECT 'evo' AS catalogue, count(*) AS upcoming, count(*) AS mapped, max(NULL::timestamptz) AS last_seen
    FROM public.events e WHERE e.occurs_at_local >= to_char(now(), 'YYYY-MM-DD') AND e.state IS DISTINCT FROM 'ignored'
  UNION ALL
  SELECT 'seatgeek', count(*), count(tevo_event_id), max(updated_at)
    FROM public.sg_events_canonical WHERE sg_event_date >= current_date
  UNION ALL
  SELECT 'gotickets', count(*), count(tevo_event_id), max(updated_at)
    FROM public.gotickets_event WHERE event_time_utc >= now() AND status = 'AS_SCHEDULED'
  UNION ALL
  SELECT 'axs', count(*), count(tevo_event_id), max(coalesce(matched_at, NULL))
    FROM public.axs_export_event WHERE gone_at IS NULL AND event_date_local >= to_char(now(), 'YYYY-MM-DD') AND coalesce(venue_country, 'US') IN ('US', 'CA', 'MX')
  UNION ALL
  SELECT 'tickpick', count(*), count(tevo_event_id), max(last_seen_at)
    FROM public.tickpick_catalog_event WHERE event_date >= current_date AND status IS DISTINCT FROM 'canceled' AND coalesce(venue_country, 'US') IN ('US', 'CA', 'MX')
  UNION ALL
  SELECT 'vivid', count(*), count(tevo_event_id), max(last_seen_at)
    FROM public.vivid_catalog_event WHERE event_date >= current_date AND coalesce(venue_country, 'US') IN ('US', 'CA', 'MX')
  UNION ALL
  SELECT 'mlb', count(*), count(tevo_event_id), max(updated_at)
    FROM public.mlb_ticket_game WHERE game_date >= current_date
)
SELECT catalogue, upcoming, mapped, upcoming - mapped AS unmapped,
       CASE WHEN upcoming > 0 THEN round(100.0 * mapped / upcoming, 1) END AS mapped_pct, last_seen
  FROM c;
REVOKE ALL ON public.v_event_catalogues FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.v_event_catalogues TO service_role;
COMMENT ON VIEW public.v_event_catalogues IS
  'Where the six event catalogues stand (US/CA/MX, upcoming): EVO (the spine), SeatGeek, GoTickets, AXS, TickPick, Vivid, plus the MLB schedule — upcoming events, how many map to EVO, freshness. Mig 20261117080000.';

COMMIT;

-- VERIFY:
--   SELECT * FROM public.v_event_catalogues;
--   SELECT public.tickpick_catalog_map(false);  SELECT public.vivid_catalog_map(false);     -- venues_by_method shows name_state
--   SELECT * FROM public.event_mapper_identity('tickpick', <a tp_event_id with tevo_event_id>);

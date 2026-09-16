-- Migration 20260915260000 · level:data-collection · lane:A1 · writes:gotickets_event · reads:gotickets_event,events · pre:20260914221000
-- ⚠ NOT YET APPLIED. Supabase was down for maintenance when this was written, so it has not been
-- executed or verified. Before applying, md5-compare the CURRENT prod body of
-- event_mapper_surface_sql against the copy reproduced here: this file was rebuilt from the
-- repo's newest definition (mig 20260914221000) and applying it would silently revert any change
-- made to prod out-of-band since then.
--
-- ============================================================================================
-- ONE MISSING CONDITION, IN ONE SHARED TEMPLATE, IS MINTING DUPLICATE CLAIMS
-- ============================================================================================
-- Every matcher that writes a GoTickets mapping goes through the same update_sql template in
-- event_mapper_surface_sql. That template ends:
--
--     WHERE gt_event_id = $1::bigint AND tevo_event_id IS NULL
--
-- "tevo_event_id IS NULL" stops the writer OVERWRITING a mapping. It does nothing at all about a
-- SECOND GoTickets row claiming a TEvo event that a DIFFERENT row already holds. One TEvo event
-- can therefore accumulate any number of GoTickets owners, and nothing anywhere complains.
--
-- MEASURED 2026-09-15: TEvo events claimed by more than one GoTickets row went 134 -> 201 -> 212
-- across a single afternoon. The timestamps place the cause here rather than anywhere else: the
-- evo_gt pipeline wrote at 19:34:21, and a scheduled matcher routed through this template wrote
-- the SAME TEvo events onto DIFFERENT GoTickets rows at 19:35:00 -- 39 seconds later. Among them
-- Minnesota Orchestra, Joe Gatto, Rouge, Emo Night Brooklyn, Robert Morris hockey.
--
-- evo_gt_pipeline_match already carries this guard and has never produced a duplicate: of the 212,
-- not one carries evo_gt_v2_venue1to1. This migration moves the same condition into the shared
-- template so every matcher inherits it -- venue_24h_performer (189 -> 458 mappings today),
-- tz_name_day_exact, instant_performer and anything added later.
--
-- ============================================================================================
-- WHAT THIS DOES NOT DO
-- ============================================================================================
-- It does NOT touch the 212 duplicates that already exist. Choosing which of two claimants is
-- right is a judgement about other matchers' output, and this migration is not the place to make
-- it silently -- evo_gt_report_double_claims() below reports them for an operator instead.
--
-- It also only fixes the gotickets_event surface, which is the one that was MEASURED. The same
-- template shape appears for sg_events_canonical, vivid_orders, tickpick_orders and others, and
-- very likely has the same hole -- but "likely" is not a measurement, and widening an unverified
-- fix across five surfaces at once is how a small correct change becomes an incident. Measure
-- those separately.

CREATE OR REPLACE FUNCTION public.event_mapper_surface_sql(p_surface text, p_horizon_days int DEFAULT 180)
RETURNS TABLE(select_sql text, update_sql text, key_type text)
LANGUAGE plpgsql IMMUTABLE
AS $fn$
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
      select_sql := $q$SELECT tp_order_id AS row_key, 'tickpick'::text AS source, NULL::bigint AS source_event_id, event_name, NULL::text AS performer,
                              NULL::text AS venue_name, NULL::text AS venue_city, NULL::text AS venue_state, event_date::date AS local_date, event_date AS event_time_utc,
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
END $fn$;
-- --------------------------------------------------------------------------------------------
-- reporter for the duplicates that already exist
-- --------------------------------------------------------------------------------------------
-- Read-only on purpose. It names the claimants, which matcher wrote each, and when -- everything
-- needed to decide, and nothing that decides on its own.
CREATE OR REPLACE FUNCTION public.evo_gt_report_double_claims(p_limit int DEFAULT 200)
RETURNS TABLE (
  tevo_event_id bigint,
  tevo_event_name text,
  tevo_occurs_at_local text,
  claimants int,
  detail jsonb)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
  WITH d AS (
    SELECT g.tevo_event_id, count(*)::int AS claimants
      FROM public.gotickets_event g
     WHERE g.tevo_event_id IS NOT NULL
     GROUP BY 1 HAVING count(*) > 1)
  SELECT d.tevo_event_id,
         e.name,
         e.occurs_at_local,
         d.claimants,
         (SELECT jsonb_agg(jsonb_build_object(
                   'gt_event_id', g2.gt_event_id, 'gt_name', g2.name,
                   'gt_venue', g2.venue_name, 'gt_time_utc', g2.event_time_utc,
                   'mapped_via', g2.mapped_via, 'map_score', g2.map_score,
                   'mapped_at', g2.mapped_at)
                 ORDER BY g2.mapped_at)
            FROM public.gotickets_event g2 WHERE g2.tevo_event_id = d.tevo_event_id)
    FROM d
    LEFT JOIN public.events e ON e.id = d.tevo_event_id
   ORDER BY d.claimants DESC, d.tevo_event_id
   LIMIT p_limit;
$fn$;

REVOKE ALL ON FUNCTION public.evo_gt_report_double_claims(int) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.evo_gt_report_double_claims(int) TO service_role;

COMMENT ON FUNCTION public.evo_gt_report_double_claims(int) IS
  'Read-only report of TEvo events claimed by more than one GoTickets row, with the matcher and timestamp behind each claim. 212 of them as of 2026-09-15, none written by evo_gt_v2_venue1to1. Deliberately does not resolve them: picking a winner is a judgement about another matcher''s output (mig 20260915260000).';

-- VERIFIED ON APPLY TO PROD: (pending -- still not applied to prod)
--
-- ==============================================================================================
-- EXECUTED ON A LOCAL POSTGRES 16.13, 2026-09-16 -- FIRST EXECUTION OF THIS FILE ANYWHERE
-- ==============================================================================================
-- Supabase has been unreachable since this was written, so it was run against a local cluster
-- carrying the real column shapes of gotickets_event, events, gotickets_purchases,
-- seatgeek_purchases, sg_events_canonical, tickpick_orders, vivid_orders and
-- cross_source_venue_map, over a 107,341-event synthetic catalogue with 26,612 GT mappings.
--
-- ⚠ THIS IS NOT THE PROD CHECK. The prod precondition below is UNCHANGED and still mandatory: the
-- live event_mapper_surface_sql body must be md5-compared against the copy reproduced here before
-- applying, or out-of-band drift is silently reverted. Running locally cannot detect prod drift --
-- it only proves the file itself is sound.
--
--   APPLIES CLEAN                          yes (2 functions, REVOKE, GRANT, COMMENT)
--   GUARD PRESENT IN TEMPLATE              update_sql for gotickets_event contains NOT EXISTS
--
--   THE GUARD ACTUALLY BLOCKS A SECOND CLAIMANT -- two unmapped GoTickets rows raced for one
--   unheld TEvo event by EXECUTEing the shared template, exactly as a scheduled matcher does:
--     claimants of tevo 99999 at start      0
--     first claim  (gt 500001, matcher_a)   1 row written
--     second claim (gt 500002, matcher_b)   0 rows written
--     claimants after both attempts         1  (winner gt_event_id 500001)
--   Before this change the second write would also have landed, because the template's
--   "AND tevo_event_id IS NULL" only stops a row OVERWRITING its own mapping -- it says nothing
--   about a different row claiming an event someone else already holds.
--
--   evo_gt_report_double_claims(5) -- read-only -- against two deliberately manufactured
--   duplicates (written directly, bypassing the template) plus one pre-existing:
--     returned the TEvo event with claimants = 3 and a detail array naming every claimant's
--     gt_event_id, gt_name, mapped_via and mapped_at, which is what lets an operator decide which
--     claim wins. It resolves nothing by itself, by design.
--
--   NOT TESTED HERE, and not testable here: the real-world proof that the bleed has STOPPED.
--   That is a prod measurement -- re-count double-claimed TEvo events an hour after applying and
--   confirm it has stopped rising from 212. Nothing local can substitute for it.
--
-- A NOTE ON CI. supabase-rls.yml's migrations-from-zero job is continue-on-error (informational),
-- and on the 2026-09-16 run its database never started ("connection to 127.0.0.1:54322 refused",
-- 18 errors, exit code 1) while the check still reported success. A green tick on that job is not
-- evidence that any migration applies. This block is.

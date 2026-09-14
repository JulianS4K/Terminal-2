-- ============================================================================
-- Migration 20260911161000 — our_purchases_map(): map the unmapped (event match + AQ matcher)
--
-- Lane:     A1 (data plane) serving D0's deals surface
-- Touches:  seatgeek_purchases, gotickets_purchases (+map_score column) ·
--           our_purchases_map() (CREATE OR REPLACE)
--           Reads: sg_events_canonical, aq_event_map, gotickets_event, events,
--                  cross_source_venue_resolve(), match_to_aq_event_id()
-- Pre-reqs: 20260911160500 (purchase books), 20260911160700
--
-- Already applied to prod · via MCP 2026-09-11 (operator: "Map the unmapped").
--
-- WHY. The first drain left 295 of 633 GoTickets purchases without a tevo_event_id:
-- every one of them is a PAST event, and the hub-id resolvers (gotickets_event,
-- aq_event_map.gotickets_event_id) only carry the catalogue's forward window (69 of
-- the 295 had a catalogue row, 3 an AQ row). Dry-run 2026-09-11 over those 295:
--   * EVENT MATCH  — same venue (name ILIKE, or cross_source_venue_resolve → venue_id),
--                    same local date, name-token overlap >= 0.6 against `events`:
--                    238 unique, 8 ambiguous (kept unmapped), 3 venue+day but name miss;
--   * AQ MATCHER   — match_to_aq_event_id('gotickets', …) 4-tier: 179 matched an AQ
--                    row, 160 of those carry a tevo id;
--   * still unmapped after both: 48 — World Cup matches, Broadway, small club shows,
--                    college football: events we do not carry in `events` at all.
-- Resolver order: hub ids (as before) → unique event match → AQ matcher. `mapped_via`
-- records the winner; `map_score` the token overlap (event match) or matcher
-- confidence (AQ). Ambiguous = never auto-mapped. Same logic for SeatGeek purchases
-- (event.location + start_data) so the book maps the day its scope is granted.
-- Purchases only — no hub write (aq_link_gotickets_by_event_match owns that).
--
-- READ-ONLY upstream: no API call. ROLLBACK: re-apply our_purchases_map() from mig
-- 20260911160500; ALTER TABLE … DROP COLUMN map_score (both tables).
-- ============================================================================

ALTER TABLE public.seatgeek_purchases  ADD COLUMN IF NOT EXISTS map_score numeric;
ALTER TABLE public.gotickets_purchases ADD COLUMN IF NOT EXISTS map_score numeric;

CREATE OR REPLACE FUNCTION public.our_purchases_map()
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public','pg_temp'
AS $fn$
DECLARE v_sg int := 0; v_gt int := 0; v_gt_ev int := 0; v_gt_aq int := 0; v_sg_ev int := 0; v_sg_aq int := 0;
BEGIN
  IF current_user NOT IN ('service_role','postgres','supabase_admin') THEN
    RAISE EXCEPTION 'forbidden: %', current_user USING ERRCODE = '42501';
  END IF;
  PERFORM set_config('statement_timeout', '150000', true);

  -- ── 1. Hub ids (unchanged) ─────────────────────────────────────────────────
  WITH m AS (
    SELECT p.order_id, coalesce(c.tevo_event_id, a.tevo_event_id) AS tevo,
           CASE WHEN c.tevo_event_id IS NOT NULL THEN 'sg_events_canonical'
                WHEN a.tevo_event_id IS NOT NULL THEN 'aq_event_map' END AS via
    FROM public.seatgeek_purchases p
    LEFT JOIN LATERAL (SELECT tevo_event_id FROM public.sg_events_canonical x WHERE x.sg_event_id = p.sg_event_id AND x.tevo_event_id IS NOT NULL LIMIT 1) c ON true
    LEFT JOIN LATERAL (SELECT tevo_event_id FROM public.aq_event_map x WHERE x.sg_event_id = p.sg_event_id AND x.tevo_event_id IS NOT NULL LIMIT 1) a ON true
    WHERE p.tevo_event_id IS NULL AND p.sg_event_id IS NOT NULL
  ), u AS (
    UPDATE public.seatgeek_purchases p SET tevo_event_id = m.tevo, mapped_via = m.via, map_score = 1, updated_at = now()
    FROM m WHERE m.order_id = p.order_id AND m.tevo IS NOT NULL RETURNING 1
  ) SELECT count(*) INTO v_sg FROM u;

  WITH m AS (
    SELECT p.gt_purchase_id, coalesce(g.tevo_event_id, a.tevo_event_id) AS tevo,
           CASE WHEN g.tevo_event_id IS NOT NULL THEN 'gotickets_event'
                WHEN a.tevo_event_id IS NOT NULL THEN 'aq_event_map' END AS via
    FROM public.gotickets_purchases p
    LEFT JOIN LATERAL (SELECT tevo_event_id FROM public.gotickets_event x WHERE x.gt_event_id = p.gt_event_id AND x.tevo_event_id IS NOT NULL LIMIT 1) g ON true
    LEFT JOIN LATERAL (SELECT tevo_event_id FROM public.aq_event_map x WHERE x.gotickets_event_id = p.gt_event_id AND x.tevo_event_id IS NOT NULL LIMIT 1) a ON true
    WHERE p.tevo_event_id IS NULL AND p.gt_event_id IS NOT NULL
  ), u AS (
    UPDATE public.gotickets_purchases p SET tevo_event_id = m.tevo, mapped_via = m.via, map_score = 1, updated_at = now()
    FROM m WHERE m.gt_purchase_id = p.gt_purchase_id AND m.tevo IS NOT NULL RETURNING 1
  ) SELECT count(*) INTO v_gt FROM u;

  -- ── 2. Unique event match: venue + local date + name-token overlap ≥ 0.6 ──
  -- GoTickets
  WITH u AS (
    SELECT gt_purchase_id, event_name, venue_name, venue_city, venue_state, event_time_local::date AS ed,
           lower(regexp_replace(regexp_replace(event_name, '\s*\(.*?\)\s*', ' ', 'g'), '[^a-z0-9 ]', ' ', 'gi')) AS nm
    FROM public.gotickets_purchases WHERE tevo_event_id IS NULL AND event_time_local IS NOT NULL AND venue_name IS NOT NULL
  ),
  cand AS (
    SELECT u.gt_purchase_id, e.id AS tevo, lower(regexp_replace(e.name, '[^a-z0-9 ]', ' ', 'gi')) AS enm, u.nm
    FROM u JOIN public.events e
      ON left(e.occurs_at_local, 10) = u.ed::text
     AND (e.venue_name ILIKE u.venue_name OR e.venue_id = public.cross_source_venue_resolve(u.venue_name, u.venue_city, u.venue_state))
  ),
  scored AS (
    SELECT c.gt_purchase_id, c.tevo,
      (SELECT count(*) FROM unnest(string_to_array(c.nm, ' ')) t WHERE length(t) > 2 AND c.enm ~ ('\m' || t || '\M'))::numeric
        / NULLIF((SELECT count(*) FROM unnest(string_to_array(c.nm, ' ')) t WHERE length(t) > 2), 0) AS overlap
    FROM cand c
  ),
  best AS (
    SELECT gt_purchase_id, count(*) FILTER (WHERE overlap >= 0.6) AS n_good,
           (array_agg(tevo ORDER BY overlap DESC))[1] AS tevo, max(overlap) AS score
    FROM scored GROUP BY 1
  ),
  up AS (
    UPDATE public.gotickets_purchases p SET tevo_event_id = b.tevo, mapped_via = 'event_match', map_score = round(b.score, 3), updated_at = now()
    FROM best b WHERE b.gt_purchase_id = p.gt_purchase_id AND b.n_good = 1 RETURNING 1
  ) SELECT count(*) INTO v_gt_ev FROM up;

  -- SeatGeek (event.location is the venue string; start_data the local start)
  WITH u AS (
    SELECT order_id, event_name, event_location AS venue_name, event_start::date AS ed,
           lower(regexp_replace(regexp_replace(event_name, '\s*\(.*?\)\s*', ' ', 'g'), '[^a-z0-9 ]', ' ', 'gi')) AS nm
    FROM public.seatgeek_purchases WHERE tevo_event_id IS NULL AND event_start IS NOT NULL AND event_location IS NOT NULL
  ),
  cand AS (
    SELECT u.order_id, e.id AS tevo, lower(regexp_replace(e.name, '[^a-z0-9 ]', ' ', 'gi')) AS enm, u.nm
    FROM u JOIN public.events e
      ON left(e.occurs_at_local, 10) = u.ed::text
     AND (e.venue_name ILIKE u.venue_name OR e.venue_id = public.cross_source_venue_resolve(u.venue_name, NULL, NULL))
  ),
  scored AS (
    SELECT c.order_id, c.tevo,
      (SELECT count(*) FROM unnest(string_to_array(c.nm, ' ')) t WHERE length(t) > 2 AND c.enm ~ ('\m' || t || '\M'))::numeric
        / NULLIF((SELECT count(*) FROM unnest(string_to_array(c.nm, ' ')) t WHERE length(t) > 2), 0) AS overlap
    FROM cand c
  ),
  best AS (
    SELECT order_id, count(*) FILTER (WHERE overlap >= 0.6) AS n_good,
           (array_agg(tevo ORDER BY overlap DESC))[1] AS tevo, max(overlap) AS score
    FROM scored GROUP BY 1
  ),
  up AS (
    UPDATE public.seatgeek_purchases p SET tevo_event_id = b.tevo, mapped_via = 'event_match', map_score = round(b.score, 3), updated_at = now()
    FROM best b WHERE b.order_id = p.order_id AND b.n_good = 1 RETURNING 1
  ) SELECT count(*) INTO v_sg_ev FROM up;

  -- ── 3. AQ 4-tier matcher for what is left ─────────────────────────────────
  WITH u AS (
    SELECT gt_purchase_id, gt_event_id, event_name, venue_name, event_time_local::date AS ed
    FROM public.gotickets_purchases WHERE tevo_event_id IS NULL AND event_time_local IS NOT NULL
  ),
  m AS (
    SELECT u.gt_purchase_id, a.tevo_event_id AS tevo, r.confidence
    FROM u
    JOIN LATERAL public.match_to_aq_event_id('gotickets', u.gt_event_id, u.event_name, u.venue_name, u.ed::timestamptz, NULL, NULL, NULL) r ON true
    JOIN public.aq_event_map a ON a.aq_short_event_id = r.aq_short_event_id AND a.tevo_event_id IS NOT NULL
  ),
  up AS (
    UPDATE public.gotickets_purchases p SET tevo_event_id = m.tevo, mapped_via = 'aq_matcher', map_score = round(m.confidence, 3), updated_at = now()
    FROM m WHERE m.gt_purchase_id = p.gt_purchase_id RETURNING 1
  ) SELECT count(*) INTO v_gt_aq FROM up;

  WITH u AS (
    SELECT order_id, sg_event_id, event_name, event_location, event_start::date AS ed
    FROM public.seatgeek_purchases WHERE tevo_event_id IS NULL AND event_start IS NOT NULL
  ),
  m AS (
    SELECT u.order_id, a.tevo_event_id AS tevo, r.confidence
    FROM u
    JOIN LATERAL public.match_to_aq_event_id('seatgeek', u.sg_event_id, u.event_name, u.event_location, u.ed::timestamptz, NULL, NULL, NULL) r ON true
    JOIN public.aq_event_map a ON a.aq_short_event_id = r.aq_short_event_id AND a.tevo_event_id IS NOT NULL
  ),
  up AS (
    UPDATE public.seatgeek_purchases p SET tevo_event_id = m.tevo, mapped_via = 'aq_matcher', map_score = round(m.confidence, 3), updated_at = now()
    FROM m WHERE m.order_id = p.order_id RETURNING 1
  ) SELECT count(*) INTO v_sg_aq FROM up;

  RETURN jsonb_build_object(
    'sg_mapped_now', v_sg + v_sg_ev + v_sg_aq, 'gt_mapped_now', v_gt + v_gt_ev + v_gt_aq,
    'gt_by', jsonb_build_object('hub', v_gt, 'event_match', v_gt_ev, 'aq_matcher', v_gt_aq),
    'sg_by', jsonb_build_object('hub', v_sg, 'event_match', v_sg_ev, 'aq_matcher', v_sg_aq),
    'sg_unmapped', (SELECT count(*) FROM public.seatgeek_purchases WHERE tevo_event_id IS NULL),
    'gt_unmapped', (SELECT count(*) FROM public.gotickets_purchases WHERE tevo_event_id IS NULL));
END $fn$;
COMMENT ON FUNCTION public.our_purchases_map() IS
  'Fill tevo_event_id on unmapped purchases, in order: hub ids (sg_events_canonical / gotickets_event / aq_event_map) → unique event match (venue + local date + name-token overlap >= 0.6 against events) → match_to_aq_event_id 4-tier. Ambiguous matches stay unmapped. mapped_via + map_score record the resolver. Idempotent; run by every drain. A1 mig 20260911161000.';

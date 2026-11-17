-- Migration 20260911010000 · level:secondary-sales · lane:D7 · writes:sg_events_canonical,seatgeek_event_xref · reads:aq_event_map,events · pre:20260910140000
--
-- Already applied to prod · via MCP 2026-09-11 under operator direction.
-- ============================================================================
-- Migration 20260911010000 — SeatGeek on-demand pull: register hub-resolved events
--
-- Lane: D7 · Pre-reqs: 20260910140000 (sg_listings_pull_on_demand), 20260910640000
--
-- ── THE GAP ────────────────────────────────────────────────────────────────
-- sg_listings_pull_on_demand() resolves an SG event id two ways: from
-- sg_events_canonical, or — failing that — from aq_event_map (the hub). Then
-- it refuses to queue any id that is NOT in sg_events_canonical, for a good
-- reason it states in its own comment: seatgeek_listings_snapshots.sg_event_id
-- has a FOREIGN KEY to sg_events_canonical, so a non-canonical id would 23503
-- on write and abort the drain's WHOLE batch.
--
-- Net effect: the hub fallback can resolve an id but never fire it. Measured
-- 2026-09-11 on the open N2S book: 3 of 61 open events (two Knicks games at
-- MSG, Tommee Profitt at Bridgestone; 4 obligations) were hub-resolvable,
-- not canonical, and therefore never polled on SeatGeek at all. Across the
-- hub, 3,860 (sg, tevo) pairs have no xref row — this pattern recurs.
--
-- A second, quieter half of the same gap: the drain (sg_broker_listings_
-- process) stamps tevo_event_id on each snapshot from seatgeek_event_xref,
-- not from the hub. Without an xref row the snapshot lands with a NULL
-- tevo_event_id, and n2s_cover_candidates joins SG snapshots BY tevo_event_id,
-- so the listings would be invisible to the matcher even once pulled.
--
-- ── THE FIX ────────────────────────────────────────────────────────────────
-- Before the queue loop, REGISTER any hub-resolved-but-uncanonical event:
--   1. sg_events_canonical  — a minimal row (name/date/venue from `events`,
--      tevo_event_id from the hub, match_method 'aq_hub_n2s', status matched).
--      ON CONFLICT DO NOTHING: an existing canonical row is never touched.
--   2. seatgeek_event_xref  — the (tevo, sg) pair the drain reads, for rows
--      registered by step 1 only. PK is tevo_event_id; DO NOTHING on conflict.
-- The existing canonical-only guard then passes on its own terms. Nothing
-- about the FK, the drain, or the guard changes; the data they need simply
-- exists first.
--
-- ⚠ CROSS-LANE: sg_events_canonical and seatgeek_event_xref are A1's SG data
-- plane. This is an operator-directed write (2026-09-11), scoped to events
-- the N2S puller is asked about, keyed on the hub A1 already maintains, and
-- never overwriting a row either table already has. Flagged to A1 in bot_chat.
-- ============================================================================

DO $do$
DECLARE d text; n text;
BEGIN
  d := pg_get_functiondef('public.sg_listings_pull_on_demand(bigint[], integer, interval)'::regprocedure);

  IF position('aq_hub_n2s' in d) > 0 THEN
    RAISE EXCEPTION 'sg_listings_pull_on_demand already registers hub events — 20260911010000 is applied; do not re-run';
  END IF;

  n := E'  FOR r IN\n    WITH want AS';
  IF (length(d) - length(replace(d, n, ''))) / length(n) <> 1 THEN
    RAISE EXCEPTION 'anchor (FOR r IN / WITH want AS) not found exactly once — body drifted, re-derive this migration';
  END IF;

  d := replace(d, n,
    E'  -- Register hub-resolved events that the canonical table has never seen,\n' ||
    E'  -- so the FK on seatgeek_listings_snapshots and the xref the drain reads\n' ||
    E'  -- both exist BEFORE anything is queued (20260911010000). Existing rows\n' ||
    E'  -- in either table are never touched.\n' ||
    E'  INSERT INTO public.sg_events_canonical\n' ||
    E'    (sg_event_id, sg_event_name, sg_event_date, sg_datetime_utc, sg_venue_name,\n' ||
    E'     tevo_event_id, match_method, match_confidence, matched_at, match_status)\n' ||
    E'  SELECT a.sg_event_id, e.name, left(e.occurs_at_local, 10)::date,\n' ||
    E'         CASE WHEN e.occurs_at_local ~ ''[+-]\\d\\d:\\d\\d$'' THEN e.occurs_at_local::timestamptz END,\n' ||
    E'         e.venue_name, e.id, ''aq_hub_n2s'', 1.0, now(), ''matched''\n' ||
    E'    FROM unnest(p_tevo_event_ids) AS t(tevo_event_id)\n' ||
    E'    JOIN public.events e ON e.id = t.tevo_event_id\n' ||
    E'    JOIN LATERAL (SELECT a.sg_event_id FROM public.aq_event_map a\n' ||
    E'                   WHERE a.tevo_event_id = t.tevo_event_id AND a.sg_event_id IS NOT NULL\n' ||
    E'                   ORDER BY a.sg_event_id LIMIT 1) a ON true\n' ||
    E'   WHERE e.occurs_at_local ~ ''^\\d{4}-\\d\\d-\\d\\dT''\n' ||
    E'     AND NOT EXISTS (SELECT 1 FROM public.sg_events_canonical c WHERE c.tevo_event_id = t.tevo_event_id)\n' ||
    E'  ON CONFLICT (sg_event_id) DO NOTHING;\n' ||
    E'\n' ||
    E'  INSERT INTO public.seatgeek_event_xref\n' ||
    E'    (tevo_event_id, sg_event_id, sg_event_name, matched_at, match_method, match_confidence)\n' ||
    E'  SELECT c.tevo_event_id, c.sg_event_id, c.sg_event_name, now(), ''aq_hub_n2s'', 1.0\n' ||
    E'    FROM public.sg_events_canonical c\n' ||
    E'   WHERE c.tevo_event_id = ANY(p_tevo_event_ids) AND c.match_method = ''aq_hub_n2s''\n' ||
    E'  ON CONFLICT (tevo_event_id) DO NOTHING;\n' ||
    E'\n' || n);

  EXECUTE d;
END $do$;

COMMENT ON FUNCTION public.sg_listings_pull_on_demand(bigint[], integer, interval) IS
  'Queue SeatGeek broker /listings pulls for the given TEvo events (GET only; RULE 2). Resolves the SG id from sg_events_canonical, else from aq_event_map; as of 20260911010000 a hub-resolved id that the canonical table has never seen is REGISTERED first (minimal sg_events_canonical row, match_method aq_hub_n2s, plus the seatgeek_event_xref pair the drain stamps tevo_event_id from), so the FK on seatgeek_listings_snapshots holds and the matcher can see the rows. Never overwrites an existing canonical or xref row. Skips events with a snapshot fresher than p_freshness; caps at p_max_events per call.';

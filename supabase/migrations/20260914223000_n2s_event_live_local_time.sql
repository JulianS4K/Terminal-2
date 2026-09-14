-- ============================================================================
-- Migration 20260914223000 — N2S: an event is live by LOCAL start time, not UTC date
--
-- Lane:     D7 (n2s_* schema; reads A1's events + venue_assets)
-- Touches:  W: n2s_event_live() (new), every n2s_* function carrying the
--              `event_dt::date >= current_date` predicate (rewritten in place),
--              v_n2s_orders (WHERE clause)
--           R: events.occurs_at_local, venue_assets.nws_time_zone
-- Pre-reqs: 20260911020000 (n2s_gt_map_by_name), 20260910650000 (n2s_cover_candidates)
--
-- ── The bug ─────────────────────────────────────────────────────────────────
-- n2s_items.event_dt is the CRM's venue-LOCAL start time. Nine call sites
-- gated "is this obligation still worth working" as
--     event_dt::date >= current_date
-- and current_date is the UTC date. At 00:00 UTC — 8pm Eastern — every
-- evening event on the US calendar day that just ended in UTC fell out of the
-- book: no source pull, no cover candidates, hidden from v_n2s_orders.
--
-- Measured on the 09-13 NFL Sunday cohort: 88 orders never got a pull and
-- never got a cover for exactly this reason. Cowboys at Giants (SNF) kicked
-- off 8:20pm ET; 64 orders arrived from 7:57pm ET, 27 before kickoff, and all
-- were invisible from 8:00pm ET. Under the rule below all 88 evaluate live at
-- their alert time; under the old rule 4 did.
--
-- ── The rule: n2s_event_live(event_dt, tevo_event_id) ───────────────────────
-- An obligation is live while its event has not started more than p_grace
-- (4h) ago, resolved in this order:
--   1. TEvo carries a real instant  (events.occurs_at_local with a UTC offset,
--      193 of 235 open N2S events)      → occurs_at_local::timestamptz + grace > now()
--   2. venue timezone known            (venue_assets.nws_time_zone, 72 of 115
--      N2S venues; all 7 distinct values are valid pg_timezone_names)
--                                      → (event_dt AT TIME ZONE tz) + grace > now()
--   3. otherwise                       → event_dt read as America/Los_Angeles.
--      The westernmost mainland zone is the SAFE fallback: an Eastern event
--      gets 3 extra hours of life, nothing is ever dropped early.
-- A midnight event_dt is TEvo's "time TBD" marker, so it is treated as the END
-- of that local day rather than its start.
--
-- ── Why the rewrite is mechanical ───────────────────────────────────────────
-- The predicate appears in eight n2s_* functions with three alias spellings
-- (i., n., bare). Two of those functions (n2s_pipeline_tick,
-- n2s_order_identity_pull) are AHEAD of this repo — they were applied without
-- a migration file — so re-pasting bodies here would silently revert them.
-- Instead the DO block below takes each function's LIVE definition and
-- rewrites only the predicate. A post-check raises if any n2s_* function still
-- carries the old form, so a partial rewrite cannot land quietly.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.n2s_event_live(
  p_event_dt      timestamp without time zone,
  p_tevo_event_id bigint,
  p_grace         interval DEFAULT interval '4 hours')
RETURNS boolean
LANGUAGE sql
STABLE
SET search_path TO 'public', 'pg_temp'
AS $function$
  WITH e AS (
    SELECT ev.occurs_at_local, ev.venue_id
      FROM public.events ev WHERE ev.id = p_tevo_event_id
  ),
  tz AS (
    SELECT va.nws_time_zone
      FROM e JOIN public.venue_assets va ON va.tevo_venue_id = e.venue_id
     WHERE va.nws_time_zone IS NOT NULL
     LIMIT 1
  ),
  s AS (
    -- a midnight timestamp is "time TBD": keep it live through the whole local day
    SELECT CASE WHEN p_event_dt IS NULL THEN NULL
                WHEN p_event_dt::time = time '00:00' THEN (p_event_dt::date + 1)::timestamp
                ELSE p_event_dt END AS t
  )
  SELECT COALESCE(
    (SELECT (e.occurs_at_local::timestamptz + p_grace) > now()
       FROM e
      WHERE e.occurs_at_local ~ '^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d[+-]\d\d:\d\d$'
        AND e.occurs_at_local !~ 'T00:00:00'),
    (SELECT ((s.t AT TIME ZONE tz.nws_time_zone) + p_grace) > now()
       FROM s, tz WHERE s.t IS NOT NULL),
    (SELECT ((s.t AT TIME ZONE 'America/Los_Angeles') + p_grace) > now()
       FROM s WHERE s.t IS NOT NULL),
    false);
$function$;

COMMENT ON FUNCTION public.n2s_event_live(timestamp, bigint, interval) IS
  'Is this N2S obligation''s event still live? True until the event started more than p_grace (4h) ago, by LOCAL time: TEvo''s offset-carrying occurs_at_local when present, else venue_assets.nws_time_zone, else event_dt read as America/Los_Angeles (the safe, never-early fallback). Replaces the `event_dt::date >= current_date` predicate that dropped every US evening event at 00:00 UTC (8pm ET). A midnight event_dt is "time TBD" and is live through the whole local day.';

REVOKE ALL ON FUNCTION public.n2s_event_live(timestamp, bigint, interval) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.n2s_event_live(timestamp, bigint, interval) TO authenticated, service_role;

-- ── Rewrite every live n2s_* function that carries the old predicate ────────
DO $do$
DECLARE
  r      record;
  v_src  text;
  v_new  text;
  v_n    int := 0;
BEGIN
  FOR r IN
    SELECT p.oid, p.proname
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public' AND p.prokind = 'f'
       AND p.proname LIKE 'n2s\_%'
       AND pg_get_functiondef(p.oid) LIKE '%event_dt::date >= current_date%'
     ORDER BY p.proname
  LOOP
    v_src := pg_get_functiondef(r.oid);
    -- "<alias>.event_dt::date >= current_date"  →  "public.n2s_event_live(<alias>.event_dt, <alias>.tevo_event_id)"
    -- the alias group is optional so the bare spelling rewrites too.
    v_new := regexp_replace(
               v_src,
               '(\m[a-z0-9_]+\.)?event_dt::date >= current_date',
               'public.n2s_event_live(\1event_dt, \1tevo_event_id)',
               'g');
    IF v_new = v_src THEN
      RAISE EXCEPTION 'n2s_event_live rewrite: predicate matched LIKE but not the regex in %', r.proname;
    END IF;
    EXECUTE v_new;
    v_n := v_n + 1;
    RAISE NOTICE 'n2s_event_live: rewrote %', r.proname;
  END LOOP;
  RAISE NOTICE 'n2s_event_live: % function(s) rewritten', v_n;
END
$do$;

-- ── The view carries the predicate in its own WHERE; same column list ───────
CREATE OR REPLACE VIEW public.v_n2s_orders AS
 SELECT n.n2s_id,
    n.order_number,
    n.s4k_source,
    n.status AS n2s_status,
    n.status_label,
    n.fail_reason,
    n.timer_expired,
    n.alert_at,
    n.timer_expires_at,
    n.event_name,
    n.event_dt::date AS event_date,
    n.event_dt,
    n.venue,
    n.tevo_event_id,
    n.mapped_via,
    n.sources_pulled_at,
    n.section,
    n."row" AS order_row,
    n.qty AS quantity,
    n.price_per_ticket AS sold_ea,
    n.grand_total AS sold_total,
    c.sub_source,
    c.sub_listing_id,
    c.sub_section,
    c.sub_row,
    c.sub_qty,
    c.sub_ea,
    c.sub_total,
    c.cover_cost,
    c.rows_closer,
    c.buy_url,
    c.captured_at,
    c.cover_rank,
    c.fifo_position,
    c.refreshed_at,
    c.n2s_id IS NOT NULL AS has_cover,
        CASE
            WHEN c.n2s_id IS NOT NULL THEN NULL::text
            WHEN n.tevo_event_id IS NULL THEN 'unmapped'::text
            WHEN NOT (EXISTS ( SELECT 1
               FROM events e
              WHERE e.id = n.tevo_event_id)) THEN 'event_not_catalogued'::text
            WHEN n.sources_pulled_at IS NULL THEN 'awaiting_source_pull'::text
            ELSE 'no_match'::text
        END AS no_cover_reason,
    b.intent_id AS open_intent_id,
    b.requested_by AS open_intent_by,
    c.sub_avail,
    n.n2s_order_key,
    c.cover_gate,
    c.cover_label,
    c.order_zone,
    c.sub_zone,
    c.sub_notes,
    c.sub_view
   FROM n2s_items n
     LEFT JOIN n2s_cover_queue c ON c.n2s_id = n.n2s_id
     LEFT JOIN n2s_buy_intent b ON b.n2s_id = n.n2s_id AND b.status = 'requested'::text
  WHERE NOT n.is_terminal AND public.n2s_event_live(n.event_dt, n.tevo_event_id);

-- ── Post-check: nothing n2s_* may still carry the UTC-date predicate ────────
DO $do$
DECLARE v_left text;
BEGIN
  SELECT string_agg(p.proname, ', ') INTO v_left
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.prokind = 'f' AND p.proname LIKE 'n2s\_%'
     AND pg_get_functiondef(p.oid) LIKE '%event_dt::date >= current_date%';
  IF v_left IS NOT NULL THEN
    RAISE EXCEPTION 'n2s_event_live: old predicate still present in: %', v_left;
  END IF;
  IF pg_get_viewdef('public.v_n2s_orders'::regclass) ILIKE '%event_dt%CURRENT_DATE%' THEN
    RAISE EXCEPTION 'n2s_event_live: v_n2s_orders still filters on the UTC date';
  END IF;
END
$do$;

-- Migration 20260615120000 · lane:D0 (author) → A1 (apply) · writes:event_watchlist (alter), event_watchlist_set_sg, event_watchlist_set_alert_sg, event_watchlist_add_world_cup, event_watchlist_list (replace), watchlist seed for julian@s4kent.com · reads:sg_events_canonical, aq_event_map, events, event_metrics, v_wc_price_latest · pre:20260606170000_watchlist_list_metrics · auth:operator-requested 2026-06-15 ("add all worldcup games to my watchlist"; design: EVO primary / SG secondary). REQUIRES A1 apply (ALTER TABLE + RPCs + seeds julian's rows).
--
-- D0 — make the per-user watchlist dual-keyed: EVO/TEvo PRIMARY, SeatGeek SECONDARY.
--
-- WHY: the 2026 World Cup is FIFA PRIMARY inventory carried by SeatGeek, NOT TEvo
-- resale. Of the 101 WC matches in sg_events_canonical, only 1 (Match 72) currently
-- resolves to a tevo_event_id via aq_event_map; the other 100 are SG-native and have
-- no TEvo id. event_watchlist was keyed on a NOT-NULL tevo_event_id, so those 100
-- could not be tracked. Per operator: use the TEvo id when one exists (primary key,
-- gets the live TEvo market on the event page + alerts), and fall back to the
-- SeatGeek id when it doesn't (secondary key, SG-native, no TEvo deep page).
--
-- DESIGN
--   • tevo_event_id becomes NULLABLE; new nullable sg_event_id column.
--   • A row must carry at least one id (CHECK). A tevo-mapped WC match stores BOTH
--     (tevo primary + sg secondary); an SG-native match stores sg only.
--   • Uniqueness: existing UNIQUE(user_email,tevo_event_id) stays (NULLs are
--     distinct, so many sg-only rows per user are fine); a partial unique index
--     guards (user_email, sg_event_id) for the sg-only rows.
--
-- DIGEST SAFETY (cross-lane note for A1): the A1-owned daily digest
-- (20260605200000) selects event_watchlist WHERE alert_enabled and joins events on
-- tevo_event_id. To avoid flooding it with empty SG-only lines (SG alert evaluation
-- is not wired yet), SG-only rows are seeded with alert_enabled=false. A defensive
-- "AND w.tevo_event_id IS NOT NULL" guard in build_watchlist_daily_email is left to
-- A1 (flagged via bot_chat) — this migration does not touch that A1-owned function.
-- The alert evaluator (20260605160000) does NOT read event_watchlist, so it is
-- unaffected.

-- ============================================================================
-- 1. Schema — dual-key the table
-- ============================================================================
ALTER TABLE public.event_watchlist
  ADD COLUMN IF NOT EXISTS sg_event_id bigint;

ALTER TABLE public.event_watchlist
  ALTER COLUMN tevo_event_id DROP NOT NULL;

ALTER TABLE public.event_watchlist
  DROP CONSTRAINT IF EXISTS event_watchlist_has_key;
ALTER TABLE public.event_watchlist
  ADD CONSTRAINT event_watchlist_has_key
  CHECK (tevo_event_id IS NOT NULL OR sg_event_id IS NOT NULL);

-- One sg-only row per (user, sg event). The original UNIQUE(user_email,
-- tevo_event_id) still covers the tevo side (NULLs distinct → no collision).
CREATE UNIQUE INDEX IF NOT EXISTS event_watchlist_user_sg_uidx
  ON public.event_watchlist(user_email, sg_event_id)
  WHERE sg_event_id IS NOT NULL;

-- ============================================================================
-- 2. RPC — add / remove a SeatGeek-native event (resolves EVO id when mapped)
-- ============================================================================
CREATE OR REPLACE FUNCTION public.event_watchlist_set_sg(p_sg_event_id bigint, p_on boolean)
RETURNS boolean
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_email text := public._wl_require_email();
  v_tevo  bigint;
BEGIN
  -- EVO primary: if this SG event maps to a TEvo id, key on that too.
  SELECT m.tevo_event_id INTO v_tevo
  FROM public.aq_event_map m
  WHERE m.sg_event_id = p_sg_event_id AND m.tevo_event_id IS NOT NULL
  LIMIT 1;

  IF p_on THEN
    IF NOT EXISTS (
      SELECT 1 FROM public.event_watchlist w
      WHERE w.user_email = v_email
        AND (w.sg_event_id = p_sg_event_id
             OR (v_tevo IS NOT NULL AND w.tevo_event_id = v_tevo))
    ) THEN
      INSERT INTO public.event_watchlist
        (user_email, tevo_event_id, sg_event_id, event_name, occurs_at_local, venue_name, alert_enabled)
      SELECT v_email, v_tevo, c.sg_event_id, c.sg_event_name, c.sg_event_date::text, c.sg_venue_name,
             (v_tevo IS NOT NULL)   -- alerts on only when a TEvo market exists to evaluate
      FROM public.sg_events_canonical c
      WHERE c.sg_event_id = p_sg_event_id;
    END IF;
    RETURN true;
  ELSE
    DELETE FROM public.event_watchlist
    WHERE user_email = v_email
      AND (sg_event_id = p_sg_event_id
           OR (v_tevo IS NOT NULL AND tevo_event_id = v_tevo));
    RETURN false;
  END IF;
END;
$$;

-- ============================================================================
-- 3. RPC — mute / unmute alerts for an SG-keyed tracked event
-- ============================================================================
CREATE OR REPLACE FUNCTION public.event_watchlist_set_alert_sg(p_sg_event_id bigint, p_on boolean)
RETURNS boolean
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_email text := public._wl_require_email();
BEGIN
  UPDATE public.event_watchlist SET alert_enabled = p_on
  WHERE user_email = v_email AND sg_event_id = p_sg_event_id;
  RETURN p_on;
END;
$$;

-- ============================================================================
-- 4. RPC — bulk-add EVERY World Cup match to the caller's watchlist.
--    Idempotent; EVO id used as primary when mapped, SG id otherwise.
--    Returns the number of rows newly inserted.
-- ============================================================================
CREATE OR REPLACE FUNCTION public.event_watchlist_add_world_cup()
RETURNS integer
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_email text := public._wl_require_email();
  v_count integer;
BEGIN
  WITH wc AS (
    SELECT c.sg_event_id, c.sg_event_name, c.sg_event_date, c.sg_venue_name,
           (SELECT m.tevo_event_id FROM public.aq_event_map m
             WHERE m.sg_event_id = c.sg_event_id AND m.tevo_event_id IS NOT NULL
             LIMIT 1) AS tevo_event_id
    FROM public.sg_events_canonical c
    WHERE c.sg_event_name ILIKE '%world cup - match%'
  ),
  ins AS (
    INSERT INTO public.event_watchlist
      (user_email, tevo_event_id, sg_event_id, event_name, occurs_at_local, venue_name, alert_enabled)
    SELECT v_email, wc.tevo_event_id, wc.sg_event_id, wc.sg_event_name,
           wc.sg_event_date::text, wc.sg_venue_name, (wc.tevo_event_id IS NOT NULL)
    FROM wc
    WHERE NOT EXISTS (
      SELECT 1 FROM public.event_watchlist w
      WHERE w.user_email = v_email
        AND (w.sg_event_id = wc.sg_event_id
             OR (wc.tevo_event_id IS NOT NULL AND w.tevo_event_id = wc.tevo_event_id))
    )
    RETURNING 1
  )
  SELECT count(*) INTO v_count FROM ins;
  RETURN v_count;
END;
$$;

-- ============================================================================
-- 5. Replace event_watchlist_list — surface sg_event_id + SG fallback fields,
--    and (for SG-only rows) headline price from the WC daily board. TEvo
--    metrics path is unchanged (EVO primary).
-- ============================================================================
CREATE OR REPLACE FUNCTION public.event_watchlist_list()
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_email    text        := public._wl_require_email();
  v_bell     timestamptz := (date_trunc('day', now() AT TIME ZONE 'America/New_York')
                              + interval '12 hours') AT TIME ZONE 'America/New_York';
  v_basis    text;
  v_baseline timestamptz;
  v_rows     jsonb;
BEGIN
  IF now() >= v_bell THEN
    v_baseline := v_bell;                 v_basis := 'bell';
  ELSE
    v_baseline := now() - interval '24 hours'; v_basis := '24h';
  END IF;

  WITH wl AS (
    SELECT w.tevo_event_id AS eid, w.sg_event_id AS sgid, w.alert_enabled, w.added_at,
           w.event_name AS snap_name, w.occurs_at_local AS snap_occ, w.venue_name AS snap_venue
    FROM public.event_watchlist w
    WHERE w.user_email = v_email
  ),
  cur AS (
    SELECT DISTINCT ON (m.event_id)
      m.event_id, m.captured_at, m.getin_price, m.retail_median, m.retail_p90, m.tickets_count
    FROM public.event_metrics m JOIN wl ON wl.eid = m.event_id
    ORDER BY m.event_id, m.captured_at DESC
  ),
  base AS (
    SELECT DISTINCT ON (m.event_id)
      m.event_id, m.captured_at AS base_at, m.getin_price AS base_getin, m.retail_median AS base_median
    FROM public.event_metrics m JOIN wl ON wl.eid = m.event_id
    WHERE m.captured_at <= v_baseline
    ORDER BY m.event_id, m.captured_at DESC
  )
  SELECT coalesce(
           jsonb_agg(r ORDER BY (r->>'occurs_at_local') ASC NULLS LAST, (r->>'added_at') DESC),
           '[]'::jsonb)
    INTO v_rows
  FROM (
    SELECT jsonb_build_object(
      'tevo_event_id',   wl.eid,
      'sg_event_id',     wl.sgid,
      'source',          CASE WHEN wl.eid IS NOT NULL THEN 'tevo' ELSE 'seatgeek' END,
      'event_name',      coalesce(e.name, sc.sg_event_name, wl.snap_name),
      'occurs_at_local', coalesce(e.occurs_at_local, wl.snap_occ, sc.sg_event_date::text),
      'venue_name',      coalesce(e.venue_name, wl.snap_venue, sc.sg_venue_name),
      'venue_location',  e.venue_location,
      'performer',       e.primary_performer_name,
      'alert_enabled',   wl.alert_enabled,
      'added_at',        wl.added_at,
      'metrics', CASE
        WHEN c.event_id IS NOT NULL THEN jsonb_build_object(
          'getin',        round(c.getin_price),
          'median',       round(c.retail_median),
          'p90',          round(c.retail_p90),
          'tickets',      c.tickets_count,
          'd_getin',      CASE WHEN b.base_getin IS NOT NULL THEN round(c.getin_price - b.base_getin) END,
          'd_getin_pct',  CASE WHEN b.base_getin IS NOT NULL AND b.base_getin <> 0
                               THEN round((c.getin_price - b.base_getin) / b.base_getin * 100, 1) END,
          'd_median',     CASE WHEN b.base_median IS NOT NULL THEN round(c.retail_median - b.base_median) END,
          'd_median_pct', CASE WHEN b.base_median IS NOT NULL AND b.base_median <> 0
                               THEN round((c.retail_median - b.base_median) / b.base_median * 100, 1) END,
          'basis',        v_basis,
          'market',       'tevo',
          'cur_at',       c.captured_at,
          'base_at',      b.base_at)
        WHEN wp.sg_event_id IS NOT NULL THEN jsonb_build_object(
          'getin',        round(wp.allin_min),
          'median',       round(wp.allin_median),
          'p90',          round(wp.allin_p90),
          'tickets',      wp.tickets_count,
          'basis',        v_basis,
          'market',       'seatgeek',
          'cur_at',       wp.captured_at)
        ELSE NULL END
    ) AS r
    FROM wl
    LEFT JOIN public.events e               ON e.id = wl.eid
    LEFT JOIN cur c                         ON c.event_id = wl.eid
    LEFT JOIN base b                        ON b.event_id = wl.eid
    LEFT JOIN public.sg_events_canonical sc ON sc.sg_event_id = wl.sgid
    LEFT JOIN public.v_wc_price_latest wp   ON wp.sg_event_id = wl.sgid
  ) q;

  RETURN jsonb_build_object(
    'user_email',  v_email,
    'count',       jsonb_array_length(v_rows),
    'basis',       v_basis,
    'baseline_at', v_baseline,
    'items',       v_rows
  );
END;
$$;

-- ============================================================================
-- 6. Grants (mirror the existing watchlist RPC grants)
-- ============================================================================
REVOKE ALL ON FUNCTION public.event_watchlist_set_sg(bigint, boolean)       FROM PUBLIC;
REVOKE ALL ON FUNCTION public.event_watchlist_set_alert_sg(bigint, boolean) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.event_watchlist_add_world_cup()               FROM PUBLIC;
REVOKE ALL ON FUNCTION public.event_watchlist_list()                        FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.event_watchlist_set_sg(bigint, boolean)       TO authenticated;
GRANT EXECUTE ON FUNCTION public.event_watchlist_set_alert_sg(bigint, boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.event_watchlist_add_world_cup()               TO authenticated;
GRANT EXECUTE ON FUNCTION public.event_watchlist_list()                        TO authenticated;

-- ============================================================================
-- 7. Seed — add ALL World Cup matches to julian@s4kent.com's watchlist now
--    (the operator's request). Runs as owner during apply (no JWT), so it is a
--    direct INSERT rather than a call to the email-gated bulk RPC. Idempotent.
-- ============================================================================
WITH wc AS (
  SELECT c.sg_event_id, c.sg_event_name, c.sg_event_date, c.sg_venue_name,
         (SELECT m.tevo_event_id FROM public.aq_event_map m
           WHERE m.sg_event_id = c.sg_event_id AND m.tevo_event_id IS NOT NULL
           LIMIT 1) AS tevo_event_id
  FROM public.sg_events_canonical c
  WHERE c.sg_event_name ILIKE '%world cup - match%'
)
INSERT INTO public.event_watchlist
  (user_email, tevo_event_id, sg_event_id, event_name, occurs_at_local, venue_name, alert_enabled)
SELECT 'julian@s4kent.com', wc.tevo_event_id, wc.sg_event_id, wc.sg_event_name,
       wc.sg_event_date::text, wc.sg_venue_name, (wc.tevo_event_id IS NOT NULL)
FROM wc
WHERE NOT EXISTS (
  SELECT 1 FROM public.event_watchlist w
  WHERE w.user_email = 'julian@s4kent.com'
    AND (w.sg_event_id = wc.sg_event_id
         OR (wc.tevo_event_id IS NOT NULL AND w.tevo_event_id = wc.tevo_event_id))
);

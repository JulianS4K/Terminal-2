-- Migration 20260927040300 · level:secondary-sales · lane:D7 · writes:n2s_sg_current,n2s_evo_full_pulls,n2s_mkt_drain,n2s_cover_candidates,n2s_cover_queue_refresh,n2s_pull_events · reads:n2s_mkt_pull · pre:20260927030200
--
-- Already applied to prod · via MCP 2026-09-27 04:03 UTC under operator direction
-- ("Do both, test first"), after rolled-back dry runs: SeatGeek candidates 1 → 58
-- (28 orders), orders covered 16 → 30; EVO path identical on a frozen snapshot.
--
-- Finding: the terminal listing stores are change-only (EVO: collect-listings
-- "Wave 3" filter; SeatGeek: seatgeek_listings_dedup) but the cover search read
-- "the latest capture" as if it were the whole list — ~38 % of live EVO groups
-- and ~2 % of SeatGeek listings were visible.
-- INTERIM: the EVO half (collect-listings?full=1 → n2s_evo_full_pulls) needed an
-- edge-function deploy that was not made; 20260927041700 replaced it with a
-- direct signed EVO call and dropped n2s_evo_full_pulls.
-- ============================================================================

-- N2S covers read the FULL current inventory for EVO and SeatGeek.
-- Both terminal stores are change-only (EVO: collect-listings Wave-3 filter;
-- SeatGeek: seatgeek_listings_dedup), while n2s_cover_candidates read "the
-- latest capture" as if it were the whole list: 38% of live EVO groups and ~2%
-- of SeatGeek listings were visible on 2026-09-27.

CREATE TABLE IF NOT EXISTS public.n2s_sg_current (
  tevo_event_id       bigint NOT NULL,
  sg_event_id         bigint NOT NULL,
  display_id          text   NOT NULL,
  sglid               bigint,
  section             text,
  "row"               text,
  quantity            integer,
  retail_price_all_in numeric,
  splits              jsonb,
  is_broker_owned     boolean,
  has_limited_view    boolean,
  seller_notes        text,
  pulled_at           timestamptz NOT NULL,
  PRIMARY KEY (tevo_event_id, display_id)
);
ALTER TABLE public.n2s_sg_current ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.n2s_sg_current FROM PUBLIC, anon, authenticated;
COMMENT ON TABLE public.n2s_sg_current IS
  'Full current SeatGeek listing set per event, replaced on every N2S SeatGeek response (n2s_mkt_drain). The cover search reads SeatGeek from here: seatgeek_listings_snapshots is change-only.';

CREATE TABLE IF NOT EXISTS public.n2s_evo_full_pulls (
  event_id     bigint NOT NULL,
  captured_at  timestamptz NOT NULL,
  rows_written integer,
  PRIMARY KEY (event_id, captured_at)
);
ALTER TABLE public.n2s_evo_full_pulls ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.n2s_evo_full_pulls FROM PUBLIC, anon, authenticated;
COMMENT ON TABLE public.n2s_evo_full_pulls IS
  'EVO captures written by collect-listings?full=1 (the N2S pull): every live ticket group, not just changed ones. The cover search anchors on the latest one.';

DO $$
DECLARE
  v_def text; v_old text; v_new text;
BEGIN
  -- ── drain: every SeatGeek response replaces that event's current set ──
  v_def := pg_get_functiondef('public.n2s_mkt_drain'::regproc);
  IF md5(v_def) <> 'b09ee194ec94c525f04348c2f310b6bd' THEN
    RAISE EXCEPTION 'n2s_mkt_drain drifted — refusing';
  END IF;
  v_old := E'          ON CONFLICT DO NOTHING;\n          GET DIAGNOSTICS v_n = ROW_COUNT;\n';
  v_new := v_old || $x$
          DELETE FROM public.n2s_sg_current WHERE tevo_event_id = r.tevo_event_id;
          INSERT INTO public.n2s_sg_current (
            tevo_event_id, sg_event_id, display_id, sglid, section, "row", quantity,
            retail_price_all_in, splits, is_broker_owned, has_limited_view, seller_notes, pulled_at)
          SELECT DISTINCT ON (l->>'id')
                 r.tevo_event_id, r.mkt_event_id, l->>'id', NULLIF(l->>'sglid','')::bigint,
                 l->>'s', l->>'r', NULLIF(l->>'q','')::int, NULLIF(l->>'pf','')::numeric,
                 l->'sp', NULLIF(l->>'bo','')::boolean, NULLIF(l->>'lv','')::boolean,
                 l->>'pn', now()
            FROM jsonb_array_elements((r.content::jsonb) -> 'listings') AS l
           WHERE l->>'id' IS NOT NULL;
$x$;
  IF (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 THEN
    RAISE EXCEPTION 'n2s_mkt_drain: SeatGeek insert anchor not found exactly once';
  END IF;
  v_def := replace(v_def, v_old, v_new);
  v_old := E'  DELETE FROM public.n2s_mkt_pull WHERE fired_at < now() - interval ''3 days'';\n';
  IF position(v_old in v_def) = 0 THEN RAISE EXCEPTION 'n2s_mkt_drain: cleanup anchor missing'; END IF;
  v_def := replace(v_def, v_old, v_old
        || E'  DELETE FROM public.n2s_sg_current WHERE pulled_at < now() - interval ''1 day'';\n'
        || E'  DELETE FROM public.n2s_evo_full_pulls WHERE captured_at < now() - interval ''1 day'';\n');
  EXECUTE v_def;

  -- ── cover search ──
  v_def := pg_get_functiondef('public.n2s_cover_candidates'::regproc);
  IF md5(v_def) <> '82afefd4151b321e6adeb40fcc535c4d' THEN
    RAISE EXCEPTION 'n2s_cover_candidates drifted — refusing';
  END IF;

  -- EVO: anchor on the latest FULL capture (+ any newer change rows); no full
  -- capture in the window -> exactly the old behaviour (latest capture only).
  v_old := $x$p_tevo AS (SELECT ev.eid, x.captured_at FROM ev CROSS JOIN LATERAL (
      SELECT s.captured_at FROM public.listings_snapshots s
       WHERE s.event_id = ev.eid AND s.captured_at >= now() - p_max_listing_age
       ORDER BY s.captured_at DESC LIMIT 1) x),$x$;
  v_new := $x$p_tevo AS (SELECT ev.eid, COALESCE(fp.captured_at, x.captured_at) AS captured_at,
                         (fp.captured_at IS NOT NULL) AS is_full
      FROM ev CROSS JOIN LATERAL (
      SELECT s.captured_at FROM public.listings_snapshots s
       WHERE s.event_id = ev.eid AND s.captured_at >= now() - p_max_listing_age
       ORDER BY s.captured_at DESC LIMIT 1) x
      LEFT JOIN LATERAL (
      SELECT f.captured_at FROM public.n2s_evo_full_pulls f
       WHERE f.event_id = ev.eid AND f.captured_at >= now() - p_max_listing_age
       ORDER BY f.captured_at DESC LIMIT 1) fp ON true),$x$;
  IF (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 THEN
    RAISE EXCEPTION 'n2s_cover_candidates: p_tevo anchor not found exactly once';
  END IF;
  v_def := replace(v_def, v_old, v_new);

  v_old := $x$      FROM p_tevo p JOIN public.listings_snapshots t
        ON t.event_id = p.eid AND t.captured_at = p.captured_at
$x$;
  v_new := $x$      FROM p_tevo p CROSS JOIN LATERAL (
        SELECT DISTINCT ON (s.tevo_ticket_group_id) s.*
          FROM public.listings_snapshots s
         WHERE s.event_id = p.eid
           AND (s.captured_at = p.captured_at OR (p.is_full AND s.captured_at > p.captured_at))
         ORDER BY s.tevo_ticket_group_id, s.captured_at DESC) t
$x$;
  IF (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 THEN
    RAISE EXCEPTION 'n2s_cover_candidates: tevo join anchor not found exactly once';
  END IF;
  v_def := replace(v_def, v_old, v_new);

  -- SeatGeek: events with a fresh full set read n2s_sg_current; others keep
  -- the old latest-capture path.
  v_old := E'  td_cur AS (\n';
  v_new := $x$  p_sgc AS (SELECT DISTINCT c.tevo_event_id AS eid FROM public.n2s_sg_current c
                WHERE c.tevo_event_id IN (SELECT eid FROM ev)
                  AND c.pulled_at >= now() - p_max_listing_age),
$x$ || v_old;
  IF (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 THEN
    RAISE EXCEPTION 'n2s_cover_candidates: td_cur anchor not found exactly once';
  END IF;
  v_def := replace(v_def, v_old, v_new);

  v_old := E'     WHERE NOT sg.is_broker_owned\n';
  v_new := v_old || E'       AND p.eid NOT IN (SELECT eid FROM p_sgc)\n';
  IF (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 THEN
    RAISE EXCEPTION 'n2s_cover_candidates: sg filter anchor not found exactly once';
  END IF;
  v_def := replace(v_def, v_old, v_new);

  v_old := E'    UNION ALL\n    SELECT ''ticketsdata:''';
  v_new := $x$    UNION ALL
    SELECT 'seatgeek', sc.sglid::text, sc.tevo_event_id,
           sc.section, sc."row", sc.quantity, sc.retail_price_all_in,
           CASE WHEN COALESCE(c.sg_url,'') <> '' AND COALESCE(sc.display_id,'') <> ''
                THEN c.sg_url || '#listing=' || sc.display_id ELSE NULL::text END,
           sc.pulled_at,
           CASE WHEN jsonb_typeof(sc.splits) = 'array'
                THEN ARRAY(SELECT e::int FROM jsonb_array_elements_text(sc.splits) AS e
                            WHERE e ~ '^[0-9]+$')
                ELSE NULL::int[] END
      FROM p_sgc p JOIN public.n2s_sg_current sc ON sc.tevo_event_id = p.eid
      LEFT JOIN public.sg_events_canonical c ON c.sg_event_id = sc.sg_event_id
     WHERE NOT sc.is_broker_owned
       AND (p_sub_sources IS NULL OR 'seatgeek' = ANY(p_sub_sources))
$x$ || v_old;
  IF (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 THEN
    RAISE EXCEPTION 'n2s_cover_candidates: ticketsdata anchor not found exactly once';
  END IF;
  v_def := replace(v_def, v_old, v_new);
  EXECUTE v_def;

  -- ── queue refresh: view quality for SeatGeek covers from the current set ──
  v_def := pg_get_functiondef('public.n2s_cover_queue_refresh'::regproc);
  IF md5(v_def) <> '0c7bb35d033d3d5979b85794f7fb5f28' THEN
    RAISE EXCEPTION 'n2s_cover_queue_refresh drifted — refusing';
  END IF;
  v_old := E'              AND sg.sglid::text   = q2.sub_listing_id\n            LIMIT 1)\n';
  v_new := v_old || $x$          UNION ALL
          (SELECT sc.seller_notes, sc.has_limited_view
             FROM public.n2s_sg_current sc
            WHERE q2.sub_source = 'seatgeek'
              AND sc.tevo_event_id = q2.tevo_event_id
              AND sc.pulled_at     = q2.captured_at
              AND sc.sglid::text   = q2.sub_listing_id
            LIMIT 1)
$x$;
  IF (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 THEN
    RAISE EXCEPTION 'n2s_cover_queue_refresh: sg lookup anchor not found exactly once';
  END IF;
  EXECUTE replace(v_def, v_old, v_new);

  -- ── polling: EVO full pulls; SeatGeek only skips a 60 s rate-limit window ──
  v_def := pg_get_functiondef('public.n2s_pull_events'::regproc);
  IF md5(v_def) <> '3e06c86a4974556650b6a3c8f13e3997' THEN
    RAISE EXCEPTION 'n2s_pull_events drifted — refusing';
  END IF;
  v_old := 'collect-listings?event_id=';
  IF (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 THEN
    RAISE EXCEPTION 'n2s_pull_events: collect-listings anchor not found exactly once';
  END IF;
  v_def := replace(v_def, v_old, 'collect-listings?full=1&event_id=');
  v_old := E'                              AND ps.last_polled_listings_at >= now() - p_refresh_after)\n           AND NOT EXISTS (SELECT 1 FROM public.sg_broker_pending b';
  IF (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 THEN
    RAISE EXCEPTION 'n2s_pull_events: sg timer anchor not found exactly once';
  END IF;
  v_def := replace(v_def, v_old, replace(v_old, 'now() - p_refresh_after', 'now() - interval ''60 seconds'''));
  v_old := E'                              AND b.fired_at >= now() - p_refresh_after)';
  IF (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 THEN
    RAISE EXCEPTION 'n2s_pull_events: sg pending anchor not found exactly once';
  END IF;
  v_def := replace(v_def, v_old, replace(v_old, 'now() - p_refresh_after', 'now() - interval ''60 seconds'''));
  EXECUTE v_def;
END $$;

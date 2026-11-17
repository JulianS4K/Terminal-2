-- Migration 20260910640000 · level:secondary-sales · lane:D7 · writes:none (function body n2s_cover_queue_refresh) · reads:gotickets_listings_snapshots,seatgeek_listings_snapshots · pre:20260910630000
--
-- Already applied to prod · via MCP 2026-09-10 under operator direction (hotfix, minutes after 630000).
-- ============================================================================
-- Migration 20260910640000 — view-quality enrichment must be QUEUE-driven
--
-- Lane: D7 · Pre-reqs: 20260910630000
--
-- ⚠ HOTFIX. 20260910630000 injected an enrichment UPDATE into
-- n2s_cover_queue_refresh() that built its source set as
--   "every gotickets/seatgeek snapshot row for any event in the queue"
-- and then joined that to the queue on (source, listing id, event, captured_at).
-- gotickets_listings_snapshots is ~160M rows and seatgeek_listings_snapshots
-- ~18M; the `tevo_event_id IN (...)` predicate has no captured_at bound, so the
-- planner pulls the whole history of every queued event before the join
-- narrows it. On prod the statement blew a 55s statement_timeout, and the
-- every-minute cron (job 602) — which has no per-statement budget of its own —
-- sat in it for minutes holding the queue's row locks. Every tick after the
-- apply would have done the same.
--
-- The fix inverts the drive: iterate the ~25 queue rows that can carry a
-- signal and do ONE indexed point lookup each —
--   idx_gt_ls_event_time        (tevo_event_id, captured_at DESC)
--   idx_sg_listings_event_at    (tevo_event_id, captured_at DESC)
-- so each lookup lands on the exact snapshot and filters a few hundred rows by
-- listing id. Measured on prod before apply: 12 ms, 24 of 24 rows matched,
-- 468 shared buffers. Semantics are identical: same key, same n2s_view_of()
-- call, same 'unknown' baseline pass and label suffix (both untouched here).
--
-- The `LIMIT 1` per branch is belt-and-braces: (tevo_event_id, captured_at,
-- listing id) is unique per snapshot on both tables, so it never drops a row.
-- ============================================================================

DO $do$
DECLARE d text; old_block text; new_block text; n int;
BEGIN
  d := pg_get_functiondef('public.n2s_cover_queue_refresh()'::regprocedure);

  -- anchor: the exact statement 20260910630000 injected, matched as a whole so
  -- a drifted body fails loudly rather than being half-patched.
  old_block := substring(d from 'UPDATE public\.n2s_cover_queue q\s+SET sub_notes = v\.notes,.*?AND v\.captured_at = q\.captured_at;');
  IF old_block IS NULL THEN
    RAISE EXCEPTION 'anchor (630000 enrichment UPDATE … FROM (…) v … AND v.captured_at = q.captured_at;) not found — refresh body drifted, re-derive this migration';
  END IF;
  SELECT count(*) INTO n FROM regexp_matches(d, 'SET sub_notes = v\.notes,', 'g');
  IF n <> 1 THEN
    RAISE EXCEPTION 'anchor expected exactly once in n2s_cover_queue_refresh(), found %', n;
  END IF;

  new_block :=
    'UPDATE public.n2s_cover_queue q' || E'\n' ||
    '     SET sub_notes = s.notes,' || E'\n' ||
    '         sub_view  = public.n2s_view_of(s.notes, s.lv)' || E'\n' ||
    '    FROM (' || E'\n' ||
    '      -- queue-driven: one indexed point lookup per row that can carry a' || E'\n' ||
    '      -- signal (idx_gt_ls_event_time / idx_sg_listings_event_at). NEVER' || E'\n' ||
    '      -- rebuild this as "all snapshots for the queue''s events" — the' || E'\n' ||
    '      -- snapshot tables are firehoses (160M / 18M rows) and that shape' || E'\n' ||
    '      -- wedged the every-minute cron on 2026-09-10 (mig 20260910640000).' || E'\n' ||
    '      SELECT q2.n2s_id, x.notes, x.lv' || E'\n' ||
    '        FROM public.n2s_cover_queue q2' || E'\n' ||
    '        CROSS JOIN LATERAL (' || E'\n' ||
    '          (SELECT g.notes, NULL::boolean AS lv' || E'\n' ||
    '             FROM public.gotickets_listings_snapshots g' || E'\n' ||
    '            WHERE q2.sub_source = ''gotickets''' || E'\n' ||
    '              AND g.tevo_event_id = q2.tevo_event_id' || E'\n' ||
    '              AND g.captured_at   = q2.captured_at' || E'\n' ||
    '              AND g.gt_listing_id::text = q2.sub_listing_id' || E'\n' ||
    '            LIMIT 1)' || E'\n' ||
    '          UNION ALL' || E'\n' ||
    '          (SELECT sg.seller_notes, sg.has_limited_view' || E'\n' ||
    '             FROM public.seatgeek_listings_snapshots sg' || E'\n' ||
    '            WHERE q2.sub_source = ''seatgeek''' || E'\n' ||
    '              AND sg.tevo_event_id = q2.tevo_event_id' || E'\n' ||
    '              AND sg.captured_at   = q2.captured_at' || E'\n' ||
    '              AND sg.sglid::text   = q2.sub_listing_id' || E'\n' ||
    '            LIMIT 1)' || E'\n' ||
    '        ) x' || E'\n' ||
    '       WHERE q2.sub_listing_id IS NOT NULL' || E'\n' ||
    '         AND q2.sub_source IN (''gotickets'', ''seatgeek'')' || E'\n' ||
    '    ) s' || E'\n' ||
    '   WHERE s.n2s_id = q.n2s_id;';

  d := replace(d, old_block, new_block);
  EXECUTE d;
END $do$;

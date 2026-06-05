-- ============================================================
-- Terminal SQL audit (2026-05-30, A1): broker event-page chain timeout fixes.
-- Reconciles the repo with prod — these were applied live via apply_migration
-- during the audit ("audit all sql based pulls into d0 terminal ... if existing fix").
--
-- Symptom: the event-page RPC chain get_broker_event_page (v1) -> _v2 -> _v3
-- ran 0.5s..19s and intermittently exceeded the 8s PostgREST statement_timeout on
-- heavy events. All three causes are the same family: a wide scan of a big table
-- where only the latest slice is needed.
--
--   (1) v1 freshness ran `SELECT max(last_seen_at) FROM espn_injuries_snapshots`
--       with NO WHERE clause -> full seq scan of a 175MB table on EVERY event-page
--       load (event-independent; ~0.6s warm, up to ~18s cold/under contention).
--       Postgres' max()->index optimization would not match an index on this column,
--       so an explicit `ORDER BY last_seen_at DESC NULLS LAST LIMIT 1` is used
--       instead, backed by a new index. v1 dropped 18.8s -> ~0.5s.  [dominant cause]
--   (2) v2 'splits' did a 24h DISTINCT ON over listings_snapshots (25.5M-row EVO
--       firehose) -> 154k-row external-merge disk sort on a heavy event. Pinned to
--       the latest collection batch: captured_at >= max(captured_at) - 30min.
--   (3) v3 'recent_listings' had the identical 24h DISTINCT ON pattern -> same fix.
--
-- After: v3 end-to-end measured ~0.35s..2.5s (live-load dependent); no >8s timeouts.
-- Each function patch is a guarded surgical replace of the live definition (aborts
-- if the target text is not found), matching exactly what ran in prod.
-- ============================================================

-- (1a) Index backing the v1 espn-injuries freshness lookup. NULLS LAST so the
--      newest (max-equivalent) value is the first index entry.
DROP INDEX IF EXISTS public.idx_espn_injuries_last_seen;
CREATE INDEX idx_espn_injuries_last_seen
  ON public.espn_injuries_snapshots (last_seen_at DESC NULLS LAST);

-- (1b) v1: replace the unconditional max() seq scan with an index-friendly ORDER BY.
DO $outer$
DECLARE v_def text; v_new text;
BEGIN
  v_def := pg_get_functiondef('public.get_broker_event_page(integer,integer)'::regprocedure);
  v_new := regexp_replace(v_def,
    'SELECT max\(last_seen_at\) INTO v_last_inj\s+FROM public\.espn_injuries_snapshots;',
    'SELECT last_seen_at INTO v_last_inj FROM public.espn_injuries_snapshots ORDER BY last_seen_at DESC NULLS LAST LIMIT 1;');
  IF v_new = v_def THEN
    RAISE EXCEPTION 'v1 espn_injuries freshness fix: target statement not found — aborting';
  END IF;
  EXECUTE v_new;
END $outer$;

-- (2) v2: pin the 'splits' latest_per_tg scan to the latest collection batch.
DO $outer$
DECLARE v_def text; v_new text;
BEGIN
  v_def := pg_get_functiondef('public.get_broker_event_page_v2(integer,integer)'::regprocedure);
  v_new := regexp_replace(v_def,
    'WHERE event_id = p_event_id AND captured_at > now\(\) - interval ''24 hours''(\s+ORDER BY tevo_ticket_group_id, captured_at DESC)',
    'WHERE event_id = p_event_id AND captured_at >= (SELECT max(captured_at) FROM public.listings_snapshots WHERE event_id = p_event_id AND captured_at > now() - interval ''7 days'') - interval ''30 minutes''\1');
  IF v_new = v_def THEN
    RAISE EXCEPTION 'v2 splits latest-batch fix: target WHERE clause not found — aborting';
  END IF;
  EXECUTE v_new;
END $outer$;

-- (3) v3: identical latest-batch pin for 'recent_listings' (note the trailing LIMIT 10
--     distinguishes it from the v2 splits block).
DO $outer$
DECLARE v_def text; v_new text;
BEGIN
  v_def := pg_get_functiondef('public.get_broker_event_page_v3(integer,integer)'::regprocedure);
  v_new := regexp_replace(v_def,
    'WHERE event_id = p_event_id AND captured_at > now\(\) - interval ''24 hours''(\s+ORDER BY tevo_ticket_group_id, captured_at DESC LIMIT 10)',
    'WHERE event_id = p_event_id AND captured_at >= (SELECT max(captured_at) FROM public.listings_snapshots WHERE event_id = p_event_id AND captured_at > now() - interval ''7 days'') - interval ''30 minutes''\1');
  IF v_new = v_def THEN
    RAISE EXCEPTION 'v3 recent_listings latest-batch fix: target WHERE clause not found — aborting';
  END IF;
  EXECUTE v_new;
END $outer$;

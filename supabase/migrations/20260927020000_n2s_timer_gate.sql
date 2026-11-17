-- Migration 20260927020000 · level:secondary-sales · lane:D7 · writes:n2s_timer_open,n2s_pull_all_sources,n2s_cover_candidates,v_n2s_orders · reads:n2s_items · pre:20260926212000
--
-- Already applied to prod · via MCP 2026-09-27 02:18 UTC under operator direction
-- ("Stop pulling covers after the 15 min timer runs out" → "Stop everything"),
-- after a rolled-back dry run (panel 352 → 1 order, Albert's feed 14 → 0 rows,
-- queue refresh 0.6 s).
--
-- ============================================================================
-- An N2S order is only worked inside its CRM response window. Past it: no more
-- source polls, no cover search, off the panel view and out of the external
-- feed (n2s_profitable_cover_sync / n2s_cover_push_queue read the view).
-- n2s_cover_history keeps its record: each order gets one closing 'gone' row.
-- The window became 10 minutes in 20260927023400.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.n2s_timer_open(
  p_expires_at timestamptz, p_expired boolean, p_alert_at timestamptz)
 RETURNS boolean
 LANGUAGE sql
 STABLE
 SET search_path TO 'pg_catalog'
AS $f$
  SELECT NOT COALESCE(p_expired, false)
     AND COALESCE(p_expires_at, p_alert_at + interval '15 minutes',
                  'infinity'::timestamptz) > now();
$f$;
REVOKE ALL ON FUNCTION public.n2s_timer_open(timestamptz, boolean, timestamptz) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.n2s_timer_open(timestamptz, boolean, timestamptz) TO authenticated, service_role;
COMMENT ON FUNCTION public.n2s_timer_open(timestamptz, boolean, timestamptz) IS
  'True while an N2S order is inside its CRM response window (timer_expires_at, else alert_at + 15 min). Gates polling, cover search, the panel view and the external feed (20260927020000).';

DO $$
DECLARE
  v_live  text := 'public.n2s_event_live(i.event_dt, i.tevo_event_id)';
  v_gate  text := 'public.n2s_event_live(i.event_dt, i.tevo_event_id)'
               || E'\n       AND public.n2s_timer_open(i.timer_expires_at, i.timer_expired, i.alert_at)';
  v_def   text;
  v_vlive text := 'n2s_event_live(n.event_dt, n.tevo_event_id))';
  v_vgate text := 'n2s_event_live(n.event_dt, n.tevo_event_id) AND n2s_timer_open(n.timer_expires_at, n.timer_expired, n.alert_at))';
BEGIN
  -- polling: new-order pull and the re-pull sweep
  v_def := pg_get_functiondef('public.n2s_pull_all_sources'::regproc);
  IF md5(v_def) <> '561390ada579722d3b9ded1f4aa77dab' THEN
    RAISE EXCEPTION 'n2s_pull_all_sources drifted from the reviewed body — refusing';
  END IF;
  IF (length(v_def) - length(replace(v_def, v_live, ''))) / length(v_live) <> 2 THEN
    RAISE EXCEPTION 'n2s_pull_all_sources: expected 2 live-gates';
  END IF;
  EXECUTE replace(v_def, v_live, v_gate);

  -- cover search: feeds the queue, the ping, the webhook push and the feed
  v_def := pg_get_functiondef('public.n2s_cover_candidates'::regproc);
  IF md5(v_def) <> 'ddae5e26dd30b588cdb4791dc1de6ae1' THEN
    RAISE EXCEPTION 'n2s_cover_candidates drifted from the reviewed body — refusing';
  END IF;
  IF (length(v_def) - length(replace(v_def, v_live, ''))) / length(v_live) <> 1 THEN
    RAISE EXCEPTION 'n2s_cover_candidates: expected 1 live-gate';
  END IF;
  EXECUTE replace(v_def, v_live, v_gate);

  -- panel view (and n2s_profitable_cover_sync / n2s_cover_push_queue, which read it)
  v_def := pg_get_viewdef('public.v_n2s_orders'::regclass);
  IF md5(v_def) <> '20e3ef85463fec7e3707e7f3a3180dcc' THEN
    RAISE EXCEPTION 'v_n2s_orders drifted from the reviewed body — refusing';
  END IF;
  IF (length(v_def) - length(replace(v_def, v_vlive, ''))) / length(v_vlive) <> 1 THEN
    RAISE EXCEPTION 'v_n2s_orders: expected 1 live-gate';
  END IF;
  EXECUTE 'CREATE OR REPLACE VIEW public.v_n2s_orders AS '
       || rtrim(replace(v_def, v_vlive, v_vgate), E'; \n');
END $$;

-- rollback: drop the n2s_timer_open(...) conjunct from n2s_pull_all_sources
-- (2 places), n2s_cover_candidates (1) and v_n2s_orders (1); DROP FUNCTION
-- public.n2s_timer_open(timestamptz, boolean, timestamptz).

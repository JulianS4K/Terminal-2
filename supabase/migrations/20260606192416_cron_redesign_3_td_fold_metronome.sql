-- 20260606192416_cron_redesign_3_td_fold_metronome.sql
--
-- ## Already applied to prod — applied via MCP 2026-06-06 (operator-authorized)
--
-- Trading-hours cadence redesign #3 of 3 (CRON_HIERARCHY §4c). Fold TicketsData (TD)
-- onto collector_band + serial metronome firing.
--   (a) TD cadence rows (source='TD'); (b) td_enqueue_peak horizon-driven (drop flat 4x/day);
--   (c) td_pull_drain serial hottest-first metronome (p_max=1) + resolved_at guard (also fixes
--       the §4b drain landmine: soft-cancelled rows with fired_at NULL no longer re-fire);
--   (d) reschedule enqueue (staggered 24/7), drain (1/min), normalize (every 2 min).
-- Budget caps (300/day via td_budget_ok, 9000/mo) + cron_should_fire retained as hard backstops.
-- Expected demand drops ~950/day (flat 4x, exhausts ~noon ET) -> ~220/day (under the 300 cap).
-- Covers SH/VD/GT/TM/TP only; SeatGeek (incl. any TD->SG discovery) stays on its native feeds.

-- (a) TD cadence rows: peak = trading interval; off = after-hours (le3d nightly floor,
--     others effectively off via a ~69d interval). collector_band 3-arg ignores owned_kind.
INSERT INTO public.collector_cadence
  (source,scope,band,owned_kind,min_hours,max_hours,peak_interval_min,offpeak_interval_min,enabled,sort_order,notes,updated_at)
VALUES
  ('TD','listings','le3d','any',0,72,240,1440,true,1,'trading-hours redesign §4c (le3d nightly floor)',now()),
  ('TD','listings','d4_7','any',72,168,480,100000,true,2,'trading-hours redesign §4c (after-hours off)',now()),
  ('TD','listings','d8_14','any',168,336,720,100000,true,3,'trading-hours redesign §4c (after-hours off)',now()),
  ('TD','listings','d15_30','any',336,720,1440,100000,true,4,'trading-hours redesign §4c (after-hours off)',now()),
  ('TD','listings','d31p','any',720,NULL,2880,100000,true,5,'trading-hours redesign §4c (after-hours off)',now())
ON CONFLICT (source,scope,band,owned_kind) DO UPDATE
  SET min_hours=EXCLUDED.min_hours, max_hours=EXCLUDED.max_hours,
      peak_interval_min=EXCLUDED.peak_interval_min, offpeak_interval_min=EXCLUDED.offpeak_interval_min,
      enabled=true, sort_order=EXCLUDED.sort_order, notes=EXCLUDED.notes, updated_at=now();

-- (b) td_enqueue_peak: enqueue when the per-event horizon-band interval is due (was: flat 4x/day)
CREATE OR REPLACE FUNCTION public.td_enqueue_peak(
  p_platform text DEFAULT NULL, p_interval_tag text DEFAULT 'manual')
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public','pg_temp' AS $enq$
DECLARE
  r RECORD; v_count int := 0; v_now timestamptz := clock_timestamp(); v_jobname text;
BEGIN
  v_jobname := CASE WHEN p_platform IS NOT NULL THEN 'td_enqueue_peak_'||lower(p_platform) ELSE 'td_enqueue_peak' END;
  IF NOT public.cron_should_fire(v_jobname) THEN RETURN 0; END IF;
  IF NOT public.td_budget_ok() THEN
    RAISE NOTICE 'td_enqueue_peak(%): budget exhausted, skipping', COALESCE(p_platform,'all');
    RETURN 0;
  END IF;

  FOR r IN
    SELECT x.event_id, x.platform, x.event_url, c.required_min
    FROM public.ticketsdata_event_xref x
    JOIN public.sg_events_canonical sgc ON sgc.sg_event_id = (
      SELECT aem.sg_event_id FROM public.aq_event_map aem
      WHERE aem.aq_short_event_id = x.aq_short_event_id LIMIT 1)
    CROSS JOIN LATERAL public.collector_band('TD','listings',
                 greatest(EXTRACT(epoch FROM (sgc.sg_datetime_utc - v_now))/3600.0, 0)) c
    WHERE x.active = true
      AND x.event_url IS NOT NULL
      AND sgc.sg_datetime_utc > v_now - interval '6 hours'
      AND (p_platform IS NULL OR x.platform = p_platform)
      AND ( x.last_enqueued_at IS NULL
            OR x.last_enqueued_at < v_now - make_interval(mins => c.required_min) )
      AND NOT EXISTS (
        SELECT 1 FROM public.td_pull_queue q
        WHERE q.event_id = x.event_id AND q.platform = x.platform AND q.resolved_at IS NULL)
    ORDER BY c.required_min ASC, x.owned_tickets DESC NULLS LAST,
             x.median_retail_price DESC NULLS LAST, x.last_enqueued_at NULLS FIRST
    LIMIT 40
  LOOP
    INSERT INTO public.td_pull_queue (event_id, platform, event_url, interval_tag, created_at)
    VALUES (r.event_id, r.platform, r.event_url, p_interval_tag, v_now);
    UPDATE public.ticketsdata_event_xref
      SET last_enqueued_at = v_now, enqueues_today = enqueues_today + 1, updated_at = v_now
      WHERE (event_id, platform) = (r.event_id, r.platform);
    v_count := v_count + 1;
  END LOOP;
  RETURN v_count;
END $enq$;
REVOKE ALL ON FUNCTION public.td_enqueue_peak(text, text) FROM anon, public;

-- (c) td_pull_drain: serial metronome, hottest (soonest-event) first, + resolved_at guard
CREATE OR REPLACE FUNCTION public.td_pull_drain(p_max integer DEFAULT 1)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public','extensions','pg_temp' AS $drn$
DECLARE r RECORD; v_user text; v_pass text; v_req_id bigint; v_count int := 0;
BEGIN
  IF NOT public.cron_should_fire('td_pull_drain') THEN RETURN 0; END IF;
  IF NOT public.td_budget_ok() THEN RAISE NOTICE 'td_pull_drain: budget exhausted, skipping'; RETURN 0; END IF;
  v_user := public.get_app_secret('TICKETSDATA_USERNAME');
  v_pass := public.get_app_secret('TICKETSDATA_PASSWORD');
  IF v_user IS NULL OR v_pass IS NULL THEN RAISE EXCEPTION 'td_pull_drain: TICKETSDATA creds missing from vault'; END IF;

  FOR r IN
    SELECT q.id, q.event_id, q.platform, q.event_url
    FROM public.td_pull_queue q
    LEFT JOIN public.ticketsdata_event_xref x ON (x.event_id, x.platform) = (q.event_id, q.platform)
    LEFT JOIN public.sg_events_canonical sgc ON sgc.sg_event_id = (
      SELECT aem.sg_event_id FROM public.aq_event_map aem
      WHERE aem.aq_short_event_id = x.aq_short_event_id LIMIT 1)
    WHERE q.fired_at IS NULL AND q.resolved_at IS NULL
    ORDER BY sgc.sg_datetime_utc ASC NULLS LAST, q.created_at ASC
    LIMIT p_max
  LOOP
    SELECT net.http_get(
      url := 'https://ticketsdata.com/fetch',
      params := jsonb_build_object('platform', public.td_api_platform(r.platform),
                  'event_url', r.event_url, 'username', v_user, 'password', v_pass),
      headers := '{}'::jsonb, timeout_milliseconds := 35000) INTO v_req_id;
    UPDATE public.td_pull_queue SET request_id = v_req_id, fired_at = clock_timestamp() WHERE id = r.id;
    v_count := v_count + 1;
  END LOOP;
  RETURN v_count;
END $drn$;
REVOKE ALL ON FUNCTION public.td_pull_drain(integer) FROM anon, public;

-- (d) reschedule crons: enqueue staggered 24/7 (band gates due-ness); drain 1/min; normalize every 2 min
SELECT cron.schedule('td_enqueue_peak_sh','0-59/10 * * * *', $c$DO $b$ BEGIN PERFORM public.td_enqueue_peak('SH','metronome'); END $b$;$c$);
SELECT cron.schedule('td_enqueue_peak_vd','2-59/10 * * * *', $c$DO $b$ BEGIN PERFORM public.td_enqueue_peak('VD','metronome'); END $b$;$c$);
SELECT cron.schedule('td_enqueue_peak_gt','4-59/10 * * * *', $c$DO $b$ BEGIN PERFORM public.td_enqueue_peak('GT','metronome'); END $b$;$c$);
SELECT cron.schedule('td_enqueue_peak_tm','6-59/10 * * * *', $c$DO $b$ BEGIN PERFORM public.td_enqueue_peak('TM','metronome'); END $b$;$c$);
SELECT cron.schedule('td_enqueue_peak_tp','8-59/10 * * * *', $c$DO $b$ BEGIN PERFORM public.td_enqueue_peak('TP','metronome'); END $b$;$c$);
SELECT cron.schedule('td_pull_drain','* * * * *', $c$DO $body$ BEGIN PERFORM public.td_pull_drain(1); END $body$;$c$);
SELECT cron.schedule('td_normalize_drain','*/2 * * * *', $c$DO $body$ BEGIN PERFORM public.td_normalize_drain(50); END $body$;$c$);

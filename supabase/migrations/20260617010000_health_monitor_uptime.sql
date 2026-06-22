-- ============================================================================
-- Migration 20260617010000 — health monitor + uptime history + dashboard RPC
--
-- Lane:     xref+macro (A1 — monitoring / ops)
-- Touches:  health_check_history (W, new), health_web_targets (W, new),
--           health_web_probe (W, new), release_health_check (R),
--           net._http_response (R), cron.job (W — schedules health_monitor_5min)
-- Pre-reqs: release_health_check() (mig 20260515170000), pg_net, cron_should_fire()
--
-- WHY: release_health_check() already rolls up cron/freshness/queue/security
-- health, but nothing PERSISTS it, so there is no uptime history and no
-- human-facing status page. This adds:
--   1. health_check_history  — timestamped snapshots (30d retention)
--   2. a */5 cron (health_tick) that snapshots release_health_check() AND
--      pg_net-pings the Render web services for true HTTP reachability
--   3. get_health_dashboard() — @s4kent-gated RPC powering static/terminal/health.html
--
-- pg_net is async (PROJECT_BIBLE §3 landmine): a tick FIRES probes, the NEXT
-- tick COLLECTS the now-resolved responses. now() is transaction-fixed inside
-- health_tick(), so every row a tick writes shares one captured_at (clean
-- per-tick timeline grouping).
-- ============================================================================

-- ---------- 1. history + config tables ----------
CREATE TABLE IF NOT EXISTS public.health_check_history (
  id          bigserial PRIMARY KEY,
  captured_at timestamptz NOT NULL DEFAULT now(),
  check_class text        NOT NULL,
  check_name  text        NOT NULL,
  status      text        NOT NULL,   -- ok | warn | fail | up | down
  metric      numeric,
  detail      text
);
CREATE INDEX IF NOT EXISTS idx_hch_captured   ON public.health_check_history (captured_at DESC);
CREATE INDEX IF NOT EXISTS idx_hch_check_time ON public.health_check_history (check_class, check_name, captured_at DESC);

CREATE TABLE IF NOT EXISTS public.health_web_targets (
  name       text PRIMARY KEY,
  url        text NOT NULL,
  enabled    boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now()
);
INSERT INTO public.health_web_targets(name, url) VALUES
  ('storefront',   'https://vibepass-storefront-test.onrender.com/healthz'),
  ('terminal_cdn', 'https://vibepass-terminal-test.onrender.com/index.html'),
  ('d2_dashboard', 'https://d2-orders-dashboard.onrender.com/healthz')
ON CONFLICT (name) DO NOTHING;

CREATE TABLE IF NOT EXISTS public.health_web_probe (
  request_id  bigint PRIMARY KEY,
  target      text NOT NULL,
  url         text NOT NULL,
  probed_at   timestamptz NOT NULL DEFAULT now(),
  resolved_at timestamptz
);

-- RLS: deny-all to anon/authenticated; reads flow only through the SECDEF RPC.
DO $rls$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['health_check_history','health_web_targets','health_web_probe'] LOOP
    EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format('DROP POLICY IF EXISTS admin_only ON public.%I', t);
    EXECUTE format('CREATE POLICY admin_only ON public.%I FOR ALL USING (false) WITH CHECK (false)', t);
    EXECUTE format('REVOKE ALL ON public.%I FROM anon, authenticated', t);
    EXECUTE format('GRANT ALL ON public.%I TO service_role', t);
  END LOOP;
END $rls$;

-- ---------- 2. probe / collect / snapshot / tick ----------
CREATE OR REPLACE FUNCTION public.health_fire_web_probes()
 RETURNS integer LANGUAGE plpgsql SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE r record; v_req bigint; n int := 0;
BEGIN
  FOR r IN SELECT name, url FROM public.health_web_targets WHERE enabled LOOP
    SELECT net.http_get(url := r.url, timeout_milliseconds := 8000) INTO v_req;
    INSERT INTO public.health_web_probe(request_id, target, url) VALUES (v_req, r.name, r.url);
    n := n + 1;
  END LOOP;
  RETURN n;
END $function$;

CREATE OR REPLACE FUNCTION public.health_collect_web_probes()
 RETURNS integer LANGUAGE plpgsql SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE n int := 0;
BEGIN
  -- responses that have arrived
  INSERT INTO public.health_check_history (check_class, check_name, status, metric, detail)
  SELECT 'web', p.target,
         CASE WHEN resp.status_code BETWEEN 200 AND 399 THEN 'up' ELSE 'down' END,
         resp.status_code::numeric,
         format('HTTP %s · %s ms',
                coalesce(resp.status_code::text, coalesce(resp.error_msg,'err')),
                round(extract(epoch FROM (resp.created - p.probed_at)) * 1000))
  FROM public.health_web_probe p
  JOIN net._http_response resp ON resp.id = p.request_id
  WHERE p.resolved_at IS NULL;
  GET DIAGNOSTICS n = ROW_COUNT;
  UPDATE public.health_web_probe p SET resolved_at = now()
   WHERE p.resolved_at IS NULL
     AND EXISTS (SELECT 1 FROM net._http_response resp WHERE resp.id = p.request_id);

  -- probes with no response after 4 min (timed out or pg_net pruned the row) = down
  INSERT INTO public.health_check_history (check_class, check_name, status, metric, detail)
  SELECT 'web', p.target, 'down', NULL, 'no response (timeout / pruned)'
  FROM public.health_web_probe p
  WHERE p.resolved_at IS NULL AND p.probed_at < now() - interval '4 minutes';
  UPDATE public.health_web_probe p SET resolved_at = now()
   WHERE p.resolved_at IS NULL AND p.probed_at < now() - interval '4 minutes';

  RETURN n;
END $function$;

CREATE OR REPLACE FUNCTION public.health_snapshot_pipeline()
 RETURNS integer LANGUAGE plpgsql SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE n int;
BEGIN
  INSERT INTO public.health_check_history (check_class, check_name, status, metric, detail)
  SELECT check_class, check_name, status, metric, detail FROM public.release_health_check();
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $function$;

CREATE OR REPLACE FUNCTION public.health_tick()
 RETURNS void LANGUAGE plpgsql SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
BEGIN
  PERFORM public.health_collect_web_probes();  -- prior tick's pings (now resolved)
  PERFORM public.health_snapshot_pipeline();   -- DB/pipeline rollup
  PERFORM public.health_fire_web_probes();      -- new pings (collected next tick)
  -- retention
  DELETE FROM public.health_check_history WHERE captured_at < now() - interval '30 days';
  DELETE FROM public.health_web_probe
   WHERE resolved_at IS NOT NULL AND resolved_at < now() - interval '1 day';
END $function$;

-- internal mutators: cron-only, never anon/authenticated
REVOKE ALL ON FUNCTION public.health_fire_web_probes()    FROM public, anon, authenticated;
REVOKE ALL ON FUNCTION public.health_collect_web_probes() FROM public, anon, authenticated;
REVOKE ALL ON FUNCTION public.health_snapshot_pipeline()  FROM public, anon, authenticated;
REVOKE ALL ON FUNCTION public.health_tick()               FROM public, anon, authenticated;

-- ---------- 3. dashboard RPC (@s4kent gated) ----------
CREATE OR REPLACE FUNCTION public.get_health_dashboard()
 RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE v_email text; v_latest timestamptz; v_result jsonb;
BEGIN
  v_email := coalesce(auth.jwt()->>'email', '');
  IF v_email NOT LIKE '%@s4kent.com' THEN
    RAISE EXCEPTION 'forbidden: % is not an @s4kent.com email', v_email USING ERRCODE = '42501';
  END IF;

  SELECT max(captured_at) INTO v_latest FROM public.health_check_history;

  WITH latest AS (
    SELECT DISTINCT ON (check_class, check_name)
           check_class, check_name, status, metric, detail, captured_at
    FROM public.health_check_history
    ORDER BY check_class, check_name, captured_at DESC
  ),
  up24 AS (
    SELECT check_class, check_name,
           round(100.0 * count(*) FILTER (WHERE status IN ('ok','up')) / nullif(count(*),0), 2) AS ok_24h,
           count(*) AS samples_24h
    FROM public.health_check_history WHERE captured_at > now() - interval '24 hours'
    GROUP BY check_class, check_name
  ),
  up7 AS (
    SELECT check_class, check_name,
           round(100.0 * count(*) FILTER (WHERE status IN ('ok','up')) / nullif(count(*),0), 2) AS ok_7d
    FROM public.health_check_history WHERE captured_at > now() - interval '7 days'
    GROUP BY check_class, check_name
  ),
  merged AS (
    SELECT l.*, u.ok_24h, u.samples_24h, u7.ok_7d
    FROM latest l
    LEFT JOIN up24 u USING (check_class, check_name)
    LEFT JOIN up7  u7 USING (check_class, check_name)
  )
  SELECT jsonb_build_object(
    'generated_at',        now(),
    'latest_snapshot_at',  v_latest,
    'overall', (SELECT jsonb_build_object(
        'status', CASE WHEN count(*) FILTER (WHERE status IN ('fail','down')) > 0 THEN 'fail'
                       WHEN count(*) FILTER (WHERE status = 'warn') > 0           THEN 'warn'
                       ELSE 'ok' END,
        'checks_total', count(*),
        'failing',      count(*) FILTER (WHERE status IN ('fail','down')),
        'warning',      count(*) FILTER (WHERE status = 'warn'),
        'uptime_24h',   round(avg(ok_24h), 2),
        'uptime_7d',    round(avg(ok_7d), 2)
      ) FROM merged),
    'checks', (SELECT coalesce(jsonb_agg(to_jsonb(m) ORDER BY
                  CASE m.status WHEN 'fail' THEN 0 WHEN 'down' THEN 0 WHEN 'warn' THEN 1 ELSE 2 END,
                  m.check_class, m.check_name), '[]'::jsonb)
               FROM merged m WHERE m.check_class <> 'web'),
    'web', (SELECT coalesce(jsonb_agg(to_jsonb(m) ORDER BY m.check_name), '[]'::jsonb)
            FROM merged m WHERE m.check_class = 'web'),
    'timeline', (SELECT coalesce(jsonb_agg(jsonb_build_object('t', captured_at, 'status', ov) ORDER BY captured_at), '[]'::jsonb)
                 FROM (
                   SELECT captured_at,
                          CASE WHEN count(*) FILTER (WHERE status IN ('fail','down')) > 0 THEN 'fail'
                               WHEN count(*) FILTER (WHERE status = 'warn') > 0           THEN 'warn'
                               ELSE 'ok' END AS ov
                   FROM public.health_check_history
                   WHERE captured_at > now() - interval '24 hours'
                   GROUP BY captured_at ORDER BY captured_at DESC LIMIT 288
                 ) tl)
  ) INTO v_result;

  RETURN coalesce(v_result, jsonb_build_object('generated_at', now(), 'latest_snapshot_at', NULL,
                  'overall', NULL, 'checks', '[]'::jsonb, 'web', '[]'::jsonb, 'timeline', '[]'::jsonb));
END $function$;

REVOKE ALL ON FUNCTION public.get_health_dashboard() FROM public;
GRANT EXECUTE ON FUNCTION public.get_health_dashboard() TO anon, authenticated;

COMMENT ON FUNCTION public.get_health_dashboard() IS
  'A1 mig 20260617010000: @s4kent-gated uptime dashboard. Latest status + 24h/7d uptime % per check + web-ping results + 24h overall timeline. Powers static/terminal/health.html.';

-- ---------- 4. cron ----------
SELECT cron.schedule('health_monitor_5min', '*/5 * * * *', $cron$
  DO $b$ BEGIN
    IF NOT public.cron_should_fire('health_monitor_5min') THEN RETURN; END IF;
    PERFORM public.health_tick();
  END $b$;
$cron$);

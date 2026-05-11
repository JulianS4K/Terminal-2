-- ============================================================================
-- 20260511000200 — security: move anon JWT + cron secret out of cron.job
--
-- Background: three cron jobs (`backfill-event-configurations-5min`,
-- `crawl-venues-and-performers-3min`, `crawl-espn-team-assets-3min`) embed
-- the Supabase anon JWT as a literal Bearer in the scheduled SQL. The token
-- is visible to anyone who can SELECT cron.job, and rotating it requires a
-- schema change.
--
-- This migration:
--   1. Asserts that `EDGE_FN_ANON_JWT` and `CRON_SECRET` are seeded in vault.
--   2. Creates a SECURITY DEFINER helper `_cron_invoke_edge_fn(url, body)`
--      that pulls both secrets from vault and calls net.http_post with the
--      Bearer + X-Cron-Secret headers attached. service_role-only.
--   3. Unschedules the 3 cron jobs and reschedules them via the helper —
--      no literal secret survives in the cron.job body.
--
-- PREREQ (operator step, before apply):
--   SELECT vault.create_secret('<anon JWT value>', 'EDGE_FN_ANON_JWT');
--   SELECT vault.create_secret('<cron secret>',  'CRON_SECRET');
-- (Or upsert via vault.update_secret if the rows already exist.)
--
-- Filed by: A1 · 2026-05-11 security chat · SEC-HIGH entry in KANBAN.md.
-- ============================================================================

-- (1) Vault presence checks — fail loudly if operator forgot the prereq.
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM vault.decrypted_secrets WHERE name = 'EDGE_FN_ANON_JWT') THEN
    RAISE EXCEPTION 'EDGE_FN_ANON_JWT not in vault. Seed it first — see migration header.';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM vault.decrypted_secrets WHERE name = 'CRON_SECRET') THEN
    RAISE EXCEPTION 'CRON_SECRET not in vault. Seed it first — see migration header.';
  END IF;
END $$;

-- (2) Helper to invoke an edge function from cron. SECURITY DEFINER + locked
--     search_path so we can run as the function owner (which has vault read)
--     even when called from the cron context.
CREATE OR REPLACE FUNCTION public._cron_invoke_edge_fn(p_url text, p_body jsonb)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_jwt    text;
  v_cron   text;
  v_req_id bigint;
BEGIN
  SELECT decrypted_secret INTO v_jwt  FROM vault.decrypted_secrets WHERE name = 'EDGE_FN_ANON_JWT';
  SELECT decrypted_secret INTO v_cron FROM vault.decrypted_secrets WHERE name = 'CRON_SECRET';
  IF v_jwt IS NULL OR v_cron IS NULL THEN
    RAISE EXCEPTION 'edge fn auth secrets missing from vault';
  END IF;

  SELECT net.http_post(
    url := p_url,
    headers := jsonb_build_object(
      'Content-Type',   'application/json',
      'Authorization',  'Bearer ' || v_jwt,
      'X-Cron-Secret',  v_cron
    ),
    body := p_body,
    timeout_milliseconds := 60000
  ) INTO v_req_id;

  RETURN v_req_id;
END $$;

-- Lock down — only service_role (cron runs as superuser/service_role) and
-- the audit role can call this. Anon must never reach vault via this surface.
REVOKE ALL ON FUNCTION public._cron_invoke_edge_fn(text, jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION public._cron_invoke_edge_fn(text, jsonb) FROM anon, authenticated;
GRANT EXECUTE ON FUNCTION public._cron_invoke_edge_fn(text, jsonb) TO service_role;

COMMENT ON FUNCTION public._cron_invoke_edge_fn(text, jsonb) IS
  'Cron helper: invokes an edge fn URL with Bearer (anon JWT) + X-Cron-Secret '
  'pulled from vault. Replaces the pattern of embedding the JWT in cron.job. '
  'Added 2026-05-11 (security chat). See KANBAN SEC-HIGH entry.';

-- (3) Unschedule the 3 jobs that embed the JWT, then reschedule via helper.
DO $$
DECLARE r record;
BEGIN
  FOR r IN SELECT jobname FROM cron.job WHERE jobname IN (
    'backfill-event-configurations-5min',
    'crawl-venues-and-performers-3min',
    'crawl-espn-team-assets-3min'
  ) LOOP
    PERFORM cron.unschedule(r.jobname);
  END LOOP;
END $$;

SELECT cron.schedule(
  'backfill-event-configurations-5min',
  '*/5 * * * *',
  $cron$
    SELECT public._cron_invoke_edge_fn(
      'https://hzrizjeaxlqcxfrtczpq.supabase.co/functions/v1/backfill-event-configurations',
      '{"all_chat_tracked": true, "limit": 150}'::jsonb
    );
  $cron$
);

SELECT cron.schedule(
  'crawl-venues-and-performers-3min',
  '*/3 * * * *',
  $cron$
    SELECT public._cron_invoke_edge_fn(
      'https://hzrizjeaxlqcxfrtczpq.supabase.co/functions/v1/crawl-venues-and-performers',
      '{"venue_limit": 5, "events_per_venue": 25}'::jsonb
    );
  $cron$
);

SELECT cron.schedule(
  'crawl-espn-team-assets-3min',
  '*/3 * * * *',
  $cron$
    SELECT public._cron_invoke_edge_fn(
      'https://hzrizjeaxlqcxfrtczpq.supabase.co/functions/v1/crawl-espn-team-assets',
      '{"limit": 30}'::jsonb
    );
  $cron$
);

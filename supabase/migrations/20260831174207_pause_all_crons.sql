-- Migration 20260831174207 · reconstructed from prod · writes: see body
--
-- Recorded 2026-11-17 (branch triage): applied on prod as "pause_all_crons" (version 20260831174207) but present in no
-- file in git. Body is prod's own supabase_migrations.schema_migrations.statements for that row,
-- statements separated by ';'. Recording only — it is already applied; do not re-apply.

-- Migration 20260831120000 — pause ALL pg_cron jobs (operator directive 2026-08-31)
-- Full enumerated manifest + RESUME block: supabase/migrations/20260831120000_pause_all_crons.sql
-- Guard: aborts unless the live active set is byte-identical to that manifest.
DO $pause_all_crons$
DECLARE
  c_manifest_md5 constant text := 'c5ff0e9252a876c70aae177506b732e2';
  v_live_md5 text;
  v_count    int;
  r          record;
  v_paused   int := 0;
BEGIN
  SELECT count(*), md5(string_agg(jobname, E'\n' ORDER BY jobname))
    INTO v_count, v_live_md5
    FROM cron.job WHERE active;

  IF v_count = 0 THEN
    RAISE NOTICE 'pause_all_crons: no active jobs — already paused, no-op';
    RETURN;
  END IF;

  IF v_live_md5 IS DISTINCT FROM c_manifest_md5 THEN
    RAISE EXCEPTION 'pause_all_crons: active-set drift (live md5 %, % jobs; manifest %). Re-snapshot before applying.',
      v_live_md5, v_count, c_manifest_md5;
  END IF;

  FOR r IN SELECT jobid FROM cron.job WHERE active LOOP
    PERFORM cron.alter_job(job_id := r.jobid, active := false);
    v_paused := v_paused + 1;
  END LOOP;

  RAISE NOTICE 'pause_all_crons: paused % jobs', v_paused;
END
$pause_all_crons$;
;

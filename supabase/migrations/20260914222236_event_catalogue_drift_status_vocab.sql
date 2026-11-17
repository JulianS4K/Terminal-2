-- Migration 20260914222236 · reconstructed from prod · writes: see body
--
-- Recorded 2026-11-17 (branch triage): applied on prod as "event_catalogue_drift_status_vocab" (version 20260914222236) but present in no
-- file in git. Body is prod's own supabase_migrations.schema_migrations.statements for that row,
-- statements separated by ';'. Recording only — it is already applied; do not re-apply.

DO $do$
DECLARE
  v_def text; v_cnt int;
  v_old text := $a$       OR (gt_status IS NOT NULL AND lower(gt_status) NOT IN ('active','onsale','on_sale'))),$a$;
  v_new text := $b$       OR (gt_status IS NOT NULL AND upper(gt_status) IN ('RESCHEDULED','CANCELLED','POSTPONED','MERGED'))),$b$;
BEGIN
  SELECT p.prosrc INTO v_def FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
  WHERE n.nspname='public' AND p.proname='event_catalogue_drift_scan';
  v_cnt := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  IF v_cnt <> 1 THEN
    RAISE EXCEPTION 'status clause matched % times (expected 1)', v_cnt;
  END IF;
  EXECUTE format(
    'CREATE OR REPLACE FUNCTION public.event_catalogue_drift_scan(p_days_ahead integer DEFAULT 400) '
    || 'RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER '
    || 'SET search_path TO ''public'', ''pg_temp'' AS %L', replace(v_def, v_old, v_new));
END
$do$;

COMMENT ON FUNCTION public.event_catalogue_drift_scan(integer) IS
  'Daily catalogue sweep over every upcoming event carried by more than one source: records date drift (>1 day), venue drift (normalised names sharing nothing) and status drift into event_catalogue_drift, resolves rows that agree again, then queues SeatGeek re-pulls for what is still in doubt. Status vocabulary is GoTickets RESCHEDULED/CANCELLED/POSTPONED/MERGED (normal is AS_SCHEDULED, NOT "active" — a looser rule flagged 4,391 of 7,915 events on the first run) and TEvo state=''rescheduled'' (normal is ''shown''). Both cross-source joins are LATERAL/LIMIT 1 because 444 events carry multiple sg_events_canonical rows. D0 mig 20260914230000.';

DELETE FROM public.event_catalogue_drift WHERE drift_kind = 'status';
;

-- Brings the DORMANT tree copy of the EVO poller in line with the live one's scope gate.
--
-- READ THIS BEFORE CITING THIS MIGRATION. It does NOT gate the running EVO poller and it did NOT
-- end the EVO deals starvation. Corrected 2026-09-20 after the merge of main; the original header
-- here claimed both, and the claim was wrong.
--
-- What actually runs: cron `evo_listings_poll_2min` (jobid 321) calls public.listings_poll_tick(120).
-- public.evo_listings_poll_tick(int) — created by mig 20260601120000, patched here — is called by
-- NO cron and no other function. Mig 20260917030000 (another session) records the same drift and
-- captured the live listings_poll_tick body into the tree with the gate line added.
--
-- Who fixed the starvation: mig 20260917003300 / 003814 (another session), applied 2026-09-17
-- 00:33Z, which introduced listings_poll_scope_enabled() + v_listings_poll_scope_events and gated
-- the LIVE listings_poll_tick. EVO feed rows per hour went 13 (23:00Z) -> 26 (00:00Z) -> 117
-- (01:00Z). THIS migration applied at 09:03Z, ~8.5 hours after the recovery, when the rate was
-- back to 3/hour. The measurements the original header quoted (3,916 addressable events, 30 polled
-- per 30 minutes, 38.3h average revisit, 1,228 EVO rows on 09-11 down to 37 by 09-16) were real,
-- but they describe the condition the OTHER session's migration cured.
--
-- Why this is kept rather than reverted: it is already applied to prod, and it stops the dormant
-- function being a trap if anyone ever repoints cron 321 back at it. One policy, one view — never
-- add a second scope list. That is its whole value; it changes no live behaviour.
DO $do$
DECLARE
  v_src text; v_args text; v_cfg text[]; v_set text := ''; v_kv text; v_a text;
BEGIN
  SELECT p.prosrc, pg_get_function_arguments(p.oid), p.proconfig INTO v_src, v_args, v_cfg
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'evo_listings_poll_tick';
  IF v_src IS NULL THEN
    RAISE EXCEPTION 'evo_listings_poll_tick not found';
  END IF;
  IF position('listings_poll_scope_enabled' in v_src) > 0 THEN
    RETURN;   -- already gated (possibly by the session that built the policy) — leave it alone
  END IF;

  -- Carry the function's existing SET clauses across verbatim rather than retyping search_path.
  FOREACH v_kv IN ARRAY coalesce(v_cfg, ARRAY[]::text[]) LOOP
    v_set := v_set || format(' SET %I TO %s', split_part(v_kv, '=', 1),
                             substr(v_kv, strpos(v_kv, '=') + 1));
  END LOOP;

  v_a := E'        AND coalesce(e.state, ''shown'') <> ''ignored''\n    ),';
  IF (length(v_src) - length(replace(v_src, v_a, ''))) / length(v_a) <> 1 THEN
    RAISE EXCEPTION 'evo candidate-filter anchor did not match exactly once';
  END IF;

  v_src := replace(v_src, v_a,
    E'        AND coalesce(e.state, ''shown'') <> ''ignored''\n'
    '        -- SCOPE GATE (migs 20260917003300/003814, joined here by 20260917100000): while the\n'
    '        -- policy is enabled, only events we hold a position in (CRM / N2S / SG orders /\n'
    '        -- GT purchases). Same predicate gt_listings_poll_tick uses. Flip the policy to widen.\n'
    '        AND (NOT public.listings_poll_scope_enabled()\n'
    '             OR e.id IN (SELECT tevo_event_id FROM public.v_listings_poll_scope_events))\n'
    '    ),');

  EXECUTE format(
    'CREATE OR REPLACE FUNCTION public.evo_listings_poll_tick(%s) RETURNS integer '
    'LANGUAGE plpgsql SECURITY DEFINER%s AS %s',
    v_args, v_set, quote_literal(v_src));
END
$do$;

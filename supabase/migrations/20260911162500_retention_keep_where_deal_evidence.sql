-- ============================================================================
-- Migration 20260911162500 — the listings cleanup must not delete the listings a deal is built on
--
-- Lane:     D0 (deals surface) · the engine is A1's — cross-lane, under operator direction, bot_chat flagged
-- Touches:  retention_policy (+keep_where, +guard trigger, 2 rows set) ·
--           retention_tick(int) (CREATE OR REPLACE — honours keep_where) ·
--           deal_listing_spell (+index for the exemption probe)
-- Pre-reqs: 20260705153000 (retention engine), 20260911162300 (deal_listing_spell)
--
-- Operator 2026-09-11: "during the evo/go listing cleanup, retain these listings".
--
-- ── WHAT WAS TRUE BEFORE ───────────────────────────────────────────────────
-- Both listing firehoses are swept on a 15-day TTL by retention_tick:
--   gotickets_listings_snapshots  keep_days 15, enabled, 1,081,068 deleted last tick (522M lifetime)
--   listings_snapshots (EVO)      keep_days 15, enabled,   862,028 deleted last tick (765M lifetime)
-- Every flagged deal points at a row in one of them: gotickets_deals_feed carries
-- (gt_listing_id, gt_captured_at) and deal_listing_spell records the stretch a listing spent
-- underpriced. The sweep does not know that, so a deal's own evidence is destroyed on a rolling
-- 15-day basis while the deal record outlives it.
--
-- Measured 2026-09-11: 1,988 of 5,679 spells (35%) entered more than 15 days ago, so the listing
-- rows behind them are already gone. grade_deal_outcomes(), the 162200 exclusion re-check and any
-- future price-model work all join back to these tables; each loses its basis at day 15.
--
-- ── THE RULE ───────────────────────────────────────────────────────────────
-- retention_policy gains `keep_where`: a SQL predicate over alias `t`. Rows matching it are NEVER
-- deleted by the sweep; everything else ages out on the same TTL as before. The firehoses keep
-- their 15-day TTL — only the listings a deal was actually built on are held back.
--
-- Cost is bounded and one-directional: the probe is an index lookup into deal_listing_spell
-- (thousands of rows), not a scan of the firehose, so the sweep's plan is unchanged for the
-- 99.9% of rows that are not exempt. A malformed predicate makes the DELETE raise, which the
-- engine records in last_error and skips — it fails toward KEEPING data, never toward deleting it.
--
-- SAFETY: keep_where is raw SQL spliced into a statement run by a SECURITY DEFINER function, so
-- trg_retention_policy_keep_where_guard rejects any value carrying a statement separator or a
-- DDL/DML keyword. retention_policy is service-role-only to begin with; this is defence in depth.
--
-- ROLLBACK: UPDATE retention_policy SET keep_where = NULL WHERE table_name IN (...);  the engine
-- treats NULL as "no exemption" and behaves exactly as it did before this migration.
-- ============================================================================

-- ── 1. The exemption predicate lives on the policy row ───────────────────────
ALTER TABLE public.retention_policy ADD COLUMN IF NOT EXISTS keep_where text;
COMMENT ON COLUMN public.retention_policy.keep_where IS
  'Optional SQL predicate over alias `t` (the table being swept). Rows matching it are NEVER deleted; NULL/blank means no exemption and the sweep behaves as it did before mig 20260911162500. Raw SQL spliced into a SECURITY DEFINER statement — guarded by trg_retention_policy_keep_where_guard.';

CREATE OR REPLACE FUNCTION public.retention_policy_keep_where_guard()
RETURNS trigger
LANGUAGE plpgsql
AS $fn$
DECLARE
  v_txt   text;
  v_depth int := 0;
  i       int;
  ch      text;
BEGIN
  IF NEW.keep_where IS NULL OR btrim(NEW.keep_where) = '' THEN
    RETURN NEW;
  END IF;
  v_txt := NEW.keep_where;

  IF v_txt LIKE '%;%' THEN
    RAISE EXCEPTION 'keep_where may not contain a statement separator: %', v_txt USING ERRCODE = '22023';
  END IF;
  IF v_txt LIKE '%--%' OR v_txt LIKE '%/*%' OR v_txt LIKE '%*/%' THEN
    RAISE EXCEPTION 'keep_where may not contain a SQL comment: %', v_txt USING ERRCODE = '22023';
  END IF;
  IF v_txt ~* '\m(drop|delete|insert|update|alter|grant|revoke|truncate|create|copy|vacuum|reindex)\M' THEN
    RAISE EXCEPTION 'keep_where must be a read-only predicate, found a write keyword: %', v_txt USING ERRCODE = '22023';
  END IF;

  -- Parentheses must balance and never close below zero. The engine splices the predicate as
  -- `AND NOT (<keep_where>)`; an unbalanced value escapes that wrapper and rewrites the whole
  -- WHERE clause. `true) OR (1=1` would turn the sweep into "delete every row, cutoff ignored"
  -- — caught by this migration's own guard test before it could reach a real policy row.
  FOR i IN 1 .. length(v_txt) LOOP
    ch := substr(v_txt, i, 1);
    IF ch = '(' THEN v_depth := v_depth + 1;
    ELSIF ch = ')' THEN
      v_depth := v_depth - 1;
      IF v_depth < 0 THEN
        RAISE EXCEPTION 'keep_where has an unbalanced closing parenthesis — it would escape the AND NOT (...) wrapper: %', v_txt
          USING ERRCODE = '22023';
      END IF;
    END IF;
  END LOOP;
  IF v_depth <> 0 THEN
    RAISE EXCEPTION 'keep_where has % unclosed parenthesis/es: %', v_depth, v_txt USING ERRCODE = '22023';
  END IF;

  RETURN NEW;
END;
$fn$;
COMMENT ON FUNCTION public.retention_policy_keep_where_guard() IS
  'Rejects a retention_policy.keep_where that could escape the engine''s `AND NOT (...)` wrapper: statement separators, SQL comments, DDL/DML keywords, and unbalanced parentheses (`true) OR (1=1` would otherwise turn the sweep into a full-table delete with the cutoff ignored). The predicate runs inside SECURITY DEFINER retention_tick, so it must stay a read-only, self-contained boolean expression. D0 mig 20260911162500.';

DROP TRIGGER IF EXISTS trg_retention_policy_keep_where_guard ON public.retention_policy;
CREATE TRIGGER trg_retention_policy_keep_where_guard
  BEFORE INSERT OR UPDATE ON public.retention_policy
  FOR EACH ROW EXECUTE FUNCTION public.retention_policy_keep_where_guard();

-- ── 2. The exemption probe must be an index lookup, not a scan ───────────────
CREATE INDEX IF NOT EXISTS deal_listing_spell_source_listing_idx
  ON public.deal_listing_spell (source, listing_id);

-- ── 3. The engine honours keep_where ─────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.retention_tick(p_global_budget_seconds integer DEFAULT 240)
RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_tick_start timestamptz := clock_timestamp();
  v_pol        RECORD;
  v_cutoff     timestamptz;
  v_pol_start  timestamptz;
  v_batch      bigint;
  v_pol_total  bigint;
  v_total      bigint := 0;
  v_colcheck   boolean;
  v_keep       text;
BEGIN
  IF current_user NOT IN ('service_role','postgres','supabase_admin') THEN
    RAISE EXCEPTION 'forbidden: retention_tick is service-only' USING ERRCODE='42501';
  END IF;

  FOR v_pol IN
    SELECT * FROM public.retention_policy WHERE enabled ORDER BY priority, table_name
  LOOP
    EXIT WHEN clock_timestamp() - v_tick_start > make_interval(secs => p_global_budget_seconds);

    IF to_regclass('public.' || v_pol.table_name) IS NULL THEN
      UPDATE public.retention_policy
         SET last_error = 'table not found', last_run_at = now(), updated_at = now()
       WHERE table_name = v_pol.table_name;
      CONTINUE;
    END IF;
    SELECT EXISTS (
      SELECT 1 FROM information_schema.columns
       WHERE table_schema='public' AND table_name=v_pol.table_name AND column_name=v_pol.ts_column
    ) INTO v_colcheck;
    IF NOT v_colcheck THEN
      UPDATE public.retention_policy
         SET last_error = format('ts_column %s not found', v_pol.ts_column),
             last_run_at = now(), updated_at = now()
       WHERE table_name = v_pol.table_name;
      CONTINUE;
    END IF;

    -- Rows matching keep_where are held back from this sweep entirely (mig 20260911162500).
    v_keep := CASE
                WHEN v_pol.keep_where IS NULL OR btrim(v_pol.keep_where) = '' THEN ''
                ELSE ' AND NOT (' || v_pol.keep_where || ')'
              END;

    v_cutoff    := now() - make_interval(days => v_pol.keep_days);
    v_pol_start := clock_timestamp();
    v_pol_total := 0;

    BEGIN
      LOOP
        EXIT WHEN clock_timestamp() - v_pol_start  > make_interval(secs => v_pol.budget_seconds);
        EXIT WHEN clock_timestamp() - v_tick_start > make_interval(secs => p_global_budget_seconds);
        EXECUTE format(
          'WITH del AS (SELECT t.ctid FROM public.%I t WHERE t.%I < $1%s LIMIT $2) '
          'DELETE FROM public.%I WHERE ctid IN (SELECT ctid FROM del)',
          v_pol.table_name, v_pol.ts_column, v_keep, v_pol.table_name)
        USING v_cutoff, v_pol.batch_rows;
        GET DIAGNOSTICS v_batch = ROW_COUNT;
        v_pol_total := v_pol_total + v_batch;
        EXIT WHEN v_batch = 0;
      END LOOP;

      UPDATE public.retention_policy
         SET last_run_at = now(), last_deleted = v_pol_total,
             total_deleted = total_deleted + v_pol_total,
             last_error = NULL, updated_at = now()
       WHERE table_name = v_pol.table_name;
      INSERT INTO public.retention_run_log (table_name, cutoff, deleted, duration_ms, note)
      VALUES (v_pol.table_name, v_cutoff, v_pol_total,
              (extract(epoch FROM clock_timestamp() - v_pol_start) * 1000)::int,
              CASE WHEN v_pol_total = 0 THEN 'clean' ELSE NULL END);

    EXCEPTION
      WHEN query_canceled THEN
        UPDATE public.retention_policy
           SET last_run_at = now(), last_error = 'query_canceled (statement_timeout)',
               updated_at = now()
         WHERE table_name = v_pol.table_name;
        RETURN v_total + v_pol_total;
      WHEN OTHERS THEN
        UPDATE public.retention_policy
           SET last_run_at = now(), last_error = left(SQLERRM, 500), updated_at = now()
         WHERE table_name = v_pol.table_name;
        INSERT INTO public.retention_run_log (table_name, cutoff, deleted, duration_ms, note)
        VALUES (v_pol.table_name, v_cutoff, v_pol_total, NULL, 'ERROR: ' || left(SQLERRM, 300));
    END;

    v_total := v_total + v_pol_total;
  END LOOP;

  RETURN v_total;
END
$function$;
COMMENT ON FUNCTION public.retention_tick(integer) IS
  'TTL sweeper driven by retention_policy. Honours keep_where: rows matching that predicate are never deleted (mig 20260911162500 — the two listing firehoses hold back the listings a flagged deal was built on). A malformed predicate raises, is recorded in last_error and skips the table, so the failure mode is keeping data, not losing it.';

-- ── 4. Hold back the listings a deal was built on ────────────────────────────
UPDATE public.retention_policy
   SET keep_where = 'EXISTS (SELECT 1 FROM public.deal_listing_spell s WHERE s.source = ''gotickets'' AND s.listing_id = t.gt_listing_id)',
       notes = notes || ' KEEP_WHERE (mig 20260911162500, operator "during the evo/go listing cleanup, retain these listings"): rows whose gt_listing_id appears in deal_listing_spell are never swept — a flagged deal''s own evidence outlives the 15-day TTL.',
       updated_at = now()
 WHERE table_name = 'gotickets_listings_snapshots';

UPDATE public.retention_policy
   SET keep_where = 'EXISTS (SELECT 1 FROM public.deal_listing_spell s WHERE s.source = ''evo'' AND s.listing_id = -t.tevo_ticket_group_id)',
       notes = notes || ' KEEP_WHERE (mig 20260911162500, operator "during the evo/go listing cleanup, retain these listings"): rows whose tevo_ticket_group_id appears in deal_listing_spell (EVO listing_id is the NEGATED ticket-group id, the feed convention) are never swept.',
       updated_at = now()
 WHERE table_name = 'listings_snapshots';

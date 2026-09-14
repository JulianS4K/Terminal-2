-- Migration 20260911030000 · level:data-collection · lane:D7 · writes:retention_policy,sweep_old_sg_listings · reads:none · pre:20260705153000
--
-- Already applied to prod · via MCP 2026-09-11 under operator direction.
-- ============================================================================
-- Migration 20260911030000 — SeatGeek snapshots are NEVER purged
--
-- Lane:     D7 (operator-directed; the surfaces are A1's — flagged in bot_chat)
-- Touches:  retention_policy (W: 2 rows + a BEFORE trigger),
--           sweep_old_sg_listings() (fn replace: now refuses to run)
-- Pre-reqs: 20260705153000 (retention_policy engine), 20260527230000 (the sweep fn)
--
-- Operator 2026-09-11: "save every SeatGeek snapshot".
--
-- ── WHAT WAS TRUE BEFORE ───────────────────────────────────────────────────
-- Nothing purges SeatGeek snapshots today — but only by accident of state, not
-- by rule. Measured 2026-09-11 02:30 UTC:
--   seatgeek_listings_snapshots  ~18.2M rows / 18 GB, oldest 2026-05-15, never swept
--   seatgeek_sales_snapshots     ~21.1M rows / 12 GB, oldest 2026-05-09, never swept
-- Two dormant paths could change that without anyone deciding to:
--   1. retention_policy rows for both tables exist with keep_days=30 and
--      enabled=false, and their notes say "flip enabled=true with (or after)
--      the SG-listings resume" (mig 20260705153000, KANBAN A1-OPS-29 item 3).
--      The SG on-demand puller IS the resume (20260910140000): the next person
--      to read that note would follow it and drain four months of history to 30d.
--   2. sweep_old_sg_listings(p_hours) — retired from cron but "kept for manual
--      use". One manual call with its default (48h) deletes everything older
--      than two days.
--
-- ── THE RULE ───────────────────────────────────────────────────────────────
-- Both SeatGeek snapshot tables are retained INDEFINITELY. The rule lives in
-- the same table the engine reads, so it cannot drift from the engine:
--   * retention_policy rows stay enabled=false and carry meta.never_purge=true
--     with the directive text. keep_days is left as-is (the CHECK floor is 3;
--     the value is inert while the row is disabled).
--   * A BEFORE INSERT OR UPDATE trigger on retention_policy REFUSES enabled=true
--     on any row whose meta.never_purge is true. Re-enabling therefore takes a
--     reviewed migration that first clears the flag — an explicit act, not a
--     note followed in good faith.
--   * sweep_old_sg_listings() keeps its signature but now raises. The old body
--     is in git (20260527230000) if it is ever wanted back.
-- Not changed: the drain's ON CONFLICT DO NOTHING on (tevo_event_id, sglid,
-- content_hash). A re-pull of a listing whose price and quantity did not move
-- still does not write a duplicate row — that is change-only persistence
-- (A1-OPS-17), a different decision from retention, and it is left alone.
--
-- Cross-lane: retention_policy + sweep_old_sg_listings are A1's retention
-- surface (RESOURCES_BIBLE §2.14). Operator-directed; flagged to A1 in bot_chat.
-- Idempotent: every step is ON CONFLICT / OR REPLACE / IF NOT EXISTS; the
-- self-check at the end fails loudly if the guard is not in force.
-- ============================================================================

-- ── 1. The guard: a never_purge row can never be enabled ───────────────────
CREATE OR REPLACE FUNCTION public.retention_policy_never_purge_guard()
RETURNS trigger
LANGUAGE plpgsql
SET search_path TO 'public', 'pg_temp'
AS $fn$
BEGIN
  IF NEW.enabled AND coalesce((NEW.meta->>'never_purge')::boolean, false) THEN
    RAISE EXCEPTION 'retention_policy.% is marked never_purge (%): clear meta.never_purge in a reviewed migration before enabling',
      NEW.table_name, coalesce(NEW.meta->>'directive', 'no directive text')
      USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END $fn$;

COMMENT ON FUNCTION public.retention_policy_never_purge_guard() IS
  'BEFORE INSERT/UPDATE guard on retention_policy: refuses enabled=true on any row whose meta.never_purge is true (mig 20260911030000). Re-enabling such a table takes a migration that clears the flag first.';

DROP TRIGGER IF EXISTS trg_retention_policy_never_purge ON public.retention_policy;
CREATE TRIGGER trg_retention_policy_never_purge
  BEFORE INSERT OR UPDATE ON public.retention_policy
  FOR EACH ROW EXECUTE FUNCTION public.retention_policy_never_purge_guard();

-- ── 2. The two SeatGeek rows: disabled + flagged, notes rewritten ───────────
INSERT INTO public.retention_policy
  (table_name, ts_column, keep_days, enabled, batch_rows, budget_seconds, priority, notes, meta)
VALUES
  ('seatgeek_listings_snapshots', 'captured_at', 30, false, 20000, 60, 70,  NULL, NULL),
  ('seatgeek_sales_snapshots',    'pulled_at',   30, false, 50000, 60, 100, NULL, NULL)
ON CONFLICT (table_name) DO NOTHING;

UPDATE public.retention_policy
   SET enabled    = false,
       meta       = coalesce(meta, '{}'::jsonb) || jsonb_build_object(
                      'never_purge', true,
                      'directive',   'operator 2026-09-11: save every SeatGeek snapshot',
                      'set_by_mig',  '20260911030000'),
       notes      = 'NEVER PURGED — operator directive 2026-09-11 ("save every SeatGeek snapshot"), mig 20260911030000. '
                 || 'Row kept so the engine has a record; enabled=true is refused by trg_retention_policy_never_purge while meta.never_purge is set. '
                 || 'Supersedes the 20260705153000 note ("flip enabled=true with the SG-listings resume") — do NOT flip. '
                 || 'keep_days is inert while disabled (CHECK floor is 3).',
       updated_at = now()
 WHERE table_name IN ('seatgeek_listings_snapshots', 'seatgeek_sales_snapshots');

-- ── 3. The manual sweep refuses to run ─────────────────────────────────────
CREATE OR REPLACE FUNCTION public.sweep_old_sg_listings(p_hours integer DEFAULT 48)
RETURNS integer
LANGUAGE plpgsql
SET search_path TO 'public', 'pg_temp'
AS $fn$
BEGIN
  RAISE EXCEPTION 'sweep_old_sg_listings is retired: seatgeek_listings_snapshots is never purged (operator directive 2026-09-11, mig 20260911030000); p_hours=% ignored', p_hours
    USING ERRCODE = 'feature_not_supported';
END $fn$;

REVOKE ALL ON FUNCTION public.sweep_old_sg_listings(integer) FROM PUBLIC, anon, authenticated;

COMMENT ON FUNCTION public.sweep_old_sg_listings(integer) IS
  'RETIRED 2026-09-11 (mig 20260911030000): raises on every call. seatgeek_listings_snapshots is never purged by operator directive. Prior body (24h/48h ctid-batched DELETE, superseded by retention_tick 20260705153000) is in git history.';

-- ── 4. Self-check: the rule is in force, and the guard actually refuses ─────
DO $do$
DECLARE v_n int; v_refused boolean := false;
BEGIN
  SELECT count(*) INTO v_n FROM public.retention_policy
   WHERE table_name IN ('seatgeek_listings_snapshots', 'seatgeek_sales_snapshots')
     AND enabled = false AND (meta->>'never_purge')::boolean;
  IF v_n <> 2 THEN
    RAISE EXCEPTION 'expected both SeatGeek retention rows disabled + never_purge, found %', v_n;
  END IF;

  BEGIN
    UPDATE public.retention_policy SET enabled = true WHERE table_name = 'seatgeek_listings_snapshots';
  EXCEPTION WHEN check_violation THEN
    v_refused := true;
  END;
  IF NOT v_refused THEN
    RAISE EXCEPTION 'guard did not refuse enabled=true on a never_purge row — trigger not in force';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'sweep_old_sg_listings' AND prosrc ILIKE '%never purged%') THEN
    RAISE EXCEPTION 'sweep_old_sg_listings still carries a DELETE body';
  END IF;
END $do$;

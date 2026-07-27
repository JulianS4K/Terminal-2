-- ============================================================
-- bot_chat backlog: implement the documented status-reply auto-resolve + clear auto-noise.
-- A1 2026-06-08. ## Applied via MCP after review. (Cross-lane: v_bot_chat_unresolved is
-- C1-owned — this lands the fix B1 flagged in bot_chat 233; C1 cc'd.)
--
-- TWO problems left the unresolved view at 1,321 rows (only ~4 real):
--  1. CLAUDE.md §1 documents "a `status` reply auto-resolves its parent thread", but the
--     view was just `WHERE resolved_at IS NULL` — the auto-resolve was never implemented
--     (B1 drift report, bot_chat 233). FIX: exclude any row that has a `status` reply
--     pointing at it via in_reply_to.
--  2. Two auto-posters flooded it and never self-resolve: the 15-min SG-429 health flag
--     (252 rows) and the movers "0 upserted" per-combo status (676 rows). FIX: one-time
--     bulk-resolve of the auto-noise (all `status`, all SG_BROKER_429 flags, and stale
--     change_log/sync/broadcast). Real flag/question/collision/p0_security are untouched.
--     (The movers source of the status spam is itself fixed by 20260608031000.)
-- ============================================================

-- 1) View: implement the status-reply auto-resolve (matches CLAUDE.md §1).
CREATE OR REPLACE VIEW public.v_bot_chat_unresolved AS
SELECT b.id, b.bot_level, b.bot_lane, b.event_type, b.message, b.related_pr, b.related_mig,
       b.in_reply_to, b.acked_at, b.acked_by, b.created_at,
       EXTRACT(epoch FROM now() - b.created_at) / 3600::numeric AS hours_open
FROM public.bot_chat b
WHERE b.resolved_at IS NULL
  AND NOT EXISTS (
    SELECT 1 FROM public.bot_chat r
    WHERE r.in_reply_to = b.id AND r.event_type = 'status')
ORDER BY (CASE b.event_type
    WHEN 'p0_security' THEN 1 WHEN 'collision' THEN 2 WHEN 'flag' THEN 3
    WHEN 'question' THEN 4 WHEN 'status' THEN 5 WHEN 'sync' THEN 6
    WHEN 'change_log' THEN 7 WHEN 'broadcast' THEN 8 ELSE NULL END), b.created_at;

REVOKE ALL ON public.v_bot_chat_unresolved FROM PUBLIC, anon, authenticated, coworker_readonly;

-- 2) One-time bulk-resolve of the accumulated auto-noise (keeps real, recent flags/questions).
UPDATE public.bot_chat
  SET resolved_at = now(),
      resolved_by = 'admin/A1',
      meta = COALESCE(meta,'{}'::jsonb) || jsonb_build_object('resolve_note','bulk auto-noise sweep mig 20260608032000')
WHERE resolved_at IS NULL
  AND (
        event_type = 'status'                                   -- movers/discovery auto-status spam
     OR message LIKE 'SG_BROKER_429%'                           -- 429 health auto-flags
     OR (event_type IN ('change_log','sync','broadcast') AND created_at < now() - interval '3 days')
  );

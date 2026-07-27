-- Migration 20260515340050 · admin · C1 · writes:public.v_bot_chat_unresolved (replace) · pre:20260515330000
-- Cluster D-1 of docs/audit-2026-05-15-consolidation-plan.md; implements A1 Q2 (bot_chat 138).
--
-- Auto-excludes rows that have a child row with event_type='status' (canonical closure signal).
-- Other reply types ('flag','question','change_log',...) leave the parent open.
-- Discipline tightening documented in docs/bot_chat_conventions.md + LANE_DISCIPLINE.md.

CREATE OR REPLACE VIEW public.v_bot_chat_unresolved AS
SELECT bc.id,
       bc.bot_level,
       bc.bot_lane,
       bc.event_type,
       bc.message,
       bc.related_pr,
       bc.related_mig,
       bc.in_reply_to,
       bc.acked_at,
       bc.acked_by,
       bc.created_at,
       EXTRACT(epoch FROM now() - bc.created_at) / 3600::numeric AS hours_open
FROM public.bot_chat bc
WHERE bc.resolved_at IS NULL
  AND NOT EXISTS (
    SELECT 1
    FROM public.bot_chat reply
    WHERE reply.in_reply_to = bc.id
      AND reply.event_type = 'status'
  )
ORDER BY
  CASE bc.event_type
    WHEN 'p0_security' THEN 1
    WHEN 'collision'   THEN 2
    WHEN 'flag'        THEN 3
    WHEN 'question'    THEN 4
    WHEN 'status'      THEN 5
    WHEN 'sync'        THEN 6
    WHEN 'change_log'  THEN 7
    WHEN 'broadcast'   THEN 8
    ELSE NULL
  END,
  bc.created_at;

COMMENT ON VIEW public.v_bot_chat_unresolved IS
  'Unresolved bot_chat rows. Auto-excludes rows that received a status reply (canonical closure signal). Per docs/bot_chat_conventions.md.';

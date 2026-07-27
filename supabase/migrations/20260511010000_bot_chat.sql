-- Migration 20260511010000 · level:admin · lane:Audit/Push · writes:bot_chat,v_bot_chat_unresolved,bot_chat_log(),bot_chat_resolve() · pre:none
-- Cross-lane communication layer. Replaces ad-hoc PR comments / KANBAN chatter.
-- See START_HERE.md §"Hard rules" for usage.

CREATE TABLE IF NOT EXISTS bot_chat (
  id            bigserial PRIMARY KEY,
  bot_level     text NOT NULL CHECK (bot_level IN
                  ('admin','security','supervisor','primary-sales','secondary-sales','data-collection')),
  bot_lane      text NOT NULL,
  event_type    text NOT NULL CHECK (event_type IN
                  ('change_log','question','flag','sync','status','collision','broadcast','p0_security')),
  message       text NOT NULL,                                -- single field; subject+body merged
  related_pr    int,
  related_mig   text,
  in_reply_to   bigint REFERENCES bot_chat(id),
  acked_at      timestamptz,
  acked_by      text,                                          -- "<level>/<lane>"
  resolved_at   timestamptz,
  resolved_by   text,
  meta          jsonb,
  created_at    timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS bot_chat_level_idx     ON bot_chat (bot_level, created_at DESC);
CREATE INDEX IF NOT EXISTS bot_chat_event_idx     ON bot_chat (event_type, resolved_at);
CREATE INDEX IF NOT EXISTS bot_chat_unresolved_ix ON bot_chat (created_at DESC) WHERE resolved_at IS NULL;
CREATE INDEX IF NOT EXISTS bot_chat_pr_idx        ON bot_chat (related_pr) WHERE related_pr IS NOT NULL;

CREATE OR REPLACE VIEW v_bot_chat_unresolved AS
SELECT id, bot_level, bot_lane, event_type, message, related_pr, related_mig,
       in_reply_to, acked_at, acked_by, created_at,
       extract(epoch FROM (now() - created_at))/3600 AS hours_open
FROM bot_chat
WHERE resolved_at IS NULL
ORDER BY
  CASE event_type
    WHEN 'p0_security' THEN 1 WHEN 'collision' THEN 2 WHEN 'flag' THEN 3
    WHEN 'question' THEN 4 WHEN 'status' THEN 5 WHEN 'sync' THEN 6
    WHEN 'change_log' THEN 7 WHEN 'broadcast' THEN 8
  END,
  created_at;

CREATE OR REPLACE FUNCTION public.bot_chat_log(
  p_level text, p_lane text, p_event_type text, p_message text,
  p_related_pr int DEFAULT NULL, p_related_mig text DEFAULT NULL,
  p_in_reply_to bigint DEFAULT NULL, p_meta jsonb DEFAULT NULL
) RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_id bigint;
BEGIN
  -- Defense-in-depth: only service_role may invoke (grants enforce; assert at body in case grants ever widen).
  IF current_user NOT IN ('service_role', 'postgres') THEN
    RAISE EXCEPTION 'bot_chat_log: caller % not authorized', current_user;
  END IF;
  INSERT INTO bot_chat (bot_level, bot_lane, event_type, message,
                        related_pr, related_mig, in_reply_to, meta)
  VALUES (p_level, p_lane, p_event_type, p_message,
          p_related_pr, p_related_mig, p_in_reply_to, p_meta)
  RETURNING id INTO v_id;
  RETURN v_id;
END $$;

CREATE OR REPLACE FUNCTION public.bot_chat_resolve(
  p_id bigint, p_resolver_level text, p_resolver_lane text, p_note text DEFAULT NULL
) RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_event_type text;
BEGIN
  IF current_user NOT IN ('service_role', 'postgres') THEN
    RAISE EXCEPTION 'bot_chat_resolve: caller % not authorized', current_user;
  END IF;
  SELECT event_type INTO v_event_type FROM bot_chat WHERE id = p_id;
  IF v_event_type IS NULL THEN RAISE EXCEPTION 'bot_chat row % not found', p_id; END IF;
  IF p_resolver_level = 'admin' THEN NULL;
  ELSIF p_resolver_level = 'security' AND v_event_type IN ('p0_security','flag') THEN NULL;
  ELSE RAISE EXCEPTION 'level=% cannot resolve event_type=%', p_resolver_level, v_event_type;
  END IF;
  UPDATE bot_chat
     SET resolved_at = now(),
         resolved_by = p_resolver_level || '/' || p_resolver_lane,
         meta = COALESCE(meta,'{}'::jsonb) || jsonb_build_object('resolve_note', p_note)
   WHERE id = p_id;
  RETURN true;
END $$;

-- Lockdown per B1 review on PR #64 (CRIT + 2 HIGH):
-- (a) CRIT: coworker_readonly auto-inherits SELECT via 20260509460000 ALTER DEFAULT PRIVILEGES.
--     UI role must not read p0_security broadcasts or any cross-bot message → explicit REVOKE.
-- (b) HIGH: authenticated grants + open RLS policies allow level spoofing via PostgREST. Removed.
-- (c) HIGH: bot_chat_resolve no longer trusts caller-claimed level — function asserts current_user.
REVOKE ALL ON bot_chat FROM PUBLIC, anon, authenticated, coworker_readonly;
REVOKE ALL ON v_bot_chat_unresolved FROM PUBLIC, anon, authenticated, coworker_readonly;
REVOKE EXECUTE ON FUNCTION public.bot_chat_log(text, text, text, text, int, text, bigint, jsonb)
  FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.bot_chat_resolve(bigint, text, text, text)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON SEQUENCE bot_chat_id_seq FROM PUBLIC, anon, authenticated, coworker_readonly;

GRANT SELECT, INSERT ON bot_chat TO service_role;
GRANT SELECT ON v_bot_chat_unresolved TO service_role;
GRANT EXECUTE ON FUNCTION public.bot_chat_log TO service_role;
GRANT EXECUTE ON FUNCTION public.bot_chat_resolve TO service_role;
GRANT USAGE, SELECT ON SEQUENCE bot_chat_id_seq TO service_role;

ALTER TABLE bot_chat ENABLE ROW LEVEL SECURITY;
-- service_role bypasses RLS by design. No authenticated/anon policies — they have no grant.
-- If per-bot JWT auth lands later, add policies deriving level/lane from claims.

INSERT INTO bot_chat (bot_level, bot_lane, event_type, message, meta)
VALUES (
  'admin', 'Audit/Push', 'broadcast',
  'FRESH START. Read START_HERE.md. Hierarchy in docs/bot-hierarchy.mermaid. Rules in MIGRATION_CONVENTIONS.md. Existing bots: rebase on main, post status confirming aligned.',
  jsonb_build_object(
    'fresh_start_at', now()::text,
    'levels', ARRAY['admin','security','supervisor','primary-sales','secondary-sales','data-collection'],
    'events', ARRAY['change_log','question','flag','sync','status','collision','broadcast','p0_security']
  )
);

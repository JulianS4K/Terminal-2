-- ============================================================================
-- Migration 20260511010000 — bot_chat cross-bot communication layer
--
-- Level:    admin
-- Lane:     Audit / Push (xref + macro)
-- Touches:  bot_chat (W), v_bot_chat_unresolved (W), bot_chat_log() (W),
--           bot_chat_resolve() (W)
-- Pre-reqs: none
--
-- Establishes a single source-of-truth table for all lanes to log changes,
-- ask questions, flag issues, and coordinate. Replaces ad-hoc PR comment +
-- KANBAN.md chatter that's been the communication layer until now.
--
-- Schema notes:
--   * `bot_level` matches the 6 levels in docs/bot-hierarchy.mermaid:
--     admin / security / supervisor / primary-sales / secondary-sales /
--     data-collection. CHECK-constrained.
--   * `bot_lane` is the free-form lane name (e.g. "Terminal Front End")
--     because multiple bots can share a level (S1/S2/S3 all
--     secondary-sales; D1/D2 both data-collection).
--   * `event_type` is enum-like (text + CHECK) for forward-compat.
--   * Inserts open: any lane can write. Acks/resolves: admin always; security
--     only for security event_types.
--   * Rows are immutable except for ack/resolve columns (enforced via RLS).
-- ============================================================================

-- (1) Table
CREATE TABLE IF NOT EXISTS bot_chat (
  id                bigserial PRIMARY KEY,
  bot_level         text NOT NULL CHECK (bot_level IN (
                      'admin',
                      'security',
                      'supervisor',
                      'primary-sales',
                      'secondary-sales',
                      'data-collection'
                    )),
  bot_lane          text NOT NULL,                                    -- e.g. "Terminal Front End"
  event_type        text NOT NULL CHECK (event_type IN (
                      'change_log',  -- "I did X, here's the PR"
                      'question',    -- "How should I handle Y?"
                      'flag',        -- "I noticed Z, may need attention"
                      'sync',        -- "I rebased / merged / aligned"
                      'status',      -- "I'm working on / blocked / done"
                      'collision',   -- "Cross-lane conflict detected"
                      'broadcast',   -- "All lanes should know X" (admin only)
                      'p0_security'  -- "Veto-grade security issue" (security only)
                    )),
  subject           text NOT NULL,
  body              text,
  related_pr        int,                                              -- nullable: GH PR number
  related_migration text,                                              -- nullable: migration timestamp prefix
  related_table     text,                                              -- nullable: table name
  in_reply_to       bigint REFERENCES bot_chat(id),                    -- threading
  acked_at          timestamptz,
  acked_by_level    text,                                              -- level of acker
  acked_by_lane     text,
  resolved_at       timestamptz,
  resolved_by_level text,                                              -- level of resolver
  resolved_by_lane  text,
  meta              jsonb,
  created_at        timestamptz NOT NULL DEFAULT now()
);

-- (2) Indexes
CREATE INDEX IF NOT EXISTS bot_chat_level_idx           ON bot_chat (bot_level, created_at DESC);
CREATE INDEX IF NOT EXISTS bot_chat_lane_idx            ON bot_chat (bot_lane, created_at DESC);
CREATE INDEX IF NOT EXISTS bot_chat_event_type_idx      ON bot_chat (event_type, resolved_at);
CREATE INDEX IF NOT EXISTS bot_chat_unresolved_idx      ON bot_chat (created_at DESC) WHERE resolved_at IS NULL;
CREATE INDEX IF NOT EXISTS bot_chat_related_pr_idx      ON bot_chat (related_pr) WHERE related_pr IS NOT NULL;
CREATE INDEX IF NOT EXISTS bot_chat_in_reply_to_idx     ON bot_chat (in_reply_to) WHERE in_reply_to IS NOT NULL;

-- (3) Unresolved-queue view — what admin (and security for security-tagged) triages
CREATE OR REPLACE VIEW v_bot_chat_unresolved AS
SELECT
  c.id, c.bot_level, c.bot_lane, c.event_type, c.subject, c.body,
  c.related_pr, c.related_migration, c.related_table,
  c.in_reply_to, c.acked_at, c.acked_by_level, c.acked_by_lane,
  c.created_at,
  extract(epoch FROM (now() - c.created_at))/3600 AS hours_open,
  (SELECT count(*) FROM bot_chat r WHERE r.in_reply_to = c.id) AS reply_count
FROM bot_chat c
WHERE c.resolved_at IS NULL
ORDER BY
  CASE c.event_type
    WHEN 'p0_security' THEN 1
    WHEN 'collision'   THEN 2
    WHEN 'flag'        THEN 3
    WHEN 'question'    THEN 4
    WHEN 'status'      THEN 5
    WHEN 'sync'        THEN 6
    WHEN 'change_log'  THEN 7
    WHEN 'broadcast'   THEN 8
  END,
  c.created_at;

COMMENT ON VIEW v_bot_chat_unresolved IS
  'Triage queue ordered by event_type severity. Admin (and security for '
  'p0_security/flag) should drain this regularly.';

-- (4) Helper: convenience insert function for lanes
CREATE OR REPLACE FUNCTION public.bot_chat_log(
  p_level             text,
  p_lane              text,
  p_event_type        text,
  p_subject           text,
  p_body              text DEFAULT NULL,
  p_related_pr        int DEFAULT NULL,
  p_related_migration text DEFAULT NULL,
  p_related_table     text DEFAULT NULL,
  p_in_reply_to       bigint DEFAULT NULL,
  p_meta              jsonb DEFAULT NULL
)
RETURNS bigint
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_id bigint;
BEGIN
  INSERT INTO bot_chat (
    bot_level, bot_lane, event_type, subject, body,
    related_pr, related_migration, related_table, in_reply_to, meta
  ) VALUES (
    p_level, p_lane, p_event_type, p_subject, p_body,
    p_related_pr, p_related_migration, p_related_table, p_in_reply_to, p_meta
  )
  RETURNING id INTO v_id;
  RETURN v_id;
END $$;

COMMENT ON FUNCTION public.bot_chat_log IS
  'Convenience insert into bot_chat. Use from any lane to log a change, '
  'flag, question, etc. See START_HERE.md §3.4 for usage.';

-- (5) Resolver function — only admin always; security only for security-tagged
CREATE OR REPLACE FUNCTION public.bot_chat_resolve(
  p_id              bigint,
  p_resolver_level  text,
  p_resolver_lane   text,
  p_note            text DEFAULT NULL
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_event_type text;
BEGIN
  SELECT event_type INTO v_event_type FROM bot_chat WHERE id = p_id;
  IF v_event_type IS NULL THEN
    RAISE EXCEPTION 'bot_chat row % not found', p_id;
  END IF;

  -- Authorization check (soft, enforced by convention not RLS — RLS would
  -- need per-row policy keyed on auth.uid() which doesn't apply to bots)
  IF p_resolver_level = 'admin' THEN
    -- Admin can resolve anything
    NULL;
  ELSIF p_resolver_level = 'security' AND v_event_type IN ('p0_security', 'flag') THEN
    -- Security can resolve security-tagged items
    NULL;
  ELSE
    RAISE EXCEPTION 'bot_chat_resolve: level=% cannot resolve event_type=%',
                    p_resolver_level, v_event_type;
  END IF;

  UPDATE bot_chat
     SET resolved_at = now(),
         resolved_by_level = p_resolver_level,
         resolved_by_lane = p_resolver_lane,
         meta = COALESCE(meta, '{}'::jsonb) || jsonb_build_object('resolve_note', p_note)
   WHERE id = p_id;
  RETURN true;
END $$;

COMMENT ON FUNCTION public.bot_chat_resolve IS
  'Mark a bot_chat entry resolved. Admin can resolve anything; security can '
  'only resolve event_type IN (p0_security, flag).';

-- (6) Grants — everyone can read + log, only privileged roles can resolve
GRANT SELECT, INSERT ON bot_chat TO authenticated, service_role;
GRANT SELECT ON v_bot_chat_unresolved TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.bot_chat_log TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.bot_chat_resolve TO service_role;
GRANT USAGE, SELECT ON SEQUENCE bot_chat_id_seq TO authenticated, service_role;

-- (7) RLS — enable but permissive (any lane can insert; immutable post-insert
--     except via bot_chat_resolve())
ALTER TABLE bot_chat ENABLE ROW LEVEL SECURITY;

CREATE POLICY bot_chat_select_all
  ON bot_chat FOR SELECT
  TO authenticated, service_role
  USING (true);

CREATE POLICY bot_chat_insert_all
  ON bot_chat FOR INSERT
  TO authenticated, service_role
  WITH CHECK (true);

-- (8) Seed entry — the canonical "fresh start" broadcast
INSERT INTO bot_chat (
  bot_level, bot_lane, event_type, subject, body, meta
) VALUES (
  'admin',
  'Audit / Push',
  'broadcast',
  'FRESH START — all lanes, read START_HERE.md',
  'bot_chat is live. Going forward, log every change, flag, and question here. ' ||
  'Hierarchy is in docs/bot-hierarchy.mermaid. Rules are in MIGRATION_CONVENTIONS.md. ' ||
  'New bots: read START_HERE.md first. ' ||
  'Existing bots: this is your one-time sync point. Reset any in-flight state, ' ||
  'rebase on current main, and post a status entry confirming you are aligned.',
  jsonb_build_object(
    'fresh_start_at', now()::text,
    'docs_to_read', ARRAY['START_HERE.md', 'docs/bot-hierarchy.mermaid', 'AGENTS.md',
                          'MIGRATION_CONVENTIONS.md', 'DOCUMENTATION_INDEX.md', 'SCHEMA.md'],
    'levels_available', ARRAY['admin', 'security', 'supervisor',
                              'primary-sales', 'secondary-sales', 'data-collection'],
    'event_types_available', ARRAY['change_log', 'question', 'flag', 'sync', 'status',
                                    'collision', 'broadcast', 'p0_security']
  )
);

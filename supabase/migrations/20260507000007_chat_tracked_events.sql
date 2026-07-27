-- Auto-track chatbot-pinged events in the cron sweep.

ALTER TABLE events
  ADD COLUMN IF NOT EXISTS is_chat_tracked       boolean DEFAULT false,
  ADD COLUMN IF NOT EXISTS chat_first_pinged_at  timestamptz,
  ADD COLUMN IF NOT EXISTS chat_last_pinged_at   timestamptz,
  ADD COLUMN IF NOT EXISTS chat_ping_count       integer DEFAULT 0;

CREATE INDEX IF NOT EXISTS events_chat_tracked_idx
  ON events (is_chat_tracked, occurs_at_local) WHERE is_chat_tracked = true;

CREATE OR REPLACE FUNCTION mark_event_chat_tracked(p_event_id bigint)
RETURNS void LANGUAGE plpgsql AS $fn$
BEGIN
  INSERT INTO events (id, is_chat_tracked, chat_first_pinged_at, chat_last_pinged_at, chat_ping_count, last_seen)
  VALUES (p_event_id, true, now(), now(), 1, now())
  ON CONFLICT (id) DO UPDATE SET
    is_chat_tracked = true,
    chat_first_pinged_at = COALESCE(events.chat_first_pinged_at, now()),
    chat_last_pinged_at = now(),
    chat_ping_count = COALESCE(events.chat_ping_count, 0) + 1,
    last_seen = now();
END $fn$;

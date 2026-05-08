-- Cowork migration. Captured into git by code (auditor) on 2026-05-07.
-- Originally applied to prod as 20260507000021; RENUMBERED to 28 here because
-- code's mig 21 (espn_collect_cron_schedules) used that version concurrently.
--
-- Daily ground-truth audit. For every bot reply that claimed "no X available"
-- or similar, look at the tool trace, find what filters it used, re-query
-- listings_snapshots at the response timestamp, count actual matches.
-- If actual > 0, the bot lied (or didn't use the data correctly).

CREATE TABLE IF NOT EXISTS chat_audit_findings (
  id                bigserial PRIMARY KEY,
  bot_message_id    bigint NOT NULL UNIQUE REFERENCES bot_messages(id) ON DELETE CASCADE,
  user_text         text,
  bot_text          text,
  claim_type        text NOT NULL,
  event_id          bigint,
  zone              text,
  max_price         numeric,
  min_qty           integer,
  include_all       boolean,
  s4k_only_count    integer,
  all_sources_count integer,
  was_truthful      boolean NOT NULL,
  severity          text NOT NULL,
  notes             text,
  audited_at        timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS chat_audit_findings_truthful_idx ON chat_audit_findings (was_truthful, audited_at DESC);
CREATE INDEX IF NOT EXISTS chat_audit_findings_event_idx ON chat_audit_findings (event_id);
CREATE INDEX IF NOT EXISTS chat_audit_findings_severity_idx ON chat_audit_findings (severity, audited_at DESC);

COMMENT ON TABLE chat_audit_findings IS
  'Ground-truth audit of bot no-results claims. For each bot reply that claimed nothing was available, we replay the filters against listings_snapshots at the response time and verify.';

-- audit_chat_message: see migration 29 (fix_audit_ordinality) for the shipping
-- version. The original v1 had an ORDER BY ordinality bug; v2 in mig 29 fixes
-- it via WITH ORDINALITY in a lateral. Skipping the buggy v1 here for clarity
-- — fresh deploy goes straight to mig 29's corrected version below.

CREATE OR REPLACE VIEW chat_audit_lies AS
SELECT id, audited_at, severity, claim_type, event_id, zone, min_qty, max_price, include_all,
       s4k_only_count, all_sources_count, user_text, bot_text, notes
FROM chat_audit_findings
WHERE was_truthful = false
ORDER BY CASE severity WHEN 'severe' THEN 0 WHEN 'major' THEN 1 WHEN 'minor' THEN 2 ELSE 3 END,
         audited_at DESC;

CREATE OR REPLACE VIEW chat_audit_recurring_lies AS
SELECT event_id, zone, min_qty, count(*) AS times_lied, max(severity) AS worst_severity, max(audited_at) AS most_recent
FROM chat_audit_findings
WHERE was_truthful = false
GROUP BY event_id, zone, min_qty
HAVING count(*) >= 2
ORDER BY count(*) DESC;

-- Stub the function so run_daily_chat_audit can be created; mig 29 replaces with real body.
CREATE OR REPLACE FUNCTION audit_chat_message(p_bot_msg_id bigint)
RETURNS jsonb LANGUAGE sql AS $$ SELECT jsonb_build_object('skip','superseded_by_mig_29'); $$;

CREATE OR REPLACE FUNCTION run_daily_chat_audit(p_lookback_hours int DEFAULT 26)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  r record;
  v_audited int := 0; v_truthful int := 0; v_lies int := 0; v_skipped int := 0;
  res jsonb;
BEGIN
  FOR r IN
    SELECT bm.id
    FROM bot_messages bm
    LEFT JOIN chat_audit_findings caf ON caf.bot_message_id = bm.id
    WHERE bm.direction = 'out'
      AND bm.created_at >= now() - (p_lookback_hours || ' hours')::interval
      AND caf.id IS NULL
      AND (
        bm.body ILIKE '%no %tickets%' OR bm.body ILIKE '%no listings%'
        OR bm.body ILIKE '%aren''t any%' OR bm.body ILIKE '%aren''t showing%'
        OR bm.body ILIKE '%sold out%' OR bm.body ~* 'no\s+\d+[\- ]?pack'
        OR bm.body ~* 'no\s+(lower|club|upper|courtside|floor|premium|vip)'
      )
  LOOP
    res := audit_chat_message(r.id);
    IF res ? 'skip' THEN v_skipped := v_skipped + 1;
    ELSE
      v_audited := v_audited + 1;
      IF (res ->> 'was_truthful')::boolean THEN v_truthful := v_truthful + 1;
      ELSE v_lies := v_lies + 1;
      END IF;
    END IF;
  END LOOP;
  RETURN jsonb_build_object(
    'lookback_hours', p_lookback_hours,
    'audited', v_audited, 'truthful', v_truthful, 'lies_detected', v_lies, 'skipped', v_skipped,
    'ran_at', now()
  );
END
$fn$;

SELECT cron.unschedule('run-daily-chat-audit') WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname='run-daily-chat-audit');
SELECT cron.schedule('run-daily-chat-audit', '0 4 * * *', $$SELECT run_daily_chat_audit(26);$$);

COMMENT ON FUNCTION run_daily_chat_audit IS 'Daily ground-truth audit: replays bot no-results claims against listings_snapshots and flags lies by severity.';

-- ============================================================================
-- Migration 20260708160000 — X news wire: hard daily ingestion budget
--
-- Lane:     xref+macro (A1 data plane)
-- Touches:  x_news_budget (W, NEW single-row config), x_news_queue (W/function),
--           v_x_news_budget_state (W/view, NEW); reads x_news_pending
-- Pre-reqs: 20260707200050 (usage accounting — the budget counts its
--           status_code/tweets_returned bookkeeping), 20260512100000
--           (trg_set_updated_at)
--
-- Operator directive (2026-07-08): "have to limit ingestion to prevent the
-- same api spend issue." The since:-polling fix (20260707200050) removed the
-- re-billing waste, but nothing capped ABSOLUTE daily spend — a recharge could
-- still drain on a burst (roster growth, a hot news day, a future bug). This
-- adds a hard, operator-tunable daily ceiling enforced inside x_news_queue:
--
--   * max_requests_per_day (default 1,200)  — bounds per-request minimum
--     charges; sits under the 1,440/day cron tick ceiling.
--   * max_tweets_per_day   (default 3,000)  — bounds the real billing driver
--     (~$0.15/1k tweets → ≈ $0.45/day ≈ $13.5/mo hard worst case; typical
--     since:-filtered days run far below).
--
-- Semantics: counted from TODAY's (UTC) x_news_pending accounting rows; when
-- either cap is reached the queue returns 0 until UTC midnight. The tweet cap
-- is checked pre-fire, so it can overshoot by at most one page (~20 tweets).
-- The post-recharge initial sweep (~427 sources × ~20 tweets ≈ 8.5k) therefore
-- spreads over ~3 days, insiders first — deliberate. Tune live:
--   UPDATE x_news_budget SET max_tweets_per_day = <n> WHERE id = 1;
-- Kill switch: SET enabled = false (removes the gate, tick/tier caps remain).
-- Budget state at a glance: SELECT * FROM v_x_news_budget_state;
-- ============================================================================

-- ----------------------------------------------------------------------------
-- (1) Single-row config.
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS x_news_budget (
  id                   smallint PRIMARY KEY DEFAULT 1 CHECK (id = 1),
  enabled              boolean NOT NULL DEFAULT true,
  max_requests_per_day integer NOT NULL DEFAULT 1200 CHECK (max_requests_per_day > 0),
  max_tweets_per_day   integer NOT NULL DEFAULT 3000 CHECK (max_tweets_per_day > 0),
  notes                text,
  updated_at           timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE x_news_budget IS
  'Hard daily ingestion budget for the X news wire (operator directive '
  '2026-07-08 — prevent a repeat of the starter-balance drain). Enforced in '
  'x_news_queue against today''s (UTC) x_news_pending accounting; caps reset '
  'at UTC midnight. max_tweets_per_day is the real spend ceiling '
  '(~$0.15/1k tweets). Mig 20260708160000.';

DROP TRIGGER IF EXISTS x_news_budget_updated_at ON x_news_budget;
CREATE TRIGGER x_news_budget_updated_at
  BEFORE UPDATE ON x_news_budget
  FOR EACH ROW EXECUTE FUNCTION trg_set_updated_at();

INSERT INTO x_news_budget (id, enabled, max_requests_per_day, max_tweets_per_day, notes)
VALUES (1, true, 1200, 3000,
        'Defaults ≈ hard $0.45-0.65/day worst case. Tune per operator; enabled=false removes the gate.')
ON CONFLICT (id) DO NOTHING;

ALTER TABLE x_news_budget ENABLE ROW LEVEL SECURITY;

-- ----------------------------------------------------------------------------
-- (2) Budget state view — today's burn vs caps.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_x_news_budget_state AS
SELECT
  b.enabled,
  b.max_requests_per_day,
  b.max_tweets_per_day,
  coalesce(t.requests_today, 0)                                   AS requests_today,
  coalesce(t.tweets_today, 0)                                     AS tweets_today,
  b.enabled AND coalesce(t.requests_today, 0) >= b.max_requests_per_day AS requests_exhausted,
  b.enabled AND coalesce(t.tweets_today, 0)   >= b.max_tweets_per_day   AS tweets_exhausted,
  round(coalesce(t.tweets_today, 0) * 0.00015, 4)                 AS est_usd_today
FROM x_news_budget b
LEFT JOIN LATERAL (
  SELECT count(*) AS requests_today,
         coalesce(sum(p.tweets_returned), 0) AS tweets_today
  FROM x_news_pending p
  WHERE p.fired_at >= date_trunc('day', now())
) t ON true
WHERE b.id = 1;

COMMENT ON VIEW v_x_news_budget_state IS
  'Today''s (UTC) X-wire burn vs the x_news_budget caps. *_exhausted = the '
  'queue is holding fire until UTC midnight (NOT a stall). Mig 20260708160000.';

-- ----------------------------------------------------------------------------
-- (3) Queue — budget gate added after the key + 402 gates. Everything else is
--     verbatim from 20260707200050.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION x_news_queue(p_limit int DEFAULT 1)
RETURNS int LANGUAGE plpgsql AS $$
DECLARE
  r RECORD; v_req_id bigint; v_count int := 0;
  v_key text; v_query text; v_url text;
  v_budget RECORD; v_req_today bigint; v_tw_today bigint;
BEGIN
  -- Key gate: exception-safe so this also no-ops if the whitelist migration
  -- (20260706113000) hasn't been applied yet.
  BEGIN
    v_key := get_app_secret('TWITTERAPI_IO_KEY');
  EXCEPTION WHEN others THEN
    v_key := NULL;
  END;
  IF v_key IS NULL OR btrim(v_key) = '' THEN
    RETURN 0;  -- no key → no spend, no requests
  END IF;

  -- Credits-exhausted backoff: a 402 in the last 30 min ⇒ hold fire. The next
  -- probe after the window re-tests the balance, so a recharge goes live
  -- within ≤30 min with no operator action here.
  IF EXISTS (SELECT 1 FROM x_news_pending
             WHERE status_code = 402
               AND fired_at > now() - interval '30 minutes') THEN
    RETURN 0;
  END IF;

  -- Daily ingestion budget (mig 20260708160000): hard caps on requests/day and
  -- tweets/day (the billing driver), counted from today's UTC accounting rows.
  -- Either cap reached ⇒ hold fire until UTC midnight. Operator tunes/disables
  -- via x_news_budget; state at a glance in v_x_news_budget_state.
  SELECT b.enabled, b.max_requests_per_day, b.max_tweets_per_day
  INTO v_budget FROM x_news_budget b WHERE b.id = 1;
  IF FOUND AND v_budget.enabled THEN
    SELECT count(*), coalesce(sum(p.tweets_returned), 0)
    INTO v_req_today, v_tw_today
    FROM x_news_pending p
    WHERE p.fired_at >= date_trunc('day', now());
    IF v_req_today >= v_budget.max_requests_per_day
       OR v_tw_today >= v_budget.max_tweets_per_day THEN
      RETURN 0;
    END IF;
  END IF;

  FOR r IN
    SELECT s.source_value, s.kind, s.league, s.poll_interval_minutes, s.last_polled_at
    FROM x_news_sources s
    WHERE s.enabled
      AND (s.last_polled_at IS NULL
           OR s.last_polled_at < now() - (s.poll_interval_minutes || ' minutes')::interval)
    ORDER BY
      (s.last_polled_at IS NULL) DESC,                                   -- never-polled first
      CASE WHEN s.last_polled_at IS NULL
           THEN s.poll_interval_minutes END ASC NULLS LAST,              -- ...tightest tier first
      (EXTRACT(EPOCH FROM (now() - s.last_polled_at)) / 60.0)
        / NULLIF(s.poll_interval_minutes, 0) DESC NULLS LAST,            -- most-overdue-by-ratio
      s.source_value
    LIMIT p_limit
  LOOP
    -- handle rows → the account's own fresh posts, no retweets/replies. On
    -- re-polls, since:<last poll − 10 min overlap> makes the page contain only
    -- NEW tweets — the billing driver is tweets returned, and the tweet_id PK
    -- dedupes the overlap for free. query rows stay verbatim.
    v_query := CASE r.kind
      WHEN 'handle' THEN 'from:' || ltrim(btrim(r.source_value), '@')
                         || ' -filter:retweets -filter:replies'
                         || CASE WHEN r.last_polled_at IS NOT NULL
                                 THEN ' since:'
                                      || to_char((r.last_polled_at - interval '10 minutes')
                                                 AT TIME ZONE 'UTC', 'YYYY-MM-DD_HH24:MI:SS')
                                      || '_UTC'
                                 ELSE '' END
      ELSE r.source_value
    END;

    v_url := 'https://api.twitterapi.io/twitter/tweet/advanced_search'
          || '?queryType=Latest&query=' || x_news_urlencode(v_query);

    SELECT net.http_get(
      url := v_url,
      headers := jsonb_build_object(
        'X-API-Key', v_key,
        'Accept', 'application/json'),
      timeout_milliseconds := 15000
    ) INTO v_req_id;

    INSERT INTO x_news_pending(source_value, kind, league, request_id, fired_at)
    VALUES (r.source_value, r.kind, r.league, v_req_id, now());

    -- Advance the round-robin cursor so the next tick picks a different source.
    UPDATE x_news_sources SET last_polled_at = now()
    WHERE source_value = r.source_value;
    v_count := v_count + 1;
  END LOOP;
  RETURN v_count;
END; $$;

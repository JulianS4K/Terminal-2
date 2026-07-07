-- ============================================================================
-- Migration 20260707200000 — X news wire: credit-usage accounting + cost fixes
--
-- Lane:     xref+macro (A1 data plane)
-- Touches:  x_news_pending (W: +status_code/+tweets_returned),
--           x_news_queue (W/function), x_news_process (W/function),
--           v_x_news_usage (W/view, NEW)
-- Pre-reqs: 20260707190000 (X pipeline w/ roster + keyword tagging)
--
-- Operator directive (2026-07-07): "look at credit usage and monitor that".
-- First live day surfaced two things this migration fixes:
--   * The starter balance exhausted after 35 pulls / 660 tweets (~$0.10 at the
--     published ~$0.15 per 1k tweets) and every subsequent poll 402'd
--     ("Credits is not enough. Please recharge") — 1,440 pointless-but-free
--     requests/day until recharge.
--   * Every poll re-pulled the ~20 latest tweets and re-paid for them even
--     though tweet_id PK deduped locally — the dominant avoidable cost
--     (~28.8k tweets/day ≈ $4.30/day at the 1/min ceiling).
--
-- WHAT THIS DOES:
--   (1) Durable per-request accounting on x_news_pending (status_code +
--       tweets_returned, written by x_news_process) — net._http_response is
--       pruned by pg_net, so billing signals must be captured at process time.
--   (2) v_x_news_usage — hourly rollup (requests by status class, tweets
--       returned vs stored-new, estimated USD at $0.00015/tweet). Window =
--       x_news_pending retention (3d); long-horizon spend lives in the
--       TwitterAPI.io dashboard.
--   (3) 402 backoff in x_news_queue: while a 402 was recorded in the last
--       30 min, the queue no-ops — one probe per ~30 min instead of 1/min
--       against an empty balance; auto-recovers ≤30 min after a recharge.
--   (4) Incremental polling: handle-kind queries append
--       since:<last_polled_at - 10 min> (UTC), so re-polls return ONLY new
--       tweets (overlap deduped by the tweet_id PK). First poll of a source
--       stays unbounded (seeds the ~20 latest). kind='query' rows remain
--       verbatim — operators add their own since:/window operators if wanted.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- (1) Accounting columns — billing signal captured before pg_net prunes it.
-- ----------------------------------------------------------------------------
ALTER TABLE x_news_pending ADD COLUMN IF NOT EXISTS status_code int;
ALTER TABLE x_news_pending ADD COLUMN IF NOT EXISTS tweets_returned int;

COMMENT ON COLUMN x_news_pending.status_code IS
  'HTTP status of the TwitterAPI.io response, recorded by x_news_process (402 = credits exhausted). Mig 20260707200000.';
COMMENT ON COLUMN x_news_pending.tweets_returned IS
  'Tweets in the response page (billing driver: ~$0.15/1k). NULL for non-200/unparseable. Mig 20260707200000.';

-- ----------------------------------------------------------------------------
-- (2) Usage rollup — the "look at credit usage" surface.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_x_news_usage AS
SELECT
  date_trunc('hour', p.fired_at)                          AS hour,
  count(*)                                                AS requests,
  count(*) FILTER (WHERE p.status_code = 200)             AS ok,
  count(*) FILTER (WHERE p.status_code = 402)             AS credit_402,
  count(*) FILTER (WHERE p.status_code = 429)             AS rate_429,
  count(*) FILTER (WHERE p.status_code IS NOT NULL
                     AND p.status_code NOT IN (200, 402, 429)) AS other_err,
  count(*) FILTER (WHERE p.resolved_at IS NULL)           AS in_flight,
  coalesce(sum(p.tweets_returned), 0)                     AS tweets_returned,
  coalesce(sum(p.rows_persisted), 0)                      AS tweets_stored_new,
  round(coalesce(sum(p.tweets_returned), 0) * 0.00015, 4) AS est_usd
FROM x_news_pending p
GROUP BY 1
ORDER BY 1 DESC;

COMMENT ON VIEW v_x_news_usage IS
  'Hourly TwitterAPI.io usage for the X news wire. est_usd = tweets_returned × '
  '$0.00015 (the published ~$0.15/1k-tweets rate; empirically consistent with '
  'the 2026-07-07 starter-balance burn: 660 tweets ≈ $0.10). Rolling window = '
  'x_news_pending retention (3d); authoritative balance = TwitterAPI.io '
  'dashboard. credit_402 > 0 ⇒ recharge needed (queue auto-backs off to one '
  'probe/~30 min). Mig 20260707200000.';

-- ----------------------------------------------------------------------------
-- (3+4) Queue — 402 backoff + incremental since: polling.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION x_news_queue(p_limit int DEFAULT 1)
RETURNS int LANGUAGE plpgsql AS $$
DECLARE
  r RECORD; v_req_id bigint; v_count int := 0;
  v_key text; v_query text; v_url text;
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

-- ----------------------------------------------------------------------------
-- (1 cont.) Process — record status + page size at resolve time.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION x_news_process()
RETURNS TABLE(processed int, posts_persisted int) LANGUAGE plpgsql AS $$
DECLARE
  r RECORD; v_json jsonb; v_count int; v_tweets int;
  v_processed int := 0; v_persisted int := 0;
BEGIN
  FOR r IN
    SELECT p.id, p.source_value, p.league, p.request_id,
           h.content, h.status_code
    FROM x_news_pending p
    JOIN net._http_response h ON h.id = p.request_id
    WHERE p.resolved_at IS NULL
  LOOP
    v_processed := v_processed + 1;
    v_count := 0;
    v_tweets := NULL;
    IF r.status_code = 200 AND r.content IS NOT NULL THEN
      BEGIN
        v_json := r.content::jsonb;
      EXCEPTION WHEN others THEN
        v_json := NULL;  -- non-JSON body → resolve with 0 rows, don't wedge the queue
      END;
      IF v_json IS NOT NULL AND jsonb_typeof(v_json -> 'tweets') = 'array' THEN
        v_tweets := jsonb_array_length(v_json -> 'tweets');
        WITH ins AS (
          INSERT INTO x_news (
            tweet_id, source_value, league, author_handle, author_name,
            title, url, created_utc, matched_keywords
          )
          SELECT
            t ->> 'id',
            r.source_value,
            r.league,
            coalesce(t #>> '{author,userName}', ''),
            t #>> '{author,name}',
            t ->> 'text',
            coalesce(t ->> 'url', 'https://x.com/i/status/' || (t ->> 'id')),
            coalesce(x_news_parse_ts(t ->> 'createdAt'), now()),
            CASE WHEN coalesce((k.mk ->> 'total_weight')::numeric, 0) > 0
                 THEN k.mk ELSE NULL END
          FROM jsonb_array_elements(v_json -> 'tweets') t
          CROSS JOIN LATERAL (SELECT match_news_keywords(t ->> 'text') AS mk) k
          WHERE coalesce(t ->> 'id', '') <> ''
            AND coalesce(t ->> 'text', '') <> ''
          ON CONFLICT (tweet_id) DO NOTHING
          RETURNING 1
        )
        SELECT count(*) INTO v_count FROM ins;
        v_persisted := v_persisted + v_count;
      END IF;
    END IF;

    UPDATE x_news_pending
    SET resolved_at = now(), rows_persisted = v_count,
        status_code = r.status_code, tweets_returned = v_tweets
    WHERE id = r.id;
  END LOOP;
  RETURN QUERY SELECT v_processed, v_persisted;
END; $$;

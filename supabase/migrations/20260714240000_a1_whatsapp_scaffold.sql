-- ============================================================================
-- Migration 20260714240000 — WhatsApp Channels ingestion scaffold (inert)
--
-- Lane:     A1 data plane (new read source, same shape as reddit_news / x_news)
-- Touches:  get_app_secret (W: whitelist WA_GATEWAY_URL + WA_GATEWAY_KEY),
--           whatsapp_channels (W: roster), whatsapp_news (W), whatsapp_news_pending
--           (W), wa_news_queue / wa_news_process (W), get_player_feed (W: fold in
--           a whatsapp source), 2 crons (gated / no-op until the gateway exists)
-- Pre-reqs: 20260714180000 (get_player_feed), 20260706113000 (get_app_secret)
--
-- WHY: operator wants WhatsApp Channels as a feed source for ALL players + cast.
--   WhatsApp has NO official read API — a public Channel's posts can only be read
--   through an UNOFFICIAL gateway (self-hosted WAHA, or Whapi/Maytapi). This lays
--   the storage + feed integration + a GENERIC gateway poller, all INERT until the
--   operator provides the gateway:
--     SELECT vault.create_secret('https://<host>', 'WA_GATEWAY_URL');
--     SELECT vault.create_secret('<token>',        'WA_GATEWAY_KEY');
--   and enables channel rows. Until both secrets exist wa_news_queue returns 0
--   (no requests, safe on prod). The poller's request/response shape is a common
--   default (GET <url>/<channel_ref>/messages → {messages:[{id,text,url,timestamp}]});
--   FINALIZE the URL + parse against the chosen gateway before enabling.
--
--   Read-only upstream (RULE 2): GET-only via pg_net. get_player_feed folds
--   whatsapp_news by the same name filter as ESPN/Reddit/X, so once posts flow
--   they surface for whichever watchlisted player/cast they mention — no per-entity
--   plumbing. (Cast shares whatsapp_news; a get_cast_feed can name-filter it later.)
-- ============================================================================

-- ----------------------------------------------------------------------------
-- (1) Whitelist the gateway secrets on get_app_secret (restated full allowlist).
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_app_secret(p_name text)
RETURNS text LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public', 'vault'
AS $function$
DECLARE v_value text;
BEGIN
  IF current_user NOT IN ('service_role', 'postgres', 'supabase_admin') THEN
    RAISE EXCEPTION 'get_app_secret: caller % not authorized', current_user USING ERRCODE = '42501';
  END IF;
  IF p_name NOT IN (
    'SEATDATA_API_KEY','TEVO_API_TOKEN','TEVO_SECRET','SEATGEEK_API_TOKEN',
    'TICKPICK_API_TOKEN','VIVID_API_TOKEN','APPSCRIPT_INGEST_SECRET',
    'TICKETSDATA_USERNAME','TICKETSDATA_PASSWORD','TWITTERAPI_IO_KEY',
    'WA_GATEWAY_URL','WA_GATEWAY_KEY'
  ) THEN
    RAISE EXCEPTION 'secret % is not in the app whitelist', p_name USING ERRCODE = '42501';
  END IF;
  SELECT decrypted_secret INTO v_value FROM vault.decrypted_secrets WHERE name = p_name LIMIT 1;
  RETURN v_value;
END $function$;

-- ----------------------------------------------------------------------------
-- (2) Roster + storage + queue. entity_type = 'player' | 'cast' | 'topic'.
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS whatsapp_channels (
  channel_ref           text PRIMARY KEY,      -- the gateway's channel id / invite code
  label                 text,                  -- display name ("Shams — Channel")
  entity_type           text,                  -- 'player' | 'cast' | 'topic'
  entity_key            text,                  -- espn_athlete_id / show_slug (nullable)
  league                text,
  enabled               boolean NOT NULL DEFAULT false,  -- off until a gateway exists
  poll_interval_minutes integer NOT NULL DEFAULT 15 CHECK (poll_interval_minutes >= 5),
  last_polled_at        timestamptz,
  notes                 text,
  created_at            timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE whatsapp_channels IS
  'Roster of WhatsApp Channels to read via the (unofficial) gateway. enabled=false '
  'until vault WA_GATEWAY_URL/KEY exist + the channel is verified. Mig 20260714240000.';

CREATE TABLE IF NOT EXISTS whatsapp_news (
  msg_id       text PRIMARY KEY,
  channel_ref  text NOT NULL,
  label        text,
  entity_type  text,
  entity_key   text,
  league       text,
  author       text,
  title        text NOT NULL,                  -- the post text (headline)
  url          text,
  posted_at    timestamptz,
  pulled_at    timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS whatsapp_news_recent_idx ON whatsapp_news(posted_at DESC);
CREATE INDEX IF NOT EXISTS whatsapp_news_pulled_idx ON whatsapp_news(pulled_at);
COMMENT ON TABLE whatsapp_news IS
  'WhatsApp Channel posts (text) for the feeds. Populated by wa_news_process. '
  'Read via get_player_feed (name filter). Mig 20260714240000.';

CREATE TABLE IF NOT EXISTS whatsapp_news_pending (
  id            bigserial PRIMARY KEY,
  channel_ref   text NOT NULL,
  request_id    bigint NOT NULL,
  fired_at      timestamptz NOT NULL DEFAULT now(),
  resolved_at   timestamptz,
  rows_persisted int
);
CREATE INDEX IF NOT EXISTS whatsapp_news_pending_unresolved_idx
  ON whatsapp_news_pending(fired_at) WHERE resolved_at IS NULL;

ALTER TABLE whatsapp_channels     ENABLE ROW LEVEL SECURITY;
ALTER TABLE whatsapp_news         ENABLE ROW LEVEL SECURITY;
ALTER TABLE whatsapp_news_pending ENABLE ROW LEVEL SECURITY;

-- ----------------------------------------------------------------------------
-- (3) Queue — one GET per due enabled channel. NO-OPS (returns 0) until BOTH
--     vault WA_GATEWAY_URL and WA_GATEWAY_KEY exist. GENERIC request shape —
--     FINALIZE against the chosen gateway before enabling channels.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.wa_news_queue(p_limit int DEFAULT 3)
RETURNS int LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  c RECORD; v_url text; v_key text; v_req bigint; v_n int := 0;
BEGIN
  BEGIN v_url := get_app_secret('WA_GATEWAY_URL'); v_key := get_app_secret('WA_GATEWAY_KEY');
  EXCEPTION WHEN OTHERS THEN v_url := NULL; END;
  IF v_url IS NULL OR btrim(v_url) = '' OR v_key IS NULL OR btrim(v_key) = '' THEN
    RETURN 0;  -- no gateway → no spend, no requests
  END IF;

  FOR c IN
    SELECT channel_ref, poll_interval_minutes FROM whatsapp_channels
    WHERE enabled
      AND (last_polled_at IS NULL OR last_polled_at < now() - (poll_interval_minutes||' minutes')::interval)
    ORDER BY last_polled_at ASC NULLS FIRST
    LIMIT greatest(1, coalesce(p_limit, 3))
  LOOP
    SELECT net.http_get(
      url := rtrim(v_url,'/') || '/' || c.channel_ref || '/messages?limit=25',
      headers := jsonb_build_object('Authorization','Bearer '||v_key, 'Accept','application/json'),
      timeout_milliseconds := 15000
    ) INTO v_req;
    INSERT INTO whatsapp_news_pending(channel_ref, request_id) VALUES (c.channel_ref, v_req);
    UPDATE whatsapp_channels SET last_polled_at = now() WHERE channel_ref = c.channel_ref;
    v_n := v_n + 1;
    PERFORM pg_sleep(0.2);
  END LOOP;
  RETURN v_n;
END $$;

-- ----------------------------------------------------------------------------
-- (4) Process — parse gateway JSON into whatsapp_news. Defensive over common
--     field names (id/message_id, text/body/caption, url/link, timestamp/date).
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.wa_news_process()
RETURNS TABLE(processed int, posts int) LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  r RECORD; v_body jsonb; v_arr jsonb; v_ins int; v_proc int := 0; v_total int := 0;
BEGIN
  FOR r IN
    SELECT p.id AS pid, p.channel_ref, h.content, h.status_code,
           ch.label, ch.entity_type, ch.entity_key, ch.league
    FROM whatsapp_news_pending p
    JOIN net._http_response h ON h.id = p.request_id
    LEFT JOIN whatsapp_channels ch ON ch.channel_ref = p.channel_ref
    WHERE p.resolved_at IS NULL
  LOOP
    v_proc := v_proc + 1; v_ins := 0;
    IF r.status_code = 200 AND r.content IS NOT NULL THEN
      BEGIN v_body := r.content::jsonb; EXCEPTION WHEN OTHERS THEN v_body := NULL; END;
      IF v_body IS NOT NULL THEN
        v_arr := coalesce(v_body->'messages', v_body->'result', v_body->'data',
                          CASE jsonb_typeof(v_body) WHEN 'array' THEN v_body ELSE '[]'::jsonb END);
        WITH ins AS (
          INSERT INTO whatsapp_news (msg_id, channel_ref, label, entity_type, entity_key, league, author, title, url, posted_at)
          SELECT
            r.channel_ref||':'||coalesce(m->>'id', m->>'message_id', md5(coalesce(m->>'text', m->>'body',''))),
            r.channel_ref, r.label, r.entity_type, r.entity_key, r.league,
            coalesce(m->>'author', m->>'from'),
            coalesce(m->>'text', m->>'body', m->>'caption', ''),
            coalesce(m->>'url', m->>'link'),
            coalesce(nullif(m->>'timestamp','')::timestamptz, nullif(m->>'date','')::timestamptz, now())
          FROM jsonb_array_elements(v_arr) m
          WHERE coalesce(m->>'text', m->>'body', m->>'caption','') <> ''
          ON CONFLICT (msg_id) DO NOTHING
          RETURNING 1)
        SELECT count(*) INTO v_ins FROM ins;
      END IF;
    END IF;
    UPDATE whatsapp_news_pending SET resolved_at = now(), rows_persisted = v_ins WHERE id = r.pid;
    v_total := v_total + v_ins;
  END LOOP;
  DELETE FROM whatsapp_news_pending WHERE resolved_at IS NOT NULL AND resolved_at < now() - interval '6 hours';
  DELETE FROM whatsapp_news WHERE pulled_at < now() - interval '4 days';
  RETURN QUERY SELECT v_proc, v_total;
END $$;

COMMENT ON FUNCTION public.wa_news_queue(int) IS
  'Polls enabled whatsapp_channels via the vault-configured gateway. No-ops until '
  'WA_GATEWAY_URL + WA_GATEWAY_KEY exist. GENERIC shape — finalize per gateway. Mig 20260714240000.';

-- ----------------------------------------------------------------------------
-- (5) Crons — gated (the fn no-ops without the gateway; safe to schedule now).
--     Off-cluster minute marks.
-- ----------------------------------------------------------------------------
SELECT cron.schedule('wa_news_queue_10min',  '9-59/10 * * * *', $$ SELECT public.wa_news_queue(3); $$);
SELECT cron.schedule('wa_news_process_5min', '4-59/5 * * * *',  $$ SELECT public.wa_news_process(); $$);

-- ----------------------------------------------------------------------------
-- (6) Fold WhatsApp into the merged player feed (restate get_player_feed +
--     a whatsapp CTE; body otherwise identical to mig 20260714180000).
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_player_feed(
  p_athlete_id text, p_name text, p_league text DEFAULT NULL,
  p_window_hours int DEFAULT 72, p_limit int DEFAULT 40)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path TO 'public', 'pg_temp' AS $func$
DECLARE
  v_email text; v_q text := nullif(btrim(coalesce(p_name,'')), '');
  v_first text; v_win int := greatest(1, least(coalesce(p_window_hours, 72), 336));
  v_lim int := greatest(1, least(coalesce(p_limit, 40), 100)); v_since timestamptz; v_items jsonb;
BEGIN
  v_email := coalesce(auth.jwt()->>'email', '');
  IF v_email NOT LIKE '%@s4kent.com' THEN
    RAISE EXCEPTION 'forbidden: % is not an @s4kent.com email', v_email USING ERRCODE = '42501'; END IF;
  IF v_q IS NULL THEN RETURN jsonb_build_object('items', '[]'::jsonb); END IF;
  v_first := (regexp_match(v_q, '^([A-Za-z]{5,})\s'))[1];
  v_since := now() - (v_win || ' hours')::interval;

  WITH news AS (
    SELECT 'ESPN'::text AS source, 'news'::text AS item_type, e.headline AS title, e.description AS summary,
           e.url, e.image_url, coalesce(e.espn_league,'ESPN') AS handle, e.published_at
    FROM espn_news e
    WHERE e.published_at > v_since AND (p_league IS NULL OR e.espn_league = p_league)
      AND ( e.headline ILIKE '%'||v_q||'%' OR e.description ILIKE '%'||v_q||'%'
            OR (v_first IS NOT NULL AND (e.headline ~* ('\m'||v_first||'\M') OR e.description ~* ('\m'||v_first||'\M'))) )),
  reddit AS (
    SELECT 'Reddit'::text, 'reddit'::text, r.title, NULL::text,
           coalesce(nullif(r.link_url,''), r.permalink), NULL::text, 'r/'||r.subreddit, r.created_utc
    FROM reddit_news r
    WHERE r.pulled_at > v_since AND ( r.title ILIKE '%'||v_q||'%' OR (v_first IS NOT NULL AND r.title ~* ('\m'||v_first||'\M')) )),
  xposts AS (
    SELECT 'X'::text, 'x'::text, CASE WHEN length(x.title) > 260 THEN left(x.title,257)||'…' ELSE x.title END,
           NULL::text, x.url, NULL::text, '@'||x.author_handle, x.created_utc
    FROM x_news x
    WHERE x.pulled_at > v_since AND ( x.title ILIKE '%'||v_q||'%' OR (v_first IS NOT NULL AND x.title ~* ('\m'||v_first||'\M')) )),
  whatsapp AS (
    SELECT 'WhatsApp'::text, 'whatsapp'::text,
           CASE WHEN length(wn.title) > 260 THEN left(wn.title,257)||'…' ELSE wn.title END,
           NULL::text, wn.url, NULL::text, coalesce(wn.label, wn.channel_ref), wn.posted_at
    FROM whatsapp_news wn
    WHERE wn.pulled_at > v_since AND ( wn.title ILIKE '%'||v_q||'%' OR (v_first IS NOT NULL AND wn.title ~* ('\m'||v_first||'\M')) )),
  txn AS (
    SELECT 'Transaction'::text, 'transaction'::text, coalesce(t.team_display_name||': ', '')||t.description, NULL::text,
           NULL::text, NULL::text, coalesce(t.team_display_name, t.team_abbr, 'ESPN'), t.txn_date
    FROM espn_transactions t
    WHERE t.txn_date > v_since AND (p_league IS NULL OR t.espn_league = p_league) AND coalesce(t.description,'') <> ''
      AND ( t.description ILIKE '%'||v_q||'%' OR (v_first IS NOT NULL AND t.description ~* ('\m'||v_first||'\M')) )),
  market AS (
    SELECT 'Market'::text, 'market'::text, 'Transfer market · '||m.dest_team_name||' '||round(m.yes_price*100)::int||'%',
           NULL::text, m.url, NULL::text, coalesce(m.source,'Kalshi'), m.updated_at
    FROM (SELECT dest_team_name, yes_price, url, source, updated_at FROM player_prediction_markets
           WHERE espn_athlete_id = p_athlete_id AND espn_league = p_league
             AND coalesce(status,'') NOT IN ('closed','settled','inactive') AND yes_price IS NOT NULL
           ORDER BY yes_price DESC NULLS LAST LIMIT 3) m),
  unioned AS (
    SELECT * FROM news UNION ALL SELECT * FROM reddit UNION ALL SELECT * FROM xposts
    UNION ALL SELECT * FROM whatsapp UNION ALL SELECT * FROM txn UNION ALL SELECT * FROM market)
  SELECT coalesce(jsonb_agg(to_jsonb(u) ORDER BY u.published_at DESC NULLS LAST), '[]'::jsonb)
  INTO v_items FROM (SELECT * FROM unioned ORDER BY published_at DESC NULLS LAST LIMIT v_lim) u;

  RETURN jsonb_build_object(
    'generated_at', to_char(now() AT TIME ZONE 'UTC','YYYY-MM-DD"T"HH24:MI:SS"Z"'),
    'items', coalesce(v_items, '[]'::jsonb));
END $func$;

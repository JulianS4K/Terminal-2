-- Cowork migration. Captured into git by code (auditor) on 2026-05-07.
-- Originally applied to prod 2026-05-07 22:12 UTC.
--
-- TEvo /v9/ticket_groups response cache. Both get_event_zones and find_listings
-- typically hit the same event_id back-to-back within a single chat session, plus
-- the same event_id often gets queried by multiple users within a few minutes.
-- 90s TTL strikes a balance between freshness and saving redundant TEvo calls.

CREATE TABLE IF NOT EXISTS tevo_ticket_groups_cache (
  event_id    bigint PRIMARY KEY,
  payload     jsonb NOT NULL,
  captured_at timestamptz NOT NULL DEFAULT now(),
  expires_at  timestamptz NOT NULL DEFAULT now() + interval '90 seconds'
);
CREATE INDEX IF NOT EXISTS tevo_ticket_groups_cache_expires_idx ON tevo_ticket_groups_cache (expires_at);

CREATE OR REPLACE FUNCTION get_cached_ticket_groups(p_event_id bigint)
RETURNS jsonb LANGUAGE sql STABLE AS $$
  SELECT payload FROM tevo_ticket_groups_cache
  WHERE event_id = p_event_id AND expires_at > now();
$$;

CREATE OR REPLACE FUNCTION put_cached_ticket_groups(p_event_id bigint, p_payload jsonb, p_ttl_seconds int DEFAULT 90)
RETURNS void LANGUAGE sql AS $$
  INSERT INTO tevo_ticket_groups_cache (event_id, payload, captured_at, expires_at)
  VALUES (p_event_id, p_payload, now(), now() + (p_ttl_seconds || ' seconds')::interval)
  ON CONFLICT (event_id) DO UPDATE SET
    payload     = EXCLUDED.payload,
    captured_at = EXCLUDED.captured_at,
    expires_at  = EXCLUDED.expires_at;
$$;

CREATE OR REPLACE FUNCTION sweep_tevo_ticket_groups_cache()
RETURNS integer LANGUAGE plpgsql AS $$
DECLARE n int;
BEGIN
  DELETE FROM tevo_ticket_groups_cache WHERE expires_at < now() - interval '1 hour';
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $$;

SELECT cron.unschedule('sweep_tevo_ticket_groups_cache') WHERE EXISTS (
  SELECT 1 FROM cron.job WHERE jobname = 'sweep_tevo_ticket_groups_cache'
);
SELECT cron.schedule('sweep_tevo_ticket_groups_cache', '15 * * * *', 'SELECT sweep_tevo_ticket_groups_cache();');

COMMENT ON TABLE tevo_ticket_groups_cache IS
  'Short-TTL cache of /v9/ticket_groups responses. Used by chat fn to deduplicate redundant TEvo fetches across get_event_zones + find_listings + find_better_seats.';

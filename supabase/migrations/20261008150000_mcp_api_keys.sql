-- Migration 20261008150000 · level:security · lane:D0 · writes:mcp_api_keys,mcp_issue_key(),mcp_revoke_key(),mcp_verify_key(),get_home_stats(),get_sg_market_chart(),get_owned_events_upcoming(),get_event_source_links() · reads:mcp_api_keys · pre:20261006190000,20260603180000
--
-- ============================================================================
-- Migration 20261008150000 — MCP server: API keys + service-role access to the
--                            terminal's email-gated read RPCs
--
-- Lane:     D0 (terminal) · operator-directed 2026-10-08 ("turn the project into
--           a mcp others can call" → tiered internal/external, API keys)
-- Touches:  mcp_api_keys (W, new table, RLS on, no policies — service only),
--           mcp_issue_key / mcp_revoke_key / mcp_verify_key (W, new; postgres +
--           service_role only), and the caller gate of get_home_stats,
--           get_sg_market_chart, get_owned_events_upcoming, get_event_source_links
--           (W: + service_role, same rule as get_event_orders_daily)
-- Pre-reqs: 20261006190000 (home stats RPCs), 20260603180000 (source links)
--
-- Already applied to prod · via MCP 2026-10-08 under operator direction ("Apply
-- + merge when green"). Verified: 4 gates rewritten; service_role JWT →
-- get_home_stats coverage 5,818 / 1,033 / 275 / 24; gmail JWT → 42501;
-- mcp_verify_key('nope') → 0 rows; 0 keys issued.
--
-- MODEL: the FastAPI server (service_role) serves /mcp. A caller presents a
--   bearer key; the server hashes it (sha256) and asks mcp_verify_key for the
--   key's tier. 'internal' keys (our team) reach the order book / owned
--   inventory tools; 'external' keys (partners) only public market data. Keys
--   are shown once by mcp_issue_key and stored only as hashes.
--
-- GATES: those four RPCs were @s4kent.com-JWT only, which also locked out the
--   server's own service_role client. service_role already bypasses RLS, so
--   letting it through grants nothing new. Each body is rewritten in place
--   (one textual swap of the gate line); the DO block fails loudly if a body
--   doesn't contain exactly the expected gate, and is a no-op on re-run.
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.mcp_api_keys (
  id            bigserial PRIMARY KEY,
  label         text NOT NULL,
  tier          text NOT NULL CHECK (tier IN ('internal', 'external')),
  key_prefix    text NOT NULL,               -- first 8 chars, to recognise a key in lists
  key_hash      text NOT NULL UNIQUE,        -- hex sha256 of the full key
  created_at    timestamptz NOT NULL DEFAULT now(),
  created_by    text,
  revoked_at    timestamptz,
  last_used_at  timestamptz
);
ALTER TABLE public.mcp_api_keys ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.mcp_api_keys FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT, UPDATE ON public.mcp_api_keys TO service_role;
GRANT USAGE ON SEQUENCE public.mcp_api_keys_id_seq TO service_role;

COMMENT ON TABLE public.mcp_api_keys IS
  'API keys for the /mcp server (mig 20261008150000). Hash-only (sha256); tier internal = our book, external = public market data. Issue with mcp_issue_key, revoke with mcp_revoke_key.';

-- Issue a key: returns the plaintext ONCE.
CREATE OR REPLACE FUNCTION public.mcp_issue_key(p_label text, p_tier text, p_created_by text DEFAULT NULL)
RETURNS text
LANGUAGE plpgsql
SET search_path = public, extensions, pg_temp
AS $func$
DECLARE
  v_key text;
BEGIN
  IF p_tier NOT IN ('internal', 'external') THEN
    RAISE EXCEPTION 'tier must be internal or external' USING ERRCODE = '22023';
  END IF;
  IF coalesce(btrim(p_label), '') = '' THEN
    RAISE EXCEPTION 'label is required' USING ERRCODE = '22023';
  END IF;
  v_key := 's4k_' || CASE p_tier WHEN 'internal' THEN 'int_' ELSE 'ext_' END
           || encode(gen_random_bytes(24), 'hex');
  INSERT INTO public.mcp_api_keys (label, tier, key_prefix, key_hash, created_by)
  VALUES (btrim(p_label), p_tier, left(v_key, 12), encode(digest(v_key, 'sha256'), 'hex'), p_created_by);
  RETURN v_key;
END
$func$;

CREATE OR REPLACE FUNCTION public.mcp_revoke_key(p_id bigint)
RETURNS boolean
LANGUAGE sql
SET search_path = public, pg_temp
AS $func$
  UPDATE public.mcp_api_keys SET revoked_at = now()
   WHERE id = p_id AND revoked_at IS NULL
  RETURNING true;
$func$;

-- Verify a presented key's hash → its id/label/tier (no row = invalid or revoked).
-- last_used_at is bumped at most once a minute so hot callers don't write per call.
CREATE OR REPLACE FUNCTION public.mcp_verify_key(p_key_hash text)
RETURNS TABLE (id bigint, label text, tier text)
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $func$
BEGIN
  UPDATE public.mcp_api_keys k SET last_used_at = now()
   WHERE k.key_hash = p_key_hash AND k.revoked_at IS NULL
     AND (k.last_used_at IS NULL OR k.last_used_at < now() - interval '1 minute');
  RETURN QUERY
    SELECT k.id, k.label, k.tier FROM public.mcp_api_keys k
     WHERE k.key_hash = p_key_hash AND k.revoked_at IS NULL;
END
$func$;

REVOKE ALL ON FUNCTION public.mcp_issue_key(text, text, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.mcp_revoke_key(bigint)          FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.mcp_verify_key(text)            FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.mcp_issue_key(text, text, text) TO service_role;
GRANT EXECUTE ON FUNCTION public.mcp_revoke_key(bigint)          TO service_role;
GRANT EXECUTE ON FUNCTION public.mcp_verify_key(text)            TO service_role;

-- Let service_role through the four @s4kent.com gates.
DO $do$
DECLARE
  v_old  constant text := 'IF v_email NOT LIKE ''%@s4kent.com'' THEN';
  v_new  constant text := 'IF coalesce(auth.role(), '''') <> ''service_role'' AND v_email NOT LIKE ''%@s4kent.com'' THEN';
  r      record;
  v_def  text;
  v_hits int;
BEGIN
  FOR r IN
    SELECT p.oid, p.proname FROM pg_proc p
    WHERE p.pronamespace = 'public'::regnamespace
      AND p.proname IN ('get_home_stats', 'get_sg_market_chart', 'get_owned_events_upcoming', 'get_event_source_links')
  LOOP
    v_def := pg_get_functiondef(r.oid);
    CONTINUE WHEN position(v_new IN v_def) > 0;          -- already applied
    v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
    IF v_hits <> 1 THEN
      RAISE EXCEPTION '%: expected exactly one gate line, found %', r.proname, v_hits;
    END IF;
    EXECUTE replace(v_def, v_old, v_new);
  END LOOP;
END
$do$;

-- ============================================================================
-- Migration 20260910090000 — N2S TicketsData: separate-account plumbing,
--                            shared account in use for testing
--
-- Lane:     D0 (orders surface) over A1's TicketsData plane
-- Level:    security — widens the get_app_secret() allowlist by two names
-- Touches:  get_app_secret() (allowlist +2), n2s_td_drain() (own credentials)
-- Pre-reqs: 20260910080000
--
-- Upstream: GET https://ticketsdata.com/fetch only — a read. RULE 2 holds.
--
-- Operator direction 2026-09-09: "seperate the vendor quota on top of existing
-- not within it." — then, immediately after: "use the shared account, this is
-- for testing only." Both are honoured: the separate-account path is built and
-- preferred, with a REPORTED fallback to the shared account until the second
-- account exists.
--
-- ── What was wrong with the previous version ───────────────────────────────
-- 20260910080000 gave N2S its own 500/day CAP but pointed it at the SHARED
-- TicketsData account (TICKETSDATA_USERNAME / TICKETSDATA_PASSWORD). That is a
-- slice carved OUT OF the existing quota, not quota on top of it: every N2S
-- pull would have drawn down the same vendor allowance every other TicketsData
-- caller shares. The 403 {"detail":"Quota exhausted"} that lane hit was proof —
-- the account, not our policy, was the binding constraint.
--
-- A cap is not quota. Capping our own spend at 500 does not create 500 more
-- calls at the vendor. The only way to make this allowance genuinely ADDITIVE
-- is a SEPARATE TicketsData account with its own quota.
--
-- ── ⚠ TESTING POSTURE: FALLS BACK TO THE SHARED ACCOUNT, ON PURPOSE ───────
-- Operator follow-up 2026-09-09: "use the shared account, this is for testing
-- only." So the N2S pair is preferred, and when it is unseeded this lane
-- FALLS BACK to TICKETSDATA_USERNAME / TICKETSDATA_PASSWORD rather than going
-- inert. That means the allowance is, for now, drawn from the SHARED vendor
-- quota — "within it", not on top of it. The separate-account plumbing is in
-- place and switching is a vault seed away, with no code change.
--
-- ⚠ THE SHARING IS REPORTED, NEVER SILENT. n2s_td_drain() returns
-- `using_shared_account`, and it is true whenever the fallback is taken. The
-- danger was never sharing per se — it is sharing INVISIBLY, where the venue
-- sweep and watchlist polling lose quota to this lane with nothing to point
-- at. A caller can now see exactly which account was charged.
--
-- ⚠ WHILE THE FALLBACK IS ACTIVE THE 500/DAY CAP IS LEAD SAFETY, NOT
-- BOOKKEEPING. It is the only thing bounding what this lane takes from the
-- shared allowance, so do not raise it casually and do not remove it as
-- "redundant with the vendor quota" — the vendor quota is shared, the cap is
-- not.
--
-- TO MAKE THE QUOTA GENUINELY ADDITIVE LATER: provision a second TicketsData
-- account and seed both secrets, in the Supabase dashboard Vault, NOT via SQL
-- (a value passed through execute_sql lands in the Postgres query log):
--   vault name  TICKETSDATA_N2S_USERNAME
--   vault name  TICKETSDATA_N2S_PASSWORD
-- The moment both resolve, this lane stops touching the shared account and
-- `using_shared_account` goes false. No migration needed.
--
-- ── 1. allowlist: two names, nothing else changed ──────────────────────────
-- The current_user assert and the REVOKE/GRANT below are preserved verbatim;
-- only the IN-list grows. Do not "tidy" the authorization check away.
CREATE OR REPLACE FUNCTION public.get_app_secret(p_name text)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public','vault'
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
    'WA_GATEWAY_URL','WA_GATEWAY_KEY',
    -- S4K CRM marketplace API (crm.s4kcs.com) — read-only order book.
    'crm.s4kcs.com',
    -- S4K CRM N2S API (crm.s4kcs.com/api/v1/n2s) — read-only sub queue.
    -- Separate key: scope 'n2s:read' only, disjoint from the one above.
    'crm.s4kcs.com/n2s',
    -- TicketsData SECOND account, for the N2S cover lane only. Its quota is
    -- ADDITIVE to TICKETSDATA_USERNAME/PASSWORD, never a slice of it. The N2S
    -- drain resolves these and does NOT fall back to the shared pair.
    'TICKETSDATA_N2S_USERNAME','TICKETSDATA_N2S_PASSWORD'
  ) THEN
    RAISE EXCEPTION 'secret % is not in the app whitelist', p_name USING ERRCODE = '42501';
  END IF;
  SELECT decrypted_secret INTO v_value FROM vault.decrypted_secrets WHERE name = p_name LIMIT 1;
  RETURN v_value;
END $function$;

REVOKE ALL ON FUNCTION public.get_app_secret(text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.get_app_secret(text) TO service_role;

-- ── 2. the N2S drain uses its OWN account ──────────────────────────────────
-- Return type gains creds_missing, so DROP + CREATE rather than REPLACE.
DROP FUNCTION IF EXISTS public.n2s_td_drain(integer, integer, interval);

CREATE OR REPLACE FUNCTION public.n2s_td_drain(
  p_max     integer  DEFAULT 10,
  p_cap     integer  DEFAULT 500,
  p_backoff interval DEFAULT interval '30 minutes'
)
RETURNS TABLE(fired integer, remaining_today integer,
              quota_blocked boolean, using_shared_account boolean)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public','extensions','pg_temp'
AS $function$
DECLARE
  r RECORD; v_user text; v_pass text; v_req bigint;
  v_count int := 0; v_head int; v_quota boolean; v_shared boolean := false;
BEGIN
  -- Prefer the N2S account; fall back to the shared one for testing. The
  -- fallback is REPORTED via using_shared_account so it can never be a silent
  -- drain on the quota other TicketsData callers depend on.
  v_user := public.get_app_secret('TICKETSDATA_N2S_USERNAME');
  v_pass := public.get_app_secret('TICKETSDATA_N2S_PASSWORD');

  IF v_user IS NULL OR btrim(v_user) = ''
     OR v_pass IS NULL OR btrim(v_pass) = '' THEN
    v_shared := true;
    v_user := public.get_app_secret('TICKETSDATA_USERNAME');
    v_pass := public.get_app_secret('TICKETSDATA_PASSWORD');
    RAISE NOTICE 'n2s_td_drain: N2S account unseeded; using the SHARED TicketsData account (testing posture) — its quota is not additive';
  END IF;

  IF v_user IS NULL OR v_pass IS NULL THEN
    RAISE EXCEPTION 'n2s_td_drain: no usable TicketsData credentials in vault';
  END IF;

  SELECT EXISTS (
    SELECT 1 FROM public.td_pull_queue q
     WHERE q.interval_tag = 'n2s_ondemand'
       AND q.resolved_at > now() - p_backoff
       AND q.error_msg = 'quota_exhausted'
  ) INTO v_quota;

  IF v_quota THEN
    RAISE NOTICE 'n2s_td_drain: vendor quota exhausted recently; backing off';
    RETURN QUERY SELECT 0, GREATEST(p_cap - public.n2s_td_credits_today(), 0), true, v_shared;
    RETURN;
  END IF;

  v_head := p_cap - public.n2s_td_credits_today();
  IF v_head <= 0 THEN
    RAISE NOTICE 'n2s_td_drain: N2S daily cap of % reached; skipping', p_cap;
    RETURN QUERY SELECT 0, 0, false, v_shared; RETURN;
  END IF;

  FOR r IN
    SELECT q.id, q.event_id, q.platform, q.event_url
      FROM public.td_pull_queue q
     WHERE q.interval_tag = 'n2s_ondemand'
       AND q.fired_at IS NULL AND q.resolved_at IS NULL
     ORDER BY q.created_at ASC
     LIMIT LEAST(p_max, v_head)
  LOOP
    SELECT net.http_get(
      url := 'https://ticketsdata.com/fetch',
      params := jsonb_build_object('platform', public.td_api_platform(r.platform),
                  'event_url', r.event_url, 'username', v_user, 'password', v_pass),
      headers := '{}'::jsonb, timeout_milliseconds := 35000) INTO v_req;
    UPDATE public.td_pull_queue
       SET request_id = v_req, fired_at = clock_timestamp() WHERE id = r.id;
    v_count := v_count + 1;
  END LOOP;

  RETURN QUERY SELECT v_count,
                      GREATEST(p_cap - public.n2s_td_credits_today(), 0),
                      false, v_shared;
END $function$;

COMMENT ON FUNCTION public.n2s_td_drain(integer, integer, interval) IS
  'Fires ONLY td_pull_queue rows tagged n2s_ondemand, using the SEPARATE '
  'TicketsData account (TICKETSDATA_N2S_USERNAME/PASSWORD) so its quota is '
  'ADDITIVE to the shared account when TICKETSDATA_N2S_USERNAME/PASSWORD are '
  'seeded. Until then it FALLS BACK to the shared account (operator testing '
  'posture) and reports using_shared_account = true, so the sharing is never '
  'silent. Bounded by the operator-set 500/day cap, which while the fallback '
  'is active is the only thing protecting the shared quota.';

REVOKE ALL ON FUNCTION public.n2s_td_drain(integer, integer, interval) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.n2s_td_drain(integer, integer, interval) TO service_role;

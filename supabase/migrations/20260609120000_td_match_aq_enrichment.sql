-- Migration 20260609120000 · lane:D0 (TD/AQ subsystem is A1-owned) ·
--   writes (DDL): ticketsdata_credit_usage (+reports cols), td_charge_credit (sig),
--                 td_reports_this_month(), td_reports_budget_ok(),
--                 td_match_queue (new), td_match_results (new),
--                 td_match_enqueue(), td_match_drain(), td_match_apply() ·
--   reads: aq_event_map, ticketsdata_event_xref ·
--   writes on run: td_match_queue/_results; td_match_apply(true) → aq_event_map ·
--   spends: TicketsData /match = 12 credits + 1 Market-Intelligence report each
--           (gated by td_budget_ok() AND td_reports_budget_ok()).
--
-- ## NOT YET APPLIED — author-only migration file.
--    Pending A1 review + explicit operator apply (CLAUDE.md §1: apply_migration
--    on prod requires operator permission; A1 is sole pusher to main). Validate
--    on a Supabase branch (copy-on-write fork) before any prod apply.
--
-- WHY ───────────────────────────────────────────────────────────────────────
-- The AQ matcher (match_to_aq_event_id) is reliable on Tier-1 platform-native id,
-- but Tiers 2–4 GUESS from venue+date ±6h. That guesswork is the documented root
-- cause of (a) false binds (Forrest Frank → Knicks G4; Braves@Giants → A's@Giants)
-- and (b) ID scatter — A1-OPS-22: 235 tevo events with ≥2 aq_event_map rows whose
-- platform ids are split across rows, so the TD daily snapshot reads only one
-- cluster and sibling platforms look "missing".
--
-- TicketsData /match is the missing oracle: feed it ONE event URL (any platform)
-- and it returns the matched id/URL on every other platform PLUS match_confidence
-- (0–100), match_type (exact|probable), and match_reason (entity-id matched, exact
-- venue key, same date). It does two jobs for AQ:
--   1. FILL  — one call resolves sg/sh/vivid ids onto a single aq row (no guessing).
--   2. ADJUDICATE — for conflicting clusters it tells us if two URLs are the SAME
--      event (→ mergeable) or genuinely distinct (parking / doubleheader → keep).
--
-- SAFETY ─────────────────────────────────────────────────────────────────────
-- /match output lands in td_match_results (staging). td_match_apply() DEFAULTS TO
-- DRY-RUN and only COALESCE-fills NULL platform-id columns — it NEVER overwrites a
-- non-null value; a mismatch is reported as action='CONFLICT' for manual review.
-- Mirrors the aq_consolidate_safe_dups(p_apply default false) convention.
-- No cron is scheduled — usage is deliberately manual (reports are scarce: 2,000/mo
-- plan-wide; this pipeline self-caps at 600/mo via td_reports_budget_ok()).
-- ─────────────────────────────────────────────────────────────────────────────

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. Reports accounting — /match consumes Market-Intelligence reports, which the
--    existing credit ledger did not track. Add two nullable columns + extend the
--    charge helper (trailing optional params → call-compatible with all callers).
-- ─────────────────────────────────────────────────────────────────────────────
ALTER TABLE public.ticketsdata_credit_usage
  ADD COLUMN IF NOT EXISTS reports           int NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS reports_remaining int;

COMMENT ON COLUMN public.ticketsdata_credit_usage.reports IS
  'Market-Intelligence reports consumed by this call (1 for /match, 0 otherwise).';
COMMENT ON COLUMN public.ticketsdata_credit_usage.reports_remaining IS
  'reports_remaining from the /match response envelope (plan-wide, not just this pipeline).';

-- Drop the prior 6-arg overload FIRST — adding params via CREATE OR REPLACE makes
-- a NEW overload (different signature), leaving the old one to make 6-arg calls
-- (td_normalize_drain etc.) ambiguous. The 8-arg version is call-compatible.
DROP FUNCTION IF EXISTS public.td_charge_credit(integer, bigint, text, text, integer, integer);
CREATE OR REPLACE FUNCTION public.td_charge_credit(
  p_n               integer DEFAULT 1,
  p_event_id        bigint  DEFAULT NULL,
  p_platform        text    DEFAULT NULL,
  p_endpoint        text    DEFAULT '/fetch',
  p_status_code     integer DEFAULT NULL,
  p_quota_remaining integer DEFAULT NULL,
  p_reports         integer DEFAULT 0,
  p_reports_remaining integer DEFAULT NULL
)
RETURNS void
LANGUAGE sql
VOLATILE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
  INSERT INTO public.ticketsdata_credit_usage
    (credits, event_id, platform, endpoint, status_code, quota_remaining,
     reports, reports_remaining)
  VALUES
    (p_n, p_event_id, p_platform, p_endpoint, p_status_code, p_quota_remaining,
     COALESCE(p_reports, 0), p_reports_remaining);
$$;
REVOKE ALL ON FUNCTION public.td_charge_credit(integer,bigint,text,text,integer,integer,integer,integer) FROM anon, public;

-- Monthly report counter (UTC calendar month, matching td_credits_this_month).
CREATE OR REPLACE FUNCTION public.td_reports_this_month()
RETURNS integer
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
  SELECT COALESCE(SUM(reports), 0)::integer
  FROM public.ticketsdata_credit_usage
  WHERE date_trunc('month', called_at AT TIME ZONE 'UTC')
      = date_trunc('month', CURRENT_TIMESTAMP AT TIME ZONE 'UTC');
$$;
REVOKE ALL ON FUNCTION public.td_reports_this_month() FROM anon, public;

-- Report budget gate for the automated /match pipeline.
--   Plan provides 2,000 Market-Intelligence reports/month. This pipeline self-caps
--   at 600/mo so the remaining ~1,400 stay free for manual dashboard + MVP use.
--   RULE: if the plan or allocation changes, update the 600 here and add a comment.
CREATE OR REPLACE FUNCTION public.td_reports_budget_ok()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
  SELECT public.td_reports_this_month() < 600;  -- 600/2,000 plan reports → automated cap
$$;
REVOKE ALL ON FUNCTION public.td_reports_budget_ok() FROM anon, public;


-- ─────────────────────────────────────────────────────────────────────────────
-- 2. td_match_queue — one row per /match job (fire→drain async, pg_net pattern).
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.td_match_queue (
  id                bigserial   PRIMARY KEY,
  tevo_event_id     bigint,                         -- canonical event being resolved (if known)
  aq_short_event_id text,                           -- target aq_event_map row to enrich (if known)
  seed_platform     text,                           -- platform the seed URL came from (audit only)
  seed_event_url    text        NOT NULL,           -- the URL fed to /match (auto-detects source)
  purpose           text        NOT NULL DEFAULT 'fill'
                      CHECK (purpose IN ('fill','adjudicate')),
  request_id        bigint,                          -- pg_net request id (net._http_response.id)
  fired_at          timestamptz NOT NULL DEFAULT now(),
  resolved_at       timestamptz,
  status_code       int,
  retry_count       int         NOT NULL DEFAULT 0,
  error_msg         text
);
CREATE INDEX IF NOT EXISTS idx_td_match_queue_open
  ON public.td_match_queue (fired_at) WHERE resolved_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_td_match_queue_tevo
  ON public.td_match_queue (tevo_event_id) WHERE tevo_event_id IS NOT NULL;

REVOKE ALL ON public.td_match_queue FROM anon, authenticated;
ALTER TABLE public.td_match_queue ENABLE ROW LEVEL SECURITY;
CREATE POLICY td_match_queue_service_only ON public.td_match_queue
  FOR ALL TO service_role USING (true);


-- ─────────────────────────────────────────────────────────────────────────────
-- 3. td_match_results — parsed /match output (staging; td_match_apply consumes it).
--    Only sg/sh/vivid ids are reliably URL-extractable as bigint. ticketmaster is
--    a hex id and tickpick/gametime have no aq column — captured in matches_raw.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.td_match_results (
  id                bigserial   PRIMARY KEY,
  queue_id          bigint      REFERENCES public.td_match_queue(id),
  tevo_event_id     bigint,
  aq_short_event_id text,
  purpose           text,
  match_type        text,                            -- exact | probable
  match_confidence  numeric(6,2),
  match_reason      jsonb,
  event_date        date,
  event_venue       text,
  sg_event_id       bigint,
  sh_event_id       bigint,
  vivid_event_id    bigint,
  tm_url            text,
  tickpick_url      text,
  gametime_url      text,
  matches_raw       jsonb,                           -- full matches{} map from the envelope
  applied_at        timestamptz,                     -- set by td_match_apply(true)
  created_at        timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_td_match_results_unapplied
  ON public.td_match_results (created_at) WHERE applied_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_td_match_results_tevo
  ON public.td_match_results (tevo_event_id) WHERE tevo_event_id IS NOT NULL;

REVOKE ALL ON public.td_match_results FROM anon, authenticated;
ALTER TABLE public.td_match_results ENABLE ROW LEVEL SECURITY;
CREATE POLICY td_match_results_service_only ON public.td_match_results
  FOR ALL TO service_role USING (true);


-- ─────────────────────────────────────────────────────────────────────────────
-- 4. td_match_enqueue(p_purpose, p_limit) — fire N /match calls.
--    Gated by td_budget_ok() AND td_reports_budget_ok(). A report is CHARGED at
--    drain time (on 200), so the gate here is a pre-flight guard.
--
--    Target selection:
--      'fill'       aq rows missing ≥1 of (sg/sh/vivid)_event_id that HAVE a seed
--                   URL (via ticketsdata_event_xref.event_url), highest-value first,
--                   not matched in the last 14 days, not already queued.
--      'adjudicate' tevo events with ≥2 aq rows carrying DISTINCT non-null
--                   sg_event_id (the A1-OPS-22 conflicting clusters); /match tells
--                   us if they're the same event or genuinely split.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.td_match_enqueue(
  p_purpose text DEFAULT 'fill',
  p_limit   integer DEFAULT 5
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'extensions', 'pg_temp'
AS $fn$
DECLARE
  r       RECORD;
  v_user  text;
  v_pass  text;
  v_req   bigint;
  v_n     int := 0;
BEGIN
  IF p_purpose NOT IN ('fill','adjudicate') THEN
    RAISE EXCEPTION 'td_match_enqueue: p_purpose must be fill|adjudicate, got %', p_purpose;
  END IF;
  IF NOT public.td_budget_ok() THEN
    RAISE NOTICE 'td_match_enqueue: TD credit budget exhausted — skipping'; RETURN 0;
  END IF;
  IF NOT public.td_reports_budget_ok() THEN
    RAISE NOTICE 'td_match_enqueue: TD report budget exhausted (600/mo cap) — skipping'; RETURN 0;
  END IF;
  v_user := public.get_app_secret('TICKETSDATA_USERNAME');
  v_pass := public.get_app_secret('TICKETSDATA_PASSWORD');
  IF v_user IS NULL OR v_pass IS NULL THEN
    RAISE EXCEPTION 'td_match_enqueue: TD creds missing in vault';
  END IF;

  FOR r IN
    WITH targets AS (
      -- ── FILL ───────────────────────────────────────────────────────────────
      SELECT a.tevo_event_id, a.aq_short_event_id, x.platform AS seed_platform,
             x.event_url AS seed_url,
             COALESCE(x.owned_tickets, 0) AS rank_owned,
             COALESCE(x.rank_score, 0)    AS rank_score
      FROM public.aq_event_map a
      JOIN public.ticketsdata_event_xref x
        ON x.aq_short_event_id = a.aq_short_event_id
       AND x.active AND x.event_url IS NOT NULL
      WHERE p_purpose = 'fill'
        AND (a.sg_event_id IS NULL OR a.sh_event_id IS NULL OR a.vivid_event_id IS NULL)
        AND NOT EXISTS (
          SELECT 1 FROM public.td_match_results mr
          WHERE mr.aq_short_event_id = a.aq_short_event_id
            AND mr.created_at > now() - interval '14 days')
        AND NOT EXISTS (
          SELECT 1 FROM public.td_match_queue q
          WHERE q.aq_short_event_id = a.aq_short_event_id
            AND q.resolved_at IS NULL)

      UNION ALL

      -- ── ADJUDICATE (conflicting-sg clusters, A1-OPS-22) ──────────────────────
      SELECT c.tevo_event_id, c.aq_short_event_id, x.platform, x.event_url,
             COALESCE(x.owned_tickets, 0), COALESCE(x.rank_score, 0)
      FROM (
        SELECT a.tevo_event_id,
               (array_agg(a.aq_short_event_id ORDER BY a.aq_short_event_id))[1] AS aq_short_event_id
        FROM public.aq_event_map a
        WHERE p_purpose = 'adjudicate' AND a.tevo_event_id IS NOT NULL
        GROUP BY a.tevo_event_id
        HAVING count(DISTINCT a.sg_event_id) FILTER (WHERE a.sg_event_id IS NOT NULL) >= 2
      ) c
      JOIN public.ticketsdata_event_xref x
        ON x.aq_short_event_id = c.aq_short_event_id
       AND x.active AND x.event_url IS NOT NULL
      WHERE NOT EXISTS (
          SELECT 1 FROM public.td_match_queue q
          WHERE q.tevo_event_id = c.tevo_event_id AND q.resolved_at IS NULL)
    )
    SELECT DISTINCT ON (aq_short_event_id)
           tevo_event_id, aq_short_event_id, seed_platform, seed_url, rank_owned, rank_score
    FROM targets
    ORDER BY aq_short_event_id, rank_owned DESC, rank_score DESC
    LIMIT GREATEST(p_limit, 0)
  LOOP
    SELECT net.http_get(
      url := 'https://ticketsdata.com/match',
      params := jsonb_build_object(
        'event_url', r.seed_url,
        'username',  v_user,
        'password',  v_pass),
      headers := '{}'::jsonb,
      timeout_milliseconds := 45000   -- /match fans out to all platforms; allow ~12–15s+
    ) INTO v_req;

    INSERT INTO public.td_match_queue
      (tevo_event_id, aq_short_event_id, seed_platform, seed_event_url, purpose, request_id)
    VALUES (r.tevo_event_id, r.aq_short_event_id, r.seed_platform, r.seed_url, p_purpose, v_req);
    v_n := v_n + 1;
  END LOOP;

  RETURN v_n;
END $fn$;
REVOKE ALL ON FUNCTION public.td_match_enqueue(text,integer) FROM anon, public;


-- ─────────────────────────────────────────────────────────────────────────────
-- 5. td_match_drain(p_max) — parse returned /match responses into td_match_results.
--    Charges 12 credits + 1 report on a successful (200, status=success) response.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.td_match_drain(p_max integer DEFAULT 50)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'extensions', 'pg_temp'
AS $fn$
DECLARE
  r        RECORD;
  j        jsonb;
  v_status text;
  v_n      int := 0;
BEGIN
  FOR r IN
    SELECT q.id AS qid, q.tevo_event_id, q.aq_short_event_id, q.purpose,
           h.status_code, h.content AS raw
    FROM public.td_match_queue q
    JOIN net._http_response h ON h.id = q.request_id
    WHERE q.resolved_at IS NULL AND q.request_id IS NOT NULL
    ORDER BY q.fired_at ASC
    LIMIT GREATEST(p_max, 0)
  LOOP
    BEGIN
      j := r.raw::jsonb;
      v_status := j->>'status';

      IF r.status_code = 200 AND v_status = 'success' THEN
        INSERT INTO public.td_match_results
          (queue_id, tevo_event_id, aq_short_event_id, purpose, match_type,
           match_confidence, match_reason, event_date, event_venue,
           sg_event_id, sh_event_id, vivid_event_id, tm_url, tickpick_url,
           gametime_url, matches_raw)
        VALUES (
          r.qid, r.tevo_event_id, r.aq_short_event_id, r.purpose,
          j->>'match_type',
          NULLIF(j->>'match_confidence','')::numeric,
          j->'match_reason',
          NULLIF(j->'event_details'->>'date','')::date,
          j->'event_details'->>'venue',
          -- seatgeek …/concert/<digits>
          (substring(coalesce(j->'matches'->>'seatgeek',''),   '/concert/([0-9]{4,})'))::bigint,
          -- stubhub …/event/<digits>/
          (substring(coalesce(j->'matches'->>'stubhub',''),    '/event/([0-9]{4,})'))::bigint,
          -- vividseats …/production/<digits>
          (substring(coalesce(j->'matches'->>'vividseats',''), '/production/([0-9]{4,})'))::bigint,
          coalesce(j->'matches'->>'ticketmaster_us', j->'matches'->>'ticketmaster_ca'),
          j->'matches'->>'tickpick',
          j->'matches'->>'gametime',
          j->'matches'
        );
        PERFORM public.td_charge_credit(
          12, r.tevo_event_id, NULL, '/match', 200,
          NULLIF(j->>'quota_remaining','')::int,
          1, NULLIF(j->>'reports_remaining','')::int);

        UPDATE public.td_match_queue
        SET resolved_at = clock_timestamp(), status_code = 200
        WHERE id = r.qid;

      ELSIF r.status_code = 402 THEN
        -- Plan quota exhausted — stop; do not keep firing.
        UPDATE public.td_match_queue
        SET resolved_at = clock_timestamp(), status_code = 402,
            error_msg = 'quota_exhausted'
        WHERE id = r.qid;
        RAISE NOTICE 'td_match_drain: 402 quota exhausted — stopping';
        EXIT;

      ELSE
        UPDATE public.td_match_queue
        SET resolved_at = clock_timestamp(),
            status_code = r.status_code,
            error_msg = left(coalesce(v_status, r.raw), 500)
        WHERE id = r.qid;
      END IF;

      v_n := v_n + 1;

    EXCEPTION WHEN OTHERS THEN
      UPDATE public.td_match_queue
      SET resolved_at = clock_timestamp(), status_code = -1, error_msg = left(SQLERRM, 500)
      WHERE id = r.qid;
    END;
  END LOOP;

  RETURN v_n;
END $fn$;
REVOKE ALL ON FUNCTION public.td_match_drain(integer) FROM anon, public;


-- ─────────────────────────────────────────────────────────────────────────────
-- 6. td_match_apply(p_min_confidence, p_apply) — COALESCE-fill NULL platform ids
--    on aq_event_map from staged /match results. DRY-RUN by default. Never
--    overwrites a non-null value; a disagreement surfaces as action='CONFLICT'.
--
--    Returns one row per (aq row × platform column) considered:
--      action = 'FILL'     — column was NULL, /match has a value (applied if p_apply)
--               'CONFLICT' — column non-null AND differs from /match (left untouched)
--               'AGREE'    — column non-null AND equals /match (no-op)
--               'SKIP_LOWCONF' — match_confidence below threshold (whole row skipped)
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.td_match_apply(
  p_min_confidence numeric DEFAULT 90,
  p_apply          boolean DEFAULT false
)
RETURNS TABLE (
  aq_short_event_id text,
  tevo_event_id     bigint,
  col               text,
  old_value         bigint,
  new_value         bigint,
  confidence        numeric,
  action            text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $fn$
DECLARE
  res  RECORD;
  a    RECORD;
  pair RECORD;
BEGIN
  FOR res IN
    SELECT * FROM public.td_match_results
    WHERE applied_at IS NULL AND aq_short_event_id IS NOT NULL
    ORDER BY created_at ASC
  LOOP
    SELECT m.aq_short_event_id, m.tevo_event_id,
           m.sg_event_id, m.sh_event_id, m.vivid_event_id
    INTO a
    FROM public.aq_event_map m
    WHERE m.aq_short_event_id = res.aq_short_event_id;

    IF NOT FOUND THEN CONTINUE; END IF;

    IF res.match_confidence IS NULL OR res.match_confidence < p_min_confidence THEN
      aq_short_event_id := res.aq_short_event_id; tevo_event_id := a.tevo_event_id;
      col := '*'; old_value := NULL; new_value := NULL;
      confidence := res.match_confidence; action := 'SKIP_LOWCONF';
      RETURN NEXT;
      CONTINUE;
    END IF;

    -- Evaluate each fillable platform column.
    FOR pair IN
      SELECT * FROM (VALUES
        ('sg_event_id',    a.sg_event_id,    res.sg_event_id),
        ('sh_event_id',    a.sh_event_id,    res.sh_event_id),
        ('vivid_event_id', a.vivid_event_id, res.vivid_event_id)
      ) AS v(col, cur, proposed)
    LOOP
      IF pair.proposed IS NULL THEN
        CONTINUE;  -- /match had nothing for this platform
      ELSIF pair.cur IS NULL THEN
        action := 'FILL';
      ELSIF pair.cur = pair.proposed THEN
        action := 'AGREE';
      ELSE
        action := 'CONFLICT';
      END IF;

      IF p_apply AND action = 'FILL' THEN
        -- COALESCE-fill only (column was NULL). imported_at is intentionally
        -- left unchanged — it records the original AQ import, not edit time.
        EXECUTE format(
          'UPDATE public.aq_event_map SET %I = $1 WHERE aq_short_event_id = $2',
          pair.col)
        USING pair.proposed, res.aq_short_event_id;
      END IF;

      aq_short_event_id := res.aq_short_event_id; tevo_event_id := a.tevo_event_id;
      col := pair.col; old_value := pair.cur; new_value := pair.proposed;
      confidence := res.match_confidence;
      RETURN NEXT;
    END LOOP;

    IF p_apply THEN
      UPDATE public.td_match_results SET applied_at = now() WHERE id = res.id;
    END IF;
  END LOOP;

  RETURN;
END $fn$;
REVOKE ALL ON FUNCTION public.td_match_apply(numeric,boolean) FROM anon, public;


-- ── Operator runbook (manual, budget-gated) ──────────────────────────────────
--   SELECT public.td_match_enqueue('fill', 5);   -- fire 5 /match calls (60 credits + 5 reports)
--   -- wait ~30–60s for pg_net responses, then:
--   SELECT public.td_match_drain();               -- parse → td_match_results
--   SELECT * FROM public.td_match_apply(90, false);   -- DRY-RUN review
--   SELECT * FROM public.td_match_apply(90, true);    -- apply FILLs; CONFLICTs left for manual
--   -- adjudicate the conflicting-sg clusters (A1-OPS-22):
--   SELECT public.td_match_enqueue('adjudicate', 5);  -- then drain; inspect td_match_results.match_reason

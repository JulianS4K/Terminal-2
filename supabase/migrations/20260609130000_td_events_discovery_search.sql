-- Migration 20260609130000 · lane:D0 (author) → A1 (apply) ·
--   writes (DDL): td_discover_targets (new), td_discovered_events (new),
--                 td_events_discover(), td_events_discover_drain(),
--                 td_match_discovered_to_local(), v_td_unmatched_discovered_events,
--                 terminal_search() (v2) ·
--   reads: aq_performer_map, events, aq_venue_map ·
--   writes on run: td_discovered_events ·
--   spends: TicketsData /events = 1 credit/call (budget-gated by td_budget_ok()) ·
--   pre: 20260517230000 (terminal_search v1)
--
-- ## NOT YET APPLIED — author-only migration file.
--    Pending A1 review + explicit operator apply (CLAUDE.md §1). Validate on a
--    Supabase branch (copy-on-write fork) before any prod apply.
--
-- WHY ───────────────────────────────────────────────────────────────────────
-- Workstream B: use TicketsData /events (performer → upcoming events, 1 credit,
-- no report) to ENHANCE SEARCH & RESULTS. Today terminal_search only returns
-- events already in our local `events` table, and /events discovery is wired
-- narrowly (td_gt_performers = 4 teams, td_sg_performers = 19 artists, both
-- feeding the matcher only — never the search surface).
--
-- This adds a general, budget-gated discovery layer that:
--   1. discovers upcoming events for performers we track but whose events we
--      DON'T have locally (the catalog-coverage gap),
--   2. stages them in td_discovered_events + flags the unmatched ones via the
--      v_td_unmatched_discovered_events view,
--   3. surfaces them in terminal_search as a new 'marketplace' section, so a
--      user searching for an event we don't track still gets a marketplace hit.
--
-- SCOPE NOTE: seeded for platform 'seatgeek' only — its /events envelope shape
-- (body.items[] with event_id / buy_url / event_date_utc / name|title) is the
-- proven one (td_sg_discover_drain). td_discover_targets is multi-platform by
-- design; other platforms are added once their /events shape is verified live.
-- ─────────────────────────────────────────────────────────────────────────────

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. td_discover_targets — unified, multi-platform performer/venue discovery
--    registry. Generalizes td_sg_performers / td_gt_performers.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.td_discover_targets (
  id                 bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  platform           text NOT NULL
                       CHECK (platform IN ('seatgeek','stubhub','vividseats',
                                           'gametime','tickpick','ticketmaster')),
  performer_url      text,
  venue_url          text,
  label              text,
  tevo_performer_id  bigint,
  active             boolean NOT NULL DEFAULT true,
  pending_request_id bigint,
  last_discovered_at timestamptz,
  created_at         timestamptz NOT NULL DEFAULT now(),
  updated_at         timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT td_discover_targets_url_present
    CHECK (performer_url IS NOT NULL OR venue_url IS NOT NULL),
  UNIQUE (platform, performer_url)
);
CREATE INDEX IF NOT EXISTS idx_td_disc_targets_due
  ON public.td_discover_targets (platform)
  WHERE active AND pending_request_id IS NULL;

COMMENT ON TABLE public.td_discover_targets IS
  'Unified TicketsData /events discovery registry (multi-platform). Drives '
  'td_events_discover(). Budget-gated. Seeded for seatgeek; other platforms '
  'added once their /events envelope is verified.';

REVOKE ALL ON public.td_discover_targets FROM anon, authenticated;
ALTER TABLE public.td_discover_targets ENABLE ROW LEVEL SECURITY;
CREATE POLICY td_disc_targets_service_only ON public.td_discover_targets
  FOR ALL TO service_role USING (true);

-- Seed: carry forward the existing SG allowlist, then broaden to performers we
-- TRACK that have upcoming local events (so /events surfaces their untracked
-- dates). SeatGeek slug pattern matches td_sg_performers' construction.
INSERT INTO public.td_discover_targets (platform, performer_url, label, tevo_performer_id)
SELECT 'seatgeek', sp.performer_url, sp.performer_name, sp.tevo_performer_id
FROM public.td_sg_performers sp
ON CONFLICT (platform, performer_url) DO NOTHING;

INSERT INTO public.td_discover_targets (platform, performer_url, label, tevo_performer_id)
SELECT DISTINCT 'seatgeek',
       'https://seatgeek.com/'
         || trim(both '-' from regexp_replace(lower(pm.performer_name), '[^a-z0-9]+', '-', 'g'))
         || '-tickets',
       pm.performer_name, pm.tevo_performer_id
FROM public.aq_performer_map pm
WHERE pm.tevo_performer_id IS NOT NULL
  AND pm.performer_name IS NOT NULL
  AND EXISTS (
    SELECT 1 FROM public.events e
    WHERE e.primary_performer_id = pm.tevo_performer_id
      AND e.occurs_at_local >= now()
      AND coalesce(e.state,'') <> 'past'
  )
ON CONFLICT (platform, performer_url) DO NOTHING;


-- ─────────────────────────────────────────────────────────────────────────────
-- 2. td_discovered_events — staging for events returned by /events. One row per
--    (platform, td_event_id). matched_tevo_event_id is filled when the event
--    maps to a local `events` row (so we can tell "new to us" from "already have").
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.td_discovered_events (
  id                    bigserial   PRIMARY KEY,
  platform              text        NOT NULL,
  td_event_id           text        NOT NULL,
  event_url             text,
  event_name            text,
  event_date            date,
  venue_name            text,
  city                  text,
  performer_label       text,
  target_id             bigint      REFERENCES public.td_discover_targets(id),
  matched_tevo_event_id bigint,
  raw                   jsonb,
  discovered_at         timestamptz NOT NULL DEFAULT now(),
  UNIQUE (platform, td_event_id)
);
CREATE INDEX IF NOT EXISTS idx_td_disc_events_unmatched
  ON public.td_discovered_events (event_date)
  WHERE matched_tevo_event_id IS NULL;
CREATE INDEX IF NOT EXISTS idx_td_disc_events_name
  ON public.td_discovered_events (lower(event_name));

REVOKE ALL ON public.td_discovered_events FROM anon, authenticated;
ALTER TABLE public.td_discovered_events ENABLE ROW LEVEL SECURITY;
CREATE POLICY td_disc_events_service_only ON public.td_discovered_events
  FOR ALL TO service_role USING (true);
-- terminal_search (SECURITY DEFINER, email-gated) reads this on the caller's
-- behalf; no direct anon/authenticated grant needed.


-- ─────────────────────────────────────────────────────────────────────────────
-- 3. td_events_discover(p_platform, p_limit) — fire /events for due targets.
--    Generalizes td_sg_discover. Budget-gated by td_budget_ok().
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.td_events_discover(
  p_platform text DEFAULT 'seatgeek',
  p_limit    integer DEFAULT 5
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'extensions', 'pg_temp'
AS $fn$
DECLARE
  r      RECORD;
  v_user text;
  v_pass text;
  v_req  bigint;
  v_n    int := 0;
BEGIN
  IF NOT public.td_budget_ok() THEN
    RAISE NOTICE 'td_events_discover: TD budget exhausted — skipping'; RETURN 0;
  END IF;
  v_user := public.get_app_secret('TICKETSDATA_USERNAME');
  v_pass := public.get_app_secret('TICKETSDATA_PASSWORD');
  IF v_user IS NULL OR v_pass IS NULL THEN
    RAISE EXCEPTION 'td_events_discover: TD creds missing in vault';
  END IF;

  FOR r IN
    SELECT id, performer_url, venue_url
    FROM public.td_discover_targets
    WHERE active AND platform = p_platform AND pending_request_id IS NULL
      AND (last_discovered_at IS NULL OR last_discovered_at < now() - interval '7 days')
    ORDER BY last_discovered_at NULLS FIRST, id
    LIMIT GREATEST(p_limit, 0)
  LOOP
    SELECT net.http_get(
      url := 'https://ticketsdata.com/events',
      params := jsonb_strip_nulls(jsonb_build_object(
        'platform',     p_platform,
        'performer_url', r.performer_url,
        'venue_url',     r.venue_url,
        'username',      v_user,
        'password',      v_pass)),
      headers := '{}'::jsonb,
      timeout_milliseconds := 35000
    ) INTO v_req;
    UPDATE public.td_discover_targets
    SET pending_request_id = v_req, updated_at = now()
    WHERE id = r.id;
    v_n := v_n + 1;
  END LOOP;

  RETURN v_n;
END $fn$;
REVOKE ALL ON FUNCTION public.td_events_discover(text,integer) FROM anon, public;


-- ─────────────────────────────────────────────────────────────────────────────
-- 4. td_events_discover_drain() — parse responses → td_discovered_events, then
--    match to local events. Charges 1 credit/call on a 200. Common /events
--    envelope: body.items[] {event_id, buy_url, name|title|display_name,
--    event_date_utc, venue|display_name}.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.td_events_discover_drain()
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'extensions', 'pg_temp'
AS $fn$
DECLARE
  r    RECORD;
  ev   RECORD;
  v_id text;
  v_ins int := 0;
BEGIN
  FOR r IN
    SELECT t.id AS tid, t.platform, t.label, h.status_code, h.content AS raw
    FROM public.td_discover_targets t
    JOIN net._http_response h ON h.id = t.pending_request_id
    WHERE t.pending_request_id IS NOT NULL
  LOOP
    IF r.status_code = 200 THEN
      FOR ev IN
        SELECT item FROM jsonb_array_elements(
          COALESCE(r.raw::jsonb->'body'->'items', r.raw::jsonb->'items', '[]'::jsonb)
        ) AS item
      LOOP
        v_id := COALESCE(
          NULLIF(ev.item->>'event_id',''),
          NULLIF(ev.item->>'id',''),
          NULLIF(substring(COALESCE(ev.item->>'buy_url', ev.item->>'url',''), '([0-9]{5,})'),''),
          md5(ev.item::text));

        INSERT INTO public.td_discovered_events
          (platform, td_event_id, event_url, event_name, event_date,
           venue_name, city, performer_label, target_id, raw)
        VALUES (
          r.platform, v_id,
          COALESCE(ev.item->>'buy_url', ev.item->>'url', ev.item->>'link'),
          COALESCE(ev.item->>'name', ev.item->>'title', ev.item->>'display_name', r.label),
          NULLIF(left(COALESCE(ev.item->>'event_date_utc', ev.item->>'event_date',
                               ev.item->>'datetime_utc',''), 10), '')::date,
          COALESCE(ev.item->>'venue', ev.item->>'venue_name'),
          COALESCE(ev.item->>'city', ev.item->>'venue_city'),
          r.label, r.tid, ev.item)
        ON CONFLICT (platform, td_event_id) DO UPDATE
          SET event_url = EXCLUDED.event_url,
              event_name = EXCLUDED.event_name,
              event_date = EXCLUDED.event_date,
              venue_name = EXCLUDED.venue_name,
              raw = EXCLUDED.raw;
        v_ins := v_ins + 1;
      END LOOP;

      PERFORM public.td_charge_credit(1, NULL,
              CASE r.platform WHEN 'seatgeek' THEN 'SG' WHEN 'stubhub' THEN 'SH'
                              WHEN 'vividseats' THEN 'VD' WHEN 'gametime' THEN 'GT'
                              WHEN 'tickpick' THEN 'TP' WHEN 'ticketmaster' THEN 'TM'
                              ELSE upper(left(r.platform,2)) END,
              '/events', 200, (r.raw::jsonb->>'quota_remaining')::int);
    END IF;

    UPDATE public.td_discover_targets
    SET pending_request_id = NULL, last_discovered_at = now(), updated_at = now()
    WHERE id = r.tid;
  END LOOP;

  IF v_ins > 0 THEN PERFORM public.td_match_discovered_to_local(); END IF;
  RETURN v_ins;
END $fn$;
REVOKE ALL ON FUNCTION public.td_events_discover_drain() FROM anon, public;


-- ─────────────────────────────────────────────────────────────────────────────
-- 5. td_match_discovered_to_local() — best-effort link discovered → local events
--    by event_date + fuzzy venue (read-only against `events`; sets only the
--    matched_tevo_event_id back-reference on staging). Conservative: requires a
--    same-date AND venue trigram ≥ 0.6 single best candidate.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.td_match_discovered_to_local()
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'extensions', 'pg_temp'
AS $fn$
DECLARE v_n int := 0;
BEGIN
  WITH cand AS (
    SELECT d.id AS disc_id,
           e.id AS tevo_event_id,
           similarity(lower(coalesce(d.venue_name,'')), lower(coalesce(e.venue_name,''))) AS sim,
           row_number() OVER (
             PARTITION BY d.id
             ORDER BY similarity(lower(coalesce(d.venue_name,'')), lower(coalesce(e.venue_name,''))) DESC
           ) AS rn
    FROM public.td_discovered_events d
    JOIN public.events e
      ON (left(e.occurs_at_local,10))::date = d.event_date   -- occurs_at_local is text
    WHERE d.matched_tevo_event_id IS NULL
      AND d.event_date IS NOT NULL
      AND d.venue_name IS NOT NULL
  )
  UPDATE public.td_discovered_events d
  SET matched_tevo_event_id = c.tevo_event_id
  FROM cand c
  WHERE c.disc_id = d.id AND c.rn = 1 AND c.sim >= 0.6;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n;
END $fn$;
REVOKE ALL ON FUNCTION public.td_match_discovered_to_local() FROM anon, public;


-- ─────────────────────────────────────────────────────────────────────────────
-- 6. v_td_unmatched_discovered_events — upcoming marketplace events with no local
--    match = catalog-coverage gaps.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE VIEW public.v_td_unmatched_discovered_events AS
SELECT id, platform, td_event_id, event_url, event_name, event_date,
       venue_name, city, performer_label, discovered_at
FROM public.td_discovered_events
WHERE matched_tevo_event_id IS NULL
  AND event_date >= (now() AT TIME ZONE 'UTC')::date;


-- ─────────────────────────────────────────────────────────────────────────────
-- 7. terminal_search() v2 — add a 'marketplace' section (unmatched discovered
--    events). Additive: existing events/performers/venues keys unchanged, so the
--    frontend is forward-compatible. Email-gate + caps preserved from v1.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.terminal_search(
  p_q     text,
  p_limit integer DEFAULT 6
)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, extensions, pg_temp
AS $func$
DECLARE
  v_email text;
  v_q     text;
  v_pat   text;
  v_cap   integer;
  v_evs   jsonb;
  v_perfs jsonb;
  v_vens  jsonb;
  v_mkt   jsonb;
BEGIN
  v_email := coalesce(auth.jwt()->>'email', '');
  IF v_email NOT LIKE '%@s4kent.com' THEN
    RAISE EXCEPTION 'forbidden: % is not an @s4kent.com email', v_email USING ERRCODE = '42501';
  END IF;

  v_q   := trim(coalesce(p_q, ''));
  v_cap := greatest(1, least(coalesce(p_limit, 6), 20));
  IF length(v_q) < 2 THEN
    RETURN jsonb_build_object('q', v_q, 'events', '[]'::jsonb, 'performers', '[]'::jsonb,
                              'venues', '[]'::jsonb, 'marketplace', '[]'::jsonb);
  END IF;
  v_pat := '%' || v_q || '%';

  SELECT coalesce(jsonb_agg(to_jsonb(e) ORDER BY e.match_len, e.occurs_at_local), '[]'::jsonb)
  INTO v_evs
  FROM (
    SELECT id AS tevo_event_id, name, venue_name, occurs_at_local,
           primary_performer_name, length(name) AS match_len
    FROM public.events
    WHERE name ILIKE v_pat
      -- occurs_at_local is TEXT (ISO8601 w/ offset); text>=timestamptz errors, so
      -- compare as a string against the formatted cutoff (fixes latent v1 bug).
      AND occurs_at_local >= to_char(now() - interval '6 hours', 'YYYY-MM-DD"T"HH24:MI:SS')
      AND coalesce(state, '') <> 'past'
    ORDER BY length(name) ASC, occurs_at_local ASC
    LIMIT v_cap
  ) e;

  SELECT coalesce(jsonb_agg(to_jsonb(p) ORDER BY p.match_len, p.performer_name), '[]'::jsonb)
  INTO v_perfs
  FROM (
    SELECT DISTINCT ON (m.tevo_performer_id)
      m.tevo_performer_id, m.performer_short_id, m.performer_name, m.category,
      length(m.performer_name) AS match_len
    FROM public.aq_performer_map m
    WHERE m.tevo_performer_id IS NOT NULL
      AND ( m.performer_name ILIKE v_pat
            OR EXISTS (SELECT 1 FROM unnest(coalesce(m.aliases, ARRAY[]::text[])) AS a(alias)
                       WHERE a.alias ILIKE v_pat) )
    ORDER BY m.tevo_performer_id, length(m.performer_name) ASC
    LIMIT v_cap
  ) p;

  SELECT coalesce(jsonb_agg(to_jsonb(v) ORDER BY v.match_len, v.venue_name), '[]'::jsonb)
  INTO v_vens
  FROM (
    SELECT DISTINCT ON (m.tevo_venue_id)
      m.tevo_venue_id, m.venue_short_id, m.venue_name, m.city, m.state,
      length(m.venue_name) AS match_len
    FROM public.aq_venue_map m
    WHERE m.tevo_venue_id IS NOT NULL
      AND (m.venue_name ILIKE v_pat OR m.city ILIKE v_pat)
    ORDER BY m.tevo_venue_id, length(m.venue_name) ASC
    LIMIT v_cap
  ) v;

  -- NEW: marketplace events we discovered via /events but don't track locally.
  SELECT coalesce(jsonb_agg(to_jsonb(k) ORDER BY k.event_date), '[]'::jsonb)
  INTO v_mkt
  FROM (
    SELECT DISTINCT ON (lower(event_name), event_date, platform)
      platform, td_event_id, event_url, event_name, event_date, venue_name, city
    FROM public.v_td_unmatched_discovered_events
    WHERE (event_name ILIKE v_pat OR performer_label ILIKE v_pat OR venue_name ILIKE v_pat)
    ORDER BY lower(event_name), event_date, platform
    LIMIT v_cap
  ) k;

  RETURN jsonb_build_object(
    'q', v_q, 'limit', v_cap,
    'events', v_evs, 'performers', v_perfs, 'venues', v_vens,
    'marketplace', v_mkt
  );
END $func$;

REVOKE ALL ON FUNCTION public.terminal_search(text, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.terminal_search(text, integer) TO anon, authenticated;

COMMENT ON FUNCTION public.terminal_search(text, integer) IS
  'D0 terminal topbar search — events (upcoming) / performers / venues / marketplace '
  '(TicketsData-discovered, untracked). Email-gated. Cap 20/section. v2 mig 20260609130000.';


-- ── Operator runbook (manual, budget-gated) ──────────────────────────────────
--   SELECT public.td_events_discover('seatgeek', 5);  -- fire 5 performer searches (5 credits)
--   -- wait ~30s for pg_net responses, then:
--   SELECT public.td_events_discover_drain();          -- parse → td_discovered_events + match
--   -- search now returns a 'marketplace' section for untracked events;
--   -- SELECT * FROM public.v_td_unmatched_discovered_events;  -- catalog-coverage gaps

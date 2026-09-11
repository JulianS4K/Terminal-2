-- ============================================================================
-- Migration 20260911200000 — ONE event mapper: event_mapper_resolve() + the shared cold path
-- Migration 20260911200000 · level:data-collection · lane:A1 · writes:tevo_venue_search,cross_source_venue_map,events,aq_event_map,cron_policy,cron.job
--
-- Lane:     A1 (data plane) — serves EVERY surface that maps a marketplace event to TEvo
-- Touches:  events (R; W only through the existing tevo_venue_events_harvest),
--           aq_event_map (R; W only through the existing create_system_aq_event),
--           cross_source_venue_map (W — alias promotion, same block as tevo_venue_daily_harvest),
--           tevo_venue_search (W — the existing queue, seeded), cron_policy (W), cron.job (W),
--           s4kcs_orders, n2s_items, tickpick_orders, vivid_orders (R — the needs union),
--           gotickets_event, sg_events_canonical, event_lifecycle (R)
-- Pre-reqs: 20260909030000 + 20260909180000 (tevo_venue_search queue; the enqueue/harvest/adopt
--           helper BODIES are prod-only, applied via MCP 2026-09-09 — signatures verified live
--           2026-09-11), 20260810184500 (matcher v3 guards), 20260610100000
--           (match_to_aq_event_id 8-arg), 20260908235500 (cross_source_venue_resolve),
--           20260608194500 (aq_name_consistent),
--           20260515250000 (cron_policy + cron_should_fire). Vault: TEVO_API_TOKEN / TEVO_SECRET
--           (read by the reused helpers only).
--
-- Already applied to prod · via MCP 2026-09-11 ~18:05 UTC under operator direction ("Apply all three now").
-- Authored 2026-09-11 (operator: "merge all event mappers into one so we can
-- utilize the same resources instead of reinventing every time" · "all event mappers" ·
-- "utilize evo performer and venue search where necessary"). Supersedes the UNAPPLIED
-- 20260911161100_our_purchases_map_evo.sql on branch claude/underpriced-listing-detector-8hdzzb
-- (its twin tie-breaks + matcher-v3 pass live on as rules 1 + 2 below; its cron never existed).
-- Parsed clean (pglast) and EXECUTED end-to-end on a scratch Postgres 16 seeded with prod rows
-- (the 54 unmapped GoTickets purchases + their mirror twins); never run against prod.
--
-- ============================================================================
-- WHY ONE RESOLVER
-- ============================================================================
-- Twelve functions each re-implement "name + venue + date → tevo_event_id" with their own
-- guards: our_purchases_map (mig 161000), s4kcs_map_events (8 rules), n2s_map_events
-- (rules 0–5), gotickets_attempt_event_xref (matcher v3), sg_attempt_event_xref_v3,
-- axs_aq_match, match_to_aq_event_id (4-tier), link_aq_tevo_from_events, the sibling fill,
-- n2s_gt_map_by_name, refresh_td_event_links, paciolan_aq_match. Every fix (parking, twins,
-- Memorial-Stadium prefix, TBD) lands in one and not the others.
--
-- This migration adds the ONE resolver and the ONE cold path; callers are switched over one
-- per PR behind event_mapper_parity() (dry-run agreement vs. what each mapper already
-- wrote). This PR switches our_purchases_map (mig 20260911200100). NOTHING existing is
-- dropped or re-pointed here.
--
--   event_mapper_resolve(source, source_id, name, performer, venue, city, state,
--                        local_date, utc, allow_identity, min_overlap)
--     → (tevo_event_id, method, score) or NO ROW. Pure, STABLE, writes nothing.
--     Rule 0 identity   — the hub (aq_event_map.<src>_event_id), sg_events_canonical,
--                         gotickets_event, or the TEvo id itself. Score 1.0.
--     Rule 1 venue+day  — same LOCAL day at the resolved venue (cross_source_venue_resolve
--                         OR exact venue string), name-token overlap ≥ 0.5 when the day has one
--                         candidate / ≥ 0.6 when several, TWIN TIE-BREAKS: the "(Rescheduled…)"
--                         flag must agree, then Session/Game/Match number, then strictly-best
--                         overlap. A tie is a decline. (from mig 161100, verified on the 7 twins)
--     Rule 2 venue±24h  — matcher v3 (gotickets_attempt_event_xref shape): venue-anchored
--                         ±24h with performer/name containment; 0.80 + 0.10 venue-id + 0.05
--                         exact venue. Declines when two EQUALLY-LIVE candidates share the instant.
--     Liveness tie-break (rules 1 + 2): TEvo re-lists an event under a new id and the mirror
--     keeps both (e.g. Colts at Titans 2026-12-20 = 3286193 seen daily + 3381900 last seen
--     in May, 0 listings). The twin the mirror saw 7+ days more recently wins; twins seen
--     within 7 days of each other stay a tie. gt_map_events' row_number tie had picked the
--     stale id on 4 future catalogue rows (found 2026-09-11). Parking pseudo-events are
--     never candidates.
--     Rule 3 name+day   — exact normalised name on the same local day, unique across venues,
--                         ≥ 2 distinctive tokens. 0.70. (s4kcs rule 2 shape)
--     Rule 4 AQ 4-tier  — match_to_aq_event_id → hub row that already carries a tevo id.
--                         Score = its confidence, capped 0.95 (identity is the only 1.0).
--     Global guards: parking pseudo-events (input AND candidates), "(Date TBD)" / "If Necessary"
--     (date unreliable — rule 0 still allowed), no date at all, and aq_name_consistent() on every
--     name-driven candidate (the s4kcs rule-8 / SG matcher-v3 matchup guard: "A at B" vs "C at B"
--     must agree on the away side). Unique-or-decline everywhere; never a guess.
--
--   v_event_mapper_needs — the union of every unmapped row (surface, row_key, the resolver
--     inputs). 20260911200100 adds the two purchase books. This is what the cold path feeds
--     on, so one TEvo request serves every surface that needs that venue.
--
--   event_mapper_deep_enqueue() / event_mapper_deep_harvest() — the shared cold path, built
--     ONLY from existing resources (RULE 2: the request shapes are the ones the reused
--     helpers already send — signed GET /v9/searches?entities=venues and GET /v9/events):
--       (c) venue STRING unresolved → tevo_venue_search 'pending' → tevo_venue_search_enqueue
--           (TEvo venue search) → _harvest → tevo_venue_alias_adopt → alias PROMOTED into
--           cross_source_venue_map (the block tevo_venue_daily_harvest runs; without it a
--           queue resolution never reaches cross_source_venue_resolve — found 2026-09-11).
--       (b) venue known, mirror has NOTHING on the need-day → tevo_venue_search 'resolved' /
--           ev_status NULL → tevo_venue_events_enqueue(60, since) pulls that venue's events
--           (past dates included — the purchase books are historical) → _harvest upserts
--           `events`.
--       (a) FUTURE need with a name → hub seed via create_system_aq_event (only when
--           match_to_aq_event_id finds no hub row) so the live aq-to-tevo-search-bridge
--           (every 15 min) runs TEvo's venue+date and NAME/performer search for it and fills
--           the hub; rule 4 then resolves it. The bridge's own selector is future-only, so
--           past needs take path (b).
--     Two crons an hour apart because pg_net's response TTL is 6 h (verified live): enqueue
--     08:45 UTC / harvest 09:45 UTC, bracketing the CRM venue sweep (09:05 / 09:35) so both
--     share one queue and one request budget. Ours fires FIRST on purpose: the CRM enqueue
--     resets ev_status and fires up to 60 venues (lowest tevo_venue_id first) with a 10-day
--     window and skips rows already 'requested' — so a venue we seeded for a PAST purchase
--     date must be in flight with OUR since-date before 09:05 or it would be pulled with the
--     CRM window and marked done. The CRM harvest at 09:35 harvests ours (50 min, inside the
--     TTL); ours at 09:45 catches stragglers, promotes aliases, and re-runs the appliers. A
--     venue string resolved on day 1 gets its events pulled on day 2's enqueue (ev_status NULL
--     after resolution) — the async queue's normal one-day lag, same as the CRM sweep.
--
--   event_mapper_parity(surface, limit) — dry-run harness for the phased switch-over:
--     replays the resolver (identity OFF, so the hub can't answer for itself) over rows a
--     mapper already mapped and reports agree / disagree / declined + 10 samples.
--
-- ROLLBACK: cron.unschedule('event_mapper_deep_enqueue_daily'), ('event_mapper_deep_harvest_daily');
--   DELETE FROM cron_policy WHERE jobname LIKE 'event_mapper_deep_%';
--   DROP FUNCTION event_mapper_parity(text,int), event_mapper_deep_harvest(), event_mapper_deep_enqueue();
--   DROP VIEW v_event_mapper_needs; DROP FUNCTION event_mapper_resolve(...), event_mapper_overlap(text,text),
--   event_mapper_norm_name(text). Seeded tevo_venue_search rows are ordinary queue rows (crm_orders=0).
-- ============================================================================

-- ── 0. Name helpers (IMMUTABLE, shared by every rule) ────────────────────────
CREATE OR REPLACE FUNCTION public.event_mapper_norm_name(p text)
RETURNS text
LANGUAGE sql IMMUTABLE PARALLEL SAFE
AS $fn$
  -- lower · parentheticals dropped ("(Rescheduled from 6/5)", "(Pirates Cowboy Hat Giveaway)")
  -- · punctuation → space · single-spaced.
  SELECT trim(regexp_replace(
           lower(regexp_replace(regexp_replace(coalesce(p, ''), '\s*\([^)]*\)\s*', ' ', 'g'),
                                '[^a-z0-9 ]', ' ', 'gi')),
           '\s+', ' ', 'g'));
$fn$;
COMMENT ON FUNCTION public.event_mapper_norm_name(text) IS
  'Event-name normaliser for the unified event mapper: lower, parentheticals dropped, punctuation → space. A1 mig 20260911200000.';

CREATE OR REPLACE FUNCTION public.event_mapper_overlap(p_needle_norm text, p_hay text)
RETURNS numeric
LANGUAGE sql IMMUTABLE PARALLEL SAFE
AS $fn$
  -- Share of the needle's DISTINCT tokens (length > 2) that appear as whole words in the hay.
  -- The hay keeps its parentheticals: "(Rescheduled…)" must stay visible to the tie-break.
  WITH t AS (SELECT DISTINCT tok FROM unnest(string_to_array(coalesce(p_needle_norm, ''), ' ')) tok
              WHERE length(tok) > 2),
       h AS (SELECT lower(regexp_replace(coalesce(p_hay, ''), '[^a-z0-9 ]', ' ', 'gi')) AS hay)
  SELECT round((SELECT count(*) FROM t, h WHERE h.hay ~ ('\m' || t.tok || '\M'))::numeric
               / NULLIF((SELECT count(*) FROM t), 0), 3);
$fn$;
COMMENT ON FUNCTION public.event_mapper_overlap(text, text) IS
  'Token overlap (0–1) of a normalised needle against a raw event name; whole-word, distinct tokens > 2 chars. A1 mig 20260911200000.';

-- ── 1. THE resolver ──────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.event_mapper_resolve(
  p_source          text,
  p_source_event_id bigint,
  p_name            text,
  p_performer       text,
  p_venue_name      text,
  p_venue_city      text,
  p_venue_state     text,
  p_local_date      date,
  p_event_time_utc  timestamptz,
  p_allow_identity  boolean DEFAULT true,
  p_min_overlap     numeric DEFAULT 0.5
)
RETURNS TABLE(tevo_event_id bigint, method text, score numeric)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $fn$
DECLARE
  v_src     text    := lower(trim(coalesce(p_source, '')));
  v_name    text    := coalesce(p_name, '');
  v_venue   text    := nullif(trim(coalesce(p_venue_name, '')), '');
  v_nm      text    := public.event_mapper_norm_name(p_name);
  v_ntok    int;
  v_resched boolean := coalesce(p_name, '') ~* 'reschedul';
  v_num     text    := (regexp_match(coalesce(p_name, ''), '(?:session|game|match)\s*#?\s*(\d{1,3})', 'i'))[1];
  v_needle  text    := lower(trim(coalesce(nullif(trim(coalesce(p_performer, '')), ''), p_name, '')));
  v_vid     bigint;
  v_tevo    bigint;
  v_score   numeric;
  v_meth    text;
  v_n       int;
BEGIN
  IF current_user NOT IN ('service_role', 'postgres', 'supabase_admin') THEN
    RAISE EXCEPTION 'forbidden: %', current_user USING ERRCODE = '42501';
  END IF;

  -- Parking pseudo-events: TEvo merges parking into the main listing (§3 landmine).
  IF coalesce(p_venue_name, '') ILIKE '%parking%' OR v_name ILIKE '%parking%'
     OR coalesce(p_performer, '') ILIKE '%parking%' THEN
    RETURN;
  END IF;

  -- ── Rule 0: identity through the hub / canonical tables ───────────────────
  IF p_allow_identity AND p_source_event_id IS NOT NULL THEN
    IF v_src IN ('tevo', 'evo') THEN
      tevo_event_id := p_source_event_id; method := 'identity_tevo'; score := 1.0;
      RETURN NEXT; RETURN;
    END IF;
    IF v_src IN ('gotickets', 'gt') THEN
      SELECT g.tevo_event_id INTO v_tevo FROM public.gotickets_event g
       WHERE g.gt_event_id = p_source_event_id AND g.tevo_event_id IS NOT NULL LIMIT 1;
      IF v_tevo IS NOT NULL THEN v_meth := 'identity_gotickets_event'; END IF;
      IF v_tevo IS NULL THEN
        SELECT a.tevo_event_id INTO v_tevo FROM public.aq_event_map a
         WHERE a.gotickets_event_id = p_source_event_id AND a.tevo_event_id IS NOT NULL
         ORDER BY (a.aq_source = 'aq_curated') DESC, a.imported_at DESC LIMIT 1;
        IF v_tevo IS NOT NULL THEN v_meth := 'identity_hub'; END IF;
      END IF;
    ELSIF v_src IN ('seatgeek', 'sg') THEN
      SELECT c.tevo_event_id INTO v_tevo FROM public.sg_events_canonical c
       WHERE c.sg_event_id = p_source_event_id AND c.tevo_event_id IS NOT NULL LIMIT 1;
      IF v_tevo IS NOT NULL THEN v_meth := 'identity_sg_canonical'; END IF;
      IF v_tevo IS NULL THEN
        SELECT a.tevo_event_id INTO v_tevo FROM public.aq_event_map a
         WHERE a.sg_event_id = p_source_event_id AND a.tevo_event_id IS NOT NULL
         ORDER BY (a.aq_source = 'aq_curated') DESC, a.imported_at DESC LIMIT 1;
        IF v_tevo IS NOT NULL THEN v_meth := 'identity_hub'; END IF;
      END IF;
    ELSIF v_src IN ('vivid', 'vividseats', 'vivid seats', 'stubhub', 'sh', 'ticketmaster', 'tm', 'seatdata', 'sd') THEN
      SELECT a.tevo_event_id INTO v_tevo FROM public.aq_event_map a
       WHERE a.tevo_event_id IS NOT NULL
         AND ((v_src IN ('vivid', 'vividseats', 'vivid seats') AND a.vivid_event_id = p_source_event_id)
           OR (v_src IN ('stubhub', 'sh')                      AND a.sh_event_id    = p_source_event_id)
           OR (v_src IN ('ticketmaster', 'tm')                 AND a.tm_event_id    = p_source_event_id)
           OR (v_src IN ('seatdata', 'sd')                     AND a.sd_event_id    = p_source_event_id))
       ORDER BY (a.aq_source = 'aq_curated') DESC, a.imported_at DESC LIMIT 1;
      IF v_tevo IS NOT NULL THEN v_meth := 'identity_hub'; END IF;
    END IF;
    IF v_tevo IS NOT NULL THEN
      tevo_event_id := v_tevo; method := v_meth; score := 1.0;
      RETURN NEXT; RETURN;
    END IF;
  END IF;

  -- Date-unreliable names never match by date (identity above is the only path for them).
  IF v_name ~* '(\(date tbd\)|\btbd\b|if necessary)' THEN RETURN; END IF;
  IF p_local_date IS NULL AND p_event_time_utc IS NULL THEN RETURN; END IF;

  v_vid  := public.cross_source_venue_resolve(p_venue_name, p_venue_city, p_venue_state);
  SELECT count(*) INTO v_ntok FROM unnest(string_to_array(v_nm, ' ')) t WHERE length(t) > 2;

  -- ── Rule 1: venue + same LOCAL day + token overlap, twin tie-breaks ───────
  IF p_local_date IS NOT NULL AND v_venue IS NOT NULL AND v_ntok >= 1 THEN
    WITH cand AS (
      SELECT e.id, e.last_seen,
             public.event_mapper_overlap(v_nm, e.name) AS ov,
             ((e.name ~* 'reschedul') = v_resched)::int
             + (v_num IS NOT NULL
                AND (regexp_match(e.name, '(?:session|game|match)\s*#?\s*(\d{1,3})', 'i'))[1] = v_num)::int AS keys
        FROM public.events e
       WHERE left(e.occurs_at_local, 10) = p_local_date::text
         AND (e.venue_name ILIKE v_venue OR (v_vid IS NOT NULL AND e.venue_id = v_vid))
         AND NOT (e.name ILIKE '%parking%' OR coalesce(e.venue_name, '') ILIKE '%parking%')
         -- matchup guard shared with s4kcs rule 8 / SG matcher v3: "A at B" vs "C at B" on the
         -- same day at the same venue (doubleheaders, tournaments) must agree on the away side
         AND public.aq_name_consistent(e.name, p_name)
    ), scored AS (
      SELECT c.*, count(*) OVER () AS n_cand FROM cand c
    ), good AS (
      SELECT s.*, count(*) OVER () AS n_good
        FROM scored s
       WHERE s.ov >= CASE WHEN s.n_cand = 1 THEN p_min_overlap ELSE greatest(p_min_overlap, 0.6) END
    ), ranked AS (
      SELECT g.*, row_number() OVER w AS rn, lead(g.keys) OVER w AS next_keys, lead(g.ov) OVER w AS next_ov,
             lead(g.last_seen) OVER w AS next_seen
        FROM good g
      WINDOW w AS (ORDER BY g.keys DESC, g.ov DESC, g.last_seen DESC NULLS LAST, g.id)
    )
    -- Liveness tie-break: TEvo re-lists an event under a new id and the mirror keeps both;
    -- the live one keeps getting seen. Two twins seen within 7 days of each other stay a tie.
    SELECT r.id, r.ov INTO v_tevo, v_score
      FROM ranked r
     WHERE r.rn = 1
       AND (r.n_good = 1 OR r.keys > coalesce(r.next_keys, -1) OR r.ov > coalesce(r.next_ov, -1)
            OR r.last_seen > coalesce(r.next_seen, '-infinity'::timestamptz) + interval '7 days');
    IF v_tevo IS NOT NULL THEN
      tevo_event_id := v_tevo; method := 'venue_day_name'; score := v_score;
      RETURN NEXT; RETURN;
    END IF;
  END IF;

  -- ── Rule 2: venue-anchored ±24h + performer/name containment (matcher v3) ──
  IF p_event_time_utc IS NOT NULL AND v_venue IS NOT NULL AND v_needle <> '' THEN
    SELECT x.id, x.sc, x.n_same INTO v_tevo, v_score, v_n
      FROM (
        SELECT y.id, y.sc,
               -- twins at one instant: a twin the mirror has not seen for 7+ days longer than
               -- the freshest one is a stale re-list, not a competitor (liveness tie-break)
               count(*) FILTER (WHERE y.last_seen IS NULL OR y.last_seen >= y.max_seen - interval '7 days')
                 OVER (PARTITION BY y.occurs_at_local) AS n_same,
               y.exact_venue, y.by_vid, y.dist, y.active, y.last_seen
          FROM (
            SELECT e.id, e.occurs_at_local, e.last_seen,
                   0.80
                   + CASE WHEN v_vid IS NOT NULL AND e.venue_id = v_vid THEN 0.10 ELSE 0 END
                   + CASE WHEN lower(trim(coalesce(e.venue_name, ''))) = lower(v_venue) THEN 0.05 ELSE 0 END AS sc,
                   max(e.last_seen) OVER (PARTITION BY e.occurs_at_local) AS max_seen,
                   (lower(trim(coalesce(e.venue_name, ''))) = lower(v_venue)) AS exact_venue,
                   (v_vid IS NOT NULL AND e.venue_id = v_vid) AS by_vid,
                   abs(extract(epoch FROM (e.occurs_at_local::timestamptz - p_event_time_utc))) AS dist,
                   coalesce(lc.is_active, true) AS active
              FROM public.events e
              LEFT JOIN public.event_lifecycle lc ON lc.event_id = e.id
             WHERE e.occurs_at_local ~ '^\d{4}-\d{2}-\d{2}'
               AND NOT (e.name ILIKE '%parking%' OR coalesce(e.venue_name, '') ILIKE '%parking%')
               AND (v_name = '' OR public.aq_name_consistent(e.name, p_name))
               AND e.occurs_at_local::timestamptz BETWEEN p_event_time_utc - interval '24 hours'
                                                      AND p_event_time_utc + interval '24 hours'
               AND (   (v_vid IS NOT NULL AND e.venue_id = v_vid)
                    OR lower(trim(coalesce(e.venue_name, ''))) = lower(v_venue)
                    OR lower(trim(coalesce(e.venue_name, ''))) LIKE lower(v_venue) || '%'
                    OR lower(v_venue) LIKE lower(trim(coalesce(e.venue_name, ''))) || '%')
               AND (   lower(coalesce(e.primary_performer_name, '')) LIKE '%' || v_needle || '%'
                    OR lower(coalesce(e.name, '')) LIKE '%' || v_needle || '%'
                    OR (char_length(coalesce(e.primary_performer_name, '')) >= 4
                        AND v_needle LIKE '%' || lower(e.primary_performer_name) || '%'))
          ) y
      ) x
     ORDER BY x.exact_venue DESC, x.by_vid DESC, x.dist, x.active DESC, x.last_seen DESC NULLS LAST, x.id
     LIMIT 1;
    IF v_tevo IS NOT NULL AND v_n = 1 THEN
      tevo_event_id := v_tevo; method := 'venue_24h_performer'; score := v_score;
      RETURN NEXT; RETURN;
    END IF;
    v_tevo := NULL;
  END IF;

  -- ── Rule 3: exact normalised name on the same local day, unique across venues ──
  IF p_local_date IS NOT NULL AND v_ntok >= 2 THEN
    SELECT count(*), min(e.id) INTO v_n, v_tevo
      FROM public.events e
     WHERE left(e.occurs_at_local, 10) = p_local_date::text
       AND NOT (e.name ILIKE '%parking%' OR coalesce(e.venue_name, '') ILIKE '%parking%')
       AND public.event_mapper_norm_name(e.name) = v_nm
       AND public.aq_name_consistent(e.name, p_name);
    IF v_n = 1 THEN
      tevo_event_id := v_tevo; method := 'name_day_exact'; score := 0.70;
      RETURN NEXT; RETURN;
    END IF;
    v_tevo := NULL;
  END IF;

  -- ── Rule 4: AQ 4-tier → hub row that already carries a tevo id ────────────
  -- match_to_aq_event_id windows ±6 h around an instant. With only a local DATE known,
  -- anchor at local noon (covers 06:00–18:00) and then local 19:00 (13:00–01:00) — the
  -- two anchors together span every plausible start time without a third call.
  FOR v_n IN 1..2 LOOP
    SELECT a.tevo_event_id, r.confidence, r.match_method INTO v_tevo, v_score, v_meth
      FROM public.match_to_aq_event_id(
             v_src,
             CASE WHEN p_allow_identity THEN p_source_event_id END,
             p_name, p_venue_name,
             coalesce(p_event_time_utc,
                      (p_local_date + CASE WHEN v_n = 1 THEN interval '12 hours' ELSE interval '19 hours' END)::timestamptz),
             NULL, NULL, NULL) r
      JOIN public.aq_event_map a
        ON a.aq_short_event_id = r.aq_short_event_id AND a.tevo_event_id IS NOT NULL
     LIMIT 1;
    EXIT WHEN v_tevo IS NOT NULL OR p_event_time_utc IS NOT NULL;
  END LOOP;
  IF v_tevo IS NOT NULL THEN
    tevo_event_id := v_tevo; method := 'aq_' || coalesce(v_meth, 'match'); score := least(coalesce(v_score, 0.5), 0.95);
    RETURN NEXT;
  END IF;
  RETURN;
END $fn$;
REVOKE ALL ON FUNCTION public.event_mapper_resolve(text, bigint, text, text, text, text, text, date, timestamptz, boolean, numeric) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.event_mapper_resolve(text, bigint, text, text, text, text, text, date, timestamptz, boolean, numeric) TO service_role;
COMMENT ON FUNCTION public.event_mapper_resolve(text, bigint, text, text, text, text, text, date, timestamptz, boolean, numeric) IS
  'THE event mapper (any marketplace event → tevo_event_id): identity (hub/canonical) → venue+local-day+overlap with twin tie-breaks → venue±24h performer (matcher v3) → exact name+day → AQ 4-tier. Pure/STABLE; unique-or-decline; parking + TBD guarded. A1 mig 20260911200000.';

-- ── 2. The needs union (surface-independent part; 20260911200100 adds the purchase books) ──
CREATE OR REPLACE VIEW public.v_event_mapper_needs AS
  SELECT 's4kcs_orders'::text AS surface, o.s4k_order_id AS row_key, lower(o.source) AS source,
         NULL::bigint AS source_event_id, o.event_name, NULL::text AS performer,
         o.venue_name, o.venue_city, o.venue_state, o.event_date AS local_date, NULL::timestamptz AS event_time_utc
    FROM public.s4kcs_orders o
   WHERE o.tevo_event_id IS NULL AND o.event_date >= current_date - 30
  UNION ALL
  SELECT 'n2s_items', n.n2s_id::text, lower(n.marketplace), NULL, n.event_name, NULL,
         n.venue, NULL, NULL, n.event_dt::date, NULL
    FROM public.n2s_items n
   WHERE n.tevo_event_id IS NULL AND coalesce(n.is_terminal, false) = false AND n.event_dt IS NOT NULL
  UNION ALL
  SELECT 'tickpick_orders', t.tp_order_id, 'tickpick', NULL, t.event_name, NULL,
         NULL, NULL, NULL, t.event_date::date, t.event_date
    FROM public.tickpick_orders t
   WHERE t.tevo_event_id IS NULL AND t.event_date >= now() - interval '90 days'
  UNION ALL
  SELECT 'vivid_orders', v.vivid_order_id, 'vivid', NULL, v.event_name, NULL,
         NULL, NULL, NULL, v.event_date::date, v.event_date
    FROM public.vivid_orders v
   WHERE v.tevo_event_id IS NULL AND v.event_date >= now() - interval '90 days';
COMMENT ON VIEW public.v_event_mapper_needs IS
  'Every unmapped marketplace row (surface, row_key, resolver inputs) the shared cold path feeds on. Purchase books added by mig 20260911200100. A1 mig 20260911200000.';

-- ── 3. Cold path, step 1: seed the EXISTING queues and fire their requests ──
CREATE OR REPLACE FUNCTION public.event_mapper_deep_enqueue()
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $fn$
DECLARE
  v_pending int := 0; v_resolved int := 0; v_seeded int := 0; v_vs int := 0; v_ve int := 0;
  v_since date; v_need int := 0; r record;
BEGIN
  IF current_user NOT IN ('service_role', 'postgres', 'supabase_admin') THEN
    RAISE EXCEPTION 'forbidden: %', current_user USING ERRCODE = '42501';
  END IF;
  PERFORM set_config('statement_timeout', '120000', true);

  -- One row per venue string across EVERY surface (parking / TBD / If-Necessary never need a pull).
  CREATE TEMP TABLE _need ON COMMIT DROP AS
  SELECT x.venue_name, max(x.venue_city) AS venue_city, max(x.venue_state) AS venue_state,
         min(x.local_date) AS first_date, count(*) AS n,
         public.cross_source_venue_resolve(x.venue_name, max(x.venue_city), max(x.venue_state)) AS vid
    FROM public.v_event_mapper_needs x
   WHERE x.venue_name IS NOT NULL AND x.local_date IS NOT NULL
     AND NOT (x.venue_name ILIKE '%parking%' OR coalesce(x.event_name, '') ILIKE '%parking%')
     AND NOT (coalesce(x.event_name, '') ~* '(\(date tbd\)|\btbd\b|if necessary|season tickets?)')
   GROUP BY x.venue_name;
  SELECT count(*) INTO v_need FROM _need;

  -- (c) unresolved venue STRINGS → the venue-search queue (TEvo /v9/searches, entities=venues).
  INSERT INTO public.tevo_venue_search (venue_name_raw, state_hint, state_code, crm_orders, status)
  SELECT n.venue_name,
         coalesce(n.venue_state, (regexp_match(n.venue_name, '[,-]\s*([A-Za-z]{2})\s*$'))[1]),
         public.tevo_state_code(coalesce(n.venue_state, (regexp_match(n.venue_name, '[,-]\s*([A-Za-z]{2})\s*$'))[1])),
         0, 'pending'
    FROM _need n WHERE n.vid IS NULL
  ON CONFLICT (venue_name_raw) DO NOTHING;
  GET DIAGNOSTICS v_pending = ROW_COUNT;

  -- (b) resolved venues whose need-days have NO mirror event → resolved row, events not yet pulled.
  INSERT INTO public.tevo_venue_search (venue_name_raw, state_hint, state_code, crm_orders, status, tevo_venue_id, ev_status)
  SELECT n.venue_name, n.venue_state, public.tevo_state_code(n.venue_state), 0, 'resolved', n.vid, NULL
    FROM _need n
   WHERE n.vid IS NOT NULL
     AND NOT EXISTS (
       SELECT 1 FROM public.v_event_mapper_needs x
         JOIN public.events e ON e.venue_id = n.vid AND left(e.occurs_at_local, 10) = x.local_date::text
        WHERE x.venue_name = n.venue_name)
  ON CONFLICT (venue_name_raw) DO UPDATE
    SET ev_status  = CASE WHEN tevo_venue_search.status = 'resolved'
                           AND coalesce(tevo_venue_search.ev_status, '') <> 'requested'
                          THEN NULL ELSE tevo_venue_search.ev_status END,
        updated_at = now();
  GET DIAGNOSTICS v_resolved = ROW_COUNT;

  -- (a) FUTURE needs → hub seed, so the live aq-to-tevo-search-bridge runs TEvo's venue+date
  --     and name/performer search for them (its selector is future-only, ≤ 50 seeds a day).
  FOR r IN
    SELECT x.source, x.source_event_id, x.event_name, x.venue_name, x.local_date
      FROM public.v_event_mapper_needs x
     WHERE x.local_date >= current_date AND x.event_name IS NOT NULL AND x.venue_name IS NOT NULL
       AND NOT (x.venue_name ILIKE '%parking%' OR x.event_name ILIKE '%parking%')
       AND NOT (x.event_name ~* '(\(date tbd\)|\btbd\b|if necessary|season tickets?)')
     ORDER BY x.local_date
     LIMIT 50
  LOOP
    IF NOT EXISTS (SELECT 1 FROM public.match_to_aq_event_id(
                     r.source, r.source_event_id, r.event_name, r.venue_name,
                     r.local_date::timestamptz, NULL, NULL, NULL)) THEN
      PERFORM public.create_system_aq_event(r.source, r.event_name, r.venue_name,
                                            r.local_date::timestamptz, r.source_event_id);
      v_seeded := v_seeded + 1;
    END IF;
  END LOOP;

  -- Fire the existing resolvers (each bounded by its own limit; events since the earliest
  -- need, never more than 180 days back — the purchase books are historical).
  SELECT greatest(min(n.first_date), current_date - 180) INTO v_since FROM _need n WHERE n.vid IS NOT NULL;
  v_vs := public.tevo_venue_search_enqueue(20);
  IF v_since IS NOT NULL THEN
    v_ve := public.tevo_venue_events_enqueue(60, v_since);
  END IF;

  RETURN jsonb_build_object('venues_needing_help', v_need, 'seeded_pending', v_pending,
                            'seeded_resolved', v_resolved, 'hub_seeded_future', v_seeded,
                            'venue_searches_fired', v_vs, 'venue_event_pulls_fired', v_ve,
                            'events_since', v_since);
END $fn$;
REVOKE ALL ON FUNCTION public.event_mapper_deep_enqueue() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.event_mapper_deep_enqueue() TO service_role;
COMMENT ON FUNCTION public.event_mapper_deep_enqueue() IS
  'Shared cold path, step 1: from v_event_mapper_needs seed tevo_venue_search (unresolved strings → pending; known venues with no mirror event → resolved/ev_status NULL), hub-seed future needs for the TEvo search bridge, then fire tevo_venue_search_enqueue + tevo_venue_events_enqueue(60, since). Async — harvest with event_mapper_deep_harvest(). A1 mig 20260911200000.';

-- ── 4. Cold path, step 2: harvest through the existing tools, promote, re-map ──
CREATE OR REPLACE FUNCTION public.event_mapper_deep_harvest()
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $fn$
DECLARE
  v_search jsonb; v_adopt int := 0; v_promoted int := 0; v_aliases int := 0; v_ev record; v_appliers jsonb := '{}'::jsonb; v_one jsonb;
BEGIN
  IF current_user NOT IN ('service_role', 'postgres', 'supabase_admin') THEN
    RAISE EXCEPTION 'forbidden: %', current_user USING ERRCODE = '42501';
  END IF;
  PERFORM set_config('statement_timeout', '170000', true);

  SELECT jsonb_object_agg(h.outcome, h.n) INTO v_search FROM public.tevo_venue_search_harvest() h;
  v_adopt := public.tevo_venue_alias_adopt();

  -- Promote every queue resolution into THE venue xref (same block as tevo_venue_daily_harvest;
  -- cross_source_venue_resolve reads only cross_source_venue_map — never a rival map).
  INSERT INTO public.cross_source_venue_map
    (tevo_venue_id, tevo_venue_name, tevo_venue_location, city, state,
     crm_aliases, gotickets_aliases, id_provenance, created_at, updated_at)
  SELECT t.tevo_venue_id, t.tevo_venue_name, t.tevo_location,
         nullif(trim(split_part(t.tevo_location, ',', 1)), ''),
         nullif(upper(trim(split_part(t.tevo_location, ',', 2))), ''),
         jsonb_build_array(t.venue_name_raw), '[]'::jsonb,
         jsonb_build_object('tevo_venue_id', 'tevo_venue_search /v9/searches (event_mapper)'),
         now(), now()
    FROM (SELECT DISTINCT ON (tevo_venue_id) tevo_venue_id, tevo_venue_name, tevo_location, venue_name_raw
            FROM public.tevo_venue_search WHERE status = 'resolved' AND tevo_venue_id IS NOT NULL
           ORDER BY tevo_venue_id, crm_orders DESC) t
   WHERE NOT EXISTS (SELECT 1 FROM public.cross_source_venue_map m WHERE m.tevo_venue_id = t.tevo_venue_id)
  ON CONFLICT DO NOTHING;
  GET DIAGNOSTICS v_promoted = ROW_COUNT;

  -- Aliases: every resolved queue string becomes a crm_alias of its venue (idempotent).
  UPDATE public.cross_source_venue_map m
     SET crm_aliases = (
           SELECT coalesce(jsonb_agg(DISTINCT a), '[]'::jsonb) FROM (
             SELECT jsonb_array_elements(coalesce(m.crm_aliases, '[]'::jsonb)) AS a
             UNION
             SELECT to_jsonb(s.venue_name_raw) FROM public.tevo_venue_search s
              WHERE s.status = 'resolved' AND s.tevo_venue_id = m.tevo_venue_id
           ) u),
         updated_at = now()
   WHERE EXISTS (SELECT 1 FROM public.tevo_venue_search s
                  WHERE s.status = 'resolved' AND s.tevo_venue_id = m.tevo_venue_id
                    AND NOT (coalesce(m.crm_aliases, '[]'::jsonb) ? s.venue_name_raw));
  GET DIAGNOSTICS v_aliases = ROW_COUNT;

  SELECT * INTO v_ev FROM public.tevo_venue_events_harvest();

  -- Appliers already switched to the resolver (each guarded: it may not be applied yet).
  IF to_regprocedure('public.our_purchases_map()') IS NOT NULL THEN
    EXECUTE 'SELECT public.our_purchases_map()' INTO v_one;
    v_appliers := v_appliers || jsonb_build_object('our_purchases_map', v_one);
  END IF;

  RETURN jsonb_build_object('venue_search', coalesce(v_search, '{}'::jsonb), 'aliases_adopted', v_adopt,
                            'venues_promoted', v_promoted, 'aliases_promoted', v_aliases,
                            'venues_harvested', v_ev.venues, 'events_upserted', v_ev.events_upserted,
                            'appliers', v_appliers);
END $fn$;
REVOKE ALL ON FUNCTION public.event_mapper_deep_harvest() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.event_mapper_deep_harvest() TO service_role;
COMMENT ON FUNCTION public.event_mapper_deep_harvest() IS
  'Shared cold path, step 2: tevo_venue_search_harvest → tevo_venue_alias_adopt → promote aliases into cross_source_venue_map → tevo_venue_events_harvest → run the appliers switched to event_mapper_resolve. Pair with event_mapper_deep_enqueue(). A1 mig 20260911200000.';

-- ── 5. Parity harness for the phased switch-over ─────────────────────────────
CREATE OR REPLACE FUNCTION public.event_mapper_parity(p_surface text, p_limit int DEFAULT 300)
RETURNS TABLE(surface text, sampled int, agree int, disagree int, declined int, disagreements jsonb)
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $fn$
DECLARE v_sql text;
BEGIN
  IF current_user NOT IN ('service_role', 'postgres', 'supabase_admin') THEN
    RAISE EXCEPTION 'forbidden: %', current_user USING ERRCODE = '42501';
  END IF;
  PERFORM set_config('statement_timeout', '120000', true);

  v_sql := CASE p_surface
    WHEN 's4kcs_orders' THEN
      $q$SELECT s4k_order_id AS row_key, lower(source) AS source, NULL::bigint AS source_event_id, event_name,
                NULL::text AS performer, venue_name, venue_city, venue_state, event_date AS local_date,
                NULL::timestamptz AS event_time_utc, tevo_event_id AS expected
           FROM public.s4kcs_orders WHERE tevo_event_id IS NOT NULL
          ORDER BY mapped_at DESC NULLS LAST, event_date DESC$q$
    WHEN 'n2s_items' THEN
      $q$SELECT n2s_id::text AS row_key, lower(marketplace) AS source, NULL::bigint AS source_event_id, event_name,
                NULL::text AS performer, venue AS venue_name, NULL::text AS venue_city, NULL::text AS venue_state,
                event_dt::date AS local_date, NULL::timestamptz AS event_time_utc, tevo_event_id AS expected
           FROM public.n2s_items WHERE tevo_event_id IS NOT NULL AND event_dt IS NOT NULL
          ORDER BY n2s_updated_at DESC NULLS LAST$q$
    WHEN 'gotickets_event' THEN
      $q$SELECT gt_event_id::text AS row_key, 'gotickets'::text AS source, gt_event_id AS source_event_id, name AS event_name,
                performer, venue_name, venue_city, venue_state, NULL::date AS local_date, event_time_utc, tevo_event_id AS expected
           FROM public.gotickets_event WHERE tevo_event_id IS NOT NULL AND event_time_utc IS NOT NULL
          ORDER BY mapped_at DESC NULLS LAST$q$
    WHEN 'sg_events_canonical' THEN
      $q$SELECT sg_event_id::text AS row_key, 'seatgeek'::text AS source, sg_event_id AS source_event_id, sg_event_name AS event_name,
                NULL::text AS performer, sg_venue_name AS venue_name, sg_venue_city AS venue_city, sg_venue_state AS venue_state,
                sg_event_date AS local_date, sg_datetime_utc AS event_time_utc, tevo_event_id AS expected
           FROM public.sg_events_canonical WHERE tevo_event_id IS NOT NULL
          ORDER BY matched_at DESC NULLS LAST$q$
    WHEN 'gotickets_purchases' THEN
      $q$SELECT gt_purchase_id::text AS row_key, 'gotickets'::text AS source, gt_event_id AS source_event_id, event_name,
                performers->0->>'name' AS performer, venue_name, venue_city, venue_state,
                event_time_local::date AS local_date, event_time_utc, tevo_event_id AS expected
           FROM public.gotickets_purchases WHERE tevo_event_id IS NOT NULL
          ORDER BY updated_at DESC NULLS LAST$q$
    ELSE NULL END;
  IF v_sql IS NULL THEN
    RAISE EXCEPTION 'event_mapper_parity: unknown surface % (s4kcs_orders | n2s_items | gotickets_event | sg_events_canonical | gotickets_purchases)', p_surface;
  END IF;

  -- Identity OFF: the hub/canonical tables must not answer for the very rows being replayed.
  EXECUTE format(
    $x$CREATE TEMP TABLE _parity ON COMMIT DROP AS
       SELECT q.row_key, q.event_name, q.venue_name, q.local_date, q.expected, r.tevo_event_id AS got, r.method, r.score
         FROM (%s LIMIT %s) q
         LEFT JOIN LATERAL public.event_mapper_resolve(q.source, q.source_event_id, q.event_name, q.performer,
                q.venue_name, q.venue_city, q.venue_state, q.local_date, q.event_time_utc, false, 0.5) r ON true$x$,
    v_sql, greatest(1, least(2000, p_limit)));

  RETURN QUERY
  SELECT p_surface,
         count(*)::int,
         count(*) FILTER (WHERE p.got = p.expected)::int,
         count(*) FILTER (WHERE p.got IS NOT NULL AND p.got <> p.expected)::int,
         count(*) FILTER (WHERE p.got IS NULL)::int,
         coalesce((SELECT jsonb_agg(jsonb_build_object('row_key', d.row_key, 'name', d.event_name, 'venue', d.venue_name,
                                                        'date', d.local_date, 'expected', d.expected, 'got', d.got,
                                                        'method', d.method, 'score', d.score))
                     FROM (SELECT * FROM _parity WHERE got IS NOT NULL AND got <> expected LIMIT 10) d), '[]'::jsonb)
    FROM _parity p;
END $fn$;
REVOKE ALL ON FUNCTION public.event_mapper_parity(text, int) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.event_mapper_parity(text, int) TO service_role;
COMMENT ON FUNCTION public.event_mapper_parity(text, int) IS
  'Dry-run agreement of event_mapper_resolve (identity OFF) vs what a surface''s own mapper already wrote: sampled / agree / disagree / declined + 10 disagreement samples. Gate for switching each mapper over. A1 mig 20260911200000.';

-- ── 6. Daily cold path, two crons inside the CRM venue sweep window (pg_net TTL 6 h) ──
INSERT INTO public.cron_policy (jobname, peak_hours_et, peak_min_interval_min, offpeak_min_interval_min, work_check_sql, daily_max_fires, notes)
VALUES
  ('event_mapper_deep_enqueue_daily',
   ARRAY[0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23], 720, 720,
   'SELECT EXISTS (SELECT 1 FROM public.v_event_mapper_needs WHERE venue_name IS NOT NULL)',
   1, 'Seed + fire the shared TEvo venue/event cold path for every unmapped surface (08:45 UTC — BEFORE the CRM sweep enqueue at 09:05, see mig header). mig 20260911200000'),
  ('event_mapper_deep_harvest_daily',
   ARRAY[0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23], 720, 720,
   'SELECT EXISTS (SELECT 1 FROM public.tevo_venue_search WHERE status = ''requested'' OR ev_status = ''requested'' UNION ALL SELECT 1 FROM public.v_event_mapper_needs)',
   1, 'Harvest the cold path (09:45 UTC, after the CRM harvest at 09:35 — pg_net TTL 6 h), promote aliases, re-run the switched appliers. mig 20260911200000')
ON CONFLICT (jobname) DO UPDATE
  SET work_check_sql = excluded.work_check_sql, notes = excluded.notes, updated_at = now();

DO $cron$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    PERFORM cron.unschedule('event_mapper_deep_enqueue_daily')
      WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'event_mapper_deep_enqueue_daily');
    PERFORM cron.schedule('event_mapper_deep_enqueue_daily', '45 8 * * *', $body$
      DO $b$ BEGIN IF NOT public.cron_should_fire('event_mapper_deep_enqueue_daily') THEN RETURN; END IF;
        PERFORM public.event_mapper_deep_enqueue();
      END $b$;$body$);
    PERFORM cron.unschedule('event_mapper_deep_harvest_daily')
      WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'event_mapper_deep_harvest_daily');
    PERFORM cron.schedule('event_mapper_deep_harvest_daily', '45 9 * * *', $body$
      DO $b$ BEGIN IF NOT public.cron_should_fire('event_mapper_deep_harvest_daily') THEN RETURN; END IF;
        PERFORM public.event_mapper_deep_harvest();
      END $b$;$body$);
  END IF;
END;
$cron$;

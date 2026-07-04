-- Migration 20260703130000 · lane:A1 (data plane — TicketsData polling target set)
--   writes (DDL): td_seed_us_open_xref() [new]
--   writes on run: td_discover_targets (INSERT ~5 US Open targets, ON CONFLICT DO NOTHING)
--   reads: td_discovered_events, aq_event_map, ticketsdata_event_xref
--   spends: nothing at apply time. The credit-spending /events discovery + the
--           actual /fetch polling are RUN SEPARATELY via the operator runbook below
--           (both GET-only against ticketsdata.com — RULE 2 read-only-upstream, OK).
--   pre: 20260609130000 (td_discover_targets / td_discovered_events / td_events_discover*),
--        20260527050000 (ticketsdata_event_xref / td_pull_queue),
--        20260609150000 (td_tier_enqueue + td_poll_policy)
--   auth: operator directive 2026-07-03 (julian@s4kent.com — "poll all us open events with td")
--
-- ## NOT YET APPLIED — author-only migration file.
--    Application to prod is gated separately (CLAUDE.md §1 — apply_migration +
--    running the credit-spending discovery are Applier actions). Validate on a
--    Supabase branch (copy-on-write fork) before any prod apply.
--
-- WHY ────────────────────────────────────────────────────────────────────────
-- The ~85 upcoming "US Open Tennis" sessions (Arthur Ashe / Louis Armstrong /
-- Grandstand / National Tennis Center, TEvo events 31703xx + a few SYS- rows)
-- have NO marketplace linkage: every aq_event_map row has NULL sh_event_id /
-- vivid_event_id / sg_event_id, and there are ZERO ticketsdata_event_xref rows.
-- So the TD poller (td_apply_targets / td_tier_enqueue, which key on the SH/VD
-- ids) cannot see them — nothing is polled.
--
-- To poll them we must first DISCOVER them on a TD marketplace (TD /events
-- resolver → marketplace event ids + urls), then seed ticketsdata_event_xref +
-- back-fill the SH/VD ids onto aq_event_map so the existing tier crons pick them
-- up. This migration wires that path in two reusable pieces:
--
--   1. Register the US Open discovery targets (StubHub grouping/8307, VividSeats
--      performer/901 + grounds/7280 + package/29919, SeatGeek us-open-tennis).
--      URLs verified live 2026-07-03 (public marketplace pages; individual
--      StubHub sessions resolve under grouping/8307, e.g. event/159405626).
--
--   2. td_seed_us_open_xref() — after discovery has staged rows into
--      td_discovered_events and td_match_discovered_to_local() has linked them to
--      our local events, this promotes the StubHub/VividSeats US Open discoveries
--      into pollable ticketsdata_event_xref rows (manual_opt_in=true so the
--      td_apply_targets deactivation sweep — mig 20260629120000 — never drops
--      them) and back-fills aq_event_map.sh_event_id / vivid_event_id.
--
-- SeatGeek is registered for CATALOG discovery only — it is a NATIVE_PLATFORM
-- (ticketsdata_client.NATIVE_PLATFORMS) excluded from TD /fetch, so we never pay
-- TD to fetch SG inventory; the SG target just improves the local catalog/search.
--
-- Read-only vs upstream: this migration only touches OUR tables + defines a
-- function. Every ticketsdata.com call in the runbook is a GET (/events, /fetch).
-- ─────────────────────────────────────────────────────────────────────────────

-- ── 1. Register US Open discovery targets ────────────────────────────────────
-- td_discover_targets.platform CHECK allows seatgeek/stubhub/vividseats/…; the
-- UNIQUE(platform, performer_url) + ON CONFLICT keeps this idempotent.
INSERT INTO public.td_discover_targets (platform, performer_url, label) VALUES
  ('stubhub',    'https://www.stubhub.com/us-open-tennis-tickets/grouping/8307',                         'US Open Tennis'),
  ('vividseats', 'https://www.vividseats.com/us-open-tennis-tickets--sports-tennis/performer/901',       'US Open Tennis'),
  ('vividseats', 'https://www.vividseats.com/us-open-tennis-grounds-admission-only-tickets--sports-tennis/performer/7280', 'US Open Tennis - Grounds Admission'),
  ('vividseats', 'https://www.vividseats.com/us-open-tennis-package-tickets--sports-tennis/performer/29919', 'US Open Tennis - Package'),
  ('seatgeek',   'https://seatgeek.com/us-open-tennis-tickets',                                          'US Open Tennis')
ON CONFLICT (platform, performer_url) DO NOTHING;


-- ── 2. td_seed_us_open_xref() — promote discovered SH/VD US Open events into
--       pollable xref rows + back-fill aq_event_map platform ids.
--
--    Idempotent. Only touches discoveries that td_match_discovered_to_local()
--    already linked to a local event (matched_tevo_event_id NOT NULL) AND whose
--    tevo_event_id resolves to an aq_event_map row — so a mis-parsed / unmatched
--    discovery is skipped, never guessed. manual_opt_in=true protects the rows
--    from the td_apply_targets deactivation sweep.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.td_seed_us_open_xref()
RETURNS TABLE(platform text, seeded integer, backfilled integer)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $fn$
DECLARE
  v_sh_seed int := 0; v_vd_seed int := 0;
  v_sh_bf   int := 0; v_vd_bf   int := 0;
BEGIN
  -- Candidate = a StubHub/VividSeats US Open discovery, matched to a local event,
  -- that event present in aq_event_map. One row per (marketplace event, aq event).
  WITH cand AS (
    SELECT d.platform,
           CASE d.platform WHEN 'stubhub' THEN 'SH' WHEN 'vividseats' THEN 'VD' END AS xplat,
           d.td_event_id,
           d.event_url,
           aem.aq_short_event_id,
           aem.tevo_event_id
    FROM public.td_discovered_events d
    JOIN public.aq_event_map aem ON aem.tevo_event_id = d.matched_tevo_event_id
    WHERE d.platform IN ('stubhub','vividseats')
      AND d.matched_tevo_event_id IS NOT NULL
      AND d.event_name ILIKE '%US Open%'
      AND d.td_event_id ~ '^[0-9]+$'          -- marketplace ids are numeric
  ),
  -- Back-fill aq_event_map so td_target_events / td_seed_mapped_xref can also see them.
  bf_sh AS (
    UPDATE public.aq_event_map a
    SET sh_event_id = c.td_event_id::bigint
    FROM (SELECT DISTINCT aq_short_event_id, td_event_id FROM cand WHERE xplat='SH') c
    WHERE a.aq_short_event_id = c.aq_short_event_id
      AND a.sh_event_id IS DISTINCT FROM c.td_event_id::bigint
    RETURNING 1
  ),
  bf_vd AS (
    UPDATE public.aq_event_map a
    SET vivid_event_id = c.td_event_id::bigint
    FROM (SELECT DISTINCT aq_short_event_id, td_event_id FROM cand WHERE xplat='VD') c
    WHERE a.aq_short_event_id = c.aq_short_event_id
      AND a.vivid_event_id IS DISTINCT FROM c.td_event_id::bigint
    RETURNING 1
  ),
  -- Upsert pollable xref rows (manual_opt_in — survives the deactivation sweep).
  seed AS (
    INSERT INTO public.ticketsdata_event_xref
      (event_id, platform, aq_short_event_id, event_url, active, always_on,
       manual_opt_in, match_method, updated_at)
    SELECT DISTINCT c.td_event_id::bigint, c.xplat, c.aq_short_event_id, c.event_url,
           true, false, true, 'us_open_discovery', now()
    FROM cand c
    ON CONFLICT (event_id, platform) DO UPDATE
      SET active = true, manual_opt_in = true,
          aq_short_event_id = EXCLUDED.aq_short_event_id,
          event_url = EXCLUDED.event_url, updated_at = now()
    RETURNING platform
  )
  SELECT
    (SELECT count(*) FROM seed  WHERE platform='SH'),
    (SELECT count(*) FROM seed  WHERE platform='VD'),
    (SELECT count(*) FROM bf_sh),
    (SELECT count(*) FROM bf_vd)
  INTO v_sh_seed, v_vd_seed, v_sh_bf, v_vd_bf;

  RETURN QUERY VALUES ('SH', v_sh_seed, v_sh_bf), ('VD', v_vd_seed, v_vd_bf);
END $fn$;

REVOKE ALL ON FUNCTION public.td_seed_us_open_xref() FROM anon, public;

COMMENT ON FUNCTION public.td_seed_us_open_xref() IS
  'Promote StubHub/VividSeats US Open discoveries (td_discovered_events, matched to '
  'a local event) into pollable ticketsdata_event_xref rows (manual_opt_in) + '
  'back-fill aq_event_map.sh_event_id/vivid_event_id. Idempotent. Run AFTER '
  'td_events_discover(''stubhub''/''vividseats'') + drain + td_match_discovered_to_local(). '
  'Mig 20260703130000.';


-- ── OPERATOR RUNBOOK (Applier — spends TD credits; each step is a GET upstream) ──
-- Budget-gate first:   SELECT public.td_budget_ok();     -- must be true
--
-- 1) Fire /events discovery for the US Open targets (1 credit / target / call):
--      SELECT public.td_events_discover('stubhub',    5);
--      SELECT public.td_events_discover('vividseats', 5);
--    -- wait ~30-40s for the pg_net responses, then parse + auto-match to local:
--      SELECT public.td_events_discover_drain();          -- stages td_discovered_events + matches
--      SELECT public.td_match_discovered_to_local();      -- (drain already calls this; safe to re-run)
--
--    Inspect what came back BEFORE seeding (verify the SH/VD /events envelope
--    parsed — its shape is proven for SeatGeek; StubHub/Vivid is newer):
--      SELECT platform, count(*), count(matched_tevo_event_id) matched
--      FROM public.td_discovered_events
--      WHERE event_name ILIKE '%US Open%' GROUP BY 1;
--
-- 2) Promote the matched SH/VD discoveries into pollable xref rows:
--      SELECT * FROM public.td_seed_us_open_xref();       -- returns per-platform seeded/backfilled counts
--
-- 3) Kick an immediate first pull (td_pull_drain fires every minute; or wait for
--    the tiered enqueue crons if enabled — td_tier_enqueue_sh/vd):
--      INSERT INTO public.td_pull_queue (event_id, platform, event_url, interval_tag, created_at)
--      SELECT x.event_id, x.platform, x.event_url, 'us_open_manual_seed', now()
--      FROM public.ticketsdata_event_xref x
--      WHERE x.match_method = 'us_open_discovery' AND x.active AND x.event_url IS NOT NULL
--        AND NOT EXISTS (SELECT 1 FROM public.td_pull_queue q
--                        WHERE q.event_id=x.event_id AND q.platform=x.platform AND q.resolved_at IS NULL);
--
--    Health:   SELECT * FROM public.v_td_poll_health;
--    Seeded:   SELECT platform, count(*) FROM public.ticketsdata_event_xref
--              WHERE match_method='us_open_discovery' GROUP BY 1;
--
-- ROLLBACK: DELETE FROM public.ticketsdata_event_xref WHERE match_method='us_open_discovery';
--           (optionally NULL out the back-filled aq_event_map.sh_event_id/vivid_event_id
--            for those aq rows) + DROP FUNCTION public.td_seed_us_open_xref();
--           + DELETE the 5 td_discover_targets rows added above if desired.

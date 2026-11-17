-- Migration 20261117050000 · level:data-collection · lane:A1 (data plane — mapping program) · writes:axs_export_release_log(new),axs_export_match() fn (release step, match rule, advisory lock),axs_catalog_refresh() fn (advisory lock),axs_title_tokens_contained()(new),axs_market_fallback_match() fn (venue_time rule),axs_event_market_map(one-off withdraw of venue_time pairs the rule refuses),axs_export_event(tevo_event_id released on weak holds) · reads:events,axs_export_event,axs_venue_directory · pre:20261117040000
--
-- MAPPING PROGRAM, BATCH 3 (KANBAN "Mapping program" MAP-8 — AXS). Whole definitions (MIGRATION_CONVENTIONS §6a);
-- the prod bodies of axs_export_match / axs_catalog_refresh carry CRLF line endings — written back with LF here,
-- nothing else outside the marked blocks changed (verified by md5 of the body with the blocks removed).
--
-- MAP-8a · WRONG HOLDS. axs_export_match step 4 takes an EVO event for an AXS event on `n_same_day = 1 OR dmin <= 90
--   OR sim >= 0.3`: when the venue has one EVO event that day, or one within 90 minutes, the title need not fit at
--   all. Where AXS lists several events at a venue on a day, that rule hands the EVO event to whichever AXS row the
--   15-minute cron reaches first — and the one-AXS-id-per-TEvo-event guard then keeps the wrong holder for good.
--   Measured 2026-11-17 on the next 120 days: 39,118 holds, 2,020 with a title fit under 0.3, of which 791 sit beside
--   another live AXS event at the same venue and day (357 venue_date, 434 venue_date_time; 387 have a sibling whose
--   title fits the EVO event at 0.5 or better — e.g. EVO "Clint Black" held by AXS "The Play That Goes Wrong").
--   Two changes:
--     3b. RELEASE: a hold whose title fits under 0.3 while another live AXS event sits at that venue that day is
--         released (logged in axs_export_release_log with the sim and the sibling count), so step 4 can hand the EVO
--         event to the row that fits. A weak hold that is the venue's only AXS event that day is kept (1,229): with
--         nothing to confuse it with, venue + day is the evidence.
--     4.  RULE: a title-less match (sim < 0.3) is taken only when the AXS event is the venue's only one that day;
--         candidates with a fitting title come first in the tie-break. Same shape for the released rows: they are
--         not re-taken by the rule that produced them.
-- MAP-8b · DEADLOCKS. axs_export_match (:04/:19/:34/:49) step 5 upserts axs_catalog while axs_catalog_refresh (:37)
--   upserts the same rows from SeatGeek — 11 deadlocks in 7 days. Both now take pg_advisory_xact_lock(hashtext(
--   'axs_catalog')) before touching the catalogue, so the second waits for the first instead of both dying.
-- MAP-8c · FALLBACK venue_time TIER. axs_market_fallback_match (unscheduled, run by hand) pairs an AXS-primary event
--   with a GoTickets / SeatGeek event by venue name (>= 0.9) and start (<= 15 min) with no title check at all; 12 of
--   the 47 live venue_time pairs are a different show at the same room (Club 90s GLEE NIGHT <> Danity Kane, Charles
--   Zaid <> Morgan Paris Lanza, Blameless <> Jackie Hill Perry). New axs_title_tokens_contained(): the two titles
--   share a significant word (& = and; stopwords and tokens under 3 chars dropped) and at least half of one side's
--   words appear as whole words in the other, or one side has at most three words — symmetric, so "PBR" fits
--   "PBR - Unleash the Beast" and "Shen Yun - Sunday" fits "Shen Yun Performing Arts" (a one-way 60 % rule dropped
--   both). The tier requires it; the 12 live pairs that fail it are withdrawn once here (withdrawn_reason
--   'title_tokens').
-- Nothing upstream is called (RULE 2). Rollback: the release log holds every (axs_event_id, tevo_event_id) released;
--   the previous function bodies are prod's as of 2026-11-17 (20261103190000, 20261102180000, 20261117010000).

BEGIN;
SET LOCAL lock_timeout = '10s';

CREATE TABLE IF NOT EXISTS public.axs_export_release_log (
  id              bigserial PRIMARY KEY,
  at              timestamptz NOT NULL DEFAULT now(),
  axs_event_id    bigint NOT NULL,
  tevo_event_id   bigint NOT NULL,
  match_method    text,
  title_sim       numeric(4,3),
  n_axs_same_day  integer,
  reason          text NOT NULL
);
CREATE INDEX IF NOT EXISTS axs_export_release_log_at_idx ON public.axs_export_release_log (at);
ALTER TABLE public.axs_export_release_log ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.axs_export_release_log FROM anon, authenticated;
GRANT SELECT ON public.axs_export_release_log TO service_role;
COMMENT ON TABLE public.axs_export_release_log IS
  'AXS export -> EVO holds axs_export_match() released: a title fit under 0.3 beside another live AXS event at the venue that day. Mig 20261117050000.';

-- ───────────────────────── axs_export_match ─────────────────────────
CREATE OR REPLACE FUNCTION public.axs_export_match(p_limit integer DEFAULT 100000)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE
  v_venues  int := 0;
  v_vmatch  int := 0;
  v_events  int := 0;
  v_reset   int := 0;
  v_catalog int := 0;
  v_aq_venues    int := 0;
  v_aq_events    int := 0;
  v_aq_written   int := 0;
  v_aq_withdrawn int := 0;
  v_venue_sync   jsonb;
  v_released     int := 0;   -- [batch3]
BEGIN
  -- 1. AXS venues seen in the export
  INSERT INTO public.axs_venue_directory AS d
         (axs_venue_id, venue_name, city, state, country, venue_lat, venue_lon, venue_postal_code,
          venue_address, events_seen, axs_ticketed_seen)
  SELECT x.venue_id::text, max(x.venue_name), max(x.venue_city), max(x.venue_state), max(x.venue_country),
         max(x.venue_lat), max(x.venue_lon), max(x.venue_postal_code), max(x.venue_address),
         count(*), count(*) FILTER (WHERE x.axs_ticketed)
    FROM public.axs_export_event x
   WHERE x.venue_id IS NOT NULL AND x.gone_at IS NULL
   GROUP BY x.venue_id
  ON CONFLICT (axs_venue_id) DO UPDATE SET
    venue_name = EXCLUDED.venue_name, city = EXCLUDED.city, state = EXCLUDED.state,
    country = EXCLUDED.country, venue_lat = EXCLUDED.venue_lat, venue_lon = EXCLUDED.venue_lon,
    venue_postal_code = EXCLUDED.venue_postal_code, venue_address = EXCLUDED.venue_address,
    events_seen = greatest(d.events_seen, EXCLUDED.events_seen),
    axs_ticketed_seen = greatest(d.axs_ticketed_seen, EXCLUDED.axs_ticketed_seen),
    last_seen_at = now();
  GET DIAGNOSTICS v_venues = ROW_COUNT;

  -- 2. unmapped AXS venues → TEvo venue
  WITH todo AS (
    SELECT d.axs_venue_id, d.venue_name, d.state, d.venue_lat, d.venue_lon,
           regexp_replace(regexp_replace(lower(d.venue_name), '^the ', ''), '[^a-z0-9]+', '', 'g') AS norm
      FROM public.axs_venue_directory d
     WHERE d.tevo_venue_id IS NULL AND d.country = 'US'),
  geo AS (
    SELECT DISTINCT ON (t.axs_venue_id) t.axs_venue_id, a.tevo_venue_id,
           round(111320 * sqrt(power(a.latitude - t.venue_lat, 2)
                 + power((a.longitude - t.venue_lon) * cos(radians(t.venue_lat)), 2)))::int AS dist_m,
           similarity(lower(a.venue_name), lower(t.venue_name)) AS sim
      FROM todo t
      JOIN public.venue_assets a
        ON t.venue_lat IS NOT NULL AND a.latitude IS NOT NULL
       AND a.latitude  BETWEEN t.venue_lat - 0.01 AND t.venue_lat + 0.01
       AND a.longitude BETWEEN t.venue_lon - 0.013 AND t.venue_lon + 0.013
     ORDER BY t.axs_venue_id,
              (similarity(lower(a.venue_name), lower(t.venue_name)) >= 0.35) DESC,
              111320 * sqrt(power(a.latitude - t.venue_lat, 2)
                 + power((a.longitude - t.venue_lon) * cos(radians(t.venue_lat)), 2)),
              similarity(lower(a.venue_name), lower(t.venue_name)) DESC),
  geo_ok AS (
    SELECT * FROM geo WHERE (dist_m <= 1000 AND sim >= 0.35) OR dist_m <= 150),
  tv AS (   -- TEvo venues as named on upcoming events, with the state from venue_location
    SELECT DISTINCT e.venue_id,
           regexp_replace(regexp_replace(lower(e.venue_name), '^the ', ''), '[^a-z0-9]+', '', 'g') AS norm,
           upper(btrim(reverse(split_part(reverse(e.venue_location), ',', 1)))) AS state
      FROM public.events e
     WHERE e.occurs_at_local >= to_char(now() - interval '1 day', 'YYYY-MM-DD') AND e.venue_id IS NOT NULL),
  byname AS (
    SELECT t.axs_venue_id, min(tv.venue_id) AS tevo_venue_id
      FROM todo t JOIN tv ON tv.norm = t.norm AND tv.state = upper(t.state)
     WHERE NOT EXISTS (SELECT 1 FROM geo_ok g WHERE g.axs_venue_id = t.axs_venue_id)
     GROUP BY t.axs_venue_id HAVING count(DISTINCT tv.venue_id) = 1),
  pick AS (
    SELECT axs_venue_id, tevo_venue_id, 'geo' AS method, dist_m FROM geo_ok
    UNION ALL
    SELECT axs_venue_id, tevo_venue_id, 'name_state', NULL FROM byname)
  UPDATE public.axs_venue_directory d
     SET tevo_venue_id = p.tevo_venue_id, match_method = p.method, match_distance_m = p.dist_m
    FROM pick p WHERE d.axs_venue_id = p.axs_venue_id;
  GET DIAGNOSTICS v_vmatch = ROW_COUNT;

  -- 3. a matched event whose date moved is matched again
  UPDATE public.axs_export_event x
     SET tevo_event_id = NULL, tevo_venue_id = NULL, match_method = NULL, matched_date = NULL, matched_at = NULL
   WHERE x.tevo_event_id IS NOT NULL AND x.matched_date IS DISTINCT FROM x.event_date_local;
  GET DIAGNOSTICS v_reset = ROW_COUNT;

  -- [batch3 begin]
  -- 3b. a hold whose title does not fit (sim < 0.3) while another live AXS event sits at that venue that day is
  --     released: venue + day alone cannot tell the two apart, and the one-id-per-EVO-event guard would otherwise
  --     keep the wrong holder for good. Logged; step 4 may hand the EVO event to the row that fits.
  WITH live AS (
    SELECT x.venue_id, left(x.event_date_local, 10) AS d, count(*) AS n
      FROM public.axs_export_event x
     WHERE x.gone_at IS NULL AND x.venue_country = 'US' AND x.event_date_local >= to_char(now(), 'YYYY-MM-DD')
     GROUP BY 1, 2),
  weak AS (
    SELECT x.axs_event_id, x.tevo_event_id, x.match_method, l.n,
           similarity(lower(coalesce(e.primary_performer_name, '') || ' ' || coalesce(e.name, '')),
                      lower(coalesce(x.event_title_clean, x.event_title))) AS sim
      FROM public.axs_export_event x
      JOIN live l ON l.venue_id = x.venue_id AND l.d = left(x.event_date_local, 10) AND l.n > 1
      JOIN public.events e ON e.id = x.tevo_event_id
     WHERE x.tevo_event_id IS NOT NULL AND x.gone_at IS NULL AND x.venue_country = 'US'
       AND x.event_date_local >= to_char(now(), 'YYYY-MM-DD')),
  rel AS (
    UPDATE public.axs_export_event x
       SET tevo_event_id = NULL, tevo_venue_id = NULL, match_method = NULL, matched_date = NULL, matched_at = NULL
      FROM weak w
     WHERE w.axs_event_id = x.axs_event_id AND w.sim < 0.3
    RETURNING x.axs_event_id, w.tevo_event_id, w.match_method, w.sim, w.n)
  INSERT INTO public.axs_export_release_log (axs_event_id, tevo_event_id, match_method, title_sim, n_axs_same_day, reason)
  SELECT r.axs_event_id, r.tevo_event_id, r.match_method, round(r.sim::numeric, 3), r.n, 'weak_title_sibling_axs' FROM rel r;
  GET DIAGNOSTICS v_released = ROW_COUNT;
  -- [batch3 end]

  -- 4. AXS events → TEvo events: same mapped venue, same local date; time then title break ties
  WITH live AS (   -- [batch3] live AXS events per venue and day
    SELECT x.venue_id, left(x.event_date_local, 10) AS d, count(*) AS n
      FROM public.axs_export_event x
     WHERE x.gone_at IS NULL AND x.venue_country = 'US' AND x.event_date_local >= to_char(now(), 'YYYY-MM-DD')
     GROUP BY 1, 2),
  todo AS (
    SELECT x.axs_event_id, x.event_date_local, x.is_tba,
           coalesce(x.event_title_clean, x.event_title) AS title, d.tevo_venue_id,
           l.n AS n_axs_same_day   -- [batch3]
      FROM public.axs_export_event x
      JOIN public.axs_venue_directory d ON d.axs_venue_id = x.venue_id::text AND d.tevo_venue_id IS NOT NULL
      JOIN live l ON l.venue_id = x.venue_id AND l.d = left(x.event_date_local, 10)   -- [batch3]
     WHERE x.tevo_event_id IS NULL AND x.gone_at IS NULL AND x.venue_country = 'US'
       AND x.event_date_local >= to_char(now(), 'YYYY-MM-DD')
     ORDER BY x.event_date_local
     LIMIT greatest(p_limit, 0)),
  cand AS (
    SELECT t.axs_event_id, t.event_date_local, e.id AS tevo_event_id, t.tevo_venue_id, t.n_axs_same_day,
           count(*) OVER (PARTITION BY t.axs_event_id) AS n_same_day,
           CASE WHEN t.is_tba OR substr(e.occurs_at_local, 12, 5) !~ '^\d\d:\d\d$' THEN 0
                ELSE abs(extract(epoch FROM (substr(e.occurs_at_local, 12, 5)::time
                                             - substr(t.event_date_local, 12, 5)::time)) / 60) END AS dmin,
           similarity(lower(coalesce(e.primary_performer_name, '') || ' ' || coalesce(e.name, '')), lower(t.title)) AS sim
      FROM todo t
      JOIN public.events e ON e.venue_id = t.tevo_venue_id AND left(e.occurs_at_local, 10) = left(t.event_date_local, 10)
     WHERE coalesce(e.state, 'shown') <> 'ignored'),
  best_per_axs AS (   -- [batch3] a title-less match only when the AXS event is the venue's only one that day; fitting titles first
    SELECT DISTINCT ON (axs_event_id) * FROM cand
     WHERE sim >= 0.3 OR (n_axs_same_day = 1 AND (n_same_day = 1 OR dmin <= 90))
     ORDER BY axs_event_id, (sim >= 0.3) DESC, dmin, sim DESC),
  best_per_tevo AS (   -- one AXS id per TEvo event, not already taken by another AXS id
    SELECT DISTINCT ON (b.tevo_event_id) b.*
      FROM best_per_axs b
     WHERE NOT EXISTS (SELECT 1 FROM public.axs_export_event o
                        WHERE o.tevo_event_id = b.tevo_event_id AND o.axs_event_id <> b.axs_event_id)
     ORDER BY b.tevo_event_id, b.sim DESC, b.dmin, b.axs_event_id)
  UPDATE public.axs_export_event x
     SET tevo_event_id = b.tevo_event_id, tevo_venue_id = b.tevo_venue_id,
         match_method = CASE WHEN b.n_same_day = 1 THEN 'venue_date' ELSE 'venue_date_time' END,
         matched_date = b.event_date_local, matched_at = now()
    FROM best_per_tevo b WHERE x.axs_event_id = b.axs_event_id;
  GET DIAGNOSTICS v_events = ROW_COUNT;

  -- 4b. AXS → AQ directly (no TEvo)
  --   (i) withdraw unpinned pairings whose AXS event moved off the AQ date or left AXS unplayed
  WITH moved AS (
    DELETE FROM public.axs_aq_event_xref p
     USING public.axs_export_event x, public.aq_event_map m
     WHERE p.axs_event_id = x.axs_event_id AND m.aq_short_event_id = p.aq_short_event_id
       AND NOT p.pinned
       AND (NOT public.axs_aq_time_ok(m.event_date, x.event_date_local)
            OR (x.gone_at IS NOT NULL AND x.event_date_local >= to_char(now(), 'YYYY-MM-DD')))
    RETURNING p.axs_event_id, p.aq_short_event_id)
  UPDATE public.aq_event_map m SET axs_event_id = NULL
    FROM moved v
   WHERE m.aq_short_event_id = v.aq_short_event_id AND m.axs_event_id = v.axs_event_id::text;
  GET DIAGNOSTICS v_aq_withdrawn = ROW_COUNT;

  --   (ii) AXS venue → AQ venue: aq_venue_map.axs_venue_id (axs_aq_venue_sync)
  v_venue_sync := public.axs_aq_venue_sync(true);
  v_aq_venues := coalesce((v_venue_sync->>'mapped_existing')::int, 0) + coalesce((v_venue_sync->>'attached_same_id')::int, 0)
               + coalesce((v_venue_sync->>'minted')::int, 0);

  --   (iii) AXS event → AQ event: the same tiers match_to_aq_event_id uses for EVO
  v_aq_events := coalesce((public.axs_aq_tier_match(greatest(p_limit, 0))->>'paired')::int, 0);

  --   (iv) write to aq_event_map: fill when empty (pinned pairings override); record conflicts
  UPDATE public.axs_aq_event_xref p SET conflict_axs_event_id = m.axs_event_id
    FROM public.aq_event_map m
   WHERE m.aq_short_event_id = p.aq_short_event_id AND NOT p.pinned
     AND m.axs_event_id IS NOT NULL AND m.axs_event_id <> p.axs_event_id::text
     AND p.conflict_axs_event_id IS DISTINCT FROM m.axs_event_id;
  UPDATE public.axs_aq_event_xref p SET axs_id_held_by = o.aq_short_event_id
    FROM public.aq_event_map o
   WHERE o.axs_event_id = p.axs_event_id::text AND o.aq_short_event_id <> p.aq_short_event_id
     AND NOT p.pinned AND p.axs_id_held_by IS DISTINCT FROM o.aq_short_event_id;
  UPDATE public.aq_event_map m SET axs_event_id = p.axs_event_id::text
    FROM public.axs_aq_event_xref p
   WHERE m.aq_short_event_id = p.aq_short_event_id
     AND m.axs_event_id IS DISTINCT FROM p.axs_event_id::text
     AND (m.axs_event_id IS NULL OR p.pinned)
     AND NOT EXISTS (SELECT 1 FROM public.aq_event_map o
                      WHERE o.axs_event_id = p.axs_event_id::text AND o.aq_short_event_id <> m.aq_short_event_id);
  GET DIAGNOSTICS v_aq_written = ROW_COUNT;

  -- 5. catalogue feed (every live US upcoming export event)
  PERFORM pg_advisory_xact_lock(hashtext('axs_catalog'));   -- [batch3] axs_catalog_refresh takes the same lock
  INSERT INTO public.axs_catalog AS c
         (axs_event_id, event_url, source, tevo_event_id, event_name, venue_name, event_date,
          axs_ticketed, axs_venue_id)
  SELECT x.axs_event_id::text, coalesce(x.event_url, 'https://www.axs.com/events/' || x.axs_event_id),
         'axs_export', x.tevo_event_id, x.event_title, x.venue_name,
         left(x.event_date_local, 10)::date, x.axs_ticketed, x.venue_id::text
    FROM public.axs_export_event x
   WHERE x.gone_at IS NULL AND x.venue_country = 'US'
     AND x.event_date_local ~ '^\d{4}-\d\d-\d\d' AND x.event_date_local >= to_char(now(), 'YYYY-MM-DD')
  ON CONFLICT (axs_event_id) DO UPDATE SET
    tevo_event_id = CASE WHEN c.source = 'axs_export' THEN EXCLUDED.tevo_event_id
                         ELSE coalesce(EXCLUDED.tevo_event_id, c.tevo_event_id) END,
    axs_ticketed  = EXCLUDED.axs_ticketed,
    axs_venue_id  = coalesce(EXCLUDED.axs_venue_id, c.axs_venue_id),
    event_date    = EXCLUDED.event_date,
    event_name    = coalesce(c.event_name, EXCLUDED.event_name),
    venue_name    = coalesce(c.venue_name, EXCLUDED.venue_name),
    last_seen_at  = now();
  GET DIAGNOSTICS v_catalog = ROW_COUNT;

  -- export-sourced catalogue rows whose event left AXS (or was played) go
  DELETE FROM public.axs_catalog c
   WHERE c.source = 'axs_export'
     AND NOT EXISTS (SELECT 1 FROM public.axs_export_event x
                      WHERE x.axs_event_id::text = c.axs_event_id AND x.gone_at IS NULL);

  RETURN jsonb_build_object('venues_seen', v_venues, 'venues_mapped_now', v_vmatch,
                            'events_rematched', v_reset, 'events_matched_now', v_events,
                            'events_released', v_released,   -- [batch3]
                            'aq_venues_mapped_now', v_aq_venues, 'aq_pairs_new', v_aq_events,
                            'aq_ids_written', v_aq_written, 'aq_pairs_withdrawn', v_aq_withdrawn,
                            'catalog_rows', v_catalog);
END $function$;

-- ───────────────────────── axs_catalog_refresh ─────────────────────────
CREATE OR REPLACE FUNCTION public.axs_catalog_refresh(p_signal_window interval DEFAULT '24 hours'::interval)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE
  v_sg       int;
  v_hand     int;
  v_signal   int;
  v_enrolled int;
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('axs_catalog'));   -- [batch3] axs_export_match step 5 takes the same lock
  -- 1. SeatGeek: integrated.provider_id is the AXS event id (trailing digits of the long form)
  INSERT INTO public.axs_catalog AS c
         (axs_event_id, event_url, source, sg_event_id, tevo_event_id, event_name, venue_name, event_date)
  SELECT DISTINCT ON (s.axs_id)
         s.axs_id, 'https://www.axs.com/events/' || s.axs_id, 'seatgeek_integrated',
         s.sg_event_id, s.tevo_event_id, s.sg_event_name, s.sg_venue_name, s.sg_event_date::date
    FROM (SELECT substring(g.raw_event_jsonb->'integrated'->>'provider_id' FROM '(\d+)$') AS axs_id,
                 g.sg_event_id, g.tevo_event_id, g.sg_event_name, g.sg_venue_name, g.sg_event_date, g.updated_at
            FROM public.sg_events_canonical g
           WHERE g.raw_event_jsonb->'integrated'->>'provider_name' = 'AXS'
             AND coalesce(g.raw_event_jsonb->'venue'->>'country', 'US') = 'US') s
   WHERE s.axs_id IS NOT NULL
   ORDER BY s.axs_id, s.updated_at DESC NULLS LAST
  ON CONFLICT (axs_event_id) DO UPDATE
     SET sg_event_id   = EXCLUDED.sg_event_id,
         tevo_event_id = coalesce(EXCLUDED.tevo_event_id, c.tevo_event_id),
         event_name    = coalesce(EXCLUDED.event_name, c.event_name),
         venue_name    = coalesce(EXCLUDED.venue_name, c.venue_name),
         event_date    = coalesce(EXCLUDED.event_date, c.event_date),
         last_seen_at  = now();
  GET DIAGNOSTICS v_sg = ROW_COUNT;

  -- 2. the hand-entered list, so the catalogue is the one place to look
  INSERT INTO public.axs_catalog AS c (axs_event_id, event_url, source, tevo_event_id, event_name, venue_name, event_date, enrolled_at)
  SELECT a.axs_event_id, a.event_url, 'axs_events', a.tevo_event_id, e.name, e.venue_name,
         CASE WHEN e.occurs_at_local ~ '^\d{4}-\d\d-\d\d' THEN left(e.occurs_at_local, 10)::date END,
         a.created_at
    FROM public.axs_events a
    LEFT JOIN public.events e ON e.id = a.tevo_event_id
   WHERE e.id IS NULL OR public.axs_is_us_location(e.venue_location)
  ON CONFLICT (axs_event_id) DO UPDATE
     SET tevo_event_id = coalesce(c.tevo_event_id, EXCLUDED.tevo_event_id),
         enrolled_at   = coalesce(c.enrolled_at, EXCLUDED.enrolled_at),
         last_seen_at  = now();
  GET DIAGNOSTICS v_hand = ROW_COUNT;

  -- 3. delivery-type signal over the last window (captured_at-indexed on both tables)
  WITH gt AS (
    SELECT tevo_event_id, count(*) n, count(*) FILTER (WHERE stock_type = 'AXS_TRANSFER') axs
      FROM public.gotickets_listings_snapshots
     WHERE captured_at > now() - p_signal_window AND tevo_event_id IS NOT NULL
     GROUP BY 1),
  evo AS (
    SELECT event_id AS tevo_event_id, count(*) n, count(*) FILTER (WHERE format = 'Flash_seats') axs
      FROM public.listings_snapshots
     WHERE captured_at > now() - p_signal_window
     GROUP BY 1)
  INSERT INTO public.axs_primary_signal AS p
         (tevo_event_id, gt_rows, gt_axs_rows, evo_rows, evo_flash_rows, axs_share, computed_at)
  SELECT coalesce(gt.tevo_event_id, evo.tevo_event_id),
         coalesce(gt.n, 0), coalesce(gt.axs, 0), coalesce(evo.n, 0), coalesce(evo.axs, 0),
         round((coalesce(gt.axs, 0) + coalesce(evo.axs, 0))::numeric
               / nullif(coalesce(gt.n, 0) + coalesce(evo.n, 0), 0), 3),
         now()
    FROM gt FULL JOIN evo ON evo.tevo_event_id = gt.tevo_event_id
  ON CONFLICT (tevo_event_id) DO UPDATE
     SET gt_rows = EXCLUDED.gt_rows, gt_axs_rows = EXCLUDED.gt_axs_rows,
         evo_rows = EXCLUDED.evo_rows, evo_flash_rows = EXCLUDED.evo_flash_rows,
         axs_share = EXCLUDED.axs_share, computed_at = EXCLUDED.computed_at;
  GET DIAGNOSTICS v_signal = ROW_COUNT;

  -- 4. enrol new upcoming SeatGeek-sourced AXS events into the AXS pull list
  WITH ins AS (
    INSERT INTO public.axs_events (axs_event_id, event_url, source_sheets, tevo_event_id, active, is_axs_primary)
    SELECT c.axs_event_id, c.event_url, 'catalog:seatgeek', c.tevo_event_id, true, true
      FROM public.axs_catalog c
     WHERE c.source = 'seatgeek_integrated'
       AND c.event_date >= current_date
       AND NOT EXISTS (SELECT 1 FROM public.axs_events a WHERE a.axs_event_id = c.axs_event_id)
    ON CONFLICT (axs_event_id) DO NOTHING
    RETURNING axs_event_id)
  UPDATE public.axs_catalog c SET enrolled_at = now()
    FROM ins WHERE c.axs_event_id = ins.axs_event_id;
  GET DIAGNOSTICS v_enrolled = ROW_COUNT;

  RETURN jsonb_build_object('seatgeek_rows', v_sg, 'axs_events_rows', v_hand,
                            'signal_rows', v_signal, 'enrolled', v_enrolled);
END $function$;

-- ───────────────────────── the fallback's title rule ─────────────────────────
-- Do at least 60 % of the market title's significant words appear, as whole words, in the AXS title + headliner?
CREATE OR REPLACE FUNCTION public.axs_title_tokens_contained(p_market_title text, p_axs_title text)
 RETURNS boolean
 LANGUAGE sql
 IMMUTABLE
AS $function$
  WITH s AS (
    SELECT ' ' || regexp_replace(lower(replace(coalesce(p_market_title, ''), '&', ' and ')), '[^a-z0-9]+', ' ', 'g') || ' ' AS ms,
           ' ' || regexp_replace(lower(replace(coalesce(p_axs_title, ''),    '&', ' and ')), '[^a-z0-9]+', ' ', 'g') || ' ' AS xs),
  stop AS (SELECT unnest(ARRAY['the', 'and', 'with', 'live', 'tour', 'presents', 'feat', 'featuring', 'show', 'concert', 'night', 'party', 'vs', '2026', '2027']) AS w),
  tm AS (SELECT DISTINCT t FROM s, regexp_split_to_table(btrim(s.ms), ' ') t WHERE length(t) >= 3 AND t NOT IN (SELECT w FROM stop)),
  tx AS (SELECT DISTINCT t FROM s, regexp_split_to_table(btrim(s.xs), ' ') t WHERE length(t) >= 3 AND t NOT IN (SELECT w FROM stop)),
  c AS (
    SELECT (SELECT count(*) FROM tm) AS nm, (SELECT count(*) FROM tx) AS nx,
           (SELECT count(*) FROM tm, s WHERE position(' ' || tm.t || ' ' IN s.xs) > 0) AS m_in_x,
           (SELECT count(*) FROM tx, s WHERE position(' ' || tx.t || ' ' IN s.ms) > 0) AS x_in_m)
  SELECT c.m_in_x >= 1
     AND (c.m_in_x >= ceil(0.5 * c.nm) OR c.x_in_m >= ceil(0.5 * c.nx) OR least(c.nm, c.nx) <= 3)
    FROM c;
$function$;
COMMENT ON FUNCTION public.axs_title_tokens_contained(text, text) IS
  'The market event title and the AXS title + headliner share a significant word (& = and; stopwords and tokens under 3 chars dropped), and at least half of one side''s words appear as whole words in the other, or one side has at most 3 words. The venue_time tier of axs_market_fallback_match requires it. Mig 20261117050000.';
REVOKE ALL ON FUNCTION public.axs_title_tokens_contained(text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.axs_title_tokens_contained(text, text) TO service_role;

-- ───────────────────────── axs_market_fallback_match ─────────────────────────
CREATE OR REPLACE FUNCTION public.axs_market_fallback_match(p_limit integer DEFAULT 100000)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE
  v_w_evo int := 0; v_w_gone int := 0; v_w_gt int := 0; v_w_sg int := 0;
  v_gt int := 0; v_sg int := 0; v_todo int := 0;
BEGIN
  -- 1. withdraw what no longer holds
  UPDATE public.axs_event_market_map m
     SET withdrawn_at = now(), withdrawn_reason = 'evo_matched'
    FROM public.axs_export_event x
   WHERE x.axs_event_id = m.axs_event_id AND m.withdrawn_at IS NULL AND x.tevo_event_id IS NOT NULL;
  GET DIAGNOSTICS v_w_evo = ROW_COUNT;
  UPDATE public.axs_event_market_map m
     SET withdrawn_at = now(), withdrawn_reason = 'axs_event_gone'
   WHERE m.withdrawn_at IS NULL
     AND NOT EXISTS (SELECT 1 FROM public.axs_export_event x
                      WHERE x.axs_event_id = m.axs_event_id AND x.gone_at IS NULL AND x.type = 'axs_primary');
  GET DIAGNOSTICS v_w_gone = ROW_COUNT;
  UPDATE public.axs_event_market_map m
     SET withdrawn_at = now(), withdrawn_reason = 'market_event_changed'
    FROM public.axs_export_event x
   WHERE x.axs_event_id = m.axs_event_id AND m.withdrawn_at IS NULL AND m.market = 'gotickets'
     AND NOT EXISTS (SELECT 1 FROM public.gotickets_event g
                      WHERE g.gt_event_id = m.market_event_id AND g.status = 'AS_SCHEDULED'
                        AND g.event_time_utc BETWEEN x.event_date_utc - interval '90 minutes'
                                                 AND x.event_date_utc + interval '90 minutes');
  GET DIAGNOSTICS v_w_gt = ROW_COUNT;
  UPDATE public.axs_event_market_map m
     SET withdrawn_at = now(), withdrawn_reason = 'market_event_changed'
    FROM public.axs_export_event x
   WHERE x.axs_event_id = m.axs_event_id AND m.withdrawn_at IS NULL AND m.market = 'seatgeek'
     AND NOT EXISTS (SELECT 1 FROM public.sg_events_canonical s
                      WHERE s.sg_event_id = m.market_event_id
                        AND s.sg_datetime_utc BETWEEN x.event_date_utc - interval '90 minutes'
                                                  AND x.event_date_utc + interval '90 minutes');
  GET DIAGNOSTICS v_w_sg = ROW_COUNT;

  -- 2. what is to be matched: AXS-primary, upcoming, US, no EVO event, no pairing in force
  SELECT count(*) INTO v_todo FROM (
    SELECT 1 FROM public.axs_export_event x
     WHERE x.type = 'axs_primary' AND x.gone_at IS NULL AND x.venue_country = 'US'
       AND x.event_date_utc >= now() AND x.tevo_event_id IS NULL
       AND x.venue_city IS NOT NULL AND x.venue_state IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM public.axs_event_market_map m
                        WHERE m.axs_event_id = x.axs_event_id AND m.withdrawn_at IS NULL)
     LIMIT greatest(p_limit, 0)) q;

  -- 3. GoTickets: its events in those cities, parking listings left out
  WITH ax AS MATERIALIZED (
    SELECT x.axs_event_id, lower(btrim(x.venue_name)) AS venue, lower(btrim(x.venue_city)) AS city,
           upper(btrim(x.venue_state)) AS st, x.event_date_utc AS t,
           lower(coalesce(x.event_title_clean, x.event_title, '')) AS title, lower(coalesce(x.headliner, '')) AS head
      FROM public.axs_export_event x
     WHERE x.type = 'axs_primary' AND x.gone_at IS NULL AND x.venue_country = 'US'
       AND x.event_date_utc >= now() AND x.tevo_event_id IS NULL
       AND x.venue_city IS NOT NULL AND x.venue_state IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM public.axs_event_market_map m
                        WHERE m.axs_event_id = x.axs_event_id AND m.withdrawn_at IS NULL)
     ORDER BY x.event_date_utc
     LIMIT greatest(p_limit, 0)),
  mk AS MATERIALIZED (
    SELECT g.gt_event_id AS id, g.name, g.venue_name, g.event_time_utc AS t,
           lower(btrim(g.venue_name)) AS venue, lower(btrim(g.venue_city)) AS city, upper(btrim(g.venue_state)) AS st,
           lower(coalesce(g.name, '')) AS title, lower(coalesce(g.performer, '')) AS head
      FROM public.gotickets_event g
     WHERE g.event_time_utc >= now() - interval '2 hours' AND g.status = 'AS_SCHEDULED'
       AND (lower(btrim(g.venue_city)), upper(btrim(g.venue_state))) IN (SELECT DISTINCT a.city, a.st FROM ax a)
       AND coalesce(g.name, '') !~* '\mparking\M' AND coalesce(g.venue_name, '') !~* '\mparking\M'
       AND NOT EXISTS (SELECT 1 FROM public.axs_event_market_map m
                        WHERE m.market = 'gotickets' AND m.market_event_id = g.gt_event_id AND m.withdrawn_at IS NULL)),
  c AS (
    SELECT a.axs_event_id, k.id, k.name, k.venue_name,
           round(abs(extract(epoch FROM k.t - a.t)) / 60)::int AS dmin,
           similarity(k.venue, a.venue) AS vsim,
           greatest(similarity(k.title, a.title),
                    CASE WHEN a.head <> '' AND k.head <> '' THEN similarity(k.head, a.head) ELSE 0 END) AS tsim,
           public.axs_title_tokens_contained(k.title, a.title || ' ' || a.head) AS tokens_ok   -- [batch3]
      FROM ax a JOIN mk k ON k.city = a.city AND k.st = a.st
       AND k.t BETWEEN a.t - interval '90 minutes' AND a.t + interval '90 minutes'),
  r AS (
    SELECT c.*, count(*) FILTER (WHERE c.vsim >= 0.9) OVER (PARTITION BY c.axs_event_id) AS n_venue,
           CASE WHEN c.vsim >= 0.5 AND c.tsim >= 0.3 THEN 'venue_title'
                WHEN c.tsim >= 0.6 THEN 'title_city'
                WHEN c.vsim >= 0.9 AND c.dmin <= 15 THEN 'venue_time' END AS method
      FROM c),
  ok AS (SELECT * FROM r WHERE method IN ('venue_title', 'title_city') OR (method = 'venue_time' AND n_venue = 1 AND tokens_ok)),   -- [batch3]
  b1 AS (SELECT DISTINCT ON (axs_event_id) * FROM ok
          ORDER BY axs_event_id, (method = 'venue_title') DESC, (method = 'title_city') DESC, tsim DESC, vsim DESC, dmin, id),
  b2 AS (SELECT DISTINCT ON (id) * FROM b1
          ORDER BY id, (method = 'venue_title') DESC, (method = 'title_city') DESC, tsim DESC, vsim DESC, dmin, axs_event_id)
  INSERT INTO public.axs_event_market_map AS m
         (axs_event_id, market, market_event_id, method, venue_sim, title_sim, time_diff_min, market_event_name, market_venue_name)
  SELECT axs_event_id, 'gotickets', id, method, round(vsim::numeric, 3), round(tsim::numeric, 3), dmin, name, venue_name FROM b2
  ON CONFLICT (axs_event_id) DO UPDATE SET
    market = EXCLUDED.market, market_event_id = EXCLUDED.market_event_id, method = EXCLUDED.method,
    venue_sim = EXCLUDED.venue_sim, title_sim = EXCLUDED.title_sim, time_diff_min = EXCLUDED.time_diff_min,
    market_event_name = EXCLUDED.market_event_name, market_venue_name = EXCLUDED.market_venue_name,
    matched_at = now(), withdrawn_at = NULL, withdrawn_reason = NULL
   WHERE m.withdrawn_at IS NOT NULL;
  GET DIAGNOSTICS v_gt = ROW_COUNT;

  -- 4. SeatGeek, for what GoTickets did not match (the same list, now without those just paired)
  WITH ax AS MATERIALIZED (
    SELECT x.axs_event_id, lower(btrim(x.venue_name)) AS venue, lower(btrim(x.venue_city)) AS city,
           upper(btrim(x.venue_state)) AS st, x.event_date_utc AS t,
           lower(coalesce(x.event_title_clean, x.event_title, '')) AS title, lower(coalesce(x.headliner, '')) AS head
      FROM public.axs_export_event x
     WHERE x.type = 'axs_primary' AND x.gone_at IS NULL AND x.venue_country = 'US'
       AND x.event_date_utc >= now() AND x.tevo_event_id IS NULL
       AND x.venue_city IS NOT NULL AND x.venue_state IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM public.axs_event_market_map m
                        WHERE m.axs_event_id = x.axs_event_id AND m.withdrawn_at IS NULL)
     ORDER BY x.event_date_utc
     LIMIT greatest(p_limit, 0)),
  mk AS MATERIALIZED (
    SELECT s.sg_event_id AS id, s.sg_event_name AS name, s.sg_venue_name AS venue_name, s.sg_datetime_utc AS t,
           lower(btrim(s.sg_venue_name)) AS venue, lower(btrim(s.sg_venue_city)) AS city, upper(btrim(s.sg_venue_state)) AS st,
           lower(coalesce(s.sg_event_name, '')) AS title, lower(coalesce(s.sg_event_name, '')) AS head
      FROM public.sg_events_canonical s
     WHERE s.sg_datetime_utc >= now() - interval '2 hours'
       AND (lower(btrim(s.sg_venue_city)), upper(btrim(s.sg_venue_state))) IN (SELECT DISTINCT a.city, a.st FROM ax a)
       AND coalesce(s.sg_event_name, '') !~* '\mparking\M' AND coalesce(s.sg_venue_name, '') !~* '\mparking\M'
       AND NOT EXISTS (SELECT 1 FROM public.axs_event_market_map m
                        WHERE m.market = 'seatgeek' AND m.market_event_id = s.sg_event_id AND m.withdrawn_at IS NULL)),
  c AS (
    SELECT a.axs_event_id, k.id, k.name, k.venue_name,
           round(abs(extract(epoch FROM k.t - a.t)) / 60)::int AS dmin,
           similarity(k.venue, a.venue) AS vsim,
           greatest(similarity(k.title, a.title),
                    CASE WHEN a.head <> '' AND k.head <> '' THEN similarity(k.head, a.head) ELSE 0 END) AS tsim,
           public.axs_title_tokens_contained(k.title, a.title || ' ' || a.head) AS tokens_ok   -- [batch3]
      FROM ax a JOIN mk k ON k.city = a.city AND k.st = a.st
       AND k.t BETWEEN a.t - interval '90 minutes' AND a.t + interval '90 minutes'),
  r AS (
    SELECT c.*, count(*) FILTER (WHERE c.vsim >= 0.9) OVER (PARTITION BY c.axs_event_id) AS n_venue,
           CASE WHEN c.vsim >= 0.5 AND c.tsim >= 0.3 THEN 'venue_title'
                WHEN c.tsim >= 0.6 THEN 'title_city'
                WHEN c.vsim >= 0.9 AND c.dmin <= 15 THEN 'venue_time' END AS method
      FROM c),
  ok AS (SELECT * FROM r WHERE method IN ('venue_title', 'title_city') OR (method = 'venue_time' AND n_venue = 1 AND tokens_ok)),   -- [batch3]
  b1 AS (SELECT DISTINCT ON (axs_event_id) * FROM ok
          ORDER BY axs_event_id, (method = 'venue_title') DESC, (method = 'title_city') DESC, tsim DESC, vsim DESC, dmin, id),
  b2 AS (SELECT DISTINCT ON (id) * FROM b1
          ORDER BY id, (method = 'venue_title') DESC, (method = 'title_city') DESC, tsim DESC, vsim DESC, dmin, axs_event_id)
  INSERT INTO public.axs_event_market_map AS m
         (axs_event_id, market, market_event_id, method, venue_sim, title_sim, time_diff_min, market_event_name, market_venue_name)
  SELECT axs_event_id, 'seatgeek', id, method, round(vsim::numeric, 3), round(tsim::numeric, 3), dmin, name, venue_name FROM b2
  ON CONFLICT (axs_event_id) DO UPDATE SET
    market = EXCLUDED.market, market_event_id = EXCLUDED.market_event_id, method = EXCLUDED.method,
    venue_sim = EXCLUDED.venue_sim, title_sim = EXCLUDED.title_sim, time_diff_min = EXCLUDED.time_diff_min,
    market_event_name = EXCLUDED.market_event_name, market_venue_name = EXCLUDED.market_venue_name,
    matched_at = now(), withdrawn_at = NULL, withdrawn_reason = NULL
   WHERE m.withdrawn_at IS NOT NULL;
  GET DIAGNOSTICS v_sg = ROW_COUNT;

  RETURN jsonb_build_object(
    'looked_at', v_todo, 'gotickets_matched', v_gt, 'seatgeek_matched', v_sg,
    'left_unmatched', v_todo - v_gt - v_sg,
    'withdrawn', jsonb_build_object('evo_matched', v_w_evo, 'axs_event_gone', v_w_gone,
                                    'gotickets_event_changed', v_w_gt, 'seatgeek_event_changed', v_w_sg));
END $function$;

-- one-off: the live venue_time pairs the title rule refuses are withdrawn (12 of 47 on 2026-11-17)
UPDATE public.axs_event_market_map m
   SET withdrawn_at = now(), withdrawn_reason = 'title_tokens'
  FROM public.axs_export_event x
 WHERE x.axs_event_id = m.axs_event_id AND m.withdrawn_at IS NULL AND m.method = 'venue_time'
   AND NOT public.axs_title_tokens_contained(m.market_event_name,
                                             coalesce(x.event_title_clean, x.event_title, '') || ' ' || coalesce(x.headliner, ''));

COMMIT;

-- VERIFY:
--   SELECT reason, match_method, count(*) FROM axs_export_release_log GROUP BY 1,2;      -- after the first :04/:19/… run
--   SELECT withdrawn_reason, count(*) FROM axs_event_market_map WHERE withdrawn_at > now() - interval '1 hour' GROUP BY 1;
--   deadlocks: SELECT count(*) FROM cron.job_run_details WHERE jobid IN (SELECT jobid FROM cron.job WHERE jobname IN ('axs_export_match_15m','axs_catalog_refresh_hourly'))
--              AND status='failed' AND return_message ILIKE '%deadlock%' AND start_time > now();

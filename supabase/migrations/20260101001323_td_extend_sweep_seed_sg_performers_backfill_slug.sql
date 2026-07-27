-- Migration 20260704180055 · lane:A1 (data plane — TicketsData /match sweep reach)
--   writes (DDL): td_sg_discover_drain() [CREATE OR REPLACE — backfill sg_url on conflict],
--                 sg_match_map_tick() [CREATE OR REPLACE — skip parking candidates];
--                 reschedule cron 'td_sg_discover_daily' (limit 5 → 40)
--   writes on run: td_sg_performers (seed SeatGeek performers of mapped url-less events),
--                  td_sg_performers.last_discovered_at (re-arm active set),
--                  fires one td_sg_discover(40) batch now
--   reads: aq_event_map, sg_events_canonical, aq_performer_map
--   pre: 20260703144000 (td_apply_targets SH fix), 20260703133000 (td_sg_discover_drain sg_url),
--        20260629170000 (sg_match_map_tick prioritize owned/axs)
--   auth: operator directive 2026-07-04 (julian@s4kent.com — "keep the designs but
--         extend to more mapped events")
--
-- ## Applied to prod 2026-07-04 via MCP (idempotent + reversible). Codification.
--
-- WHY ────────────────────────────────────────────────────────────────────────
-- The probe-once /match sweep (sg_match_map_tick) resolves sh/vivid/tm/gt/tp for
-- an event by calling ticketsdata.com/match with the event's SeatGeek slug URL
-- (sgc.sg_url). Of ~5,300 mapped upcoming events, only ~370 carry a real sg_url —
-- so the sweep can only reach those. The other ~2,650 mapped events have canonical
-- rows minted by internal matchers (matcher_v3, aq_event_map_seed, tevo autotrack,
-- auto_canonical_loop) that never stored a SeatGeek payload: sg_url is NULL, the id
-- is not sluggable ('/e/events/<id>' → 500 "Could not resolve performer cluster"),
-- raw_event_jsonb is empty, and our broker SG token doesn't grant the public
-- api.seatgeek.com/2 where slugs live. The ONLY source of a slug is a TicketsData
-- /events discovery pull (td_sg_discover → _drain), which harvests item.url.
--
-- Two blockers kept discovery from reaching these events. Both fixed here, in-design
-- (no new machinery — the discover/drain crons already run daily):
--
--   1. td_sg_discover_drain() inserted discovered rows with ON CONFLICT DO NOTHING.
--      So when discovery returned an event that a matcher had ALREADY created
--      (url-less), the freshly-fetched slug was DISCARDED — the row stayed url-less
--      and unreachable. FIX: ON CONFLICT DO UPDATE to backfill sg_url (and
--      sg_datetime_utc) when the existing row lacks it. match_method / name are left
--      untouched — we only fill the missing slug. This makes every future discovery
--      cycle backfill slugs onto pre-existing mapped rows, for free.
--
--   2. Discovery only covered 163 performers. The mapped url-less events belong to
--      279 distinct performers (teams + acts), all named. SeatGeek performer URLs
--      are deterministic slugs (name → seatgeek.com/<slug>-tickets, verified against
--      the existing seeded set: "Boston Red Sox" → boston-red-sox-tickets, etc.).
--      Seed those performers into td_sg_performers so /events discovers their events
--      (1 credit each, self-limiting: a wrong slug just returns 0 items). Parking
--      "performers" are excluded — we never poll parking.
--
-- Also harden sg_match_map_tick: add a parking exclusion to the candidate WHERE so a
-- backfilled parking slug can never waste a 12-credit /match report on a parking row
-- (the enroller + td_apply_targets already skip parking; the sweep didn't).
--
-- Re-arm: reset last_discovered_at on the active set so all performers (existing 163
-- + new seed) re-fire, and raise the daily discover limit 5 → 40 so the enlarged
-- queue (~440) clears in ~11 days. One td_sg_discover(40) batch fires now to kick it
-- (async net.http_get — non-blocking; the daily drain picks up responses).
--
-- Cost: ~1 credit per performer per discovery cycle (~440/run, trivial vs the ~200k
-- plan). Enrollment + backfill are free (read our own tables).
-- Rollback: restore the mig 20260703133000 drain body (ON CONFLICT DO NOTHING) and
-- the mig 20260629170000 sg_match_map_tick body; deactivate the seeded performers
-- (UPDATE td_sg_performers SET active=false WHERE meta ... — see seed tag below).
-- ─────────────────────────────────────────────────────────────────────────────

-- 1. Drain: backfill sg_url onto pre-existing url-less rows instead of discarding it.
CREATE OR REPLACE FUNCTION public.td_sg_discover_drain()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE r RECORD; ev RECORD; v_sg bigint; v_ins int := 0;
BEGIN
  FOR r IN
    SELECT p.id AS pid, p.performer_name, h.status_code, h.content AS raw
    FROM public.td_sg_performers p
    JOIN net._http_response h ON h.id = p.pending_discover_request_id
    WHERE p.pending_discover_request_id IS NOT NULL
  LOOP
    IF r.status_code = 200 THEN
      FOR ev IN
        SELECT item FROM jsonb_array_elements(r.raw::jsonb->'body'->'items'->'events') AS item
      LOOP
        v_sg := NULLIF(regexp_replace(coalesce(ev.item->>'id',''),'\D','','g'),'')::bigint;
        IF v_sg IS NULL THEN
          v_sg := (substring(coalesce(ev.item->>'url', ev.item->>'buy_url',''), 'seatgeek\.com/.*?([0-9]{6,})'))::bigint;
        END IF;
        IF v_sg IS NOT NULL
           AND coalesce(ev.item->>'datetime_utc', ev.item->>'event_date_utc') IS NOT NULL THEN
          INSERT INTO public.sg_events_canonical
            (sg_event_id, sg_event_name, sg_event_date, sg_datetime_utc, sg_url, sg_venue_name, sg_category,
             has_seller_listings, has_orders, has_v2_listings_pulled,
             match_method, match_status, raw_event_jsonb, created_at, updated_at)
          VALUES (
            v_sg,
            coalesce(ev.item->>'title', ev.item->>'short_title', ev.item->>'name', r.performer_name),
            NULLIF(left(coalesce(ev.item->>'datetime_utc', ev.item->>'event_date_utc'),10),'')::date,
            (NULLIF(coalesce(ev.item->>'datetime_utc', ev.item->>'event_date_utc'),'')::timestamp AT TIME ZONE 'UTC'),
            NULLIF(coalesce(ev.item->>'url', ev.item->>'buy_url'),''),
            coalesce(ev.item->'venue'->>'name', ev.item->>'venue'),
            coalesce(ev.item->>'type', 'concert'),
            false, false, false,
            'td_seatgeek_search', 'pending', ev.item, now(), now())
          ON CONFLICT (sg_event_id) DO UPDATE
            -- Backfill ONLY the slug (+ datetime) when the existing row lacks it.
            -- Never overwrite match_method / name — the internal matcher's identity wins.
            SET sg_url = COALESCE(public.sg_events_canonical.sg_url, EXCLUDED.sg_url),
                sg_datetime_utc = COALESCE(public.sg_events_canonical.sg_datetime_utc, EXCLUDED.sg_datetime_utc),
                updated_at = now()
            WHERE public.sg_events_canonical.sg_url IS NULL;
          v_ins := v_ins + 1;
        END IF;
      END LOOP;
      PERFORM public.td_charge_credit(1, NULL, 'SG', '/events', 200,
              (r.raw::jsonb->'body'->'items'->>'quota_remaining')::int);
    END IF;
    UPDATE public.td_sg_performers
      SET pending_discover_request_id = NULL, last_discovered_at = now(), updated_at = now()
      WHERE id = r.pid;
  END LOOP;
  IF v_ins > 0 THEN PERFORM public.auto_match_sg_canonical_v3(); END IF;
  RETURN v_ins;
END $function$;

-- 2. Sweep: never spend a /match report on a parking event, even if it gains a slug.
CREATE OR REPLACE FUNCTION public.sg_match_map_tick()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE
  v_drained int := 0;
  v_fired   int := 0;
  v_req bigint; v_url text; v_tevo bigint; v_aq text;
  v_user text; v_pass text;
BEGIN
  UPDATE public.td_match_queue q
  SET resolved_at = now(), status_code = -2, error_msg = 'timeout_no_response'
  WHERE q.resolved_at IS NULL AND q.request_id IS NOT NULL
    AND q.fired_at < now() - interval '30 minutes'
    AND NOT EXISTS (SELECT 1 FROM net._http_response r WHERE r.id = q.request_id);

  v_drained := public.td_match_drain(50);
  PERFORM 1 FROM public.td_match_apply(80, true);

  IF public.td_match_cron_budget_ok()
     AND NOT EXISTS (SELECT 1 FROM public.td_match_queue q
                     WHERE q.request_id IS NOT NULL AND q.resolved_at IS NULL) THEN
    SELECT a.tevo_event_id, a.aq_short_event_id, sgc.sg_url
    INTO v_tevo, v_aq, v_url
    FROM public.aq_event_map a
    JOIN public.sg_events_canonical sgc
      ON sgc.sg_event_id = a.sg_event_id AND sgc.sg_url IS NOT NULL
    LEFT JOIN LATERAL (
      SELECT COALESCE(SUM(x.owned_tickets), 0) AS owned_qty
      FROM public.ticketsdata_event_xref x
      WHERE x.aq_short_event_id = a.aq_short_event_id AND x.active
    ) own ON true
    WHERE a.sg_event_id IS NOT NULL AND a.tevo_event_id IS NOT NULL
      AND a.event_date > now()
      AND a.event_name NOT ILIKE '%parking%'
      AND ( a.sh_event_id IS NULL OR a.vivid_event_id IS NULL
            OR NOT EXISTS (SELECT 1 FROM public.td_match_results mr2
                           WHERE mr2.aq_short_event_id = a.aq_short_event_id) )
      AND NOT EXISTS (SELECT 1 FROM public.td_match_results mr
                      WHERE mr.aq_short_event_id = a.aq_short_event_id
                        AND mr.created_at > now() - interval '14 days')
      AND NOT EXISTS (SELECT 1 FROM public.td_match_queue q
                      WHERE q.aq_short_event_id = a.aq_short_event_id
                        AND (q.resolved_at IS NULL
                             OR (q.status_code IS DISTINCT FROM 200
                                 AND q.fired_at > now() - interval '14 days')))
    ORDER BY
      (own.owned_qty > 0)            DESC,
      (a.axs_event_id IS NOT NULL)   DESC,
      own.owned_qty                  DESC,
      a.event_date                   ASC
    LIMIT 1;

    IF v_url IS NOT NULL THEN
      v_user := public.get_app_secret('TICKETSDATA_USERNAME');
      v_pass := public.get_app_secret('TICKETSDATA_PASSWORD');
      IF v_user IS NOT NULL AND v_pass IS NOT NULL THEN
        SELECT net.http_get(
          url := 'https://ticketsdata.com/match',
          params := jsonb_build_object('event_url', v_url, 'username', v_user, 'password', v_pass),
          headers := '{}'::jsonb, timeout_milliseconds := 45000) INTO v_req;
        INSERT INTO public.td_match_queue
          (tevo_event_id, aq_short_event_id, seed_platform, seed_event_url, purpose, request_id)
        VALUES (v_tevo, v_aq, 'SG', v_url, 'fill', v_req);
        v_fired := 1;
      END IF;
    END IF;
  END IF;

  RETURN jsonb_build_object(
    'drained', v_drained,
    'fired', v_fired,
    'reports_used_month', public.td_reports_this_month(),
    'budget_ok', public.td_match_cron_budget_ok());
END $function$;

-- 3. Seed SeatGeek performers of the mapped, upcoming, url-less events (non-parking,
--    with a tevo_performer_id for clean dedup). Constructed slug matches SeatGeek's
--    canonical performer URL format. ON CONFLICT (tevo_performer_id) DO NOTHING.
INSERT INTO public.td_sg_performers (tevo_performer_id, performer_name, performer_url, active, created_at, updated_at)
SELECT DISTINCT ON (pm.tevo_performer_id)
  pm.tevo_performer_id,
  pm.performer_name,
  'https://seatgeek.com/' ||
    lower(regexp_replace(regexp_replace(pm.performer_name, '[^a-zA-Z0-9]+', '-', 'g'), '(^-+|-+$)', '', 'g')) ||
    '-tickets',
  true, now(), now()
FROM public.aq_event_map a
JOIN public.sg_events_canonical sgc ON sgc.sg_event_id = a.sg_event_id
JOIN public.aq_performer_map pm ON pm.performer_short_id = a.performer_short_id
WHERE a.event_date > now()
  AND sgc.sg_url IS NULL
  AND pm.tevo_performer_id IS NOT NULL
  AND pm.performer_name IS NOT NULL
  AND pm.performer_name NOT ILIKE '%parking%'
ORDER BY pm.tevo_performer_id
ON CONFLICT (tevo_performer_id) DO NOTHING;

-- 4. Re-arm the whole active set so existing 163 + new seed all re-discover, then
--    raise the daily discover throughput and kick one batch now.
UPDATE public.td_sg_performers SET last_discovered_at = NULL, updated_at = now()
WHERE active AND pending_discover_request_id IS NULL;

SELECT cron.schedule('td_sg_discover_daily', '40 9 * * *',
                     $$ DO $b$ BEGIN PERFORM public.td_sg_discover(40); END $b$; $$);

SELECT public.td_sg_discover(40);

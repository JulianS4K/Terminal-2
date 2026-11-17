-- ============================================================================
-- Migration 20260911210000 — every event mapper calls THE resolver: cross-map, per-surface modes, shadow dry-run
-- Migration 20260911210000 · level:data-collection · lane:A1 · writes:event_mapper_switch,event_mapper_shadow_log,aq_event_map,cross_source_venue_map,aq_performer_map,seatgeek_performer_xref,gotickets_event,sg_events_canonical,s4kcs_orders,n2s_items,tickpick_orders,vivid_orders,gotickets_purchases,seatgeek_purchases,cron.job
--
-- Lane:     A1 (data plane) — every surface that maps a marketplace event to TEvo
-- Touches:  event_mapper_switch (NEW, W), event_mapper_shadow_log (NEW, W),
--           aq_event_map (W — cross-map: source ids + venue/performer short ids onto the hub row of a resolved tevo id; never overwrites),
--           cross_source_venue_map (W — the source venue string becomes an alias of the event's TEvo venue, fill-only),
--           aq_performer_map + seatgeek_performer_xref (W — the source performer name becomes an alias of the event's TEvo performer, fill-only),
--           gotickets_event + sg_events_canonical (W — tevo writeback, fill-only),
--           s4kcs_orders, n2s_items, tickpick_orders, vivid_orders, gotickets_purchases, seatgeek_purchases
--             (W — tevo_event_id + method/score columns, fill-only, LIVE mode only),
--           cron.job (W — the six mapper crons now call event_mapper_run(<surface>)),
--           evo_orders, gotickets_sales, seatgeek_orders (R — N2S order-identity rules 0b/0c/0e)
-- Pre-reqs: 20260911200000 (event_mapper_resolve + cold path), 20260911200100 (purchases applier),
--           20260911160500/161000 (purchase books, applied in prod), 20260909012000 (s4kcs_map_events),
--           20260911040000 (n2s_map_events rules 0–0e), 20260804230000 (gt_map_events),
--           20260810184500 (match_gotickets_us_events), 20260516240000 (auto_match_sg_canonical_v3)
--
-- Already applied to prod · via MCP 2026-09-11 ~18:05 UTC under operator direction ("Apply all three now").
-- Authored 2026-09-11 (operator: "merge all these mappers into one function and
-- strengthen so they map to evo and cross map, then have all current users call them after a dry run").
--
-- ============================================================================
-- HOW THE SWITCH-OVER WORKS (dry run first, mechanically)
-- ============================================================================
--   event_mapper_switch(surface, mode)  — one row per surface, mode ∈ legacy | shadow | live.
--     legacy : the surface's OLD mapper runs, the resolver does nothing.
--     shadow : the OLD mapper runs and still writes; the resolver then replays the same rows
--              (identity OFF) and logs agree / disagree / resolver_only / legacy_only into
--              event_mapper_shadow_log. Nothing the resolver decides is written. THIS IS THE DRY RUN.
--     live   : the resolver is the writer (event_mapper_map_surface(surface, apply => true)); the
--              old mapper is not called. Every hit is CROSS-MAPPED: the source id lands on the hub
--              row of that tevo id (aq_event_map.<src>_event_id, fill-only) and, for GoTickets /
--              SeatGeek, on the catalogue (gotickets_event / sg_events_canonical.tevo_event_id,
--              fill-only) — so the NEXT surface that sees the same event resolves by identity.
--   Seed: the two purchase books start LIVE (they are this PR's first caller and carry no
--   legacy mapper worth keeping); every other surface starts in SHADOW. Flipping a surface is
--   one row update after reading event_mapper_shadow_report(surface):
--     UPDATE event_mapper_switch SET mode = 'live', changed_at = now(), note = '<why>' WHERE surface = '<s>';
--
--   event_mapper_run(surface, [horizon_days]) — the ONE entry point every cron now calls; it
--     dispatches on the mode. Crons re-pointed here (jobnames unchanged, schedules unchanged):
--       s4kcs_map_events_10min      → event_mapper_run('s4kcs_orders')
--       n2s_map_events_5min         → …; event_mapper_run('n2s_items'); … (the other three
--                                     statements of that job — identity pull, GT-by-name, pull-all — stay)
--       gt_map_events_hourly        → event_mapper_run('gotickets_event')
--       gt_map_events_wide_daily    → event_mapper_run('gotickets_event', 3650)
--       gotickets_match_us_6h       → event_mapper_run('gotickets_event')
--       auto_match_sg_canonical_v3_hourly (DISABLED since 2026-06-19, stays disabled)
--                                   → event_mapper_run('sg_events_canonical')
--       our_purchases_map_hourly    → event_mapper_run('gotickets_purchases') + ('seatgeek_purchases')
--     tickpick_orders / vivid_orders have no venue column; they keep the :22 AQ sweep + :40 backfill
--     as legacy and are SHADOWED by the daily cold path only (rules 3 + 4 can still map them live).
--
--   N2S identity rules 0 / 0b / 0c / 0d / 0e (the same order in the CRM / EVO / GoTickets / Vivid /
--   SeatGeek books) are IDENTITY, not inference — they are carried into the applier verbatim so
--   the live path never loses them to the resolver's name/venue/date rules.
--
--   Venue + performer cross-map (operator: "also map venue ids and performer ids cross sources to
--   simplify table references and speed"): the resolved TEvo event names its venue_id and
--   primary_performer_id, so the source's venue string / performer name are learned as aliases of
--   those canonical ids (cross_source_venue_map.<src>_aliases; aq_performer_map.aliases +
--   seatgeek_performer_xref), and the hub row gets venue_short_id / performer_short_id from the aq
--   maps. Lookups: cross_source_venue_resolve(name) and the new event_mapper_performer_id(name) —
--   one call each, alias tier first, no TEvo search once learned.
--
--   Cross-map honours the hub landmines (PROJECT_BIBLE §0/§3): pick the aq_curated row for the
--   tevo id when one exists, else the oldest; create a SYS row only when the hub has no row for
--   that tevo id at all; set a source-id column only when it is NULL on that row AND no other hub
--   row already carries that source id for a different tevo id. Never overwrite.
--
-- ROLLBACK: for each re-pointed cron, restore its command (bodies recorded in §5 below); DROP FUNCTION
--   event_mapper_run(text,int), event_mapper_shadow_report(text,interval), event_mapper_map_surface(text,boolean,int,text[]),
--   event_mapper_surface_sql(text,int), event_mapper_apply(text,bigint,bigint,text,text,date,numeric);
--   DROP TABLE event_mapper_shadow_log, event_mapper_switch; re-apply our_purchases_map() from 20260911200100.
-- ============================================================================

-- ── 1. Mode table + shadow log ───────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.event_mapper_switch (
  surface     text PRIMARY KEY,
  mode        text NOT NULL DEFAULT 'shadow' CHECK (mode IN ('legacy', 'shadow', 'live')),
  changed_at  timestamptz NOT NULL DEFAULT now(),
  note        text
);
ALTER TABLE public.event_mapper_switch ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.event_mapper_switch FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.event_mapper_switch TO service_role;
COMMENT ON TABLE public.event_mapper_switch IS
  'Per-surface mode of the unified event mapper: legacy (old mapper only) | shadow (old mapper writes, resolver replays + logs — the dry run) | live (resolver writes + cross-maps). A1 mig 20260911210000.';

INSERT INTO public.event_mapper_switch (surface, mode, note) VALUES
  ('gotickets_purchases', 'live',   'first switched caller (mig 20260911200100)'),
  ('seatgeek_purchases',  'live',   'first switched caller (mig 20260911200100)'),
  ('s4kcs_orders',        'shadow', 'legacy = s4kcs_map_events() (8 rules)'),
  ('n2s_items',           'shadow', 'legacy = n2s_map_events(true); identity rules 0–0e carried into the applier'),
  ('gotickets_event',     'shadow', 'legacy = gt_map_events() + match_gotickets_us_events()'),
  ('sg_events_canonical', 'shadow', 'legacy = auto_match_sg_canonical_v3() (cron disabled since 2026-06-19)'),
  ('tickpick_orders',     'shadow', 'legacy = match_unmatched_orders_sweep :22 + backfill :40 (no venue column)'),
  ('vivid_orders',        'shadow', 'legacy = match_unmatched_orders_sweep :22 + backfill :40 (no venue column)')
ON CONFLICT (surface) DO NOTHING;

CREATE TABLE IF NOT EXISTS public.event_mapper_shadow_log (
  id            bigserial PRIMARY KEY,
  at            timestamptz NOT NULL DEFAULT now(),
  surface       text NOT NULL,
  row_key       text NOT NULL,
  legacy_tevo   bigint,
  resolver_tevo bigint,
  method        text,
  score         numeric,
  verdict       text NOT NULL   -- agree | disagree | resolver_only | legacy_only
);
CREATE INDEX IF NOT EXISTS event_mapper_shadow_log_surface_at_idx ON public.event_mapper_shadow_log (surface, at DESC);
ALTER TABLE public.event_mapper_shadow_log ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.event_mapper_shadow_log FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT, DELETE ON public.event_mapper_shadow_log TO service_role;
COMMENT ON TABLE public.event_mapper_shadow_log IS
  'Dry-run ledger of the unified event mapper: for every row a legacy mapper touched while its surface is in shadow mode, what the resolver would have written. Read via event_mapper_shadow_report(). A1 mig 20260911210000.';

-- ── 2. Cross-map writer ──────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.event_mapper_apply(
  p_source text, p_source_event_id bigint, p_tevo bigint,
  p_name text, p_venue_name text, p_local_date date, p_score numeric DEFAULT NULL, p_performer text DEFAULT NULL
)
RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $fn$
DECLARE
  v_src text := lower(trim(coalesce(p_source, '')));
  v_col text;
  v_aq  text;
  v_n   int := 0;
  v_out text := '';
  v_venue_id bigint; v_perf_id bigint; v_resolved_vid bigint; v_alias_col text;
BEGIN
  IF current_user NOT IN ('service_role', 'postgres', 'supabase_admin') THEN
    RAISE EXCEPTION 'forbidden: %', current_user USING ERRCODE = '42501';
  END IF;
  IF p_tevo IS NULL THEN RETURN 'no_tevo'; END IF;

  v_col := CASE
    WHEN v_src IN ('gotickets', 'gt')                     THEN 'gotickets_event_id'
    WHEN v_src IN ('seatgeek', 'sg')                      THEN 'sg_event_id'
    WHEN v_src IN ('vivid', 'vividseats', 'vivid seats')  THEN 'vivid_event_id'
    WHEN v_src IN ('stubhub', 'sh')                       THEN 'sh_event_id'
    WHEN v_src IN ('ticketmaster', 'tm')                  THEN 'tm_event_id'
    WHEN v_src IN ('seatdata', 'sd')                      THEN 'sd_event_id'
    ELSE NULL END;

  -- Hub row for this tevo id: curated first, else the oldest; create only when none exists.
  SELECT a.aq_short_event_id INTO v_aq FROM public.aq_event_map a
   WHERE a.tevo_event_id = p_tevo
   ORDER BY (a.aq_source = 'aq_curated') DESC, a.imported_at NULLS LAST LIMIT 1;
  IF v_aq IS NULL AND p_name IS NOT NULL AND p_local_date IS NOT NULL THEN
    v_aq := public.create_system_aq_event(v_src, p_name, p_venue_name, p_local_date::timestamptz, p_source_event_id);
    UPDATE public.aq_event_map SET tevo_event_id = p_tevo WHERE aq_short_event_id = v_aq AND tevo_event_id IS NULL;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    IF v_n > 0 THEN v_out := v_out || 'hub_row_created;'; END IF;
  END IF;

  -- Source id onto that hub row: fill-only, and never when another hub row already binds this
  -- source id to a DIFFERENT tevo id (that is a hub duplicate to consolidate, not to widen).
  IF v_aq IS NOT NULL AND v_col IS NOT NULL AND p_source_event_id IS NOT NULL THEN
    EXECUTE format(
      'UPDATE public.aq_event_map SET %1$I = $1 WHERE aq_short_event_id = $2 AND %1$I IS NULL
          AND NOT EXISTS (SELECT 1 FROM public.aq_event_map o WHERE o.%1$I = $1 AND o.tevo_event_id IS DISTINCT FROM $3)',
      v_col) USING p_source_event_id, v_aq, p_tevo;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    IF v_n > 0 THEN v_out := v_out || 'hub_' || v_col || ';'; END IF;
  END IF;

  -- Venue + performer cross-map (fill-only): the resolved TEvo event names its venue and primary
  -- performer, so the SOURCE's venue string / performer name become aliases of those canonical ids.
  -- Venue xref = cross_source_venue_map (THE one — never a rival; PROJECT_BIBLE §4); performer = the
  -- hub's aq_performer_map.aliases + seatgeek_performer_xref. The hub row also gets venue_short_id /
  -- performer_short_id when the aq maps know the id. Every later lookup then hits the alias tier
  -- instead of the prefix tier or a TEvo search.
  SELECT e.venue_id, e.primary_performer_id INTO v_venue_id, v_perf_id FROM public.events e WHERE e.id = p_tevo;
  IF v_venue_id IS NOT NULL AND nullif(trim(coalesce(p_venue_name, '')), '') IS NOT NULL THEN
    v_alias_col := CASE
      WHEN v_src IN ('seatgeek', 'sg')                     THEN 'sg_aliases'
      WHEN v_src IN ('tickpick', 'tp')                     THEN 'tickpick_aliases'
      WHEN v_src IN ('vivid', 'vividseats', 'vivid seats') THEN 'vivid_aliases'
      WHEN v_src IN ('gotickets', 'gt')                    THEN 'gotickets_aliases'
      ELSE 'crm_aliases' END;
    -- only when the string does not already resolve — and never when it resolves to ANOTHER venue
    -- (that is an ambiguity for the venue sweep, not something an event match may decide)
    v_resolved_vid := public.cross_source_venue_resolve(p_venue_name, NULL, NULL);
    IF v_resolved_vid IS NULL THEN
      EXECUTE format(
        'UPDATE public.cross_source_venue_map SET %1$I = coalesce(%1$I, ''[]''::jsonb) || to_jsonb($1::text), updated_at = now()
          WHERE tevo_venue_id = $2 AND NOT (coalesce(%1$I, ''[]''::jsonb) ? $1)', v_alias_col)
        USING trim(p_venue_name), v_venue_id;
      GET DIAGNOSTICS v_n = ROW_COUNT;
      IF v_n > 0 THEN v_out := v_out || 'venue_alias;'; END IF;
    END IF;
    UPDATE public.aq_event_map a SET venue_short_id = m.venue_short_id
      FROM public.aq_venue_map m
     WHERE a.aq_short_event_id = v_aq AND a.venue_short_id IS NULL AND m.tevo_venue_id = v_venue_id;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    IF v_n > 0 THEN v_out := v_out || 'hub_venue_short_id;'; END IF;
  END IF;
  IF v_perf_id IS NOT NULL THEN
    IF nullif(trim(coalesce(p_performer, '')), '') IS NOT NULL THEN
      UPDATE public.aq_performer_map m
         SET aliases = array_append(coalesce(m.aliases, '{}'::text[]), trim(p_performer))
       WHERE m.tevo_performer_id = v_perf_id
         AND NOT (lower(trim(p_performer)) = ANY (SELECT lower(x) FROM unnest(coalesce(m.aliases, '{}'::text[])) x))
         AND lower(trim(p_performer)) <> lower(coalesce(m.performer_name, ''));
      GET DIAGNOSTICS v_n = ROW_COUNT;
      IF v_n > 0 THEN v_out := v_out || 'performer_alias;'; END IF;
      IF v_src IN ('seatgeek', 'sg') AND NOT EXISTS (SELECT 1 FROM public.seatgeek_performer_xref x WHERE lower(x.sg_performer_name) = lower(trim(p_performer))) THEN
        INSERT INTO public.seatgeek_performer_xref (tevo_performer_id, sg_performer_name, match_method, match_confidence, matched_at)
        VALUES (v_perf_id, trim(p_performer), 'event_mapper', p_score, now());
        v_out := v_out || 'sg_performer_xref;';
      END IF;
    END IF;
    UPDATE public.aq_event_map a SET performer_short_id = m.performer_short_id
      FROM public.aq_performer_map m
     WHERE a.aq_short_event_id = v_aq AND a.performer_short_id IS NULL AND m.tevo_performer_id = v_perf_id;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    IF v_n > 0 THEN v_out := v_out || 'hub_performer_short_id;'; END IF;
  END IF;

  -- Catalogue writebacks (fill-only): the next surface that meets this event resolves by identity.
  IF v_src IN ('gotickets', 'gt') AND p_source_event_id IS NOT NULL THEN
    UPDATE public.gotickets_event
       SET tevo_event_id = p_tevo, mapped_via = 'event_mapper', map_score = p_score, mapped_at = now(), updated_at = now()
     WHERE gt_event_id = p_source_event_id AND tevo_event_id IS NULL;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    IF v_n > 0 THEN v_out := v_out || 'gotickets_event;'; END IF;
  ELSIF v_src IN ('seatgeek', 'sg') AND p_source_event_id IS NOT NULL THEN
    UPDATE public.sg_events_canonical
       SET tevo_event_id = p_tevo, match_method = 'event_mapper', match_confidence = p_score, matched_at = now(), updated_at = now()
     WHERE sg_event_id = p_source_event_id AND tevo_event_id IS NULL;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    IF v_n > 0 THEN v_out := v_out || 'sg_events_canonical;'; END IF;
  END IF;

  RETURN nullif(v_out, '');
END $fn$;
REVOKE ALL ON FUNCTION public.event_mapper_apply(text, bigint, bigint, text, text, date, numeric, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.event_mapper_apply(text, bigint, bigint, text, text, date, numeric, text) TO service_role;
COMMENT ON FUNCTION public.event_mapper_apply(text, bigint, bigint, text, text, date, numeric, text) IS
  'Cross-map a resolved (source, source_event_id, venue string, performer name) → tevo_event_id: source id onto the hub row of that tevo id, venue string → cross_source_venue_map alias of the event''s venue, performer name → aq_performer_map alias (+ seatgeek_performer_xref), hub venue/performer short ids, tevo writeback onto gotickets_event / sg_events_canonical. All fill-only. A1 mig 20260911210000.';

-- ── 2b. One lookup for performer ids (the venue twin is cross_source_venue_resolve) ──
CREATE OR REPLACE FUNCTION public.event_mapper_performer_id(p_name text)
RETURNS bigint
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $fn$
  -- exact TEvo name → hub alias (learned by event_mapper_apply) → SG xref → similarity fallback
  SELECT coalesce(
    (SELECT performer_id FROM public.performer_metadata WHERE lower(trim(name)) = lower(trim(p_name)) LIMIT 1),
    (SELECT tevo_performer_id FROM public.aq_performer_map
      WHERE tevo_performer_id IS NOT NULL
        AND (lower(trim(performer_name)) = lower(trim(p_name))
             OR lower(trim(p_name)) = ANY (SELECT lower(x) FROM unnest(coalesce(aliases, '{}'::text[])) x))
      LIMIT 1),
    (SELECT tevo_performer_id FROM public.seatgeek_performer_xref WHERE lower(sg_performer_name) = lower(trim(p_name)) LIMIT 1),
    public.resolve_tevo_performer_id(p_name, 0.6))
  WHERE nullif(trim(coalesce(p_name, '')), '') IS NOT NULL;
$fn$;
REVOKE ALL ON FUNCTION public.event_mapper_performer_id(text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.event_mapper_performer_id(text) TO service_role;
COMMENT ON FUNCTION public.event_mapper_performer_id(text) IS
  'Any source performer name → tevo_performer_id: TEvo exact → hub aliases (learned by the event mapper) → SG xref → similarity ≥ 0.6. Venue twin: cross_source_venue_resolve(). A1 mig 20260911210000.';

-- ── 3. Surface catalogue: one SELECT shape per surface + its UPDATE ───────────
CREATE OR REPLACE FUNCTION public.event_mapper_surface_sql(p_surface text, p_horizon_days int DEFAULT 180)
RETURNS TABLE(select_sql text, update_sql text, key_type text)
LANGUAGE plpgsql IMMUTABLE
AS $fn$
BEGIN
  -- select_sql yields: row_key, source, source_event_id, event_name, performer, venue_name, venue_city,
  --                    venue_state, local_date, event_time_utc, previous (current tevo), ord (recency)
  -- update_sql takes $1 row_key (text, cast inside), $2 tevo, $3 method, $4 score; fill-only.
  CASE p_surface
    WHEN 'gotickets_purchases' THEN
      select_sql := $q$SELECT gt_purchase_id::text AS row_key, 'gotickets'::text AS source, gt_event_id AS source_event_id, event_name,
                              performers->0->>'name' AS performer, venue_name, venue_city, venue_state, event_time_local::date AS local_date,
                              event_time_utc, tevo_event_id AS previous, updated_at AS ord FROM public.gotickets_purchases WHERE event_time_local IS NOT NULL$q$;
      update_sql := $q$UPDATE public.gotickets_purchases SET tevo_event_id = $2, mapped_via = $3, map_score = $4, updated_at = now() WHERE gt_purchase_id = $1::bigint AND tevo_event_id IS NULL$q$;
    WHEN 'seatgeek_purchases' THEN
      select_sql := $q$SELECT order_id AS row_key, 'seatgeek'::text AS source, sg_event_id AS source_event_id, event_name, NULL::text AS performer,
                              event_location AS venue_name, NULL::text AS venue_city, NULL::text AS venue_state, event_start::date AS local_date,
                              NULL::timestamptz AS event_time_utc, tevo_event_id AS previous, updated_at AS ord FROM public.seatgeek_purchases WHERE event_start IS NOT NULL$q$;
      update_sql := $q$UPDATE public.seatgeek_purchases SET tevo_event_id = $2, mapped_via = $3, map_score = $4, updated_at = now() WHERE order_id = $1 AND tevo_event_id IS NULL$q$;
    WHEN 's4kcs_orders' THEN
      select_sql := $q$SELECT s4k_order_id AS row_key, lower(source) AS source, NULL::bigint AS source_event_id, event_name, NULL::text AS performer,
                              venue_name, venue_city, venue_state, event_date AS local_date, NULL::timestamptz AS event_time_utc,
                              tevo_event_id AS previous, coalesce(mapped_at, pulled_at) AS ord FROM public.s4kcs_orders WHERE event_date >= current_date - 7$q$;
      update_sql := $q$UPDATE public.s4kcs_orders SET tevo_event_id = $2, map_method = $3, map_confidence = $4, mapped_at = now() WHERE s4k_order_id = $1 AND tevo_event_id IS NULL$q$;
    WHEN 'n2s_items' THEN
      select_sql := $q$SELECT n2s_id::text AS row_key, lower(marketplace) AS source, NULL::bigint AS source_event_id, event_name, NULL::text AS performer,
                              venue AS venue_name, NULL::text AS venue_city, NULL::text AS venue_state, event_dt::date AS local_date, NULL::timestamptz AS event_time_utc,
                              tevo_event_id AS previous, n2s_updated_at AS ord FROM public.n2s_items WHERE NOT coalesce(is_terminal, false) AND event_dt IS NOT NULL$q$;
      update_sql := $q$UPDATE public.n2s_items SET tevo_event_id = $2, mapped_via = $3 WHERE n2s_id = $1::bigint AND tevo_event_id IS NULL$q$;
    WHEN 'tickpick_orders' THEN
      select_sql := $q$SELECT tp_order_id AS row_key, 'tickpick'::text AS source, NULL::bigint AS source_event_id, event_name, NULL::text AS performer,
                              NULL::text AS venue_name, NULL::text AS venue_city, NULL::text AS venue_state, event_date::date AS local_date, event_date AS event_time_utc,
                              tevo_event_id AS previous, ordered_at AS ord FROM public.tickpick_orders WHERE event_date >= now() - interval '90 days'$q$;
      update_sql := $q$UPDATE public.tickpick_orders SET tevo_event_id = $2, matched_via = $3, match_confidence = $4, matched_at = now() WHERE tp_order_id = $1 AND tevo_event_id IS NULL$q$;
    WHEN 'vivid_orders' THEN
      select_sql := $q$SELECT vivid_order_id AS row_key, 'vivid'::text AS source, NULL::bigint AS source_event_id, event_name, NULL::text AS performer,
                              NULL::text AS venue_name, NULL::text AS venue_city, NULL::text AS venue_state, event_date::date AS local_date, event_date AS event_time_utc,
                              tevo_event_id AS previous, ordered_at AS ord FROM public.vivid_orders WHERE event_date >= now() - interval '90 days'$q$;
      update_sql := $q$UPDATE public.vivid_orders SET tevo_event_id = $2 WHERE vivid_order_id = $1 AND tevo_event_id IS NULL$q$;
    WHEN 'gotickets_event' THEN
      select_sql := format($q$SELECT gt_event_id::text AS row_key, 'gotickets'::text AS source, gt_event_id AS source_event_id, name AS event_name, performer,
                              venue_name, venue_city, venue_state, NULL::date AS local_date, event_time_utc, tevo_event_id AS previous,
                              coalesce(mapped_at, updated_at) AS ord FROM public.gotickets_event
                        WHERE status = 'AS_SCHEDULED' AND event_time_utc > now() AND event_time_utc < now() + make_interval(days => %s)$q$,
                        greatest(1, coalesce(p_horizon_days, 180)));
      update_sql := $q$UPDATE public.gotickets_event SET tevo_event_id = $2, mapped_via = $3, map_score = $4, mapped_at = now(), updated_at = now() WHERE gt_event_id = $1::bigint AND tevo_event_id IS NULL$q$;
    WHEN 'sg_events_canonical' THEN
      select_sql := $q$SELECT sg_event_id::text AS row_key, 'seatgeek'::text AS source, sg_event_id AS source_event_id, sg_event_name AS event_name, NULL::text AS performer,
                              sg_venue_name AS venue_name, sg_venue_city AS venue_city, sg_venue_state AS venue_state, sg_event_date AS local_date, sg_datetime_utc AS event_time_utc,
                              tevo_event_id AS previous, coalesce(matched_at, updated_at) AS ord FROM public.sg_events_canonical
                        WHERE sg_event_date >= current_date AND coalesce(sg_category, '') NOT IN ('Parking', 'parking')$q$;
      update_sql := $q$UPDATE public.sg_events_canonical SET tevo_event_id = $2, match_method = $3, match_confidence = $4, matched_at = now(), updated_at = now() WHERE sg_event_id = $1::bigint AND tevo_event_id IS NULL$q$;
    ELSE
      RAISE EXCEPTION 'event_mapper: unknown surface % (gotickets_purchases | seatgeek_purchases | s4kcs_orders | n2s_items | tickpick_orders | vivid_orders | gotickets_event | sg_events_canonical)', p_surface;
  END CASE;
  key_type := 'text';
  RETURN NEXT;
END $fn$;
COMMENT ON FUNCTION public.event_mapper_surface_sql(text, int) IS
  'The one place each surface''s resolver inputs (SELECT) and fill-only write (UPDATE) are declared. A1 mig 20260911210000.';

-- ── 4. THE applier: resolver over one surface, dry-run by default ────────────
CREATE OR REPLACE FUNCTION public.event_mapper_map_surface(
  p_surface text, p_apply boolean DEFAULT false, p_limit int DEFAULT 500, p_keys text[] DEFAULT NULL
)
RETURNS TABLE(row_key text, previous bigint, tevo_event_id bigint, method text, score numeric, crossmap text)
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $fn$
DECLARE v_sel text; v_upd text; v_n int; rr record; v_x text;
BEGIN
  IF current_user NOT IN ('service_role', 'postgres', 'supabase_admin') THEN
    RAISE EXCEPTION 'forbidden: %', current_user USING ERRCODE = '42501';
  END IF;
  PERFORM set_config('statement_timeout', '170000', true);
  SELECT s.select_sql, s.update_sql INTO v_sel, v_upd FROM public.event_mapper_surface_sql(p_surface) s;

  -- N2S identity rules 0–0e (verbatim from n2s_map_events): the SAME ORDER in one of our books.
  -- Identity beats inference, so they run before the resolver and only in apply mode.
  IF p_surface = 'n2s_items' AND p_apply AND p_keys IS NULL THEN
    UPDATE public.n2s_items n SET tevo_event_id = o.tevo_event_id, mapped_via = 'n2s_crm_order_identity'
      FROM public.s4kcs_orders o
     WHERE o.s4k_order_id = n.n2s_order_key AND o.tevo_event_id IS NOT NULL AND n.tevo_event_id IS NULL AND NOT coalesce(n.is_terminal, false);
    UPDATE public.n2s_items n SET tevo_event_id = o.tevo_event_id, mapped_via = 'n2s_evo_order_identity'
      FROM public.evo_orders o
     WHERE n.s4k_source = 'EVO' AND o.evo_order_id::text = n.n2s_order_key AND o.tevo_event_id IS NOT NULL
       AND n.tevo_event_id IS NULL AND NOT coalesce(n.is_terminal, false);
    UPDATE public.n2s_items n SET tevo_event_id = s.eid, mapped_via = 'n2s_gt_order_identity'
      FROM (SELECT n2.n2s_id, min(coalesce(g.tevo_event_id, a.tevo_event_id)) AS eid
              FROM public.n2s_items n2
              JOIN public.gotickets_sales gs ON gs.gt_sale_id::text = n2.order_number
              LEFT JOIN public.gotickets_event g ON g.gt_event_id = gs.gt_event_id
              LEFT JOIN public.aq_event_map a ON a.gotickets_event_id = gs.gt_event_id AND a.tevo_event_id IS NOT NULL
             WHERE n2.s4k_source = 'GoTickets' AND n2.tevo_event_id IS NULL AND NOT coalesce(n2.is_terminal, false)
             GROUP BY n2.n2s_id HAVING count(DISTINCT coalesce(g.tevo_event_id, a.tevo_event_id)) = 1) s
     WHERE n.n2s_id = s.n2s_id AND n.tevo_event_id IS NULL;
    UPDATE public.n2s_items n SET tevo_event_id = s.eid, mapped_via = 'n2s_vivid_order_identity'
      FROM (SELECT n2.n2s_id, min(coalesce(o.tevo_event_id, a.tevo_event_id)) AS eid
              FROM public.n2s_items n2
              JOIN public.vivid_orders o ON o.vivid_order_id = n2.order_number
              LEFT JOIN public.aq_event_map a ON o.raw->>'productionId' ~ '^[0-9]+$'
                                             AND a.vivid_event_id = (o.raw->>'productionId')::bigint AND a.tevo_event_id IS NOT NULL
             WHERE n2.s4k_source = 'Vivid Seats' AND n2.tevo_event_id IS NULL AND NOT coalesce(n2.is_terminal, false)
             GROUP BY n2.n2s_id HAVING count(DISTINCT coalesce(o.tevo_event_id, a.tevo_event_id)) = 1) s
     WHERE n.n2s_id = s.n2s_id AND n.tevo_event_id IS NULL;
    UPDATE public.n2s_items n SET tevo_event_id = s.eid, mapped_via = 'n2s_sg_order_identity'
      FROM (SELECT n2.n2s_id, min(coalesce(o.tevo_event_id, c.tevo_event_id, a.tevo_event_id)) AS eid
              FROM public.n2s_items n2
              JOIN public.seatgeek_orders o ON o.sg_order_id = n2.order_number
              LEFT JOIN public.sg_events_canonical c ON c.sg_event_id = o.sg_event_id AND c.tevo_event_id IS NOT NULL
              LEFT JOIN public.aq_event_map a ON a.sg_event_id = o.sg_event_id AND a.tevo_event_id IS NOT NULL
             WHERE n2.s4k_source = 'SeatGeek' AND n2.tevo_event_id IS NULL AND NOT coalesce(n2.is_terminal, false)
             GROUP BY n2.n2s_id HAVING count(DISTINCT coalesce(o.tevo_event_id, c.tevo_event_id, a.tevo_event_id)) = 1) s
     WHERE n.n2s_id = s.n2s_id AND n.tevo_event_id IS NULL;
  END IF;

  -- Candidate rows: unmapped (normal) or an explicit key set (shadow replay), newest first.
  DROP TABLE IF EXISTS _em_rows;
  IF p_keys IS NULL THEN
    EXECUTE format('CREATE TEMP TABLE _em_rows ON COMMIT DROP AS SELECT * FROM (%s) q WHERE q.previous IS NULL ORDER BY q.ord DESC NULLS LAST LIMIT %s',
                   v_sel, greatest(1, least(5000, p_limit)));
  ELSE
    EXECUTE format('CREATE TEMP TABLE _em_rows ON COMMIT DROP AS SELECT * FROM (%s) q WHERE q.row_key = ANY($1)', v_sel) USING p_keys;
  END IF;

  DROP TABLE IF EXISTS _em_out;
  CREATE TEMP TABLE _em_out ON COMMIT DROP AS
  SELECT q.row_key, q.previous, q.source, q.source_event_id, q.event_name, q.performer, q.venue_name, q.local_date,
         res.tevo_event_id AS tevo, res.method, res.score, NULL::text AS crossmap
    FROM _em_rows q
    LEFT JOIN LATERAL public.event_mapper_resolve(q.source, q.source_event_id, q.event_name, q.performer, q.venue_name,
                        q.venue_city, q.venue_state, q.local_date, q.event_time_utc, (p_keys IS NULL), 0.5) res ON true;

  IF p_apply THEN
    FOR rr IN SELECT o.* FROM _em_out o WHERE o.tevo IS NOT NULL AND o.previous IS NULL LOOP
      EXECUTE v_upd USING rr.row_key, rr.tevo, rr.method, rr.score;
      GET DIAGNOSTICS v_n = ROW_COUNT;
      IF v_n > 0 THEN
        v_x := public.event_mapper_apply(rr.source, rr.source_event_id, rr.tevo, rr.event_name, rr.venue_name, rr.local_date, rr.score, rr.performer);
        UPDATE _em_out o SET crossmap = coalesce(v_x, 'written') WHERE o.row_key = rr.row_key;
      END IF;
    END LOOP;
  END IF;

  RETURN QUERY SELECT o.row_key, o.previous, o.tevo, o.method, o.score, o.crossmap FROM _em_out o;
END $fn$;
REVOKE ALL ON FUNCTION public.event_mapper_map_surface(text, boolean, int, text[]) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.event_mapper_map_surface(text, boolean, int, text[]) TO service_role;
COMMENT ON FUNCTION public.event_mapper_map_surface(text, boolean, int, text[]) IS
  'Run event_mapper_resolve over one surface. p_apply=false (default) = dry run, returns what WOULD be written; p_apply=true = fill-only write + cross-map (event_mapper_apply). p_keys replays specific rows with identity OFF (shadow compare). N2S order-identity rules 0–0e run first in apply mode. A1 mig 20260911210000.';

-- ── 5. THE entry point every cron calls: dispatch on the surface''s mode ──────
CREATE OR REPLACE FUNCTION public.event_mapper_run(p_surface text, p_horizon_days int DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $fn$
DECLARE
  v_mode text; v_legacy jsonb := NULL; v_keys text[]; v_sel text; v_n int := 0;
  v_agree int := 0; v_dis int := 0; v_ronly int := 0; v_lonly int := 0;
BEGIN
  IF current_user NOT IN ('service_role', 'postgres', 'supabase_admin') THEN
    RAISE EXCEPTION 'forbidden: %', current_user USING ERRCODE = '42501';
  END IF;
  PERFORM set_config('statement_timeout', '170000', true);
  SELECT mode INTO v_mode FROM public.event_mapper_switch WHERE surface = p_surface;
  v_mode := coalesce(v_mode, 'shadow');

  IF v_mode = 'live' THEN
    SELECT count(*) INTO v_n FROM public.event_mapper_map_surface(p_surface, true, 2000) m WHERE m.tevo_event_id IS NOT NULL;
    RETURN jsonb_build_object('surface', p_surface, 'mode', v_mode, 'mapped', v_n);
  END IF;

  -- Snapshot the unmapped keys the legacy mapper is about to see (bounded), so shadow can replay them.
  SELECT s.select_sql INTO v_sel FROM public.event_mapper_surface_sql(p_surface, coalesce(p_horizon_days, 180)) s;
  IF v_mode = 'shadow' THEN
    EXECUTE format('SELECT coalesce(array_agg(q.row_key), ''{}''::text[]) FROM (SELECT row_key FROM (%s) q WHERE q.previous IS NULL ORDER BY q.ord DESC NULLS LAST LIMIT 2000) q', v_sel) INTO v_keys;
  END IF;

  -- The legacy mapper, exactly as its cron called it.
  CASE p_surface
    WHEN 's4kcs_orders'        THEN SELECT jsonb_agg(to_jsonb(t)) INTO v_legacy FROM public.s4kcs_map_events() t;
    WHEN 'n2s_items'           THEN SELECT jsonb_agg(to_jsonb(t)) INTO v_legacy FROM public.n2s_map_events(true) t;
    WHEN 'gotickets_event'     THEN
      v_legacy := jsonb_build_object('gt_map_events', public.gt_map_events(coalesce(p_horizon_days, 120)));
      IF p_horizon_days IS NOT NULL AND p_horizon_days > 180 THEN
        SELECT v_legacy || jsonb_build_object('match_gotickets_us_events', to_jsonb(t)) INTO v_legacy FROM public.match_gotickets_us_events(3000, p_horizon_days, 0.80, true) t;
      ELSE
        SELECT v_legacy || jsonb_build_object('match_gotickets_us_events', to_jsonb(t)) INTO v_legacy FROM public.match_gotickets_us_events(1500, 180, 0.80, true) t;
      END IF;
    WHEN 'sg_events_canonical' THEN SELECT to_jsonb(t) INTO v_legacy FROM public.auto_match_sg_canonical_v3() t;
    ELSE v_legacy := jsonb_build_object('legacy', 'none (AQ sweep :22 / backfill :40 own this surface)');
  END CASE;

  IF v_mode = 'shadow' AND coalesce(array_length(v_keys, 1), 0) > 0 THEN
    -- Replay the same rows through the resolver (identity OFF — the hub must not answer for
    -- what the legacy mapper just wrote) and log the verdict; write nothing.
    -- m.previous is the value AFTER the legacy mapper ran (the key set was snapshotted before).
    INSERT INTO public.event_mapper_shadow_log (surface, row_key, legacy_tevo, resolver_tevo, method, score, verdict)
    SELECT p_surface, m.row_key, m.previous, m.tevo_event_id, m.method, m.score,
           CASE WHEN m.previous IS NOT NULL AND m.tevo_event_id = m.previous THEN 'agree'
                WHEN m.previous IS NOT NULL AND m.tevo_event_id IS NOT NULL  THEN 'disagree'
                WHEN m.previous IS NULL     AND m.tevo_event_id IS NOT NULL  THEN 'resolver_only'
                ELSE 'legacy_only' END
      FROM public.event_mapper_map_surface(p_surface, false, 2000, v_keys) m
     WHERE m.previous IS NOT NULL OR m.tevo_event_id IS NOT NULL;
    SELECT count(*) FILTER (WHERE verdict = 'agree'), count(*) FILTER (WHERE verdict = 'disagree'),
           count(*) FILTER (WHERE verdict = 'resolver_only'), count(*) FILTER (WHERE verdict = 'legacy_only')
      INTO v_agree, v_dis, v_ronly, v_lonly
      FROM public.event_mapper_shadow_log WHERE surface = p_surface AND at > now() - interval '1 minute';
  END IF;

  RETURN jsonb_build_object('surface', p_surface, 'mode', v_mode, 'legacy', v_legacy,
                            'shadow', jsonb_build_object('replayed', coalesce(array_length(v_keys, 1), 0), 'agree', v_agree,
                                                         'disagree', v_dis, 'resolver_only', v_ronly, 'legacy_only', v_lonly));
END $fn$;
REVOKE ALL ON FUNCTION public.event_mapper_run(text, int) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.event_mapper_run(text, int) TO service_role;
COMMENT ON FUNCTION public.event_mapper_run(text, int) IS
  'The ONE mapper entry point every cron calls. Dispatches on event_mapper_switch.mode: legacy → old mapper; shadow → old mapper writes + resolver replay logged (dry run); live → resolver writes + cross-maps. A1 mig 20260911210000.';

-- ── 6. Dry-run readout ───────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.event_mapper_shadow_report(p_surface text, p_since interval DEFAULT interval '7 days')
RETURNS TABLE(surface text, mode text, rows_logged bigint, agree bigint, disagree bigint, resolver_only bigint, legacy_only bigint,
              agreement_pct numeric, disagreements jsonb, resolver_only_samples jsonb)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $fn$
  WITH l AS (SELECT DISTINCT ON (row_key) * FROM public.event_mapper_shadow_log
              WHERE surface = p_surface AND at > now() - p_since ORDER BY row_key, at DESC)
  SELECT p_surface, (SELECT mode FROM public.event_mapper_switch WHERE surface = p_surface),
         count(*), count(*) FILTER (WHERE verdict = 'agree'), count(*) FILTER (WHERE verdict = 'disagree'),
         count(*) FILTER (WHERE verdict = 'resolver_only'), count(*) FILTER (WHERE verdict = 'legacy_only'),
         round(100.0 * count(*) FILTER (WHERE verdict = 'agree') / nullif(count(*) FILTER (WHERE verdict IN ('agree', 'disagree')), 0), 1),
         coalesce((SELECT jsonb_agg(jsonb_build_object('row_key', row_key, 'legacy', legacy_tevo, 'resolver', resolver_tevo, 'method', method, 'score', score))
                     FROM (SELECT * FROM l WHERE verdict = 'disagree' ORDER BY at DESC LIMIT 15) d), '[]'::jsonb),
         coalesce((SELECT jsonb_agg(jsonb_build_object('row_key', row_key, 'resolver', resolver_tevo, 'method', method, 'score', score))
                     FROM (SELECT * FROM l WHERE verdict = 'resolver_only' ORDER BY at DESC LIMIT 10) d), '[]'::jsonb)
    FROM l;
$fn$;
REVOKE ALL ON FUNCTION public.event_mapper_shadow_report(text, interval) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.event_mapper_shadow_report(text, interval) TO service_role;
COMMENT ON FUNCTION public.event_mapper_shadow_report(text, interval) IS
  'The dry-run readout for one surface: latest verdict per row from event_mapper_shadow_log (agree / disagree / resolver_only / legacy_only) + samples. Flip a surface to live only when disagree ≈ 0. A1 mig 20260911210000.';

-- ── 7. our_purchases_map() → the one entry point ─────────────────────────────
CREATE OR REPLACE FUNCTION public.our_purchases_map()
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $fn$
DECLARE v_gt jsonb; v_sg jsonb;
BEGIN
  IF current_user NOT IN ('service_role', 'postgres', 'supabase_admin') THEN
    RAISE EXCEPTION 'forbidden: %', current_user USING ERRCODE = '42501';
  END IF;
  v_gt := public.event_mapper_run('gotickets_purchases');
  v_sg := public.event_mapper_run('seatgeek_purchases');
  RETURN jsonb_build_object(
    'gt_mapped_now', coalesce((v_gt->>'mapped')::int, 0), 'sg_mapped_now', coalesce((v_sg->>'mapped')::int, 0),
    'gt_unmapped', (SELECT count(*) FROM public.gotickets_purchases WHERE tevo_event_id IS NULL),
    'sg_unmapped', (SELECT count(*) FROM public.seatgeek_purchases WHERE tevo_event_id IS NULL),
    'runs', jsonb_build_array(v_gt, v_sg));
END $fn$;
COMMENT ON FUNCTION public.our_purchases_map() IS
  'v3: event_mapper_run(''gotickets_purchases'') + (''seatgeek_purchases'') — mode-dispatched (both seeded live), fill-only, cross-mapped. A1 mig 20260911210000.';

-- ── 8. Re-point the mapper crons at the one entry point (jobnames + schedules unchanged) ──
-- Previous commands (for rollback):
--   s4kcs_map_events_10min   : SELECT public.s4kcs_map_events();
--   n2s_map_events_5min      :  SELECT public.n2s_order_identity_pull(); SELECT public.n2s_map_events(true); SELECT public.n2s_gt_map_by_name(); SELECT public.n2s_pull_all_sources();
--   gt_map_events_hourly     : SELECT public.gt_map_events();
--   gt_map_events_wide_daily : SELECT public.gt_map_events(3650); SELECT public.match_gotickets_us_events(3000, 3650, 0.80, true);
--   gotickets_match_us_6h    : BEGIN; SET LOCAL statement_timeout='90s'; DO $b$ … PERFORM public.match_gotickets_us_events(p_max => 1500, p_horizon_days => 180, p_min_score => 0.80, p_apply => true); … COMMIT;
--   auto_match_sg_canonical_v3_hourly (inactive) : DO $body$ … PERFORM public.auto_match_sg_canonical_v3(); …
--   our_purchases_map_hourly : (mig 20260911200100) PERFORM public.our_purchases_map();
DO $cron$
DECLARE r record;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN RETURN; END IF;
  FOR r IN
    SELECT jobid, jobname FROM cron.job
     WHERE jobname IN ('s4kcs_map_events_10min', 'n2s_map_events_5min', 'gt_map_events_hourly', 'gt_map_events_wide_daily',
                       'gotickets_match_us_6h', 'auto_match_sg_canonical_v3_hourly')
  LOOP
    PERFORM cron.alter_job(r.jobid, command := CASE r.jobname
      WHEN 's4kcs_map_events_10min'   THEN $c$SET statement_timeout='170s'; SELECT public.event_mapper_run('s4kcs_orders');$c$
      WHEN 'n2s_map_events_5min'      THEN $c$ SELECT public.n2s_order_identity_pull(); SELECT public.event_mapper_run('n2s_items'); SELECT public.n2s_gt_map_by_name(); SELECT public.n2s_pull_all_sources(); $c$
      WHEN 'gt_map_events_hourly'     THEN $c$SET statement_timeout='170s'; SELECT public.event_mapper_run('gotickets_event');$c$
      WHEN 'gt_map_events_wide_daily' THEN $c$SET statement_timeout='170s'; SELECT public.event_mapper_run('gotickets_event', 3650);$c$
      WHEN 'gotickets_match_us_6h'    THEN $c$DO $b$ BEGIN IF NOT public.cron_should_fire('gotickets_match_us_6h') THEN RETURN; END IF; PERFORM public.event_mapper_run('gotickets_event'); END $b$;$c$
      WHEN 'auto_match_sg_canonical_v3_hourly' THEN $c$DO $body$ BEGIN IF NOT public.cron_should_fire('auto_match_sg_canonical_v3_hourly') THEN RETURN; END IF; PERFORM public.event_mapper_run('sg_events_canonical'); END $body$;$c$
      END);
  END LOOP;
END;
$cron$;

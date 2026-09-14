-- Migration 20260911040000 · level:secondary-sales · lane:D7 · writes:n2s_items · reads:evo_orders,gotickets_sales,gotickets_event,vivid_orders,seatgeek_orders,seatgeek_event_xref,aq_event_map · pre:20260910180000
--
-- Already applied to prod · via MCP 2026-09-11 under operator direction.
-- ============================================================================
-- Migration 20260911040000 — N2S mapper: identity from the marketplace books
--                            we ingest directly (EVO, GoTickets, Vivid, SeatGeek)
--
-- Lane:     D7 · Pre-reqs: 20260910180000 (rule 0 / rule 5), 20260910040000
--           (n2s_order_key = the EVO split), 20260911020000 (cron 598 command)
-- Touches:  n2s_map_events() — four identity rules inserted right after rule 0.
--           Rules 1-5 unchanged. No new cron; cron 598 already runs this.
--
-- READ-ONLY upstream: pure joins over tables we already hold. RULE 2 untouched.
--
-- Operator 2026-09-11: "for orders where we are also ingesting straight from
-- marketplace source use eventid to map faster".
--
-- ── WHAT WAS TRUE BEFORE ───────────────────────────────────────────────────
-- Rule 0 (20260910180000) maps by order identity, but only through the CRM
-- marketplace book (s4kcs_orders). Two marketplaces reach this database by a
-- SECOND, direct road — our own seller-side ingest — and the mapper ignored
-- both, so their obligations fell through to name/date/venue inference:
--
--   EVO       evo_orders carries tevo_event_id on every processed order.
--             EVO orders are in NO CRM feed (20260910000000), so rule 0 can
--             never see them. The 22 live EVO obligations were mapped by
--             inference (11 name+date+venue, 4 GT alias, 1 venue+date) or not
--             at all (6).
--   GoTickets gotickets_sales carries gt_event_id, GT's OWN event id, which
--             gotickets_event already resolves to a tevo id (gt_map_events /
--             n2s_gt_map_by_name). That is an event-id path, not a name path.
--
-- Measured 2026-09-11 on the full n2s_items book before writing this:
--   EVO       evo_orders.evo_order_id = n2s_order_key  -> 22/22 rows found,
--             20 carry a tevo id, 4 currently unmapped become mapped,
--             0 disagreements in 16 overlaps with rules 1-5.
--   GoTickets gotickets_sales.gt_sale_id = order_number -> 6/49 found, 5 carry
--             a GT event id that resolves, 0 disagreements in 5 overlaps.
--             (gt_order_item_id was also tried: 1 hit, 1 DISAGREEMENT — not
--             the order key. Left out.)
--   Vivid     vivid_orders.vivid_order_id = order_number -> 0 of 117 TODAY,
--             but not because the road is missing: the pull is status-filtered
--             (cron 207 fires vivid_orders_queue_multi('PENDING_SHIPMENT') only)
--             and the 117 N2S orders are in some other Vivid status — 867 of
--             our rows sit inside the N2S id range, neighbours of the N2S ids
--             (81410832/81410849 around N2S 81410869), the N2S ids themselves
--             absent even from raw. Widening the pull is an A1 ingest change;
--             the rule is wired now so it starts working the tick that lands.
--   SeatGeek  seatgeek_orders.sg_order_id = order_number -> 0 of 16 TODAY,
--             because the SellerDirect pull fetches PAGE 1 of each status,
--             ascending by creation: the 400 rows we hold are from 2019-2025
--             (confirmed total 6,633 / fulfilled 582,238 upstream). Fixed by
--             20260911080000 (tail-page pull). Rule wired now, same reason.
--   TickPick  tickpick_orders -> 0 of 107; that ingest stopped 2026-05-31
--             (cron OFF, RESOURCES_BIBLE §5). No rule: nothing to read yet.
--   StubHub / Gametime reach us only through the CRM book (rule 0, 92%).
-- "Overlap" = rows both the new rule and an existing rule can map, used as the
-- correctness check: the new rule must agree everywhere it can be compared.
--
-- ── THE RULES ──────────────────────────────────────────────────────────────
-- Rule 0b  n2s_evo_order_identity   evo_orders.evo_order_id = n2s_order_key
-- Rule 0c  n2s_gt_order_identity    gotickets_sales.gt_sale_id = order_number
--                                   -> gt_event_id -> gotickets_event, else the
--                                   hub (aq_event_map.gotickets_event_id);
--                                   unique-or-decline across the sale's rows
-- Rule 0d  n2s_vivid_order_identity vivid_orders.vivid_order_id = order_number
--                                   -> tevo id from the row, else the hub on
--                                   raw.productionId (= aq_event_map.vivid_event_id)
-- Rule 0e  n2s_sg_order_identity    seatgeek_orders.sg_order_id = order_number
--                                   -> tevo id from the order row, else its
--                                   sg_event_id through seatgeek_event_xref,
--                                   else the hub; unique-or-decline
-- Keys are compared as TEXT on purpose: a ::bigint cast on the N2S side would
-- depend on the planner evaluating a regex guard first, which Postgres does not
-- promise. The books are 4.7k / 10k rows — a text compare costs nothing.
-- Both run immediately after rule 0 and before any inference, for the reason
-- 20260910180000 gives: identity beats inference, so no name guard should get
-- a chance to disagree with an order we already hold. Both are fill-only
-- (tevo_event_id IS NULL) and skip terminal rows, like every other rule.
--
-- "Faster" here is not cron cadence — cron 598 already runs every minute. It
-- is that an EVO obligation maps on its FIRST tick from a key we hold, instead
-- of waiting for a name/date/venue match that may never come (6 of 22 never
-- did). Anchored self-asserting edit; refuses a drifted body and a re-run.
-- ============================================================================

DO $do$
DECLARE d text; n text;
BEGIN
  d := pg_get_functiondef('public.n2s_map_events(boolean)'::regprocedure);

  IF position('n2s_evo_order_identity' in d) > 0 THEN
    RAISE EXCEPTION 'n2s_map_events already carries rule 0b — 20260911040000 is applied; do not re-run';
  END IF;

  n := E'  DROP TABLE IF EXISTS _m;\n';
  IF (length(d) - length(replace(d, n, ''))) / length(n) <> 1 THEN
    RAISE EXCEPTION 'anchor (DROP TABLE IF EXISTS _m) not found exactly once — body drifted, re-derive this migration';
  END IF;

  d := replace(d, n,
    E'  -- Rule 0b: the SAME ORDER is in our own EVO seller book (20260911040000).\n' ||
    E'  -- n2s_order_key is the EVO split (part 2 of "8046287-19081243").\n' ||
    E'  IF p_apply THEN\n' ||
    E'    UPDATE public.n2s_items n\n' ||
    E'       SET tevo_event_id = o.tevo_event_id, mapped_via = ''n2s_evo_order_identity''\n' ||
    E'      FROM public.evo_orders o\n' ||
    E'     WHERE n.s4k_source = ''EVO''\n' ||
    E'       AND o.evo_order_id::text = n.n2s_order_key\n' ||
    E'       AND o.tevo_event_id IS NOT NULL\n' ||
    E'       AND n.tevo_event_id IS NULL\n' ||
    E'       AND NOT n.is_terminal;\n' ||
    E'    GET DIAGNOSTICS v_n = ROW_COUNT; v_mapped := v_mapped + v_n;\n' ||
    E'\n' ||
    E'    -- Rule 0c: the SAME SALE is in our GoTickets sales feed. Its gt_event_id\n' ||
    E'    -- resolves through gotickets_event (the GT mappers) or, failing that, the\n' ||
    E'    -- hub (aq_event_map.gotickets_event_id). Unique-or-decline across both.\n' ||
    E'    UPDATE public.n2s_items n\n' ||
    E'       SET tevo_event_id = s.eid, mapped_via = ''n2s_gt_order_identity''\n' ||
    E'      FROM (SELECT n2.n2s_id, min(coalesce(g.tevo_event_id, a.tevo_event_id)) AS eid\n' ||
    E'              FROM public.n2s_items n2\n' ||
    E'              JOIN public.gotickets_sales gs ON gs.gt_sale_id::text = n2.order_number\n' ||
    E'              LEFT JOIN public.gotickets_event g ON g.gt_event_id = gs.gt_event_id\n' ||
    E'              LEFT JOIN public.aq_event_map a ON a.gotickets_event_id = gs.gt_event_id\n' ||
    E'                                             AND a.tevo_event_id IS NOT NULL\n' ||
    E'             WHERE n2.s4k_source = ''GoTickets''\n' ||
    E'               AND n2.tevo_event_id IS NULL AND NOT n2.is_terminal\n' ||
    E'             GROUP BY n2.n2s_id\n' ||
    E'            HAVING count(DISTINCT coalesce(g.tevo_event_id, a.tevo_event_id)) = 1) s\n' ||
    E'     WHERE n.n2s_id = s.n2s_id AND n.tevo_event_id IS NULL;\n' ||
    E'    GET DIAGNOSTICS v_n = ROW_COUNT; v_mapped := v_mapped + v_n;\n' ||
    E'\n' ||
    E'    -- Rule 0d: the SAME ORDER is in our own Vivid broker-order pull. The tevo\n' ||
    E'    -- id comes from the order row, else from the hub on Vivid''s production id\n' ||
    E'    -- (raw.productionId = aq_event_map.vivid_event_id; measured 2,533 agree /\n' ||
    E'    -- 2 disagree against the AQ-name path). Unique-or-decline.\n' ||
    E'    UPDATE public.n2s_items n\n' ||
    E'       SET tevo_event_id = s.eid, mapped_via = ''n2s_vivid_order_identity''\n' ||
    E'      FROM (SELECT n2.n2s_id, min(coalesce(o.tevo_event_id, a.tevo_event_id)) AS eid\n' ||
    E'              FROM public.n2s_items n2\n' ||
    E'              JOIN public.vivid_orders o ON o.vivid_order_id = n2.order_number\n' ||
    E'              LEFT JOIN public.aq_event_map a\n' ||
    E'                     ON o.raw->>''productionId'' ~ ''^[0-9]+$''\n' ||
    E'                    AND a.vivid_event_id = (o.raw->>''productionId'')::bigint\n' ||
    E'                    AND a.tevo_event_id IS NOT NULL\n' ||
    E'             WHERE n2.s4k_source = ''Vivid Seats''\n' ||
    E'               AND n2.tevo_event_id IS NULL AND NOT n2.is_terminal\n' ||
    E'             GROUP BY n2.n2s_id\n' ||
    E'            HAVING count(DISTINCT coalesce(o.tevo_event_id, a.tevo_event_id)) = 1) s\n' ||
    E'     WHERE n.n2s_id = s.n2s_id AND n.tevo_event_id IS NULL;\n' ||
    E'    GET DIAGNOSTICS v_n = ROW_COUNT; v_mapped := v_mapped + v_n;\n' ||
    E'\n' ||
    E'    -- Rule 0e: the SAME ORDER is in our SeatGeek SellerDirect order pull. The\n' ||
    E'    -- tevo id comes from the order row, else its sg_event_id through the xref,\n' ||
    E'    -- else the hub. Unique-or-decline: two candidate tevo ids = no mapping.\n' ||
    E'    UPDATE public.n2s_items n\n' ||
    E'       SET tevo_event_id = s.eid, mapped_via = ''n2s_sg_order_identity''\n' ||
    E'      FROM (SELECT n2.n2s_id, min(coalesce(o.tevo_event_id, x.tevo_event_id, a.tevo_event_id)) AS eid\n' ||
    E'              FROM public.n2s_items n2\n' ||
    E'              JOIN public.seatgeek_orders o ON o.sg_order_id = n2.order_number\n' ||
    E'              LEFT JOIN public.seatgeek_event_xref x ON x.sg_event_id = o.sg_event_id\n' ||
    E'              LEFT JOIN public.aq_event_map a ON a.sg_event_id = o.sg_event_id\n' ||
    E'                                             AND a.tevo_event_id IS NOT NULL\n' ||
    E'             WHERE n2.s4k_source = ''SeatGeek''\n' ||
    E'               AND n2.tevo_event_id IS NULL AND NOT n2.is_terminal\n' ||
    E'             GROUP BY n2.n2s_id\n' ||
    E'            HAVING count(DISTINCT coalesce(o.tevo_event_id, x.tevo_event_id, a.tevo_event_id)) = 1) s\n' ||
    E'     WHERE n.n2s_id = s.n2s_id AND n.tevo_event_id IS NULL;\n' ||
    E'    GET DIAGNOSTICS v_n = ROW_COUNT; v_mapped := v_mapped + v_n;\n' ||
    E'  END IF;\n' ||
    E'\n' || n);

  EXECUTE d;

  -- Self-check: both rules are in the live body, in order, before the inference block.
  d := pg_get_functiondef('public.n2s_map_events(boolean)'::regprocedure);
  IF position('n2s_evo_order_identity' in d) = 0 OR position('n2s_gt_order_identity' in d) = 0
     OR position('n2s_vivid_order_identity' in d) = 0 OR position('n2s_sg_order_identity' in d) = 0
     OR position('n2s_sg_order_identity' in d) > position('n2s_name_date_venue' in d) THEN
    RAISE EXCEPTION 'post-apply check failed: identity rules missing or not ahead of inference';
  END IF;
END $do$;

COMMENT ON FUNCTION public.n2s_map_events(boolean) IS
  'Map open N2S obligations to a tevo_event_id, fill-only and unique-or-decline. Order: rule 0 CRM order identity (s4kcs_orders) · 0b EVO order identity (evo_orders, via the n2s_order_key split, 20260911040000) · 0c GoTickets sale identity (gotickets_sales.gt_event_id -> gotickets_event) · 0d Vivid order identity (vivid_orders) · 0e SeatGeek order identity (seatgeek_orders, tevo id from the row / xref / hub) — all four 20260911040000 · 1 name+local date (+venue guard) · 2-4 venue+date (unique / session / name guard) · 5 GoTickets name alias. Identity rules run first because an order we already hold beats any inference. 0d/0e map nothing until the Vivid pull is widened beyond PENDING_SHIPMENT and the SeatGeek pull reaches current pages (20260911080000); TickPick ingest is off, so no rule. Run by cron 598 every minute; n2s_gt_map_by_name() and n2s_pull_all_sources() follow in the same command.';

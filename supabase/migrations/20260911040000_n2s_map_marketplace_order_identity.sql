-- Migration 20260911040000 · level:secondary-sales · lane:D7 · writes:n2s_items · reads:evo_orders,gotickets_sales,gotickets_event · pre:20260910180000
-- ============================================================================
-- Migration 20260911040000 — N2S mapper: identity from the marketplace books
--                            we ingest directly (EVO, GoTickets)
--
-- Lane:     D7 · Pre-reqs: 20260910180000 (rule 0 / rule 5), 20260910040000
--           (n2s_order_key = the EVO split), 20260911020000 (cron 598 command)
-- Touches:  n2s_map_events() — two identity rules inserted right after rule 0.
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
--   Vivid / TickPick / SeatGeek -> 0 of 117 / 107 / 16 in vivid_orders,
--             tickpick_orders, seatgeek_orders. Same finding as 20260910040000:
--             these are FAILED orders and the seller books hold only orders
--             that processed. There is no identity road for them; they stay on
--             rules 0-5 (the CRM book covers StubHub + Gametime at 92%).
-- "Overlap" = rows both the new rule and an existing rule can map, used as the
-- correctness check: the new rule must agree everywhere it can be compared.
--
-- ── THE RULES ──────────────────────────────────────────────────────────────
-- Rule 0b  n2s_evo_order_identity   evo_orders.evo_order_id = n2s_order_key
-- Rule 0c  n2s_gt_order_identity    gotickets_sales.gt_sale_id = order_number
--                                   -> gotickets_event.gt_event_id -> tevo id,
--                                   unique-or-decline across the sale's rows
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
    E'    -- Rule 0c: the SAME SALE is in our GoTickets sales feed, whose gt_event_id\n' ||
    E'    -- gotickets_event already resolves. Unique-or-decline across the sale''s rows.\n' ||
    E'    UPDATE public.n2s_items n\n' ||
    E'       SET tevo_event_id = s.eid, mapped_via = ''n2s_gt_order_identity''\n' ||
    E'      FROM (SELECT n2.n2s_id, min(g.tevo_event_id) AS eid\n' ||
    E'              FROM public.n2s_items n2\n' ||
    E'              JOIN public.gotickets_sales gs ON gs.gt_sale_id::text = n2.order_number\n' ||
    E'              JOIN public.gotickets_event g ON g.gt_event_id = gs.gt_event_id\n' ||
    E'                                           AND g.tevo_event_id IS NOT NULL\n' ||
    E'             WHERE n2.s4k_source = ''GoTickets''\n' ||
    E'               AND n2.tevo_event_id IS NULL AND NOT n2.is_terminal\n' ||
    E'             GROUP BY n2.n2s_id\n' ||
    E'            HAVING count(DISTINCT g.tevo_event_id) = 1) s\n' ||
    E'     WHERE n.n2s_id = s.n2s_id AND n.tevo_event_id IS NULL;\n' ||
    E'    GET DIAGNOSTICS v_n = ROW_COUNT; v_mapped := v_mapped + v_n;\n' ||
    E'  END IF;\n' ||
    E'\n' || n);

  EXECUTE d;

  -- Self-check: both rules are in the live body, in order, before the inference block.
  d := pg_get_functiondef('public.n2s_map_events(boolean)'::regprocedure);
  IF position('n2s_evo_order_identity' in d) = 0 OR position('n2s_gt_order_identity' in d) = 0
     OR position('n2s_evo_order_identity' in d) > position('n2s_name_date_venue' in d) THEN
    RAISE EXCEPTION 'post-apply check failed: identity rules missing or not ahead of inference';
  END IF;
END $do$;

COMMENT ON FUNCTION public.n2s_map_events(boolean) IS
  'Map open N2S obligations to a tevo_event_id, fill-only and unique-or-decline. Order: rule 0 CRM order identity (s4kcs_orders) · 0b EVO order identity (evo_orders, via the n2s_order_key split, 20260911040000) · 0c GoTickets sale identity (gotickets_sales.gt_event_id -> gotickets_event, 20260911040000) · 1 name+local date (+venue guard) · 2-4 venue+date (unique / session / name guard) · 5 GoTickets name alias. Identity rules run first because an order we already hold beats any inference. Vivid, TickPick and SeatGeek failed orders are in no book we hold (measured 0/117, 0/107, 0/16) and rely on the inference rules. Run by cron 598 every minute; n2s_gt_map_by_name() and n2s_pull_all_sources() follow in the same command.';

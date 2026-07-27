-- ============================================================
-- Durable matcher: reconcile split Knicks NBA-Finals home-game aq_event_map rows.
-- A1 2026-05-30. Companion to the immediate live re-link done for tevo 3346011.
--
-- PROBLEM: each Knicks Finals home game at MSG exists as TWO un-merged aq_event_map
-- records — a TEvo/SeatGeek-seeded row (`system_seed`: carries sg_event_id + tevo_event_id
-- + the Ticketmaster id) and a curated row (`aq_curated`, "...Home Game N...": carries the
-- StubHub + Vivid ids but sg_event_id / tevo_event_id NULL). The terminal RPC
-- get_event_td_listings resolves tevo -> sg_events_canonical -> aq_event_map.sg_event_id
-- -> aq_short_event_id -> ticketsdata_event_xref, so it can ONLY reach xref rows whose aq
-- row carries the SG id. The curated SH/VD rows (sg NULL) are unreachable -> StubHub and
-- Vivid show no data on the event page even though thousands of listings are being pulled.
--
-- FIX: for each curated Knicks-Finals MSG home-game row, find the matching TEvo event
-- (same venue + "Home Game N" number + NBA Finals) and its sg_event_id via
-- sg_events_canonical, then either:
--   (a) CONSOLIDATE — if a tevo/SG-anchored canonical aq row already exists for that SG id
--       (e.g. Game 1's SYS-* row), copy the SH/VD ids onto it, re-point the curated row's
--       xref to it, and mark the curated dup merged; or
--   (b) PROMOTE — if no canonical row exists (Games 2 & 3), attach sg_event_id +
--       tevo_event_id directly to the curated row so its existing xref resolves.
-- Idempotent + re-runnable -> safe to wire as a periodic self-heal cron (see tail note).
--
-- Validated dry-run (2026-05-30): hg1 77QZKV6 -> consolidate (SYS-9b0abcf107);
-- hg2 DQJ7ABK -> promote (tevo 3346012 / sg 18068096); hg3 9N9GB96 -> promote
-- (tevo 3346026 / sg 18068098). The stale "Eastern Conference Finals" SYS rows are
-- excluded by the '%NBA Finals%' filter.
--
-- OUT OF SCOPE (tracked separately):
--   * Game 4 (77QZKKO): no sg_events_canonical anchor (SG never wired tevo 3346028) ->
--     cannot resolve until SG side is wired; this fn correctly skips it.
--   * Gametime: no GT id exists in our maps for these games -> needs GT venue+date
--     discovery (separate path), or GT simply does not list a TBD-opponent placeholder.
--   * Ticketmaster: mapped + actively pulling but returns 0 listings (no upstream
--     inventory for a TBD-opponent placeholder) — nothing to fix our side.
-- ============================================================

CREATE OR REPLACE FUNCTION public.td_reconcile_knicks_finals_aq()
RETURNS TABLE(action text, home_game int, curated_aq text, target_aq text, tevo_id bigint, sg_id bigint)
LANGUAGE plpgsql
SET search_path TO 'public','pg_temp'
AS $function$
DECLARE r record;
BEGIN
  FOR r IN
    SELECT c.aq_short_event_id AS curated_aq, c.sh_event_id, c.vivid_event_id,
           ((regexp_match(c.event_name,'Home Game ([0-9]+)'))[1])::int AS hg,
           m.tevo_id, m.sg_id, m.canon_aq
    FROM public.aq_event_map c
    JOIN LATERAL (
      SELECT e.id AS tevo_id, sgc.sg_event_id AS sg_id,
             (SELECT a.aq_short_event_id FROM public.aq_event_map a
                WHERE a.sg_event_id = sgc.sg_event_id
                ORDER BY (a.tevo_event_id IS NOT NULL) DESC, a.aq_short_event_id LIMIT 1) AS canon_aq
      FROM public.events e
      JOIN public.sg_events_canonical sgc ON sgc.tevo_event_id = e.id
      WHERE e.venue_id = 896
        AND e.name ILIKE '%New York Knicks%' AND e.name ILIKE '%NBA Finals%'
        AND e.name ILIKE ('%Home Game ' || ((regexp_match(c.event_name,'Home Game ([0-9]+)'))[1]) || '%')
      ORDER BY e.id LIMIT 1
    ) m ON true
    WHERE c.aq_source = 'aq_curated'
      AND c.venue_name = 'Madison Square Garden'
      AND c.event_name ILIKE '%New York Knicks%' AND c.event_name ILIKE '%NBA Finals%'
      AND c.sh_event_id IS NOT NULL
      AND (c.sg_event_id IS NULL OR c.tevo_event_id IS NULL)
  LOOP
    IF r.canon_aq IS NOT NULL AND r.canon_aq <> r.curated_aq THEN
      -- (a) a tevo/SG-anchored canonical row exists: consolidate ids + xref onto it
      UPDATE public.aq_event_map
        SET sh_event_id    = COALESCE(sh_event_id, r.sh_event_id),
            vivid_event_id = COALESCE(vivid_event_id, r.vivid_event_id)
        WHERE aq_short_event_id = r.canon_aq;
      UPDATE public.ticketsdata_event_xref
        SET aq_short_event_id = r.canon_aq, updated_at = now()
        WHERE aq_short_event_id = r.curated_aq AND platform IN ('SH','VD','TP','GT','TM');
      -- mark the curated dup merged: excludes it from future runs + clears the dup ids
      UPDATE public.aq_event_map
        SET tevo_event_id = r.tevo_id, sh_event_id = NULL, vivid_event_id = NULL
        WHERE aq_short_event_id = r.curated_aq;
      action := 'consolidated'; target_aq := r.canon_aq;
    ELSE
      -- (b) no canonical row: promote the curated row by attaching sg + tevo
      UPDATE public.aq_event_map
        SET sg_event_id = r.sg_id, tevo_event_id = r.tevo_id
        WHERE aq_short_event_id = r.curated_aq;
      action := 'promoted'; target_aq := r.curated_aq;
    END IF;
    home_game := r.hg; curated_aq := r.curated_aq; tevo_id := r.tevo_id; sg_id := r.sg_id;
    RETURN NEXT;
  END LOOP;
END $function$;

-- Maintenance fn — not part of the anon-callable surface.
REVOKE ALL ON FUNCTION public.td_reconcile_knicks_finals_aq() FROM anon, PUBLIC;

-- Run once on apply (idempotent).
DO $do$
DECLARE n int;
BEGIN
  SELECT count(*) INTO n FROM public.td_reconcile_knicks_finals_aq();
  RAISE NOTICE 'td_reconcile_knicks_finals_aq: reconciled % curated row(s)', n;
END $do$;

-- OPTIONAL self-heal cron (operator-gated; left commented — enable if curated rows recur):
-- SELECT cron.schedule('td-reconcile-knicks-finals-daily', '20 10 * * *',
--   $$SELECT public.td_reconcile_knicks_finals_aq();$$);

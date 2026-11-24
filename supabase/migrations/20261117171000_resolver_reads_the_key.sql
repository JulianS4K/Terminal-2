-- Migration 20261117171000 · level:data-collection · lane:A1 (data plane — mapping program) · writes:event_mapper_identity()(redefined),event_key_identity()(new) · reads:event_xmap,event_xmap_alias,espn_ticket_game + the resolver's sources · pre:20261117170000
--
-- MAPPING PROGRAM — THE RESOLVER READS THE INTERNAL KEY.
--
-- The lanes resolve a listing through event_mapper_identity(source, id) -> (tevo_event_id, method): each source's own
-- verified match first, the hub second. Two additions (mig 20261117170000 made the spine's row id the internal key):
--   'espn' is a source: a game ESPN lists resolves through espn_ticket_match's EVO match (identity_espn_game).
--   the key is the last word: a listing in a spine cluster whose EVO id came from ANOTHER source's verified match
--   (a Vivid production whose TickPick sibling the TickPick mapper matched; a GoTickets row the spine attached to an
--   ESPN game that has the EVO event) resolves to that EVO id (identity_spine) — the derived link the spine was
--   built to show, read where it is needed instead of written back into every catalogue.
-- event_key_identity(source, id) is the key-first form the lanes move to: the internal key (always, when the listing
-- is known to the spine), the EVO id when the cluster has one, and how. A listing with a key and no EVO id is an event
-- we know and EVO does not list — a real answer, where the EVO-keyed resolver had none. RULE 2: nothing upstream.

BEGIN;
SET LOCAL lock_timeout = '10s';

CREATE OR REPLACE FUNCTION public.event_mapper_identity(p_source text, p_source_event_id bigint)
 RETURNS TABLE(tevo_event_id bigint, method text)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE v_src text := lower(trim(coalesce(p_source, ''))); v_tevo bigint; v_meth text;
BEGIN
  IF current_user NOT IN ('service_role', 'postgres', 'supabase_admin') THEN
    RAISE EXCEPTION 'forbidden: %', current_user USING ERRCODE = '42501';
  END IF;
  IF p_source_event_id IS NULL THEN RETURN; END IF;

  IF v_src IN ('tevo', 'evo') THEN
    tevo_event_id := p_source_event_id; method := 'identity_tevo'; RETURN NEXT; RETURN;
  ELSIF v_src IN ('gotickets', 'gt') THEN
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
    -- mig 20261117100000: the MLB ticketing schedule first — a game the schedule ties to this SeatGeek id names
    -- the EVO event with the authority of the league's own back end (mlb_ticket_map() verifies it every hour);
    -- SeatGeek's own link named another EVO event on 137 games and was wrong on 134 of them (mig 20261117000000)
    SELECT g.tevo_event_id INTO v_tevo FROM public.mlb_ticket_game g
     WHERE g.sg_event_id = p_source_event_id AND g.tevo_event_id IS NOT NULL AND g.removed_at IS NULL
     ORDER BY g.tevo_matched_at DESC NULLS LAST LIMIT 1;
    IF v_tevo IS NOT NULL THEN v_meth := 'identity_mlb_schedule'; END IF;
    IF v_tevo IS NULL THEN
      SELECT c.tevo_event_id INTO v_tevo FROM public.sg_events_canonical c
       WHERE c.sg_event_id = p_source_event_id AND c.tevo_event_id IS NOT NULL LIMIT 1;
      IF v_tevo IS NOT NULL THEN v_meth := 'identity_sg_canonical'; END IF;
    END IF;
    IF v_tevo IS NULL THEN
      SELECT a.tevo_event_id INTO v_tevo FROM public.aq_event_map a
       WHERE a.sg_event_id = p_source_event_id AND a.tevo_event_id IS NOT NULL
       ORDER BY (a.aq_source = 'aq_curated') DESC, a.imported_at DESC LIMIT 1;
      IF v_tevo IS NOT NULL THEN v_meth := 'identity_hub'; END IF;
    END IF;
  ELSIF v_src IN ('tickpick', 'tp') THEN
    -- mig 20261117080000: the TickPick catalogue's verified match first, the hub second
    SELECT c.tevo_event_id INTO v_tevo FROM public.tickpick_catalog_event c
     WHERE c.tp_event_id = p_source_event_id AND c.tevo_event_id IS NOT NULL LIMIT 1;
    IF v_tevo IS NOT NULL THEN v_meth := 'identity_tickpick_catalog'; END IF;
    IF v_tevo IS NULL THEN
      SELECT a.tevo_event_id INTO v_tevo FROM public.aq_event_map a
       WHERE a.tp_event_id = p_source_event_id AND a.tevo_event_id IS NOT NULL
       ORDER BY (a.aq_source = 'aq_curated') DESC, a.imported_at DESC LIMIT 1;
      IF v_tevo IS NOT NULL THEN v_meth := 'identity_hub'; END IF;
    END IF;
  ELSIF v_src IN ('vivid', 'vividseats', 'vivid seats') THEN
    -- mig 20261117080000: the Vivid catalogue (its eventId = the productionId on our orders) first, the hub second
    SELECT c.tevo_event_id INTO v_tevo FROM public.vivid_catalog_event c
     WHERE c.vivid_event_id = p_source_event_id AND c.tevo_event_id IS NOT NULL LIMIT 1;
    IF v_tevo IS NOT NULL THEN v_meth := 'identity_vivid_catalog'; END IF;
    IF v_tevo IS NULL THEN
      SELECT a.tevo_event_id INTO v_tevo FROM public.aq_event_map a
       WHERE a.vivid_event_id = p_source_event_id AND a.tevo_event_id IS NOT NULL
       ORDER BY (a.aq_source = 'aq_curated') DESC, a.imported_at DESC LIMIT 1;
      IF v_tevo IS NOT NULL THEN v_meth := 'identity_hub'; END IF;
    END IF;
  ELSIF v_src = 'espn' THEN
    -- mig 20261117171000: a game ESPN lists, matched to its EVO event by espn_ticket_match (mig 20261117160000)
    SELECT g.tevo_event_id INTO v_tevo FROM public.espn_ticket_game g
     WHERE g.espn_event_id = p_source_event_id::text AND g.tevo_event_id IS NOT NULL LIMIT 1;
    IF v_tevo IS NOT NULL THEN v_meth := 'identity_espn_game'; END IF;
  ELSIF v_src IN ('stubhub', 'sh', 'ticketmaster', 'tm', 'seatdata', 'sd') THEN
    SELECT a.tevo_event_id INTO v_tevo FROM public.aq_event_map a
     WHERE a.tevo_event_id IS NOT NULL
       AND ((v_src IN ('stubhub', 'sh')                      AND a.sh_event_id    = p_source_event_id)
         OR (v_src IN ('ticketmaster', 'tm')                 AND a.tm_event_id    = p_source_event_id)
         OR (v_src IN ('seatdata', 'sd')                     AND a.sd_event_id    = p_source_event_id))
     ORDER BY (a.aq_source = 'aq_curated') DESC, a.imported_at DESC LIMIT 1;
    IF v_tevo IS NOT NULL THEN v_meth := 'identity_hub'; END IF;
  END IF;

  -- mig 20261117171000: the internal event key last — the listing sits in a spine cluster (event_xmap) that another
  -- source's verified match tied to an EVO event; EVO is one source among the cluster's, read through the key
  IF v_tevo IS NULL THEN
    SELECT x.tevo_event_id INTO v_tevo FROM public.event_xmap x
     WHERE x.xmap_id = public.event_key_lookup(v_src, p_source_event_id) AND x.tevo_event_id IS NOT NULL;
    IF v_tevo IS NOT NULL THEN v_meth := 'identity_spine'; END IF;
  END IF;

  IF v_tevo IS NOT NULL THEN
    tevo_event_id := v_tevo; method := v_meth; RETURN NEXT;
  END IF;
  RETURN;
END $function$;

-- ───────────────────────── the key-first resolver ─────────────────────────
CREATE OR REPLACE FUNCTION public.event_key_identity(p_source text, p_source_event_id bigint)
 RETURNS TABLE(internal_event_id bigint, tevo_event_id bigint, method text)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE v_key bigint; v_tevo bigint; v_meth text;
BEGIN
  IF current_user NOT IN ('service_role', 'postgres', 'supabase_admin') THEN
    RAISE EXCEPTION 'forbidden: %', current_user USING ERRCODE = '42501';
  END IF;
  IF p_source_event_id IS NULL THEN RETURN; END IF;
  v_key := public.event_key_lookup(p_source, p_source_event_id);
  SELECT i.tevo_event_id, i.method INTO v_tevo, v_meth FROM public.event_mapper_identity(p_source, p_source_event_id) i LIMIT 1;
  -- an EVO id the resolver found names a cluster too (the EVO row of the spine), when the listing's own id is not in it yet
  IF v_key IS NULL AND v_tevo IS NOT NULL THEN
    v_key := public.event_key_lookup('tevo', v_tevo);
    IF v_key IS NOT NULL THEN v_meth := coalesce(v_meth, '') || '+key_via_tevo'; END IF;
  END IF;
  IF v_key IS NULL AND v_tevo IS NULL THEN RETURN; END IF;
  internal_event_id := v_key; tevo_event_id := v_tevo; method := coalesce(v_meth, 'key_only');
  RETURN NEXT;
END $function$;
COMMENT ON FUNCTION public.event_key_identity(text, bigint) IS
  'The key-first resolver (mig 20261117171000): a listing (source, id) -> its internal event key (event_xmap.xmap_id), the EVO id when the cluster has one, and how. A key with no EVO id is an event EVO does not list.';
REVOKE ALL ON FUNCTION public.event_key_identity(text, bigint), public.event_mapper_identity(text, bigint) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.event_key_identity(text, bigint), public.event_mapper_identity(text, bigint) TO service_role;

COMMIT;

-- VERIFY:
--   SELECT * FROM event_key_identity('vivid', 7419725);     -- key + EVO id (+ how)
--   SELECT method, count(*) FROM (SELECT (event_mapper_identity('vivid', c.vivid_event_id)).method FROM (SELECT vivid_event_id FROM vivid_catalog_event WHERE tevo_event_id IS NULL AND event_date BETWEEN current_date AND current_date + 60 LIMIT 2000) c) s GROUP BY 1;  -- how many unmatched Vivid rows the spine now resolves

-- tickets_dev_fill_outward was permanently starved, and it is the same failure this session
-- diagnosed on the Vivid surface a few hours earlier: a cap applied to an ORDERED list whose
-- head is already exhausted. Caught by the scheduled check-in, not by CI — the symptom is not a
-- failure, it is a job that succeeds every tick while doing nothing.
--
-- _td_gap ordered its candidates by event_date ASC and took LIMIT v_cap, and only THEN did
-- tickets_dev_probe_enqueue drop the ids it already knows. The oldest gap rows are exactly the
-- ones probed on the first run, so every subsequent tick re-picked the same ~150 suppressed ids
-- and enqueued nothing. Measured before the fix, four ticks in: 4,904 gap rows, 0 enqueued. The
-- other ~4,750 rows could never get a turn. After the fix: 150 enqueued, 3,990 askable
-- remaining, draining ~600/hour.
--
-- The guard has to be applied BEFORE the LIMIT, not after. tickets_dev_askable() single-sources
-- it so the selector and the enqueuer cannot drift apart again — the drift IS the bug: the
-- enqueuer knew which ids were spent and the selector did not.
--
-- fill_outward now also returns askable_remaining, so the same starvation is visible in the
-- return value next time instead of having to be inferred from flat coverage counters.

CREATE OR REPLACE FUNCTION public.tickets_dev_askable(p_marketplace text, p_id text)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $fn$
  SELECT p_id IS NOT NULL AND p_id <> ''
     AND NOT EXISTS (SELECT 1 FROM public.tickets_dev_source_id s
                      WHERE s.marketplace = p_marketplace AND s.source_event_id = p_id)
     -- a settled 'not_found' is re-askable after a week (catalogues backfill);
     -- 'source_not_indexed' is declared non-retryable upstream, so it is never asked again
     AND NOT EXISTS (SELECT 1 FROM public.tickets_dev_probe p
                      WHERE p.marketplace = p_marketplace AND p.source_event_id = p_id
                        AND (p.outcome IS NULL
                             OR p.outcome = 'source_not_indexed'
                             OR p.settled_at > now() - interval '7 days'));
$fn$;

REVOKE ALL ON FUNCTION public.tickets_dev_askable(text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.tickets_dev_askable(text, text) TO service_role;

COMMENT ON FUNCTION public.tickets_dev_askable(text, text) IS
  'Single source of truth for "may we probe this id?". MUST be applied before any LIMIT in a selector, or the cap lands on already-exhausted ids (mig 20260915011000).';

CREATE OR REPLACE FUNCTION public.tickets_dev_probe_enqueue(p_marketplace text, p_ids text[])
RETURNS int
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $fn$
DECLARE v_key text; v_n int := 0; v_id text; v_req bigint;
BEGIN
  IF current_user NOT IN ('service_role', 'postgres', 'supabase_admin') THEN
    RAISE EXCEPTION 'forbidden: %', current_user USING ERRCODE = '42501';
  END IF;
  IF p_marketplace IS NULL OR p_ids IS NULL THEN RETURN 0; END IF;

  SELECT decrypted_secret INTO v_key FROM vault.decrypted_secrets WHERE name = 'tickets.dev';
  IF v_key IS NULL THEN
    RAISE NOTICE 'tickets_dev: vault secret "tickets.dev" missing — nothing enqueued';
    RETURN 0;
  END IF;

  FOR v_id IN
    SELECT DISTINCT x FROM unnest(p_ids) x WHERE public.tickets_dev_askable(p_marketplace, x)
  LOOP
    v_req := net.http_get(
               url := 'https://api.tickets.dev/v1/events?source=' || p_marketplace
                      || '&eventId=' || v_id,
               headers := jsonb_build_object('x-api-key', v_key),
               timeout_milliseconds := 8000);
    INSERT INTO public.tickets_dev_probe (marketplace, source_event_id, req_id, requested_at, outcome, settled_at)
    VALUES (p_marketplace, v_id, v_req, now(), NULL, NULL)
    ON CONFLICT (marketplace, source_event_id)
      DO UPDATE SET req_id = excluded.req_id, requested_at = now(), outcome = NULL, settled_at = NULL;
    v_n := v_n + 1;
  END LOOP;
  RETURN v_n;
END $fn$;

REVOKE ALL ON FUNCTION public.tickets_dev_probe_enqueue(text, text[]) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.tickets_dev_probe_enqueue(text, text[]) TO service_role;

CREATE OR REPLACE FUNCTION public.tickets_dev_fill_outward(p_limit int DEFAULT 200)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $fn$
DECLARE v_cap int; v_g int := 0; v_v int := 0; v_s int := 0; v_gap int; v_ask int;
BEGIN
  IF current_user NOT IN ('service_role', 'postgres', 'supabase_admin') THEN
    RAISE EXCEPTION 'forbidden: %', current_user USING ERRCODE = '42501';
  END IF;
  v_cap := greatest(1, least(500, coalesce(p_limit, 200)));

  DROP TABLE IF EXISTS _td_gap;
  CREATE TEMP TABLE _td_gap ON COMMIT DROP AS
  SELECT a.tevo_event_id, a.gotickets_event_id, a.vivid_event_id, a.sh_event_id, a.tm_event_id, a.event_date
    FROM public.aq_event_map a
   WHERE a.tevo_event_id IS NOT NULL
     AND a.event_date >= current_date - 1
     AND num_nonnulls(a.gotickets_event_id, a.vivid_event_id, a.sh_event_id, a.tm_event_id) BETWEEN 1 AND 3;
  SELECT count(*) INTO v_gap FROM _td_gap;

  -- askable BEFORE the limit. This is the whole fix: without it the cap lands on the oldest
  -- ids, which are precisely the ones already probed, and nothing is ever enqueued again.
  SELECT public.tickets_dev_probe_enqueue('gotickets', array_agg(id)) INTO v_g FROM (
    SELECT DISTINCT gotickets_event_id::text AS id, min(event_date) AS d FROM _td_gap
     WHERE gotickets_event_id IS NOT NULL
       AND public.tickets_dev_askable('gotickets', gotickets_event_id::text)
     GROUP BY 1 ORDER BY 2 LIMIT v_cap) q;
  SELECT public.tickets_dev_probe_enqueue('vividseats', array_agg(id)) INTO v_v FROM (
    SELECT DISTINCT vivid_event_id::text AS id, min(event_date) AS d FROM _td_gap
     WHERE vivid_event_id IS NOT NULL AND gotickets_event_id IS NULL
       AND public.tickets_dev_askable('vividseats', vivid_event_id::text)
     GROUP BY 1 ORDER BY 2 LIMIT v_cap) q;
  SELECT public.tickets_dev_probe_enqueue('stubhub', array_agg(id)) INTO v_s FROM (
    SELECT DISTINCT sh_event_id::text AS id, min(event_date) AS d FROM _td_gap
     WHERE sh_event_id IS NOT NULL AND gotickets_event_id IS NULL AND vivid_event_id IS NULL
       AND public.tickets_dev_askable('stubhub', sh_event_id::text)
     GROUP BY 1 ORDER BY 2 LIMIT v_cap) q;

  -- how much askable work is left, so a future starvation is visible in the return value
  SELECT count(*) INTO v_ask FROM (
    SELECT gotickets_event_id::text AS id, 'gotickets' AS mk FROM _td_gap WHERE gotickets_event_id IS NOT NULL
    UNION ALL SELECT vivid_event_id::text, 'vividseats' FROM _td_gap WHERE vivid_event_id IS NOT NULL AND gotickets_event_id IS NULL
    UNION ALL SELECT sh_event_id::text, 'stubhub' FROM _td_gap WHERE sh_event_id IS NOT NULL AND gotickets_event_id IS NULL AND vivid_event_id IS NULL) z
   WHERE public.tickets_dev_askable(z.mk, z.id);

  RETURN jsonb_build_object('gap_rows', v_gap, 'askable_remaining', v_ask,
                            'enqueued', jsonb_build_object('gotickets', coalesce(v_g,0),
                                                           'vividseats', coalesce(v_v,0),
                                                           'stubhub', coalesce(v_s,0)));
END $fn$;

REVOKE ALL ON FUNCTION public.tickets_dev_fill_outward(int) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.tickets_dev_fill_outward(int) TO service_role;

COMMENT ON FUNCTION public.tickets_dev_fill_outward(int) IS
  'EVO -> all: probe tickets.dev with an id the hub already holds, to learn the sibling ids it does not. Returns askable_remaining so starvation is visible. GET-only (RULE 2). Mig 20260915011000.';

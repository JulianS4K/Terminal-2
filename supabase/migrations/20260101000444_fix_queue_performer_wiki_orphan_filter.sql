-- ============================================================================
-- B1 OPS-MED (bot_chat #259, active 90+min): performer_wiki_pending FK violation.
--
-- Problem: `queue_performer_wiki_searches(p_limit)` pulls events.primary_performer_id
-- candidates directly. FK `performer_wiki_pending.tevo_performer_id →
-- performer_metadata.performer_id` (NOT VALID) enforces on new inserts.
-- Events can reference performer_ids not yet ingested into performer_metadata
-- (R2 sequencing gap), so the cron crashes every :17/:47 firing.
--
-- Fix: add `EXISTS (SELECT 1 FROM performer_metadata WHERE performer_id = ...)`
-- to the queue-source WHERE clause. Skips orphans cleanly without altering
-- the FK semantics. Existing rows unaffected.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.queue_performer_wiki_searches(p_limit integer DEFAULT 50)
 RETURNS integer
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  r RECORD;
  v_req_id bigint;
  v_count int := 0;
BEGIN
  FOR r IN
    SELECT DISTINCT e.primary_performer_id AS pid, e.primary_performer_name AS pname
    FROM events e
    LEFT JOIN performer_wikipedia pw ON pw.tevo_performer_id = e.primary_performer_id
    LEFT JOIN performer_wiki_pending pwp
      ON pwp.tevo_performer_id = e.primary_performer_id
     AND pwp.fired_at > now() - interval '1 hour'
    WHERE e.primary_performer_id IS NOT NULL
      AND e.primary_performer_name IS NOT NULL
      AND pw.tevo_performer_id IS NULL
      AND pwp.tevo_performer_id IS NULL
      -- B1 #259 (2026-05-16): skip events whose performer hasn't been
      -- ingested into performer_metadata yet; the FK (NOT VALID) enforces
      -- on new inserts. Without this filter the cron crashes every 30 min.
      AND EXISTS (
        SELECT 1 FROM performer_metadata pm
        WHERE pm.performer_id = e.primary_performer_id
      )
    ORDER BY e.primary_performer_id
    LIMIT p_limit
  LOOP
    SELECT net.http_get(
      url := 'https://en.wikipedia.org/w/api.php',
      params := jsonb_build_object(
        'action', 'opensearch',
        'namespace', '0',
        'limit', '1',
        'format', 'json',
        'search', r.pname
      ),
      timeout_milliseconds := 10000
    ) INTO v_req_id;

    INSERT INTO performer_wiki_pending(
      tevo_performer_id, performer_name, stage, search_request_id, fired_at
    ) VALUES (r.pid, r.pname, 'search', v_req_id, now())
    ON CONFLICT (tevo_performer_id, stage) DO UPDATE SET
      search_request_id = EXCLUDED.search_request_id,
      fired_at = now(),
      resolved_at = NULL;

    v_count := v_count + 1;
    PERFORM pg_sleep(0.2);
  END LOOP;
  RETURN v_count;
END;
$function$;

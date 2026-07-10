-- Migration 20260709170000 · lane:D0 (author) → A1 (apply) · writes:axs_event_performer_xref,match_axs_events_to_performers,get_axs_performer_match_summary,cron(axs-performer-match) · reads:axs_event_snapshots,axs_performers,aq_performer_map · pre:none · auth:OPERATOR-APPROVAL REQUIRED before apply_migration (creates a table + cron + backfills)
--
-- D0 — AXS event → performer name-match job.
--
-- AXS events carry no structured performer field (the act is only in the event
-- name; axs_performers is an unlinked 130-artist seed list). This job bridges
-- the gap with a two-hop name match, so AXS inventory can attribute to a
-- performer:
--   1. AXS event name  →  axs_performers artist  (longest artist name that
--      appears in the title; ~87% of events hit).
--   2. AXS artist  →  canonical TEvo performer  (exact lower-name match against
--      aq_performer_map; ~53% of artists bridge — e.g. "Journey"→JOURNEY→5997).
--
-- Result per AXS event: its artist + optional tevo_performer_id. A tevo bridge
-- means the AXS event can fold into the canonical performer_stat_card; no bridge
-- = an AXS-only artist (tribute/regional acts like "Killer Queen"). Runs daily
-- (matching is stable; not latency-sensitive).

-- ============================================================
-- 1. Xref table
-- ============================================================
CREATE TABLE IF NOT EXISTS public.axs_event_performer_xref (
  axs_event_id      text PRIMARY KEY,
  event_name        text,
  axs_artist_id     text,
  axs_performer     text,
  tevo_performer_id bigint,          -- canonical bridge (nullable = AXS-only artist)
  match_method      text,            -- 'name_in_title+tevo_bridge' | 'name_in_title' | 'unmatched'
  matched_at        timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS axs_event_performer_xref_tevo_idx
  ON public.axs_event_performer_xref (tevo_performer_id) WHERE tevo_performer_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS axs_event_performer_xref_artist_idx
  ON public.axs_event_performer_xref (axs_artist_id);
ALTER TABLE public.axs_event_performer_xref ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.axs_event_performer_xref FROM anon, authenticated;

-- ============================================================
-- 2. Matcher
-- ============================================================
CREATE OR REPLACE FUNCTION public.match_axs_events_to_performers()
RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $func$
DECLARE
  v_n integer;
BEGIN
  WITH ev AS (
    SELECT DISTINCT ON (axs_event_id) axs_event_id, event_name
    FROM public.axs_event_snapshots
    WHERE event_name IS NOT NULL
    ORDER BY axs_event_id, captured_at DESC
  ),
  matched AS (
    SELECT ev.axs_event_id, ev.event_name, a.axs_artist_id, a.performer AS axs_performer,
      (SELECT q.tevo_performer_id FROM public.aq_performer_map q
       WHERE lower(q.performer_name) = lower(a.performer) LIMIT 1) AS tevo_performer_id
    FROM ev
    LEFT JOIN LATERAL (
      SELECT a2.axs_artist_id, a2.performer
      FROM public.axs_performers a2
      WHERE length(a2.performer) > 2 AND ev.event_name ILIKE '%'||a2.performer||'%'
      ORDER BY length(a2.performer) DESC
      LIMIT 1
    ) a ON true
  )
  INSERT INTO public.axs_event_performer_xref
    (axs_event_id, event_name, axs_artist_id, axs_performer, tevo_performer_id, match_method, matched_at)
  SELECT axs_event_id, event_name, axs_artist_id, axs_performer, tevo_performer_id,
    CASE WHEN axs_performer IS NULL           THEN 'unmatched'
         WHEN tevo_performer_id IS NOT NULL   THEN 'name_in_title+tevo_bridge'
         ELSE 'name_in_title' END,
    now()
  FROM matched
  ON CONFLICT (axs_event_id) DO UPDATE SET
    event_name = EXCLUDED.event_name, axs_artist_id = EXCLUDED.axs_artist_id,
    axs_performer = EXCLUDED.axs_performer, tevo_performer_id = EXCLUDED.tevo_performer_id,
    match_method = EXCLUDED.match_method, matched_at = now();

  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n;
END;
$func$;

REVOKE ALL ON FUNCTION public.match_axs_events_to_performers() FROM PUBLIC;

-- ============================================================
-- 3. Read RPC — match summary (gated)
-- ============================================================
CREATE OR REPLACE FUNCTION public.get_axs_performer_match_summary()
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, extensions, pg_temp
AS $func$
DECLARE
  v_email text; v_result jsonb;
BEGIN
  v_email := coalesce(auth.jwt()->>'email', '');
  IF v_email NOT LIKE '%@s4kent.com' THEN
    RAISE EXCEPTION 'forbidden: % is not an @s4kent.com email', v_email USING ERRCODE = '42501';
  END IF;
  SELECT jsonb_build_object(
    'total',        count(*),
    'bridged',      count(*) FILTER (WHERE tevo_performer_id IS NOT NULL),
    'artist_only',  count(*) FILTER (WHERE axs_performer IS NOT NULL AND tevo_performer_id IS NULL),
    'unmatched',    count(*) FILTER (WHERE axs_performer IS NULL),
    'by_method',    (SELECT jsonb_object_agg(match_method, n) FROM
                      (SELECT match_method, count(*) n FROM public.axs_event_performer_xref GROUP BY 1) q)
  ) INTO v_result FROM public.axs_event_performer_xref;
  RETURN v_result;
END;
$func$;

REVOKE ALL ON FUNCTION public.get_axs_performer_match_summary() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_axs_performer_match_summary() TO anon, authenticated;

-- ============================================================
-- 4. Backfill + daily cron
-- ============================================================
SELECT public.match_axs_events_to_performers();

DO $cron$
BEGIN
  PERFORM cron.unschedule('axs-performer-match');
EXCEPTION WHEN OTHERS THEN NULL;
END;
$cron$;

-- Daily 07:25 UTC — matching is stable, not latency-sensitive; avoids the
-- saturated :02/:05/:07 minute clusters.
SELECT cron.schedule('axs-performer-match', '25 7 * * *', $cron$
  SELECT public.match_axs_events_to_performers();
$cron$);

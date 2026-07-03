-- Migration 20260703014000 · level:standard · lane:broadway (D3) · writes:broadway_show_ref,broadway_cast_pull_log · reads: · pre:20260703013500
--
-- Daily cast-source poll for the cast-run overlay.
--
-- The cast overlay (broadway_cast_run) is a curated, cited feed. This adds a
-- once-a-day WATCH on the cast sites so the curation stays fresh without a
-- human re-checking every show by hand. The poll's job is CHANGE DETECTION,
-- not auto-authoring: it fetches each tracked show's Wikipedia cast section,
-- hashes it, and on a change logs the candidate cast + raises a bot_chat flag
-- for a human to confirm. The curated table stays authoritative — the poll
-- never overwrites it. (High-accuracy, low-volume data: a person confirms the
-- marquee, exactly like a curated injury report.)
--
-- Why Wikipedia: it is the one cast source that is automation-friendly from our
-- infra — the REST/parse API is open, rate-limit-free at this scale, and proven
-- by the existing wiki-collect function. IBDB / Playbill / BroadwayWorld 403
-- datacenter fetchers, so they stay in the human-curated path.
--
-- RULE 2: the edge function is GET-only against en.wikipedia.org.
-- RULE 1: cron.schedule + the edge-function deploy are Applier actions — this
--         file authors both; they arm on apply by A1. Idempotent.

-- ============================================================================
-- (1) broadway_show_ref — per-show cast-source config + freshness stamp
-- ============================================================================

ALTER TABLE public.broadway_show_ref
  ADD COLUMN IF NOT EXISTS cast_wiki_title    text,          -- Wikipedia article title to poll (NULL = not polled)
  ADD COLUMN IF NOT EXISTS cast_source_url    text,          -- canonical human cast page (for curators)
  ADD COLUMN IF NOT EXISTS cast_source_name   text,          -- 'Wikipedia' | 'IBDB' | 'Playbill' | …
  ADD COLUMN IF NOT EXISTS cast_last_polled_at timestamptz,
  ADD COLUMN IF NOT EXISTS cast_last_section_hash text;      -- last seen hash → change detection

COMMENT ON COLUMN public.broadway_show_ref.cast_wiki_title IS
  'Wikipedia article title the daily poll fetches (e.g. "Oh, Mary!"). NULL '
  'means the show is not auto-polled yet — its cast stays fully hand-curated.';

-- Seed the poll targets we are confident about (article titles verified).
-- Others stay NULL until a curator sets a title; the poll skips NULLs.
UPDATE public.broadway_show_ref SET
  cast_wiki_title = v.wiki, cast_source_name = 'Wikipedia',
  cast_source_url = 'https://en.wikipedia.org/wiki/' || replace(v.wiki, ' ', '_')
FROM (VALUES
  ('oh-mary',   'Oh, Mary!'),
  ('hamilton',  'Hamilton (musical)'),
  ('wicked',    'Wicked (musical)'),
  ('hadestown', 'Hadestown')
) AS v(slug, wiki)
WHERE broadway_show_ref.show_slug = v.slug;

-- ============================================================================
-- (2) broadway_cast_pull_log — per-poll diagnostic ledger + change record
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.broadway_cast_pull_log (
  id                bigserial   PRIMARY KEY,
  show_slug         text        NOT NULL,
  source            text        NOT NULL DEFAULT 'Wikipedia',
  wiki_title        text,
  http_status       integer,
  section_hash      text,                                   -- hash of the cast section this poll
  section_changed   boolean     NOT NULL DEFAULT false,     -- differs from broadway_show_ref.cast_last_section_hash
  candidates        jsonb       NOT NULL DEFAULT '[]'::jsonb, -- best-effort parsed {performer,dates} for human review — NEVER written to broadway_cast_run directly
  flag_raised       boolean     NOT NULL DEFAULT false,
  error_message     text,
  created_at        timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_bwy_cast_pull_show ON public.broadway_cast_pull_log (show_slug, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_bwy_cast_pull_changed ON public.broadway_cast_pull_log (created_at DESC) WHERE section_changed;

COMMENT ON TABLE public.broadway_cast_pull_log IS
  'Per-poll ledger for broadway-cast-collect. section_changed=true means the '
  'source cast section moved since last poll → a bot_chat flag is raised for a '
  'curator. candidates is advisory only (never auto-promoted into '
  'broadway_cast_run). 90-day retention via sweep_old_broadway_cast_pulls().';

-- retention sweep (90d — small rows, keep for change history)
CREATE OR REPLACE FUNCTION public.sweep_old_broadway_cast_pulls()
RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp
AS $$
DECLARE v_deleted integer;
BEGIN
  DELETE FROM public.broadway_cast_pull_log WHERE created_at < now() - interval '90 days';
  GET DIAGNOSTICS v_deleted = ROW_COUNT;
  RETURN v_deleted;
END;
$$;
REVOKE ALL ON FUNCTION public.sweep_old_broadway_cast_pulls() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.sweep_old_broadway_cast_pulls() TO service_role;

-- ============================================================================
-- (3) RLS
-- ============================================================================

ALTER TABLE public.broadway_cast_pull_log ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS broadway_cast_pull_log_read ON public.broadway_cast_pull_log;
CREATE POLICY broadway_cast_pull_log_read ON public.broadway_cast_pull_log
  FOR SELECT TO authenticated USING (true);

-- ============================================================================
-- (4) Daily cron — invoke broadway-cast-collect once a day
--     13:43 UTC (avoids the saturated :02/:05/:07 marks; 1 fire/day).
--     Uses the standard cron_should_fire gate + _cron_invoke_edge_fn wrapper.
--     ARMS ON APPLY (Applier / A1) — cron.schedule is a prod mutation.
-- ============================================================================

DO $body$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    PERFORM cron.schedule(
      'broadway_cast_collect_daily',
      '43 13 * * *',
      $cron$DO $cronbody$
      BEGIN
        IF NOT public.cron_should_fire('broadway_cast_collect_daily') THEN RETURN; END IF;
        PERFORM public._cron_invoke_edge_fn(
          'https://hzrizjeaxlqcxfrtczpq.supabase.co/functions/v1/broadway-cast-collect',
          '{}'::jsonb
        );
      END $cronbody$;$cron$
    );
  END IF;
END $body$;

INSERT INTO public.cron_policy (
  jobname, peak_hours_et, peak_min_interval_min, offpeak_min_interval_min,
  daily_max_fires, enabled, notes
) VALUES (
  'broadway_cast_collect_daily',
  '{}'::int[], 1440, 1440, 1, true,
  'Daily Wikipedia cast-section watch for tracked Broadway shows. Change '
  'detection + bot_chat flag on move; never auto-writes broadway_cast_run.'
) ON CONFLICT (jobname) DO UPDATE SET
  notes = EXCLUDED.notes, enabled = EXCLUDED.enabled, daily_max_fires = EXCLUDED.daily_max_fires,
  updated_at = now();

-- ============================================================================
-- DONE. Edge function: supabase/functions/broadway-cast-collect/index.ts
-- ============================================================================

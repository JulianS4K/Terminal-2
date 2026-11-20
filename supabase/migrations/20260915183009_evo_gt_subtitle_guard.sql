-- Migration 20260915183009 · reconstructed from prod · writes: see body
--
-- Recorded 2026-11-17 (branch triage): applied on prod as "evo_gt_subtitle_guard" (version 20260915183009) but present in no
-- file in git. Body is prod's own supabase_migrations.schema_migrations.statements for that row,
-- statements separated by ';'. Recording only — it is already applied; do not re-apply.


-- The resident-orchestra defect, caught in the US/CA dry run.
--
-- evo_gt_map scores a pair as greatest(name_similarity, performer_similarity). For a touring act
-- that is right and necessary -- "Kamelot with Visions of Atlantis and Frozen Crown" against
-- "Kamelot", or "Unsane" against "Unsane with CNTS", are the same show and only the performer
-- agrees. But greatest() also lets a matching PERFORMER completely mask a differing event NAME,
-- and for a resident ensemble that is exactly wrong:
--
--   Vancouver Symphony Orchestra - Mozart, Strauss ...  vs  ... - Ravel's Bolero     score 1.00
--   Calgary Philharmonic Orchestra - Nordic ...         vs  ... - Naomi Woo ...      score 1.00
--
-- Same hall, same night, same orchestra, DIFFERENT CONCERT. Both scored a perfect 1.00 purely on
-- the orchestra's name, and neither aq_name_consistent nor the ordinal guard catches it because
-- there is no number in dispute and the names genuinely are consistent as far as they overlap.
--
-- The distinction that separates the two cases is where the names DIVERGE. In the support-act
-- case one name contains the other and the extra text is billing. In the programme case both
-- names share a prefix and then carry DIFFERENT subtitles after a dash. So: if both sides have a
-- subtitle after the first ' - ' and those subtitles disagree, decline.
--
-- Checked against every one of the 29 proposals in that run before shipping: it declines exactly
-- the two orchestra pairs and leaves the other 27 alone, including the ones it could plausibly
-- have broken -- "2026 Harvest Music Festival - Tuesday (Jim Cuddy)" against itself (subtitles
-- agree), "Kamelot with ..." against "Kamelot" (GoTickets side has no subtitle at all).
CREATE OR REPLACE FUNCTION public.evo_gt_subtitle_agrees(p_a text, p_b text)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
SET search_path = public, pg_temp
AS $fn$
  WITH s AS (
    SELECT nullif(btrim(substring(lower(public.unaccent(coalesce(p_a,''))) from ' - (.*)$')),'') AS sa,
           nullif(btrim(substring(lower(public.unaccent(coalesce(p_b,''))) from ' - (.*)$')),'') AS sb
  )
  SELECT CASE
           WHEN sa IS NULL OR sb IS NULL THEN true          -- only one side names a programme
           ELSE similarity(sa, sb) >= 0.45                  -- both do: they must agree
         END
  FROM s;
$fn$;

COMMENT ON FUNCTION public.evo_gt_subtitle_agrees(text, text) IS
  'False when both names carry a differing subtitle after the first " - ". Stops a resident orchestra''s performer match from masking a different programme on the same night (mig 20260915200000).';

REVOKE ALL ON FUNCTION public.evo_gt_subtitle_agrees(text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.evo_gt_subtitle_agrees(text, text) TO service_role;
;

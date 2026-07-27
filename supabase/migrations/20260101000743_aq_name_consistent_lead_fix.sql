-- Refine aq_name_consistent: first-3-token equality fast-path for concert-style names.
--
-- The comprehensive audit's cleanup over-flagged short/acronym headliners whose only shared
-- token is a <4-char acronym (e.g. "O.A.R. - Three Decades" vs "O.A.R. with Gavin DeGraw and
-- Lisa Loeb" = same concert) and unbound them. Punctuation normalization strips "-"/":" before
-- any separator split, so a lead-segment split doesn't work; instead compare the first 3
-- space-tokens, GATED to non-"at" names only — for "X at Y" sports the away team leads, so
-- first-N would wrongly pass same-away/different-home matchups (those stay on the token+away
-- logic). Supersedes the transient aq_name_consistent_lead_segment attempt.
--
-- ## Already applied to prod  Applied via MCP 2026-06-01
CREATE OR REPLACE FUNCTION public.aq_name_consistent(p_tevo text, p_aq text)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
AS $function$
  WITH s AS (
    SELECT trim(regexp_replace(lower(regexp_replace(coalesce(p_tevo,''),'[^a-zA-Z0-9 ]',' ','g')),'\s+',' ','g')) AS t,
           trim(regexp_replace(lower(regexp_replace(coalesce(p_aq,''),  '[^a-zA-Z0-9 ]',' ','g')),'\s+',' ','g')) AS a
  ),
  sw AS (SELECT ARRAY['home','game','date','necessary','finals','final','round','preseason',
                      'national','football','basketball','hockey','baseball','soccer','series',
                      'commissioners','presented','tour','night'] AS w),
  tok AS (
    SELECT s.t, s.a,
      (SELECT array_agg(x) FROM unnest(string_to_array(s.t,' ')) x, sw WHERE length(x)>=4 AND x <> ALL(sw.w)) AS tfull,
      (SELECT array_agg(x) FROM unnest(string_to_array(s.a,' ')) x, sw WHERE length(x)>=4 AND x <> ALL(sw.w)) AS afull,
      (SELECT array_agg(x) FROM unnest(string_to_array(split_part(s.t,' at ',1),' ')) x, sw WHERE length(x)>=4 AND x <> ALL(sw.w)) AS taway,
      (SELECT array_agg(x) FROM unnest(string_to_array(split_part(s.a,' at ',1),' ')) x, sw WHERE length(x)>=4 AND x <> ALL(sw.w)) AS aaway,
      (position(' at ' in s.t)>0 AND position(' at ' in s.a)>0) AS both_at,
      (string_to_array(s.t,' '))[1:3] AS t3,
      (string_to_array(s.a,' '))[1:3] AS a3
    FROM s
  )
  SELECT
    (a <> '' AND t <> '' AND (position(a in t) > 0 OR position(t in a) > 0))
    OR (NOT both_at AND a3 = t3 AND coalesce(a3[1],'') <> '')
    OR (
      coalesce(tfull && afull, false)
      AND (NOT both_at OR taway IS NULL OR aaway IS NULL OR coalesce(taway && aaway, false))
    )
  FROM tok;
$function$;

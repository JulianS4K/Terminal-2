-- Migration 20260708181000 · level:standard · lane:A1 (data plane — fantasy scoring) · writes:fantasy_scoring_rulesets (1 UPDATE) · reads: · pre:20260705180000 · auth:operator-requested 2026-07-08 (fantasy audit — NHL #1e)
-- ============================================================================
-- Fantasy #1e — reconcile the NHL ruleset to the REAL hockey gamelog labels.
--
-- The NHL seed (mig 20260705180000, PR #806) keyed its ruleset on ESPN's long
-- `names` (goals/assists/shotsTotal/…) and flagged them PROVISIONAL. But the
-- gamelog ingest stores stats keyed by ESPN's short `labels`, so those keys
-- never matched → NHL scored zero.
--
-- Labels verified live 2026-07-08 (pg_net → ESPN hockey gamelog):
--   skater: G A PTS +/- PIM S SPCT PPG PPA SHG SHA GWG TOI/G PROD
--   goalie: GS TOI/G WINS L T OTL GA GAA SA SV SV% SO
-- The two sets are disjoint (a line is either a skater or a goalie), so one
-- FLAT ruleset scores both without a split. PTS is excluded (= G+A, would
-- double-count). Standard-points weights, mirroring the #806 intent.
-- ============================================================================
UPDATE public.fantasy_scoring_rulesets
   SET rules = '{"G":3,"A":2,"S":0.5,"PPG":0.5,"SHG":1,"GWG":0.5,"+/-":0.5,'
               '"SV":0.2,"GA":-1,"SO":3,"WINS":2}'::jsonb
 WHERE name = 'NHL Standard Points';

-- Migration 20260916140000 · level:data-collection · lane:A1 · writes:evo_gt_event_pair (match_pass col), evo_gt_promote_second_pass() fn, evo_gt_pipeline_tick() fn · reads:evo_gt_event_pair, gotickets_event · pre:20260916120000
--
-- ============================================================================================
-- THE MATCHER HAD NO SECOND ROUND, AND GREEDY MUTUAL-BEST ALWAYS LEAVES SOME BEHIND
-- ============================================================================================
-- evo_gt_pipeline_match ranks every candidate pair on both sides and accepts only where each is
-- the other's best (rn_evo = 1 AND rn_gt = 1). That is correct and it is what keeps the mapping
-- 1-1. What it does not do is look again once the winners are settled: an EVO event whose first
-- choice was taken by somebody else is simply left in not_mutual_best forever, even when the GT
-- event it would settle for is ALSO unclaimed and would settle for it.
--
-- MEASURED ON PROD BEFORE WRITING THIS, and the honest number is much smaller than the bucket:
--   not_mutual_best rows                                     6,518
--   distinct EVO events in it                                6,056
--     -- of those, ALSO hold an accepted pair (pure noise)    5,095  (84%)
--     -- of those, hold NO accepted pair (real lost coverage)   961
--   lost rows where the GT side is legitimately claimed         754  (correctly rejected --
--                                                                    recovering them would break
--                                                                    another event's match)
--   lost rows where BOTH sides are free                         289  <-- the only recoverable set
--     -- of those, become mutual-best on a second pass          266
--     -- and also clear p_min_score                             125  <-- what this migration wins
--
-- So this is worth +125 events against 27,470 accepted, about +0.45%. It is NOT the "biggest
-- untouched bucket" the 6,518 headline suggested -- 84% of that bucket is losing candidates for
-- events that are already matched, which the pair table keeps on purpose. Recording the real
-- figure here so nobody re-chases 6,518.
--
-- THE MATINEE/EVENING THEORY WAS WRONG, and it is worth saying why. A sample showed 14:00 EVO
-- paired to a 20:00 GT and vice versa, at delta 6h, which looked like cross-pairing. It is not:
-- w_evo and w_gt ALREADY order by delta_hours ASC as the third key, so the delta-0 same-showtime
-- pair wins and the delta-6 cross pair is the LOSER the table retains. Those sample rows were the
-- rejects, not the outcome. Reading the ranking beat reading the sample.
--
-- WHY A SEPARATE FUNCTION rather than a fourth step inside evo_gt_pipeline_match: the matcher is
-- ~250 lines of window functions that is working correctly and is the single most load-bearing
-- thing in the mapping pipeline. This needs none of its internals -- it operates on the pair table
-- it already produced. Keeping it out of that function means this can be disabled, re-run or
-- reverted on its own, and that a bug here cannot take the primary matcher down with it.
--
-- 1-1 IS PRESERVED BY CONSTRUCTION. Within a round, rn_e2 = 1 is unique per EVO event and
-- rn_g2 = 1 is unique per GT event, so at most one promotion exists per event on either side.
-- Across rounds, anything already accepted is excluded from the free set before re-ranking. The
-- writer additionally carries the both-ways guard (mig 20260915260000), so even a logic error here
-- cannot mint a double claim.
-- ============================================================================================

ALTER TABLE public.evo_gt_event_pair
  ADD COLUMN IF NOT EXISTS match_pass smallint NOT NULL DEFAULT 1;

COMMENT ON COLUMN public.evo_gt_event_pair.match_pass IS
  'Which pass accepted this pair: 1 = the primary mutual-best match, 2+ = recovered by evo_gt_promote_second_pass once earlier winners were settled. Lets the run log tell a genuine coverage gain from ordinary matcher drift (mig 20260916140000).';

CREATE OR REPLACE FUNCTION public.evo_gt_promote_second_pass(
  p_apply      boolean DEFAULT false,
  p_min_score  numeric DEFAULT 0.55,
  p_max_rounds int     DEFAULT 5
)
RETURNS jsonb
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $fn$
DECLARE
  v_round    int := 0;
  v_promoted int := 0;
  v_total    int := 0;
  v_written  int := 0;
  v_rounds   jsonb := '[]'::jsonb;
  v_started  timestamptz := clock_timestamp();
BEGIN
  IF current_user NOT IN ('service_role', 'postgres', 'supabase_admin') THEN
    RAISE EXCEPTION 'forbidden: %', current_user USING ERRCODE = '42501';
  END IF;
  PERFORM set_config('statement_timeout', '170000', true);

  -- A dry run must not leave promotions behind, so the whole thing runs against a working copy of
  -- the verdicts and only touches the real table when p_apply is true.
  DROP TABLE IF EXISTS _pass;
  CREATE TEMP TABLE _pass ON COMMIT DROP AS
  SELECT tevo_event_id, gt_event_id, score, delta_hours, verdict,
         same_local_day, ordinals_ok, subtitle_ok
    FROM public.evo_gt_event_pair;
  CREATE INDEX ON _pass (verdict);
  CREATE INDEX ON _pass (tevo_event_id);
  CREATE INDEX ON _pass (gt_event_id);

  LOOP
    v_round := v_round + 1;
    EXIT WHEN v_round > p_max_rounds;

    WITH acc_e AS (SELECT DISTINCT tevo_event_id FROM _pass WHERE verdict = 'accepted'),
         acc_g AS (SELECT DISTINCT gt_event_id   FROM _pass WHERE verdict = 'accepted'),
    free AS (
      SELECT p.tevo_event_id, p.gt_event_id, p.score, p.delta_hours
        FROM _pass p
       WHERE p.verdict = 'not_mutual_best'
         AND p.same_local_day
         AND p.ordinals_ok
         AND p.subtitle_ok
         AND p.score >= p_min_score
         AND NOT EXISTS (SELECT 1 FROM acc_e a WHERE a.tevo_event_id = p.tevo_event_id)
         AND NOT EXISTS (SELECT 1 FROM acc_g a WHERE a.gt_event_id   = p.gt_event_id)),
    rr AS (
      SELECT f.*,
             row_number() OVER (PARTITION BY tevo_event_id ORDER BY score DESC, delta_hours ASC, gt_event_id)   AS rn_e2,
             row_number() OVER (PARTITION BY gt_event_id   ORDER BY score DESC, delta_hours ASC, tevo_event_id) AS rn_g2
        FROM free f),
    promote AS (SELECT tevo_event_id, gt_event_id FROM rr WHERE rn_e2 = 1 AND rn_g2 = 1)
    UPDATE _pass t
       SET verdict = 'accepted'
      FROM promote pr
     WHERE t.tevo_event_id = pr.tevo_event_id
       AND t.gt_event_id   = pr.gt_event_id
       AND t.verdict = 'not_mutual_best';

    GET DIAGNOSTICS v_promoted = ROW_COUNT;
    v_total  := v_total + v_promoted;
    v_rounds := v_rounds || jsonb_build_object('round', v_round, 'promoted', v_promoted);
    EXIT WHEN v_promoted = 0;
  END LOOP;

  IF NOT p_apply THEN
    RETURN jsonb_build_object(
      'applied', false,
      'note', 'DRY RUN -- nothing written.',
      'rounds', v_rounds, 'promoted_total', v_total,
      'elapsed_ms', round(EXTRACT(epoch FROM (clock_timestamp() - v_started)) * 1000));
  END IF;

  -- Publish the promoted verdicts, then write them through. The writer carries the same fill-only
  -- and both-ways conditions as the primary matcher: it never overwrites an existing mapping and
  -- never claims a TEvo event another GoTickets row already holds.
  UPDATE public.evo_gt_event_pair v
     SET verdict = 'accepted', match_pass = 2
    FROM _pass t
   WHERE v.tevo_event_id = t.tevo_event_id
     AND v.gt_event_id   = t.gt_event_id
     AND t.verdict = 'accepted'
     AND v.verdict = 'not_mutual_best';

  UPDATE public.gotickets_event g
     SET tevo_event_id = v.tevo_event_id,
         mapped_via    = 'evo_gt_v2_pass2',
         map_score     = v.score,
         mapped_at     = now(),
         updated_at    = now()
    FROM public.evo_gt_event_pair v
   WHERE g.gt_event_id = v.gt_event_id
     AND v.verdict = 'accepted'
     AND v.match_pass = 2
     AND g.tevo_event_id IS NULL
     AND NOT EXISTS (SELECT 1 FROM public.gotickets_event g2
                      WHERE g2.tevo_event_id = v.tevo_event_id
                        AND g2.gt_event_id <> v.gt_event_id);
  GET DIAGNOSTICS v_written = ROW_COUNT;

  RETURN jsonb_build_object(
    'applied', true,
    'rounds', v_rounds, 'promoted_total', v_total, 'written', v_written,
    'elapsed_ms', round(EXTRACT(epoch FROM (clock_timestamp() - v_started)) * 1000));
END $fn$;

REVOKE ALL ON FUNCTION public.evo_gt_promote_second_pass(boolean, numeric, int) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.evo_gt_promote_second_pass(boolean, numeric, int) TO service_role;

COMMENT ON FUNCTION public.evo_gt_promote_second_pass(boolean, numeric, int) IS
  'Recovers pairs that greedy mutual-best left behind: where an EVO event and a GT event are BOTH still unclaimed and are each other''s best among what remains, accept them. Iterates until a round promotes nothing (default max 5). DRY RUN unless p_apply => true. 1-1 holds by construction (rn=1 is unique per side within a round; accepted events leave the free set between rounds) and the writer repeats the both-ways guard so a logic error here still cannot mint a double claim. Measured on prod 2026-09-16: +125 events, against a not_mutual_best bucket of 6,518 that is 84% already-matched noise. A1 mig 20260916140000.';

-- --------------------------------------------------------------------------------------------
-- Wire it into the daily tick. It must run AFTER the primary match, on the pair table that match
-- just produced -- it cannot run before, because it needs to know who won.
-- --------------------------------------------------------------------------------------------
ALTER TABLE public.evo_gt_pipeline_run_log
  ADD COLUMN IF NOT EXISTS pass2_result jsonb;

COMMENT ON COLUMN public.evo_gt_pipeline_run_log.pass2_result IS
  'Result of evo_gt_promote_second_pass for this tick: the per-round promotion counts and how many actually wrote through. Separate from match_result so a coverage gain from the second pass is never mistaken for the primary matcher improving (mig 20260916140000).';

CREATE OR REPLACE FUNCTION public.evo_gt_pipeline_tick()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_t0 timestamptz := clock_timestamp();
  v_venue jsonb; v_match jsonb; v_pass2 jsonb;
  v_links_before int; v_links_after int;
BEGIN
  IF current_user NOT IN ('service_role','postgres','supabase_admin') THEN
    RAISE EXCEPTION 'evo_gt_pipeline_tick: caller % not authorized', current_user
      USING ERRCODE='42501';
  END IF;
  PERFORM set_config('statement_timeout', '900000', true);

  SELECT count(*) INTO v_links_before FROM public.evo_gt_venue_link;
  v_venue := public.evo_gt_venue_link_build(true);
  SELECT count(*) INTO v_links_after FROM public.evo_gt_venue_link;

  IF v_links_before > 100 AND v_links_after < (v_links_before * 0.8)::int THEN
    RAISE EXCEPTION
      'evo_gt_pipeline_tick: venue map collapsed % -> % (< 80%%), refusing to publish; nothing written',
      v_links_before, v_links_after;
  END IF;

  v_match := public.evo_gt_pipeline_match(true);
  v_pass2 := public.evo_gt_promote_second_pass(true);

  INSERT INTO public.evo_gt_pipeline_run_log (duration_ms, venue_result, match_result, pass2_result)
  VALUES ((extract(epoch FROM (clock_timestamp() - v_t0)) * 1000)::int, v_venue, v_match, v_pass2);

  RETURN jsonb_build_object('venue', v_venue, 'match', v_match, 'pass2', v_pass2);
END $fn$;

REVOKE ALL ON FUNCTION public.evo_gt_pipeline_tick() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.evo_gt_pipeline_tick() TO service_role;

-- ============================================================================================
-- APPLIED AND VERIFIED ON PROD, 2026-09-16
-- ============================================================================================
--   DRY RUN            round 1 promoted 125 · round 2 promoted 6 · round 3 promoted 0, converged
--                      The single-pass simulation written beforehand predicted 125. Iterating
--                      found 6 more, which is the whole argument for the loop.
--   APPLIED            131 promoted, 103 WRITTEN
--                        24 not written -- the GoTickets row already carried a mapping from
--                           another matcher, and the writer is fill-only
--                         4 not written -- BLOCKED BY THE BOTH-WAYS GUARD, which is that guard
--                           catching this migration's own new code
--   COVERAGE           accepted 27,470 -> 27,601 · gotickets_event mapped 29,188 -> 29,291
--
--   INVARIANTS AFTER, all measured, none assumed:
--     double-claimed TEvo events        235 -> 235   (unchanged)
--     accepted pairs                    27,601
--     accepted distinct EVO             27,601       (exactly 1-1)
--     accepted distinct GT              27,601       (exactly 1-1)
--     accepted on a different local day      0
--
-- WHAT THIS IS NOT. +131 promoted / +103 written against 27,601 accepted is about +0.4%. The
-- not_mutual_best bucket reads 6,518 and that headline is misleading: 84% of it is losing
-- candidates for events that already hold an accepted pair, which the table keeps deliberately.
-- Of the 961 EVO events with no accepted pair, 754 lost to a GT row another event legitimately
-- holds. Only 289 had both sides free, and that is the whole addressable set. Anyone reading
-- 6,518 as headroom will be disappointed; the number to chase is different_local_day, or the
-- ~103k forward events with no tape at all.

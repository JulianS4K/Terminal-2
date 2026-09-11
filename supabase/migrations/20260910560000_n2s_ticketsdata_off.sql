-- ============================================================================
-- Migration 20260910560000 — take TicketsData out of the N2S matcher
--
-- Lane: D7 · Level: Applier (cron deactivation)
-- Operator 2026-09-10: "ticket data is off for now, didnt renew contract."
--
-- The vendor contract has lapsed, so every TicketsData call now fails. Two
-- things follow for this lane: the N2S TD polling crons (599 enqueue, 601
-- sweep+drain) are deactivated, and the matcher stops treating TD as a default
-- source.
--
-- ⚠ SCOPE: THIS IS THE D7 SLICE ONLY. ~22 further ACTIVE TicketsData crons
-- belong to A1's data plane (td_tier_enqueue_*, td_enqueue_peak_*,
-- td_pull_drain, td_normalize_drain, td_*_discover, td_watchlist_refresh …).
-- They are NOT touched here: they feed surfaces beyond N2S and switching off
-- another lane's ingest is not D7's call. They are reported to the operator
-- instead — every one is now calling a dead vendor. Tracked as A1-OPS-33.
--
-- ⚠ OPT-IN, NOT DELETED. The TD arm of n2s_cover_candidates is kept and its
-- guard tightened from "included unless excluded" to "excluded unless asked
-- for": p_sub_sources => ARRAY['ticketsdata'] still works. If the contract is
-- renewed this is a one-line revert, and no historical cover referencing a td
-- listing becomes unreadable.
--
-- Side effect: moots D7-OPS-1 (unseeded TICKETSDATA_N2S_* vault pair) and
-- D7-OPS-2 (td_budget_ok() reporting healthy through an outage) FOR THIS LANE
-- — there is no longer a quota to protect or misreport. Both remain open for
-- A1's TD surface.
-- ============================================================================

SELECT cron.alter_job(599, active := false);
SELECT cron.alter_job(601, active := false);

DO $do$
DECLARE d text;
BEGIN
  d := pg_get_functiondef('public.n2s_cover_candidates(bigint[],interval,integer,text[])'::regprocedure);

  IF position('(p_sub_sources IS NULL OR ''ticketsdata'' = ANY(p_sub_sources))' in d) = 0 THEN
    IF position('(''ticketsdata'' = ANY(p_sub_sources))' in d) > 0 THEN
      RAISE NOTICE 'ticketsdata already opt-in; nothing to do';
      RETURN;
    END IF;
    RAISE EXCEPTION 'ticketsdata source guard not found — body changed?';
  END IF;

  d := replace(d,
       '(p_sub_sources IS NULL OR ''ticketsdata'' = ANY(p_sub_sources))',
       '(''ticketsdata'' = ANY(p_sub_sources))');

  IF position('(p_sub_sources IS NULL OR ''ticketsdata''' in d) > 0 THEN
    RAISE EXCEPTION 'ticketsdata guard still permissive after rewrite';
  END IF;

  EXECUTE d;
END $do$;

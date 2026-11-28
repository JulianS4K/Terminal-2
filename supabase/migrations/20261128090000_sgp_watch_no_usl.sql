-- Migration 20261128090000 · level:data-collection · lane:a1 (SeatGeek primary watch) · writes:sgp_watch_team.enabled(USL off) · reads:—
--
-- The USL clubs leave the SeatGeek primary watch. Operator 2026-11-28: "remove usl". Their rows stay, switched off
-- (enabled = false): the catalogue search no longer runs for them, v_sgp_watch_games drops their games, and nothing of
-- theirs is captured. 20 clubs (AV Alta FC to Westchester SC). Back on: UPDATE sgp_watch_team SET enabled = true
-- WHERE league = 'USL'.

BEGIN;

UPDATE public.sgp_watch_team SET enabled = false, note = 'USL: off, operator 2026-11-28 "remove usl"' WHERE league = 'USL';

COMMIT;

-- Migration 20260901000915 · reconstructed from prod · writes: see body
--
-- Recorded 2026-11-17 (branch triage): applied on prod as "xref_evo_gt_mapper_accurate_offset_diagnosis" (version 20260901000915) but present in no
-- file in git. Body is prod's own supabase_migrations.schema_migrations.statements for that row,
-- statements separated by ';'. Recording only — it is already applied; do not re-apply.


-- ============================================================================
-- Migration — correct the recorded diagnosis on evo_map_events_to_gotickets
--
-- Lane:     xref+macro
-- Touches:  evo_map_events_to_gotickets (COMMENT only; no behaviour change)
-- Pre-reqs: xref_evo_gt_mapper_fix_tier_ambiguity
--
-- The header of xref_evo_to_gotickets_event_mapper claimed the two time-offset
-- spikes had "no correctable cause" and attributed the -1 minute cluster to
-- GoTickets' :01/:31 minute clusters. Sampling the matches disproved both.
-- The real causes are specific and nameable, and are recorded here on the
-- object itself so the next reader gets the corrected account rather than the
-- migration header's guess. Behaviour is unchanged -- the tolerance window was
-- already right; only the explanation was wrong.
-- ============================================================================

COMMENT ON FUNCTION public.evo_map_events_to_gotickets(integer, boolean) IS
$c$EVO-driven EVO -> GoTickets event mapper. Drives from our 8,907 future
`events` rather than GoTickets' 126,976-row future catalogue, which is what the
two pre-existing mappers do (gt_map_events, match_gotickets_us_events).

Why a third mapper: gt_map_events requires an EXACT-MINUTE time equality, and
match_gotickets_us_events only considers GT rows whose venue already appears in
cross_source_venue_map.canonical_name -- a 391-row table that just 2,872 of
123,566 unmapped future GT events (2.3%) clear.

The exact-minute rule is the binding constraint. Among unmapped future EVO
events with a same-canonical-venue, performer-agreeing GT candidate inside
+/-3h, the delta distribution is +60min:265, -1min:93, 0min:16, +120min:12.
Only sixteen are exact.

MEASURED CAUSES (verified by sampling, not inferred):
  * +60 and +120 -- a TIMEZONE DISCREPANCY ON CANADIAN VENUES. 248 of the 265
    +60 cases and 12 of the 12 +120 cases sit at Canadian venues (Scotiabank
    Arena, Canadian Tire Centre, Rogers Place, Scotiabank Saddledome, ...).
    NOT daylight saving -- the spike spans every month from 2026-09 to 2027-04
    rather than sitting on one side of a transition.
  * -1 -- TBD PLACEHOLDERS ON BOTH SIDES. All 93 have GT minute = 59. TEvo
    marks an unknown time as 00:00 local; GoTickets marks it 23:59 the previous
    local day. The two conventions land one minute apart in absolute time.

Neither is corrected by an offset -- a global shift would break the events that
are already exact -- so both are absorbed by a bounded window.

TIERS (each demands exactly one surviving candidate):
  evo_gt_exact 0.95  same canonical venue, |delta| <= 1 min, performer >= 0.45
  evo_gt_near  0.88  same canonical venue, |delta| <= 120 min, performer >= 0.60
  evo_gt_tbd   0.72  placeholder present on either side -> reconcile by local
                     date (+/-1 day) instead of clock time, performer >= 0.60

GUARDS: uniqueness enforced BOTH ways (one GT candidate per EVO event, and that
GT row claimed by only one EVO event); never overwrites an existing
tevo_event_id; status = AS_SCHEDULED; parking excluded on both sides. The
two-way uniqueness matters -- a Spurs/Frost Bank Center pair 55h apart with
performer similarity 1.00 is a different game, not a time disagreement.

p_apply = false runs a dry run (counts only, no writes).
First production run 2026-09-01: 75 exact + 273 near + 10 tbd = 358 links,
taking future EVO->GT coverage from 37.8% to 41.9%, adding no fan-out.

CEILING: catalogue overlap, not matcher quality. Of 5,548 unmapped future EVO
events only 683 have ANY same-venue GT candidate within +/-30h and 442 also
agree on performer. The rest are simply not in GoTickets' catalogue under a
venue name we share.$c$;
;

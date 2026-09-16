-- Migration 20260916120000 · level:data-collection · lane:A1 · writes:event_demand_policy (new), event_demand_weight (new), event_demand_signal (new), event_demand_refresh() fn, v_event_demand_tier (new view) · reads:events, seatgeek_sales_snapshots, gotickets_purchases, gotickets_deal_outcome, latest_event_metrics · pre:20260915260000
-- ⚠ NOT YET APPLIED. Supabase was down for maintenance when this was written, so nothing here has
-- been executed, and no number below the "MEASURED" line has been re-measured against prod.
-- event_demand_refresh() therefore DEFAULTS TO DRY RUN (p_apply := false) and writes nothing until
-- an operator passes true. Nothing in this migration reschedules a cron or changes any live poller.
--
-- ==============================================================================================
-- DEMAND TIERS FROM THE THREE CRM FEEDS
-- ==============================================================================================
-- What exists today is TWO signals, in two places that evolved separately:
--
--   collector_cadence  (source, scope, band)  -- hours-to-event  x  owned_kind in (owned|non|any)
--   sg_priority_policy (tier)                 -- hours-to-event  x  requires_owned boolean
--
-- Both grade on time-to-event, and both treat our own interest as a BOOLEAN: do we hold stock or
-- not. Nothing anywhere reads what the market is actually doing with an event, what we have spent
-- on it, or what it has already cost us. An event we own one ticket in outranks an event trading
-- 400 times a week that we happen to be flat on.
--
-- This migration adds the missing dimension as a substrate rather than a fourth poller: one
-- scored row per forward TEvo event, derived from the three CRM feeds, which every existing
-- poller can read by tevo_event_id (the cross-source spine, PROJECT_BIBLE §0).
--
--   FEED 1  seatgeek_sales_snapshots  -- the public tape. What the market cleared, and at what.
--   FEED 2  gotickets_purchases       -- our buy book. Revealed preference, in dollars.
--   FEED 3  gotickets_deal_outcome    -- the loss ledger. What we lost, and what it cost us.
--
-- WIRING THE POLLERS IS DELIBERATELY NOT IN THIS FILE. Teaching collector_band() about the tier
-- changes EVO, SG and GT cadence simultaneously, and that is not a change to make in a migration
-- that could not be run once before shipping. This one builds and scores the tiers; a second,
-- separately reviewed migration consumes them.
--
-- ==============================================================================================
-- FOUR THINGS THAT WOULD MAKE THIS WRONG IF THEY WERE NOT HANDLED
-- ==============================================================================================
--
-- 1. THE TAPE IS CIRCULAR. seatgeek_sales_snapshots only contains sales for events we already
--    poll. A quiet event and an unpolled event look identical in it, so scoring on raw sale COUNT
--    means "we rarely poll it" scores as "nobody wants it", and the event is demoted for it --
--    permanently, because the evidence that would promote it only arrives if we poll. So velocity
--    is normalised by sg_observed_days (span of our own coverage, not calendar days), and an event
--    with NO observation at all is not scored low -- it is not scored. It goes to T_PROBE, a
--    bounded exploration slice ordered by soonest event date. Cold start and lock-in are the same
--    bug and this is the one fix for both.
--
-- 2. LOSS HISTORY IS NOT PER-EVENT. An event happens once; a forward event has no outcomes at all.
--    Read literally, feed 3 would be NULL for every row this table is about. The signal only
--    carries at venue and performer level, so the loss component cascades event -> venue ->
--    performer -> none and records which in loss_basis. A tier driven by an inherited prior and a
--    tier driven by this event's own history are not the same claim and the column says which.
--
-- 3. GET-IN IS A PROXY HERE, NOT A QUOTE. brokerdata /sales returns cleared prices only -- there
--    are no asks in seatgeek_sales_snapshots (the table has broadcast_price and nothing else).
--    sg_getin_price is therefore the 10th percentile of what CLEARED, which is a floor on recent
--    transactions, not a live get-in. True get-in needs seatgeek_listings_snapshots, an 8.16M-row
--    table the SG classifier already documents as timing out under correlated access; adding that
--    join belongs in its own migration with its own plan. The column name would be a lie without
--    this paragraph, which is why the paragraph is here.
--
-- 4. A TIER PLAN THAT OVERRUNS THE RATE LIMIT IS THE BUG WE ALREADY SHIPPED ONCE. Canada pages 42
--    and 43 were lost silently because a caller ran at the ceiling and a 429 had nowhere to go
--    (mig 20260915200000, DEFECT 3). Tier populations here are therefore fixed COUNTS, not score
--    percentiles, and event_demand_refresh() multiplies population by polls_per_day and RAISES
--    before writing anything if the total exceeds p_daily_budget. A retune that cannot be afforded
--    fails loudly at retune time instead of quietly at poll time.
--
-- ==============================================================================================
-- MEASURED (carried from the 2026-09-15 rate-limit work; NOT re-measured, Supabase was down)
-- ==============================================================================================
--   TEvo sustained rate, proven   0.73 req/s  -- 40 requests per ~55s round, zero 429s across the
--                                                whole 1,044-page US+CA backfill
--   TEvo rate, known to fail      1.45 req/s  -- 173 requests produced 39x HTTP 429
--   No Retry-After and no X-RateLimit-* header is returned, so the ceiling is inferred from
--   behaviour alone and every number below it is a floor on ignorance, not a budget from the API.
--
--   0.73 req/s over 24h            = 63,072 requests/day gross
--   less 10% retry reserve         = 56,765 -> p_daily_budget DEFAULT 56800
--   EVO forward catalogue           = 107,341 events, so uniform daily coverage needs 1.24 req/s,
--                                     above proven and close to the rate that is known to fail.
--                                     Tiering is what makes the catalogue affordable at all.
--   GoTickets' limit is COMPLETELY UNMEASURED. p_daily_budget describes TEvo. Do not read a GT
--   cadence out of it until GT has been laddered the same way (20/40/80).
-- ==============================================================================================

-- ─────────────────────────────────────────────────────────────────────────────────────────────
-- 1. Policy: tier populations and cadence. Operator-editable; the refresh reads it every run.
-- ─────────────────────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.event_demand_policy (
  tier            text PRIMARY KEY,
  label           text    NOT NULL,
  sort_order      int     NOT NULL,          -- 1 = hottest; assignment walks this order
  population_cap  int,                       -- events allowed to hold this tier; NULL = remainder
  polls_per_day   numeric NOT NULL,          -- fractional is fine: 0.2 = once every five days
  -- Score tiers size themselves as a SHARE OF THE MIDDLE rather than a fixed count. The middle
  -- is every scored event the activity tier did not take, and the shares are required to cover
  -- all of it -- see "why the middle is a share" below. population_cap is for the two tiers whose
  -- size is not a share: the activity tier and the probe tier.
  share_pct       numeric CHECK (share_pct IS NULL OR (share_pct > 0 AND share_pct <= 100)),
  -- How the tier's population is chosen:
  --   'score'    by demand_score rank, filling population_cap in sort_order
  --   'activity' by QUALIFICATION -- the event has sales or purchases against it. Operator rule
  --              of 2026-09-16: anything trading, or anything we have bought, is polled hourly.
  --              Ordered by demand_score within the qualifying set, so when more events qualify
  --              than the cap can hold it is the best of them that get the hourly slot.
  --   'probe'    by soonest event date, from events that could not be scored at all
  fill_mode       text    NOT NULL DEFAULT 'score'
                  CHECK (fill_mode IN ('score', 'activity', 'probe')),
  enabled         boolean NOT NULL DEFAULT true,
  notes           text,
  updated_at      timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT event_demand_policy_ppd_ck CHECK (polls_per_day >= 0),
  CONSTRAINT event_demand_policy_cap_ck CHECK (population_cap IS NULL OR population_cap >= 0)
);
REVOKE ALL ON TABLE public.event_demand_policy FROM anon;

COMMENT ON TABLE public.event_demand_policy IS
  'Demand-tier cadence. Score tiers size themselves as share_pct of THE MIDDLE (every scored event the activity tier did not take); the shares cover all of it, so evidence-bearing events get a graded slope instead of overflowing onto the floor. fill_mode=activity is claimed FIRST (any event with sales or purchases, best demand_score first, up to population_cap); fill_mode=score then walks sort_order ascending over everything left, filling each population_cap from the demand_score ranking, and the one score tier with NULL population_cap absorbs the remainder as the coverage floor; fill_mode=probe is filled by events with NO observation, so cold-start events are never ranked against events we have actually watched. Operator retunes here; event_demand_refresh() re-costs the plan against p_daily_budget and refuses to publish one that does not fit.';

INSERT INTO public.event_demand_policy
  (tier, label, sort_order, population_cap, share_pct, polls_per_day, fill_mode, notes) VALUES
  ('T0_HOURLY', 'Trading or bought - hourly', 0, 1000, NULL, 24,   'activity', 'Hourly.     1,000 x 24    = 24,000/day. Operator rule 2026-09-16: anything with sales against it, or anything we have purchased, is pinged hourly. Claimed BEFORE the middle; qualifiers beyond the cap fall into the middle, which is where they now land on a graded slope instead of a cliff.'),
  ('M1_FAST',   'Middle - top 3%',            1, NULL,    3,  4,   'score',    'Every 6h.     900 x 4     =  3,600/day'),
  ('M2_BRISK',  'Middle - next 7%',           2, NULL,    7,  2,   'score',    'Every 12h.  2,100 x 2     =  4,200/day'),
  ('M3_STEADY', 'Middle - next 15%',          3, NULL,   15,  1,   'score',    'Daily.      4,500 x 1     =  4,500/day'),
  ('M4_SLOW',   'Middle - next 25%',          4, NULL,   25,  0.5, 'score',    'Every 2d.   7,500 x 0.5   =  3,750/day'),
  ('M5_TRICKLE','Middle - bottom 50%',        5, NULL,   50,  0.2, 'score',    'Every 5d.  15,000 x 0.2   =  3,000/day. The worst-served event we have EVIDENCE about. It is still five times better than the floor, which is the point.'),
  ('T_PROBE',   'Unobserved - exploring',     6, 3000, NULL,  1,   'probe',    'Daily.      3,000 x 1     =  3,000/day. Never polled, so unscorable; soonest event date first. This slice is what stops the tape being self-fulfilling.'),
  ('T6_FLOOR',  'Floor - never dark',         7, NULL, NULL,  0.0714,'score',  'Fortnightly. 73,341 x 0.0714 = 5,237/day. Absorbs the remainder. Now holds ONLY events with no evidence at all -- see below.')
ON CONFLICT (tier) DO NOTHING;
-- Total at the measured catalogue: 51,287 polls/day = 90.3% of the 56,800 TEvo budget.
--
-- ==============================================================================================
-- WHY THE MIDDLE IS A SHARE OF ITSELF, AND NOT A LIST OF FIXED COUNTS
-- ==============================================================================================
-- The first ladder sized every tier as an absolute number, and under the hourly rule that produced
-- a cliff nobody asked for. MEASURED on the test catalogue, before this change:
--
--   T5_FLOOR   19,600 SCORED events  +  73,341 unscored
--
-- 19,600 events we hold real evidence about -- a tape, our own purchases, graded losses -- were
-- sitting on the weekly floor, polled at exactly the same rate as the 73,341 we know nothing about
-- whatsoever. The fixed counts above them (400 / 1,000 / 3,000 / 6,000) covered 10,400 of the
-- 30,000-event middle and the remaining two thirds fell off the end.
--
-- That is the wrong shape. Evidence should buy a graded cadence, not a pass/fail at rank 10,400.
-- So the middle now sizes itself from its OWN population: the shares sum to 100 and cover every
-- scored event the activity tier did not take. The floor stops being where the middle overflows
-- to, and goes back to meaning what its name says -- the events we have never seen anything about.
--
-- The resulting slope, with no cliff anywhere in it:
--
--   hourly (60m) -> 6h -> 12h -> daily -> 2d -> 5d  |  probe daily  |  floor fortnightly
--
-- WHAT PAID FOR IT. The middle needs ~19,300/day and the budget had ~16,800 spare, so something
-- had to give. It was the floor, weekly -> fortnightly, which frees 5,251/day. That is the least
-- informative spend in the whole ladder: those events have no evidence by definition, and
-- T_PROBE is already sampling 3,000 of them a day on purpose. Waiting 14 days instead of 7 to
-- re-touch an event nothing has ever been observed about costs less than stranding 19,600 events
-- we have measured. The floor still guarantees nothing goes dark, which was its actual job.
--
-- A SHARE LADDER IS NOT SELF-LIMITING THE WAY FIXED COUNTS WERE. Its cost moves with the size of
-- the middle, so as the qualifying/scored population grows the plan gets more expensive on its
-- own. That is exactly what the budget guard is for, and it is why the shares are validated to
-- sum to <= 100 before anything is costed: shares that sum to 140 would silently assign some
-- events twice.
-- ==============================================================================================
--
-- ON CONFLICT DO NOTHING is deliberate: this table is operator-editable, and a re-apply of this
-- migration must never silently revert a retune. Changing the shipped defaults later means an
-- explicit UPDATE, not an edit to this INSERT.

-- ─────────────────────────────────────────────────────────────────────────────────────────────
-- 1b. Per-source budgets. WE WILL ALSO POLL GOTICKETS, so "the budget" is no longer one number.
--
--     A GoTickets request does not spend TEvo's allowance -- they are different APIs with
--     different limits -- so the plan is NOT simply twice as expensive. It is two plans, each
--     costed against its own ceiling, over different populations: TEvo covers the whole forward
--     catalogue, GoTickets only the events that carry a GT mapping.
--
--     What is actually known about each ceiling, and it is not much:
--       TEVO  56,800/day.  0.73 req/s is the only rate this project has sustained without a 429
--                          (40 requests per ~55s round, zero 429s across the 1,044-page US+CA
--                          backfill); 1.45 req/s produced 39x HTTP 429. No Retry-After and no
--                          X-RateLimit-* header is returned, so this is inferred from behaviour.
--       GT    UNMEASURED.  Never laddered. Two data points, both from mig 20260804230000: the
--                          full /rest/events dump is "heavily rate-limited (429 after a few
--                          pulls, verified 2026-08-04)", while /rest/events/delta is "NOT
--                          rate-limited". So GT throttles bulk hard, and a NULL here means the
--                          plan CANNOT be checked against it -- not that it is free.
--       SG    UNMEASURED.  brokerdata is plainly looser: sg_priority_poll_tick already polls its
--                          HOT tier every 60s. Not costed here; SG has its own poller.
--
--     THE DELTA ENDPOINT DOES NOT RESCUE THIS -- MEASURED 2026-09-16, AND THE ANSWER IS NO.
--     The hope was that /rest/events/delta ("NOT rate-limited", mig 20260804230000) might fire when
--     a GoTickets event's LISTINGS move, not only when its metadata does. If it did, hourly
--     freshness over the whole GT catalogue would cost 24 calls a day instead of one per event per
--     hour, and none of the per-event GT arithmetic below would matter. Measured over a 3-hour
--     window on prod:
--
--       events with listing activity                     3,661
--       of those, inventory actually moved               3,076   (display_price or quantity changed)
--       of those, catalogue row touched by the delta         3   = 0.1%
--
--     Three out of 3,076 is noise. Corroborating: the most recent drained delta pull upserted ZERO
--     events, and only 9 catalogue rows changed in 3 hours, while 1,601,293 listing snapshots
--     landed across 4,560 events in the same window. The delta is a METADATA feed -- it moves on
--     name, time, status and venue changes, not on inventory.
--
--     So per-event GT polling is required after all, the GT plan below is the real cost, and this
--     tiering is what makes it affordable rather than an alternative to something cheaper.
-- ─────────────────────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.event_demand_source_budget (
  source        text PRIMARY KEY,           -- 'TEVO' | 'GT' | 'SG'
  daily_budget  int,                        -- NULL = UNMEASURED; the plan cannot be checked
  enforced      boolean NOT NULL DEFAULT true,
  notes         text,
  updated_at    timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT event_demand_source_budget_ck CHECK (daily_budget IS NULL OR daily_budget > 0)
);
REVOKE ALL ON TABLE public.event_demand_source_budget FROM anon;

INSERT INTO public.event_demand_source_budget (source, daily_budget, enforced, notes) VALUES
  ('TEVO', 56800, true,  '0.73 req/s proven x 24h, less a 10% retry reserve. Population: every forward event. 1.45 req/s is known to fail.'),
  ('GT',   NULL,  false, 'UNMEASURED -- never rate-laddered. Population: forward events carrying a GT mapping. A NULL budget means the plan is reported against this source but NOT enforced; it does not mean the source is free. Ladder GT (20/40/80) before setting a number here, and check the /rest/events/delta question first -- it may make per-event GT polling moot.')
ON CONFLICT (source) DO NOTHING;

COMMENT ON TABLE public.event_demand_source_budget IS
  'Per-source daily request ceilings. A GoTickets request does not spend TEvo''s allowance, so the plan is costed once per source over that source''s own pollable population rather than as a single doubled number. daily_budget NULL means UNMEASURED: event_demand_refresh() reports the cost against that source but cannot enforce it, and says so. A1 mig 20260916120000.';

-- ─────────────────────────────────────────────────────────────────────────────────────────────
-- 2. Weights: how the five components combine. Separate table so a retune is an UPDATE, not a
--    migration. Components are rank-normalised before weighting (see §4), so these are pure
--    relative importance -- no unit, no scale, nothing to recalibrate when the catalogue grows.
-- ─────────────────────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.event_demand_weight (
  component  text PRIMARY KEY,
  weight     numeric NOT NULL,
  enabled    boolean NOT NULL DEFAULT true,
  notes      text,
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT event_demand_weight_ck CHECK (weight >= 0)
);
REVOKE ALL ON TABLE public.event_demand_weight FROM anon;

INSERT INTO public.event_demand_weight (component, weight, notes) VALUES
  ('value',    1.0, 'FEED 1. sg_qty_30d x sg_med_price -- dollars the market moved through this event.'),
  ('velocity', 1.0, 'FEED 1. Sales per OBSERVED day, not per calendar day. See defect 1 in the header.'),
  ('exposure', 1.2, 'FEED 2. Our GoTickets spend, 90d. Outranks market noise because it is our money.'),
  ('loss',     1.5, 'FEED 3. Dollars lost, 180d, inherited venue/performer where the event has no history. Heaviest weight: where we priced wrong is where another poll pays most.'),
  ('owned',    1.0, 'The signal the two existing ladders already use. Retained, not replaced -- this migration adds a dimension, it does not overrule the operator directive of 2026-05-14.')
ON CONFLICT (component) DO NOTHING;

-- A property of rank-normalising that an operator retuning these weights has to know: on a
-- SPARSE column, percent_rank degenerates towards a binary indicator. If only a few hundred of
-- ~107k forward events carry any GoTickets spend, every other row ties at percent_rank 0 and the
-- 'exposure' weight stops behaving as a graded measure -- it becomes, in effect, a flat bonus
-- applied to the events we bought on. That is a reasonable thing to want, and it is what the 1.2
-- is for; it is not what "weight" usually implies, so it is written down here rather than
-- rediscovered from a tier list that looks strange. Check the spread with:
--   SELECT component, ... FROM event_demand_signal -- count(*) FILTER (WHERE exposure_r > 0)
-- before concluding a weight is mis-set.

COMMENT ON TABLE public.event_demand_weight IS
  'Relative weights for the demand_score components. Rank-normalised inputs (percent_rank), so weights carry no units and an outlier cannot dominate the score. Set weight 0 or enabled=false to drop a component without deleting its measurement.';

-- ─────────────────────────────────────────────────────────────────────────────────────────────
-- 3. The substrate: one scored row per forward event. Pollers read v_event_demand_tier (§6).
-- ─────────────────────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.event_demand_signal (
  tevo_event_id        bigint PRIMARY KEY,
  event_name           text,
  venue_id             bigint,
  primary_performer_id int,
  occurs_at            timestamptz,
  hours_to_event       numeric,

  -- FEED 1 -- SeatGeek public sales (the tape)
  sg_sales_7d          int     NOT NULL DEFAULT 0,
  sg_sales_30d         int     NOT NULL DEFAULT 0,
  sg_qty_30d           int     NOT NULL DEFAULT 0,
  sg_med_price         numeric,
  sg_getin_price       numeric,                  -- p10 of CLEARED price, not a live ask. Header §3.
  sg_first_seen_at     timestamptz,
  sg_last_sale_at      timestamptz,
  sg_observed_days     numeric,                  -- span of OUR coverage. NULL = never observed.

  -- FEED 2 -- GoTickets purchases (our buy book)
  gt_purchases_90d     int     NOT NULL DEFAULT 0,
  gt_spend_90d         numeric NOT NULL DEFAULT 0,
  gt_cancels_90d       int     NOT NULL DEFAULT 0,

  -- FEED 3 -- the loss ledger (what we lost for)
  loss_n               int     NOT NULL DEFAULT 0,
  loss_amount          numeric NOT NULL DEFAULT 0,
  graded_n             int     NOT NULL DEFAULT 0,
  loss_rate            numeric,
  loss_basis           text    NOT NULL DEFAULT 'none',   -- event | venue | performer | none

  -- retained existing signal
  owned_count          int     NOT NULL DEFAULT 0,
  -- Which sources can actually poll this event. TEvo covers the whole forward catalogue; GoTickets
  -- only what carries a mapping, which is why the two plans cost different amounts over different
  -- populations rather than one plan costing double.
  pollable_gt          boolean NOT NULL DEFAULT false,

  -- scoring (each 0..1, rank-normalised within the batch)
  value_r              numeric,
  velocity_r           numeric,
  exposure_r           numeric,
  loss_r               numeric,
  owned_r              numeric,
  demand_score         numeric,                  -- NULL = unscorable (never observed) -> T_PROBE
  tier                 text    NOT NULL,
  tier_rank            int,
  computed_at          timestamptz NOT NULL DEFAULT now()
);
REVOKE ALL ON TABLE public.event_demand_signal FROM anon;

CREATE INDEX IF NOT EXISTS event_demand_signal_tier_idx    ON public.event_demand_signal (tier, occurs_at);
CREATE INDEX IF NOT EXISTS event_demand_signal_score_idx   ON public.event_demand_signal (demand_score DESC NULLS LAST);
CREATE INDEX IF NOT EXISTS event_demand_signal_venue_idx   ON public.event_demand_signal (venue_id);

COMMENT ON TABLE public.event_demand_signal IS
  'Per-forward-event demand tier from the three CRM feeds: seatgeek_sales_snapshots (market tape), gotickets_purchases (our buy book), gotickets_deal_outcome (loss ledger). Rebuilt by event_demand_refresh(). demand_score NULL means the event has never been observed and was NOT scored low -- it is routed to the T_PROBE exploration slice instead. loss_basis says whether the loss component is this event''s own history or a venue/performer prior. A1 mig 20260916120000.';

COMMENT ON COLUMN public.event_demand_signal.sg_getin_price IS
  'Tenth percentile of CLEARED sale price over 30d, not a live get-in quote: brokerdata /sales returns no asks. Treat as a floor on recent transactions.';
COMMENT ON COLUMN public.event_demand_signal.sg_observed_days IS
  'Span of our own coverage WITHIN THE 30-DAY WINDOW (so it is capped at 30, and an event watched for a year still reads <= 30). The denominator for velocity, so that "we rarely poll it" cannot read as "nobody wants it". NULL = never observed. sg_first_seen_at is likewise the first pull inside that window, not the first pull ever.';
COMMENT ON COLUMN public.event_demand_signal.loss_basis IS
  'Which level fed the loss component: event (this event''s own graded deals), venue, performer, or none. A tier driven by an inherited prior is a weaker claim than one driven by the event''s own history.';

-- ─────────────────────────────────────────────────────────────────────────────────────────────
-- 4. The refresh. DRY RUN BY DEFAULT -- p_apply := false returns the plan and writes nothing.
--
--    Scoring is rank-based, not scale-based: every component goes through percent_rank() inside
--    the batch, so one 40,000-dollar event cannot swamp the score the way a log-of-dollars sum
--    would, and no weight needs recalibrating as the catalogue grows. Weights are pure relative
--    importance, read live from event_demand_weight.
--
--    Aggregate-then-join throughout (temp tables with indexes), matching sg_classify_events():
--    correlated access against the snapshot tables times out at this scale.
-- ─────────────────────────────────────────────────────────────────────────────────────────────
DROP FUNCTION IF EXISTS public.event_demand_refresh(boolean, int, int, int);
CREATE OR REPLACE FUNCTION public.event_demand_refresh(
  p_apply                 boolean DEFAULT false,
  p_horizon_days          int     DEFAULT 400,
  p_daily_budget          int     DEFAULT 56800,
  p_min_graded            int     DEFAULT 3,
  -- Activity qualification -- the operator's hourly rule. These two are the population levers;
  -- see the hourly arithmetic above the policy INSERT before touching them.
  p_activity_window_days  int     DEFAULT 30,   -- 7 or 30; 7 qualifies on the last week only
  p_activity_min_sales    int     DEFAULT 1,    -- "has sales" = at least this many in the window
  p_activity_min_buys     int     DEFAULT 1     -- "has purchases" = at least this many in 90d
)
RETURNS jsonb
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $fn$
DECLARE
  v_now        timestamptz := clock_timestamp();
  v_started    timestamptz := clock_timestamp();
  v_w          jsonb;
  v_wsum       numeric;
  v_null_caps  int;
  v_last_order int;
  v_null_order int;
  v_scored     int := 0;
  v_unscored   int := 0;
  v_qualified  int := 0;
  v_admitted   int := 0;
  v_overflow   int := 0;
  v_act_cap    int;
  v_middle     int := 0;
  v_share_sum  numeric;
  v_cost_gt    numeric := 0;
  v_gt_pop     int := 0;
  v_budgets    jsonb;
  v_src        RECORD;
  v_tmp        text;
  v_total      int := 0;
  v_cost       numeric := 0;
  v_rows_before int := 0;
  v_written    int := 0;
  v_deleted    int := 0;
  v_tiers      jsonb;
BEGIN
  IF current_user NOT IN ('service_role', 'postgres', 'supabase_admin') THEN
    RAISE EXCEPTION 'forbidden: %', current_user USING ERRCODE = '42501';
  END IF;
  PERFORM set_config('statement_timeout', '170000', true);

  -- ON COMMIT DROP frees these at COMMIT, not at RETURN, so a SECOND call inside the SAME
  -- transaction collides with the first call's tables and dies on 'relation "_ev" already exists'.
  -- That breaks the most natural way anyone will use this: BEGIN; dry run; look; apply; COMMIT.
  -- Dropping first makes the function re-entrant within a transaction. (Found by calling it twice
  -- in one SELECT -- every earlier test had used one call per autocommit statement and passed.)
  -- to_regclass rather than DROP IF EXISTS: the latter emits a NOTICE per missing table, which
  -- would put 13 lines of noise into the log on every clean run of a daily cron.
  FOREACH v_tmp IN ARRAY ARRAY['_ev','_gtmap','_sg','_gt','_loss_raw','_loss_venue','_loss_perf',
                               '_owned','_base','_scored','_final','_qualified','_assign'] LOOP
    IF to_regclass('pg_temp.' || v_tmp) IS NOT NULL THEN
      EXECUTE format('DROP TABLE %I', v_tmp);
    END IF;
  END LOOP;

  -- ── 4.0 Validate the ladder BEFORE doing any work. Exactly one non-probe tier may carry a NULL
  --        population_cap (the floor), and it must be the last one, or the cumulative boundaries
  --        below are nonsense and events fall through the ladder into no tier at all.
  -- Exactly one score tier carries no share: the floor, which takes the remainder and must sort
  -- last, or the cumulative share boundaries below are nonsense and events fall through the
  -- ladder into no tier at all.
  SELECT count(*) FILTER (WHERE share_pct IS NULL),
         max(sort_order),
         max(sort_order) FILTER (WHERE share_pct IS NULL)
    INTO v_null_caps, v_last_order, v_null_order
    FROM public.event_demand_policy WHERE enabled AND fill_mode = 'score';

  IF v_null_caps <> 1 OR v_null_order IS DISTINCT FROM v_last_order THEN
    RAISE EXCEPTION
      'event_demand_refresh: ladder invalid -- need exactly one enabled score tier with NULL share_pct (the floor), as the highest sort_order among score tiers (found % without a share, last one at %, highest sort_order %)',
      v_null_caps, v_null_order, v_last_order;
  END IF;

  -- Shares over 100 would assign the same event to two tiers; under 100 silently dumps the
  -- uncovered remainder of the MIDDLE onto the floor, which is the cliff this ladder exists to
  -- remove. Under is allowed but it is a choice, so it is stated back in the result.
  SELECT coalesce(sum(share_pct), 0) INTO v_share_sum
    FROM public.event_demand_policy WHERE enabled AND fill_mode = 'score';

  IF v_share_sum > 100 THEN
    RAISE EXCEPTION
      'event_demand_refresh: score-tier shares sum to % percent, which would assign some events to two tiers. They must sum to at most 100.',
      v_share_sum;
  END IF;

  -- An UNCAPPED activity tier is the one shape that can silently blow the budget wide open: its
  -- population is whatever the data says, and at 24 polls/day it only takes 2,367 qualifying
  -- events to exceed the whole day's allowance on its own. It must be capped.
  IF EXISTS (SELECT 1 FROM public.event_demand_policy
              WHERE enabled AND fill_mode = 'activity' AND population_cap IS NULL) THEN
    RAISE EXCEPTION
      'event_demand_refresh: an enabled activity tier has no population_cap -- its size is set by the data, so uncapped it can cost any amount. Give it a cap.';
  END IF;

  IF p_activity_window_days NOT IN (7, 30) THEN
    RAISE EXCEPTION
      'event_demand_refresh: p_activity_window_days must be 7 or 30 (got %) -- those are the two windows the tape aggregate actually computes',
      p_activity_window_days;
  END IF;

  SELECT jsonb_object_agg(component, weight), sum(weight)
    INTO v_w, v_wsum
    FROM public.event_demand_weight WHERE enabled;

  IF coalesce(v_wsum, 0) <= 0 THEN
    RAISE EXCEPTION 'event_demand_refresh: all component weights are zero or disabled -- every event would score identically';
  END IF;

  -- ── 4.1 Forward events only. The standing directive is that we do not poll the past, and a
  --        finished event cannot repay a request. Cast matches the EVO poller (mig 20260531150000).
  CREATE TEMP TABLE _ev ON COMMIT DROP AS
  SELECT e.id AS tevo_event_id,
         e.name AS event_name,
         e.venue_id::bigint            AS venue_id,
         e.primary_performer_id        AS primary_performer_id,
         e.occurs_at_local::timestamptz AS occurs_at,
         EXTRACT(epoch FROM (e.occurs_at_local::timestamptz - v_now)) / 3600.0 AS hours_to_event
    FROM public.events e
   WHERE e.occurs_at_local IS NOT NULL
     AND e.occurs_at_local::timestamptz >= v_now
     AND e.occurs_at_local::timestamptz <  v_now + make_interval(days => p_horizon_days);
  CREATE UNIQUE INDEX ON _ev (tevo_event_id);
  CREATE INDEX ON _ev (venue_id);
  CREATE INDEX ON _ev (primary_performer_id);

  -- Which forward events GoTickets can poll at all. Aggregate-then-join: one pass over the
  -- mapping, not a correlated EXISTS per event.
  CREATE TEMP TABLE _gtmap ON COMMIT DROP AS
  SELECT DISTINCT g.tevo_event_id
    FROM public.gotickets_event g
   WHERE g.tevo_event_id IS NOT NULL;
  CREATE UNIQUE INDEX ON _gtmap (tevo_event_id);

  -- ── 4.2 FEED 1 -- the public tape. sg_observed_days is the span of OUR coverage, and it is the
  --        velocity denominator so that thin coverage cannot masquerade as thin demand.
  CREATE TEMP TABLE _sg ON COMMIT DROP AS
  SELECT s.tevo_event_id,
         count(*) FILTER (WHERE s.sale_at_utc > v_now - interval '7 days')  AS sales_7d,
         count(*) FILTER (WHERE s.sale_at_utc > v_now - interval '30 days') AS sales_30d,
         coalesce(sum(s.quantity) FILTER (WHERE s.sale_at_utc > v_now - interval '30 days'), 0) AS qty_30d,
         percentile_cont(0.50) WITHIN GROUP (ORDER BY s.broadcast_price)
           FILTER (WHERE s.sale_at_utc > v_now - interval '30 days' AND s.broadcast_price > 0) AS med_price,
         percentile_cont(0.10) WITHIN GROUP (ORDER BY s.broadcast_price)
           FILTER (WHERE s.sale_at_utc > v_now - interval '30 days' AND s.broadcast_price > 0) AS getin_price,
         min(s.pulled_at) AS first_seen_at,
         max(s.sale_at_utc) AS last_sale_at,
         GREATEST(EXTRACT(epoch FROM (max(s.pulled_at) - min(s.pulled_at))) / 86400.0, 1.0) AS observed_days
    FROM public.seatgeek_sales_snapshots s
   WHERE s.tevo_event_id IS NOT NULL
     AND s.sale_at_utc > v_now - interval '30 days'
   GROUP BY s.tevo_event_id;
  CREATE UNIQUE INDEX ON _sg (tevo_event_id);

  -- ── 4.3 FEED 2 -- our buy book. Cancelled orders are counted separately, not as spend: a
  --        cancelled purchase is a signal about the event, but it is not money at risk on it.
  CREATE TEMP TABLE _gt ON COMMIT DROP AS
  SELECT coalesce(p.tevo_event_id, ge.tevo_event_id) AS tevo_event_id,
         count(*) FILTER (WHERE p.cancel_reason IS NULL)                     AS purchases_90d,
         coalesce(sum(p.order_total) FILTER (WHERE p.cancel_reason IS NULL), 0) AS spend_90d,
         count(*) FILTER (WHERE p.cancel_reason IS NOT NULL)                 AS cancels_90d
    FROM public.gotickets_purchases p
    LEFT JOIN public.gotickets_event ge ON ge.gt_event_id = p.gt_event_id
   WHERE p.create_time > v_now - interval '90 days'
     AND coalesce(p.tevo_event_id, ge.tevo_event_id) IS NOT NULL
   GROUP BY 1;
  CREATE UNIQUE INDEX ON _gt (tevo_event_id);

  -- ── 4.4 FEED 3 -- the loss ledger, graded at event level and then rolled up to venue and
  --        performer. The rollup is not a nicety: a forward event has no outcomes of its own, so
  --        without the prior this component is NULL for every row the table is about.
  CREATE TEMP TABLE _loss_raw ON COMMIT DROP AS
  SELECT d.tevo_event_id,
         ev.venue_id::bigint     AS venue_id,
         ev.primary_performer_id AS primary_performer_id,
         count(*)                                              AS graded_n,
         count(*) FILTER (WHERE d.outcome = 'LOSS')            AS loss_n,
         coalesce(sum(GREATEST(d.cost - coalesce(d.realized_net, d.cost), 0))
                  FILTER (WHERE d.outcome = 'LOSS'), 0)        AS loss_amount
    FROM public.gotickets_deal_outcome d
    JOIN public.events ev ON ev.id = d.tevo_event_id
   WHERE d.graded_at > v_now - interval '180 days'
   GROUP BY 1, 2, 3;
  CREATE INDEX ON _loss_raw (tevo_event_id);
  CREATE INDEX ON _loss_raw (venue_id);
  CREATE INDEX ON _loss_raw (primary_performer_id);

  CREATE TEMP TABLE _loss_venue ON COMMIT DROP AS
  SELECT venue_id, sum(graded_n) AS graded_n, sum(loss_n) AS loss_n, sum(loss_amount) AS loss_amount
    FROM _loss_raw WHERE venue_id IS NOT NULL GROUP BY venue_id;
  CREATE UNIQUE INDEX ON _loss_venue (venue_id);

  CREATE TEMP TABLE _loss_perf ON COMMIT DROP AS
  SELECT primary_performer_id AS pid, sum(graded_n) AS graded_n, sum(loss_n) AS loss_n, sum(loss_amount) AS loss_amount
    FROM _loss_raw WHERE primary_performer_id IS NOT NULL GROUP BY primary_performer_id;
  CREATE UNIQUE INDEX ON _loss_perf (pid);

  -- ── 4.5 Retained existing signal: do we hold stock. This is what the two live ladders grade on
  --        today, and dropping it here would silently overrule the 2026-05-14 operator directive.
  CREATE TEMP TABLE _owned ON COMMIT DROP AS
  SELECT m.tevo_event_id, max(coalesce(m.owned_tickets_count, 0)) AS owned_count
    FROM public.latest_event_metrics m
   WHERE m.tevo_event_id IS NOT NULL AND coalesce(m.owned_tickets_count, 0) > 0
   GROUP BY m.tevo_event_id;
  CREATE UNIQUE INDEX ON _owned (tevo_event_id);

  -- ── 4.6 Assemble and score.
  --
  --    UNKNOWN IS NOT ZERO. An event we have never polled on SeatGeek has no tape, and scoring its
  --    velocity as 0 would be the circularity defect wearing a different hat. So the two tape
  --    components are NULL for unobserved events, and the weighted sum renormalises over the
  --    components that actually have a value. An event is only scored at all if at least one
  --    DIRECT feed says something about it; an inherited venue prior is not evidence about this
  --    event, and an event with nothing but a prior goes to T_PROBE to be looked at instead.
  CREATE TEMP TABLE _base ON COMMIT DROP AS
  SELECT ev.*,
         sg.sales_7d, sg.sales_30d, sg.qty_30d, sg.med_price, sg.getin_price,
         sg.first_seen_at, sg.last_sale_at, sg.observed_days,
         coalesce(gt.purchases_90d, 0) AS purchases_90d,
         coalesce(gt.spend_90d, 0)     AS spend_90d,
         coalesce(gt.cancels_90d, 0)   AS cancels_90d,
         coalesce(ow.owned_count, 0)   AS owned_count,
         -- loss cascade: this event's own graded history, else the venue's, else the performer's
         CASE WHEN coalesce(le.graded_n, 0) >= p_min_graded THEN 'event'
              WHEN coalesce(lv.graded_n, 0) >= p_min_graded THEN 'venue'
              WHEN coalesce(lp.graded_n, 0) >= p_min_graded THEN 'performer'
              ELSE 'none' END AS loss_basis,
         CASE WHEN coalesce(le.graded_n, 0) >= p_min_graded THEN le.graded_n
              WHEN coalesce(lv.graded_n, 0) >= p_min_graded THEN lv.graded_n
              WHEN coalesce(lp.graded_n, 0) >= p_min_graded THEN lp.graded_n
              ELSE 0 END::int AS graded_n,
         CASE WHEN coalesce(le.graded_n, 0) >= p_min_graded THEN le.loss_n
              WHEN coalesce(lv.graded_n, 0) >= p_min_graded THEN lv.loss_n
              WHEN coalesce(lp.graded_n, 0) >= p_min_graded THEN lp.loss_n
              ELSE 0 END::int AS loss_n,
         CASE WHEN coalesce(le.graded_n, 0) >= p_min_graded THEN le.loss_amount
              WHEN coalesce(lv.graded_n, 0) >= p_min_graded THEN lv.loss_amount
              WHEN coalesce(lp.graded_n, 0) >= p_min_graded THEN lp.loss_amount
              ELSE 0 END AS loss_amount,
         (sg.tevo_event_id IS NOT NULL
          OR gt.tevo_event_id IS NOT NULL
          OR coalesce(ow.owned_count, 0) > 0
          OR coalesce(le.graded_n, 0) > 0) AS has_direct_evidence,
         (gm.tevo_event_id IS NOT NULL) AS pollable_gt
    FROM _ev ev
    LEFT JOIN _sg  sg ON sg.tevo_event_id = ev.tevo_event_id
    LEFT JOIN _gt  gt ON gt.tevo_event_id = ev.tevo_event_id
    LEFT JOIN _owned ow ON ow.tevo_event_id = ev.tevo_event_id
    LEFT JOIN _loss_raw   le ON le.tevo_event_id        = ev.tevo_event_id
    LEFT JOIN _loss_venue lv ON lv.venue_id             = ev.venue_id
    LEFT JOIN _loss_perf  lp ON lp.pid                  = ev.primary_performer_id
    LEFT JOIN _gtmap      gm ON gm.tevo_event_id        = ev.tevo_event_id;
  CREATE UNIQUE INDEX ON _base (tevo_event_id);

  -- Rank-normalise. The tape components rank only WITHIN the observed population, so an
  -- unobserved event is absent from that ranking rather than sitting at the bottom of it.
  CREATE TEMP TABLE _scored ON COMMIT DROP AS
  WITH r AS (
    SELECT b.*,
           -- Loss is scored as dollars lost PER GRADED DEAL, an intensity. A total would mean
           -- inheriting a busy venue's prior ranks every event in it highly on volume alone.
           --
           -- NULL, not 0, when nothing graded at any level. Zero purchases is a known zero -- we
           -- read our own book and it said nothing there -- but no graded deal at this event, its
           -- venue OR its performer is an absence of evidence. Scoring it 0 would file a venue we
           -- have never traded alongside a venue where we reliably do not lose money, which is the
           -- same mistake as scoring an unpolled event's velocity at 0.
           CASE WHEN b.graded_n > 0 THEN b.loss_amount / b.graded_n END AS loss_per_deal,
           CASE WHEN b.observed_days IS NULL THEN NULL
                ELSE coalesce(b.qty_30d, 0) * coalesce(b.med_price, 0) END      AS value_raw,
           CASE WHEN b.observed_days IS NULL THEN NULL
                ELSE coalesce(b.sales_30d, 0) / b.observed_days END             AS velocity_raw
      FROM _base b
  )
  SELECT r.*,
         CASE WHEN r.value_raw    IS NULL THEN NULL
              ELSE percent_rank() OVER (PARTITION BY (r.value_raw    IS NULL) ORDER BY r.value_raw)    END AS value_r,
         CASE WHEN r.velocity_raw IS NULL THEN NULL
              ELSE percent_rank() OVER (PARTITION BY (r.velocity_raw IS NULL) ORDER BY r.velocity_raw) END AS velocity_r,
         -- spend and owned rank over EVERY row: a zero there is measured, not missing.
         percent_rank() OVER (ORDER BY r.spend_90d)     AS exposure_r,
         CASE WHEN r.loss_per_deal IS NULL THEN NULL
              ELSE percent_rank() OVER (PARTITION BY (r.loss_per_deal IS NULL) ORDER BY r.loss_per_deal) END AS loss_r,
         percent_rank() OVER (ORDER BY r.owned_count)   AS owned_r
    FROM r;
  CREATE UNIQUE INDEX ON _scored (tevo_event_id);

  -- Weighted sum over the components that HAVE a value, renormalised by their weights alone.
  CREATE TEMP TABLE _final ON COMMIT DROP AS
  SELECT s.*,
         CASE WHEN NOT s.has_direct_evidence THEN NULL
              WHEN (CASE WHEN s.value_r    IS NULL THEN 0 ELSE coalesce((v_w->>'value')::numeric, 0)    END
                  + CASE WHEN s.velocity_r IS NULL THEN 0 ELSE coalesce((v_w->>'velocity')::numeric, 0) END
                  + CASE WHEN s.loss_r     IS NULL THEN 0 ELSE coalesce((v_w->>'loss')::numeric, 0)     END
                  + coalesce((v_w->>'exposure')::numeric, 0)
                  + coalesce((v_w->>'owned')::numeric, 0)) <= 0 THEN NULL
              ELSE ( coalesce(s.value_r    * coalesce((v_w->>'value')::numeric, 0), 0)
                   + coalesce(s.velocity_r * coalesce((v_w->>'velocity')::numeric, 0), 0)
                   + coalesce(s.loss_r     * coalesce((v_w->>'loss')::numeric, 0), 0)
                   + s.exposure_r * coalesce((v_w->>'exposure')::numeric, 0)
                   + s.owned_r    * coalesce((v_w->>'owned')::numeric, 0) )
                 / ( CASE WHEN s.value_r    IS NULL THEN 0 ELSE coalesce((v_w->>'value')::numeric, 0)    END
                   + CASE WHEN s.velocity_r IS NULL THEN 0 ELSE coalesce((v_w->>'velocity')::numeric, 0) END
                   + CASE WHEN s.loss_r     IS NULL THEN 0 ELSE coalesce((v_w->>'loss')::numeric, 0)     END
                   + coalesce((v_w->>'exposure')::numeric, 0)
                   + coalesce((v_w->>'owned')::numeric, 0) )
         END AS demand_score
    FROM _scored s;
  CREATE UNIQUE INDEX ON _final (tevo_event_id);

  -- ── 4.7 Assign tiers.
  --
  --    ACTIVITY IS CLAIMED FIRST. The operator's rule is a qualification, not a ranking: anything
  --    with sales against it, or anything we have bought, is polled hourly. It is still capped,
  --    because the size of that set is decided by the data and hourly is 24 polls a day -- 2,367
  --    qualifiers would eat the entire budget with nothing left for anything else. Within the
  --    qualifying set the cap is filled by demand_score, so when more qualify than fit it is the
  --    best of them that keep the hourly slot and the rest fall through to the score ladder.
  --    The overflow is COUNTED AND REPORTED rather than swallowed -- an operator who asked for
  --    hourly needs to know how much of it they actually got.
  SELECT population_cap INTO v_act_cap
    FROM public.event_demand_policy
   WHERE enabled AND fill_mode = 'activity' ORDER BY sort_order LIMIT 1;

  CREATE TEMP TABLE _qualified ON COMMIT DROP AS
  SELECT f.tevo_event_id,
         row_number() OVER (ORDER BY f.demand_score DESC NULLS LAST, f.tevo_event_id) AS rn
    FROM _final f
   WHERE (CASE WHEN p_activity_window_days <= 7
               THEN coalesce(f.sales_7d, 0) ELSE coalesce(f.sales_30d, 0) END) >= p_activity_min_sales
      OR f.purchases_90d >= p_activity_min_buys;
  CREATE UNIQUE INDEX ON _qualified (tevo_event_id);

  SELECT count(*) INTO v_qualified FROM _qualified;
  v_admitted := LEAST(v_qualified, coalesce(v_act_cap, 0));
  v_overflow := v_qualified - v_admitted;

  --    THE MIDDLE is every scored event the activity tier did not take, and each score tier takes
  --    share_pct OF THAT, so the slope is sized by the middle's own population rather than by
  --    fixed counts that go stale the moment the catalogue moves. Ties break on tevo_event_id so
  --    two runs over unchanged data assign identically.
  SELECT count(*) INTO v_middle
    FROM _final f
   WHERE f.demand_score IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM _qualified q
                      WHERE q.tevo_event_id = f.tevo_event_id AND q.rn <= coalesce(v_act_cap, 0));
  CREATE TEMP TABLE _assign ON COMMIT DROP AS
  WITH act_tier AS (
    SELECT tier, polls_per_day, population_cap
      FROM public.event_demand_policy
     WHERE enabled AND fill_mode = 'activity' ORDER BY sort_order LIMIT 1
  ),
  admitted AS (
    SELECT q.tevo_event_id, a.tier, q.rn::int AS tier_rank, a.polls_per_day
      FROM _qualified q CROSS JOIN act_tier a
     WHERE q.rn <= a.population_cap
  ),
  -- Everything the activity tier did not take is ranked by the score ladder -- including the
  -- qualifiers that overflowed its cap, which is why they are excluded here and not earlier.
  ranked AS (
    SELECT tevo_event_id,
           row_number() OVER (ORDER BY demand_score DESC, tevo_event_id) AS rn
      FROM _final f
     WHERE f.demand_score IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM admitted ad WHERE ad.tevo_event_id = f.tevo_event_id)
  ),
  -- Cumulative boundaries in ROWS, derived from the shares against the middle's real size.
  -- floor(share x middle / 100) per tier; the floor tier (share_pct NULL) takes whatever is left,
  -- which under a full 100% ladder is only the rounding remainder.
  ladder AS (
    SELECT tier, polls_per_day, sort_order,
           coalesce(sum(floor(share_pct * v_middle / 100.0)) OVER (ORDER BY sort_order
                     ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING), 0)::bigint AS lo,
           CASE WHEN share_pct IS NULL THEN NULL
                ELSE sum(floor(share_pct * v_middle / 100.0)) OVER (ORDER BY sort_order)::bigint
           END AS hi
      FROM public.event_demand_policy WHERE enabled AND fill_mode = 'score'
  ),
  probe AS (
    SELECT f.tevo_event_id,
           row_number() OVER (ORDER BY f.occurs_at, f.tevo_event_id) AS rn
      FROM _final f
     WHERE f.demand_score IS NULL
       AND NOT EXISTS (SELECT 1 FROM admitted ad WHERE ad.tevo_event_id = f.tevo_event_id)
  ),
  probe_tier AS (
    SELECT tier, polls_per_day, population_cap
      FROM public.event_demand_policy WHERE enabled AND fill_mode = 'probe' ORDER BY sort_order LIMIT 1
  )
  SELECT tevo_event_id, tier, tier_rank, polls_per_day FROM admitted
  UNION ALL
  SELECT r.tevo_event_id, l.tier, r.rn::int, l.polls_per_day
    FROM ranked r
    JOIN ladder l ON r.rn > l.lo AND (l.hi IS NULL OR r.rn <= l.hi)
  UNION ALL
  SELECT p.tevo_event_id, pt.tier, p.rn::int, pt.polls_per_day
    FROM probe p CROSS JOIN probe_tier pt
   WHERE pt.population_cap IS NULL OR p.rn <= pt.population_cap;
  CREATE UNIQUE INDEX ON _assign (tevo_event_id);

  -- Unscored events beyond the probe cap still need a home, or they silently vanish from the
  -- plan and nobody polls them at all. They fall to the floor tier -- the whole point of which
  -- is that nothing goes dark.
  INSERT INTO _assign (tevo_event_id, tier, tier_rank, polls_per_day)
  SELECT f.tevo_event_id, pol.tier, NULL, pol.polls_per_day
    FROM _final f
    CROSS JOIN LATERAL (
      SELECT tier, polls_per_day FROM public.event_demand_policy
       WHERE enabled AND fill_mode = 'score' AND share_pct IS NULL
       ORDER BY sort_order LIMIT 1) pol
   WHERE NOT EXISTS (SELECT 1 FROM _assign a WHERE a.tevo_event_id = f.tevo_event_id);

  -- ── 4.8 Cost the plan BEFORE writing it. See defect 4 in the header: a ladder that cannot be
  --        afforded must fail here, loudly, and not at poll time as a silent dropped page.
  SELECT count(*) FILTER (WHERE demand_score IS NOT NULL),
         count(*) FILTER (WHERE demand_score IS NULL),
         count(*)
    INTO v_scored, v_unscored, v_total
    FROM _final;

  SELECT coalesce(sum(polls_per_day), 0) INTO v_cost FROM _assign;

  -- GoTickets is polled too, over its OWN population: only events carrying a GT mapping. Its cost
  -- is a second plan against a second ceiling, not a doubling of this one -- a GT request does not
  -- spend TEvo's allowance.
  SELECT coalesce(sum(a.polls_per_day), 0), count(*)
    INTO v_cost_gt, v_gt_pop
    FROM _assign a JOIN _final f ON f.tevo_event_id = a.tevo_event_id
   WHERE f.pollable_gt;

  SELECT jsonb_object_agg(tier, jsonb_build_object('events', n, 'polls_per_day', ppd))
    INTO v_tiers
    FROM (SELECT tier, count(*) AS n, round(sum(polls_per_day), 1) AS ppd
            FROM _assign GROUP BY tier) t;

  -- Cost every configured source and say plainly which ones could be CHECKED. An unmeasured
  -- ceiling is reported, never silently treated as satisfied: a NULL budget is ignorance, not
  -- headroom, and this is the line where that distinction either holds or quietly stops holding.
  SELECT jsonb_object_agg(x.source, x.row) INTO v_budgets FROM (
    SELECT b2.source,
           jsonb_build_object(
             'events',       CASE WHEN b2.source = 'GT' THEN v_gt_pop ELSE v_total END,
             'polls_per_day',round(CASE WHEN b2.source = 'GT' THEN v_cost_gt ELSE v_cost END, 0),
             'daily_budget', b2.daily_budget,
             'enforced',     b2.enforced AND b2.daily_budget IS NOT NULL,
             'status',       CASE
               WHEN b2.daily_budget IS NULL THEN 'UNMEASURED -- cost reported, NOT checked'
               WHEN (CASE WHEN b2.source = 'GT' THEN v_cost_gt ELSE v_cost END) > b2.daily_budget
                    THEN 'OVER BUDGET'
               ELSE 'fits' END) AS row
      FROM public.event_demand_source_budget b2
     WHERE b2.source IN ('TEVO', 'GT')) x;

  -- Any source with a known, enforced ceiling can veto the whole plan, not just TEvo.
  FOR v_src IN
    SELECT source, daily_budget,
           CASE WHEN source = 'GT' THEN v_cost_gt ELSE v_cost END AS src_cost
      FROM public.event_demand_source_budget
     WHERE enforced AND daily_budget IS NOT NULL AND source IN ('TEVO', 'GT')
  LOOP
    IF v_src.src_cost > v_src.daily_budget THEN
      RAISE EXCEPTION
        'event_demand_refresh: % plan costs % polls/day against its own budget of % -- over by %. Nothing written. Budgets: %',
        v_src.source, round(v_src.src_cost, 0), v_src.daily_budget,
        round(v_src.src_cost, 0) - v_src.daily_budget, v_budgets;
    END IF;
  END LOOP;

  IF v_cost > p_daily_budget THEN
    RAISE EXCEPTION
      'event_demand_refresh: plan costs % polls/day against a budget of % -- over by %. Nothing written. The activity tier is usually the cause: % events qualified, % admitted at % polls/day each. Narrow it (p_activity_window_days => 7, or raise p_activity_min_sales) or lower its population_cap before touching the score tiers. Tiers: %',
      round(v_cost, 0), p_daily_budget, round(v_cost, 0) - p_daily_budget,
      v_qualified, v_admitted,
      coalesce((SELECT polls_per_day FROM public.event_demand_policy
                 WHERE enabled AND fill_mode = 'activity' ORDER BY sort_order LIMIT 1), 0),
      v_tiers;
  END IF;

  IF NOT p_apply THEN
    RETURN jsonb_build_object(
      'applied', false,
      'note', 'DRY RUN -- nothing written. Pass p_apply => true to publish.',
      'events_total', v_total, 'events_scored', v_scored, 'events_unscored_probe', v_unscored,
      'activity', jsonb_build_object(
        'qualified', v_qualified, 'admitted', v_admitted, 'overflow', v_overflow,
        'window_days', p_activity_window_days,
        'min_sales', p_activity_min_sales, 'min_purchases', p_activity_min_buys,
        'note', CASE WHEN v_overflow > 0
                     THEN v_overflow || ' events have sales or purchases but did NOT get the hourly slot -- they fell through to the score ladder. Widen the cap only if the budget allows, or narrow qualification.'
                     ELSE 'every qualifying event got the hourly slot' END),
      'middle_events', v_middle, 'middle_share_pct', v_share_sum,
      'by_source', v_budgets,
      'middle_events', v_middle, 'middle_share_pct', v_share_sum,
    'by_source', v_budgets,
    'planned_polls_per_day', round(v_cost, 0), 'daily_budget', p_daily_budget,
      'budget_used_pct', round(100 * v_cost / NULLIF(p_daily_budget, 0), 1),
      'weights', v_w, 'tiers', v_tiers,
      'elapsed_ms', round(EXTRACT(epoch FROM (clock_timestamp() - v_started)) * 1000));
  END IF;

  -- ── 4.9 Collapse guard, same shape as evo_gt_pipeline_tick: a rebuild that loses most of its
  --        population is a fault upstream, not a real change in demand, and publishing it would
  --        take the whole catalogue dark before anyone noticed.
  SELECT count(*) INTO v_rows_before FROM public.event_demand_signal;
  IF v_rows_before > 1000 AND v_total < (v_rows_before * 0.8)::int THEN
    RAISE EXCEPTION
      'event_demand_refresh: population collapsed % -> % (< 80%%), refusing to publish; nothing written',
      v_rows_before, v_total;
  END IF;

  INSERT INTO public.event_demand_signal AS t (
    tevo_event_id, event_name, venue_id, primary_performer_id, occurs_at, hours_to_event,
    sg_sales_7d, sg_sales_30d, sg_qty_30d, sg_med_price, sg_getin_price,
    sg_first_seen_at, sg_last_sale_at, sg_observed_days,
    gt_purchases_90d, gt_spend_90d, gt_cancels_90d,
    loss_n, loss_amount, graded_n, loss_rate, loss_basis, owned_count, pollable_gt,
    value_r, velocity_r, exposure_r, loss_r, owned_r, demand_score, tier, tier_rank, computed_at)
  SELECT f.tevo_event_id, f.event_name, f.venue_id, f.primary_performer_id, f.occurs_at, f.hours_to_event,
         coalesce(f.sales_7d, 0), coalesce(f.sales_30d, 0), coalesce(f.qty_30d, 0),
         f.med_price, f.getin_price, f.first_seen_at, f.last_sale_at, f.observed_days,
         f.purchases_90d, f.spend_90d, f.cancels_90d,
         f.loss_n, f.loss_amount, f.graded_n,
         CASE WHEN f.graded_n > 0 THEN round(f.loss_n::numeric / f.graded_n, 4) END,
         f.loss_basis, f.owned_count, f.pollable_gt,
         f.value_r, f.velocity_r, f.exposure_r, f.loss_r, f.owned_r, f.demand_score,
         a.tier, a.tier_rank, v_now
    FROM _final f JOIN _assign a ON a.tevo_event_id = f.tevo_event_id
  ON CONFLICT (tevo_event_id) DO UPDATE SET
    event_name = EXCLUDED.event_name, venue_id = EXCLUDED.venue_id,
    primary_performer_id = EXCLUDED.primary_performer_id,
    occurs_at = EXCLUDED.occurs_at, hours_to_event = EXCLUDED.hours_to_event,
    sg_sales_7d = EXCLUDED.sg_sales_7d, sg_sales_30d = EXCLUDED.sg_sales_30d,
    sg_qty_30d = EXCLUDED.sg_qty_30d, sg_med_price = EXCLUDED.sg_med_price,
    sg_getin_price = EXCLUDED.sg_getin_price, sg_first_seen_at = EXCLUDED.sg_first_seen_at,
    sg_last_sale_at = EXCLUDED.sg_last_sale_at, sg_observed_days = EXCLUDED.sg_observed_days,
    gt_purchases_90d = EXCLUDED.gt_purchases_90d, gt_spend_90d = EXCLUDED.gt_spend_90d,
    gt_cancels_90d = EXCLUDED.gt_cancels_90d,
    loss_n = EXCLUDED.loss_n, loss_amount = EXCLUDED.loss_amount, graded_n = EXCLUDED.graded_n,
    loss_rate = EXCLUDED.loss_rate, loss_basis = EXCLUDED.loss_basis,
    owned_count = EXCLUDED.owned_count, pollable_gt = EXCLUDED.pollable_gt,
    value_r = EXCLUDED.value_r, velocity_r = EXCLUDED.velocity_r, exposure_r = EXCLUDED.exposure_r,
    loss_r = EXCLUDED.loss_r, owned_r = EXCLUDED.owned_r, demand_score = EXCLUDED.demand_score,
    tier = EXCLUDED.tier, tier_rank = EXCLUDED.tier_rank, computed_at = EXCLUDED.computed_at;
  GET DIAGNOSTICS v_written = ROW_COUNT;

  -- Events that have left the horizon (now in the past) stop being this table's business.
  DELETE FROM public.event_demand_signal d
   WHERE NOT EXISTS (SELECT 1 FROM _final f WHERE f.tevo_event_id = d.tevo_event_id);
  GET DIAGNOSTICS v_deleted = ROW_COUNT;

  RETURN jsonb_build_object(
    'applied', true,
    'events_total', v_total, 'events_scored', v_scored, 'events_unscored_probe', v_unscored,
    'rows_written', v_written, 'rows_retired', v_deleted, 'rows_before', v_rows_before,
    'activity', jsonb_build_object(
      'qualified', v_qualified, 'admitted', v_admitted, 'overflow', v_overflow,
      'window_days', p_activity_window_days,
      'min_sales', p_activity_min_sales, 'min_purchases', p_activity_min_buys),
    'middle_events', v_middle, 'middle_share_pct', v_share_sum,
    'by_source', v_budgets,
    'planned_polls_per_day', round(v_cost, 0), 'daily_budget', p_daily_budget,
    'budget_used_pct', round(100 * v_cost / NULLIF(p_daily_budget, 0), 1),
    'weights', v_w, 'tiers', v_tiers,
    'elapsed_ms', round(EXTRACT(epoch FROM (clock_timestamp() - v_started)) * 1000));
END $fn$;

REVOKE ALL ON FUNCTION public.event_demand_refresh(boolean, int, int, int, int, int, int) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.event_demand_refresh(boolean, int, int, int, int, int, int) TO service_role;

COMMENT ON FUNCTION public.event_demand_refresh(boolean, int, int, int, int, int, int) IS
  'Rebuilds event_demand_signal from the three CRM feeds and assigns demand tiers. DRY RUN unless p_apply => true. The activity tier is claimed first (operator rule 2026-09-16: anything with sales, or anything we have purchased, is polled hourly), capped, and filled by demand_score within the qualifying set; the result ALWAYS reports qualified/admitted/overflow so a silently-demoted qualifier cannot pass for hourly coverage. Costs the plan against p_daily_budget (default 56,800 = 0.73 req/s proven x 24h less a 10% retry reserve) and RAISES rather than publishing a ladder that overruns it. p_daily_budget describes TEvo; brokerdata.seatgeek.com is a separate limit that tolerates far more, and GoTickets has never been rate-laddered at all. Cost is one poll per event: a mapped EVO<->GT pair polled on both sides costs two. A1 mig 20260916120000.';

-- ─────────────────────────────────────────────────────────────────────────────────────────────
-- 5. The contract the pollers read. Thin on purpose: a poller should need the tier, the cadence
--    and the due time, and nothing about how any of them were derived.
-- ─────────────────────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE VIEW public.v_event_demand_tier AS
SELECT s.tevo_event_id,
       s.event_name,
       s.occurs_at,
       s.hours_to_event,
       s.tier,
       s.tier_rank,
       s.demand_score,
       p.polls_per_day,
       CASE WHEN p.polls_per_day > 0
            THEN round(1440.0 / p.polls_per_day)::int END AS interval_minutes,
       s.loss_basis,
       (s.sg_observed_days IS NULL) AS unobserved,
       s.computed_at
  FROM public.event_demand_signal s
  JOIN public.event_demand_policy p ON p.tier = s.tier AND p.enabled;

REVOKE ALL ON public.v_event_demand_tier FROM anon;
GRANT SELECT ON public.v_event_demand_tier TO service_role;

COMMENT ON VIEW public.v_event_demand_tier IS
  'Poller-facing contract for demand tiers: tier, polls_per_day and the derived interval_minutes per forward tevo_event_id. Nothing reads this yet -- wiring collector_band()/sg_priority_policy to it is a separate, separately reviewed migration (see the header of A1 mig 20260916120000).';

-- ==============================================================================================
-- VERIFIED ON A LOCAL POSTGRES 16.13, 2026-09-16 -- NOT ON PROD
-- ==============================================================================================
-- Supabase was unreachable, so this was executed against a local cluster carrying the real column
-- shapes of events, seatgeek_sales_snapshots, gotickets_purchases, gotickets_event,
-- gotickets_deal_outcome and latest_event_metrics, loaded with a synthetic catalogue sized to the
-- measured one: 107,341 forward events; a tape on 30,000 (10,000 actively trading, 20,000 with a
-- single sale 20 days old, so the qualification window actually discriminates); our purchases on
-- 600 events with NO tape; owned stock on 400 more with no tape; 20,000 graded deals confined to
-- a minority of venues; and a GoTickets mapping on 26,612 events, matching the pipeline's accepted
-- count, so the two source plans cover genuinely different populations.
--
-- This proves the code runs, the guards fire and the arithmetic closes. It proves NOTHING about
-- prod's distributions, about how many events qualify for hourly, or about GoTickets' ceiling.
--
--   MIGRATION APPLIES CLEAN                       yes
--   REFRESH, 107,341 events                       2.6s, dry run and apply alike
--   TEVO PLAN                                     51,174 polls/day = 90.1% of its 56,800 budget
--   GT PLAN                                       34,634 polls/day over 26,612 events,
--                                                 UNMEASURED -- reported, not enforced
--   DETERMINISM                                   two consecutive applies: 0 rows differ
--
--   THE SLOPE, with no cliff anywhere in it:
--     T0_HOURLY   1,000 @ 60min      (activity: has sales, or we bought it)
--     M1_FAST       894 @ 360min     top 3% of the middle
--     M2_BRISK    2,086 @ 720min     next 7%
--     M3_STEADY   4,470 @ 1440min    next 15%
--     M4_SLOW     7,450 @ 2880min    next 25%
--     M5_TRICKLE 14,900 @ 7200min    bottom 50% -- still 5x the floor
--     T_PROBE     3,000 @ 1440min    never observed; soonest first
--     T6_FLOOR   73,541 @ 20168min   no evidence at all
--
--   THE CLIFF THIS REMOVED, measured before and after on the same fixture:
--     before   T5_FLOOR held 19,600 SCORED events alongside 73,341 unscored -- events with a
--              tape, our own purchases and graded losses, polled at exactly the rate of events
--              nothing had ever been observed about
--     after    the floor holds 0 scored events. Every event we have evidence about sits somewhere
--              on the M1..M5 slope.
--
--   THE HOURLY RULE, MEASURED:
--     qualified (sales in 30d OR a purchase in 90d)   30,546
--     admitted at the 1,000 cap                        1,000
--     overflow -- qualified but not hourly            29,546  (these now land on the slope, not
--                                                              on the floor -- that is the change)
--     honouring it in full                           733,104 polls/day = 12.9x the TEvo budget
--
--   GOTICKETS IS NOT A PROPORTIONAL SHARE OF THE COST, which is the surprise worth keeping:
--     GT-pollable events        26,612  =  25% of the catalogue
--     GT plan cost              34,634  =  68% of the TEvo plan's cost
--   Mapping correlates with activity, and activity is what buys cadence -- 754 of the 1,000 hourly
--   events are GT-pollable. So the mapped quarter of the catalogue is most of the expensive part,
--   and a GT ceiling far below TEvo's would bind on THIS plan long before TEvo's did.
--
--   GUARDS -- each RAISEs and writes nothing:
--     TEvo budget overrun       cap 1,120 costs 56,951 against 56,800    -> refused
--     GT budget overrun         GT budget set to 20,000 vs 34,634        -> refused
--     shares over 100           M5 share 50 -> 60, sum 110               -> refused
--     no floor tier             every score tier given a share           -> refused
--     floor not last            floor moved off the highest sort_order   -> refused
--     uncapped activity tier    T0_HOURLY population_cap set NULL        -> refused
--     bad activity window       p_activity_window_days => 14             -> refused
--     population collapse       horizon cut to 30d, 107,341 -> 8,969     -> refused
--     all weights disabled      every component enabled=false            -> refused
--     non-privileged caller     role authenticated                       -> permission denied
--
-- FOUND BY RUNNING IT, NOT BY READING IT -- all real defects in earlier drafts:
--   1. The first ladder cost 59,030 polls/day against its own 56,800 budget. The header's
--      arithmetic predated the T_PROBE tier and never had its 5,000/day added back in.
--   2. The loss component scored "no graded deal at this event, its venue or its performer" as
--      0.0 -- filing a venue we have never traded next to one where we reliably do not lose money.
--   3. A fixture that could not tell the two qualification levers apart: every tape event in it
--      had 8 recent sales, so window=7 and min_sales=3 both reported an unchanged population and
--      looked inert. They were not; the fixture was.
--   4. The fixed-count middle stranded 19,600 SCORED events on the weekly floor -- only visible
--      by grouping the applied table by tier and counting how many had a demand_score. Reading
--      the ladder, 400/1,000/3,000/6,000 looks like a reasonable spread; it covers a third of the
--      middle and the rest falls off the end.
--   5. A GT source row that read identically to TEvo, because the first fixture mapped every
--      event to GoTickets. The per-source split was untestable until the mapping was cut to a
--      realistic 26,612 -- and only then did the 25%-of-events / 68%-of-cost skew appear.
--   6. NOT RE-ENTRANT WITHIN A TRANSACTION. ON COMMIT DROP frees the temp tables at COMMIT, not at
--      RETURN, so a SECOND call inside the SAME transaction died on 'relation "_ev" already
--      exists'. Every earlier test had made one call per autocommit statement and passed, so this
--      survived ten guard tests and two determinism runs unseen. It breaks the most natural way
--      anyone would actually use this -- BEGIN; dry run; look at it; apply; COMMIT -- which is
--      exactly the sequence the pre-apply checklist tells an operator to run. Fixed by dropping
--      the temp tables at entry, via to_regclass rather than DROP IF EXISTS so a clean run does
--      not put 13 NOTICE lines into a daily cron's log. Both paths now verified:
--        two calls in one SELECT        -> 51,174/day, 90.1%
--        dry run then apply, one txn    -> applied=false, then 107,341 rows written
--
-- BEFORE APPLYING TO PROD
--   1. Run with p_apply => false and read activity.overflow and by_source FIRST.
--   2. GT's budget is NULL, so its plan is reported and NOT checked. That is ignorance, not
--      headroom. Ladder GoTickets (20/40/80) and set a real number. The cheaper escape route has
--      already been tested and closed: /rest/events/delta does NOT move on listing changes
--      (3 of 3,076 events whose inventory moved, 2026-09-16 -- see the source-budget section),
--      so per-event polling is genuinely required and 34,634/day is genuinely what it costs.
--   3. Read the tier histogram. If T0/M1 fill with events carrying no tape, exposure/loss are
--      dominating a sparse column -- see the note above event_demand_weight.
--   4. Confirm events.occurs_at_local casts as the EVO poller assumes (mig 20260531150000).

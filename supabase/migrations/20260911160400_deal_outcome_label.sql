-- ============================================================================
-- Migration 20260911160400 — DEAL OUTCOME LABEL: grade every played deal
--
-- Lane:     D0 (deals surface)
-- Touches:  gotickets_deal_outcome (W, new) · grade_deal_outcomes() (W, new fn) ·
--           v_deal_calibration (new view) · get_deal_calibration() (new read RPC) ·
--           cron_policy (W, +1 row) · cron.job (W, deal_outcome_grade_daily)
--           Reads: gotickets_deals_feed, events, performer_metadata,
--           performer_zone_rules, seatgeek_sales_snapshots, seatdata_sales_snapshots,
--           v_s4kcs_orders, order_fee_schedule; fns gt_curated_zone_id, section_in_range
-- Pre-reqs: 20260911160300 (feed prod columns), 20260811272000 (gt_curated_zone_id),
--           20260811220000 (feed win_prob/confidence cols), 20260909220000 (v_s4kcs_orders)
--
-- WHY (operator direction 2026-09-11: "start with the outcome label"). The DEALS
-- feed has produced 5,131 rows since 2026-08-11 and NOTHING grades them: the
-- shadow table's realized_eol was never filled, deal_tracking holds one 10-row
-- cohort, and the calibration readout only exists as ad-hoc session SQL. Every
-- signal we want to add next (trend, standings, sentiment, our own purchases)
-- needs a label to be weighted against. This is that label — one row per played
-- deal, graded the same way the scanner priced it.
--
-- LABEL = what the seat actually cleared at, event-day, net of the resale fee:
--   * POOL: realized sales for the event in [event_date - p_window_days, event_date]
--     from THREE sources — SeatGeek sales (sg_sale_id-deduped), SeatData sales
--     (content_hash-deduped) and S4K's own CRM sales (v_s4kcs_orders.price_per_ticket,
--     non-REJECTED; CRM rows with no purchase_date — the SeatGeek marketplace
--     rows — count as event-level comps of unknown date).
--   * MATCH LEVEL, finest first, needing >= p_min_comps sales:
--       zone    — same CURATED zone as the deal (gt_curated_zone_id on the deal's
--                 section; the sale's section tested with performer_zone_rules +
--                 section_in_range — the scanner's own anchor logic, verbatim),
--       section — same section NUMBER,
--       event   — whole event (recorded, but LOW trust: Field 126 on 3091464 has a
--                 $114 zone median vs a $44 event median; exclude by default).
--   * REALIZED: median/p25/p75 at the chosen level, per-source counts, and
--     realized_win_share = share of comps whose net proceeds clear
--     (1 + p_roi_target) × cost — the empirical twin of the feed's win_prob.
--   * OUTCOME: WIN (net median >= +15%) · FLAT (>= cost) · LOSS · NO_COMPS.
--   * PREDICTION SNAPSHOT copied from the feed at grade time (win_prob,
--     net_profit_pct, confidence, resale_basis, regime, mod_z, vs_zone_pct) so
--     calibration never depends on the feed row surviving a rescan.
--   * LISTING SIGNAL: gone_at / hours_alive / gone_before_event — did the flagged
--     listing itself disappear (sold or pulled) before the event.
--
-- Grades rows once event_date <= yesterday (lets the sales pulls land). NO_COMPS
-- rows are re-graded daily for p_regrade_days so late-arriving sales upgrade them.
-- Set-based, bounded (p_max rows/run, statement_timeout), service_role-guarded.
-- Our own PURCHASE side (SeatGeek buy-side orders) is a follow-up that attaches
-- an 'own_flip' basis to this same key; the meta jsonb is the forward-compat slot.
--
-- Measured shape on the 4 sample deals (2026-09-11, ev 3091464/3101512/3101513):
-- zone_n 30/16/30/2, sec_n 0/2/3/1, ev_n 426/426/296/186 — zone level resolves
-- for the large zones, section fills the gap, event never wins by default.
--
-- READ-ONLY upstream: no API call. Pure SELECT over ingested data.
-- ROLLBACK: SELECT cron.unschedule('deal_outcome_grade_daily');
--           DELETE FROM public.cron_policy WHERE jobname='deal_outcome_grade_daily';
--           DROP FUNCTION public.get_deal_calibration(text,int);
--           DROP VIEW public.v_deal_calibration;
--           DROP FUNCTION public.grade_deal_outcomes(int,int,int,numeric,numeric,int);
--           DROP TABLE public.gotickets_deal_outcome;
-- ============================================================================

-- ── 1. Outcome table ─────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.gotickets_deal_outcome (
  tevo_event_id        bigint      NOT NULL,
  gt_listing_id        bigint      NOT NULL,
  -- deal identity (denormalised so the label survives feed rescans)
  event_date           date        NOT NULL,
  section              text,
  secnum               text,
  zone_id              bigint,               -- performer_zones.id via gt_curated_zone_id
  zone_name            text,
  quantity             int,
  cost                 numeric     NOT NULL, -- gt_price at flag time
  first_seen_at        timestamptz,
  -- prediction snapshot (feed values at grade time)
  pred_win_prob        numeric,
  pred_net_profit_pct  int,
  pred_confidence      text,
  pred_resale_basis    text,
  pred_realized_n      int,
  pred_regime          text,
  pred_mod_z           numeric,
  pred_vs_zone_pct     int,
  -- realized pool, per match level (event-day window)
  zone_n               int         NOT NULL DEFAULT 0,
  zone_med             numeric,
  sec_n                int         NOT NULL DEFAULT 0,
  sec_med              numeric,
  ev_n                 int         NOT NULL DEFAULT 0,
  ev_med               numeric,
  -- chosen level + realized readout
  match_level          text        NOT NULL, -- 'zone' | 'section' | 'event' | 'none'
  realized_n           int         NOT NULL DEFAULT 0,
  realized_med         numeric,
  realized_p25         numeric,
  realized_p75         numeric,
  realized_sg_n        int         NOT NULL DEFAULT 0,
  realized_sd_n        int         NOT NULL DEFAULT 0,
  realized_crm_n       int         NOT NULL DEFAULT 0,
  seller_fee_pct       numeric     NOT NULL,
  realized_net         numeric,               -- realized_med × (1 − fee)
  realized_roi_pct     numeric,               -- (realized_net − cost) / cost × 100
  realized_win_share   numeric,               -- share of comps clearing (1+target)×cost net
  outcome              text        NOT NULL, -- 'WIN' | 'FLAT' | 'LOSS' | 'NO_COMPS'
  -- listing signal
  listing_gone_at      timestamptz,
  hours_alive          numeric,
  gone_before_event    boolean,
  -- bookkeeping
  graded_at            timestamptz NOT NULL DEFAULT now(),
  grade_version        int         NOT NULL DEFAULT 1,
  params               jsonb       NOT NULL DEFAULT '{}'::jsonb,
  meta                 jsonb       NOT NULL DEFAULT '{}'::jsonb,
  created_at           timestamptz NOT NULL DEFAULT now(),
  updated_at           timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (tevo_event_id, gt_listing_id),
  CONSTRAINT gotickets_deal_outcome_level_chk
    CHECK (match_level IN ('zone','section','event','none')),
  CONSTRAINT gotickets_deal_outcome_outcome_chk
    CHECK (outcome IN ('WIN','FLAT','LOSS','NO_COMPS'))
);
ALTER TABLE public.gotickets_deal_outcome ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS gotickets_deal_outcome_event_date_idx
  ON public.gotickets_deal_outcome (event_date DESC);
CREATE INDEX IF NOT EXISTS gotickets_deal_outcome_outcome_idx
  ON public.gotickets_deal_outcome (outcome, match_level);
GRANT SELECT ON public.gotickets_deal_outcome TO authenticated, service_role;
COMMENT ON TABLE public.gotickets_deal_outcome IS
  'Outcome LABEL for every played GoTickets deal (one row per feed (event, listing)). Realized = event-day sales (SeatGeek + SeatData + S4K CRM) matched at the finest level with >= p_min_comps: curated zone > section number > event. realized_net = median x (1-fee); outcome WIN/FLAT/LOSS/NO_COMPS; prediction snapshot copied from the feed at grade time. Written only by grade_deal_outcomes(). D0 mig 20260911160400.';

-- ── 2. Grader ────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.grade_deal_outcomes(
  p_max           int     DEFAULT 300,
  p_window_days   int     DEFAULT 4,
  p_min_comps     int     DEFAULT 3,
  p_roi_target    numeric DEFAULT 0.15,
  p_fee           numeric DEFAULT NULL,
  p_regrade_days  int     DEFAULT 14
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_fee     numeric;
  v_start   timestamptz := clock_timestamp();
  v_cand    int := 0;
  v_written int := 0;
  v_out     jsonb;
BEGIN
  IF current_user NOT IN ('service_role','postgres','supabase_admin') THEN
    RAISE EXCEPTION 'forbidden: %', current_user USING ERRCODE = '42501';
  END IF;
  -- One bounded set-based pass; the cron budget is 3 min, leave headroom.
  PERFORM set_config('statement_timeout', '170000', true);

  v_fee := coalesce(p_fee,
             (SELECT seller_fee_pct FROM public.order_fee_schedule
               WHERE source = 'sg_seller' ORDER BY effective_from DESC LIMIT 1),
             0.10);

  -- 2a. Candidates: played deals never graded, or graded NO_COMPS recently enough
  --     that late sales could still upgrade them.
  CREATE TEMP TABLE _cand ON COMMIT DROP AS
  SELECT f.tevo_event_id AS ev, f.gt_listing_id, f.event_date, f.section, f.quantity,
         f.gt_price::numeric AS cost, f.first_seen_at, f.gone_at,
         f.win_prob, f.net_profit_pct, f.confidence, f.resale_basis,
         f.realized_n AS pred_realized_n, f.regime, f.mod_z, f.vs_zone_pct,
         f.zone AS zone_name,
         public.gt_curated_zone_id(e.primary_performer_id, e.venue_id, f.section) AS zone_id,
         (regexp_match(f.section, '(\d{1,4})'))[1] AS secnum
  FROM public.gotickets_deals_feed f
  JOIN public.events e ON e.id = f.tevo_event_id
  LEFT JOIN public.gotickets_deal_outcome o
         ON o.tevo_event_id = f.tevo_event_id AND o.gt_listing_id = f.gt_listing_id
  WHERE f.gt_price > 0
    AND f.event_date <= current_date - 1
    AND (o.tevo_event_id IS NULL
         OR (o.outcome = 'NO_COMPS' AND f.event_date >= current_date - p_regrade_days))
  ORDER BY f.event_date DESC, f.first_seen_at
  LIMIT p_max;

  SELECT count(*) INTO v_cand FROM _cand;
  IF v_cand = 0 THEN
    RETURN jsonb_build_object('candidates', 0, 'written', 0, 'fee', v_fee,
                              'elapsed_ms', round(extract(epoch FROM clock_timestamp() - v_start) * 1000));
  END IF;

  -- 2b. Realized pool per event, event-day window, three sources, each deduped
  --     exactly as PROJECT_BIBLE §7 requires (SG 11x duplication).
  CREATE TEMP TABLE _pool ON COMMIT DROP AS
  WITH ev AS (SELECT DISTINCT ev, event_date FROM _cand)
  SELECT ev.ev, 'sg'::text AS src, s.broadcast_price::numeric AS px, s.section
  FROM ev
  JOIN LATERAL (
    SELECT DISTINCT ON (x.sg_sale_id) x.broadcast_price, x.section
    FROM public.seatgeek_sales_snapshots x
    WHERE x.tevo_event_id = ev.ev AND x.broadcast_price > 0
      AND x.sale_at_utc::date BETWEEN ev.event_date - p_window_days AND ev.event_date
    ORDER BY x.sg_sale_id, x.pulled_at DESC
  ) s ON true
  UNION ALL
  SELECT ev.ev, 'sd', s.price::numeric, s.section
  FROM ev
  JOIN LATERAL (
    SELECT DISTINCT ON (x.content_hash) x.price, x.section
    FROM public.seatdata_sales_snapshots x
    WHERE x.tevo_event_id = ev.ev AND x.price > 0
      AND x.sale_timestamp::date BETWEEN ev.event_date - p_window_days AND ev.event_date
    ORDER BY x.content_hash, x.pulled_at DESC
  ) s ON true
  UNION ALL
  SELECT ev.ev, 'crm', c.price_per_ticket::numeric, c.section
  FROM ev
  JOIN public.v_s4kcs_orders c
    ON c.tevo_event_id = ev.ev AND c.price_per_ticket > 0
   AND c.order_status <> 'REJECTED'
   AND (c.purchase_date IS NULL
        OR c.purchase_date BETWEEN ev.event_date - p_window_days AND ev.event_date);

  -- 2c. Tag each (deal, sale) pair with the two match predicates.
  CREATE TEMP TABLE _tag ON COMMIT DROP AS
  SELECT c.ev, c.gt_listing_id, p.src, p.px,
         (c.zone_id IS NOT NULL AND EXISTS (
            SELECT 1 FROM public.performer_zone_rules pzr
            WHERE pzr.zone_id = c.zone_id
              AND public.section_in_range(
                    coalesce((regexp_match(p.section, '(\d{2,4})'))[1], p.section),
                    pzr.section_from, pzr.section_to)))                       AS in_zone,
         (c.secnum IS NOT NULL
          AND (regexp_match(p.section, '(\d{1,4})'))[1] = c.secnum)          AS same_sec,
         (p.px * (1 - v_fee) >= (1 + p_roi_target) * c.cost)                  AS clears
  FROM _cand c JOIN _pool p ON p.ev = c.ev;

  -- 2d. Per-level aggregates, then pick the finest level that has enough comps.
  CREATE TEMP TABLE _agg ON COMMIT DROP AS
  SELECT ev, gt_listing_id,
    count(*) FILTER (WHERE in_zone)                                            AS zone_n,
    percentile_cont(0.5)  WITHIN GROUP (ORDER BY px) FILTER (WHERE in_zone)    AS zone_med,
    percentile_cont(0.25) WITHIN GROUP (ORDER BY px) FILTER (WHERE in_zone)    AS zone_p25,
    percentile_cont(0.75) WITHIN GROUP (ORDER BY px) FILTER (WHERE in_zone)    AS zone_p75,
    avg(clears::int) FILTER (WHERE in_zone)                                    AS zone_win,
    count(*) FILTER (WHERE in_zone AND src='sg')                               AS zone_sg,
    count(*) FILTER (WHERE in_zone AND src='sd')                               AS zone_sd,
    count(*) FILTER (WHERE in_zone AND src='crm')                              AS zone_crm,
    count(*) FILTER (WHERE same_sec)                                           AS sec_n,
    percentile_cont(0.5)  WITHIN GROUP (ORDER BY px) FILTER (WHERE same_sec)   AS sec_med,
    percentile_cont(0.25) WITHIN GROUP (ORDER BY px) FILTER (WHERE same_sec)   AS sec_p25,
    percentile_cont(0.75) WITHIN GROUP (ORDER BY px) FILTER (WHERE same_sec)   AS sec_p75,
    avg(clears::int) FILTER (WHERE same_sec)                                   AS sec_win,
    count(*) FILTER (WHERE same_sec AND src='sg')                              AS sec_sg,
    count(*) FILTER (WHERE same_sec AND src='sd')                              AS sec_sd,
    count(*) FILTER (WHERE same_sec AND src='crm')                             AS sec_crm,
    count(*)                                                                   AS ev_n,
    percentile_cont(0.5)  WITHIN GROUP (ORDER BY px)                           AS ev_med,
    percentile_cont(0.25) WITHIN GROUP (ORDER BY px)                           AS ev_p25,
    percentile_cont(0.75) WITHIN GROUP (ORDER BY px)                           AS ev_p75,
    avg(clears::int)                                                           AS ev_win,
    count(*) FILTER (WHERE src='sg')                                           AS ev_sg,
    count(*) FILTER (WHERE src='sd')                                           AS ev_sd,
    count(*) FILTER (WHERE src='crm')                                          AS ev_crm
  FROM _tag GROUP BY ev, gt_listing_id;

  WITH chosen AS (
    SELECT c.*,
      coalesce(a.zone_n,0) AS zone_n, a.zone_med, coalesce(a.sec_n,0) AS sec_n, a.sec_med,
      coalesce(a.ev_n,0) AS ev_n, a.ev_med,
      CASE WHEN coalesce(a.zone_n,0) >= p_min_comps THEN 'zone'
           WHEN coalesce(a.sec_n,0)  >= p_min_comps THEN 'section'
           WHEN coalesce(a.ev_n,0)   >= p_min_comps THEN 'event'
           ELSE 'none' END AS lvl,
      a.*
    FROM _cand c LEFT JOIN _agg a ON a.ev = c.ev AND a.gt_listing_id = c.gt_listing_id
  ),
  readout AS (
    SELECT ch.*,
      CASE lvl WHEN 'zone' THEN zone_n WHEN 'section' THEN sec_n WHEN 'event' THEN ev_n ELSE 0 END      AS r_n,
      CASE lvl WHEN 'zone' THEN zone_med WHEN 'section' THEN sec_med WHEN 'event' THEN ev_med END        AS r_med,
      CASE lvl WHEN 'zone' THEN zone_p25 WHEN 'section' THEN sec_p25 WHEN 'event' THEN ev_p25 END        AS r_p25,
      CASE lvl WHEN 'zone' THEN zone_p75 WHEN 'section' THEN sec_p75 WHEN 'event' THEN ev_p75 END        AS r_p75,
      CASE lvl WHEN 'zone' THEN zone_win WHEN 'section' THEN sec_win WHEN 'event' THEN ev_win END        AS r_win,
      CASE lvl WHEN 'zone' THEN zone_sg WHEN 'section' THEN sec_sg WHEN 'event' THEN ev_sg ELSE 0 END    AS r_sg,
      CASE lvl WHEN 'zone' THEN zone_sd WHEN 'section' THEN sec_sd WHEN 'event' THEN ev_sd ELSE 0 END    AS r_sd,
      CASE lvl WHEN 'zone' THEN zone_crm WHEN 'section' THEN sec_crm WHEN 'event' THEN ev_crm ELSE 0 END AS r_crm
    FROM chosen ch
  ),
  ins AS (
    INSERT INTO public.gotickets_deal_outcome AS o (
      tevo_event_id, gt_listing_id, event_date, section, secnum, zone_id, zone_name, quantity, cost, first_seen_at,
      pred_win_prob, pred_net_profit_pct, pred_confidence, pred_resale_basis, pred_realized_n,
      pred_regime, pred_mod_z, pred_vs_zone_pct,
      zone_n, zone_med, sec_n, sec_med, ev_n, ev_med,
      match_level, realized_n, realized_med, realized_p25, realized_p75,
      realized_sg_n, realized_sd_n, realized_crm_n, seller_fee_pct,
      realized_net, realized_roi_pct, realized_win_share, outcome,
      listing_gone_at, hours_alive, gone_before_event,
      graded_at, grade_version, params, updated_at)
    SELECT r.ev, r.gt_listing_id, r.event_date, r.section, r.secnum, r.zone_id, r.zone_name, r.quantity, r.cost, r.first_seen_at,
      r.win_prob, r.net_profit_pct, r.confidence, r.resale_basis, r.pred_realized_n,
      r.regime, r.mod_z, r.vs_zone_pct,
      r.zone_n, round(r.zone_med::numeric,2), r.sec_n, round(r.sec_med::numeric,2), r.ev_n, round(r.ev_med::numeric,2),
      r.lvl, r.r_n, round(r.r_med::numeric,2), round(r.r_p25::numeric,2), round(r.r_p75::numeric,2),
      r.r_sg, r.r_sd, r.r_crm, v_fee,
      round((r.r_med * (1 - v_fee))::numeric, 2),
      round(((r.r_med * (1 - v_fee) - r.cost) / r.cost * 100)::numeric, 1),
      round(r.r_win::numeric, 3),
      CASE WHEN r.lvl = 'none' OR r.r_med IS NULL           THEN 'NO_COMPS'
           WHEN r.r_med * (1 - v_fee) >= (1 + p_roi_target) * r.cost THEN 'WIN'
           WHEN r.r_med * (1 - v_fee) >= r.cost                       THEN 'FLAT'
           ELSE 'LOSS' END,
      r.gone_at,
      round(extract(epoch FROM (coalesce(r.gone_at, r.event_date::timestamptz) - r.first_seen_at)) / 3600.0, 1),
      (r.gone_at IS NOT NULL AND r.gone_at < r.event_date::timestamptz),
      now(), 1,
      jsonb_build_object('window_days', p_window_days, 'min_comps', p_min_comps,
                         'roi_target', p_roi_target, 'fee', v_fee),
      now()
    FROM readout r
    ON CONFLICT (tevo_event_id, gt_listing_id) DO UPDATE SET
      zone_n = excluded.zone_n, zone_med = excluded.zone_med,
      sec_n = excluded.sec_n, sec_med = excluded.sec_med,
      ev_n = excluded.ev_n, ev_med = excluded.ev_med,
      match_level = excluded.match_level, realized_n = excluded.realized_n,
      realized_med = excluded.realized_med, realized_p25 = excluded.realized_p25, realized_p75 = excluded.realized_p75,
      realized_sg_n = excluded.realized_sg_n, realized_sd_n = excluded.realized_sd_n, realized_crm_n = excluded.realized_crm_n,
      seller_fee_pct = excluded.seller_fee_pct, realized_net = excluded.realized_net,
      realized_roi_pct = excluded.realized_roi_pct, realized_win_share = excluded.realized_win_share,
      outcome = excluded.outcome,
      listing_gone_at = excluded.listing_gone_at, hours_alive = excluded.hours_alive,
      gone_before_event = excluded.gone_before_event,
      graded_at = now(), params = excluded.params, updated_at = now()
    RETURNING outcome, match_level
  )
  SELECT jsonb_build_object(
    'candidates', v_cand,
    'written', count(*),
    'by_outcome', jsonb_object_agg(outcome, n) FILTER (WHERE grp = 'o'),
    'by_level',   jsonb_object_agg(match_level, n) FILTER (WHERE grp = 'l')
  ) INTO v_out
  FROM (
    SELECT 'o' grp, outcome, NULL::text match_level, count(*) n FROM ins GROUP BY outcome
    UNION ALL
    SELECT 'l', NULL, match_level, count(*) FROM ins GROUP BY match_level
  ) s;

  v_out := v_out || jsonb_build_object(
    'fee', v_fee,
    'elapsed_ms', round(extract(epoch FROM clock_timestamp() - v_start) * 1000));
  RETURN v_out;
END;
$fn$;

REVOKE ALL ON FUNCTION public.grade_deal_outcomes(int,int,int,numeric,numeric,int) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.grade_deal_outcomes(int,int,int,numeric,numeric,int) FROM anon, authenticated;
GRANT EXECUTE ON FUNCTION public.grade_deal_outcomes(int,int,int,numeric,numeric,int) TO service_role;
COMMENT ON FUNCTION public.grade_deal_outcomes(int,int,int,numeric,numeric,int) IS
  'Grades played GoTickets deals into gotickets_deal_outcome: event-day realized sales (SG + SeatData + S4K CRM) at the finest match level with >= p_min_comps (curated zone > section number > event), net of the sg_seller fee, vs the flagged cost. Re-grades NO_COMPS rows for p_regrade_days. Set-based, p_max rows/run. service_role only. D0 mig 20260911160400.';

-- ── 3. Calibration readout ───────────────────────────────────────────────────
-- Each row = one bucket of one grouping; only labelled rows (outcome <> NO_COMPS)
-- at zone/section level (event-level is recorded on the base table but too coarse
-- to calibrate against — see header).
CREATE OR REPLACE VIEW public.v_deal_calibration
WITH (security_invoker = true) AS
WITH lab AS (
  SELECT *,
    CASE WHEN pred_win_prob IS NULL THEN 'z null (outlier-only)'
         WHEN pred_win_prob >= 0.70 THEN 'd >=0.70'
         WHEN pred_win_prob >= 0.50 THEN 'c 0.50-0.69'
         WHEN pred_win_prob >= 0.30 THEN 'b 0.30-0.49'
         ELSE 'a <0.30' END AS win_prob_bucket
  FROM public.gotickets_deal_outcome
  WHERE outcome <> 'NO_COMPS' AND match_level IN ('zone','section')
),
x AS (
  SELECT 'all'          AS grouping, 'all'                              AS bucket, * FROM lab
  UNION ALL SELECT 'win_prob',   win_prob_bucket,                                * FROM lab
  UNION ALL SELECT 'regime',     coalesce(pred_regime, 'null'),                  * FROM lab
  UNION ALL SELECT 'confidence', coalesce(pred_confidence, 'null'),              * FROM lab
  UNION ALL SELECT 'match_level', match_level,                                   * FROM lab
)
SELECT grouping, bucket,
       count(*)                                                                AS deals,
       round(avg(pred_win_prob) * 100, 1)                                      AS pred_win_pct,
       round(100.0 * count(*) FILTER (WHERE outcome = 'WIN')  / count(*), 1)   AS actual_win_pct,
       round(100.0 * count(*) FILTER (WHERE outcome <> 'LOSS') / count(*), 1)  AS actual_not_loss_pct,
       round(avg(realized_win_share) * 100, 1)                                 AS realized_win_share_pct,
       round((percentile_cont(0.5) WITHIN GROUP (ORDER BY realized_roi_pct))::numeric, 1) AS med_realized_roi_pct,
       round(avg(realized_n), 1)                                               AS avg_comps,
       max(graded_at)                                                          AS last_graded_at
FROM x
GROUP BY grouping, bucket;
GRANT SELECT ON public.v_deal_calibration TO authenticated, service_role;
COMMENT ON VIEW public.v_deal_calibration IS
  'Deal-feed calibration scorecard over gotickets_deal_outcome (labelled rows, zone/section level only): predicted win_prob vs actual WIN rate, by win_prob bucket / regime / confidence / match level. D0 mig 20260911160400.';

CREATE OR REPLACE FUNCTION public.get_deal_calibration(
  p_grouping text DEFAULT NULL,   -- 'win_prob' | 'regime' | 'confidence' | 'match_level' | NULL = all groupings
  p_days     int  DEFAULT 180     -- only deals whose event_date is within the last p_days
)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_email text := coalesce(auth.jwt()->>'email', '');
  v_out   jsonb;
BEGIN
  IF v_email NOT LIKE '%@s4kent.com' THEN
    RAISE EXCEPTION 'forbidden: % is not @s4kent.com', v_email USING ERRCODE = '42501';
  END IF;
  PERFORM set_config('statement_timeout', '10000', true);

  WITH lab AS (
    SELECT *,
      CASE WHEN pred_win_prob IS NULL THEN 'z null (outlier-only)'
           WHEN pred_win_prob >= 0.70 THEN 'd >=0.70'
           WHEN pred_win_prob >= 0.50 THEN 'c 0.50-0.69'
           WHEN pred_win_prob >= 0.30 THEN 'b 0.30-0.49'
           ELSE 'a <0.30' END AS win_prob_bucket
    FROM public.gotickets_deal_outcome
    WHERE outcome <> 'NO_COMPS' AND match_level IN ('zone','section')
      AND event_date >= current_date - GREATEST(p_days, 1)
  ),
  x AS (
    SELECT 'all' AS grouping, 'all' AS bucket, * FROM lab
    UNION ALL SELECT 'win_prob',    win_prob_bucket,                  * FROM lab
    UNION ALL SELECT 'regime',      coalesce(pred_regime, 'null'),    * FROM lab
    UNION ALL SELECT 'confidence',  coalesce(pred_confidence, 'null'),* FROM lab
    UNION ALL SELECT 'match_level', match_level,                      * FROM lab
  ),
  rows_ AS (
    SELECT grouping, bucket, count(*) AS deals,
           round(avg(pred_win_prob) * 100, 1)                                        AS pred_win_pct,
           round(100.0 * count(*) FILTER (WHERE outcome = 'WIN') / count(*), 1)      AS actual_win_pct,
           round(100.0 * count(*) FILTER (WHERE outcome <> 'LOSS') / count(*), 1)    AS actual_not_loss_pct,
           round(avg(realized_win_share) * 100, 1)                                   AS realized_win_share_pct,
           round((percentile_cont(0.5) WITHIN GROUP (ORDER BY realized_roi_pct))::numeric, 1) AS med_realized_roi_pct,
           round(avg(realized_n), 1)                                                 AS avg_comps
    FROM x
    WHERE p_grouping IS NULL OR grouping = p_grouping OR grouping = 'all'
    GROUP BY grouping, bucket
  )
  SELECT jsonb_build_object(
    'days', p_days,
    'generated_at', now(),
    'labelled',  (SELECT count(*) FROM public.gotickets_deal_outcome WHERE outcome <> 'NO_COMPS'),
    'no_comps',  (SELECT count(*) FROM public.gotickets_deal_outcome WHERE outcome = 'NO_COMPS'),
    'last_graded_at', (SELECT max(graded_at) FROM public.gotickets_deal_outcome),
    'rows', coalesce((SELECT jsonb_agg(to_jsonb(r) ORDER BY grouping, bucket) FROM rows_ r), '[]'::jsonb)
  ) INTO v_out;
  RETURN v_out;
END;
$fn$;

REVOKE ALL ON FUNCTION public.get_deal_calibration(text,int) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.get_deal_calibration(text,int) FROM anon;
GRANT EXECUTE ON FUNCTION public.get_deal_calibration(text,int) TO authenticated, service_role;
COMMENT ON FUNCTION public.get_deal_calibration(text,int) IS
  'D0 read RPC: deal-feed calibration scorecard (predicted win_prob vs realized WIN rate by bucket) from gotickets_deal_outcome. Email-gated @s4kent.com, authenticated-only. D0 mig 20260911160400.';

-- ── 4. Daily cron, policy-gated ──────────────────────────────────────────────
INSERT INTO public.cron_policy
  (jobname, peak_hours_et, peak_min_interval_min, offpeak_min_interval_min,
   work_check_sql, daily_max_fires, notes)
VALUES
  ('deal_outcome_grade_daily',
   ARRAY[0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23],
   720, 720,
   $wc$SELECT EXISTS (
         SELECT 1 FROM public.gotickets_deals_feed f
         LEFT JOIN public.gotickets_deal_outcome o
           ON o.tevo_event_id = f.tevo_event_id AND o.gt_listing_id = f.gt_listing_id
         WHERE f.gt_price > 0 AND f.event_date <= current_date - 1
           AND (o.tevo_event_id IS NULL
                OR (o.outcome = 'NO_COMPS' AND f.event_date >= current_date - 14)))$wc$,
   2,
   'Grades played GoTickets deals into gotickets_deal_outcome once a day (12:25 UTC, after the overnight sales pulls). Skips when nothing is ungraded. mig 20260911160400')
ON CONFLICT (jobname) DO UPDATE SET
  work_check_sql = excluded.work_check_sql, notes = excluded.notes, updated_at = now();

DO $cron$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    PERFORM cron.unschedule('deal_outcome_grade_daily')
      WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'deal_outcome_grade_daily');
    PERFORM cron.schedule('deal_outcome_grade_daily', '25 12 * * *', $body$
      DO $b$ BEGIN
        IF NOT public.cron_should_fire('deal_outcome_grade_daily') THEN RETURN; END IF;
        PERFORM public.grade_deal_outcomes(300);
      END $b$;
    $body$);
  END IF;
END;
$cron$;

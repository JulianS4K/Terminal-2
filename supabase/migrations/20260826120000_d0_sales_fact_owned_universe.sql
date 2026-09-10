-- ============================================================================
-- Migration 20260826120000 — d0_sales_fact: extend the OWNED-sales universe
--                            past the six-ESPN-league gate
--
-- Lane:     D0 (author) → applier (apply)
-- Touches:  d0_sales_fact (W — ALTER: league DROP NOT NULL),
--           d0_sales_events (W — new view),
--           d0_league_summary (W — replace), d0_league_price_weighted (W — replace),
--           d0_refresh_sales_fact() (W — replace),
--           d0_refresh_sales_fact_active(interval) (W — replace),
--           events (R), d0_league_performers (R), d0_league_events (R),
--           evo_orders (R), evo_order_items (R), seatgeek_orders (R),
--           tickpick_orders (R), vivid_orders (R), order_status_xref (R),
--           seatgeek_sales_snapshots (R), seatdata_sales_snapshots (R),
--           sg_events_canonical (R)
-- Pre-reqs: the 2026-06-24 D0 sales-report objects (applied direct to prod;
--           their DDL is not in this tree — see docs/d0-sales-reports.md §0.4)
--
-- WHY
--   Every insert in both refresh functions inner-joins d0_league_events, which
--   gates the entire fact table to performer_metadata.espn_league IN
--   (MLB,NBA,NFL,NHL,MLS,WNBA). Roughly half of our own sale lines fall outside
--   it, so S4K sales at non-sports events — comedy, community, mid-tier music,
--   and the venue-distributed inventory now coming online — are invisible.
--
--   Measured on prod 2026-08-26: 856 owned lines tracked (all EVO, $1,292,219.64
--   gross) against ~1,613 succeeded owned sale lines that exist upstream
--   (1,413 EVO order items + 200 fulfilled SeatGeek orders).
--
-- SCOPE — owned sources only
--   The four OWNED sources (evo, seatgeek_orders, tickpick, vivid) move to the
--   full event universe. The two MARKET sources (seatgeek_sales, seatdata) stay
--   league-gated deliberately: extending them adds 420,849 SeatData lines alone
--   to a 924,398-row table, and the SeatGeek-sales firehose join over the
--   non-league universe did not complete inside 60s. Widening market breadth is
--   a separate decision with its own cost, not a side effect of this one.
--
-- WHAT THIS DOES NOT FIX
--   The 200 fulfilled SeatGeek orders all carry tevo_event_id IS NULL, so they
--   still cannot join to an event and remain untracked after this migration.
--   Same for 68 EVO order items with no resolvable event. That is an order→event
--   mapping gap (backfill_order_tevo_from_aq, hourly :40), tracked separately.
--   Expected effect here: owned lines ~856 → ~1,409.
--
-- SAFETY
--   Idempotent and reversible: ALTER ... DROP NOT NULL plus CREATE OR REPLACE
--   only. No data is deleted except by the refresh functions' own existing
--   delete-then-reinsert cycle. Existing league-scoped reads are unchanged —
--   the two league aggregates gain an explicit `league IS NOT NULL` filter so
--   they return exactly what they returned before, and every performer view
--   inner-joins d0_league_event_roles, which admits league events only.
-- ============================================================================

begin;

-- 1. Non-league sales carry no league. ---------------------------------------
alter table public.d0_sales_fact alter column league drop not null;

-- 2. The full event universe, with league optional. ---------------------------
--    Mirrors d0_league_events exactly, but LEFT JOINs the league roster instead
--    of inner-joining it, so non-league events survive with league = NULL.
create or replace view public.d0_sales_events as
  select e.id as event_id,
         lp.league
  from events e
  left join d0_league_performers lp on lp.performer_id = e.primary_performer_id;

comment on view public.d0_sales_events is
  'All events, league OPTIONAL (left join to d0_league_performers). Superset of '
  'd0_league_events, which stays the league-gated inner-join universe used by the '
  'market-data sources in d0_refresh_sales_fact*. Added 20260826120000.';

-- 3. League aggregates keep their pre-existing shape: league rows only. -------
create or replace view public.d0_league_summary as
 SELECT league,
    round(sum(gross), 2) AS total_revenue,
    sum(qty) AS tickets_sold,
    round((percentile_cont((0.50)::double precision) WITHIN GROUP (ORDER BY ((price_per_ticket)::double precision)))::numeric, 2) AS median_price,
    round(avg(price_per_ticket), 2) AS avg_price,
    count(*) AS sale_lines
   FROM d0_sales_fact
  WHERE league IS NOT NULL
  GROUP BY league;

create or replace view public.d0_league_price_weighted as
 WITH base AS (
         SELECT d0_sales_fact.league,
            d0_sales_fact.price_per_ticket,
            sum(d0_sales_fact.qty) AS qty
           FROM d0_sales_fact
          WHERE (d0_sales_fact.price_per_ticket IS NOT NULL)
            AND (d0_sales_fact.league IS NOT NULL)
          GROUP BY d0_sales_fact.league, d0_sales_fact.price_per_ticket
        ), cum AS (
         SELECT base.league,
            base.price_per_ticket,
            base.qty,
            sum(base.qty) OVER (PARTITION BY base.league ORDER BY base.price_per_ticket ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS cum_qty,
            sum(base.qty) OVER (PARTITION BY base.league) AS tot_qty
           FROM base
        )
 SELECT league,
    max(tot_qty) AS tickets,
    round(min(price_per_ticket) FILTER (WHERE (cum_qty >= (tot_qty / 2.0))), 2) AS weighted_median_price
   FROM cum
  GROUP BY league;

-- 4. Full rebuild — market sources league-gated, owned sources universe-wide. --
create or replace function public.d0_refresh_sales_fact()
 returns void
 language plpgsql
 security definer
 set search_path to 'public', 'pg_temp'
as $function$
begin
  delete from d0_sales_fact;

  -- MARKET (league-gated — see the SCOPE note in the migration header)
  insert into d0_sales_fact (source,is_owned,event_id,league,section,qty,price_per_ticket,gross)
  select 'seatgeek_sales',false,le.event_id,le.league,coalesce(nullif(trim(s.section),''),'(blank)'),
    s.quantity::numeric, s.broadcast_price, s.broadcast_price*coalesce(nullif(s.quantity,0),1)::numeric
  from d0_league_events le
  join sg_events_canonical c on c.tevo_event_id=le.event_id
  join lateral (
    select distinct on (ss.sg_sale_id) ss.section, ss.quantity, ss.broadcast_price
    from seatgeek_sales_snapshots ss
    where ss.sg_event_id=c.sg_event_id and ss.sg_sale_id is not null
    order by ss.sg_sale_id, ss.pulled_at desc
  ) s on true;

  insert into d0_sales_fact (source,is_owned,event_id,league,section,qty,price_per_ticket,gross)
  select 'seatdata',false,le.event_id,le.league,coalesce(nullif(trim(s.section),''),'(blank)'),
    coalesce(nullif(s.quantity,0),1)::numeric, s.price, s.price*coalesce(nullif(s.quantity,0),1)::numeric
  from d0_league_events le join seatdata_sales_snapshots s on s.tevo_event_id=le.event_id;

  -- OWNED (full universe — d0_sales_events, league may be NULL)
  insert into d0_sales_fact (source,is_owned,event_id,league,section,qty,price_per_ticket,gross)
  select 'evo',true,le.event_id,le.league,coalesce(nullif(trim(i.ticket_group_section),''),'(blank)'),
    i.quantity::numeric, i.price, i.price*i.quantity::numeric
  from d0_sales_events le
  join evo_order_items i on i.event_id=le.event_id
  join evo_orders o on o.evo_order_id=i.evo_order_id
  join order_status_xref x on x.source='evo' and x.source_status=o.state and x.is_sale_succeeded;

  insert into d0_sales_fact (source,is_owned,event_id,league,section,qty,price_per_ticket,gross)
  select 'seatgeek_orders',true,le.event_id,le.league,coalesce(nullif(trim(o.sale_section),''),'(blank)'),
    o.sale_quantity::numeric, o.sale_price, o.payment_total
  from d0_sales_events le
  join seatgeek_orders o on o.tevo_event_id=le.event_id
  join order_status_xref x on x.source='seatgeek' and x.source_status=o.status and x.is_sale_succeeded;

  insert into d0_sales_fact (source,is_owned,event_id,league,section,qty,price_per_ticket,gross)
  select 'tickpick',true,le.event_id,le.league,'(no section)',
    o.quantity::numeric, case when o.quantity>0 then o.total/o.quantity else o.total end, o.total
  from d0_sales_events le
  join tickpick_orders o on o.tevo_event_id=le.event_id
  join order_status_xref x on x.source='tickpick' and x.source_status=o.status and x.is_sale_succeeded;

  insert into d0_sales_fact (source,is_owned,event_id,league,section,qty,price_per_ticket,gross)
  select 'vivid',true,le.event_id,le.league,'(no section)',
    o.quantity::numeric, case when o.quantity>0 then o.total/o.quantity else o.total end, o.total
  from d0_sales_events le
  join vivid_orders o on o.tevo_event_id=le.event_id
  join order_status_xref x on x.source='vivid' and x.source_status=o.status and x.is_sale_succeeded;
end $function$;

-- 5. Incremental rebuild. -----------------------------------------------------
--    _aff is now the FULL active universe (league nullable). The delete keys off
--    _aff, so it must be the widest scope of the two — otherwise owned rows for
--    non-league events would be inserted on every pass without ever being
--    cleared, and duplicate. Market inserts re-narrow with `a.league is not null`.
--
--    Return value: previously the count of active LEAGUE events, now the count of
--    all active events refreshed. d0_refresh_health reads cron.job_run_details,
--    not this number, so no monitoring surface changes shape.
create or replace function public.d0_refresh_sales_fact_active(p_window interval default '3 days'::interval)
 returns integer
 language plpgsql
 security definer
 set search_path to 'public', 'pg_temp'
as $function$
declare n_events int;
begin
  create temp table _aff on commit drop as
    select e.id as event_id, lp.league
    from events e
    left join d0_league_performers lp on lp.performer_id = e.primary_performer_id
    where e.last_seen >= now() - p_window;
  create index on _aff(event_id);
  select count(*) into n_events from _aff;

  delete from d0_sales_fact f using _aff a where f.event_id = a.event_id;

  -- MARKET (league-gated)
  insert into d0_sales_fact (source,is_owned,event_id,league,section,qty,price_per_ticket,gross)
  select 'seatgeek_sales',false,a.event_id,a.league,coalesce(nullif(trim(s.section),''),'(blank)'),
    s.quantity::numeric, s.broadcast_price, s.broadcast_price*coalesce(nullif(s.quantity,0),1)::numeric
  from _aff a
  join sg_events_canonical c on c.tevo_event_id=a.event_id
  join lateral (
    select distinct on (ss.sg_sale_id) ss.section, ss.quantity, ss.broadcast_price
    from seatgeek_sales_snapshots ss
    where ss.sg_event_id=c.sg_event_id and ss.sg_sale_id is not null
    order by ss.sg_sale_id, ss.pulled_at desc
  ) s on true
  where a.league is not null;

  insert into d0_sales_fact (source,is_owned,event_id,league,section,qty,price_per_ticket,gross)
  select 'seatdata',false,a.event_id,a.league,coalesce(nullif(trim(s.section),''),'(blank)'),
    coalesce(nullif(s.quantity,0),1)::numeric, s.price, s.price*coalesce(nullif(s.quantity,0),1)::numeric
  from _aff a join seatdata_sales_snapshots s on s.tevo_event_id=a.event_id
  where a.league is not null;

  -- OWNED (full universe)
  insert into d0_sales_fact (source,is_owned,event_id,league,section,qty,price_per_ticket,gross)
  select 'evo',true,a.event_id,a.league,coalesce(nullif(trim(i.ticket_group_section),''),'(blank)'),
    i.quantity::numeric, i.price, i.price*i.quantity::numeric
  from _aff a
  join evo_order_items i on i.event_id=a.event_id
  join evo_orders o on o.evo_order_id=i.evo_order_id
  join order_status_xref x on x.source='evo' and x.source_status=o.state and x.is_sale_succeeded;

  insert into d0_sales_fact (source,is_owned,event_id,league,section,qty,price_per_ticket,gross)
  select 'seatgeek_orders',true,a.event_id,a.league,coalesce(nullif(trim(o.sale_section),''),'(blank)'),
    o.sale_quantity::numeric, o.sale_price, o.payment_total
  from _aff a
  join seatgeek_orders o on o.tevo_event_id=a.event_id
  join order_status_xref x on x.source='seatgeek' and x.source_status=o.status and x.is_sale_succeeded;

  insert into d0_sales_fact (source,is_owned,event_id,league,section,qty,price_per_ticket,gross)
  select 'tickpick',true,a.event_id,a.league,'(no section)',
    o.quantity::numeric, case when o.quantity>0 then o.total/o.quantity else o.total end, o.total
  from _aff a
  join tickpick_orders o on o.tevo_event_id=a.event_id
  join order_status_xref x on x.source='tickpick' and x.source_status=o.status and x.is_sale_succeeded;

  insert into d0_sales_fact (source,is_owned,event_id,league,section,qty,price_per_ticket,gross)
  select 'vivid',true,a.event_id,a.league,'(no section)',
    o.quantity::numeric, case when o.quantity>0 then o.total/o.quantity else o.total end, o.total
  from _aff a
  join vivid_orders o on o.tevo_event_id=a.event_id
  join order_status_xref x on x.source='vivid' and x.source_status=o.status and x.is_sale_succeeded;

  return n_events;
end $function$;

commit;

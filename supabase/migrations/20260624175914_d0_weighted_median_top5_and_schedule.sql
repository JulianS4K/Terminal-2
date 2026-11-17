-- Migration 20260624175914 · reconstructed from prod · writes: see body
--
-- Recorded 2026-11-17 (branch triage): applied on prod as "d0_weighted_median_top5_and_schedule" (version 20260624175914) but present in no
-- file in git. Body is prod's own supabase_migrations.schema_migrations.statements for that row,
-- statements separated by ';'. Recording only — it is already applied; do not re-apply.


-- (c) Convenience: top 5 sections per performer/role by revenue
create or replace view d0_perf_top5_sections as
select performer_id, performer_name, performer_league, role, section, tickets, revenue,
       rank_by_revenue, rank_by_volume
from d0_perf_sections
where rank_by_revenue <= 5;

-- (b) Quantity-weighted median ticket price (true per-seat median, no row explosion):
--     price at which cumulative tickets crosses half of total tickets.
create or replace view d0_perf_price_weighted as
with base as (
  select performer_id, performer_name, performer_league, role, price_per_ticket, sum(qty) as qty
  from d0_perf_sale_lines
  where price_per_ticket is not null
  group by performer_id, performer_name, performer_league, role, price_per_ticket
), cum as (
  select *,
    sum(qty) over (partition by performer_id, role order by price_per_ticket
                   rows between unbounded preceding and current row) as cum_qty,
    sum(qty) over (partition by performer_id, role) as tot_qty
  from base
)
select performer_id, performer_name, performer_league, role,
       max(tot_qty) as tickets,
       round(min(price_per_ticket) filter (where cum_qty >= tot_qty/2.0),2) as weighted_median_price
from cum
group by performer_id, performer_name, performer_league, role;

-- Per-league quantity-weighted median (companion to d0_league_summary)
create or replace view d0_league_price_weighted as
with base as (
  select league, price_per_ticket, sum(qty) as qty
  from d0_sales_fact where price_per_ticket is not null
  group by league, price_per_ticket
), cum as (
  select *,
    sum(qty) over (partition by league order by price_per_ticket
                   rows between unbounded preceding and current row) as cum_qty,
    sum(qty) over (partition by league) as tot_qty
  from base
)
select league, max(tot_qty) as tickets,
       round(min(price_per_ticket) filter (where cum_qty >= tot_qty/2.0),2) as weighted_median_price
from cum group by league;

-- Make the refresh zero-downtime: DELETE+INSERT in one txn (readers keep seeing
-- the old rows via MVCC) instead of TRUNCATE (which would block reads under an
-- ACCESS EXCLUSIVE lock for the whole multi-minute rebuild).
create or replace function d0_refresh_sales_fact()
returns void language plpgsql security definer as $$
begin
  delete from d0_sales_fact;

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

  insert into d0_sales_fact (source,is_owned,event_id,league,section,qty,price_per_ticket,gross)
  select 'evo',true,le.event_id,le.league,coalesce(nullif(trim(i.ticket_group_section),''),'(blank)'),
    i.quantity::numeric, i.price, i.price*i.quantity::numeric
  from d0_league_events le
  join evo_order_items i on i.event_id=le.event_id
  join evo_orders o on o.evo_order_id=i.evo_order_id
  join order_status_xref x on x.source='evo' and x.source_status=o.state and x.is_sale_succeeded;

  insert into d0_sales_fact (source,is_owned,event_id,league,section,qty,price_per_ticket,gross)
  select 'seatgeek_orders',true,le.event_id,le.league,coalesce(nullif(trim(o.sale_section),''),'(blank)'),
    o.sale_quantity::numeric, o.sale_price, o.payment_total
  from d0_league_events le
  join seatgeek_orders o on o.tevo_event_id=le.event_id
  join order_status_xref x on x.source='seatgeek' and x.source_status=o.status and x.is_sale_succeeded;

  insert into d0_sales_fact (source,is_owned,event_id,league,section,qty,price_per_ticket,gross)
  select 'tickpick',true,le.event_id,le.league,'(no section)',
    o.quantity::numeric, case when o.quantity>0 then o.total/o.quantity else o.total end, o.total
  from d0_league_events le
  join tickpick_orders o on o.tevo_event_id=le.event_id
  join order_status_xref x on x.source='tickpick' and x.source_status=o.status and x.is_sale_succeeded;

  insert into d0_sales_fact (source,is_owned,event_id,league,section,qty,price_per_ticket,gross)
  select 'vivid',true,le.event_id,le.league,'(no section)',
    o.quantity::numeric, case when o.quantity>0 then o.total/o.quantity else o.total end, o.total
  from d0_league_events le
  join vivid_orders o on o.tevo_event_id=le.event_id
  join order_status_xref x on x.source='vivid' and x.source_status=o.status and x.is_sale_succeeded;
end $$;

-- Schedule nightly at 06:40 UTC (clear of the 03-05 / 07-09 UTC heavy clusters).
select cron.schedule('d0_refresh_sales_fact_nightly', '40 6 * * *', $$select d0_refresh_sales_fact();$$);
;

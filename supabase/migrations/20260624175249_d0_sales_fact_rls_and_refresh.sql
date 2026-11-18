-- Migration 20260624175249 · reconstructed from prod · writes: see body
--
-- Recorded 2026-11-17 (branch triage): applied on prod as "d0_sales_fact_rls_and_refresh" (version 20260624175249) but present in no
-- file in git. Body is prod's own supabase_migrations.schema_migrations.statements for that row,
-- statements separated by ';'. Recording only — it is already applied; do not re-apply.


-- Match the security posture of every other table (service_role bypasses RLS;
-- anon/authenticated get nothing unless a policy is added later).
alter table d0_sales_fact enable row level security;

comment on table d0_sales_fact is
  'D0 front-end sales fact (point-in-time snapshot). One row per succeeded/market sale for the 6 league leagues'' home events. Sources: seatgeek_sales + seatdata (market), evo/seatgeek_orders/tickpick/vivid (owned). Rebuild with select d0_refresh_sales_fact(). NOTE: seatgeek_sales linked via sg_events_canonical (authoritative), NOT the partial tevo_event_id column.';
comment on view d0_perf_by_source is 'Per performer x role(home/away) x source: tickets + revenue.';
comment on view d0_perf_home_away is 'Per performer: home/away revenue, tickets, and median ticket price.';
comment on view d0_perf_price_stats is 'Per performer x role: p25/median/p75/avg/max per-ticket price.';
comment on view d0_perf_sections is 'Per performer x role x section: tickets + revenue, ranked. Filter rank_by_revenue<=5 or rank_by_volume<=5 for top-5.';
comment on view d0_league_summary is 'Per league: total revenue, tickets sold, median + avg ticket price (no home/away double count).';
comment on view d0_league_visiting_teams is 'Per league: visiting (away) teams ranked by away revenue and by away median price.';

-- Idempotent rebuild. Safe to run server-side (e.g. pg_cron); takes minutes,
-- so it will exceed a 60s interactive client timeout but completes in the background.
create or replace function d0_refresh_sales_fact()
returns void language plpgsql security definer as $$
begin
  truncate d0_sales_fact;

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
;

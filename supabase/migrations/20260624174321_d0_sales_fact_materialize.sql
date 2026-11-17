-- Migration 20260624174321 · reconstructed from prod · writes: see body
--
-- Recorded 2026-11-17 (branch triage): applied on prod as "d0_sales_fact_materialize" (version 20260624174321) but present in no
-- file in git. Body is prod's own supabase_migrations.schema_migrations.statements for that row,
-- statements separated by ';'. Recording only — it is already applied; do not re-apply.


-- Swap the live fact VIEW for a physical TABLE (the deep view chain blocked
-- predicate pushdown, forcing a full all-league dedup on every read).
drop view if exists d0_sales_fact cascade;  -- cascades to perf_sale_lines + all report views

create table d0_sales_fact (
  source           text    not null,
  is_owned         boolean not null,
  event_id         bigint  not null,
  league           text    not null,
  section          text,
  qty              numeric,
  price_per_ticket numeric,
  gross            numeric
);
create index idx_d0_sales_fact_event on d0_sales_fact(event_id);
create index idx_d0_sales_fact_league on d0_sales_fact(league);

-- ---- recreate the report layer on top of the physical table ----
create or replace view d0_perf_sale_lines as
select r.performer_id, r.performer_name, r.performer_league, r.role,
       f.source, f.is_owned, f.section, f.qty, f.price_per_ticket, f.gross
from d0_sales_fact f
join d0_league_event_roles r on r.event_id = f.event_id;

create or replace view d0_perf_by_source as
select performer_id, performer_name, performer_league, role, source, is_owned,
       sum(qty) as tickets, round(sum(gross),2) as revenue
from d0_perf_sale_lines
group by performer_id, performer_name, performer_league, role, source, is_owned;

create or replace view d0_perf_home_away as
select performer_id, performer_name, performer_league,
   round(sum(gross) filter (where role='home'),2) as home_revenue,
   round(sum(gross) filter (where role='away'),2) as away_revenue,
   round(sum(gross),2) as total_revenue,
   sum(qty) filter (where role='home') as home_tickets,
   sum(qty) filter (where role='away') as away_tickets,
   round(percentile_cont(0.5) within group (order by case when role='home' then price_per_ticket end)::numeric,2) as home_median_price,
   round(percentile_cont(0.5) within group (order by case when role='away' then price_per_ticket end)::numeric,2) as away_median_price
from d0_perf_sale_lines
group by performer_id, performer_name, performer_league;

create or replace view d0_perf_price_stats as
select performer_id, performer_name, performer_league, role,
   count(*) as sales, sum(qty) as tickets,
   round(percentile_cont(0.25) within group (order by price_per_ticket)::numeric,2) as p25,
   round(percentile_cont(0.50) within group (order by price_per_ticket)::numeric,2) as median,
   round(percentile_cont(0.75) within group (order by price_per_ticket)::numeric,2) as p75,
   round(avg(price_per_ticket)::numeric,2) as avg_price,
   round(max(price_per_ticket)::numeric,2) as max_price
from d0_perf_sale_lines
group by performer_id, performer_name, performer_league, role;

create or replace view d0_perf_sections as
select performer_id, performer_name, performer_league, role, section,
   sum(qty) as tickets, round(sum(gross),2) as revenue,
   row_number() over (partition by performer_id, role order by sum(gross) desc) as rank_by_revenue,
   row_number() over (partition by performer_id, role order by sum(qty) desc) as rank_by_volume
from d0_perf_sale_lines
where section <> '(no section)'
group by performer_id, performer_name, performer_league, role, section;

create or replace view d0_league_summary as
select league,
   round(sum(gross),2) as total_revenue,
   sum(qty) as tickets_sold,
   round(percentile_cont(0.50) within group (order by price_per_ticket)::numeric,2) as median_price,
   round(avg(price_per_ticket)::numeric,2) as avg_price,
   count(*) as sale_lines
from d0_sales_fact
group by league;

create or replace view d0_league_visiting_teams as
select r.event_league as league, r.performer_id as visiting_performer_id,
   r.performer_name as visiting_team,
   round(sum(f.gross),2) as away_revenue,
   sum(f.qty) as away_tickets,
   round(percentile_cont(0.5) within group (order by f.price_per_ticket)::numeric,2) as away_median_price,
   row_number() over (partition by r.event_league order by sum(f.gross) desc) as rank_by_revenue,
   row_number() over (partition by r.event_league order by percentile_cont(0.5) within group (order by f.price_per_ticket) desc) as rank_by_median_price
from d0_sales_fact f
join d0_league_event_roles r on r.event_id = f.event_id and r.role='away'
group by r.event_league, r.performer_id, r.performer_name;
;

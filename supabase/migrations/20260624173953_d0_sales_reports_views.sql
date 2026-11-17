-- Migration 20260624173953 · reconstructed from prod · writes: see body
--
-- Recorded 2026-11-17 (branch triage): applied on prod as "d0_sales_reports_views" (version 20260624173953) but present in no
-- file in git. Body is prod's own supabase_migrations.schema_migrations.statements for that row,
-- statements separated by ';'. Recording only — it is already applied; do not re-apply.


-- =====================================================================
-- D0 front-end sales reports: per-performer + per-league
-- Leagues: MLB, NBA, NFL, NHL, MLS, WNBA
-- Sources: seatgeek_sales (market), seatdata (market),
--          evo / seatgeek_orders / tickpick / vivid (owned, succeeded sales)
-- Attribution: each event credited to home (primary performer) and away
--   (other league performers on the card). League totals use the sale
--   grain directly (no double count); per-performer views use home/away roles.
-- =====================================================================

-- 1. League performers (team identity + league)
create or replace view d0_league_performers as
select pm.performer_id, pm.name as performer_name, pm.espn_league as league
from performer_metadata pm
where pm.espn_league in ('MLB','NBA','NFL','NHL','MLS','WNBA');

-- 2. League "home" events (event belongs to the home team's league)
create or replace view d0_league_events as
select e.id as event_id, lp.league
from events e
join d0_league_performers lp on lp.performer_id = e.primary_performer_id;

-- 3. Event -> performer roles (home/away), league teams only
create or replace view d0_league_event_roles as
select e.id as event_id,
       home_lp.league as event_league,
       p.performer_id,
       lp.performer_name,
       lp.league as performer_league,
       case when p.performer_id = e.primary_performer_id then 'home' else 'away' end as role
from events e
join d0_league_performers home_lp on home_lp.performer_id = e.primary_performer_id
cross join lateral (
   select distinct x as performer_id
   from unnest(e.performer_ids || array[e.primary_performer_id]) x
) p
join d0_league_performers lp on lp.performer_id = p.performer_id;

-- 4. Unified sale-grain fact (one row per succeeded/market sale), league home events
create or replace view d0_sales_fact as
-- SeatGeek market sales (latest snapshot per sale, via canonical sg<->tevo map)
select 'seatgeek_sales'::text as source, false as is_owned,
       le.event_id, le.league,
       coalesce(nullif(trim(s.section),''),'(blank)') as section,
       s.quantity::numeric as qty,
       s.broadcast_price as price_per_ticket,
       s.broadcast_price * coalesce(nullif(s.quantity,0),1)::numeric as gross
from d0_league_events le
join sg_events_canonical c on c.tevo_event_id = le.event_id
join lateral (
   select distinct on (ss.sg_sale_id) ss.section, ss.quantity, ss.broadcast_price
   from seatgeek_sales_snapshots ss
   where ss.sg_event_id = c.sg_event_id and ss.sg_sale_id is not null
   order by ss.sg_sale_id, ss.pulled_at desc
) s on true
union all
-- SeatData market sales
select 'seatdata', false, le.event_id, le.league,
       coalesce(nullif(trim(s.section),''),'(blank)'),
       coalesce(nullif(s.quantity,0),1)::numeric, s.price,
       s.price * coalesce(nullif(s.quantity,0),1)::numeric
from d0_league_events le
join seatdata_sales_snapshots s on s.tevo_event_id = le.event_id
union all
-- Owned: EVO succeeded order items
select 'evo', true, le.event_id, le.league,
       coalesce(nullif(trim(i.ticket_group_section),''),'(blank)'),
       i.quantity::numeric, i.price, i.price * i.quantity::numeric
from d0_league_events le
join evo_order_items i on i.event_id = le.event_id
join evo_orders o on o.evo_order_id = i.evo_order_id
join order_status_xref x on x.source='evo' and x.source_status=o.state and x.is_sale_succeeded
union all
-- Owned: SeatGeek succeeded orders
select 'seatgeek_orders', true, le.event_id, le.league,
       coalesce(nullif(trim(o.sale_section),''),'(blank)'),
       o.sale_quantity::numeric, o.sale_price, o.payment_total
from d0_league_events le
join seatgeek_orders o on o.tevo_event_id = le.event_id
join order_status_xref x on x.source='seatgeek' and x.source_status=o.status and x.is_sale_succeeded
union all
-- Owned: TickPick succeeded orders (no section)
select 'tickpick', true, le.event_id, le.league,
       '(no section)', o.quantity::numeric,
       case when o.quantity>0 then o.total / o.quantity else o.total end, o.total
from d0_league_events le
join tickpick_orders o on o.tevo_event_id = le.event_id
join order_status_xref x on x.source='tickpick' and x.source_status=o.status and x.is_sale_succeeded
union all
-- Owned: Vivid succeeded orders (no section)
select 'vivid', true, le.event_id, le.league,
       '(no section)', o.quantity::numeric,
       case when o.quantity>0 then o.total / o.quantity else o.total end, o.total
from d0_league_events le
join vivid_orders o on o.tevo_event_id = le.event_id
join order_status_xref x on x.source='vivid' and x.source_status=o.status and x.is_sale_succeeded;

-- 5. Sale lines attributed to each performer (home + away)  [per-performer base]
create or replace view d0_perf_sale_lines as
select r.performer_id, r.performer_name, r.performer_league, r.role,
       f.source, f.is_owned, f.section, f.qty, f.price_per_ticket, f.gross
from d0_sales_fact f
join d0_league_event_roles r on r.event_id = f.event_id;

-- =====================  PER-PERFORMER REPORTS  =======================

-- A. Revenue by sales source, split home/away
create or replace view d0_perf_by_source as
select performer_id, performer_name, performer_league, role, source, is_owned,
       sum(qty) as tickets, round(sum(gross),2) as revenue
from d0_perf_sale_lines
group by performer_id, performer_name, performer_league, role, source, is_owned;

-- B. Home/away summary incl. visiting (away) revenue + median price
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

-- C. Price distribution per performer (by role)
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

-- D. Sections per performer ranked by revenue and by volume (FE filters rank<=5)
create or replace view d0_perf_sections as
select performer_id, performer_name, performer_league, role, section,
   sum(qty) as tickets, round(sum(gross),2) as revenue,
   row_number() over (partition by performer_id, role order by sum(gross) desc) as rank_by_revenue,
   row_number() over (partition by performer_id, role order by sum(qty) desc) as rank_by_volume
from d0_perf_sale_lines
where section <> '(no section)'
group by performer_id, performer_name, performer_league, role, section;

-- =====================  PER-LEAGUE REPORTS  ==========================

-- E. One row per league: total revenue, tickets, median + avg price (no double count)
create or replace view d0_league_summary as
select league,
   round(sum(gross),2) as total_revenue,
   sum(qty) as tickets_sold,
   round(percentile_cont(0.50) within group (order by price_per_ticket)::numeric,2) as median_price,
   round(avg(price_per_ticket)::numeric,2) as avg_price,
   count(*) as sale_lines
from d0_sales_fact
group by league;

-- F. Visiting (away) teams within each league, by revenue + median price
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

-- Drop the keyword/regex zone system in favour of the manually curated
-- performer_zones + performer_zone_rules tables, which are the source of truth.
-- Sections without a matching rule return 'unmapped' (no guessing).
--
-- performer_zones / performer_zone_rules were populated out-of-band (Supabase
-- dashboard) and aren't tracked in earlier migrations. They're scoped per
-- (performer_id, venue_id) and curated by hand. Future performers/venues will
-- have empty zone data until someone adds rules — that's a feature, not a bug.

drop function if exists get_event_zones_rollup(bigint, boolean);
drop function if exists derive_zone(text, text, bigint, bigint);
drop table if exists zone_rules;

create or replace function get_event_zones_rollup(
  p_event_id   bigint,
  p_owned_only boolean default true
) returns table (
  zone        text,
  tickets     bigint,
  min_retail  numeric,
  max_retail  numeric
)
language sql
stable
as $func$
  with latest as (
    select max(captured_at) as captured_at
    from listings_snapshots where event_id = p_event_id
  ),
  ev as (
    select id as event_id, primary_performer_id as performer_id, venue_id
    from events where id = p_event_id
  ),
  rolled as (
    select
      coalesce(zm.name, 'unmapped') as zone,
      coalesce(zm.display_order, 99999) as display_order,
      l.quantity,
      l.retail_price
    from listings_snapshots l
    join latest using (captured_at)
    cross join ev
    left join lateral (
      select pz.name, pz.display_order
      from performer_zone_rules r
      join performer_zones pz on pz.id = r.zone_id
      where pz.performer_id = ev.performer_id
        and pz.venue_id     = ev.venue_id
        and r.section_from <= l.section
        and r.section_to   >= l.section
        and (
          r.row_from is null
          or (l.row is not null and l.row between r.row_from and r.row_to)
        )
      order by pz.display_order asc, pz.id asc
      limit 1
    ) zm on true
    where l.event_id = p_event_id
      and l.is_ancillary = false
      and (p_owned_only = false or l.is_owned = true)
  )
  select
    zone,
    sum(quantity)::bigint                          as tickets,
    round(min(retail_price)::numeric, 2)           as min_retail,
    round(max(retail_price)::numeric, 2)           as max_retail
  from rolled
  group by zone, display_order
  order by display_order, zone;
$func$;

revoke all on function get_event_zones_rollup(bigint, boolean) from public;
grant execute on function get_event_zones_rollup(bigint, boolean) to service_role;

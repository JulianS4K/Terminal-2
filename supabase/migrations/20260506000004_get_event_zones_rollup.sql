-- Zone-level rollup for one event, latest snapshot. Concise output for SMS:
-- zone, tickets, min_retail, max_retail (no groups, no median).
-- Called by the bot's get_event_zones tool; gated upstream by bot_users.is_internal.
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
    select id as event_id, venue_id from events where id = p_event_id
  )
  select
    derive_zone(l.section, l.row, ev.venue_id, ev.event_id)        as zone,
    sum(l.quantity)::bigint                                        as tickets,
    round(min(l.retail_price)::numeric, 2)                         as min_retail,
    round(max(l.retail_price)::numeric, 2)                         as max_retail
  from listings_snapshots l
  join latest using (captured_at)
  cross join ev
  where l.event_id = p_event_id
    and l.is_ancillary = false
    and (p_owned_only = false or l.is_owned = true)
  group by 1
  order by sum(l.retail_price * l.quantity) desc;
$func$;

revoke all on function get_event_zones_rollup(bigint, boolean) from public;
grant execute on function get_event_zones_rollup(bigint, boolean) to service_role;

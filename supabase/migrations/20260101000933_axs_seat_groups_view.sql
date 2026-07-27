-- AXS consecutive-seat grouping → marketplace-style "N together" listings.
--
-- DATA RULE (AXS): individual seats that are CONSECUTIVE within the same
-- section + row, at the same price and seat_type (and same primary/resale
-- source), are one sellable block — present them grouped, not as N separate
-- rows. v_axs_seat_groups applies the classic gaps-and-islands grouping
-- (seat_no - row_number() is constant across a run of consecutive numbers).
-- Non-numeric seat labels (GA / lettered) can't be range-grouped → each stays
-- its own qty-1 block. Caveat: venues that number odd/even by aisle side break
-- strict numeric adjacency (physically-adjacent seats differ by 2); this rule
-- groups by numeric consecutiveness only, so such rows surface as qty-1 blocks.

create or replace view public.v_axs_seat_groups as
with base as (
  select snapshot_id, axs_event_id, tevo_event_id, tevo_venue_id,
         section_label, row_label, seat_type, src, price, neighborhood, is_ga,
         seat_number,
         case when seat_number ~ '^[0-9]+$' then seat_number::int end as seat_no
  from public.axs_seat_snapshots
),
islands as (
  select *,
    case when seat_no is not null then
      seat_no - row_number() over (
        partition by snapshot_id, section_label, row_label, seat_type, price, src
        order by seat_no)
    end as grp
  from base
)
select
  snapshot_id, axs_event_id, tevo_event_id, tevo_venue_id,
  section_label, row_label, seat_type, src, price,
  max(neighborhood) as neighborhood, bool_or(is_ga) as is_ga,
  count(*) as qty,
  min(seat_no) as seat_from,
  max(seat_no) as seat_to,
  string_agg(coalesce(seat_no::text, seat_number), ',' order by seat_no nulls last, seat_number) as seats
from islands
group by snapshot_id, axs_event_id, tevo_event_id, tevo_venue_id,
         section_label, row_label, seat_type, src, price, grp,
         case when grp is null then seat_number end;

comment on view public.v_axs_seat_groups is
  'AXS DATA RULE: consecutive seats (same section+row+price+seat_type+src, adjacent seat numbers) collapsed into one "N together" block via gaps-and-islands. qty = block size, seat_from/seat_to = range, seats = the member numbers. Non-numeric labels stay qty-1. Source for the marketplace-style AXS listing view.';

-- AXS listings in the EVO/TEvo listing data standard.
--
-- Mirrors public.listings_snapshots' shape (event_id/section/row/quantity/
-- retail_price/format/splits/type/wheelchair/is_owned) so AXS box-office
-- inventory reads like every other source — built on v_axs_seat_groups so each
-- row is a CONSECUTIVE block (the AXS seat-grouping RULE). AXS additionally
-- carries exact seat numbers (TEvo ticket groups don't), surfaced as
-- seat_from/seat_to/seat_numbers. Keyed on tevo_event_id like the standard.

create or replace view public.v_axs_listings as
select
  g.tevo_event_id                                   as event_id,        -- canonical key (nullable until AQ-mapped)
  s.captured_at,
  g.axs_event_id,
  g.snapshot_id,
  g.tevo_venue_id,
  g.section_label                                   as section,
  g.row_label                                       as row,
  g.qty                                             as quantity,
  g.price                                           as retail_price,
  g.seat_type                                       as type,            -- STANDARD|PREMIUM|ACCESSIBLE|FLASHSEATS
  case when g.seat_type = 'FLASHSEATS'
       then 'AXS Mobile ID (FlashSeats)' else 'AXS Mobile ID' end       as format,
  (select array(select generate_series(1, g.qty)))  as splits,          -- any split 1..block size
  (g.seat_type = 'ACCESSIBLE')                       as wheelchair,
  true                                              as eticket,
  true                                              as instant_delivery,
  false                                             as is_owned,         -- never our inventory
  'axs'::text                                       as source,
  g.src,                                                                 -- primary | resale
  g.neighborhood,
  g.is_ga,
  g.seat_from,
  g.seat_to,
  g.seats                                           as seat_numbers      -- AXS-only: exact seats in the block
from public.v_axs_seat_groups g
join public.axs_event_snapshots s on s.id = g.snapshot_id;

comment on view public.v_axs_listings is
  'AXS box-office inventory in the EVO listing standard (section/row/quantity/retail_price/format/splits/type/wheelchair, keyed on tevo_event_id), one row per consecutive-seat block (v_axs_seat_groups). Adds AXS-only seat_from/seat_to/seat_numbers. Read-only.';

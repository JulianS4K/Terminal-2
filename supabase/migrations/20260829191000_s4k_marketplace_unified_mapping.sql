-- Migration 20260829191000 · level:data-collection · lane:A1 · writes:order_status_xref[insert],v_s4k_marketplace_unified[new] · reads:s4k_marketplace_orders,order_status_xref · pre:20260829190000 (s4k_marketplace_orders) · auth:OPERATOR-APPROVAL REQUIRED before apply
--
-- Map S4K marketplace orders onto the existing undelivered/unified model.
--
-- Target model: `unified_orders` is a VIEW that UNION ALLs the per-source order
-- tables (evo_orders, seatgeek_orders, tickpick_orders, vivid_orders), each
-- LEFT JOINed to order_status_xref on (source, source_status) to derive
-- canonical_status / is_terminal / is_sale_succeeded.
--
-- §1 DOUBLE-COUNTING IS THE RISK — READ BEFORE UNIONING.
--   The S4K API fronts SIX marketplaces, and THREE of them we already pull
--   natively into their own tables:
--       SeatGeek    -> seatgeek_orders     (already in unified_orders)
--       TickPick    -> tickpick_orders     (already in unified_orders)
--       Vivid Seats -> vivid_orders        (already in unified_orders)
--   Unioning all six would count those three TWICE in every downstream sales
--   metric. So this view exposes ONLY the three sources that are genuinely new:
--       GoTickets · StubHub · Gametime
--   The other three still land in s4k_marketplace_orders (useful as an
--   independent cross-check against the native pullers) but are deliberately
--   excluded here. Same principle as ticketsdata_client.NATIVE_PLATFORMS.
--   If a native puller is ever retired, move that source out of the exclusion
--   below — do not add it in both places.
--
-- §2 EVERYTHING FROM THIS API IS UNDELIVERED BY CONSTRUCTION.
--   The endpoint serves "open/undelivered" orders only, so no row here is
--   terminal and none is a completed sale: every mapping below is
--   is_terminal = false, is_sale_succeeded = false. A fulfilled order simply
--   stops appearing, which s4k_marketplace_ingest records as closed_at.
--
-- §3 StubHub "statuses" are SELLER ACTION PROMPTS, not order states.
--   Measured 2026-08-29: "Upload Transfer Receipts" (7,955), "Enter Ticket
--   Barcodes" (167), "Print Shipping Label", "On the Way", … These describe
--   what the seller must do next, so they all mean "sale accepted, delivery
--   outstanding" -> canonical 'accepted'. The two "Confirm Sale(s)" variants
--   are the exception: the sale is not yet confirmed -> 'pending'.
--   NOTE an upstream template bug in that vocabulary:
--   "Transfer #{#TicketTypeName#}# Tickets" (119 rows) is an uninterpolated
--   placeholder. Mapped like the other transfer prompts; raise it with S4K.
--   Because this list is open-ended and cosmetic upstream, an UNMAPPED StubHub
--   status must degrade safely — see the coalesce in the view.

-- ---- 1) status vocabulary (measured from a live pull, not guessed) ----------
insert into public.order_status_xref (source, source_status, canonical_status, is_terminal, is_sale_succeeded)
values
  -- Gametime
  ('s4k_gametime',  'unfulfilled',                    'accepted', false, false),
  ('s4k_gametime',  'unconfirmed',                    'pending',  false, false),
  -- GoTickets
  ('s4k_gotickets', 'PENDING_FULFILLMENT',            'accepted', false, false),
  -- StubHub — seller action prompts; all "delivery outstanding".
  ('s4k_stubhub',   'Upload Transfer Receipts',       'accepted', false, false),
  ('s4k_stubhub',   'Enter Ticket Barcodes',          'accepted', false, false),
  ('s4k_stubhub',   'Transfer #{#TicketTypeName#}# Tickets', 'accepted', false, false),
  ('s4k_stubhub',   'Re-enter Barcodes',              'accepted', false, false),
  ('s4k_stubhub',   'Upload E-Tickets',               'accepted', false, false),
  ('s4k_stubhub',   'Upload QR Codes',                'accepted', false, false),
  ('s4k_stubhub',   'Print Shipping Label',           'accepted', false, false),
  ('s4k_stubhub',   'Re-Transfer Ticket',             'accepted', false, false),
  ('s4k_stubhub',   'Upload Ticket Links',            'accepted', false, false),
  ('s4k_stubhub',   'On the Way',                     'accepted', false, false),
  ('s4k_stubhub',   'Ship Tickets',                   'accepted', false, false),
  ('s4k_stubhub',   'Wait for Delivery',              'accepted', false, false),
  -- Sale not yet confirmed by the seller.
  ('s4k_stubhub',   'Confirm Sales',                  'pending',  false, false),
  ('s4k_stubhub',   'Confirm Sale',                   'pending',  false, false),
  -- Replacement offered -> the existing 'substitution' canonical state.
  ('s4k_stubhub',   'Issue reported: replacement tickets offered',
                                                      'substitution', false, false)
on conflict do nothing;

-- ---- 2) unified-shaped projection of the NON-NATIVE sources ----------------
create or replace view public.v_s4k_marketplace_unified as
select
  case o.source
    when 'GoTickets' then 's4k_gotickets'
    when 'StubHub'   then 's4k_stubhub'
    when 'Gametime'  then 's4k_gametime'
  end                                             as source,
  o.order_id                                      as source_order_id,
  null::bigint                                    as tevo_event_id,
  null::text                                      as sg_event_id,
  o.order_status                                  as source_status,
  -- Unmapped statuses must NOT vanish or masquerade as fulfilled. StubHub's
  -- prompt vocabulary changes upstream, so default an unknown one to the
  -- conservative non-terminal 'accepted' rather than NULL (which would drop
  -- the row from any status-filtered view) or 'fulfilled' (which would book a
  -- sale that has not happened).
  coalesce(x.canonical_status, 'accepted')        as canonical_status,
  coalesce(x.is_terminal, false)                  as is_terminal,
  coalesce(x.is_sale_succeeded, false)            as is_sale_succeeded,
  o.delivery                                      as source_type,
  o.price                                         as gross_value,
  o.quantity::bigint                              as quantity,
  null::text                                      as buyer_name,
  null::text                                      as seller_name,
  null::text                                      as client_name,
  o.purchase_date::timestamptz                    as created_at,
  o.last_seen_at                                  as updated_at,
  o.last_seen_at                                  as last_seen_at,
  o.event_name                                    as event_name,
  o.event_date::timestamptz                       as event_date,
  null::text                                      as aq_short_event_id
from public.s4k_marketplace_orders o
left join public.order_status_xref x
       on x.source = case o.source
            when 'GoTickets' then 's4k_gotickets'
            when 'StubHub'   then 's4k_stubhub'
            when 'Gametime'  then 's4k_gametime'
          end
      and x.source_status = o.order_status
where o.closed_at is null
  -- Excluded on purpose: already unioned into unified_orders from their own
  -- native tables. See §1 — adding them here double-counts.
  and o.source in ('GoTickets', 'StubHub', 'Gametime');

comment on view public.v_s4k_marketplace_unified is
  'S4K marketplace orders projected into the unified_orders column shape, restricted to the three sources NOT already pulled natively (GoTickets, StubHub, Gametime). SeatGeek/TickPick/Vivid Seats are excluded to avoid double-counting against seatgeek_orders/tickpick_orders/vivid_orders. All rows are undelivered by construction: never terminal, never a succeeded sale.';
grant select on public.v_s4k_marketplace_unified to service_role;

-- ---- 3) coverage check ------------------------------------------------------
-- Surfaces any status arriving from the three mapped sources that has no
-- order_status_xref row, so vocabulary drift is caught instead of silently
-- defaulting. Pairs with the existing order_status_coverage table.
create or replace view public.v_s4k_marketplace_unmapped_status as
select o.source, o.order_status, count(*) as n, max(o.last_seen_at) as last_seen_at
  from public.s4k_marketplace_orders o
  left join public.order_status_xref x
         on x.source = case o.source
              when 'GoTickets' then 's4k_gotickets'
              when 'StubHub'   then 's4k_stubhub'
              when 'Gametime'  then 's4k_gametime'
            end
        and x.source_status = o.order_status
 where o.closed_at is null
   and o.source in ('GoTickets', 'StubHub', 'Gametime')
   and x.source_status is null
 group by 1, 2
 order by 3 desc;
comment on view public.v_s4k_marketplace_unmapped_status is
  'Statuses from the mapped S4K sources with no order_status_xref row. Non-empty means upstream vocabulary drifted and those rows are defaulting to accepted — add the mapping.';
grant select on public.v_s4k_marketplace_unmapped_status to service_role;

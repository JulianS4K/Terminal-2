-- ============================================================================
-- Migration 20260727140000 — AXS buy deep-link (offer-level) helper for the terminal
--
-- Lane:     A1 (data plane — AXS ingest pipeline)
-- Touches:  axs_event_buy_url() (W, new function)
-- Pre-reqs: 20260727120000 (v2 ingest stores raw with body.onsale.onsale_id)
--
-- WHY: the terminal wants a per-listing "Buy on AXS" hand-off. AXS primary can't
-- deep-link to specific seats (session-signed + Queue-It), so the closest level is
-- the primary offer's seat picker: https://shop.axs.com/?c=axs&e=<onsale_id>,
-- where onsale_id = context_id ∥ offer_id for the "Regular" offer.
--
-- Derived on demand from the already-stored raw payload (STABLE fn) — no table
-- rewrite, no ingest change. NULL for legacy veritix snapshots (no body.onsale).
-- ============================================================================

create or replace function public.axs_event_buy_url(p_snapshot_id bigint)
 returns text
 language sql
 stable
 security definer
 set search_path to 'public', 'pg_temp'
as $function$
  select case
    when (raw #>> '{onsale,onsale_id}') is not null
    then 'https://shop.axs.com/?c=axs&e=' || (raw #>> '{onsale,onsale_id}')
  end
  from public.axs_event_snapshots where id = p_snapshot_id;
$function$;

revoke all on function public.axs_event_buy_url(bigint) from public;
grant execute on function public.axs_event_buy_url(bigint) to service_role;

-- ============================================================================
-- Migration 20260727150000 — stable AXS listing IDs (marketplace-style)
--
-- Lane:     A1 (data plane — AXS ingest pipeline)
-- Touches:  axs_listing_id() (W, new), v_axs_seat_groups (W), v_axs_listings (W),
--           axs_seat_blocks (W, + listing_id column), axs_persist_blocks() (W)
-- Pre-reqs: 20260727130000 (axs_seat_blocks + v_axs_seat_groups + axs_persist_blocks)
--
-- WHY: AXS is primary box office and assigns no listing id, but we want each
-- contiguous seat block numbered the way StubHub/TEvo/etc. track a listing — a
-- stable id that persists across polls so a listing's lifecycle (reprice, shrink,
-- sell) can be followed.
--
-- IDENTITY: deterministic hash of (event, section, row, seat_from, seat_to, type,
-- src). Price and qty are DELIBERATELY excluded — a reprice keeps the same
-- listing_id (so you can detect the price change on one id), matching how
-- marketplaces keep a listing id across edits. A partial sale that shrinks/splits
-- the contiguous run changes seat_from/seat_to → a new id, which is correct: it is
-- genuinely a different sellable block.
-- ============================================================================

create or replace function public.axs_listing_id(
  p_event text, p_section text, p_row text, p_from integer, p_to integer, p_type text, p_src text)
 returns bigint
 language sql
 immutable
as $function$
  select abs(hashtextextended(
    coalesce(p_event,'')   || '|' || coalesce(p_section,'') || '|' || coalesce(p_row,'') || '|' ||
    coalesce(p_from::text,'') || '|' || coalesce(p_to::text,'') || '|' ||
    coalesce(p_type,'')    || '|' || coalesce(p_src,''), 0));
$function$;

-- v_axs_seat_groups + listing_id (append-only column add)
create or replace view public.v_axs_seat_groups as
 WITH base AS (
   SELECT axs_seat_snapshots.snapshot_id, axs_seat_snapshots.axs_event_id,
          axs_seat_snapshots.tevo_event_id, axs_seat_snapshots.tevo_venue_id,
          axs_seat_snapshots.section_label, axs_seat_snapshots.row_label,
          axs_seat_snapshots.seat_type, axs_seat_snapshots.src, axs_seat_snapshots.price,
          axs_seat_snapshots.neighborhood, axs_seat_snapshots.is_ga, axs_seat_snapshots.seat_number,
          CASE WHEN axs_seat_snapshots.seat_number ~ '^[0-9]+$'::text
               THEN axs_seat_snapshots.seat_number::integer ELSE NULL::integer END AS seat_no
   FROM axs_seat_snapshots
 ), islands AS (
   SELECT base.snapshot_id, base.axs_event_id, base.tevo_event_id, base.tevo_venue_id,
          base.section_label, base.row_label, base.seat_type, base.src, base.price,
          base.neighborhood, base.is_ga, base.seat_number, base.seat_no,
          CASE WHEN base.seat_no IS NOT NULL
               THEN base.seat_no - row_number() OVER (PARTITION BY base.snapshot_id, base.section_label,
                      base.row_label, base.seat_type, base.price, base.src ORDER BY base.seat_no)
               ELSE NULL::bigint END AS grp
   FROM base
 )
 SELECT snapshot_id, axs_event_id, tevo_event_id, tevo_venue_id, section_label, row_label,
        seat_type, src, price, max(neighborhood) AS neighborhood, bool_or(is_ga) AS is_ga,
        count(*) AS qty, min(seat_no) AS seat_from, max(seat_no) AS seat_to,
        string_agg(COALESCE(seat_no::text, seat_number), ','::text ORDER BY seat_no, seat_number) AS seats,
        public.axs_listing_id(COALESCE(tevo_event_id::text, axs_event_id), section_label, row_label,
                              min(seat_no)::integer, max(seat_no)::integer, seat_type, src) AS listing_id
 FROM islands
 GROUP BY snapshot_id, axs_event_id, tevo_event_id, tevo_venue_id, section_label, row_label,
          seat_type, src, price, grp, (CASE WHEN grp IS NULL THEN seat_number ELSE NULL::text END);

-- v_axs_listings + listing_id passthrough (append-only)
create or replace view public.v_axs_listings as
 SELECT g.tevo_event_id AS event_id, s.captured_at, g.axs_event_id, g.snapshot_id, g.tevo_venue_id,
        g.section_label AS section, g.row_label AS "row", g.qty AS quantity, g.price AS retail_price,
        g.seat_type AS type,
        CASE WHEN g.seat_type = 'FLASHSEATS'::text THEN 'AXS Mobile ID (FlashSeats)'::text
             ELSE 'AXS Mobile ID'::text END AS format,
        (SELECT ARRAY(SELECT generate_series(1::bigint, g.qty))) AS splits,
        g.seat_type = 'ACCESSIBLE'::text AS wheelchair, true AS eticket, true AS instant_delivery,
        false AS is_owned, 'axs'::text AS source, g.src, g.neighborhood, g.is_ga,
        g.seat_from, g.seat_to, g.seats AS seat_numbers, g.listing_id
 FROM v_axs_seat_groups g
   JOIN axs_event_snapshots s ON s.id = g.snapshot_id;

-- persist listing_id alongside the tracked blocks
alter table public.axs_seat_blocks add column if not exists listing_id bigint;
create index if not exists idx_axs_seat_blocks_listing on public.axs_seat_blocks(listing_id);

create or replace function public.axs_persist_blocks(p_snapshot_id bigint)
 returns integer language plpgsql security definer set search_path to 'public', 'pg_temp'
as $function$
declare v_cap timestamptz; v_n integer;
begin
  select captured_at into v_cap from public.axs_event_snapshots where id = p_snapshot_id;
  delete from public.axs_seat_blocks where snapshot_id = p_snapshot_id;
  insert into public.axs_seat_blocks (
    snapshot_id, tevo_event_id, axs_event_id, tevo_venue_id, section_label, row_label,
    seat_type, src, price, qty, seat_from, seat_to, seats, is_ga, neighborhood,
    gap_before, listing_id, captured_at)
  select
    g.snapshot_id, g.tevo_event_id, g.axs_event_id, g.tevo_venue_id, g.section_label, g.row_label,
    g.seat_type, g.src, g.price, g.qty, g.seat_from, g.seat_to, g.seats, g.is_ga, g.neighborhood,
    greatest(coalesce(
      g.seat_from - lag(g.seat_to) over (
        partition by g.section_label, g.row_label order by g.seat_from) - 1, 0), 0),
    g.listing_id, v_cap
  from public.v_axs_seat_groups g
  where g.snapshot_id = p_snapshot_id;
  get diagnostics v_n = row_count;
  return v_n;
end $function$;

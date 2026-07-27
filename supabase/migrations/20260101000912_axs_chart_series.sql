-- AXS time-series for the event chart workbench: median price + listing count
-- per snapshot, so AXS can be overlaid on the cross-source price/count charts.
-- Median is computed across the snapshot's section price_mins (the box office
-- exposes per-section base prices, not per-listing rows). Keyed by tevo_event_id
-- (the chart's axis), so it lights up once AXS snapshots are AQ-linked + ingested.
create or replace function public.get_axs_event_price_series(
  p_event_id bigint, p_since timestamptz default '1970-01-01T00:00:00+00:00')
returns table(captured_at timestamptz, listings_count int, median_price numeric)
language sql stable as $$
  select s.captured_at,
         s.listings_count,
         percentile_cont(0.5) within group (order by sec.price_min)::numeric
  from public.axs_event_snapshots s
  left join public.axs_section_snapshots sec on sec.snapshot_id = s.id
  where s.tevo_event_id = p_event_id
    and s.captured_at >= p_since
  group by s.id, s.captured_at, s.listings_count
  order by s.captured_at;
$$;

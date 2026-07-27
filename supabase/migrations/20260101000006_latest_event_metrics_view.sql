-- View: latest event_metrics row per event (mirrors latest_snapshots but for the v2 metrics).
-- Used by /api/portfolio for aggregated performer/venue/watchlist views.
-- Applied directly to prod via Supabase MCP on 2026-04-25 alongside the portfolio endpoint.
create or replace view latest_event_metrics as
select distinct on (event_id) *
from event_metrics
order by event_id, captured_at desc;

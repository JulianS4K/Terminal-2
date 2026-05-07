-- Bring section_metrics up to full depth: percentile suite, wholesale, get-in,
-- owned-inventory rollups, and dominant-zone tag.

ALTER TABLE section_metrics
  ADD COLUMN IF NOT EXISTS sections_count integer,
  ADD COLUMN IF NOT EXISTS retail_p25 numeric, ADD COLUMN IF NOT EXISTS retail_p75 numeric,
  ADD COLUMN IF NOT EXISTS retail_p90 numeric, ADD COLUMN IF NOT EXISTS retail_sum numeric,
  ADD COLUMN IF NOT EXISTS wholesale_min numeric, ADD COLUMN IF NOT EXISTS wholesale_median numeric,
  ADD COLUMN IF NOT EXISTS wholesale_mean numeric, ADD COLUMN IF NOT EXISTS wholesale_max numeric,
  ADD COLUMN IF NOT EXISTS getin_price numeric,
  ADD COLUMN IF NOT EXISTS owned_groups_count integer, ADD COLUMN IF NOT EXISTS owned_tickets_count integer,
  ADD COLUMN IF NOT EXISTS owned_share numeric, ADD COLUMN IF NOT EXISTS owned_median_retail numeric,
  ADD COLUMN IF NOT EXISTS zone text, ADD COLUMN IF NOT EXISTS zone_source text;

CREATE INDEX IF NOT EXISTS section_metrics_event_captured_idx ON section_metrics (event_id, captured_at DESC);
CREATE INDEX IF NOT EXISTS section_metrics_zone_idx ON section_metrics (event_id, captured_at, zone);

-- compute_event_section_metrics + compute_event_breakdowns wrapper
-- (full body in 20260507000005_fix_section_metrics_groupby.sql; this file
--  defines the original; v5 patches the GROUP BY bug.)

CREATE OR REPLACE FUNCTION compute_event_breakdowns(p_event_id bigint, p_captured_at timestamptz)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE v_zones integer; v_sections integer;
BEGIN
  v_zones := compute_event_zone_metrics(p_event_id, p_captured_at);
  v_sections := compute_event_section_metrics(p_event_id, p_captured_at);
  RETURN jsonb_build_object('zones_written', v_zones, 'sections_written', v_sections);
END $fn$;

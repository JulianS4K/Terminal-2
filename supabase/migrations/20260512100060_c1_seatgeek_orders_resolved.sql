-- Migration 20260512100060 · level:supervisor · lane:canonical · writes:seatgeek_orders_resolved,resolve_seatgeek_order,backfill_seatgeek_orders_resolved · reads:seatgeek_orders,v_canonical_venue,v_canonical_performer,sg_extract_performers · pre:20260512100000,20260512100030

CREATE TABLE IF NOT EXISTS seatgeek_orders_resolved (
  sg_order_id           text PRIMARY KEY REFERENCES seatgeek_orders(sg_order_id) ON DELETE CASCADE,
  tevo_venue_id         bigint,
  venue_confidence      numeric(3,2),
  venue_match_method    text,
  tevo_performer_ids    bigint[]       NOT NULL DEFAULT '{}',
  performer_confidences numeric(3,2)[] NOT NULL DEFAULT '{}',
  performer_match_methods text[]       NOT NULL DEFAULT '{}',
  occurs_at_resolved    timestamptz,
  resolution_method     text NOT NULL DEFAULT 'historical_venue_performer_v1',
  notes                 text,
  meta                  jsonb       NOT NULL DEFAULT '{}'::jsonb,
  created_at            timestamptz NOT NULL DEFAULT now(),
  updated_at            timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS seatgeek_orders_resolved_venue_idx
  ON seatgeek_orders_resolved (tevo_venue_id) WHERE tevo_venue_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS seatgeek_orders_resolved_performers_gin
  ON seatgeek_orders_resolved USING GIN (tevo_performer_ids);
CREATE INDEX IF NOT EXISTS seatgeek_orders_resolved_occurs_idx
  ON seatgeek_orders_resolved (occurs_at_resolved);

CREATE TRIGGER seatgeek_orders_resolved_updated_at
  BEFORE UPDATE ON seatgeek_orders_resolved
  FOR EACH ROW EXECUTE FUNCTION trg_set_updated_at();

COMMENT ON TABLE seatgeek_orders_resolved IS
  'Path B resolution sidecar for seatgeek_orders. Resolves tevo_venue_id and tevo_performer_ids directly on each SG order, bypassing the missing TEvo event row for historical 2018-2025 sales. Methodology: docs/cross-source-entity-resolution-2026-05-11.md.';

-- RLS
ALTER TABLE seatgeek_orders_resolved ENABLE ROW LEVEL SECURITY;
CREATE POLICY seatgeek_orders_resolved_service_all ON seatgeek_orders_resolved
  FOR ALL TO service_role USING (true) WITH CHECK (true);
CREATE POLICY seatgeek_orders_resolved_readonly_select ON seatgeek_orders_resolved
  FOR SELECT TO coworker_readonly USING (true);

-- Resolver function (one-shot backfill + reactive trigger source)
CREATE OR REPLACE FUNCTION resolve_seatgeek_order(p_sg_order_id text)
RETURNS seatgeek_orders_resolved
LANGUAGE plpgsql
AS $$
DECLARE
  v_order      seatgeek_orders%ROWTYPE;
  v_perfs      text[];
  v_perf_ids   bigint[] := '{}';
  v_perf_confs numeric(3,2)[] := '{}';
  v_perf_methods text[] := '{}';
  v_venue_id   bigint;
  v_venue_conf numeric(3,2);
  v_venue_meth text;
  v_perf       text;
  v_pid        bigint;
  v_result     seatgeek_orders_resolved%ROWTYPE;
BEGIN
  SELECT * INTO v_order FROM seatgeek_orders WHERE sg_order_id = p_sg_order_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'seatgeek_orders row not found for sg_order_id=%', p_sg_order_id;
  END IF;

  -- Venue: exact match against v_canonical_venue on either TEvo or SG name
  SELECT cv.tevo_venue_id INTO v_venue_id
  FROM v_canonical_venue cv
  WHERE lower(cv.tevo_venue_name) = lower(v_order.sg_venue)
     OR lower(cv.sg_venue_name)   = lower(v_order.sg_venue)
  LIMIT 1;

  IF v_venue_id IS NOT NULL THEN
    v_venue_conf := 0.95;
    v_venue_meth := 'exact_name';
  END IF;

  -- Performers via existing sg_extract_performers() helper
  v_perfs := sg_extract_performers(v_order.sg_event_name);

  IF v_perfs IS NOT NULL THEN
    FOREACH v_perf IN ARRAY v_perfs LOOP
      SELECT cp.tevo_performer_id INTO v_pid
      FROM v_canonical_performer cp
      WHERE lower(cp.tevo_performer_name) = lower(v_perf)
         OR lower(cp.sg_performer_name)   = lower(v_perf)
      LIMIT 1;
      IF v_pid IS NOT NULL THEN
        v_perf_ids     := array_append(v_perf_ids, v_pid);
        v_perf_confs   := array_append(v_perf_confs, 0.95::numeric(3,2));
        v_perf_methods := array_append(v_perf_methods, 'exact_name');
      END IF;
    END LOOP;
  END IF;

  INSERT INTO seatgeek_orders_resolved (
    sg_order_id, tevo_venue_id, venue_confidence, venue_match_method,
    tevo_performer_ids, performer_confidences, performer_match_methods,
    occurs_at_resolved, resolution_method
  ) VALUES (
    p_sg_order_id, v_venue_id, v_venue_conf, v_venue_meth,
    v_perf_ids, v_perf_confs, v_perf_methods,
    (v_order.sg_event_date::timestamptz),
    'historical_venue_performer_v1'
  )
  ON CONFLICT (sg_order_id) DO UPDATE SET
    tevo_venue_id = EXCLUDED.tevo_venue_id,
    venue_confidence = EXCLUDED.venue_confidence,
    venue_match_method = EXCLUDED.venue_match_method,
    tevo_performer_ids = EXCLUDED.tevo_performer_ids,
    performer_confidences = EXCLUDED.performer_confidences,
    performer_match_methods = EXCLUDED.performer_match_methods,
    occurs_at_resolved = EXCLUDED.occurs_at_resolved,
    updated_at = now()
  RETURNING * INTO v_result;

  RETURN v_result;
END;
$$;

COMMENT ON FUNCTION resolve_seatgeek_order(text) IS
  'Path B resolver: walks v_canonical_venue + v_canonical_performer via sg_extract_performers() to populate seatgeek_orders_resolved. Idempotent via ON CONFLICT.';

-- Bulk backfill function
CREATE OR REPLACE FUNCTION backfill_seatgeek_orders_resolved(p_limit int DEFAULT 500)
RETURNS TABLE(attempted int, venue_matched int, full_matched int)
LANGUAGE plpgsql
AS $$
DECLARE
  r record;
  v_attempted int := 0;
  v_venue int := 0;
  v_full int := 0;
  v_row seatgeek_orders_resolved%ROWTYPE;
BEGIN
  FOR r IN
    SELECT sg_order_id FROM seatgeek_orders
    WHERE sg_order_id NOT IN (SELECT sg_order_id FROM seatgeek_orders_resolved)
    LIMIT p_limit
  LOOP
    v_attempted := v_attempted + 1;
    v_row := resolve_seatgeek_order(r.sg_order_id);
    IF v_row.tevo_venue_id IS NOT NULL THEN v_venue := v_venue + 1; END IF;
    IF v_row.tevo_venue_id IS NOT NULL AND array_length(v_row.tevo_performer_ids, 1) >= 1 THEN
      v_full := v_full + 1;
    END IF;
  END LOOP;
  RETURN QUERY SELECT v_attempted, v_venue, v_full;
END;
$$;

COMMENT ON FUNCTION backfill_seatgeek_orders_resolved(int) IS
  'Bulk Path B resolver. Call with limit; idempotent across runs. Expected first-run yield (per audit): ~67.8% venue / ~19.8% full match on the 400 historical SG orders.';

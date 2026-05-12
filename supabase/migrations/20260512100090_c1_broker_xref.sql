-- Migration 20260512100090 · level:supervisor · lane:canonical · writes:broker_xref · reads:listings_snapshots,seatgeek_seller_listings · pre:20260512100000,20260512100030

CREATE TABLE IF NOT EXISTS broker_xref (
  tevo_brokerage_id   bigint NOT NULL,
  tevo_brokerage_name text,
  sg_seller_id        text   NOT NULL,
  sg_seller_name      text,
  confidence          numeric(3,2) NOT NULL,
  match_method        text         NOT NULL,
  matched_by          text         NOT NULL DEFAULT 'auto',
  notes               text,
  meta                jsonb        NOT NULL DEFAULT '{}'::jsonb,
  created_at          timestamptz  NOT NULL DEFAULT now(),
  updated_at          timestamptz  NOT NULL DEFAULT now(),
  PRIMARY KEY (tevo_brokerage_id, sg_seller_id)
);

CREATE UNIQUE INDEX IF NOT EXISTS broker_xref_tevo_unique_hc
  ON broker_xref (tevo_brokerage_id) WHERE confidence >= 0.85;
CREATE UNIQUE INDEX IF NOT EXISTS broker_xref_sg_unique_hc
  ON broker_xref (sg_seller_id) WHERE confidence >= 0.85;

CREATE TRIGGER broker_xref_updated_at
  BEFORE UPDATE ON broker_xref
  FOR EACH ROW EXECUTE FUNCTION trg_set_updated_at();

COMMENT ON TABLE broker_xref IS
  'Layer 2.5 of cross-source xref methodology. Maps TEvo brokerage_id ↔ SeatGeek seller. Partial UNIQUE indexes enforce 1:1 mapping at confidence ≥ 0.85; low-confidence dupes allowed for review.';

ALTER TABLE broker_xref ENABLE ROW LEVEL SECURITY;
CREATE POLICY broker_xref_service_all ON broker_xref
  FOR ALL TO service_role USING (true) WITH CHECK (true);
CREATE POLICY broker_xref_readonly_select ON broker_xref
  FOR SELECT TO coworker_readonly USING (true);

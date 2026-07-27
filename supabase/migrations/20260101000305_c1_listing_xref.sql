-- Migration 20260512100120 · level:supervisor · lane:canonical · writes:listing_xref · reads:listings_snapshots,seatgeek_seller_listings,broker_xref · pre:20260512100000,20260512100030,20260512100090

CREATE TABLE IF NOT EXISTS listing_xref (
  id                    bigserial PRIMARY KEY,
  tevo_ticket_group_id  bigint NOT NULL,
  sg_listing_id         text   NOT NULL,
  captured_at_tevo      timestamptz NOT NULL,
  captured_at_sg        timestamptz NOT NULL,
  confidence            numeric(3,2) NOT NULL,
  match_method          text NOT NULL CHECK (match_method IN
                            ('seat_array_intersect','seat_array_disjoint',
                             'broker_section_row_qty','inconclusive')),
  price_spread_pct      numeric(5,2),
  notes                 text,
  meta                  jsonb       NOT NULL DEFAULT '{}'::jsonb,
  created_at            timestamptz NOT NULL DEFAULT now(),
  updated_at            timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS listing_xref_tevo_idx
  ON listing_xref (tevo_ticket_group_id, captured_at_tevo DESC);
CREATE INDEX IF NOT EXISTS listing_xref_sg_idx
  ON listing_xref (sg_listing_id, captured_at_sg DESC);
CREATE INDEX IF NOT EXISTS listing_xref_method_conf_idx
  ON listing_xref (match_method, confidence);

CREATE TRIGGER listing_xref_updated_at
  BEFORE UPDATE ON listing_xref
  FOR EACH ROW EXECUTE FUNCTION trg_set_updated_at();

COMMENT ON TABLE listing_xref IS
  'Layer 4 cross-source listing match. Seat-array intersection is primary; broker_xref + section/row/qty is fallback. Price is NEVER a match key. Not unique on (tevo_id, sg_id) — re-listings over time are legitimate.';

COMMENT ON COLUMN listing_xref.price_spread_pct IS
  'Observability only, NOT a match key. Records (sg_price - tevo_price) / tevo_price at match time.';

ALTER TABLE listing_xref ENABLE ROW LEVEL SECURITY;
CREATE POLICY listing_xref_service_all ON listing_xref
  FOR ALL TO service_role USING (true) WITH CHECK (true);
CREATE POLICY listing_xref_readonly_select ON listing_xref
  FOR SELECT TO coworker_readonly USING (true);

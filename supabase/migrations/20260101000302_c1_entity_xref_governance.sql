-- Migration 20260512100030 · level:supervisor · lane:canonical · writes:entity_xref_overrides,entity_xref_conflicts · reads:- · pre:20260512100000

CREATE TABLE IF NOT EXISTS entity_xref_overrides (
  layer       text NOT NULL CHECK (layer IN ('venue','performer','broker','event','listing')),
  tevo_id     text NOT NULL,
  sg_id       text NOT NULL,
  reason      text,
  set_by      text NOT NULL,
  meta        jsonb       NOT NULL DEFAULT '{}'::jsonb,
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (layer, tevo_id)
);

CREATE TRIGGER entity_xref_overrides_updated_at
  BEFORE UPDATE ON entity_xref_overrides
  FOR EACH ROW EXECUTE FUNCTION trg_set_updated_at();

COMMENT ON TABLE entity_xref_overrides IS
  'Manual cross-source xref overrides. A row here always beats auto-matches for the (layer, tevo_id) key. Single source of truth for "system got this wrong; here is the right answer".';

CREATE TABLE IF NOT EXISTS entity_xref_conflicts (
  id                   bigserial PRIMARY KEY,
  layer                text NOT NULL CHECK (layer IN ('venue','performer','broker','event','listing')),
  tevo_id              text NOT NULL,
  candidate_sg_ids     text[] NOT NULL,
  confidence_scores    numeric(3,2)[] NOT NULL,
  status               text NOT NULL DEFAULT 'needs_review'
                       CHECK (status IN ('needs_review','resolved','dismissed')),
  resolved_at          timestamptz,
  resolution_note      text,
  meta                 jsonb       NOT NULL DEFAULT '{}'::jsonb,
  created_at           timestamptz NOT NULL DEFAULT now(),
  updated_at           timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS entity_xref_conflicts_layer_status_idx
  ON entity_xref_conflicts (layer, status, created_at);

CREATE TRIGGER entity_xref_conflicts_updated_at
  BEFORE UPDATE ON entity_xref_conflicts
  FOR EACH ROW EXECUTE FUNCTION trg_set_updated_at();

COMMENT ON TABLE entity_xref_conflicts IS
  'Log of cross-source xref conflicts where two or more candidates tied within 0.05 confidence. Set status=resolved when manually adjudicated (typically via entity_xref_overrides).';

-- RLS per PR #57 pattern: service_role writes, coworker_readonly reads
ALTER TABLE entity_xref_overrides ENABLE ROW LEVEL SECURITY;
ALTER TABLE entity_xref_conflicts ENABLE ROW LEVEL SECURITY;

CREATE POLICY entity_xref_overrides_service_all ON entity_xref_overrides
  FOR ALL TO service_role USING (true) WITH CHECK (true);
CREATE POLICY entity_xref_overrides_readonly_select ON entity_xref_overrides
  FOR SELECT TO coworker_readonly USING (true);

CREATE POLICY entity_xref_conflicts_service_all ON entity_xref_conflicts
  FOR ALL TO service_role USING (true) WITH CHECK (true);
CREATE POLICY entity_xref_conflicts_readonly_select ON entity_xref_conflicts
  FOR SELECT TO coworker_readonly USING (true);

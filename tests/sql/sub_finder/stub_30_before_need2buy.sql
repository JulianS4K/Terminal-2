ALTER TABLE n2s_items ADD COLUMN IF NOT EXISTS status_label text, ADD COLUMN IF NOT EXISTS raw jsonb,
  ADD COLUMN IF NOT EXISTS item_source text, ADD COLUMN IF NOT EXISTS n2s_updated_at timestamptz;
CREATE TABLE IF NOT EXISTS mcp_api_keys (id bigint primary key, label text);

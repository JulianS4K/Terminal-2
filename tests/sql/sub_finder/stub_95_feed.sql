-- the results feed reads when the CRM's N2S feed last carried an item (mig 20261118172530)
ALTER TABLE n2s_items ADD COLUMN IF NOT EXISTS last_seen_at timestamptz DEFAULT now();

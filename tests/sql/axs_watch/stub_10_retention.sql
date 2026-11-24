-- Stand-in for the retention engine's table (mig 20260705153000): the box-office history (mig 20261124203030) adds
-- its three rows to it. Nothing here sweeps.
CREATE TABLE public.retention_policy (
  table_name text PRIMARY KEY, ts_column text NOT NULL DEFAULT 'captured_at', keep_days integer NOT NULL,
  enabled boolean NOT NULL DEFAULT true, batch_rows integer NOT NULL DEFAULT 50000,
  budget_seconds integer NOT NULL DEFAULT 60, priority integer NOT NULL DEFAULT 100, notes text,
  meta jsonb, keep_where text);

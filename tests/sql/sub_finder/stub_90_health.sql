-- Stand-ins for what mig 20261116210000 (the health check) reads from the data lane: the log of
-- our reads of the CRM's Need-to-Sub feed and the mirror of the CRM's order book. The MLB tables
-- are left out on purpose: the health check must answer without them (scenario s34 adds them).
CREATE TABLE IF NOT EXISTS public.n2s_crm_direct_log (id bigserial PRIMARY KEY, fetched_at timestamptz NOT NULL DEFAULT now(),
  status integer, ms integer, items integer, upserted integer, new_orders integer, error text);
CREATE TABLE IF NOT EXISTS public.s4kcs_orders (id bigserial PRIMARY KEY, last_seen_at timestamptz);

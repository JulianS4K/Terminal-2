-- Stand-ins for what the GoTickets firehose rebuild (mig 20261122030000) reads and writes: the firehose table as it is
-- in prod (shape, primary key, the two indexes, the two invalid REINDEX leftovers, autovacuum options, grants), the
-- deal evidence table, the retention policy row, pg_cron. Shapes follow prod on 2026-11-22.
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='anon') THEN CREATE ROLE anon; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='authenticated') THEN CREATE ROLE authenticated; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='service_role') THEN CREATE ROLE service_role; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='coworker_readonly') THEN CREATE ROLE coworker_readonly; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='analyst_ro') THEN CREATE ROLE analyst_ro; END IF;
END $$;

-- the firehose (mig 20260804230000 + the autovacuum options of 20260911235000)
CREATE TABLE public.gotickets_listings_snapshots (
  tevo_event_id     bigint,
  gt_event_id       bigint      NOT NULL,
  captured_at       timestamptz NOT NULL,
  gt_listing_id     bigint      NOT NULL,
  section           text,
  section_id        bigint,
  row               text,
  quantity          integer,
  display_price     numeric(12,2),
  all_in_price      numeric(12,2),
  service_fee       numeric(12,2),
  face_value        numeric(12,2),
  stock_type        text,
  in_hand_date      date,
  general_admission boolean,
  splits            integer[],
  notes             text,
  PRIMARY KEY (gt_event_id, captured_at, gt_listing_id)
) WITH (autovacuum_vacuum_scale_factor = 0.02, autovacuum_vacuum_insert_scale_factor = 0.05, autovacuum_analyze_scale_factor = 0.02);
CREATE INDEX idx_gt_ls_captured   ON public.gotickets_listings_snapshots (captured_at);
CREATE INDEX idx_gt_ls_event_time ON public.gotickets_listings_snapshots (tevo_event_id, captured_at DESC);
-- the leftovers of REINDEX CONCURRENTLY runs that did not finish (prod carries both, 0 bytes, invalid)
CREATE INDEX idx_gt_ls_captured_ccnew   ON public.gotickets_listings_snapshots (captured_at);
CREATE INDEX idx_gt_ls_event_time_ccnew ON public.gotickets_listings_snapshots (tevo_event_id, captured_at DESC);
GRANT ALL ON public.gotickets_listings_snapshots TO service_role;
GRANT SELECT ON public.gotickets_listings_snapshots TO coworker_readonly, analyst_ro;
COMMENT ON TABLE public.gotickets_listings_snapshots IS 'GoTickets Pro-API listings firehose. 15d retention (20260804230000).';

-- the deal evidence (mig 20260911162500 keep_where): the columns the rebuild reads
CREATE TABLE public.deal_listing_spell (
  id bigserial PRIMARY KEY, source text NOT NULL, tevo_event_id bigint, listing_id bigint NOT NULL, gt_event_id bigint,
  entered_at timestamptz NOT NULL DEFAULT now(), exited_at timestamptz
);

-- the retention engine's policy table (migs 20260705153000, 20260911162500, 20261023043520)
CREATE TABLE public.retention_policy (
  table_name text PRIMARY KEY, ts_column text NOT NULL DEFAULT 'captured_at', keep_days int NOT NULL, batch_rows int NOT NULL DEFAULT 50000,
  budget_seconds int NOT NULL DEFAULT 90, priority int NOT NULL DEFAULT 100, enabled boolean NOT NULL DEFAULT true, keep_where text, notes text,
  last_run_at timestamptz, last_deleted bigint, total_deleted bigint NOT NULL DEFAULT 0, last_error text, clean_runs int NOT NULL DEFAULT 0,
  next_eligible_at timestamptz, created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now()
);
INSERT INTO public.retention_policy (table_name, keep_days, priority, keep_where, notes, last_error, next_eligible_at)
VALUES ('gotickets_listings_snapshots', 15, 10,
        $k$EXISTS (SELECT 1 FROM public.deal_listing_spell s WHERE s.source = 'gotickets' AND s.listing_id = t.gt_listing_id)$k$,
        'GoTickets Pro-API listings firehose — 15d.', 'query_canceled (statement_timeout)', NULL);

-- pg_cron
CREATE SCHEMA cron;
CREATE TABLE cron.job (jobid bigserial PRIMARY KEY, jobname text UNIQUE, schedule text, command text, active boolean NOT NULL DEFAULT true);
CREATE FUNCTION cron.schedule(name text, schedule text, command text) RETURNS bigint LANGUAGE sql AS $$
  INSERT INTO cron.job (jobname, schedule, command) VALUES (name, schedule, command)
  ON CONFLICT (jobname) DO UPDATE SET schedule = excluded.schedule, command = excluded.command RETURNING jobid $$;
CREATE FUNCTION cron.unschedule(name text) RETURNS boolean LANGUAGE sql AS $$ DELETE FROM cron.job WHERE jobname = name RETURNING true $$;

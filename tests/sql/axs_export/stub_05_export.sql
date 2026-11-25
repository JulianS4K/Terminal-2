-- axs_export_sync as it stands BEFORE mig 20261115010000 (which adds cursor, last_full_error,
-- last_full_error_at), plus the TicketsData budget gate the tick asks before starting a run.
CREATE TABLE public.axs_export_sync (
  id                   integer PRIMARY KEY DEFAULT 1,
  run_kind             text,
  run_started_at       timestamptz,
  run_params           jsonb,
  page                 integer,
  tries                integer NOT NULL DEFAULT 0,
  pending_request_id   bigint,
  pending_since        timestamptz,
  pages_in_run         integer NOT NULL DEFAULT 0,
  rows_in_run          integer NOT NULL DEFAULT 0,
  last_full_started_at timestamptz,
  last_full_done_at    timestamptz,
  last_incr_started_at timestamptz,
  last_incr_done_at    timestamptz,
  last_error           text,
  updated_at           timestamptz NOT NULL DEFAULT now(),
  aq_mint_missing      boolean NOT NULL DEFAULT false
);
INSERT INTO public.axs_export_sync (id) VALUES (1);

CREATE FUNCTION public.td_budget_ok() RETURNS boolean LANGUAGE sql STABLE AS $$ SELECT true $$;

-- the shared axs_watch stub carries a reduced axs_export_event; the export upsert writes the full row,
-- so the columns it needs are added here rather than widening the shared stub.
ALTER TABLE public.axs_export_event
  ADD COLUMN IF NOT EXISTS event_title_clean  text,
  ADD COLUMN IF NOT EXISTS performer_ids      bigint[],
  ADD COLUMN IF NOT EXISTS tour_title         text,
  ADD COLUMN IF NOT EXISTS age_restriction    text,
  ADD COLUMN IF NOT EXISTS venue_address      text,
  ADD COLUMN IF NOT EXISTS venue_country      text,
  ADD COLUMN IF NOT EXISTS venue_postal_code  text,
  ADD COLUMN IF NOT EXISTS venue_lat          numeric,
  ADD COLUMN IF NOT EXISTS venue_lon          numeric,
  ADD COLUMN IF NOT EXISTS announce_utc       timestamptz,
  ADD COLUMN IF NOT EXISTS presale_utc        timestamptz,
  ADD COLUMN IF NOT EXISTS first_seen_utc     timestamptz,
  ADD COLUMN IF NOT EXISTS last_seen_utc      timestamptz;

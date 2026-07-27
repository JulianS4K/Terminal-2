-- Registry of AXS events to ingest (sourced from the AXS_RESALE workbook,
-- column D). Parallels ticketsdata_event_xref: the tracked set, drained on a
-- cadence / on demand into axs_event_snapshots via the AXS /fetch pull
-- (~40s + 1 credit each, so NOT a firehose). tevo_event_id / tevo_venue_id are
-- filled from the pull's venue peg + AQ mapping. RLS on, service-role only.

CREATE TABLE IF NOT EXISTS public.axs_events (
  id               bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  axs_event_id     text NOT NULL UNIQUE,   -- native id from the event URL
  event_url        text NOT NULL,
  source_sheets    text,                   -- workbook sheet(s) that referenced it
  tevo_event_id    bigint,                 -- AQ-derived (nullable)
  tevo_venue_id    bigint,                 -- from the pull's axs_venues peg
  active           boolean NOT NULL DEFAULT true,
  last_pulled_at   timestamptz,
  last_snapshot_id bigint REFERENCES public.axs_event_snapshots(id) ON DELETE SET NULL,
  created_at       timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS axs_events_active_idx     ON public.axs_events (active) WHERE active;
CREATE INDEX IF NOT EXISTS axs_events_tevo_event_idx ON public.axs_events (tevo_event_id) WHERE tevo_event_id IS NOT NULL;

COMMENT ON TABLE public.axs_events IS
  'AXS events to ingest (from AXS_RESALE workbook col D). Drained into axs_event_snapshots via /fetch?platform=axs. Read-only source.';

ALTER TABLE public.axs_events ENABLE ROW LEVEL SECURITY;

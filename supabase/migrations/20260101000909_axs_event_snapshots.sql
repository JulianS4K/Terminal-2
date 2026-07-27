-- Normalized AXS snapshot schema. AXS returns one big JSON document per event
-- (api="veritix", primary + AXS-Marketplace resale, ~20-40s/pull). We fit it to
-- our conventions like the other sources: an event-level snapshot row carrying
-- the raw payload + summary metrics (mirrors seatgeek_listings_snapshots:
-- tevo_event_id / captured_at / raw jsonb), plus per-section normalized rows
-- (AXS is section/price-level granular — the analog of per-listing rows).
--
-- Canonical keys: tevo_venue_id is pegged from public.axs_venues; tevo_event_id
-- is the canonical event id, DERIVED via the AQ mapper (axs_event_id is the
-- source-native key from the event URL) and nullable until mapped — same rule
-- as the order/sales tables. RLS on, service-role only.

CREATE TABLE IF NOT EXISTS public.axs_event_snapshots (
  id                bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  captured_at       timestamptz NOT NULL DEFAULT now(),
  axs_event_id      text,                 -- native AXS id from the event URL
  event_url         text,
  tevo_event_id     bigint,               -- canonical, AQ-derived (nullable)
  tevo_venue_id     bigint,               -- pegged from axs_venues
  aq_short_event_id text,
  venue_short_id    text,
  event_name        text,
  venue_name        text,
  occurs_at_local   text,                 -- offset-bearing, matches public.events
  event_tz          text,
  api               text,                 -- AXS backend, e.g. 'veritix'
  onsale_now        boolean,
  onsale_at         timestamptz,
  offsale_at        timestamptz,
  currency          text,
  price_min         numeric,              -- base ticket price ($)
  price_max         numeric,
  getin             numeric,              -- cheapest AVAILABLE base price ($)
  listings_count    integer,
  sections_count    integer,
  offers_count      integer,
  seats_primary     integer,
  seats_resale      integer,
  in_axs_list       boolean,              -- venue found in axs_venues
  canonical_matched boolean,              -- venue has a canonical tevo_venue_id
  response_s        numeric,              -- AXS generation time (s)
  quota_remaining   bigint,
  raw               jsonb                 -- full AXS document
);

CREATE INDEX IF NOT EXISTS axs_event_snapshots_tevo_event_idx
  ON public.axs_event_snapshots (tevo_event_id) WHERE tevo_event_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS axs_event_snapshots_tevo_venue_idx
  ON public.axs_event_snapshots (tevo_venue_id) WHERE tevo_venue_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS axs_event_snapshots_axs_event_idx
  ON public.axs_event_snapshots (axs_event_id, captured_at DESC);

CREATE TABLE IF NOT EXISTS public.axs_section_snapshots (
  id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  snapshot_id     bigint NOT NULL REFERENCES public.axs_event_snapshots(id) ON DELETE CASCADE,
  captured_at     timestamptz NOT NULL DEFAULT now(),
  tevo_event_id   bigint,
  tevo_venue_id   bigint,
  axs_event_id    text,
  section_label   text,
  neighborhood    text,
  is_ga           boolean,
  sold_out        boolean,
  avail_qty       integer,
  price_min       numeric,
  price_max       numeric,
  seat_types      text[],
  has_resale      boolean,                -- section carries AXS-Marketplace resale
  connection_fee  numeric                 -- AXS resale connection fee ($)
);

CREATE INDEX IF NOT EXISTS axs_section_snapshots_snapshot_idx
  ON public.axs_section_snapshots (snapshot_id);
CREATE INDEX IF NOT EXISTS axs_section_snapshots_tevo_event_idx
  ON public.axs_section_snapshots (tevo_event_id) WHERE tevo_event_id IS NOT NULL;

COMMENT ON TABLE public.axs_event_snapshots IS
  'AXS event pulls (primary + AXS-Marketplace resale), one row per fetch. raw=full document; metrics derived by axs_client.normalize(). tevo_venue_id pegged from axs_venues; tevo_event_id AQ-derived. Source is read-only.';
COMMENT ON TABLE public.axs_section_snapshots IS
  'Per-section normalization of an AXS pull (FK axs_event_snapshots). AXS analog of per-listing snapshot rows.';

ALTER TABLE public.axs_event_snapshots   ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.axs_section_snapshots ENABLE ROW LEVEL SECURITY;

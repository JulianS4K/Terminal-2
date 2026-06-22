-- AXS.com venue reference list (operator-supplied scrape, 2026-06-09).
-- Purpose: catalog venues whose primary ticketer is AXS so we can flag them
-- against our canonical venue set. AXS is NOT an integrated resale source —
-- this is a static reference table only (no poller, no cron, read-only).
--
-- Population + exact-match linkage is done as a data step (see
-- scripts/axs_venues_load.py); this migration only creates the schema.

CREATE TABLE IF NOT EXISTS public.axs_venues (
  id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  axs_name      text NOT NULL,                 -- verbatim name from AXS.com
  -- normalized key: lower -> strip leading "the " -> drop non-[a-z0-9]; mirrors
  -- the canonical venue normalization so an exact match is a plain equality.
  -- Names that reduce to '' (CJK / accent-only) fall back to a 'cjk:'-prefixed
  -- key so they stay distinct in the reference list (they never match canon).
  axs_name_norm text GENERATED ALWAYS AS (
    coalesce(
      nullif(regexp_replace(regexp_replace(lower(axs_name),'^the ',''),'[^a-z0-9]+','','g'), ''),
      'cjk:' || lower(btrim(axs_name))
    )
  ) STORED,
  section       text,                          -- the A–Z bucket the name appeared under on AXS
  tevo_venue_id bigint,                        -- exact-normalized match into our canonical set, else NULL
  matched_name  text,                          -- canonical name we matched to (audit trail)
  match_method  text,                          -- 'exact_norm' when linked, NULL when unmapped
  created_at    timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT axs_venues_name_norm_uniq UNIQUE (axs_name_norm)
);

CREATE INDEX IF NOT EXISTS axs_venues_tevo_venue_id_idx
  ON public.axs_venues (tevo_venue_id) WHERE tevo_venue_id IS NOT NULL;

COMMENT ON TABLE public.axs_venues IS
  'AXS.com primary-ticketer venue list (operator scrape 2026-06-09). Static reference; tevo_venue_id is an exact-normalized link to v_canonical_venue/cross_source_venue_map where one exists, NULL = unmapped (review later). AXS is not a resale source.';

ALTER TABLE public.axs_venues ENABLE ROW LEVEL SECURITY;
-- No anon/auth policies: service_role only (matches anon-execute lockdown posture).

-- ============================================================================
-- Phase 12: SG-internal stitching + 2018-2020 ignored_historic bucket
--
-- Two parallel goals:
--   1. Mark the 185 sg_events_canonical rows from 2018-2020 as
--      'ignored_historic' so the matcher / proposals / drift accounting all
--      skip them. We'll re-evaluate when historic Tevo data is loaded.
--   2. Stitch SG-internal data (listings, sales, seller_listings, orders)
--      to sg_events_canonical so every sg_event_id referenced anywhere has
--      exactly one canonical event row, even before a Tevo match lands.
--
-- Queue-for-review pattern:
--   Phase 11's auto-match writes sg_events_canonical.tevo_event_id directly.
--   Per Phase 12 design, broker-initiated matches (from T4 view) should
--   instead queue into sg_event_match_pending; a small RPC promotes
--   confirmed entries.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. match_status column on sg_events_canonical
-- ----------------------------------------------------------------------------
ALTER TABLE sg_events_canonical
  ADD COLUMN IF NOT EXISTS match_status text
    CHECK (match_status IN ('pending','matched','ignored_historic','unmatchable'))
    DEFAULT 'pending';

-- Backfill statuses
UPDATE sg_events_canonical
   SET match_status = CASE
     WHEN tevo_event_id IS NOT NULL                                  THEN 'matched'
     WHEN sg_event_date BETWEEN '2018-01-01' AND '2020-12-31'        THEN 'ignored_historic'
     ELSE 'pending'
   END
 WHERE match_status = 'pending';

CREATE INDEX IF NOT EXISTS sg_events_canonical_match_status_idx
  ON sg_events_canonical (match_status);

-- ----------------------------------------------------------------------------
-- 2. Defensive stitch: ensure every sg_event_id referenced in any SG snapshot
--    or order/seller_listing exists in sg_events_canonical. The collect cron
--    upserts canonical first, but this catches any drift.
-- ----------------------------------------------------------------------------
INSERT INTO sg_events_canonical (sg_event_id, sg_event_name, sg_event_date,
                                 sg_venue_name, match_status, created_at, updated_at)
SELECT DISTINCT s.sg_event_id, s.sg_event_name, s.sg_event_date, s.sg_venue,
       CASE WHEN s.sg_event_date BETWEEN '2018-01-01' AND '2020-12-31'
            THEN 'ignored_historic' ELSE 'pending' END,
       NOW(), NOW()
  FROM (
    SELECT sg_event_id,
           NULL::text  AS sg_event_name,
           NULL::date  AS sg_event_date,
           NULL::text  AS sg_venue
      FROM seatgeek_listings_snapshots
    UNION
    SELECT sg_event_id, NULL, NULL, NULL FROM seatgeek_sales_snapshots
    UNION
    SELECT sg_event_id, sg_event_name, sg_event_date, sg_venue
      FROM seatgeek_orders WHERE sg_event_id IS NOT NULL
    UNION
    SELECT sg_event_id, sg_event_name, sg_event_date, sg_venue
      FROM seatgeek_seller_listings
  ) s
 WHERE NOT EXISTS (
   SELECT 1 FROM sg_events_canonical c WHERE c.sg_event_id = s.sg_event_id)
ON CONFLICT (sg_event_id) DO NOTHING;

-- ----------------------------------------------------------------------------
-- 3. Update v_sg_event_match_proposals to exclude ignored_historic
-- ----------------------------------------------------------------------------
DROP VIEW IF EXISTS v_sg_event_match_proposals CASCADE;
CREATE VIEW v_sg_event_match_proposals AS
WITH sg AS (
  SELECT sg_event_id, sg_event_name, sg_venue_name, sg_event_date, sg_category
    FROM sg_events_canonical
   WHERE tevo_event_id IS NULL
     AND sg_event_date IS NOT NULL
     AND COALESCE(match_status, 'pending') NOT IN ('ignored_historic', 'unmatchable')
),
sg_tokens AS (
  SELECT sg_event_id,
         ARRAY(SELECT t FROM unnest(string_to_array(lower(
           regexp_replace(sg_event_name, '[^a-zA-Z0-9 ]', ' ', 'g')), ' ')) AS t
              WHERE length(t) > 2
                AND t NOT IN ('the','and','with','presale','citi','only','saturday','sunday',
                              'session','stadium','weekend','parking','preseason','game',
                              'games','tour','live','evening','featuring','feat','for')) AS tokens,
         sg_event_name, sg_venue_name, sg_event_date, sg_category
    FROM sg
),
tevo_candidates AS (
  SELECT s.sg_event_id, s.sg_event_name, s.sg_venue_name, s.sg_event_date, s.sg_category, s.tokens AS sg_tokens,
         e.id AS tevo_event_id, e.name AS tevo_event_name, e.venue_id AS tevo_venue_id, e.venue_name AS tevo_venue_name,
         e.primary_performer_name, (e.occurs_at_local::timestamptz)::date AS tevo_event_date, e.event_type AS tevo_event_type
    FROM sg_tokens s
    JOIN events e ON (e.occurs_at_local::timestamptz)::date = s.sg_event_date
     AND (EXISTS (SELECT 1 FROM seatgeek_venue_xref svx WHERE lower(svx.sg_venue_name) = lower(s.sg_venue_name) AND svx.tevo_venue_id = e.venue_id)
       OR lower(trim(e.venue_name)) = lower(trim(s.sg_venue_name))
       OR lower(trim(e.venue_name)) LIKE lower(trim(s.sg_venue_name)) || '%'
       OR lower(trim(s.sg_venue_name)) LIKE lower(trim(e.venue_name)) || '%')
),
scored AS (
  SELECT *, ARRAY(SELECT t FROM unnest(string_to_array(lower(regexp_replace(
    coalesce(tevo_event_name,'') || ' ' || coalesce(primary_performer_name,''),
    '[^a-zA-Z0-9 ]', ' ', 'g')), ' ')) AS t WHERE length(t) > 2) AS tevo_tokens
    FROM tevo_candidates
)
SELECT sg_event_id, sg_event_name, sg_venue_name, sg_event_date, sg_category,
       tevo_event_id, tevo_event_name, tevo_venue_id, tevo_venue_name, tevo_event_date,
       primary_performer_name, tevo_event_type, sg_tokens, tevo_tokens,
       CASE WHEN cardinality(sg_tokens) = 0 OR cardinality(tevo_tokens) = 0 THEN 0::numeric
            ELSE cardinality(ARRAY(SELECT unnest(sg_tokens) INTERSECT SELECT unnest(tevo_tokens)))::numeric / GREATEST(cardinality(sg_tokens), 1)
       END AS token_overlap,
       COUNT(*) OVER (PARTITION BY sg_event_id) AS candidates_at_venue_date
  FROM scored
 ORDER BY sg_event_id, tevo_event_id;

GRANT SELECT ON v_sg_event_match_proposals TO authenticated, anon, service_role;

-- ----------------------------------------------------------------------------
-- 4. Bucket views — what's where in the SG event lifecycle
-- ----------------------------------------------------------------------------
DROP VIEW IF EXISTS v_sg_events_by_status CASCADE;
CREATE VIEW v_sg_events_by_status AS
SELECT match_status, COUNT(*) AS n,
       MIN(sg_event_date) AS earliest_date,
       MAX(sg_event_date) AS latest_date
  FROM sg_events_canonical
 GROUP BY match_status;

DROP VIEW IF EXISTS v_sg_events_pending_match CASCADE;
CREATE VIEW v_sg_events_pending_match AS
SELECT * FROM sg_events_canonical
 WHERE match_status = 'pending';

DROP VIEW IF EXISTS v_sg_events_ignored_historic CASCADE;
CREATE VIEW v_sg_events_ignored_historic AS
SELECT * FROM sg_events_canonical
 WHERE match_status = 'ignored_historic';

GRANT SELECT ON v_sg_events_by_status, v_sg_events_pending_match, v_sg_events_ignored_historic
  TO authenticated, anon, service_role;

-- ----------------------------------------------------------------------------
-- 5. Update orphan views to exclude ignored_historic from the noise floor
-- ----------------------------------------------------------------------------
DROP VIEW IF EXISTS v_orphan_seatgeek_data CASCADE;
CREATE VIEW v_orphan_seatgeek_data AS
WITH ignored AS (
  SELECT sg_event_id FROM sg_events_canonical WHERE match_status = 'ignored_historic'
)
SELECT 'listings'::text AS kind, sg_event_id, COUNT(*) AS row_count, MAX(captured_at) AS last_seen
  FROM seatgeek_listings_snapshots
 WHERE tevo_event_id IS NULL
   AND sg_event_id NOT IN (SELECT sg_event_id FROM ignored)
 GROUP BY sg_event_id
UNION ALL
SELECT 'sales', sg_event_id, COUNT(*), MAX(pulled_at)
  FROM seatgeek_sales_snapshots
 WHERE tevo_event_id IS NULL
   AND sg_event_id NOT IN (SELECT sg_event_id FROM ignored)
 GROUP BY sg_event_id
UNION ALL
SELECT 'orders', sg_event_id, COUNT(*), MAX(pulled_at)
  FROM seatgeek_orders
 WHERE tevo_event_id IS NULL AND sg_event_id IS NOT NULL
   AND sg_event_id NOT IN (SELECT sg_event_id FROM ignored)
 GROUP BY sg_event_id
UNION ALL
SELECT 'seller_listings', sg_event_id, COUNT(*), MAX(pulled_at)
  FROM seatgeek_seller_listings
 WHERE tevo_event_id IS NULL
   AND sg_event_id NOT IN (SELECT sg_event_id FROM ignored)
 GROUP BY sg_event_id;

GRANT SELECT ON v_orphan_seatgeek_data TO authenticated, anon, service_role;

-- ----------------------------------------------------------------------------
-- 6. Broker-queued match table — for the T4 "pin Tevo match" UI action
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS sg_event_match_pending (
  id                   bigserial PRIMARY KEY,
  sg_event_id          bigint NOT NULL,
  proposed_tevo_event_id bigint NOT NULL,
  proposed_by          text,                    -- broker user id / name
  proposed_at          timestamptz NOT NULL DEFAULT NOW(),
  reviewed_by          text,
  reviewed_at          timestamptz,
  status               text NOT NULL DEFAULT 'pending'
                          CHECK (status IN ('pending','approved','rejected','superseded')),
  notes                text,
  meta                 jsonb,
  UNIQUE (sg_event_id, proposed_tevo_event_id)
);

CREATE INDEX IF NOT EXISTS sg_event_match_pending_status_idx
  ON sg_event_match_pending (status);

-- queue_sg_event_match: broker action — write a pending row, no canonical change
CREATE OR REPLACE FUNCTION queue_sg_event_match(
  p_sg_event_id          bigint,
  p_proposed_tevo_event_id bigint,
  p_proposed_by          text DEFAULT NULL,
  p_notes                text DEFAULT NULL,
  p_meta                 jsonb DEFAULT '{}'::jsonb
) RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE v_id bigint;
BEGIN
  INSERT INTO sg_event_match_pending
    (sg_event_id, proposed_tevo_event_id, proposed_by, notes, meta)
  VALUES (p_sg_event_id, p_proposed_tevo_event_id, p_proposed_by, p_notes, p_meta)
  ON CONFLICT (sg_event_id, proposed_tevo_event_id)
    DO UPDATE SET proposed_by = EXCLUDED.proposed_by,
                  proposed_at = NOW(),
                  notes       = EXCLUDED.notes,
                  meta        = EXCLUDED.meta,
                  status      = 'pending'
  RETURNING id INTO v_id;
  RETURN v_id;
END;
$$;
GRANT EXECUTE ON FUNCTION queue_sg_event_match(bigint, bigint, text, text, jsonb)
  TO authenticated, service_role;

-- approve_sg_event_match: reviewer action — promote a pending row into the
-- canonical mapping. The Phase 4 trigger sg_events_canonical_to_xref then
-- cascades to seatgeek_event_xref and on to canonical_external_ids.
CREATE OR REPLACE FUNCTION approve_sg_event_match(
  p_pending_id   bigint,
  p_reviewed_by  text DEFAULT NULL
) RETURNS void LANGUAGE plpgsql AS $$
DECLARE r RECORD;
BEGIN
  SELECT * INTO r FROM sg_event_match_pending WHERE id = p_pending_id AND status = 'pending'
   FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'no pending match with id %', p_pending_id;
  END IF;
  UPDATE sg_events_canonical
     SET tevo_event_id    = r.proposed_tevo_event_id,
         match_method     = 'broker_manual_approved',
         match_confidence = 1.0,
         match_status     = 'matched',
         matched_at       = NOW(),
         updated_at       = NOW()
   WHERE sg_event_id = r.sg_event_id;
  UPDATE sg_event_match_pending
     SET status = 'approved', reviewed_by = p_reviewed_by, reviewed_at = NOW()
   WHERE id = p_pending_id;
  -- Mark any other pending entries for the same sg_event_id as superseded
  UPDATE sg_event_match_pending
     SET status = 'superseded', reviewed_by = p_reviewed_by, reviewed_at = NOW()
   WHERE sg_event_id = r.sg_event_id AND id <> p_pending_id AND status = 'pending';
END;
$$;
GRANT EXECUTE ON FUNCTION approve_sg_event_match(bigint, text) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION reject_sg_event_match(
  p_pending_id   bigint,
  p_reviewed_by  text DEFAULT NULL,
  p_reason       text DEFAULT NULL
) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  UPDATE sg_event_match_pending
     SET status = 'rejected', reviewed_by = p_reviewed_by, reviewed_at = NOW(),
         notes = COALESCE(p_reason, notes)
   WHERE id = p_pending_id AND status = 'pending';
END;
$$;
GRANT EXECUTE ON FUNCTION reject_sg_event_match(bigint, text, text) TO authenticated, service_role;

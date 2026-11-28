-- Migration 20261128080000 · level:data-collection · lane:a1 (AXS watch) · writes:axs_collision_evidence(new),axs_collision_evidence_snapshot()(new),v_axs_collision_dossier(new) · reads:axs_watch_raw_capture,primary_poll_event,v_axs_event_collisions
--
-- ============================================================================
-- Migration 20261128080000 — a dossier the collisions cannot outlive
--
-- Lane:     a1 (AXS watch)
-- pre:      20261127220000 (raw capture), 20261128060030 (venue-scoped collisions)
--
-- READ-ONLY UPSTREAM (RULE 2): nothing here calls a market. It only reads bodies already
-- stored by the poller.
--
-- Operator 2026-11-28: "lets document the collisions over the weekend and then hit ticketsdata
-- on monday with more evidence".
--
-- ── WHY A TABLE AND NOT JUST THE RAW CAPTURES ─────────────────────────────
-- axs_watch_raw_capture keeps whole bodies, which is what proved the defect, but it is not a
-- record we can take to anyone: it grows without bound, it is pruned, and the proof is buried
-- in a 600-listing array. This stores the extracted proof per read, so the dossier survives
-- pruning and reads as a table.
--
-- ── THE PROOF, AS ESTABLISHED ON 2026-11-28 ───────────────────────────────
-- Internal event 5263, Toyota Center, Trans-Siberian Orchestra 2026-12-11:
--   our 1579099  event.starts_local 15:00  sub_event "TSO - 3:00 PM" @ 15:00   SELF-CONSISTENT
--   our 1579101  event.starts_local 19:30  sub_event "TSO - 3:00 PM" @ 15:00   WRONG
--   Both return 1,672 seats. The intersection on (section|row|seat|face) is 1,672. Zero seats
--   are unique to either. The 19:30 show is being served the 15:00 show's inventory.
--   TicketsData's own fee name says so: 292 listings under BOTH events carry
--   "Service Fee - 261211_300 TSO" — 261211 is 2026-12-11 and 300 is the 3:00 PM performance.
--   That string is the single most useful line of evidence we have, because it is their own
--   label for the performance, not our inference from a timestamp.
--
-- Internal event 5217, Toyota Center:
--   our 1374728  "Disney Descendants, ZOMBIES..." starts_local 2026-12-02 19:00
--                but sub_event "for KING + COUNTRY" @ 2026-12-03 19:00
--   our 1519444  "for KING + COUNTRY"             starts_local 2026-12-03 19:00
--   1,874 of ~1,879 seats shared; the handful that differ are sales in the ~3 h between the
--   two captures. A children's musical is publishing a Christian rock show's seats.
--
-- ── SELF-CONSISTENCY IS THE DISCRIMINATOR ─────────────────────────────────
-- self_consistent compares the body's own event.starts_local against its own
-- onsale.sub_events[0].date. It matters because in a collision pair ONE SIDE IS USUALLY
-- RIGHT: 1579099 is the real 3:00 PM show and its body agrees with itself. Only 1579101 is
-- defective. Pausing both was the safe first move; the dossier is what tells us which one can
-- go back to publishing.
--
-- ── NO CRON ───────────────────────────────────────────────────────────────
-- Deliberately not scheduled. The snapshot is taken by whoever is looking — the hourly AXS
-- monitor pass over the weekend — so this adds no cron, no credits and no upstream reads.
-- Calling it twice in the same minute for the same read is harmless: the unique index makes a
-- repeat a no-op rather than a duplicate row.
--
-- ── ROLLBACK ──────────────────────────────────────────────────────────────
-- DROP VIEW public.v_axs_collision_dossier;
-- DROP FUNCTION public.axs_collision_evidence_snapshot();
-- DROP TABLE public.axs_collision_evidence;
-- ============================================================================

BEGIN;

CREATE TABLE IF NOT EXISTS public.axs_collision_evidence (
  id                  bigserial PRIMARY KEY,
  snapshot_at         timestamptz NOT NULL DEFAULT now(),
  captured_at         timestamptz NOT NULL,
  axs_event_internal  text        NOT NULL,
  venue_name          text,
  our_event_id        text        NOT NULL,
  our_event_name      text,
  our_event_date      date,
  body_event_title    text,
  body_starts_local   text,
  sub_event_title     text,
  sub_event_date      text,
  self_consistent     boolean,
  listing_count       integer,
  seat_count          integer,
  perf_coded_fees     integer,
  fee_name_samples    text[],
  offer_name_samples  text[],
  note                text
);

-- one row per (event, read): a second snapshot of the same read changes nothing
CREATE UNIQUE INDEX IF NOT EXISTS axs_collision_evidence_read_uniq
  ON public.axs_collision_evidence (our_event_id, captured_at);
CREATE INDEX IF NOT EXISTS axs_collision_evidence_internal_idx
  ON public.axs_collision_evidence (axs_event_internal, captured_at DESC);

REVOKE ALL ON public.axs_collision_evidence FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.axs_collision_evidence TO service_role;

-- Extract the proof from every stored body belonging to an event that shares an AXS internal
-- event id with another watched event at the same venue. Returns how many rows it added.
CREATE OR REPLACE FUNCTION public.axs_collision_evidence_snapshot()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_added integer;
BEGIN
  WITH cap AS (
    SELECT c.axs_event_id, c.captured_at, c.body->'body' AS b
      FROM public.axs_watch_raw_capture c
     WHERE jsonb_typeof(c.body->'body'->'listings') = 'array'
  ), ours AS (
    SELECT cap.*,
           public.axs_watch_internal_event_id(cap.b) AS internal,
           t.name, t.event_date, t.venue_name
      FROM cap
      JOIN public.primary_poll_event t
        ON t.source = 'axs' AND t.source_event_id = cap.axs_event_id
  ), colliding AS (
    -- the same test the settle makes: another watched event at the same venue, same internal id
    SELECT o.* FROM ours o
     WHERE o.internal IS NOT NULL
       AND EXISTS (SELECT 1 FROM public.primary_poll_event p
                    WHERE p.source = 'axs' AND p.axs_event_internal = o.internal
                      AND p.source_event_id <> o.axs_event_id
                      AND p.venue_name IS NOT DISTINCT FROM o.venue_name)
  ), rolled AS (
    SELECT c.axs_event_id, c.captured_at, c.internal, c.venue_name, c.name, c.event_date,
           c.b->'event'->>'title'                     AS body_title,
           c.b->'event'->>'starts_local'              AS starts_local,
           c.b->'onsale'->'sub_events'->0->>'title'   AS sub_title,
           c.b->'onsale'->'sub_events'->0->>'date'    AS sub_date,
           jsonb_array_length(c.b->'listings')        AS n_listings,
           (SELECT count(*) FROM jsonb_array_elements(c.b->'listings') l,
                   jsonb_array_elements_text(coalesce(l->'seats','[]'::jsonb)) s)::int AS n_seats,
           (SELECT count(*) FROM jsonb_array_elements(c.b->'listings') l,
                   jsonb_array_elements(coalesce(l->'pricing'->'fees','[]'::jsonb)) f
             WHERE f->>'name' ~ '[0-9]{6}_[0-9]{3,4}')::int AS n_perf_fees,
           (SELECT array_agg(DISTINCT f->>'name')
              FROM jsonb_array_elements(c.b->'listings') l,
                   jsonb_array_elements(coalesce(l->'pricing'->'fees','[]'::jsonb)) f
             WHERE f->>'name' ~ '[0-9]{6}_[0-9]{3,4}')     AS perf_fee_names,
           (SELECT array_agg(DISTINCT l->>'offer_name')
              FROM jsonb_array_elements(c.b->'listings') l
             WHERE coalesce(l->>'offer_name','') <> '')     AS offer_names
      FROM colliding c
  )
  INSERT INTO public.axs_collision_evidence
    (captured_at, axs_event_internal, venue_name, our_event_id, our_event_name, our_event_date,
     body_event_title, body_starts_local, sub_event_title, sub_event_date, self_consistent,
     listing_count, seat_count, perf_coded_fees, fee_name_samples, offer_name_samples, note)
  SELECT r.captured_at, r.internal, r.venue_name, r.axs_event_id, r.name, r.event_date,
         r.body_title, r.starts_local, r.sub_title, r.sub_date,
         -- Wall clock against wall clock: sub_events[].date carries no zone, so the naive
         -- local parts are what compare. Taking the offset off starts_local with right(...,6)
         -- breaks on a 'Z' suffix, and a capturing group in substring() returns the GROUP, not
         -- the match -- both caught in the harness before this reached prod.
         -- NULL where either side is unreadable, rather than a false verdict.
         CASE WHEN substring(r.starts_local from '^(\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}(?::\d{2})?)') IS NULL
                OR substring(r.sub_date     from '^(\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}(?::\d{2})?)') IS NULL
              THEN NULL
              ELSE abs(extract(epoch FROM (
                     substring(r.starts_local from '^(\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}(?::\d{2})?)')::timestamp
                   - substring(r.sub_date     from '^(\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}(?::\d{2})?)')::timestamp))) <= 1800
         END,
         r.n_listings, r.n_seats, r.n_perf_fees,
         r.perf_fee_names[1:6], r.offer_names[1:6],
         'snapshot of a stored read; collision proved by shared AXS internal event id ' || r.internal
    FROM rolled r
   ON CONFLICT (our_event_id, captured_at) DO NOTHING;
  GET DIAGNOSTICS v_added = ROW_COUNT;
  RETURN v_added;
END $function$;

REVOKE ALL ON FUNCTION public.axs_collision_evidence_snapshot() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.axs_collision_evidence_snapshot() TO service_role;

-- The dossier as one would present it: a pair to a row, newest read each.
CREATE OR REPLACE VIEW public.v_axs_collision_dossier AS
WITH latest AS (
  SELECT DISTINCT ON (our_event_id) *
    FROM public.axs_collision_evidence
   ORDER BY our_event_id, captured_at DESC
)
SELECT axs_event_internal,
       venue_name,
       count(*)                                                    AS our_events,
       array_agg(our_event_id       ORDER BY body_starts_local)     AS event_ids,
       array_agg(our_event_name     ORDER BY body_starts_local)     AS event_names,
       array_agg(body_starts_local  ORDER BY body_starts_local)     AS starts_local,
       array_agg(sub_event_title    ORDER BY body_starts_local)     AS sub_event_titles,
       array_agg(sub_event_date     ORDER BY body_starts_local)     AS sub_event_dates,
       array_agg(self_consistent    ORDER BY body_starts_local)     AS self_consistent,
       array_agg(listing_count      ORDER BY body_starts_local)     AS listing_counts,
       array_agg(seat_count         ORDER BY body_starts_local)     AS seat_counts,
       -- the same performance-coded fee under two of our events is the headline
       (SELECT array_agg(DISTINCT x) FROM latest l2,
               unnest(coalesce(l2.fee_name_samples,'{}')) x
         WHERE l2.axs_event_internal = latest.axs_event_internal)   AS performance_coded_fees,
       min(captured_at)                                             AS oldest_read,
       max(captured_at)                                             AS newest_read,
       (SELECT count(*) FROM public.axs_collision_evidence e
         WHERE e.axs_event_internal = latest.axs_event_internal)     AS reads_on_file
  FROM latest
 GROUP BY axs_event_internal, venue_name
 ORDER BY axs_event_internal;

REVOKE ALL ON public.v_axs_collision_dossier FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.v_axs_collision_dossier TO service_role;

COMMIT;

NOTIFY pgrst, 'reload schema';

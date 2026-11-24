-- Migration 20261124120000 · level:data-collection · lane:A1 (data plane — cross-source listings) · writes:listing_overlap_config(new),listing_overlap_label(new),listing_overlap_event(new),listing_overlap_evo_live(new),listing_overlap_evo_poll(new),v_listing_overlap_event(new),listing_overlap_*()(new),cron:listing_overlap_tick_30s(new) · reads:listings_snapshots,gotickets_listings_snapshots,gotickets_event,event_metrics,evo_listings_poll_state,gt_listings_poll_state,events,collector_cadence
--
-- ============================================================================
-- Migration 20261124120000 — label every EVO and GoTickets listing as on both
--   markets or on one only, as each listings poll lands
--
-- Lane:     A1 (data plane — cross-source listings)
-- Touches:  listing_overlap_config (W), listing_overlap_label (W), listing_overlap_event (W),
--           listing_overlap_evo_live (W), listing_overlap_evo_poll (W),
--           listings_snapshots (R), gotickets_listings_snapshots (R), gotickets_event (R),
--           event_metrics (R), evo_listings_poll_state (R), gt_listings_poll_state (R),
--           events (R), collector_cadence (R)
-- Pre-reqs: 20261023051000 + 20261023054000 (pinned listing polls), 20260909223000
--           (seat_section_norm). The exact EVO book needs the collect-listings edge
--           function that calls listing_overlap_evo_seen(); until that is deployed the
--           matcher runs on the change-only firehose and says so (evo_exact = false).
--
-- Prefix note: authored 2026-11-17 as 20261117030000; renumbered 20261124120000 before it was
-- applied anywhere, because 20261117030000_mapping_program_batch2 took that slot on main.
--
-- Operator 2026-11-17: "look at the listings we get from Evo and gotix, and figure out
-- what's in both and what's exists in only one and label them" … "Expand coverage to
-- events we poll constantly, and build a system to match and label upon polling".
--
-- WHAT IT COVERS. Every event the listing pollers poll on both markets: an EVO poll
-- (evo_listings_poll_state) and a GoTickets poll (gt_listings_poll_state) of a GoTickets
-- event mapped to the same TEvo event. On 2026-11-17 the pins put 4,772 games in the EVO
-- poll and 3,004 of them had a GoTickets event. Nothing here adds a poll or calls a market:
-- it reads what the pollers already stored (RULE 2 — no upstream call of any kind).
--
-- THE TWO BOOKS.
--   GoTickets  every poll stores the whole book at one captured_at (gt_listings_drain
--              inserts every listing of the response), so the book is the rows of the
--              latest capture. A poll that came back empty leaves no rows; the poll
--              state's consecutive_empty > 0 says the book is empty.
--   EVO        collect-listings stores a ticket group only when it is new, changed, or
--              its last row is over an hour old. So at the latest capture T every live
--              group has a row in (T - 61 min, T], but so does a group that left inside
--              that hour. listing_overlap_evo_seen() takes the ids of the whole response
--              from the edge function and keeps the live set (listing_overlap_evo_live,
--              written only for groups that arrive or leave). With it the EVO book is
--              exact; without it (evo_exact = false) a group delisted in the last hour
--              is still counted until it ages out.
--   Parking and other ancillary EVO groups, and GoTickets parking events, are left out.
--
-- THE MATCH. Neither feed carries seat numbers, so "the same listing" is inferred:
-- same event, same section, same row, same quantity, and a GoTickets all-in price within
-- price_band of price_center x the EVO retail price (log scale; defaults 0.989 and 0.12,
-- i.e. roughly 0.88 to 1.12). On 2026-11-17, over the 20 events with a complete book on
-- both sides (8,710 GoTickets listings), 4,893 section/row/quantity spots held exactly one
-- listing per market: the price ratio had median 0.989 and 95 % were within +/-10 %.
--   Sections  seat_section_norm() (the token the CRM, TEvo, GoTickets and SeatGeek share),
--             then a glued letter prefix is dropped when three or more digits follow
--             ("C129" = "Club 129", "VIP111" = "VIP 111", "Section108D" = "Section 108D")
--             and punctuation and spaces are removed ("FLOORE" = "Floor E"). A shorter
--             code keeps its letters ("A6" is not "B6"). Venue nicknames that differ
--             ("C-B" vs "Club B") do not match: those listings are labelled one-market
--             with reason section_absent rather than guessed.
--   Pairing   inside one section/row/quantity spot both sides are sorted by price and
--             walked together (listing_overlap_pair), so two sellers' pairs in one row
--             are matched to their own copies and the leftover stays unpaired.
--
-- THE LABELS (listing_overlap_label, one row per listing currently in a book).
--   both      paired with counterpart_id on the other market (reason paired)
--   unclear   the same section, row and quantity is free on the other market, but the
--             price is outside the band (reason price_gap)
--   evo_only / gt_only, with the reason:
--     extra_copy      the other market has that section/row/quantity, all paired already
--     qty_differs     same section and row there, no listing of this quantity
--     row_absent      the section is there, this row is not
--     section_absent  the section is not on the other market (or is named differently)
-- A row is rewritten only when its label, reason or counterpart changes (or the price
-- ratio moves 0.02), so writes follow listing churn, not poll volume. label_since is when
-- the current label began.
--
-- UPON POLLING. listing_overlap_tick() (cron listing_overlap_tick_30s, single-runner via
-- cron_try_lock) picks the events whose EVO or GoTickets poll fired after the capture last
-- matched, keeps those where a new capture has actually landed, and matches up to
-- tick_max_events of them, least recently matched first, inside tick_budget_seconds.
--
-- WHY EVERY 30 SECONDS (operator 2026-11-17: "note response times and fix timer
-- accordingly"). Measured 2026-11-17 over three hours of the pinned polls:
--   the poll tick fires at second :01 of every even minute and takes 8 s (p95 15 s);
--   an EVO response is stamped 18 s after its poll fired (p95 64 s, max 76 s);
--   a GoTickets response arrives ~13 s after firing and is stored by gt_ingest_drain_1min,
--   which starts at second :01 of every minute and takes 1.3 s (p95 7 s).
-- A job on the minute would start alongside that drain, miss what it is storing, and label
-- a GoTickets poll a full minute late. Every 30 seconds, whatever its phase, a stored
-- response is matched within 30 seconds. The work budget is 20 s, counted from the start
-- of the tick, so a tick ends before the next one is due; a tick that does overrun makes
-- the next one skip (cron_try_lock).
-- A book older than three poll intervals (collector_cadence) plus 15 minutes is not
-- matched against: the event is marked stale_evo / stale_gt and its labels are removed —
-- no label rather than a wrong one. Labels untouched for 50 hours are removed the same way.
--
-- READ IT. listing_overlap_event_listings(event) = both books with each listing's label;
-- v_listing_overlap_event = one row per event (counts, capture times, status).
-- Service-role only for now; no terminal panel reads it yet.
--
-- STOP IT. UPDATE public.listing_overlap_config SET enabled = false;  (the tick returns at once)
-- rollback: SELECT cron.unschedule('listing_overlap_tick_30s');
--           DROP VIEW public.v_listing_overlap_event;
--           DROP FUNCTION public.listing_overlap_event_listings(bigint), public.listing_overlap_tick(integer, integer),
--             public.listing_overlap_match_event(bigint), public.listing_overlap_compute(bigint, timestamptz, boolean, numeric, numeric),
--             public.listing_overlap_gt_book(bigint), public.listing_overlap_gt_cap(bigint), public.listing_overlap_gt_sources(bigint),
--             public.listing_overlap_evo_book(bigint, timestamptz, boolean), public.listing_overlap_evo_seen(bigint, timestamptz, bigint[]),
--             public.listing_overlap_pair(numeric[], numeric[], numeric, numeric),
--             public.listing_overlap_row_key(text), public.listing_overlap_section_key(text);
--           DROP TABLE public.listing_overlap_label, public.listing_overlap_event, public.listing_overlap_evo_live,
--             public.listing_overlap_evo_poll, public.listing_overlap_config;
-- ============================================================================

SET LOCAL lock_timeout = '10s';

-- ---------------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.listing_overlap_config (
  id                  boolean     PRIMARY KEY DEFAULT true CHECK (id),
  enabled             boolean     NOT NULL DEFAULT true,
  price_center        numeric     NOT NULL DEFAULT 0.989 CHECK (price_center > 0),
  price_band          numeric     NOT NULL DEFAULT 0.12  CHECK (price_band > 0 AND price_band < 1),
  tick_max_events     integer     NOT NULL DEFAULT 80    CHECK (tick_max_events BETWEEN 1 AND 500),
  tick_budget_seconds integer     NOT NULL DEFAULT 20    CHECK (tick_budget_seconds BETWEEN 1 AND 50),
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE public.listing_overlap_config IS
  'One row. enabled = the kill switch for listing_overlap_tick(); price_center / price_band = the GoTickets all-in to EVO retail price ratio a pair must fall in (log scale); tick_* = work per 30-second tick (mig 20261124120000).';
INSERT INTO public.listing_overlap_config (id) VALUES (true) ON CONFLICT (id) DO NOTHING;

CREATE TABLE IF NOT EXISTS public.listing_overlap_label (
  tevo_event_id   bigint      NOT NULL,
  source          text        NOT NULL CHECK (source IN ('evo', 'gt')),
  listing_id      bigint      NOT NULL,
  label           text        NOT NULL CHECK (label IN ('both', 'evo_only', 'gt_only', 'unclear')),
  reason          text        NOT NULL CHECK (reason IN ('paired', 'price_gap', 'extra_copy', 'qty_differs', 'row_absent', 'section_absent')),
  counterpart_id  bigint,
  price_ratio     numeric(7,3),
  label_since     timestamptz NOT NULL DEFAULT now(),
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (tevo_event_id, source, listing_id)
);
COMMENT ON TABLE public.listing_overlap_label IS
  'Current label of every listing in the EVO and GoTickets books of a polled event: both (paired with counterpart_id on the other market), evo_only / gt_only, or unclear (same section, row and quantity on the other market at a price outside the band). source evo: listing_id = tevo_ticket_group_id; source gt: listing_id = gt_listing_id. price_ratio = GoTickets all-in / EVO retail. Rewritten only when a label changes; a listing that leaves its book loses its row. Written by listing_overlap_match_event() only (mig 20261124120000).';

CREATE TABLE IF NOT EXISTS public.listing_overlap_event (
  tevo_event_id  bigint      PRIMARY KEY,
  status         text        NOT NULL CHECK (status IN ('ok', 'stale_evo', 'stale_gt')),
  evo_cap        timestamptz,
  gt_cap         timestamptz,
  evo_exact      boolean     NOT NULL DEFAULT false,
  evo_listings   integer,
  gt_listings    integer,
  both_pairs     integer,
  evo_only       integer,
  gt_only        integer,
  evo_unclear    integer,
  gt_unclear     integer,
  matched_at     timestamptz NOT NULL DEFAULT now(),
  duration_ms    integer,
  created_at     timestamptz NOT NULL DEFAULT now(),
  updated_at     timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS listing_overlap_event_matched_idx ON public.listing_overlap_event (matched_at);
COMMENT ON TABLE public.listing_overlap_event IS
  'One row per event the overlap matcher has seen: the EVO and GoTickets captures it last matched (evo_cap, gt_cap), the counts, and status — ok, or stale_evo / stale_gt when one book was too old to match against (labels removed). evo_exact = the EVO book came from the live id set of that very capture; false = rebuilt from the change-only firehose, where a group delisted in the last hour still counts (mig 20261124120000).';

CREATE TABLE IF NOT EXISTS public.listing_overlap_evo_live (
  event_id              bigint      NOT NULL,
  tevo_ticket_group_id  bigint      NOT NULL,
  first_seen_at         timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (event_id, tevo_ticket_group_id)
);
COMMENT ON TABLE public.listing_overlap_evo_live IS
  'The ticket groups in the latest EVO response of an event, kept by listing_overlap_evo_seen(): a row is inserted when a group first appears and deleted when a response no longer carries it, so writes follow arrivals and departures only. The capture it describes is in listing_overlap_evo_poll (mig 20261124120000).';

CREATE TABLE IF NOT EXISTS public.listing_overlap_evo_poll (
  event_id     bigint      PRIMARY KEY,
  captured_at  timestamptz NOT NULL,
  groups       integer     NOT NULL,
  updated_at   timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE public.listing_overlap_evo_poll IS
  'The EVO capture listing_overlap_evo_live describes, per event. The matcher treats the live set as exact only when captured_at equals the capture it is matching (mig 20261124120000).';

ALTER TABLE public.listing_overlap_config   ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.listing_overlap_label    ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.listing_overlap_event    ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.listing_overlap_evo_live ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.listing_overlap_evo_poll ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.listing_overlap_config, public.listing_overlap_label, public.listing_overlap_event,
              public.listing_overlap_evo_live, public.listing_overlap_evo_poll FROM anon, authenticated;
GRANT ALL ON public.listing_overlap_config, public.listing_overlap_label, public.listing_overlap_event,
             public.listing_overlap_evo_live, public.listing_overlap_evo_poll TO service_role;

-- ---------------------------------------------------------------------------
-- Keys
-- ---------------------------------------------------------------------------

-- The two key functions are single expressions with no SET clause on purpose: the planner
-- inlines them, and they run once per listing per match (as SQL functions with a body of
-- their own they cost ~70 us a call, 20x the expression).
CREATE OR REPLACE FUNCTION public.listing_overlap_section_key(p_section text)
RETURNS text
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
AS $function$
  SELECT nullif(
           regexp_replace(
             regexp_replace(
               regexp_replace(public.seat_section_norm(p_section), '^[A-Z]+([0-9]{3,}[A-Z]{0,2})$', '\1'),
               '[^A-Z0-9]', '', 'g'),
             '^GENERALADMISSION$', 'GA'),
           '');
$function$;
COMMENT ON FUNCTION public.listing_overlap_section_key(text) IS
  'Section key the EVO / GoTickets overlap matcher joins on: seat_section_norm(), a glued letter prefix dropped when 3+ digits follow (C129 -> 129, VIP111 -> 111, SECTION108D -> 108D), then letters and digits only (FLOOR E -> FLOORE). NULL for a blank section.';

CREATE OR REPLACE FUNCTION public.listing_overlap_row_key(p_row text)
RETURNS text
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
AS $function$
  SELECT regexp_replace(
           regexp_replace(upper(coalesce(p_row, '')), '^\s*(ROW\s*)?|\s+', '', 'g'),
           '^0+(?=.)', '');
$function$;
COMMENT ON FUNCTION public.listing_overlap_row_key(text) IS
  'Row key the EVO / GoTickets overlap matcher joins on: upper case, a leading "ROW" and leading zeros dropped, no spaces. A blank row is the empty string, so two listings without a row compare equal.';

CREATE OR REPLACE FUNCTION public.listing_overlap_pair(p_evo numeric[], p_gt numeric[], p_center numeric, p_band numeric)
RETURNS TABLE (evo_idx integer, gt_idx integer)
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  i integer := 1;
  j integer := 1;
  n integer := coalesce(cardinality(p_evo), 0);
  m integer := coalesce(cardinality(p_gt), 0);
  d numeric;
BEGIN
  -- Both arrays ascending. Walk them together: a pair inside the band is taken, otherwise
  -- the cheaper side (after the centre shift) moves on. For points on a line with one
  -- tolerance this takes as many pairs as any assignment can.
  WHILE i <= n AND j <= m LOOP
    d := ln(p_gt[j] / (p_evo[i] * p_center));
    IF abs(d) <= p_band THEN
      evo_idx := i; gt_idx := j;
      RETURN NEXT;
      i := i + 1; j := j + 1;
    ELSIF d < 0 THEN
      j := j + 1;
    ELSE
      i := i + 1;
    END IF;
  END LOOP;
END
$function$;
COMMENT ON FUNCTION public.listing_overlap_pair(numeric[], numeric[], numeric, numeric) IS
  'Pairs two ascending price lists (EVO retail, GoTickets all-in) of one section/row/quantity spot: positions i, j pair when |ln(gt / (evo x centre))| <= band. Returns the positions.';

-- ---------------------------------------------------------------------------
-- EVO: the live id set, written by the collect-listings edge function
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.listing_overlap_evo_seen(p_event_id bigint, p_captured_at timestamptz, p_ids bigint[])
RETURNS integer
LANGUAGE plpgsql
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_ids bigint[] := coalesce(p_ids, '{}'::bigint[]);
  v_have timestamptz;
BEGIN
  IF p_event_id IS NULL OR p_captured_at IS NULL THEN
    RAISE EXCEPTION 'listing_overlap_evo_seen: event and capture time are required' USING ERRCODE = '22023';
  END IF;
  -- Two responses for one event can finish out of order; the older one must not win.
  SELECT captured_at INTO v_have FROM public.listing_overlap_evo_poll WHERE event_id = p_event_id FOR UPDATE;
  IF v_have IS NOT NULL AND v_have >= p_captured_at THEN
    RETURN 0;
  END IF;

  DELETE FROM public.listing_overlap_evo_live v
   WHERE v.event_id = p_event_id
     AND NOT EXISTS (SELECT 1 FROM unnest(v_ids) AS u(id) WHERE u.id = v.tevo_ticket_group_id);
  INSERT INTO public.listing_overlap_evo_live (event_id, tevo_ticket_group_id, first_seen_at)
  SELECT p_event_id, u.id, p_captured_at FROM (SELECT DISTINCT unnest(v_ids) AS id) u WHERE u.id IS NOT NULL
  ON CONFLICT (event_id, tevo_ticket_group_id) DO NOTHING;

  INSERT INTO public.listing_overlap_evo_poll (event_id, captured_at, groups, updated_at)
  VALUES (p_event_id, p_captured_at, cardinality(v_ids), now())
  ON CONFLICT (event_id) DO UPDATE SET captured_at = excluded.captured_at, groups = excluded.groups, updated_at = now();
  RETURN cardinality(v_ids);
END
$function$;
COMMENT ON FUNCTION public.listing_overlap_evo_seen(bigint, timestamptz, bigint[]) IS
  'Called by the collect-listings edge function with every ticket group id of one EVO response. Keeps listing_overlap_evo_live equal to that response (inserts arrivals, deletes departures) and records the capture in listing_overlap_evo_poll. A response older than the one already recorded is ignored. Returns the number of ids taken.';

-- ---------------------------------------------------------------------------
-- The two books
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.listing_overlap_evo_book(p_event_id bigint, p_cap timestamptz, p_exact boolean)
RETURNS TABLE (listing_id bigint, section text, row_name text, quantity integer, price numeric, is_owned boolean, seen_at timestamptz)
LANGUAGE sql
STABLE
SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT d.tevo_ticket_group_id, d.section, d.row, d.quantity, d.retail_price, coalesce(d.is_owned, false), d.captured_at
    FROM (SELECT DISTINCT ON (l.tevo_ticket_group_id)
                 l.tevo_ticket_group_id, l.section, l.row, l.quantity, l.retail_price, l.is_owned, l.is_ancillary, l.captured_at
            FROM public.listings_snapshots l
           WHERE l.event_id = p_event_id
             AND l.captured_at > p_cap - interval '61 minutes' AND l.captured_at <= p_cap
           ORDER BY l.tevo_ticket_group_id, l.captured_at DESC) d
   WHERE NOT coalesce(d.is_ancillary, false) AND d.quantity > 0 AND d.retail_price > 0
     AND (NOT coalesce(p_exact, false)
          OR EXISTS (SELECT 1 FROM public.listing_overlap_evo_live v
                      WHERE v.event_id = p_event_id AND v.tevo_ticket_group_id = d.tevo_ticket_group_id));
$function$;
COMMENT ON FUNCTION public.listing_overlap_evo_book(bigint, timestamptz, boolean) IS
  'The EVO book of an event as of capture p_cap: each ticket group''s latest row in the 61 minutes up to it (collect-listings rewrites an unchanged group once its last row is an hour old), seats only. p_exact = keep only groups in listing_overlap_evo_live, i.e. in the response itself; otherwise a group that left inside the hour is still returned.';

CREATE OR REPLACE FUNCTION public.listing_overlap_gt_sources(p_event_id bigint)
RETURNS TABLE (gt_event_id bigint, cap timestamptz, is_empty boolean)
LANGUAGE sql
STABLE
SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT ge.gt_event_id,
         CASE WHEN coalesce(ps.consecutive_empty, 0) > 0 THEN ps.last_polled_listings_at
              ELSE (SELECT max(s.captured_at) FROM public.gotickets_listings_snapshots s
                     WHERE s.gt_event_id = ge.gt_event_id AND s.captured_at > now() - interval '3 days') END,
         coalesce(ps.consecutive_empty, 0) > 0
    FROM public.gotickets_event ge
    LEFT JOIN public.gt_listings_poll_state ps ON ps.gt_event_id = ge.gt_event_id
   WHERE ge.tevo_event_id = p_event_id AND ge.status = 'AS_SCHEDULED' AND coalesce(ge.name, '') !~* 'parking';
$function$;
COMMENT ON FUNCTION public.listing_overlap_gt_sources(bigint) IS
  'The GoTickets events mapped to a TEvo event (scheduled, not parking), each with its latest listings capture. is_empty = the last poll that answered returned no listings: the book is empty as of that poll, whatever older captures hold.';

CREATE OR REPLACE FUNCTION public.listing_overlap_gt_cap(p_event_id bigint)
RETURNS timestamptz
LANGUAGE sql
STABLE
SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT max(s.cap) FROM public.listing_overlap_gt_sources(p_event_id) s;
$function$;

CREATE OR REPLACE FUNCTION public.listing_overlap_gt_book(p_event_id bigint)
RETURNS TABLE (listing_id bigint, gt_event_id bigint, section text, section_id bigint, row_name text, quantity integer, price numeric, seen_at timestamptz)
LANGUAGE sql
STABLE
SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT DISTINCT ON (g.gt_listing_id)
         g.gt_listing_id, g.gt_event_id, g.section, g.section_id, g.row, g.quantity, g.all_in_price, g.captured_at
    FROM public.listing_overlap_gt_sources(p_event_id) s
    JOIN public.gotickets_listings_snapshots g ON g.gt_event_id = s.gt_event_id AND g.captured_at = s.cap
   WHERE NOT s.is_empty AND s.cap IS NOT NULL AND g.quantity > 0 AND g.all_in_price > 0
   ORDER BY g.gt_listing_id, g.captured_at DESC;
$function$;
COMMENT ON FUNCTION public.listing_overlap_gt_book(bigint) IS
  'The GoTickets book of a TEvo event: every listing of the latest capture of each mapped GoTickets event (each capture holds the whole book). Price = all_in_price.';

-- ---------------------------------------------------------------------------
-- The match: reads both books, returns one label per listing. Writes nothing.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.listing_overlap_compute(
  p_event_id bigint, p_evo_cap timestamptz, p_evo_exact boolean, p_center numeric, p_band numeric)
RETURNS TABLE (source text, listing_id bigint, label text, reason text, counterpart_id bigint, price_ratio numeric)
LANGUAGE sql
STABLE
SET search_path TO 'public', 'pg_temp'
AS $function$
  WITH e AS MATERIALIZED (
    SELECT b.listing_id, public.listing_overlap_section_key(b.section) AS sk,
           public.listing_overlap_row_key(b.row_name) AS rk, b.quantity AS q, b.price
      FROM public.listing_overlap_evo_book(p_event_id, p_evo_cap, p_evo_exact) b),
  g AS MATERIALIZED (
    SELECT b.listing_id, public.listing_overlap_section_key(b.section) AS sk,
           public.listing_overlap_row_key(b.row_name) AS rk, b.quantity AS q, b.price
      FROM public.listing_overlap_gt_book(p_event_id) b),
  ek AS (SELECT e.sk, e.rk, e.q, array_agg(e.listing_id ORDER BY e.price, e.listing_id) AS ids,
                array_agg(e.price ORDER BY e.price, e.listing_id) AS prices
           FROM e WHERE e.sk IS NOT NULL GROUP BY e.sk, e.rk, e.q),
  gk AS (SELECT g.sk, g.rk, g.q, array_agg(g.listing_id ORDER BY g.price, g.listing_id) AS ids,
                array_agg(g.price ORDER BY g.price, g.listing_id) AS prices
           FROM g WHERE g.sk IS NOT NULL GROUP BY g.sk, g.rk, g.q),
  p AS MATERIALIZED (
    SELECT ek.ids[x.evo_idx] AS evo_id, gk.ids[x.gt_idx] AS gt_id,
           round(gk.prices[x.gt_idx] / ek.prices[x.evo_idx], 3) AS ratio
      FROM ek
      JOIN gk ON gk.sk = ek.sk AND gk.rk = ek.rk AND gk.q = ek.q
      CROSS JOIN LATERAL public.listing_overlap_pair(ek.prices, gk.prices, p_center, p_band) x),
  eu AS (SELECT e.* FROM e WHERE NOT EXISTS (SELECT 1 FROM p WHERE p.evo_id = e.listing_id)),
  gu AS (SELECT g.* FROM g WHERE NOT EXISTS (SELECT 1 FROM p WHERE p.gt_id = g.listing_id)),
  e_free AS (SELECT DISTINCT eu.sk, eu.rk, eu.q FROM eu WHERE eu.sk IS NOT NULL),
  e_spot AS (SELECT DISTINCT e.sk, e.rk, e.q FROM e WHERE e.sk IS NOT NULL),
  e_row  AS (SELECT DISTINCT e.sk, e.rk FROM e WHERE e.sk IS NOT NULL),
  e_sec  AS (SELECT DISTINCT e.sk FROM e WHERE e.sk IS NOT NULL),
  g_free AS (SELECT DISTINCT gu.sk, gu.rk, gu.q FROM gu WHERE gu.sk IS NOT NULL),
  g_spot AS (SELECT DISTINCT g.sk, g.rk, g.q FROM g WHERE g.sk IS NOT NULL),
  g_row  AS (SELECT DISTINCT g.sk, g.rk FROM g WHERE g.sk IS NOT NULL),
  g_sec  AS (SELECT DISTINCT g.sk FROM g WHERE g.sk IS NOT NULL)
  SELECT 'evo', p.evo_id, 'both', 'paired', p.gt_id, p.ratio FROM p
  UNION ALL
  SELECT 'gt', p.gt_id, 'both', 'paired', p.evo_id, p.ratio FROM p
  UNION ALL
  SELECT 'evo', eu.listing_id,
         CASE WHEN f.sk IS NOT NULL THEN 'unclear' ELSE 'evo_only' END,
         CASE WHEN f.sk IS NOT NULL THEN 'price_gap'
              WHEN s.sk IS NOT NULL THEN 'extra_copy'
              WHEN r.sk IS NOT NULL THEN 'qty_differs'
              WHEN c.sk IS NOT NULL THEN 'row_absent'
              ELSE 'section_absent' END,
         NULL::bigint, NULL::numeric
    FROM eu
    LEFT JOIN g_free f ON f.sk = eu.sk AND f.rk = eu.rk AND f.q = eu.q
    LEFT JOIN g_spot s ON s.sk = eu.sk AND s.rk = eu.rk AND s.q = eu.q
    LEFT JOIN g_row  r ON r.sk = eu.sk AND r.rk = eu.rk
    LEFT JOIN g_sec  c ON c.sk = eu.sk
  UNION ALL
  SELECT 'gt', gu.listing_id,
         CASE WHEN f.sk IS NOT NULL THEN 'unclear' ELSE 'gt_only' END,
         CASE WHEN f.sk IS NOT NULL THEN 'price_gap'
              WHEN s.sk IS NOT NULL THEN 'extra_copy'
              WHEN r.sk IS NOT NULL THEN 'qty_differs'
              WHEN c.sk IS NOT NULL THEN 'row_absent'
              ELSE 'section_absent' END,
         NULL::bigint, NULL::numeric
    FROM gu
    LEFT JOIN e_free f ON f.sk = gu.sk AND f.rk = gu.rk AND f.q = gu.q
    LEFT JOIN e_spot s ON s.sk = gu.sk AND s.rk = gu.rk AND s.q = gu.q
    LEFT JOIN e_row  r ON r.sk = gu.sk AND r.rk = gu.rk
    LEFT JOIN e_sec  c ON c.sk = gu.sk;
$function$;
COMMENT ON FUNCTION public.listing_overlap_compute(bigint, timestamptz, boolean, numeric, numeric) IS
  'One label per listing in the EVO book (as of p_evo_cap) and the GoTickets book of an event: both / evo_only / gt_only / unclear, the reason, and for a pair the other listing and the GoTickets / EVO price ratio. Reads only.';

-- ---------------------------------------------------------------------------
-- Match one event and store the result
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.listing_overlap_match_event(p_event_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_start    timestamptz := clock_timestamp();
  v_cfg      public.listing_overlap_config%ROWTYPE;
  v_evo_cap  timestamptz;
  v_gt_cap   timestamptz;
  v_hours    numeric;
  v_evo_min  integer;
  v_gt_min   integer;
  v_exact    boolean;
  v_status   text := 'ok';
  v_evo integer; v_gt integer; v_both integer; v_eonly integer; v_gonly integer; v_eunc integer; v_gunc integer;
  v_del integer := 0; v_ups integer := 0;
BEGIN
  SELECT * INTO v_cfg FROM public.listing_overlap_config;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'listing_overlap_config has no row';
  END IF;

  SELECT max(m.captured_at) INTO v_evo_cap
    FROM public.event_metrics m
   WHERE m.event_id = p_event_id AND m.captured_at > now() - interval '3 days';
  v_gt_cap := public.listing_overlap_gt_cap(p_event_id);
  IF v_evo_cap IS NULL OR v_gt_cap IS NULL THEN
    RETURN jsonb_build_object('event_id', p_event_id, 'status', 'no_book',
                              'evo_cap', v_evo_cap, 'gt_cap', v_gt_cap);
  END IF;

  -- A book is current while it is younger than three of its own poll intervals (+15 min).
  SELECT greatest(extract(epoch FROM e.occurs_at_local::timestamptz - now()) / 3600.0, 0)
    INTO v_hours
    FROM public.events e
   WHERE e.id = p_event_id AND e.occurs_at_local ~ '^\d{4}-\d\d-\d\dT';
  SELECT c.required_min INTO v_evo_min FROM public.collector_band('EVO', 'listings', coalesce(v_hours, 0)) c;
  SELECT c.required_min INTO v_gt_min  FROM public.collector_band('GT',  'listings', coalesce(v_hours, 0)) c;
  IF now() - v_evo_cap > make_interval(mins => 3 * coalesce(v_evo_min, 1440) + 15) THEN
    v_status := 'stale_evo';
  ELSIF now() - v_gt_cap > make_interval(mins => 3 * coalesce(v_gt_min, 2880) + 15) THEN
    v_status := 'stale_gt';
  END IF;

  IF v_status <> 'ok' THEN
    DELETE FROM public.listing_overlap_label WHERE tevo_event_id = p_event_id;
    GET DIAGNOSTICS v_del = ROW_COUNT;
    INSERT INTO public.listing_overlap_event AS st
      (tevo_event_id, status, evo_cap, gt_cap, evo_exact, matched_at, duration_ms)
    VALUES (p_event_id, v_status, v_evo_cap, v_gt_cap, false, now(),
            (extract(epoch FROM clock_timestamp() - v_start) * 1000)::integer)
    ON CONFLICT (tevo_event_id) DO UPDATE SET
      status = excluded.status, evo_cap = excluded.evo_cap, gt_cap = excluded.gt_cap, evo_exact = false,
      evo_listings = NULL, gt_listings = NULL, both_pairs = NULL, evo_only = NULL, gt_only = NULL,
      evo_unclear = NULL, gt_unclear = NULL,
      matched_at = now(), duration_ms = excluded.duration_ms, updated_at = now();
    RETURN jsonb_build_object('event_id', p_event_id, 'status', v_status, 'evo_cap', v_evo_cap,
                              'gt_cap', v_gt_cap, 'labels_removed', v_del);
  END IF;

  v_exact := EXISTS (SELECT 1 FROM public.listing_overlap_evo_poll ep
                      WHERE ep.event_id = p_event_id AND ep.captured_at = v_evo_cap);

  WITH n AS MATERIALIZED (
    SELECT * FROM public.listing_overlap_compute(p_event_id, v_evo_cap, v_exact, v_cfg.price_center, v_cfg.price_band)),
  del AS (
    DELETE FROM public.listing_overlap_label l
     WHERE l.tevo_event_id = p_event_id
       AND NOT EXISTS (SELECT 1 FROM n WHERE n.source = l.source AND n.listing_id = l.listing_id)
    RETURNING 1),
  ups AS (
    INSERT INTO public.listing_overlap_label AS l
      (tevo_event_id, source, listing_id, label, reason, counterpart_id, price_ratio)
    SELECT p_event_id, n.source, n.listing_id, n.label, n.reason, n.counterpart_id, n.price_ratio FROM n
    ON CONFLICT (tevo_event_id, source, listing_id) DO UPDATE SET
      label = excluded.label, reason = excluded.reason, counterpart_id = excluded.counterpart_id,
      price_ratio = excluded.price_ratio,
      label_since = CASE WHEN l.label IS DISTINCT FROM excluded.label THEN now() ELSE l.label_since END,
      updated_at = now()
    WHERE (l.label, l.reason, l.counterpart_id) IS DISTINCT FROM (excluded.label, excluded.reason, excluded.counterpart_id)
       OR abs(coalesce(l.price_ratio, 0) - coalesce(excluded.price_ratio, 0)) >= 0.02
    RETURNING 1)
  SELECT count(*) FILTER (WHERE n.source = 'evo'), count(*) FILTER (WHERE n.source = 'gt'),
         count(*) FILTER (WHERE n.source = 'evo' AND n.label = 'both'),
         count(*) FILTER (WHERE n.label = 'evo_only'), count(*) FILTER (WHERE n.label = 'gt_only'),
         count(*) FILTER (WHERE n.source = 'evo' AND n.label = 'unclear'),
         count(*) FILTER (WHERE n.source = 'gt' AND n.label = 'unclear'),
         (SELECT count(*) FROM del), (SELECT count(*) FROM ups)
    INTO v_evo, v_gt, v_both, v_eonly, v_gonly, v_eunc, v_gunc, v_del, v_ups
    FROM n;

  INSERT INTO public.listing_overlap_event AS st
    (tevo_event_id, status, evo_cap, gt_cap, evo_exact, evo_listings, gt_listings, both_pairs,
     evo_only, gt_only, evo_unclear, gt_unclear, matched_at, duration_ms)
  VALUES (p_event_id, 'ok', v_evo_cap, v_gt_cap, v_exact, v_evo, v_gt, v_both, v_eonly, v_gonly, v_eunc, v_gunc,
          now(), (extract(epoch FROM clock_timestamp() - v_start) * 1000)::integer)
  ON CONFLICT (tevo_event_id) DO UPDATE SET
    status = 'ok', evo_cap = excluded.evo_cap, gt_cap = excluded.gt_cap, evo_exact = excluded.evo_exact,
    evo_listings = excluded.evo_listings, gt_listings = excluded.gt_listings, both_pairs = excluded.both_pairs,
    evo_only = excluded.evo_only, gt_only = excluded.gt_only,
    evo_unclear = excluded.evo_unclear, gt_unclear = excluded.gt_unclear,
    matched_at = now(), duration_ms = excluded.duration_ms, updated_at = now();

  RETURN jsonb_build_object(
    'event_id', p_event_id, 'status', 'ok', 'evo_cap', v_evo_cap, 'gt_cap', v_gt_cap, 'evo_exact', v_exact,
    'evo_listings', v_evo, 'gt_listings', v_gt, 'both_pairs', v_both, 'evo_only', v_eonly, 'gt_only', v_gonly,
    'evo_unclear', v_eunc, 'gt_unclear', v_gunc, 'labels_written', v_ups, 'labels_removed', v_del);
END
$function$;
COMMENT ON FUNCTION public.listing_overlap_match_event(bigint) IS
  'Matches the current EVO and GoTickets books of one event and stores the result: listing_overlap_label is brought in line (changed labels rewritten, departed listings removed) and listing_overlap_event gets the counts and the two captures matched. A book older than three poll intervals + 15 min is not matched against: status stale_evo / stale_gt, labels removed. Returns what it did.';

-- ---------------------------------------------------------------------------
-- The tick: match every event whose poll has landed since its last match
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.listing_overlap_tick(p_max integer DEFAULT NULL, p_budget_seconds integer DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_start   timestamptz := clock_timestamp();
  v_cfg     public.listing_overlap_config%ROWTYPE;
  v_max     integer;
  v_budget  integer;
  r         record;
  v_done    integer := 0;
  v_err     integer := 0;
  v_stale   integer := 0;
  v_out     boolean := false;
BEGIN
  SELECT * INTO v_cfg FROM public.listing_overlap_config;
  IF NOT FOUND OR NOT v_cfg.enabled THEN
    RETURN jsonb_build_object('enabled', false);
  END IF;
  v_max    := coalesce(p_max, v_cfg.tick_max_events);
  v_budget := coalesce(p_budget_seconds, v_cfg.tick_budget_seconds);

  FOR r IN
    WITH due AS (
      -- a poll fired after the capture last matched (cheap: the two poll clocks)
      SELECT ps.event_id AS eid
        FROM public.evo_listings_poll_state ps
        LEFT JOIN public.listing_overlap_event st ON st.tevo_event_id = ps.event_id
       WHERE ps.last_polled_listings_at > now() - interval '60 minutes'
         AND (st.evo_cap IS NULL OR ps.last_polled_listings_at > st.evo_cap)
      UNION
      SELECT ge.tevo_event_id
        FROM public.gt_listings_poll_state ps
        JOIN public.gotickets_event ge ON ge.gt_event_id = ps.gt_event_id
        LEFT JOIN public.listing_overlap_event st ON st.tevo_event_id = ge.tevo_event_id
       WHERE ps.last_polled_listings_at > now() - interval '60 minutes'
         AND ge.tevo_event_id IS NOT NULL
         AND (st.gt_cap IS NULL OR ps.last_polled_listings_at > st.gt_cap)),
    -- An EVO-polled game with no GoTickets event stays in "due" for the hour after each poll
    -- and never gets a row; it is dropped here on one small index probe, before the firehoses.
    gt AS MATERIALIZED (
      SELECT d.eid, public.listing_overlap_gt_cap(d.eid) AS cap
        FROM due d
       WHERE EXISTS (SELECT 1 FROM public.gotickets_event ge
                      WHERE ge.tevo_event_id = d.eid AND ge.status = 'AS_SCHEDULED'))
    SELECT g.eid
      FROM gt g
      LEFT JOIN public.listing_overlap_event st ON st.tevo_event_id = g.eid
      CROSS JOIN LATERAL (SELECT max(m.captured_at) AS cap FROM public.event_metrics m
                           WHERE m.event_id = g.eid AND m.captured_at > now() - interval '3 days') ec
     WHERE g.cap IS NOT NULL AND ec.cap IS NOT NULL
       -- … and that poll has landed: a capture differs from the one matched
       AND (st.tevo_event_id IS NULL OR ec.cap IS DISTINCT FROM st.evo_cap OR g.cap IS DISTINCT FROM st.gt_cap)
     ORDER BY st.matched_at NULLS FIRST, g.eid
     LIMIT v_max
  LOOP
    IF clock_timestamp() - v_start > make_interval(secs => v_budget) THEN
      v_out := true;
      EXIT;
    END IF;
    BEGIN
      PERFORM public.listing_overlap_match_event(r.eid);
      v_done := v_done + 1;
    EXCEPTION WHEN OTHERS THEN
      v_err := v_err + 1;
      RAISE WARNING 'listing_overlap_tick: event % failed: %', r.eid, SQLERRM;
    END;
  END LOOP;

  -- Labels nobody has refreshed for 50 hours (both polls stopped: the game is over, or the
  -- event left the pins) describe a book that no longer exists. Bounded per tick.
  IF NOT v_out THEN
    FOR r IN
      SELECT st.tevo_event_id
        FROM public.listing_overlap_event st
       WHERE st.status = 'ok' AND st.matched_at < now() - interval '50 hours'
       ORDER BY st.matched_at
       LIMIT 50
    LOOP
      EXIT WHEN clock_timestamp() - v_start > make_interval(secs => v_budget);
      DELETE FROM public.listing_overlap_label WHERE tevo_event_id = r.tevo_event_id;
      UPDATE public.listing_overlap_event
         SET status = CASE WHEN evo_cap <= gt_cap THEN 'stale_evo' ELSE 'stale_gt' END,
             evo_listings = NULL, gt_listings = NULL, both_pairs = NULL, evo_only = NULL, gt_only = NULL,
             evo_unclear = NULL, gt_unclear = NULL, updated_at = now()
       WHERE tevo_event_id = r.tevo_event_id;
      v_stale := v_stale + 1;
    END LOOP;
    DELETE FROM public.listing_overlap_event WHERE matched_at < now() - interval '30 days';
  END IF;

  RETURN jsonb_build_object('enabled', true, 'matched', v_done, 'errors', v_err, 'expired', v_stale,
                            'out_of_time', v_out,
                            'ms', (extract(epoch FROM clock_timestamp() - v_start) * 1000)::integer);
END
$function$;
COMMENT ON FUNCTION public.listing_overlap_tick(integer, integer) IS
  'Scan-on-arrival for the EVO / GoTickets overlap labels: matches every event with an EVO or GoTickets listings capture newer than the one last matched (least recently matched first, at most p_max events, inside p_budget_seconds; both default to listing_overlap_config), then expires labels untouched for 50 hours. Does nothing when listing_overlap_config.enabled is false. Cron listing_overlap_tick_30s.';

-- ---------------------------------------------------------------------------
-- Reading the result
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.listing_overlap_event_listings(p_event_id bigint)
RETURNS TABLE (source text, listing_id bigint, section text, row_name text, quantity integer, price numeric,
               is_owned boolean, label text, reason text, counterpart_id bigint, price_ratio numeric,
               label_since timestamptz, seen_at timestamptz)
LANGUAGE sql
STABLE
SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT 'evo', b.listing_id, b.section, b.row_name, b.quantity, b.price, b.is_owned,
         l.label, l.reason, l.counterpart_id, l.price_ratio, l.label_since, b.seen_at
    FROM public.listing_overlap_event st
    CROSS JOIN LATERAL public.listing_overlap_evo_book(st.tevo_event_id, st.evo_cap, st.evo_exact) b
    LEFT JOIN public.listing_overlap_label l
           ON l.tevo_event_id = st.tevo_event_id AND l.source = 'evo' AND l.listing_id = b.listing_id
   WHERE st.tevo_event_id = p_event_id AND st.status = 'ok'
  UNION ALL
  SELECT 'gt', b.listing_id, b.section, b.row_name, b.quantity, b.price, NULL::boolean,
         l.label, l.reason, l.counterpart_id, l.price_ratio, l.label_since, b.seen_at
    FROM public.listing_overlap_event st
    CROSS JOIN LATERAL public.listing_overlap_gt_book(st.tevo_event_id) b
    LEFT JOIN public.listing_overlap_label l
           ON l.tevo_event_id = st.tevo_event_id AND l.source = 'gt' AND l.listing_id = b.listing_id
   WHERE st.tevo_event_id = p_event_id AND st.status = 'ok';
$function$;
COMMENT ON FUNCTION public.listing_overlap_event_listings(bigint) IS
  'Both books of an event with each listing''s overlap label: source evo (listing_id = tevo_ticket_group_id, price = retail) and gt (listing_id = gt_listing_id, price = all-in). No rows while the event is stale or was never matched. A listing that arrived after the last match has a NULL label until the next tick.';

CREATE OR REPLACE VIEW public.v_listing_overlap_event
WITH (security_invoker = true) AS
SELECT st.tevo_event_id, e.name, e.venue_name, e.occurs_at_local, st.status, st.evo_exact,
       st.evo_listings, st.gt_listings, st.both_pairs, st.evo_only, st.gt_only, st.evo_unclear, st.gt_unclear,
       round(100.0 * st.both_pairs / nullif(st.gt_listings, 0), 1)  AS gt_pct_on_evo,
       round(100.0 * st.both_pairs / nullif(st.evo_listings, 0), 1) AS evo_pct_on_gt,
       st.evo_cap, st.gt_cap, st.matched_at, st.duration_ms
  FROM public.listing_overlap_event st
  LEFT JOIN public.events e ON e.id = st.tevo_event_id;
COMMENT ON VIEW public.v_listing_overlap_event IS
  'One row per event the EVO / GoTickets overlap matcher has seen: listings per market, pairs on both, one-market and unclear counts, share of each book that is on the other market, the captures matched and the status (mig 20261124120000).';
REVOKE ALL ON public.v_listing_overlap_event FROM anon, authenticated;

-- ---------------------------------------------------------------------------
-- Who may run it
-- ---------------------------------------------------------------------------

REVOKE EXECUTE ON FUNCTION
  public.listing_overlap_evo_seen(bigint, timestamptz, bigint[]),
  public.listing_overlap_evo_book(bigint, timestamptz, boolean),
  public.listing_overlap_gt_sources(bigint),
  public.listing_overlap_gt_cap(bigint),
  public.listing_overlap_gt_book(bigint),
  public.listing_overlap_compute(bigint, timestamptz, boolean, numeric, numeric),
  public.listing_overlap_match_event(bigint),
  public.listing_overlap_tick(integer, integer),
  public.listing_overlap_event_listings(bigint)
FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION
  public.listing_overlap_evo_seen(bigint, timestamptz, bigint[]),
  public.listing_overlap_evo_book(bigint, timestamptz, boolean),
  public.listing_overlap_gt_sources(bigint),
  public.listing_overlap_gt_cap(bigint),
  public.listing_overlap_gt_book(bigint),
  public.listing_overlap_compute(bigint, timestamptz, boolean, numeric, numeric),
  public.listing_overlap_match_event(bigint),
  public.listing_overlap_tick(integer, integer),
  public.listing_overlap_event_listings(bigint)
TO service_role;

-- ---------------------------------------------------------------------------
-- Schedule: every 30 seconds, one runner at a time (why 30: see the header). Steady state is
-- one index probe per event polled in the last hour plus one match per landed poll (about
-- 65 a minute at the 2026-10-23 pin load, ~20 ms each). The statement timeout is the outer
-- bound; the loop's own 20 s budget is what normally ends a tick.
-- ---------------------------------------------------------------------------

DO $schedule$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = 'cron') THEN
    PERFORM cron.schedule(
      'listing_overlap_tick_30s', '30 seconds',
      $cron$SET statement_timeout = '50s'; DO $b$ BEGIN IF NOT public.cron_try_lock('listing_overlap_tick') THEN RETURN; END IF; PERFORM public.listing_overlap_tick(); END $b$;$cron$);
  END IF;
END
$schedule$;

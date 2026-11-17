-- Migration 20260916200000 · level:data-collection · lane:A1 · writes:s4kcs_orders (vivid_event_id, sh_event_id, sg_event_id, tm_event_id, tp_event_id, paciolan_event_id, market_ids_via, market_ids_at), s4kcs_link_marketplaces() fn · reads:aq_event_map, tickets_dev_source_id, seatgeek_event_xref · pre:20260916180000
--
-- ============================================================================================
-- ONE MIGRATION PER MARKETPLACE IS THE ACTUAL BUG
-- ============================================================================================
-- 20260916160000 added a GoTickets column. 20260916180000 added a tickets.dev column. Both were
-- right and the pattern is wrong: every new marketplace meant another migration, another linker,
-- another set of consumers rewritten to chain through TEvo. This adds the REST OF THEM AT ONCE --
-- Vivid, StubHub, SeatGeek, Ticketmaster, TickPick, Paciolan -- so the next marketplace is a
-- column and a route, not a project.
--
-- Operator 2026-09-16: "Add columns to every marketplace so we don't have to keep building ...
-- if we use tickets.dev as the primary mapper then map to Evo and add all marketplace columns
-- we can skip a ton of steps."
--
-- ============================================================================================
-- THE tickets.dev-AS-PRIMARY-MAPPER IDEA IS WRONG, AND HERE IS THE MEASUREMENT THAT SAYS SO
-- ============================================================================================
-- It is a reasonable hypothesis -- tickets.dev IS a cross-marketplace identity, which is exactly
-- what a primary spine should be. It loses on coverage, and not narrowly. Future non-parking CRM
-- orders reachable per marketplace, by route (of 27,713):
--
--   route                          vivid   stubhub  seatgeek  ticketmaster  tickpick  gotickets
--   A  aq_event_map via aq_short   20,168   18,507    17,810       12,383          0     20,374
--   B  aq_event_map via TEVO       26,673   25,935    26,265       19,020          0     26,753
--   C  tickets.dev cluster         19,884   15,491         0       15,566          0     20,058
--   D  direct xref (SG / GT)            0        0    22,801            0          0     18,719
--
-- ROUTE B WINS EVERY COLUMN, and on SeatGeek tickets.dev scores a FLAT ZERO -- the catalogue does
-- not index SeatGeek at all (501 source_not_indexed, non-retryable, mig 20260914211000). Making
-- tickets.dev primary would trade a 26,265-order SeatGeek route for nothing.
--
-- The other half of the idea -- "map tickets.dev to EVO" -- was measured too, and recovers ZERO.
-- Of 243 future orders with no TEvo id, 20 have a cluster, and not one of those clusters has a
-- sibling marketplace id that resolves to a TEvo event. GoTickets supplies a TEvo id for exactly
-- 1. There is no backfill here, so this migration does not touch tevo_event_id at all: that column
-- is load-bearing everywhere and a 1-row gain is not a reason to write to it.
--
-- SO TEVO STAYS THE SPINE and tickets.dev keeps the job it is actually good at: the fallback that
-- reaches orders the TEvo routes cannot. The operator's PRIMARY conclusion is what survives --
-- all the columns, filled once, so consumers stop chaining. That part is the whole win.
--
-- ============================================================================================
-- THE PURPOSE-BUILT GOTICKETS LINKER LOSES TO THE GENERIC ROUTE BY 8,159 ORDERS
-- ============================================================================================
-- This is the operator's point proving itself on the way past. 20260916160000 built a dedicated
-- GoTickets linker -- sale identity, then the TEvo spine with a single-claimant guard. It fills
-- 18,719 future orders. aq_event_map.gotickets_event_id, which nothing pointed at, fills 26,753.
--
--   agree                              18,326 orders / 1,360 events
--   aq fills what the linker could not  8,159 orders /   533 events
--   linker fills what aq cannot           350 orders /    85 events
--   DISAGREE                               43 orders /    14 events
--
-- So gt_event_id gets an aq_tevo/aq_short fill pass here, and the one-off linker keeps its place
-- at the front because IT IS RIGHT WHERE THEY CONFLICT. Of the 43 disagreements, 19 are against
-- gt_mapped_via = 'sale_identity' -- gotickets_sales.gt_sale_id = s4k_order_id, an identity with
-- nothing to tune. Where an identity and aq_event_map disagree, aq is wrong: that is 10 events of
-- genuine aq defect, surfaced here and left for A1 rather than propagated. None of the 43 sit on a
-- double-claimed TEvo event, so the double-claims are not the explanation.
--
-- Fill-only ordering is therefore not a formality, it is the correctness argument: the strong
-- route writes first, the broad route fills the holes, and the broad route can never overwrite
-- the strong one.
--
-- ============================================================================================
-- TICKETMASTER IDS ARE NOT INTEGERS AND aq_event_map CANNOT HOLD 84% OF THEM
-- ============================================================================================
-- Measured on tickets_dev_source_id: 3,390 of 4,054 ticketmaster ids are NON-NUMERIC, e.g.
-- '0000647BC2B6EC64'. aq_event_map.tm_event_id is BIGINT. That is not a style difference -- it is
-- a column that structurally cannot represent five sixths of the id space it is named for, and a
-- ::bigint cast of a real TM id does not return NULL, it RAISES. So:
--   * s4kcs_orders.tm_event_id is TEXT, deliberately, and so is paciolan_event_id
--     ('appstatesports.evenue.net:FB26:FB02' -- 43 of 43 non-numeric).
--   * every cast of a text id to bigint in this function is gated on ~ '^[0-9]+$', so a
--     marketplace that starts issuing alphanumeric ids degrades to "unfilled", never to an error.
-- The aq_event_map type itself is A1's to fix and is NOT fixed here; this migration refuses to
-- inherit the defect, which is a different thing from repairing it.
--
-- ============================================================================================
-- FILL ORDER IS THE MEASUREMENT ABOVE, AND EVERY PASS REFUSES AMBIGUITY
-- ============================================================================================
--   1. aq_tevo       aq_event_map by tevo_event_id      -- the winner on every column
--   2. aq_short      aq_event_map by aq_short_event_id  -- reaches orders with no TEvo id
--   3. tdev_cluster  tickets.dev cluster                -- vivid/stubhub/tm/paciolan fallback
--   4. sg_xref       seatgeek_event_xref by TEvo        -- SeatGeek only, +167 orders aq misses
--
-- Fill is PER COLUMN, not per row: an order can take SeatGeek from route 4 and Vivid from route 1.
-- Each column records which route filled it in market_ids_via, so "how do we know this id" is
-- answerable per cell rather than per order.
--
-- 1,371 TEvo events have MORE THAN ONE aq_event_map row, but multi-row rarely means disagreement:
-- only 54 conflict on vivid, 54 on ticketmaster, 48 on seatgeek, 45 on stubhub, 24 on gotickets.
-- Where the rows genuinely disagree the cell is left NULL and counted as refused, for the same
-- reason as the two migrations before this: a wrong id in the CRM is a reporting defect and an
-- invisible one. count(DISTINCT x) = 1 is the guard, and min(x) is then that one value.
--
-- market_ids_via IS ONE JSONB, NOT SIX *_via COLUMNS. Six marketplaces x (id, via, at) is 18
-- columns and the next marketplace makes it 21. One id column plus a shared provenance object
-- makes the next marketplace ONE column -- which is the entire thing the operator asked for.
-- gt_event_id and tdev_id keep their own *_mapped_via columns: they shipped hours ago, and
-- rewriting a just-applied surface to save two columns is churn, not tidiness.
--
-- TickPick gets a column that fills with NOTHING today -- aq_event_map.tp_event_id is populated in
-- 43 rows total and none of them are ours. It is added anyway and that is the point: the column
-- costs nothing empty, and when a TickPick route appears it is a route, not a migration.
-- ============================================================================================

ALTER TABLE public.s4kcs_orders
  ADD COLUMN IF NOT EXISTS vivid_event_id    bigint,
  ADD COLUMN IF NOT EXISTS sh_event_id       bigint,
  ADD COLUMN IF NOT EXISTS sg_event_id       bigint,
  ADD COLUMN IF NOT EXISTS tm_event_id       text,
  ADD COLUMN IF NOT EXISTS tp_event_id       bigint,
  ADD COLUMN IF NOT EXISTS paciolan_event_id text,
  ADD COLUMN IF NOT EXISTS market_ids_via    jsonb,
  ADD COLUMN IF NOT EXISTS market_ids_at     timestamptz;

CREATE INDEX IF NOT EXISTS s4kcs_orders_vivid_event_id_idx ON public.s4kcs_orders (vivid_event_id) WHERE vivid_event_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS s4kcs_orders_sh_event_id_idx    ON public.s4kcs_orders (sh_event_id)    WHERE sh_event_id    IS NOT NULL;
CREATE INDEX IF NOT EXISTS s4kcs_orders_sg_event_id_idx    ON public.s4kcs_orders (sg_event_id)    WHERE sg_event_id    IS NOT NULL;
CREATE INDEX IF NOT EXISTS s4kcs_orders_tm_event_id_idx    ON public.s4kcs_orders (tm_event_id)    WHERE tm_event_id    IS NOT NULL;
CREATE INDEX IF NOT EXISTS s4kcs_orders_tp_event_id_idx    ON public.s4kcs_orders (tp_event_id)    WHERE tp_event_id    IS NOT NULL;

COMMENT ON COLUMN public.s4kcs_orders.tm_event_id IS
  'Ticketmaster event id, TEXT because 84% of real TM ids are non-numeric (e.g. 0000647BC2B6EC64). aq_event_map.tm_event_id is bigint and therefore cannot hold most of them -- this column deliberately does not inherit that (mig 20260916200000).';

COMMENT ON COLUMN public.s4kcs_orders.paciolan_event_id IS
  'Paciolan/eVenue event key, TEXT -- they are colon-delimited paths, never integers (e.g. appstatesports.evenue.net:FB26:FB02).';

COMMENT ON COLUMN public.s4kcs_orders.market_ids_via IS
  'Per-marketplace provenance for the id columns, e.g. {"seatgeek":"sg_xref","vivid":"aq_tevo"}. aq_tevo = aq_event_map by tevo_event_id (best coverage on every marketplace). aq_short = by aq_short_event_id. tdev_cluster = tickets.dev cluster. sg_xref = seatgeek_event_xref. One object rather than six *_via columns so the next marketplace is one column, not four.';

CREATE OR REPLACE FUNCTION public.s4kcs_link_marketplaces(
  p_apply        boolean DEFAULT false,
  p_horizon_days int     DEFAULT NULL   -- NULL = future only; a number widens back that many days
)
RETURNS jsonb
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $fn$
DECLARE
  v_from     date;
  v_eligible int := 0;
  v_touched  int := 0;
  v_fill     jsonb;
  v_refused  jsonb;
  v_after    jsonb;
  v_started  timestamptz := clock_timestamp();
BEGIN
  IF current_user NOT IN ('service_role', 'postgres', 'supabase_admin') THEN
    RAISE EXCEPTION 'forbidden: %', current_user USING ERRCODE = '42501';
  END IF;
  PERFORM set_config('statement_timeout', '170000', true);

  v_from := CASE WHEN p_horizon_days IS NULL THEN current_date
                 ELSE current_date - p_horizon_days END;

  -- ROUTE 1 -- aq_event_map keyed on TEvo. count(DISTINCT) = 1 is the ambiguity guard; with one
  -- distinct value min() IS that value. NULLs are ignored by both, so an all-NULL column yields
  -- count 0 and stays NULL rather than being mistaken for agreement.
  DROP TABLE IF EXISTS _aqt;
  CREATE TEMP TABLE _aqt ON COMMIT DROP AS
  SELECT tevo_event_id,
         CASE WHEN count(DISTINCT vivid_event_id)      = 1 THEN min(vivid_event_id)      END AS vivid,
         CASE WHEN count(DISTINCT sh_event_id)         = 1 THEN min(sh_event_id)         END AS sh,
         CASE WHEN count(DISTINCT sg_event_id)         = 1 THEN min(sg_event_id)         END AS sg,
         CASE WHEN count(DISTINCT tm_event_id)         = 1 THEN min(tm_event_id)::text   END AS tm,
         CASE WHEN count(DISTINCT tp_event_id)         = 1 THEN min(tp_event_id)         END AS tp,
         CASE WHEN count(DISTINCT gotickets_event_id)  = 1 THEN min(gotickets_event_id)  END AS gt,
         (count(DISTINCT vivid_event_id) > 1) AS c_vivid,
         (count(DISTINCT sh_event_id)    > 1) AS c_sh,
         (count(DISTINCT sg_event_id)    > 1) AS c_sg,
         (count(DISTINCT tm_event_id)    > 1) AS c_tm,
         (count(DISTINCT tp_event_id)    > 1) AS c_tp,
         (count(DISTINCT gotickets_event_id) > 1) AS c_gt
    FROM public.aq_event_map WHERE tevo_event_id IS NOT NULL GROUP BY 1;
  CREATE INDEX ON _aqt (tevo_event_id);

  -- ROUTE 2 -- the same table keyed on the AQ short id, which some orders carry when TEvo is absent.
  DROP TABLE IF EXISTS _aqs;
  CREATE TEMP TABLE _aqs ON COMMIT DROP AS
  SELECT aq_short_event_id,
         CASE WHEN count(DISTINCT vivid_event_id) = 1 THEN min(vivid_event_id)    END AS vivid,
         CASE WHEN count(DISTINCT sh_event_id)    = 1 THEN min(sh_event_id)       END AS sh,
         CASE WHEN count(DISTINCT sg_event_id)    = 1 THEN min(sg_event_id)       END AS sg,
         CASE WHEN count(DISTINCT tm_event_id)    = 1 THEN min(tm_event_id)::text END AS tm,
         CASE WHEN count(DISTINCT tp_event_id)    = 1 THEN min(tp_event_id)       END AS tp,
         CASE WHEN count(DISTINCT gotickets_event_id) = 1 THEN min(gotickets_event_id) END AS gt
    FROM public.aq_event_map WHERE aq_short_event_id IS NOT NULL GROUP BY 1;
  CREATE INDEX ON _aqs (aq_short_event_id);

  -- ROUTE 3 -- the tickets.dev cluster. source_event_id is TEXT for all marketplaces, so every
  -- numeric destination is gated on a digits-only test: a marketplace that starts issuing
  -- alphanumeric ids must degrade to "unfilled", never to a cast that raises mid-run.
  DROP TABLE IF EXISTS _tdv;
  CREATE TEMP TABLE _tdv ON COMMIT DROP AS
  SELECT tdev_id,
         CASE WHEN count(DISTINCT source_event_id) FILTER (WHERE marketplace='vividseats' AND source_event_id ~ '^[0-9]+$') = 1
              THEN min(source_event_id) FILTER (WHERE marketplace='vividseats' AND source_event_id ~ '^[0-9]+$') END AS vivid,
         CASE WHEN count(DISTINCT source_event_id) FILTER (WHERE marketplace='stubhub' AND source_event_id ~ '^[0-9]+$') = 1
              THEN min(source_event_id) FILTER (WHERE marketplace='stubhub' AND source_event_id ~ '^[0-9]+$') END AS sh,
         -- ticketmaster and paciolan stay text: no gate, because nothing is cast.
         CASE WHEN count(DISTINCT source_event_id) FILTER (WHERE marketplace='ticketmaster') = 1
              THEN min(source_event_id) FILTER (WHERE marketplace='ticketmaster') END AS tm,
         CASE WHEN count(DISTINCT source_event_id) FILTER (WHERE marketplace='paciolan') = 1
              THEN min(source_event_id) FILTER (WHERE marketplace='paciolan') END AS pac
    FROM public.tickets_dev_source_id GROUP BY 1;
  CREATE INDEX ON _tdv (tdev_id);

  -- ROUTE 4 -- SeatGeek's own xref. The only route that reads a marketplace's dedicated events
  -- surface rather than the shared spine, and it finds 167 orders aq_event_map does not carry.
  DROP TABLE IF EXISTS _sgx;
  CREATE TEMP TABLE _sgx ON COMMIT DROP AS
  SELECT tevo_event_id,
         CASE WHEN count(DISTINCT sg_event_id) = 1 THEN min(sg_event_id) END AS sg
    FROM public.seatgeek_event_xref WHERE tevo_event_id IS NOT NULL GROUP BY 1;
  CREATE INDEX ON _sgx (tevo_event_id);

  DROP TABLE IF EXISTS _res;
  CREATE TEMP TABLE _res ON COMMIT DROP AS
  SELECT o.source, o.s4k_order_id,
         o.vivid_event_id AS now_vivid, o.sh_event_id AS now_sh, o.sg_event_id AS now_sg,
         o.tm_event_id    AS now_tm,    o.tp_event_id AS now_tp, o.paciolan_event_id AS now_pac,
         o.gt_event_id    AS now_gt,
         coalesce(t.vivid, s.vivid, d.vivid::bigint) AS vivid,
         CASE WHEN t.vivid IS NOT NULL THEN 'aq_tevo' WHEN s.vivid IS NOT NULL THEN 'aq_short'
              WHEN d.vivid IS NOT NULL THEN 'tdev_cluster' END AS vivid_via,
         coalesce(t.sh, s.sh, d.sh::bigint) AS sh,
         CASE WHEN t.sh IS NOT NULL THEN 'aq_tevo' WHEN s.sh IS NOT NULL THEN 'aq_short'
              WHEN d.sh IS NOT NULL THEN 'tdev_cluster' END AS sh_via,
         coalesce(t.sg, s.sg, x.sg) AS sg,
         CASE WHEN t.sg IS NOT NULL THEN 'aq_tevo' WHEN s.sg IS NOT NULL THEN 'aq_short'
              WHEN x.sg IS NOT NULL THEN 'sg_xref' END AS sg_via,
         coalesce(t.tm, s.tm, d.tm) AS tm,
         CASE WHEN t.tm IS NOT NULL THEN 'aq_tevo' WHEN s.tm IS NOT NULL THEN 'aq_short'
              WHEN d.tm IS NOT NULL THEN 'tdev_cluster' END AS tm_via,
         coalesce(t.tp, s.tp) AS tp,
         CASE WHEN t.tp IS NOT NULL THEN 'aq_tevo' WHEN s.tp IS NOT NULL THEN 'aq_short' END AS tp_via,
         d.pac AS pac,
         CASE WHEN d.pac IS NOT NULL THEN 'tdev_cluster' END AS pac_via,
         -- GoTickets is fill-only BEHIND the dedicated linker: see the header. aq is broader and,
         -- where they conflict, measurably wrong against sale identity.
         coalesce(t.gt, s.gt) AS gt,
         CASE WHEN t.gt IS NOT NULL THEN 'aq_tevo' WHEN s.gt IS NOT NULL THEN 'aq_short' END AS gt_via,
         coalesce(t.c_vivid,false) AS c_vivid, coalesce(t.c_sh,false) AS c_sh,
         coalesce(t.c_sg,false)    AS c_sg,    coalesce(t.c_tm,false) AS c_tm,
         coalesce(t.c_tp,false)    AS c_tp,   coalesce(t.c_gt,false) AS c_gt
    FROM public.s4kcs_orders o
    LEFT JOIN _aqt t ON t.tevo_event_id     = o.tevo_event_id
    LEFT JOIN _aqs s ON s.aq_short_event_id = o.aq_short_event_id
    LEFT JOIN _tdv d ON d.tdev_id           = o.tdev_id
    LEFT JOIN _sgx x ON x.tevo_event_id     = o.tevo_event_id
   WHERE o.event_date >= v_from
     AND coalesce(o.event_name, '') !~* 'parking|shuttle';

  SELECT count(*) INTO v_eligible FROM _res;

  -- Exact because every pass is fill-only: what is NULL now and resolvable IS what gets written.
  SELECT jsonb_build_object(
           'vivid',        count(*) FILTER (WHERE now_vivid IS NULL AND vivid IS NOT NULL),
           'stubhub',      count(*) FILTER (WHERE now_sh    IS NULL AND sh    IS NOT NULL),
           'seatgeek',     count(*) FILTER (WHERE now_sg    IS NULL AND sg    IS NOT NULL),
           'ticketmaster', count(*) FILTER (WHERE now_tm    IS NULL AND tm    IS NOT NULL),
           'tickpick',     count(*) FILTER (WHERE now_tp    IS NULL AND tp    IS NOT NULL),
           'paciolan',     count(*) FILTER (WHERE now_pac   IS NULL AND pac   IS NOT NULL),
           'gotickets',    count(*) FILTER (WHERE now_gt    IS NULL AND gt    IS NOT NULL)),
         jsonb_build_object(
           'vivid',        count(*) FILTER (WHERE vivid IS NULL AND c_vivid),
           'stubhub',      count(*) FILTER (WHERE sh    IS NULL AND c_sh),
           'seatgeek',     count(*) FILTER (WHERE sg    IS NULL AND c_sg),
           'ticketmaster', count(*) FILTER (WHERE tm    IS NULL AND c_tm),
           'tickpick',     count(*) FILTER (WHERE tp    IS NULL AND c_tp),
           'gotickets',    count(*) FILTER (WHERE gt    IS NULL AND c_gt))
    INTO v_fill, v_refused
    FROM _res;

  IF NOT p_apply THEN
    RETURN jsonb_build_object(
      'applied', false, 'note', 'DRY RUN -- nothing written.',
      'horizon_from', v_from::text, 'eligible_orders', v_eligible,
      'would_fill', v_fill, 'refused_conflicting_aq_rows', v_refused,
      'elapsed_ms', round(EXTRACT(epoch FROM (clock_timestamp() - v_started)) * 1000));
  END IF;

  UPDATE public.s4kcs_orders o SET
    vivid_event_id    = coalesce(o.vivid_event_id,    r.vivid),
    sh_event_id       = coalesce(o.sh_event_id,       r.sh),
    sg_event_id       = coalesce(o.sg_event_id,       r.sg),
    tm_event_id       = coalesce(o.tm_event_id,       r.tm),
    tp_event_id       = coalesce(o.tp_event_id,       r.tp),
    paciolan_event_id = coalesce(o.paciolan_event_id, r.pac),
    gt_event_id       = coalesce(o.gt_event_id,       r.gt),
    gt_mapped_via     = coalesce(o.gt_mapped_via,     r.gt_via),
    gt_mapped_at      = CASE WHEN o.gt_event_id IS NULL AND r.gt IS NOT NULL THEN now()
                             ELSE o.gt_mapped_at END,
    market_ids_via    = coalesce(o.market_ids_via, '{}'::jsonb) || jsonb_strip_nulls(jsonb_build_object(
      'vivid',        CASE WHEN o.vivid_event_id    IS NULL AND r.vivid IS NOT NULL THEN r.vivid_via END,
      'stubhub',      CASE WHEN o.sh_event_id       IS NULL AND r.sh    IS NOT NULL THEN r.sh_via    END,
      'seatgeek',     CASE WHEN o.sg_event_id       IS NULL AND r.sg    IS NOT NULL THEN r.sg_via    END,
      'ticketmaster', CASE WHEN o.tm_event_id       IS NULL AND r.tm    IS NOT NULL THEN r.tm_via    END,
      'tickpick',     CASE WHEN o.tp_event_id       IS NULL AND r.tp    IS NOT NULL THEN r.tp_via    END,
      'paciolan',     CASE WHEN o.paciolan_event_id IS NULL AND r.pac   IS NOT NULL THEN r.pac_via   END)),
    market_ids_at     = now()
   FROM _res r
  WHERE o.s4k_order_id = r.s4k_order_id AND o.source = r.source
    AND (   (o.vivid_event_id    IS NULL AND r.vivid IS NOT NULL)
         OR (o.sh_event_id       IS NULL AND r.sh    IS NOT NULL)
         OR (o.sg_event_id       IS NULL AND r.sg    IS NOT NULL)
         OR (o.tm_event_id       IS NULL AND r.tm    IS NOT NULL)
         OR (o.tp_event_id       IS NULL AND r.tp    IS NOT NULL)
         OR (o.paciolan_event_id IS NULL AND r.pac   IS NOT NULL)
         OR (o.gt_event_id       IS NULL AND r.gt    IS NOT NULL));
  GET DIAGNOSTICS v_touched = ROW_COUNT;

  SELECT jsonb_build_object(
           'tevo',         count(*) FILTER (WHERE tevo_event_id     IS NOT NULL),
           'gotickets',    count(*) FILTER (WHERE gt_event_id       IS NOT NULL),
           'tickets_dev',  count(*) FILTER (WHERE tdev_id           IS NOT NULL),
           'vivid',        count(*) FILTER (WHERE vivid_event_id    IS NOT NULL),
           'stubhub',      count(*) FILTER (WHERE sh_event_id       IS NOT NULL),
           'seatgeek',     count(*) FILTER (WHERE sg_event_id       IS NOT NULL),
           'ticketmaster', count(*) FILTER (WHERE tm_event_id       IS NOT NULL),
           'tickpick',     count(*) FILTER (WHERE tp_event_id       IS NOT NULL),
           'paciolan',     count(*) FILTER (WHERE paciolan_event_id IS NOT NULL))
    INTO v_after
    FROM public.s4kcs_orders
   WHERE event_date >= v_from AND coalesce(event_name,'') !~* 'parking|shuttle';

  RETURN jsonb_build_object(
    'applied', true, 'horizon_from', v_from::text, 'eligible_orders', v_eligible,
    'rows_touched', v_touched, 'filled', v_fill,
    'refused_conflicting_aq_rows', v_refused, 'coverage_after', v_after,
    'elapsed_ms', round(EXTRACT(epoch FROM (clock_timestamp() - v_started)) * 1000));
END $fn$;

REVOKE ALL ON FUNCTION public.s4kcs_link_marketplaces(boolean, int) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.s4kcs_link_marketplaces(boolean, int) TO service_role;

COMMENT ON FUNCTION public.s4kcs_link_marketplaces(boolean, int) IS
  'Fills every marketplace id column on s4kcs_orders in one pass. Routes, in measured precedence: aq_event_map by tevo_event_id (best coverage on every marketplace), aq_event_map by aq_short_event_id, the tickets.dev cluster, then seatgeek_event_xref for SeatGeek. Fill is PER COLUMN and fill-only, with the supplying route recorded per marketplace in market_ids_via. Cells where aq_event_map rows disagree are left NULL and counted, never guessed. ALSO fills gt_event_id from aq, but strictly BEHIND s4kcs_link_gotickets, whose identity route is right on all 19 conflicts they have -- provenance for that column stays in gt_mapped_via, not market_ids_via. Does NOT write tevo_event_id -- measured, the cluster backfills zero. DRY RUN unless p_apply => true (mig 20260916200000).';

-- ============================================================================================
-- APPLIED AND VERIFIED ON PROD, 2026-09-16 (future orders only)
-- ============================================================================================
-- Run 1 (all marketplaces except GoTickets), 27,713 eligible, 27,161 rows touched in 13.4s:
--   vivid 26,728 · seatgeek 26,432 · stubhub 25,978 · ticketmaster 24,494 · paciolan 738 · tickpick 0
--   refused as conflicting: vivid 5, stubhub 1, everything else 0
--
-- Run 2 (the GoTickets route added after run 1 exposed the gap), 8,227 rows touched in 3.3s.
--
-- TWO CHECKS THAT ACTUALLY PROVE SOMETHING, rather than restating the output:
--   * SEATGEEK RECONCILES EXACTLY. aq_event_map reaches 26,265 and seatgeek_event_xref adds 167
--     that aq does not carry. 26,265 + 167 = 26,432, which is the filled count to the order.
--   * THE SECOND DRY RUN FILLED ZERO on every column run 1 had already done. Fill-only is not
--     just asserted in the comments, it is idempotent in fact: re-running writes nothing.
--
--   future CRM order coverage after both runs (of 27,739):
--     tevo 27,470 · gotickets 26,946 · vivid 26,728 · seatgeek 26,432 · stubhub 25,978
--     ticketmaster 24,494 · tickets_dev 20,204 · paciolan 738 · tickpick 0
--
-- GOTICKETS WENT 18,719 -> 26,946 ON A ROUTE THAT ALREADY EXISTED. That is the operator's whole
-- point, demonstrated on the way past: the dedicated linker shipped hours earlier was beaten by a
-- column nothing was reading. The specialist still goes first and that is not deference -- it is
-- right on all 19 conflicts where it uses sale identity, which makes aq_event_map wrong on 10
-- events. Those 10 are an A1 defect, recorded here, not propagated into the CRM.
--
-- NOT YET APPLIED: the five partial indexes above. Applying the whole migration in one call hit
-- the 60s MCP ceiling -- s4kcs_orders is 45,024 rows but 272 MB (the raw jsonb column), so five
-- index builds are five scans of a fat heap. DDL is transactional, so that attempt rolled back
-- clean and the columns and function were then applied separately, which is why they are in prod
-- and the indexes are not. The indexes are an optimisation for reverse lookups (marketplace id ->
-- orders); nothing in the fill path needs them. Apply them one statement at a time.
--
-- WHAT THIS DOES NOT FIX, and the reason matters more than the list:
-- every column here is only as good as s4kcs_orders.tevo_event_id, which is set UPSTREAM by fuzzy
-- name/venue/date matching (s4kcs_map_events and friends). Only 5.8% of future orders are mapped
-- by true order-id identity; 7,911 are mapped by name+date with NO venue check, and 753 sit on a
-- 0.70-confidence method that nothing downstream thresholds on. A wrong tevo_event_id now yields
-- six confidently wrong marketplace ids instead of one. Widening the join surface widens the blast
-- radius of an upstream mismatch, and that trade is worth stating out loud rather than discovering.

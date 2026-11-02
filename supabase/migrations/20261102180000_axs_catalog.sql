-- Migration 20261102180000 · level:data-collection · lane:A1 (AXS ingest) · writes:axs_catalog(new),axs_primary_signal(new),axs_catalog_refresh()(new),v_axs_catalog(new),v_axs_signal_unmatched(new),axs_events(INSERT on refresh),cron axs_catalog_refresh_hourly(new) · reads:sg_events_canonical,axs_events,gotickets_listings_snapshots,listings_snapshots,events · pre:none
--
-- ============================================================================
-- AXS event catalogue (operator 2026-11-02: "we need to find an AXS event catalogue").
--
-- WHY: AXS has no public search or event list we can read, and TicketsData's find_events does
-- not support AXS (list_marketplaces 2026-11-02: axs find_events_params = []). Every AXS event we
-- track (axs_events) was hand-entered from spreadsheet tabs. Two sources we already ingest name
-- AXS events without anyone typing a URL:
--
--   1. SeatGeek's event payload (sg_events_canonical.raw_event_jsonb, from the TicketsData
--      SeatGeek discovery drain) carries `integrated.provider_name` = the PRIMARY ticketer, and
--      for AXS `integrated.provider_id` IS the AXS event id — plain ("1449706") or long form
--      ("1001251000AXS1150431" → 1150431). Verified 2026-11-02 against 12 known axs_events URLs:
--      12/12 exact. So https://www.axs.com/events/<id> is built, not guessed.
--   2. Resale delivery type: AXS-ticketed tickets can only move through AXS transfer, so a high
--      share of GoTickets `stock_type = 'AXS_TRANSFER'` / EVO `format = 'Flash_seats'` listings
--      marks an AXS event (2026-11-02: T-Mobile Arena 86 % / 62 %, Toyota Center 58 % / 59 %,
--      United Center 0.3 % / 0.3 %). This gives no AXS id — it flags our own events as AXS-sold
--      (team home games, where SeatGeek's provider field is often empty).
--
-- WHAT
--   * axs_catalog        one row per AXS event id: URL, source, SeatGeek / TEvo ids, name,
--                        venue, date. Source 'axs_events' mirrors the hand-entered list;
--                        'sitemap' is reserved for the AXS sitemap (not reachable yet).
--   * axs_primary_signal per TEvo event: GT / EVO rows written in the last hour and how many
--                        were AXS transfer. Raw listings are delta-stored (PROJECT_BIBLE §3), so
--                        this is the share of CHANGED listings — a proxy, good at venue level.
--   * axs_catalog_refresh() upserts both, then enrols new upcoming SeatGeek-sourced AXS events
--     into axs_events (source_sheets 'catalog:seatgeek', is_axs_primary true). Every AXS pull
--     cron is inactive (400/402/422/423/428/510 since 09-01), so enrolling spends nothing until
--     the operator resumes them.
--   * v_axs_catalog      catalogue + signal + whether the event is already tracked.
--   * v_axs_signal_unmatched  AXS-sold by delivery type (share >= 0.30, >= 20 rows) with no AXS id yet.
--   * cron axs_catalog_refresh_hourly at :37 (gated by cron_should_fire).
-- Nothing calls AXS, SeatGeek or TicketsData: this only reads what is already stored.
-- Rollback: SELECT cron.unschedule('axs_catalog_refresh_hourly'); DROP VIEW v_axs_signal_unmatched, v_axs_catalog;
--   DROP FUNCTION axs_catalog_refresh(); DROP TABLE axs_primary_signal, axs_catalog;
--   DELETE FROM axs_events WHERE source_sheets = 'catalog:seatgeek' AND last_pulled_at IS NULL;
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.axs_catalog (
  axs_event_id   text        PRIMARY KEY,
  event_url      text        NOT NULL,
  source         text        NOT NULL CHECK (source IN ('seatgeek_integrated', 'axs_events', 'sitemap')),
  sg_event_id    bigint,
  tevo_event_id  bigint,
  event_name     text,
  venue_name     text,
  event_date     date,
  first_seen_at  timestamptz NOT NULL DEFAULT now(),
  last_seen_at   timestamptz NOT NULL DEFAULT now(),
  enrolled_at    timestamptz
);
CREATE INDEX IF NOT EXISTS axs_catalog_tevo_idx ON public.axs_catalog (tevo_event_id) WHERE tevo_event_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS axs_catalog_date_idx ON public.axs_catalog (event_date);
COMMENT ON TABLE public.axs_catalog IS
  'AXS event catalogue: every AXS event id we can name without a hand-entered URL (SeatGeek integrated.provider_id) plus the hand-entered axs_events list. Refreshed hourly by axs_catalog_refresh() (mig 20261102180000).';

CREATE TABLE IF NOT EXISTS public.axs_primary_signal (
  tevo_event_id  bigint      PRIMARY KEY,
  gt_rows        integer     NOT NULL DEFAULT 0,
  gt_axs_rows    integer     NOT NULL DEFAULT 0,
  evo_rows       integer     NOT NULL DEFAULT 0,
  evo_flash_rows integer     NOT NULL DEFAULT 0,
  axs_share      numeric,
  computed_at    timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE public.axs_primary_signal IS
  'Per TEvo event: share of GoTickets AXS_TRANSFER + EVO Flash_seats listings written in the last hour (delta-stored rows, so a proxy). >= 0.30 marks an AXS-ticketed event (mig 20261102180000).';

ALTER TABLE public.axs_catalog ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.axs_primary_signal ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.axs_catalog, public.axs_primary_signal FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.axs_catalog, public.axs_primary_signal TO service_role;

CREATE OR REPLACE FUNCTION public.axs_catalog_refresh(p_signal_window interval DEFAULT interval '1 hour')
RETURNS jsonb LANGUAGE plpgsql SET search_path = public, pg_temp AS $$
DECLARE
  v_sg       int;
  v_hand     int;
  v_signal   int;
  v_enrolled int;
BEGIN
  -- 1. SeatGeek: integrated.provider_id is the AXS event id (trailing digits of the long form)
  INSERT INTO public.axs_catalog AS c
         (axs_event_id, event_url, source, sg_event_id, tevo_event_id, event_name, venue_name, event_date)
  SELECT DISTINCT ON (s.axs_id)
         s.axs_id, 'https://www.axs.com/events/' || s.axs_id, 'seatgeek_integrated',
         s.sg_event_id, s.tevo_event_id, s.sg_event_name, s.sg_venue_name, s.sg_event_date::date
    FROM (SELECT substring(g.raw_event_jsonb->'integrated'->>'provider_id' FROM '(\d+)$') AS axs_id,
                 g.sg_event_id, g.tevo_event_id, g.sg_event_name, g.sg_venue_name, g.sg_event_date, g.updated_at
            FROM public.sg_events_canonical g
           WHERE g.raw_event_jsonb->'integrated'->>'provider_name' = 'AXS') s
   WHERE s.axs_id IS NOT NULL
   ORDER BY s.axs_id, s.updated_at DESC NULLS LAST
  ON CONFLICT (axs_event_id) DO UPDATE
     SET sg_event_id   = EXCLUDED.sg_event_id,
         tevo_event_id = coalesce(EXCLUDED.tevo_event_id, c.tevo_event_id),
         event_name    = coalesce(EXCLUDED.event_name, c.event_name),
         venue_name    = coalesce(EXCLUDED.venue_name, c.venue_name),
         event_date    = coalesce(EXCLUDED.event_date, c.event_date),
         last_seen_at  = now();
  GET DIAGNOSTICS v_sg = ROW_COUNT;

  -- 2. the hand-entered list, so the catalogue is the one place to look
  INSERT INTO public.axs_catalog AS c (axs_event_id, event_url, source, tevo_event_id, event_name, venue_name, event_date, enrolled_at)
  SELECT a.axs_event_id, a.event_url, 'axs_events', a.tevo_event_id, e.name, e.venue_name,
         CASE WHEN e.occurs_at_local ~ '^\d{4}-\d\d-\d\d' THEN left(e.occurs_at_local, 10)::date END,
         a.created_at
    FROM public.axs_events a
    LEFT JOIN public.events e ON e.id = a.tevo_event_id
  ON CONFLICT (axs_event_id) DO UPDATE
     SET tevo_event_id = coalesce(c.tevo_event_id, EXCLUDED.tevo_event_id),
         enrolled_at   = coalesce(c.enrolled_at, EXCLUDED.enrolled_at),
         last_seen_at  = now();
  GET DIAGNOSTICS v_hand = ROW_COUNT;

  -- 3. delivery-type signal over the last window (captured_at-indexed on both tables)
  WITH gt AS (
    SELECT tevo_event_id, count(*) n, count(*) FILTER (WHERE stock_type = 'AXS_TRANSFER') axs
      FROM public.gotickets_listings_snapshots
     WHERE captured_at > now() - p_signal_window AND tevo_event_id IS NOT NULL
     GROUP BY 1),
  evo AS (
    SELECT event_id AS tevo_event_id, count(*) n, count(*) FILTER (WHERE format = 'Flash_seats') axs
      FROM public.listings_snapshots
     WHERE captured_at > now() - p_signal_window
     GROUP BY 1)
  INSERT INTO public.axs_primary_signal AS p
         (tevo_event_id, gt_rows, gt_axs_rows, evo_rows, evo_flash_rows, axs_share, computed_at)
  SELECT coalesce(gt.tevo_event_id, evo.tevo_event_id),
         coalesce(gt.n, 0), coalesce(gt.axs, 0), coalesce(evo.n, 0), coalesce(evo.axs, 0),
         round((coalesce(gt.axs, 0) + coalesce(evo.axs, 0))::numeric
               / nullif(coalesce(gt.n, 0) + coalesce(evo.n, 0), 0), 3),
         now()
    FROM gt FULL JOIN evo ON evo.tevo_event_id = gt.tevo_event_id
  ON CONFLICT (tevo_event_id) DO UPDATE
     SET gt_rows = EXCLUDED.gt_rows, gt_axs_rows = EXCLUDED.gt_axs_rows,
         evo_rows = EXCLUDED.evo_rows, evo_flash_rows = EXCLUDED.evo_flash_rows,
         axs_share = EXCLUDED.axs_share, computed_at = EXCLUDED.computed_at;
  GET DIAGNOSTICS v_signal = ROW_COUNT;

  -- 4. enrol new upcoming SeatGeek-sourced AXS events into the AXS pull list
  WITH ins AS (
    INSERT INTO public.axs_events (axs_event_id, event_url, source_sheets, tevo_event_id, active, is_axs_primary)
    SELECT c.axs_event_id, c.event_url, 'catalog:seatgeek', c.tevo_event_id, true, true
      FROM public.axs_catalog c
     WHERE c.source = 'seatgeek_integrated'
       AND c.event_date >= current_date
       AND NOT EXISTS (SELECT 1 FROM public.axs_events a WHERE a.axs_event_id = c.axs_event_id)
    ON CONFLICT (axs_event_id) DO NOTHING
    RETURNING axs_event_id)
  UPDATE public.axs_catalog c SET enrolled_at = now()
    FROM ins WHERE c.axs_event_id = ins.axs_event_id;
  GET DIAGNOSTICS v_enrolled = ROW_COUNT;

  RETURN jsonb_build_object('seatgeek_rows', v_sg, 'axs_events_rows', v_hand,
                            'signal_rows', v_signal, 'enrolled', v_enrolled);
END $$;
REVOKE ALL ON FUNCTION public.axs_catalog_refresh(interval) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.axs_catalog_refresh(interval) TO service_role;

CREATE OR REPLACE VIEW public.v_axs_catalog WITH (security_invoker = true) AS
SELECT c.axs_event_id, c.event_url, c.source, c.event_name, c.venue_name, c.event_date,
       c.sg_event_id, c.tevo_event_id,
       a.axs_event_id IS NOT NULL AS tracked,
       a.active AS tracked_active, a.last_pulled_at,
       s.axs_share, s.gt_rows + s.evo_rows AS signal_rows, s.computed_at AS signal_at,
       c.first_seen_at, c.last_seen_at, c.enrolled_at
  FROM public.axs_catalog c
  LEFT JOIN public.axs_events a ON a.axs_event_id = c.axs_event_id
  LEFT JOIN public.axs_primary_signal s ON s.tevo_event_id = c.tevo_event_id;
REVOKE ALL ON public.v_axs_catalog FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.v_axs_catalog TO service_role;

-- AXS-sold by delivery type, but no AXS id known yet (mostly team home games, whose SeatGeek
-- provider field is empty): the list of URLs still to find.
CREATE OR REPLACE VIEW public.v_axs_signal_unmatched WITH (security_invoker = true) AS
SELECT s.tevo_event_id, e.name AS event_name, e.venue_name, e.occurs_at_local,
       s.axs_share, s.gt_rows, s.gt_axs_rows, s.evo_rows, s.evo_flash_rows, s.computed_at
  FROM public.axs_primary_signal s
  JOIN public.events e ON e.id = s.tevo_event_id
 WHERE s.axs_share >= 0.30
   AND s.gt_rows + s.evo_rows >= 20
   AND NOT EXISTS (SELECT 1 FROM public.axs_catalog c WHERE c.tevo_event_id = s.tevo_event_id)
   AND NOT EXISTS (SELECT 1 FROM public.axs_events a WHERE a.tevo_event_id = s.tevo_event_id);
REVOKE ALL ON public.v_axs_signal_unmatched FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.v_axs_signal_unmatched TO service_role;

SELECT cron.schedule('axs_catalog_refresh_hourly', '37 * * * *', $c$
DO $body$ BEGIN
  IF NOT public.cron_should_fire('axs_catalog_refresh_hourly') THEN RETURN; END IF;
  PERFORM public.axs_catalog_refresh();
END $body$;
$c$);

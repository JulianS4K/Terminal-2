-- Migration 20260811210000 · lane:D0 (author) → applier (apply) · writes:gotickets_deals_feed [table], gotickets_deals_scan_state [table], scan_gotickets_deals(int,numeric,numeric,int) [fn], get_deals_feed(int,timestamptz,numeric,text,boolean) [fn], cron gotickets_deals_scan_5min · reads:gotickets_listings_snapshots,listings_snapshots,event_listing_snapshot_daily,clearing_dte_curve,sg_events_canonical,events,performer_metadata,derive_zone_fallback,price_dte_bucket · pre:get_gotickets_deals (mig 20260811203000) same deal logic, clearing_dte_curve+price_dte_bucket (mig 20260708180040) · auth:scanner service_role-guarded SECDEF; feed resolver email-gated read SECDEF (@s4kent.com)
--
-- WHY (operator-directed 2026-08-11). Turns the DEALS surface from a per-event
-- lookup into a LIVE CROSS-EVENT FEED: as the GoTickets collector re-scans events
-- through the day, newly-deemed deals stream into a feed the terminal polls, so an
-- operator watches deals appear in real time instead of querying one event.
--
-- Same deal definition as get_gotickets_deals (mig 20260811203000): GoTickets is the
-- only BUYABLE inventory; the benchmark is the OTHER sources (EVO zone median, common
-- key derive_zone_fallback). A GoTickets all_in_price <= (1-min_discount)×EVO zone
-- median (zone needs >= min_zone_n EVO listings AND median >= min_zone_median) is a
-- deal; the amalgam 7d-MA vs DTE clearing-curve regime tags it OPPORTUNITY / CAUTION.
--
-- ARCHITECTURE
--   * gotickets_deals_feed — one row per (tevo_event_id, gt_listing_id) currently a
--     deal. first_seen_at drives feed ordering ("new at the top"); last_seen_at is
--     bumped each scan the listing is still a deal; gone_at is stamped when it drops
--     off (sold / repriced above the line) so the UI can retire it. Unique per
--     (event, listing) → a listing appears once, its price/verdict updated in place.
--   * gotickets_deals_scan_state — per-event watermark (last GoTickets captured_at
--     processed) so the scanner only re-does events with a FRESH capture.
--   * scan_gotickets_deals() — one bounded, set-based pass: pick the p_max_events
--     events with the newest GoTickets capture since their watermark (freshest scans
--     first = most "live"), compute their current deals in a single statement,
--     UPSERT (insert stamps first_seen_at; update refreshes price/verdict + clears a
--     stale gone_at on reappearance), then stamp gone_at on this batch's feed rows
--     that are no longer deals. service_role-guarded. Cheap enough for a 5-min cron;
--     self-gates to 0 work when nothing new was scanned.
--   * get_deals_feed() — email-gated read the page polls: newest-first, optional
--     `since` (incremental append), min-discount / regime filters, active-only by
--     default. Returns the feed rows + a scan summary (last_scanned_at, active count).
--   * cron gotickets_deals_scan_5min ('*/5 * * * *') — keeps the feed fresh.
--
-- ROLLBACK: cron.unschedule('gotickets_deals_scan_5min');
--           DROP FUNCTION get_deals_feed(int,timestamptz,numeric,text,boolean);
--           DROP FUNCTION scan_gotickets_deals(int,numeric,numeric,int);
--           DROP TABLE gotickets_deals_feed; DROP TABLE gotickets_deals_scan_state;

-- ── 1. Feed + scan-state tables ──────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.gotickets_deals_feed (
  tevo_event_id  bigint  NOT NULL,
  gt_listing_id  bigint  NOT NULL,
  event_name     text,
  event_date     date,
  zone           text,
  section        text,
  "row"          text,
  quantity       int,
  gt_price       numeric,
  market_median  numeric,
  market_n       int,
  vs_market_pct  int,
  regime         text,
  verdict        text,
  is_accessible  boolean DEFAULT false,
  in_hand_date   date,
  gt_captured_at timestamptz,
  first_seen_at  timestamptz NOT NULL DEFAULT now(),
  last_seen_at   timestamptz NOT NULL DEFAULT now(),
  gone_at        timestamptz,
  PRIMARY KEY (tevo_event_id, gt_listing_id)
);
ALTER TABLE public.gotickets_deals_feed ENABLE ROW LEVEL SECURITY;
-- feed ordering: newest active deals first
CREATE INDEX IF NOT EXISTS gotickets_deals_feed_firstseen_idx
  ON public.gotickets_deals_feed (first_seen_at DESC) WHERE gone_at IS NULL;
CREATE INDEX IF NOT EXISTS gotickets_deals_feed_event_idx
  ON public.gotickets_deals_feed (tevo_event_id);
GRANT SELECT ON public.gotickets_deals_feed TO authenticated, service_role;
COMMENT ON TABLE public.gotickets_deals_feed IS
  'Live GoTickets deal feed (one row per event×GT listing currently below the cross-market EVO zone median). first_seen_at = feed order; gone_at retires sold/repriced. Fed by scan_gotickets_deals. D0 mig 20260811210000.';

CREATE TABLE IF NOT EXISTS public.gotickets_deals_scan_state (
  tevo_event_id   bigint PRIMARY KEY,
  last_gt_cap     timestamptz,
  last_scanned_at timestamptz NOT NULL DEFAULT now(),
  deals_found     int DEFAULT 0
);
ALTER TABLE public.gotickets_deals_scan_state ENABLE ROW LEVEL SECURITY;
GRANT SELECT ON public.gotickets_deals_scan_state TO authenticated, service_role;
COMMENT ON TABLE public.gotickets_deals_scan_state IS
  'Per-event watermark for scan_gotickets_deals (last GoTickets captured_at processed). D0 mig 20260811210000.';

-- ── 2. Scanner ───────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.scan_gotickets_deals(
  p_max_events      int     DEFAULT 40,
  p_min_discount    numeric DEFAULT 0.20,
  p_min_zone_median numeric DEFAULT 50,
  p_min_zone_n      int     DEFAULT 6
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, extensions, pg_temp
AS $fn$
DECLARE
  v_new int := 0; v_gone int := 0; v_events int := 0;
BEGIN
  IF current_user NOT IN ('service_role','postgres','supabase_admin') THEN
    RAISE EXCEPTION 'forbidden: %', current_user USING ERRCODE='42501';
  END IF;
  PERFORM set_config('statement_timeout', '55000', true);

  -- candidate events: freshest GoTickets capture since the per-event watermark
  CREATE TEMP TABLE _cand ON COMMIT DROP AS
    SELECT c.ev, c.cap
    FROM (
      SELECT g.tevo_event_id AS ev, max(g.captured_at) AS cap
      FROM public.gotickets_listings_snapshots g
      WHERE g.captured_at > now() - interval '4 hours' AND g.tevo_event_id IS NOT NULL
      GROUP BY g.tevo_event_id
    ) c
    LEFT JOIN public.gotickets_deals_scan_state s ON s.tevo_event_id = c.ev
    WHERE c.cap > coalesce(s.last_gt_cap, 'epoch'::timestamptz)
    ORDER BY c.cap DESC
    LIMIT GREATEST(p_max_events, 1);

  SELECT count(*) INTO v_events FROM _cand;
  IF v_events = 0 THEN
    RETURN jsonb_build_object('scanned_events',0,'new_deals',0,'gone',0,'at',now());
  END IF;

  -- current deals for the batch (same definition as get_gotickets_deals) + regime
  CREATE TEMP TABLE _deals ON COMMIT DROP AS
  WITH evo_latest AS (
    SELECT l.event_id AS ev, max(l.captured_at) AS mx
    FROM public.listings_snapshots l JOIN _cand c ON c.ev = l.event_id
    WHERE l.captured_at > now() - interval '48 hours'
    GROUP BY l.event_id
  ),
  evo_zone AS (
    SELECT l.event_id AS ev,
           coalesce(nullif(public.derive_zone_fallback(l.section,l.row),''),'(unzoned)') AS zone,
           percentile_cont(0.5) WITHIN GROUP (ORDER BY l.retail_price)::numeric AS evo_med,
           min(l.retail_price)::numeric AS evo_getin,
           count(*) AS evo_n
    FROM public.listings_snapshots l
    JOIN evo_latest e ON e.ev = l.event_id AND l.captured_at = e.mx
    WHERE l.retail_price > 0 AND coalesce(l.is_ancillary,false)=false
    GROUP BY l.event_id, 2
  ),
  gt AS (
    SELECT g.tevo_event_id AS ev, g.gt_listing_id, g.section, g.row, g.quantity,
           g.all_in_price::numeric AS price, g.in_hand_date, c.cap AS gt_cap,
           coalesce(nullif(public.derive_zone_fallback(g.section,g.row),''),'(unzoned)') AS zone,
           (g.row ~* 'wc|wheelchair|accessible' OR g.section ~* 'accessible') AS is_accessible
    FROM public.gotickets_listings_snapshots g
    JOIN _cand c ON c.ev = g.tevo_event_id AND g.captured_at = c.cap
    WHERE g.all_in_price > 0 AND coalesce(g.general_admission,false)=false
  ),
  -- event-level regime (amalgam 7d MA vs DTE clearing curve), per candidate event
  cat AS (
    SELECT e.id AS ev,
           CASE WHEN e.event_type='game' THEN 'Sports'
                WHEN pm.top_category_name IN ('Sports','Concerts','Comedy','Theater') THEN pm.top_category_name
                ELSE 'Other' END AS category
    FROM public.events e LEFT JOIN public.performer_metadata pm ON pm.performer_id=e.primary_performer_id
    WHERE e.id IN (SELECT ev FROM _cand)
  ),
  d AS (
    SELECT dd.event_id AS ev, dd.snapshot_date, dd.amalgam_median,
           row_number() OVER (PARTITION BY dd.event_id ORDER BY dd.snapshot_date DESC,
             CASE dd.snapshot_slot WHEN 'evening' THEN 3 WHEN 'midday' THEN 2 ELSE 1 END DESC) AS rn
    FROM public.event_listing_snapshot_daily dd
    WHERE dd.event_id IN (SELECT ev FROM _cand) AND dd.amalgam_median IS NOT NULL
  ),
  edate AS (
    SELECT sgc.tevo_event_id AS ev, sgc.sg_event_name AS nm, sgc.sg_datetime_utc::date AS dt
    FROM public.sg_events_canonical sgc WHERE sgc.tevo_event_id IN (SELECT ev FROM _cand)
  ),
  regime AS (
    SELECT c.ev, c.category,
      (SELECT amalgam_median FROM d WHERE d.ev=c.ev AND rn=1)                        AS cur_med,
      (SELECT amalgam_median FROM d WHERE d.ev=c.ev AND rn=22)                       AS med_7d_ago,
      ((SELECT dt FROM edate WHERE edate.ev=c.ev) - (SELECT snapshot_date FROM d WHERE d.ev=c.ev AND rn=1))  AS dte_now,
      ((SELECT dt FROM edate WHERE edate.ev=c.ev) - (SELECT snapshot_date FROM d WHERE d.ev=c.ev AND rn=22)) AS dte_7d_ago
    FROM cat c
  ),
  regime2 AS (
    SELECT r.ev,
      CASE WHEN r.med_7d_ago>0 THEN round((r.cur_med/r.med_7d_ago-1)*100,1) END AS actual_pct,
      CASE WHEN cw.level_index>0 THEN round((cn.level_index/cw.level_index-1)*100,1) END AS expected_pct
    FROM regime r
    LEFT JOIN public.clearing_dte_curve cn ON cn.category=r.category AND cn.dte_bucket=public.price_dte_bucket(r.dte_now::int)
    LEFT JOIN public.clearing_dte_curve cw ON cw.category=r.category AND cw.dte_bucket=public.price_dte_bucket(r.dte_7d_ago::int)
  ),
  regime3 AS (
    SELECT ev,
      CASE
        WHEN actual_pct IS NULL THEN 'UNKNOWN'
        WHEN (coalesce(actual_pct,0)-coalesce(expected_pct,0))<=-6 THEN 'DUMPING'
        WHEN (coalesce(actual_pct,0)-coalesce(expected_pct,0))<=-2 THEN 'SOFTENING'
        WHEN (coalesce(actual_pct,0)-coalesce(expected_pct,0))>=4  THEN 'RISING'
        ELSE 'STABLE' END AS regime
    FROM regime2
  )
  SELECT gt.ev, gt.gt_listing_id,
         ed.nm AS event_name, ed.dt AS event_date,
         gt.zone, gt.section, gt.row, gt.quantity,
         round(gt.price,2) AS gt_price, round(z.evo_med,2) AS market_median, z.evo_n AS market_n,
         round((gt.price/z.evo_med-1)*100,0)::int AS vs_market_pct,
         coalesce(rg.regime,'UNKNOWN') AS regime,
         CASE WHEN rg.regime IN ('DUMPING','SOFTENING') THEN 'CAUTION'
              WHEN rg.regime IN ('STABLE','RISING') THEN 'OPPORTUNITY'
              ELSE 'REVIEW' END AS verdict,
         gt.is_accessible, gt.in_hand_date, gt.gt_cap AS gt_captured_at
  FROM gt
  JOIN evo_zone z ON z.ev = gt.ev AND z.zone = gt.zone
  LEFT JOIN edate ed ON ed.ev = gt.ev
  LEFT JOIN regime3 rg ON rg.ev = gt.ev
  WHERE z.evo_n >= GREATEST(p_min_zone_n,3)
    AND z.evo_med >= GREATEST(p_min_zone_median,0)
    AND gt.price <= (1 - LEAST(GREATEST(p_min_discount,0.01),0.95)) * z.evo_med
    AND gt.price >= 0.15 * z.evo_med;

  -- retire feed rows for THIS batch's events that are no longer deals
  UPDATE public.gotickets_deals_feed f
     SET gone_at = now()
   WHERE f.tevo_event_id IN (SELECT ev FROM _cand)
     AND f.gone_at IS NULL
     AND NOT EXISTS (SELECT 1 FROM _deals d WHERE d.ev=f.tevo_event_id AND d.gt_listing_id=f.gt_listing_id);
  GET DIAGNOSTICS v_gone = ROW_COUNT;

  -- upsert current deals (insert stamps first_seen_at; update refreshes + un-retires)
  WITH ins AS (
    INSERT INTO public.gotickets_deals_feed AS f
      (tevo_event_id, gt_listing_id, event_name, event_date, zone, section, "row", quantity,
       gt_price, market_median, market_n, vs_market_pct, regime, verdict, is_accessible,
       in_hand_date, gt_captured_at, first_seen_at, last_seen_at, gone_at)
    SELECT ev, gt_listing_id, event_name, event_date, zone, section, "row", quantity,
           gt_price, market_median, market_n, vs_market_pct, regime, verdict, is_accessible,
           in_hand_date, gt_captured_at, now(), now(), NULL
    FROM _deals
    ON CONFLICT (tevo_event_id, gt_listing_id) DO UPDATE SET
      gt_price=excluded.gt_price, market_median=excluded.market_median, market_n=excluded.market_n,
      vs_market_pct=excluded.vs_market_pct, regime=excluded.regime, verdict=excluded.verdict,
      zone=excluded.zone, section=excluded.section, "row"=excluded."row", quantity=excluded.quantity,
      is_accessible=excluded.is_accessible, in_hand_date=excluded.in_hand_date,
      gt_captured_at=excluded.gt_captured_at, last_seen_at=now(), gone_at=NULL
    RETURNING (xmax = 0) AS inserted
  )
  SELECT count(*) FILTER (WHERE inserted) INTO v_new FROM ins;

  -- advance per-event watermark
  INSERT INTO public.gotickets_deals_scan_state (tevo_event_id, last_gt_cap, last_scanned_at, deals_found)
  SELECT c.ev, c.cap, now(), (SELECT count(*) FROM _deals d WHERE d.ev=c.ev)
  FROM _cand c
  ON CONFLICT (tevo_event_id) DO UPDATE SET
    last_gt_cap=excluded.last_gt_cap, last_scanned_at=now(), deals_found=excluded.deals_found;

  RETURN jsonb_build_object('scanned_events',v_events,'new_deals',v_new,'gone',v_gone,'at',now());
END;
$fn$;
REVOKE ALL ON FUNCTION public.scan_gotickets_deals(int,numeric,numeric,int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.scan_gotickets_deals(int,numeric,numeric,int) TO service_role;
COMMENT ON FUNCTION public.scan_gotickets_deals(int,numeric,numeric,int) IS
  'Incremental live-feed scanner: newest-captured GoTickets events since watermark → compute cross-market deals → upsert gotickets_deals_feed (first_seen_at stamps new; gone_at retires vanished). service_role only. D0 mig 20260811210000.';

-- ── 3. Feed reader (page polls this) ─────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.get_deals_feed(
  p_limit        int         DEFAULT 100,
  p_since        timestamptz DEFAULT NULL,
  p_min_discount numeric     DEFAULT NULL,
  p_regime       text        DEFAULT NULL,
  p_include_gone boolean     DEFAULT false
)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_email text := coalesce(auth.jwt()->>'email','');
  v_result jsonb;
  v_maxpct int := CASE WHEN p_min_discount IS NULL THEN NULL ELSE -round(LEAST(GREATEST(p_min_discount,0.0),0.95)*100)::int END;
BEGIN
  IF v_email NOT LIKE '%@s4kent.com' THEN
    RAISE EXCEPTION 'forbidden: %', v_email USING ERRCODE='42501';
  END IF;

  SELECT jsonb_build_object(
    'generated_at', now(),
    'active_deals', (SELECT count(*) FROM public.gotickets_deals_feed WHERE gone_at IS NULL),
    'last_scan_at', (SELECT max(last_scanned_at) FROM public.gotickets_deals_scan_state),
    'deals', coalesce((
      SELECT jsonb_agg(jsonb_build_object(
        'tevo_event_id', tevo_event_id, 'gt_listing_id', gt_listing_id,
        'event_name', event_name, 'event_date', event_date,
        'zone', zone, 'section', section, 'row', "row", 'quantity', quantity,
        'gt_price', gt_price, 'market_median', market_median, 'market_n', market_n,
        'vs_market_pct', vs_market_pct, 'regime', regime, 'verdict', verdict,
        'is_accessible', is_accessible, 'in_hand_date', in_hand_date,
        'first_seen_at', first_seen_at, 'last_seen_at', last_seen_at, 'gone_at', gone_at
      ) ORDER BY first_seen_at DESC, vs_market_pct ASC)
      FROM (
        SELECT * FROM public.gotickets_deals_feed f
        WHERE (p_include_gone OR f.gone_at IS NULL)
          AND (p_since IS NULL OR f.first_seen_at > p_since)
          AND (v_maxpct IS NULL OR f.vs_market_pct <= v_maxpct)
          AND (p_regime IS NULL OR f.regime = p_regime)
        ORDER BY f.first_seen_at DESC, f.vs_market_pct ASC
        LIMIT LEAST(GREATEST(p_limit,1),500)
      ) q), '[]'::jsonb)
  ) INTO v_result;

  RETURN v_result;
END;
$fn$;
REVOKE ALL ON FUNCTION public.get_deals_feed(int,timestamptz,numeric,text,boolean) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.get_deals_feed(int,timestamptz,numeric,text,boolean) FROM anon;
GRANT EXECUTE ON FUNCTION public.get_deals_feed(int,timestamptz,numeric,text,boolean) TO authenticated, service_role;
COMMENT ON FUNCTION public.get_deals_feed(int,timestamptz,numeric,text,boolean) IS
  'D0 DEALS live feed reader. Newest-first GoTickets deals from gotickets_deals_feed; p_since for incremental polling (append new), p_min_discount/p_regime filters, active-only unless p_include_gone. Email-gated SECDEF. Mig 20260811210000.';

-- ── 4. 5-minute scan cron (self-gates to 0 work when nothing new) ────────────
DO $cron$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname='pg_cron') THEN
    PERFORM cron.unschedule('gotickets_deals_scan_5min')
      WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname='gotickets_deals_scan_5min');
    -- batch 20/run: measured safe (~fast); 40+ can exceed the 55s budget on
    -- big-inventory events (e.g. US Open ~16k GT listings), which would roll the
    -- run back and never advance the watermark. Freshest-captured events first.
    PERFORM cron.schedule('gotickets_deals_scan_5min', '*/5 * * * *',
      $$SELECT public.scan_gotickets_deals(20);$$);
  END IF;
END;
$cron$;

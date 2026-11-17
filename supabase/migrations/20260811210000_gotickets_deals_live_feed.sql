-- Migration 20260811210000 · lane:D0 (author) → applier (apply) · writes:gotickets_deals_feed [table], gotickets_deals_scan_state [table], scan_gotickets_deals(int,numeric,int,numeric,numeric) [fn], get_deals_feed(int,timestamptz,numeric,boolean) [fn], cron gotickets_deals_scan_5min · reads:gotickets_listings_snapshots,sg_events_canonical,events,performer_metadata,clearing_dte_curve,derive_zone_fallback,price_dte_bucket · pre:derive_zone_fallback (mig 20260507000000), clearing_dte_curve+price_dte_bucket (mig 20260708180040) · auth:scanner service_role-guarded SECDEF; feed resolver email-gated read SECDEF (@s4kent.com)
--
-- WHY (operator-directed 2026-08-11). A LIVE cross-event feed of GoTickets DEALS:
-- as the GoTickets collector re-scans events through the day, newly-deemed deals
-- stream into a feed the terminal polls and prepends at the top.
--
-- DEAL = A ROBUST LOW OUTLIER **that clears a ≥15% profit target** (operator
-- directives: "deals should be outliers not a majority" · "only look at go tickets
-- for this for now" · "given assumed price degradation and historic value … a
-- profit of at least 15%"). Two gates, both must pass:
--
--   GATE 1 — SECTION OUTLIER (GoTickets-only). A deal is judged purely against other
--     GoTickets listings for the SAME SECTION (prices within a section are tight;
--     the coarse keyword zone lumps premium+cheap sections and its spread hides
--     everything — measured: zone-level z<=-3.5 flagged 0 of ~600, section-level
--     flags the genuine 0-2/event tail). Per (event × section): median m + MAD →
--     modified z = 0.6745·(p−m)/MAD; z <= -p_z (default 3.5) ⇒ low outlier. MAD=0 →
--     Tukey lower fence p < Q1 − 1.5·IQR. Section needs >= p_min_section_n listings
--     (default 5) and median >= p_min_section_median (default $50).
--
--   GATE 2 — ≥15% PROFIT after assumed degradation. Resale reference = the section
--     median (what you could relist at). Assumed price degradation = the measured
--     clearing_dte_curve (value decays toward the event); resale is discounted to
--     EVENT DAY (conservative floor): est_resale = section_median × curve[event-day]
--     / curve[now] for the event's category. profit = (est_resale − gt_price) /
--     gt_price must be >= p_min_roi (default 0.15). Missing curve/category ⇒ factor
--     1 (no degradation assumed). This is where "historic value" enters: the curve
--     is measured from history. (A hard historic cap via zone_price_baseline —
--     resale also capped at the zone's historic norm — is an easy later refinement.)
--
-- The coarse zone + degradation/profit are computed ONLY for the surviving section
-- outliers (a handful), never over the whole book, so a 16k-listing event stays
-- cheap. GoTickets is the only inventory surfaced.
--
-- ARCHITECTURE
--   * gotickets_deals_feed — one row per (event, GT listing) that is an outlier deal
--     clearing the profit target. first_seen_at = feed order; last_seen_at bumped
--     each scan it still qualifies; gone_at retires listings that sold / repriced /
--     fell below target. Unique per (event, listing).
--   * gotickets_deals_scan_state — per-event watermark (last GoTickets captured_at
--     processed) so only events with a FRESH capture get re-scanned.
--   * scan_gotickets_deals() — one bounded, set-based pass: newest-captured events
--     since watermark → section low outliers → profit gate → UPSERT (first_seen_at
--     stamps new; update refreshes + un-retires) → stamp gone_at on this batch's
--     rows that no longer qualify. service_role-guarded.
--   * get_deals_feed() — email-gated read the page polls: newest-first, `since`
--     incremental append, min-profit filter, active-only by default.
--   * cron gotickets_deals_scan_5min ('*/5 * * * *') — batch 20/run (measured safe
--     vs the 55s budget on big-inventory events like US Open ~16k listings).
--
-- ROLLBACK: cron.unschedule('gotickets_deals_scan_5min');
--           DROP FUNCTION get_deals_feed(int,timestamptz,numeric,boolean);
--           DROP FUNCTION scan_gotickets_deals(int,numeric,int,numeric,numeric);
--           DROP TABLE gotickets_deals_feed; DROP TABLE gotickets_deals_scan_state;

-- ── 1. Feed + scan-state tables ──────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.gotickets_deals_feed (
  tevo_event_id   bigint  NOT NULL,
  gt_listing_id   bigint  NOT NULL,
  event_name      text,
  event_date      date,
  zone            text,
  section         text,
  "row"           text,
  quantity        int,
  gt_price        numeric,
  section_median  numeric,
  section_n       int,
  mod_z           numeric,
  vs_section_pct  int,
  est_resale      numeric,
  roi_pct         int,
  is_accessible   boolean DEFAULT false,
  in_hand_date    date,
  gt_captured_at  timestamptz,
  first_seen_at   timestamptz NOT NULL DEFAULT now(),
  last_seen_at    timestamptz NOT NULL DEFAULT now(),
  gone_at         timestamptz,
  PRIMARY KEY (tevo_event_id, gt_listing_id)
);
ALTER TABLE public.gotickets_deals_feed ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS gotickets_deals_feed_firstseen_idx
  ON public.gotickets_deals_feed (first_seen_at DESC) WHERE gone_at IS NULL;
CREATE INDEX IF NOT EXISTS gotickets_deals_feed_event_idx
  ON public.gotickets_deals_feed (tevo_event_id);
GRANT SELECT ON public.gotickets_deals_feed TO authenticated, service_role;
COMMENT ON TABLE public.gotickets_deals_feed IS
  'Live GoTickets deal feed - one row per (event, GT listing) that is a robust LOW price outlier within its SECTION (GoTickets-only) AND clears the >=15% profit gate (est_resale after clearing-curve degradation). first_seen_at = feed order; gone_at retires. Fed by scan_gotickets_deals. D0 mig 20260811210000.';

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

-- ── 2. Scanner (GT-only section low outliers, gated at >=15% profit) ─────────
CREATE OR REPLACE FUNCTION public.scan_gotickets_deals(
  p_max_events         int     DEFAULT 20,
  p_z_threshold        numeric DEFAULT 3.5,
  p_min_section_n      int     DEFAULT 5,
  p_min_section_median numeric DEFAULT 50,
  p_min_roi            numeric DEFAULT 0.15
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, extensions, pg_temp
AS $fn$
DECLARE
  v_new int := 0; v_gone int := 0; v_events int := 0;
  v_z   numeric := GREATEST(p_z_threshold, 0.1);
BEGIN
  IF current_user NOT IN ('service_role','postgres','supabase_admin') THEN
    RAISE EXCEPTION 'forbidden: %', current_user USING ERRCODE='42501';
  END IF;
  PERFORM set_config('statement_timeout', '55000', true);

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

  CREATE TEMP TABLE _deals ON COMMIT DROP AS
  WITH gt AS (
    SELECT g.tevo_event_id AS ev, g.gt_listing_id, btrim(g.section) AS section, g.row, g.quantity,
           g.all_in_price::numeric AS price, g.in_hand_date, c.cap AS gt_cap,
           (g.row ~* 'wc|wheelchair|accessible' OR g.section ~* 'accessible') AS is_accessible
    FROM public.gotickets_listings_snapshots g
    JOIN _cand c ON c.ev = g.tevo_event_id AND g.captured_at = c.cap
    WHERE g.all_in_price > 0 AND coalesce(g.general_admission,false)=false AND g.section IS NOT NULL
  ),
  ss AS (
    SELECT ev, section, count(*) AS n,
           percentile_cont(0.5)  WITHIN GROUP (ORDER BY price)::numeric AS med,
           percentile_cont(0.25) WITHIN GROUP (ORDER BY price)::numeric AS q1,
           percentile_cont(0.75) WITHIN GROUP (ORDER BY price)::numeric AS q3
    FROM gt GROUP BY ev, section
  ),
  sm AS (
    SELECT g.ev, g.section, percentile_cont(0.5) WITHIN GROUP (ORDER BY abs(g.price - s.med))::numeric AS madv
    FROM gt g JOIN ss s USING (ev, section) GROUP BY g.ev, g.section
  ),
  edate AS (
    SELECT sgc.tevo_event_id AS ev, sgc.sg_event_name AS nm, sgc.sg_datetime_utc::date AS dt
    FROM public.sg_events_canonical sgc WHERE sgc.tevo_event_id IN (SELECT ev FROM _cand)
  ),
  -- GATE 1: section low outliers (few rows survive)
  outl AS (
    SELECT gt.ev, gt.gt_listing_id, ed.nm AS event_name, ed.dt AS event_date,
           gt.section, gt.row, gt.quantity, gt.price, gt.in_hand_date, gt.gt_cap, gt.is_accessible,
           s.med AS section_median, s.n AS section_n,
           CASE WHEN m.madv > 0 THEN round(0.6745*(gt.price - s.med)/m.madv, 2) END AS mod_z,
           round((gt.price/s.med - 1)*100, 0)::int AS vs_section_pct
    FROM gt
    JOIN ss s USING (ev, section)
    JOIN sm m USING (ev, section)
    LEFT JOIN edate ed ON ed.ev = gt.ev
    WHERE s.n >= GREATEST(p_min_section_n,3)
      AND s.med >= GREATEST(p_min_section_median,0)
      AND (
            (m.madv > 0 AND 0.6745*(gt.price - s.med)/m.madv <= -v_z)
         OR (m.madv = 0 AND gt.price < s.q1 - 1.5*(s.q3 - s.q1))
          )
  ),
  cat AS (
    SELECT e.id AS ev,
           CASE WHEN e.event_type='game' THEN 'Sports'
                WHEN pm.top_category_name IN ('Sports','Concerts','Comedy','Theater') THEN pm.top_category_name
                ELSE 'Other' END AS category
    FROM public.events e LEFT JOIN public.performer_metadata pm ON pm.performer_id=e.primary_performer_id
    WHERE e.id IN (SELECT DISTINCT ev FROM outl)
  ),
  -- assumed price degradation to event day (clearing curve), per outlier event
  deg AS (
    SELECT o.ev,
           coalesce(cev.level_index / nullif(cn.level_index,0), 1)::numeric AS factor
    FROM (SELECT DISTINCT ev, event_date FROM outl) o
    LEFT JOIN cat c ON c.ev = o.ev
    LEFT JOIN public.clearing_dte_curve cn
      ON cn.category = c.category
     AND cn.dte_bucket = public.price_dte_bucket((o.event_date - (now() AT TIME ZONE 'utc')::date)::int)
    LEFT JOIN public.clearing_dte_curve cev
      ON cev.category = c.category AND cev.dte_bucket = public.price_dte_bucket(0)
  )
  -- GATE 2: >=15% profit after degradation
  SELECT o.ev, o.gt_listing_id, o.event_name, o.event_date,
         coalesce(nullif(public.derive_zone_fallback(o.section, o.row),''),'(unzoned)') AS zone,
         o.section, o.row, o.quantity, round(o.price,2) AS gt_price,
         round(o.section_median,2) AS section_median, o.section_n, o.mod_z, o.vs_section_pct,
         round(o.section_median * coalesce(d.factor,1), 2) AS est_resale,
         round((o.section_median * coalesce(d.factor,1) - o.price)/o.price*100, 0)::int AS roi_pct,
         o.is_accessible, o.in_hand_date, o.gt_cap AS gt_captured_at
  FROM outl o
  LEFT JOIN deg d ON d.ev = o.ev
  WHERE (o.section_median * coalesce(d.factor,1) - o.price)/o.price >= GREATEST(p_min_roi, 0);

  UPDATE public.gotickets_deals_feed f
     SET gone_at = now()
   WHERE f.tevo_event_id IN (SELECT ev FROM _cand)
     AND f.gone_at IS NULL
     AND NOT EXISTS (SELECT 1 FROM _deals d WHERE d.ev=f.tevo_event_id AND d.gt_listing_id=f.gt_listing_id);
  GET DIAGNOSTICS v_gone = ROW_COUNT;

  WITH ins AS (
    INSERT INTO public.gotickets_deals_feed AS f
      (tevo_event_id, gt_listing_id, event_name, event_date, zone, section, "row", quantity,
       gt_price, section_median, section_n, mod_z, vs_section_pct, est_resale, roi_pct,
       is_accessible, in_hand_date, gt_captured_at, first_seen_at, last_seen_at, gone_at)
    SELECT ev, gt_listing_id, event_name, event_date, zone, section, "row", quantity,
           gt_price, section_median, section_n, mod_z, vs_section_pct, est_resale, roi_pct,
           is_accessible, in_hand_date, gt_captured_at, now(), now(), NULL
    FROM _deals
    ON CONFLICT (tevo_event_id, gt_listing_id) DO UPDATE SET
      gt_price=excluded.gt_price, section_median=excluded.section_median, section_n=excluded.section_n,
      mod_z=excluded.mod_z, vs_section_pct=excluded.vs_section_pct, est_resale=excluded.est_resale,
      roi_pct=excluded.roi_pct, zone=excluded.zone, section=excluded.section, "row"=excluded."row",
      quantity=excluded.quantity, is_accessible=excluded.is_accessible, in_hand_date=excluded.in_hand_date,
      gt_captured_at=excluded.gt_captured_at, last_seen_at=now(), gone_at=NULL
    RETURNING (xmax = 0) AS inserted
  )
  SELECT count(*) FILTER (WHERE inserted) INTO v_new FROM ins;

  INSERT INTO public.gotickets_deals_scan_state (tevo_event_id, last_gt_cap, last_scanned_at, deals_found)
  SELECT c.ev, c.cap, now(), (SELECT count(*) FROM _deals d WHERE d.ev=c.ev)
  FROM _cand c
  ON CONFLICT (tevo_event_id) DO UPDATE SET
    last_gt_cap=excluded.last_gt_cap, last_scanned_at=now(), deals_found=excluded.deals_found;

  RETURN jsonb_build_object('scanned_events',v_events,'new_deals',v_new,'gone',v_gone,'at',now());
END;
$fn$;
REVOKE ALL ON FUNCTION public.scan_gotickets_deals(int,numeric,int,numeric,numeric) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.scan_gotickets_deals(int,numeric,int,numeric,numeric) TO service_role;
COMMENT ON FUNCTION public.scan_gotickets_deals(int,numeric,int,numeric,numeric) IS
  'Incremental live-feed scanner (GoTickets-only): newest-captured events since watermark -> per-section robust low outliers (median+MAD mod-z<=-thr, IQR fence) -> >=p_min_roi profit gate (est_resale = section median x clearing-curve degradation to event day) -> upsert gotickets_deals_feed. service_role only. D0 mig 20260811210000.';

-- ── 3. Feed reader (page polls this) ─────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.get_deals_feed(
  p_limit         int         DEFAULT 100,
  p_since         timestamptz DEFAULT NULL,
  p_min_roi       numeric     DEFAULT NULL,   -- e.g. 0.25 → only deals with >=25% projected profit
  p_include_gone  boolean     DEFAULT false
)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_email  text := coalesce(auth.jwt()->>'email','');
  v_result jsonb;
  v_minroi int := CASE WHEN p_min_roi IS NULL THEN NULL ELSE round(GREATEST(p_min_roi,0)*100)::int END;
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
        'gt_price', gt_price, 'section_median', section_median, 'section_n', section_n,
        'mod_z', mod_z, 'vs_section_pct', vs_section_pct,
        'est_resale', est_resale, 'roi_pct', roi_pct,
        'is_accessible', is_accessible, 'in_hand_date', in_hand_date,
        'first_seen_at', first_seen_at, 'last_seen_at', last_seen_at, 'gone_at', gone_at
      ) ORDER BY first_seen_at DESC, roi_pct DESC)
      FROM (
        SELECT * FROM public.gotickets_deals_feed f
        WHERE (p_include_gone OR f.gone_at IS NULL)
          AND (p_since IS NULL OR f.first_seen_at > p_since)
          AND (v_minroi IS NULL OR f.roi_pct >= v_minroi)
        ORDER BY f.first_seen_at DESC, f.roi_pct DESC
        LIMIT LEAST(GREATEST(p_limit,1),500)
      ) q), '[]'::jsonb)
  ) INTO v_result;

  RETURN v_result;
END;
$fn$;
REVOKE ALL ON FUNCTION public.get_deals_feed(int,timestamptz,numeric,boolean) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.get_deals_feed(int,timestamptz,numeric,boolean) FROM anon;
GRANT EXECUTE ON FUNCTION public.get_deals_feed(int,timestamptz,numeric,boolean) TO authenticated, service_role;
COMMENT ON FUNCTION public.get_deals_feed(int,timestamptz,numeric,boolean) IS
  'D0 DEALS live feed reader. Newest-first GoTickets section-outlier deals (>=15% projected profit) from gotickets_deals_feed; p_since for incremental polling, p_min_roi filters projected profit, active-only unless p_include_gone. Email-gated SECDEF. Mig 20260811210000.';

-- ── 4. 5-minute scan cron (self-gates to 0 work when nothing new) ────────────
DO $cron$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname='pg_cron') THEN
    PERFORM cron.unschedule('gotickets_deals_scan_5min')
      WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname='gotickets_deals_scan_5min');
    PERFORM cron.schedule('gotickets_deals_scan_5min', '*/5 * * * *',
      $$SELECT public.scan_gotickets_deals();$$);
  END IF;
END;
$cron$;

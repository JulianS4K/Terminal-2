-- ============================================================
-- AQ-hub resolver — the durable, source-agnostic way to map everything to tevo.
-- A1 2026-05-30 (operator directive: "use the aq mapper ... build ... so we can easily
-- map all sources"). Stage 2 of the 3-stage mapping pipeline (see D0_BIBLE §3h):
--   :22 match_unmatched_orders_sweep()      -> stamps aq_short_event_id on order rows
--   :35 resolve_aq_tevo_from_sources()      -> THIS: fills aq_event_map.tevo_event_id
--   :40 backfill_order_tevo_from_aq()       -> derives each order's tevo_event_id
--
-- WHY: the sg/td bridges fill aq_event_map.tevo_event_id from sg_event_id, but many
-- aq_curated/system_seed rows have NULL venue or placeholder dates ("...T23:59") and no
-- sg link, so they never resolve — while the linked SOURCE's raw holds the true venue +
-- datetime. This resolves those rows from that reliable raw (UNIQUE match only, so it can
-- never mis-map), which then maps every order AND listing on the row, through the AQ hub.
--
-- ★ To onboard a new source: add its reliable raw venue + local-datetime to the `sig`
--   UNION. Do NOT add per-source order hacks — fill the hub and derive through it.
-- First run resolved 176 unresolved aq rows.
-- ============================================================
CREATE OR REPLACE FUNCTION public.resolve_aq_tevo_from_sources()
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public','pg_temp'
AS $function$
DECLARE n integer;
BEGIN
  WITH sig AS (
    -- TickPick orders: raw.event.event_date (local) + raw.venue.name
    SELECT o.aq_short_event_id AS aq,
           split_part((o.raw->'venue'->>'name'),' - ',1) AS venue,
           left(o.raw->'event'->>'event_date',19) AS dt
    FROM public.tickpick_orders o
    JOIN public.aq_event_map a ON a.aq_short_event_id = o.aq_short_event_id
    WHERE a.tevo_event_id IS NULL
      AND (o.raw->'event'->>'event_date') IS NOT NULL AND (o.raw->'venue'->>'name') IS NOT NULL
    UNION ALL
    -- Vivid orders: raw_xml <eventDate> + <venue>
    SELECT o.aq_short_event_id,
           split_part(substring(o.raw_xml from '<venue>([^<]+)</venue>'),' - ',1),
           replace(substring(o.raw_xml from '<eventDate>([^<]+)</eventDate>'),' ','T')
    FROM public.vivid_orders o
    JOIN public.aq_event_map a ON a.aq_short_event_id = o.aq_short_event_id
    WHERE a.tevo_event_id IS NULL AND o.raw_xml IS NOT NULL
  ),
  matched AS (
    SELECT s.aq, max(e.id) AS tevo
    FROM sig s
    JOIN public.events e ON e.venue_name = s.venue AND left(e.occurs_at_local,19) = s.dt
    WHERE s.venue IS NOT NULL AND s.venue <> '' AND s.dt IS NOT NULL
    GROUP BY s.aq HAVING count(DISTINCT e.id) = 1
  )
  UPDATE public.aq_event_map a SET tevo_event_id = m.tevo
  FROM matched m WHERE a.aq_short_event_id = m.aq AND a.tevo_event_id IS NULL;
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $function$;

REVOKE ALL ON FUNCTION public.resolve_aq_tevo_from_sources() FROM anon, PUBLIC;

-- @ :35 — after match_unmatched_orders_sweep (:22), before backfill_order_tevo_from_aq (:40).
DO $$ BEGIN PERFORM cron.unschedule('resolve-aq-tevo-from-sources-hourly'); EXCEPTION WHEN OTHERS THEN NULL; END $$;
SELECT cron.schedule('resolve-aq-tevo-from-sources-hourly', '35 * * * *',
  $cron$SELECT public.resolve_aq_tevo_from_sources();$cron$);

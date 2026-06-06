-- 20260606191854_cron_redesign_1_collector_cadence_trading_hours.sql
--
-- ## Already applied to prod — applied via MCP 2026-06-06 (operator-authorized)
--
-- Trading-hours cadence redesign #1 of 3 (CRON_HIERARCHY §4c).
-- Widen collector_band peak window to ET trading hours {9-23,0}; re-tune SG
-- listings(owned) + sales bands to the time-to-event decay derived from two
-- sample weeks (sales/event 39@d0 -> ~3.5@d15-30; median reprices ~4x/day ≤3d).
-- Reversible: collector_band is CREATE OR REPLACE; collector_cadence is data.

-- 1. collector_band: peak hours 12-23 -> 9-23,0 ET (both overloads)
CREATE OR REPLACE FUNCTION public.collector_band(p_source text, p_scope text, p_hours numeric)
RETURNS TABLE(band text, required_min integer) LANGUAGE sql STABLE
SET search_path TO 'public','pg_temp' AS $function$
  SELECT c.band,
         CASE WHEN EXTRACT(hour FROM now() AT TIME ZONE 'America/New_York')::int
                   = ANY (ARRAY[9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,0])
              THEN c.peak_interval_min ELSE c.offpeak_interval_min END
  FROM public.collector_cadence c
  WHERE c.source=p_source AND c.scope=p_scope AND c.enabled
    AND p_hours >= c.min_hours AND (c.max_hours IS NULL OR p_hours < c.max_hours)
  ORDER BY c.sort_order LIMIT 1;
$function$;

CREATE OR REPLACE FUNCTION public.collector_band(p_source text, p_scope text, p_hours numeric, p_owned boolean)
RETURNS TABLE(band text, required_min integer) LANGUAGE sql STABLE
SET search_path TO 'public','pg_temp' AS $function$
  SELECT c.band,
         CASE WHEN EXTRACT(hour FROM now() AT TIME ZONE 'America/New_York')::int
                   = ANY (ARRAY[9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,0])
              THEN c.peak_interval_min ELSE c.offpeak_interval_min END
  FROM public.collector_cadence c
  WHERE c.source=p_source AND c.scope=p_scope AND c.enabled
    AND p_hours >= c.min_hours AND (c.max_hours IS NULL OR p_hours < c.max_hours)
    AND c.owned_kind IN (CASE WHEN p_owned THEN 'owned' ELSE 'non' END, 'any')
  ORDER BY (c.owned_kind <> 'any') DESC, c.sort_order LIMIT 1;
$function$;

-- 2. SG listings (owned): split le7d -> le3d + d4_7, retune middle/far
DELETE FROM public.collector_cadence
 WHERE source='SG' AND scope='listings' AND owned_kind='owned' AND band='le7d';
INSERT INTO public.collector_cadence
  (source,scope,band,owned_kind,min_hours,max_hours,peak_interval_min,offpeak_interval_min,enabled,sort_order,notes,updated_at)
VALUES
  ('SG','listings','le3d','owned',0,72,30,90,true,1,'trading-hours redesign §4c',now()),
  ('SG','listings','d4_7','owned',72,168,60,180,true,2,'trading-hours redesign §4c',now())
ON CONFLICT (source,scope,band,owned_kind) DO UPDATE
  SET min_hours=EXCLUDED.min_hours, max_hours=EXCLUDED.max_hours,
      peak_interval_min=EXCLUDED.peak_interval_min, offpeak_interval_min=EXCLUDED.offpeak_interval_min,
      enabled=true, sort_order=EXCLUDED.sort_order, notes=EXCLUDED.notes, updated_at=now();
UPDATE public.collector_cadence SET peak_interval_min=150, offpeak_interval_min=480, sort_order=3, updated_at=now()
 WHERE source='SG' AND scope='listings' AND owned_kind='owned' AND band='d8_14';
UPDATE public.collector_cadence SET peak_interval_min=600, offpeak_interval_min=1440, sort_order=4, updated_at=now()
 WHERE source='SG' AND scope='listings' AND owned_kind='owned' AND band='d15_30';
UPDATE public.collector_cadence SET peak_interval_min=1200, offpeak_interval_min=1440, sort_order=5, updated_at=now()
 WHERE source='SG' AND scope='listings' AND owned_kind='owned' AND band='d31p';

-- 3. SG sales (any): split le7d -> le3d + d4_7, retune
DELETE FROM public.collector_cadence
 WHERE source='SG' AND scope='sales' AND owned_kind='any' AND band='le7d';
INSERT INTO public.collector_cadence
  (source,scope,band,owned_kind,min_hours,max_hours,peak_interval_min,offpeak_interval_min,enabled,sort_order,notes,updated_at)
VALUES
  ('SG','sales','le3d','any',0,72,30,90,true,1,'trading-hours redesign §4c',now()),
  ('SG','sales','d4_7','any',72,168,90,240,true,2,'trading-hours redesign §4c',now())
ON CONFLICT (source,scope,band,owned_kind) DO UPDATE
  SET min_hours=EXCLUDED.min_hours, max_hours=EXCLUDED.max_hours,
      peak_interval_min=EXCLUDED.peak_interval_min, offpeak_interval_min=EXCLUDED.offpeak_interval_min,
      enabled=true, sort_order=EXCLUDED.sort_order, notes=EXCLUDED.notes, updated_at=now();
UPDATE public.collector_cadence SET peak_interval_min=240, offpeak_interval_min=720, sort_order=3, updated_at=now()
 WHERE source='SG' AND scope='sales' AND owned_kind='any' AND band='d8_14';
UPDATE public.collector_cadence SET peak_interval_min=720, offpeak_interval_min=1440, sort_order=4, updated_at=now()
 WHERE source='SG' AND scope='sales' AND owned_kind='any' AND band='d15_30';
UPDATE public.collector_cadence SET peak_interval_min=1440, offpeak_interval_min=1440, sort_order=5, updated_at=now()
 WHERE source='SG' AND scope='sales' AND owned_kind='any' AND band='d31p';

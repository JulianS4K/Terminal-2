-- venue -> IANA timezone, so a UTC instant can be turned into the LOCAL day it belongs to.
--
-- Operator: "do the venue timezone map". Every wrong-night defect this session traces back to the
-- same missing fact:
--   * sg_event_date turned out to be a UTC date — one day ahead of the mirror on 25% of rows;
--   * vivid_orders.event_date is local wall time labelled +00, so rule 2 is switched OFF for that
--     surface entirely and has been since mig 20260911230000;
--   * gotickets_event carries only event_time_utc, with no local time and no timezone, which is
--     why the GoTickets fallback had to route through tickets.dev clusters instead of matching
--     the catalogue directly;
--   * 45 CRM orders / 134 tickets sit one day off a unique TEvo candidate with no safe way to
--     decide which side is right.
-- All of it needs one thing: the venue's zone.
--
-- THREE SOURCES, strongest first:
--   1. tickpick_orders.raw->'venue'->>'timezone' — a real IANA name published on the order
--      payload, with lat/lon beside it. 202 venues, 169 already mapped to a tevo_venue_id.
--   2. tickets_dev_event.venue_tz — IANA from the catalogue. 421 venues, matched by name.
--   3. seatgeek — DERIVED, not published. sg_events_canonical carries BOTH sg_datetime_utc and
--      raw_event_jsonb->>'datetime_local', so the zone can be FITTED: find every IANA zone where
--      (utc AT TIME ZONE zone) reproduces the observed local time for EVERY observation of that
--      venue. 1,292 SG venues, 889 mapped to a tevo_venue_id — much the widest source.
--
-- WHY THE FIT IS TRUSTWORTHY. Postgres carries the full tz database, so the fit is tested against
-- real DST rules rather than an assumed offset. It was validated against the venues where a
-- direct IANA name also exists: **127 venues with both sources, 117 exact matches, 10 where the
-- published zone was among the fitted alternatives, and ZERO real disagreements.**
--
-- A venue rarely narrows to exactly one zone — Xfinity Center MA fits {America/New_York,
-- America/Toronto}, The Factory STL fits {America/Chicago, America/Winnipeg}. That is harmless:
-- those zones are offset-identical, so any of them yields the same local day, which is all this
-- map is asked for. The alternatives are kept in a column so the ambiguity stays visible rather
-- than being silently collapsed.
--
-- The one real trap is a zone that only LOOKS equivalent over the observed window:
-- America/Mexico_City abolished DST in 2022, so against summer-only observations it fits
-- alongside America/Denver and would diverge in winter. Two defences: the candidate list is
-- ordered US-first, and distinct_offsets records whether the observations actually straddle a DST
-- change. 644 of 884 fitted venues rest on a single offset, which is weaker evidence and says so
-- in the row rather than being presented as certainty.
--
-- A direct IANA name always beats a fit: sources 1 and 2 overwrite source 3, and 1 overwrites 2.
--
-- Coverage after the first run: 990 venues, 977 of the hub's 1,128 (86.6%). Distribution is
-- sane — Eastern 411, Central 238, Pacific 161, Mountain 72, Phoenix 12, Honolulu 5.

CREATE TABLE IF NOT EXISTS public.venue_timezone (
  tevo_venue_id    bigint PRIMARY KEY,
  iana_tz          text NOT NULL,
  source           text NOT NULL,          -- tickpick | tickets_dev | seatgeek_fit
  observations     int,                    -- how many (utc, local) pairs the fit rested on
  distinct_offsets int,                    -- >1 means the observations straddle a DST change
  alternatives     text[],                 -- other zones fitting equally over the observed window
  venue_name       text,
  derived_at       timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.venue_timezone IS
  'tevo_venue_id -> IANA zone. Direct from TickPick/tickets.dev where published, otherwise FITTED from SeatGeek local+utc pairs against the Postgres tz database. distinct_offsets>1 means the fit straddles a DST change (mig 20260915050000).';

-- the local day a UTC instant falls on at this venue. NULL when the zone is unknown — callers
-- MUST treat NULL as "cannot decide" and never substitute a default zone. Substituting one is
-- how the wrong-night class of defect gets created.
CREATE OR REPLACE FUNCTION public.venue_local_day(p_tevo_venue_id bigint, p_utc timestamptz)
RETURNS date
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $fn$
  SELECT CASE WHEN v.iana_tz IS NULL OR p_utc IS NULL THEN NULL
              ELSE (p_utc AT TIME ZONE v.iana_tz)::date END
    FROM public.venue_timezone v WHERE v.tevo_venue_id = p_tevo_venue_id;
$fn$;

REVOKE ALL ON FUNCTION public.venue_local_day(bigint, timestamptz) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.venue_local_day(bigint, timestamptz) TO service_role;

COMMENT ON FUNCTION public.venue_local_day(bigint, timestamptz) IS
  'UTC instant -> local calendar day at that venue. NULL means the zone is unknown; never substitute a default (mig 20260915050000).';

CREATE OR REPLACE FUNCTION public.venue_timezone_derive(p_apply boolean DEFAULT false)
RETURNS TABLE(out_source text, out_venues int, out_ambiguous int, out_single_offset_only int)
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $fn$
DECLARE v_sg int;
BEGIN
  IF current_user NOT IN ('service_role', 'postgres', 'supabase_admin') THEN
    RAISE EXCEPTION 'forbidden: %', current_user USING ERRCODE = '42501';
  END IF;
  PERFORM set_config('statement_timeout', '160000', true);

  -- candidate zones in preference order. US first, because an offset-equivalent non-US zone
  -- (notably America/Mexico_City, which dropped DST in 2022) can fit a summer-only window and
  -- then diverge in winter.
  DROP TABLE IF EXISTS _z;
  CREATE TEMP TABLE _z ON COMMIT DROP AS
  SELECT tz, ord FROM unnest(ARRAY[
    'America/New_York','America/Chicago','America/Denver','America/Los_Angeles','America/Phoenix',
    'America/Anchorage','Pacific/Honolulu','America/Detroit','America/Indiana/Indianapolis',
    'America/Toronto','America/Vancouver','America/Edmonton','America/Winnipeg','America/Halifax',
    'America/St_Johns','America/Mexico_City','America/Puerto_Rico','Europe/London','Europe/Dublin'
  ]) WITH ORDINALITY AS t(tz, ord);

  DROP TABLE IF EXISTS _fit;
  CREATE TEMP TABLE _fit ON COMMIT DROP AS
  WITH pairs AS (
    SELECT x.tevo_id AS tevo_venue_id, max(c.sg_venue_name) AS venue_name,
           c.sg_datetime_utc AS utc_ts, (c.raw_event_jsonb->>'datetime_local')::timestamp AS local_ts
      FROM public.sg_events_canonical c
      JOIN public.canonical_external_ids x
        ON x.entity_kind = 'venue' AND x.source_key = 'seatgeek' AND x.external_id = c.sg_venue_id::text
     WHERE c.raw_event_jsonb ? 'datetime_local' AND c.sg_datetime_utc IS NOT NULL
     GROUP BY x.tevo_id, c.sg_datetime_utc, (c.raw_event_jsonb->>'datetime_local')::timestamp),
  agg AS (
    SELECT tevo_venue_id, max(venue_name) AS venue_name, count(*) AS obs,
           count(DISTINCT (utc_ts - local_ts AT TIME ZONE 'UTC')) AS distinct_offsets
      FROM pairs GROUP BY tevo_venue_id),
  ok AS (
    SELECT a.tevo_venue_id, a.venue_name, a.obs, a.distinct_offsets, z.tz, z.ord
      FROM agg a CROSS JOIN _z z
     WHERE NOT EXISTS (SELECT 1 FROM pairs p
                        WHERE p.tevo_venue_id = a.tevo_venue_id
                          AND (p.utc_ts AT TIME ZONE z.tz) <> p.local_ts))
  SELECT DISTINCT ON (tevo_venue_id)
         tevo_venue_id, venue_name, obs, distinct_offsets,
         first_value(tz) OVER (PARTITION BY tevo_venue_id ORDER BY ord) AS iana_tz,
         array_agg(tz) OVER (PARTITION BY tevo_venue_id ORDER BY ord
                             ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING) AS alts
    FROM ok ORDER BY tevo_venue_id, ord;

  IF p_apply THEN
    INSERT INTO public.venue_timezone (tevo_venue_id, iana_tz, source, observations, distinct_offsets, alternatives, venue_name, derived_at)
    SELECT f.tevo_venue_id, f.iana_tz, 'seatgeek_fit', f.obs, f.distinct_offsets,
           nullif(f.alts, ARRAY[f.iana_tz]), f.venue_name, now()
      FROM _fit f
    ON CONFLICT (tevo_venue_id) DO UPDATE
      SET iana_tz = CASE WHEN public.venue_timezone.source IN ('tickpick','tickets_dev')
                         THEN public.venue_timezone.iana_tz ELSE excluded.iana_tz END,
          observations = excluded.observations, distinct_offsets = excluded.distinct_offsets,
          alternatives = excluded.alternatives, derived_at = now();

    INSERT INTO public.venue_timezone (tevo_venue_id, iana_tz, source, venue_name, derived_at)
    SELECT DISTINCT ON (a.tevo_venue_id) a.tevo_venue_id, t.venue_tz, 'tickets_dev', t.venue_name, now()
      FROM public.tickets_dev_event t
      JOIN public.aq_event_map a ON lower(trim(a.venue_name)) = lower(trim(t.venue_name))
                                AND a.tevo_venue_id IS NOT NULL
     WHERE t.venue_tz IS NOT NULL AND t.venue_tz <> ''
     ORDER BY a.tevo_venue_id, t.fetched_at DESC
    ON CONFLICT (tevo_venue_id) DO UPDATE
      SET iana_tz = CASE WHEN public.venue_timezone.source = 'tickpick'
                         THEN public.venue_timezone.iana_tz ELSE excluded.iana_tz END,
          source = CASE WHEN public.venue_timezone.source = 'tickpick' THEN 'tickpick' ELSE 'tickets_dev' END,
          derived_at = now();

    INSERT INTO public.venue_timezone (tevo_venue_id, iana_tz, source, venue_name, derived_at)
    SELECT DISTINCT ON (x.tevo_id) x.tevo_id, o.raw->'venue'->>'timezone', 'tickpick',
           o.raw->'venue'->>'name', now()
      FROM public.tickpick_orders o
      JOIN public.canonical_external_ids x ON x.entity_kind = 'venue' AND x.source_key = 'tickpick'
                                          AND x.external_id = o.raw->'venue'->>'id'
     WHERE o.raw->'venue'->>'timezone' IS NOT NULL AND o.raw->'venue'->>'timezone' <> ''
     ORDER BY x.tevo_id, o.ordered_at DESC
    ON CONFLICT (tevo_venue_id) DO UPDATE
      SET iana_tz = excluded.iana_tz, source = 'tickpick', derived_at = now();

    -- the published sources emit legacy aliases; normalise so the table has one spelling per zone
    UPDATE public.venue_timezone SET iana_tz = CASE iana_tz
      WHEN 'US/Eastern'  THEN 'America/New_York'   WHEN 'US/Central' THEN 'America/Chicago'
      WHEN 'US/Pacific'  THEN 'America/Los_Angeles' WHEN 'US/Mountain' THEN 'America/Denver'
      WHEN 'US/Arizona'  THEN 'America/Phoenix'     WHEN 'US/Hawaii'  THEN 'Pacific/Honolulu'
      WHEN 'US/Alaska'   THEN 'America/Anchorage'   ELSE iana_tz END
     WHERE iana_tz LIKE 'US/%';
  END IF;

  SELECT count(*) INTO v_sg FROM _fit;
  RETURN QUERY
    SELECT 'seatgeek_fit'::text, v_sg,
           (SELECT count(*)::int FROM _fit WHERE array_length(alts,1) > 1),
           (SELECT count(*)::int FROM _fit WHERE distinct_offsets = 1);
END $fn$;

REVOKE ALL ON FUNCTION public.venue_timezone_derive(boolean) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.venue_timezone_derive(boolean) TO service_role;

COMMENT ON FUNCTION public.venue_timezone_derive(boolean) IS
  'Builds venue_timezone from TickPick (IANA direct) > tickets.dev (IANA direct) > SeatGeek (fitted from local+utc pairs). Dry run by default (mig 20260915050000).';

-- The four-step pipeline's +/-24h window needs a UTC instant for every EVO event, and an EVO
-- event only has one if its venue has a timezone. Once the full US+CA backfill landed, 42,189 of
-- the 107,341 forward US+CA events -- 39% -- were at venues with no timezone at all, and were
-- therefore invisible to step 3 entirely.
--
-- THIS IS THE API'S BEHAVIOUR, NOT A DRAIN DEFECT. That was checked before anything was built:
-- of 2,701 events sampled straight out of the stored /v9/events responses, 1,057 carry no
-- venue.time_zone key. TEvo simply omits it for a large minority of venues.
--
-- The existing venue_timezone_derive() could not help. Its three tiers are a SeatGeek local+utc
-- fit, tickets.dev's published IANA and TickPick's order payload -- all of which require the venue
-- to exist in one of those other systems, and these 3,223 venues are TEvo venues that do not.
-- Only 70 of them had any event carrying an explicit offset in occurs_at_local, so an
-- observation-based fit was not available either. 3,075 of them DO have latitude and longitude,
-- filled by the new ingest from the same payload that omitted the zone.
--
-- ============================================================================================
-- SCORED BEFORE IT WAS TRUSTED
-- ============================================================================================
-- A derivation rule nobody scored is a guess with a schema, so the function scores itself against
-- every venue whose zone was already settled by a stronger source, and it does so BEFORE writing.
--
-- MEASURED against 2,449 such venues: 2,342 agree exactly. Of the 107 that differ, 93 are a
-- different zone NAME carrying the same offset. That leaves 14 real disagreements -- and reading
-- them, several are cases where the STORED zone is the wrong one: a Colorado venue recorded as
-- America/New_York, a Washington venue as America/Denver, a Virginia and a New York venue as
-- America/Chicago, an Iowa venue as America/New_York. The rest are the genuinely ambiguous
-- counties of Indiana and Tennessee.
--
-- Those pre-existing wrong rows are NOT corrected here. This function only FILLS. venue_timezone's
-- standing rule is that a weak observation never overwrites a derived zone, and geography is the
-- weakest source in the table -- so it writes only where iana_tz IS NULL, and the 2,449 venues it
-- was scored against are exactly the ones it cannot touch.
--
-- RESULT: 3,273 venues filled; EVO US+CA forward events with no resolvable UTC instant went from
-- 42,189 to 0.

CREATE OR REPLACE FUNCTION public.tz_from_us_ca_geography(
  p_country text, p_state text, p_lat numeric, p_lon numeric)
RETURNS text
LANGUAGE sql
IMMUTABLE
SET search_path = public, pg_temp
AS $fn$
  SELECT CASE upper(btrim(coalesce(p_state,'')))
    WHEN 'CT' THEN 'America/New_York' WHEN 'DE' THEN 'America/New_York'
    WHEN 'DC' THEN 'America/New_York' WHEN 'GA' THEN 'America/New_York'
    WHEN 'ME' THEN 'America/New_York' WHEN 'MD' THEN 'America/New_York'
    WHEN 'MA' THEN 'America/New_York' WHEN 'NH' THEN 'America/New_York'
    WHEN 'NJ' THEN 'America/New_York' WHEN 'NY' THEN 'America/New_York'
    WHEN 'NC' THEN 'America/New_York' WHEN 'OH' THEN 'America/New_York'
    WHEN 'PA' THEN 'America/New_York' WHEN 'RI' THEN 'America/New_York'
    WHEN 'SC' THEN 'America/New_York' WHEN 'VT' THEN 'America/New_York'
    WHEN 'VA' THEN 'America/New_York' WHEN 'WV' THEN 'America/New_York'
    WHEN 'AL' THEN 'America/Chicago'  WHEN 'AR' THEN 'America/Chicago'
    WHEN 'IL' THEN 'America/Chicago'  WHEN 'IA' THEN 'America/Chicago'
    WHEN 'LA' THEN 'America/Chicago'  WHEN 'MN' THEN 'America/Chicago'
    WHEN 'MS' THEN 'America/Chicago'  WHEN 'MO' THEN 'America/Chicago'
    WHEN 'OK' THEN 'America/Chicago'  WHEN 'WI' THEN 'America/Chicago'
    WHEN 'CO' THEN 'America/Denver'   WHEN 'MT' THEN 'America/Denver'
    WHEN 'NM' THEN 'America/Denver'   WHEN 'UT' THEN 'America/Denver'
    WHEN 'WY' THEN 'America/Denver'
    WHEN 'AZ' THEN 'America/Phoenix'
    WHEN 'CA' THEN 'America/Los_Angeles' WHEN 'WA' THEN 'America/Los_Angeles'
    WHEN 'NV' THEN 'America/Los_Angeles'
    WHEN 'AK' THEN 'America/Anchorage' WHEN 'HI' THEN 'Pacific/Honolulu'
    WHEN 'PR' THEN 'America/Puerto_Rico' WHEN 'VI' THEN 'America/Puerto_Rico'
    WHEN 'GU' THEN 'Pacific/Guam' WHEN 'MP' THEN 'Pacific/Guam'
    WHEN 'AS' THEN 'Pacific/Pago_Pago'
    -- states a single zone cannot describe: the longitude decides, and when it is
    -- missing the majority zone is used rather than a guess dressed up as a fact
    WHEN 'FL' THEN CASE WHEN p_lon < -85.0  THEN 'America/Chicago' ELSE 'America/New_York' END
    WHEN 'KY' THEN CASE WHEN p_lon < -86.0  THEN 'America/Chicago' ELSE 'America/New_York' END
    WHEN 'TN' THEN CASE WHEN p_lon < -85.5  THEN 'America/Chicago' ELSE 'America/New_York' END
    WHEN 'MI' THEN CASE WHEN p_lon < -90.0  THEN 'America/Chicago' ELSE 'America/Detroit' END
    WHEN 'IN' THEN CASE WHEN p_lon < -86.9 AND p_lat > 41.0 THEN 'America/Chicago'
                        ELSE 'America/Indiana/Indianapolis' END
    WHEN 'KS' THEN CASE WHEN p_lon < -101.5 THEN 'America/Denver' ELSE 'America/Chicago' END
    WHEN 'NE' THEN CASE WHEN p_lon < -101.0 THEN 'America/Denver' ELSE 'America/Chicago' END
    WHEN 'ND' THEN CASE WHEN p_lon < -101.0 THEN 'America/Denver' ELSE 'America/Chicago' END
    WHEN 'SD' THEN CASE WHEN p_lon < -100.0 THEN 'America/Denver' ELSE 'America/Chicago' END
    WHEN 'TX' THEN CASE WHEN p_lon < -104.0 THEN 'America/Denver' ELSE 'America/Chicago' END
    WHEN 'OR' THEN CASE WHEN p_lon > -117.5 THEN 'America/Boise' ELSE 'America/Los_Angeles' END
    WHEN 'ID' THEN CASE WHEN p_lat > 45.5   THEN 'America/Los_Angeles' ELSE 'America/Boise' END
    -- Canada
    WHEN 'NL' THEN 'America/St_Johns'
    WHEN 'NS' THEN 'America/Halifax' WHEN 'NB' THEN 'America/Halifax'
    WHEN 'PE' THEN 'America/Halifax'
    WHEN 'QC' THEN 'America/Toronto'
    WHEN 'ON' THEN CASE WHEN p_lon < -90.0 THEN 'America/Winnipeg' ELSE 'America/Toronto' END
    WHEN 'MB' THEN 'America/Winnipeg'
    WHEN 'SK' THEN 'America/Regina'
    WHEN 'AB' THEN 'America/Edmonton'
    WHEN 'BC' THEN CASE WHEN p_lon > -120.5 AND p_lat > 54.0 THEN 'America/Dawson_Creek'
                        ELSE 'America/Vancouver' END
    WHEN 'YT' THEN 'America/Whitehorse'
    WHEN 'NT' THEN 'America/Edmonton'
    WHEN 'NU' THEN 'America/Iqaluit'
    ELSE NULL END;
$fn$;

COMMENT ON FUNCTION public.tz_from_us_ca_geography(text, text, numeric, numeric) IS
  'IANA zone from (state, lat, lon) for US and Canada. Needed because TEvo omits venue.time_zone on roughly 39% of events -- measured at 1,057 of 2,701 sampled, so this is the API''s behaviour and not a drain defect. Longitude is consulted only for the states and provinces a single zone cannot describe; everywhere else the state IS the zone. Returns NULL for anything unrecognised rather than guessing (mig 20260915240000).';

CREATE OR REPLACE FUNCTION public.venue_timezone_fill_from_geography(p_apply boolean DEFAULT false)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE v_written int := 0; v_check jsonb; v_cand int;
BEGIN
  IF current_user NOT IN ('service_role','postgres','supabase_admin') THEN
    RAISE EXCEPTION 'venue_timezone_fill_from_geography: caller % not authorized', current_user
      USING ERRCODE='42501';
  END IF;
  PERFORM set_config('statement_timeout', '300000', true);

  -- SELF-CHECK FIRST, on venues whose zone is already known from a stronger source. A derivation
  -- rule nobody scored is a guess with a schema. This scores it against 2,500+ venues that TEvo,
  -- TickPick, tickets.dev or the SeatGeek fit already settled, BEFORE writing anything.
  SELECT jsonb_build_object(
           'checked', count(*),
           'agree',   count(*) FILTER (WHERE t.iana_tz = g.tz),
           'differ',  count(*) FILTER (WHERE t.iana_tz <> g.tz),
           'same_offset_today', count(*) FILTER (WHERE t.iana_tz <> g.tz
             AND (now() AT TIME ZONE t.iana_tz) = (now() AT TIME ZONE g.tz)),
           'disagreements', (SELECT jsonb_agg(x) FROM (
               SELECT va2.state, t2.iana_tz AS known, g2.tz AS derived, count(*) AS n
                 FROM public.venue_timezone t2
                 JOIN public.venue_assets va2 ON va2.tevo_venue_id = t2.tevo_venue_id
                 CROSS JOIN LATERAL (SELECT public.tz_from_us_ca_geography(
                          va2.country, va2.state, va2.latitude, va2.longitude) AS tz) g2
                WHERE g2.tz IS NOT NULL AND t2.iana_tz IS NOT NULL AND t2.iana_tz <> g2.tz
                  AND (now() AT TIME ZONE t2.iana_tz) <> (now() AT TIME ZONE g2.tz)
                GROUP BY 1,2,3 ORDER BY 4 DESC LIMIT 12) x))
    INTO v_check
    FROM public.venue_timezone t
    JOIN public.venue_assets va ON va.tevo_venue_id = t.tevo_venue_id
    CROSS JOIN LATERAL (SELECT public.tz_from_us_ca_geography(
             va.country, va.state, va.latitude, va.longitude) AS tz) g
   WHERE g.tz IS NOT NULL AND t.iana_tz IS NOT NULL;

  DROP TABLE IF EXISTS _fillz;
  CREATE TEMP TABLE _fillz ON COMMIT DROP AS
  SELECT va.tevo_venue_id, va.venue_name, g.tz
    FROM public.venue_assets va
    CROSS JOIN LATERAL (SELECT public.tz_from_us_ca_geography(
             va.country, va.state, va.latitude, va.longitude) AS tz) g
   WHERE g.tz IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM public.venue_timezone t
                      WHERE t.tevo_venue_id = va.tevo_venue_id AND t.iana_tz IS NOT NULL);
  SELECT count(*) INTO v_cand FROM _fillz;

  IF p_apply THEN
    -- FILL ONLY. venue_timezone's standing rule is that a single weak observation never
    -- overwrites a derived zone, and geography is the weakest source in the table.
    INSERT INTO public.venue_timezone
      (tevo_venue_id, iana_tz, source, observations, distinct_offsets, venue_name, derived_at)
    SELECT f.tevo_venue_id, f.tz, 'geography', 0, 0, f.venue_name, now()
      FROM _fillz f
    ON CONFLICT (tevo_venue_id) DO UPDATE SET
      iana_tz    = coalesce(public.venue_timezone.iana_tz, EXCLUDED.iana_tz),
      source     = CASE WHEN public.venue_timezone.iana_tz IS NULL
                        THEN 'geography' ELSE public.venue_timezone.source END,
      venue_name = coalesce(public.venue_timezone.venue_name, EXCLUDED.venue_name);
    GET DIAGNOSTICS v_written = ROW_COUNT;
  END IF;

  RETURN jsonb_build_object(
    'applied', p_apply, 'candidates', v_cand, 'written', v_written,
    'self_check_against_known_zones', v_check);
END $fn$;

REVOKE ALL ON FUNCTION public.venue_timezone_fill_from_geography(boolean) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.venue_timezone_fill_from_geography(boolean) TO service_role;

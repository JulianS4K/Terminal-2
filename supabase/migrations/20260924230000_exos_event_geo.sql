-- ============================================================================
-- Migration 20260924230000 — Exos (Bridge / D4): venue coordinates for maps
--
-- Lane:     d4 (exos / bridge ticketing infra)
-- Touches:  W: TABLE exos_event_geo (new), VIEW exos_public_event_geo (new),
--              FUNCTION exos_upsert_event_geo, exos_expire_event_geo, exos_event_geo_due (new)
--           R: exos_events
-- Pre-reqs: exos_events (20260520120000)
--
-- Roadmap item 7b, phase 1 of the Google Maps work (EXP docs/maps.md). The
-- exos-geocode edge function resolves an event's venue address with the
-- Geocoding API on the server (the key never reaches the browser) and stores
-- the result here; the map UI reads it through the public view.
--
-- Google's caching terms, enforced in the schema rather than by convention:
--   * lat/lng may be kept for at most 30 days, so the public view hides any
--     pair older than that, and exos_expire_event_geo() nulls them out (the
--     refresh cron calls it after re-geocoding what's due);
--   * the Place ID may be kept indefinitely, so it survives expiry and the
--     refresh re-geocodes by place_id (exact, and no re-parsing the address);
--   * no tiles or images are stored anywhere.
-- `query` is the normalized address that was geocoded; when an organizer
-- edits the venue, the edge function sees it changed and geocodes again.
--
-- Writes are service-role only (the edge function). Idempotent.
-- D4 authors; applying to prod is operator-gated.
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.exos_event_geo (
  event_id          uuid PRIMARY KEY REFERENCES public.exos_events (id) ON DELETE CASCADE,
  query             text NOT NULL CHECK (length(query) BETWEEN 1 AND 500),
  status            text NOT NULL CHECK (status IN ('ok', 'zero_results', 'error')),
  place_id          text CHECK (place_id IS NULL OR length(place_id) <= 512),
  lat               double precision CHECK (lat IS NULL OR lat BETWEEN -90 AND 90),
  lng               double precision CHECK (lng IS NULL OR lng BETWEEN -180 AND 180),
  formatted_address text CHECK (formatted_address IS NULL OR length(formatted_address) <= 500),
  error             text CHECK (error IS NULL OR length(error) <= 500),
  geocoded_at       timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now(),
  CHECK ((lat IS NULL) = (lng IS NULL))
);
CREATE INDEX IF NOT EXISTS exos_event_geo_geocoded_idx ON public.exos_event_geo (geocoded_at);

ALTER TABLE public.exos_event_geo ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.exos_event_geo FROM PUBLIC, anon, authenticated;
GRANT ALL ON public.exos_event_geo TO service_role;

-- Public read: published events only, coordinates only while fresh.
CREATE OR REPLACE VIEW public.exos_public_event_geo AS
  SELECT g.event_id, g.place_id, g.lat, g.lng, g.formatted_address, g.geocoded_at
  FROM public.exos_event_geo g
  JOIN public.exos_events e ON e.id = g.event_id
  WHERE e.status = 'published'
    AND g.status = 'ok'
    AND g.lat IS NOT NULL
    AND g.geocoded_at > now() - interval '30 days';
REVOKE ALL ON public.exos_public_event_geo FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.exos_public_event_geo TO anon, authenticated, service_role;

-- Record a geocode result (service role).
--   * A transient error (Google 5xx, quota, timeout) on the SAME address only
--     records the error: the pin and its geocoded_at stay, so the next daily
--     refresh retries and the view's 30-day filter still bounds the cache.
--     (Dropping the pin here would blank the map for ~25 days until the row
--     came due again.)
--   * A new address that fails, or any zero-results answer, clears the
--     coordinates so the map never shows a pin for the old place.
CREATE OR REPLACE FUNCTION public.exos_upsert_event_geo(
  p_event_id uuid,
  p_query text,
  p_status text,
  p_place_id text DEFAULT NULL,
  p_lat double precision DEFAULT NULL,
  p_lng double precision DEFAULT NULL,
  p_formatted_address text DEFAULT NULL,
  p_error text DEFAULT NULL
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF current_user NOT IN ('service_role', 'postgres', 'supabase_admin') THEN
    RAISE EXCEPTION 'exos_upsert_event_geo: service role only' USING ERRCODE = '42501';
  END IF;
  IF p_status = 'error' THEN
    UPDATE public.exos_event_geo
       SET error = left(p_error, 500), updated_at = now()
     WHERE event_id = p_event_id AND query = left(p_query, 500);
    IF FOUND THEN RETURN; END IF;
  END IF;
  INSERT INTO public.exos_event_geo AS g
    (event_id, query, status, place_id, lat, lng, formatted_address, error, geocoded_at, updated_at)
  VALUES (p_event_id, left(p_query, 500), p_status, p_place_id,
          CASE WHEN p_status = 'ok' THEN p_lat END, CASE WHEN p_status = 'ok' THEN p_lng END,
          left(p_formatted_address, 500), left(p_error, 500), now(), now())
  ON CONFLICT (event_id) DO UPDATE SET
    query             = EXCLUDED.query,
    status            = EXCLUDED.status,
    place_id          = COALESCE(EXCLUDED.place_id, CASE WHEN g.query = EXCLUDED.query THEN g.place_id END),
    lat               = EXCLUDED.lat,
    lng               = EXCLUDED.lng,
    formatted_address = COALESCE(EXCLUDED.formatted_address, CASE WHEN g.query = EXCLUDED.query THEN g.formatted_address END),
    error             = EXCLUDED.error,
    geocoded_at       = now(),
    updated_at        = now();
END $$;
REVOKE ALL ON FUNCTION public.exos_upsert_event_geo(uuid, text, text, text, double precision, double precision, text, text) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.exos_upsert_event_geo(uuid, text, text, text, double precision, double precision, text, text) TO service_role;

-- Rows the refresh should re-geocode: published or upcoming-ish events whose
-- lookup is older than p_days (default 25, leaving a margin before 30).
CREATE OR REPLACE FUNCTION public.exos_event_geo_due(p_days int DEFAULT 25, p_limit int DEFAULT 50)
RETURNS TABLE (event_id uuid, query text, place_id text)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT g.event_id, g.query, g.place_id
  FROM public.exos_event_geo g
  JOIN public.exos_events e ON e.id = g.event_id
  WHERE e.status = 'published'
    AND g.geocoded_at < now() - make_interval(days => greatest(1, least(29, coalesce(p_days, 25))))
  ORDER BY g.geocoded_at
  LIMIT greatest(1, least(500, coalesce(p_limit, 50)));
$$;
REVOKE ALL ON FUNCTION public.exos_event_geo_due(int, int) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.exos_event_geo_due(int, int) TO service_role;

-- Drop coordinates older than 30 days (Place IDs stay). Returns rows cleared.
CREATE OR REPLACE FUNCTION public.exos_expire_event_geo()
RETURNS int
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_n int;
BEGIN
  UPDATE public.exos_event_geo
     SET lat = NULL, lng = NULL, updated_at = now()
   WHERE lat IS NOT NULL AND geocoded_at <= now() - interval '30 days';
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n;
END $$;
REVOKE ALL ON FUNCTION public.exos_expire_event_geo() FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.exos_expire_event_geo() TO service_role;

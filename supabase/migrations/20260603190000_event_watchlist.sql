-- Migration 20260603190000 · lane:D0 (author) → A1 (apply) · writes:event_watchlist + RPCs event_watchlist_set/_set_alert/_list · reads:events · pre:20260603180000 · auth:operator-requested 2026-06-03
--
-- D0 — per-user event watchlist for the email-gated terminal. Users sign in with
-- Google OAuth; the JWT email is BOTH the row owner AND the alert recipient once
-- alerts ship ("unlock the logged-in email as the alert source"). RLS scopes
-- every row to its owner; writes go through SECDEF RPCs that stamp the email
-- server-side (clients never assert identity) and snapshot the event's name/date
-- so the home table renders without a heavy join on every read.
--
-- Surfaces: a ★ track toggle on event.html + the first table on the terminal
-- home (max 50 rows/page, client-paged). alert_enabled is per-event so a user
-- can mute one tracked event without un-tracking it.

CREATE TABLE IF NOT EXISTS public.event_watchlist (
  id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  user_email      text   NOT NULL,
  tevo_event_id   bigint NOT NULL,
  event_name      text,
  occurs_at_local text,                       -- snapshot (events.occurs_at_local is TEXT; PROJECT_BIBLE §3)
  venue_name      text,
  alert_enabled   boolean NOT NULL DEFAULT true,
  added_at        timestamptz NOT NULL DEFAULT now(),
  UNIQUE (user_email, tevo_event_id)
);
CREATE INDEX IF NOT EXISTS event_watchlist_user_idx ON public.event_watchlist(user_email, occurs_at_local);

ALTER TABLE public.event_watchlist ENABLE ROW LEVEL SECURITY;

-- Owner-scoped read (defense in depth — writes are SECDEF). The email gate keeps
-- it to the @s4kent google domain even if RLS GRANTs widen later.
DROP POLICY IF EXISTS event_watchlist_owner_sel ON public.event_watchlist;
CREATE POLICY event_watchlist_owner_sel ON public.event_watchlist
  FOR SELECT TO authenticated
  USING (user_email = lower(auth.jwt()->>'email')
         AND (auth.jwt()->>'email') LIKE '%@s4kent.com');

GRANT SELECT ON public.event_watchlist TO authenticated;

-- ── Helper: the caller's verified @s4kent email, or raise. ──────────────────
CREATE OR REPLACE FUNCTION public._wl_require_email()
RETURNS text
LANGUAGE plpgsql STABLE
AS $$
DECLARE v_email text;
BEGIN
  v_email := lower(coalesce(auth.jwt()->>'email', ''));
  IF v_email NOT LIKE '%@s4kent.com' THEN
    RAISE EXCEPTION 'forbidden: % is not an @s4kent.com email', v_email USING ERRCODE = '42501';
  END IF;
  RETURN v_email;
END;
$$;

-- ── Add / remove an event from the caller's watchlist. Returns the new state. ──
CREATE OR REPLACE FUNCTION public.event_watchlist_set(p_event_id bigint, p_on boolean)
RETURNS boolean
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_email text := public._wl_require_email();
BEGIN
  IF p_on THEN
    INSERT INTO public.event_watchlist (user_email, tevo_event_id, event_name, occurs_at_local, venue_name)
    SELECT v_email, e.id, e.name, e.occurs_at_local, e.venue_name
    FROM public.events e WHERE e.id = p_event_id
    ON CONFLICT (user_email, tevo_event_id) DO NOTHING;
    -- Event row missing (far-future / TEvo-only): still track by id so alerts work.
    INSERT INTO public.event_watchlist (user_email, tevo_event_id)
    SELECT v_email, p_event_id
    WHERE NOT EXISTS (SELECT 1 FROM public.events WHERE id = p_event_id)
    ON CONFLICT (user_email, tevo_event_id) DO NOTHING;
    RETURN true;
  ELSE
    DELETE FROM public.event_watchlist WHERE user_email = v_email AND tevo_event_id = p_event_id;
    RETURN false;
  END IF;
END;
$$;

-- ── Mute / unmute alerts for one tracked event (without un-tracking). ──────────
CREATE OR REPLACE FUNCTION public.event_watchlist_set_alert(p_event_id bigint, p_on boolean)
RETURNS boolean
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_email text := public._wl_require_email();
BEGIN
  UPDATE public.event_watchlist SET alert_enabled = p_on
  WHERE user_email = v_email AND tevo_event_id = p_event_id;
  RETURN p_on;
END;
$$;

-- ── List the caller's watchlist, joined fresh to events for current name/date,
--    soonest event first. Returns a jsonb array (the FE pages it client-side). ──
CREATE OR REPLACE FUNCTION public.event_watchlist_list()
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_email text := public._wl_require_email();
  v_rows jsonb;
BEGIN
  SELECT coalesce(jsonb_agg(r ORDER BY (r->>'occurs_at_local') ASC NULLS LAST, (r->>'added_at') DESC), '[]'::jsonb)
    INTO v_rows
  FROM (
    SELECT jsonb_build_object(
      'tevo_event_id',   w.tevo_event_id,
      'event_name',      coalesce(e.name, w.event_name),
      'occurs_at_local', coalesce(e.occurs_at_local, w.occurs_at_local),
      'venue_name',      coalesce(e.venue_name, w.venue_name),
      'venue_location',  e.venue_location,
      'performer',       e.primary_performer_name,
      'alert_enabled',   w.alert_enabled,
      'added_at',        w.added_at
    ) AS r
    FROM public.event_watchlist w
    LEFT JOIN public.events e ON e.id = w.tevo_event_id
    WHERE w.user_email = v_email
  ) q;

  RETURN jsonb_build_object('user_email', v_email, 'count', jsonb_array_length(v_rows), 'items', v_rows);
END;
$$;

REVOKE ALL ON FUNCTION public.event_watchlist_set(bigint, boolean)       FROM PUBLIC;
REVOKE ALL ON FUNCTION public.event_watchlist_set_alert(bigint, boolean) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.event_watchlist_list()                     FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.event_watchlist_set(bigint, boolean)       TO authenticated;
GRANT EXECUTE ON FUNCTION public.event_watchlist_set_alert(bigint, boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.event_watchlist_list()                     TO authenticated;

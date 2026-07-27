-- Security remediation (2026-06-06): close two live exposures surfaced by the
-- security advisor + a direct grant audit.
--
-- (A) RLS was disabled on six public tables that ALSO carry the default
--     GRANT ALL TO anon, authenticated. With RLS off, an anon caller could
--     SELECT/INSERT/UPDATE/DELETE/TRUNCATE these tables via PostgREST.
--     Enabling RLS gates the grants; service_role and SECURITY DEFINER owner
--     functions bypass RLS, so cron + the data pipeline are unaffected. We
--     preserve authenticated (@s4kent.com staff) read access via an explicit
--     SELECT policy to match current behavior; no anon access, no client writes.
--
-- (B) anon held EXECUTE on four data-mutating SECURITY DEFINER RPCs
--     (create_user_alert / delete_user_alert / event_watchlist_set /
--     event_watchlist_set_alert). An unauthenticated caller could create or
--     delete user alerts and toggle watchlist rows. Revoke anon + PUBLIC;
--     keep authenticated.

-- ---- (A) Enable RLS + staff SELECT policy on the six tables ----
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY[
    'performer_metrics_daily','venue_metrics_daily','wc_price_daily',
    'event_xref_cleanup_archive_20260606','evo_only_patterns','td_sg_performers'
  ] LOOP
    EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format('DROP POLICY IF EXISTS %1$I_authenticated_select ON public.%1$I', t);
    EXECUTE format(
      'CREATE POLICY %1$I_authenticated_select ON public.%1$I '
      'FOR SELECT TO authenticated USING (true)', t);
  END LOOP;
END $$;

-- ---- (B) Revoke anon/PUBLIC EXECUTE on the four mutating RPCs ----
REVOKE EXECUTE ON FUNCTION public.create_user_alert(
  text, bigint, text, text, numeric, jsonb, text[], text, text, integer, text, timestamptz
) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.create_user_alert(
  text, bigint, text, text, numeric, jsonb, text[], text, text, integer, text, timestamptz
) TO authenticated;

REVOKE EXECUTE ON FUNCTION public.delete_user_alert(bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.delete_user_alert(bigint) TO authenticated;

REVOKE EXECUTE ON FUNCTION public.event_watchlist_set(bigint, boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.event_watchlist_set(bigint, boolean) TO authenticated;

REVOKE EXECUTE ON FUNCTION public.event_watchlist_set_alert(bigint, boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.event_watchlist_set_alert(bigint, boolean) TO authenticated;

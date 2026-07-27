-- Grant authenticated users SELECT on event_listing_snapshot_daily
-- Required for loadTdFreshness() in event.js (direct Supabase client query)
-- Pattern matches other broker tables: @s4kent.com gate via RLS

GRANT SELECT ON public.event_listing_snapshot_daily TO authenticated;

-- Drop service_role_all (qual=true = any service_role query, no user gate)
-- and replace with two explicit policies
DROP POLICY IF EXISTS "service_role_all" ON public.event_listing_snapshot_daily;

-- Service role: full access for cron writes
CREATE POLICY "service_role_all"
  ON public.event_listing_snapshot_daily
  FOR ALL
  TO service_role
  USING (true)
  WITH CHECK (true);

-- Authenticated broker users: read-only, @s4kent.com gate
CREATE POLICY "s4k_broker_select"
  ON public.event_listing_snapshot_daily
  FOR SELECT
  TO authenticated
  USING (auth.email() LIKE '%@s4kent.com');

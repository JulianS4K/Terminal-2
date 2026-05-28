-- Grant authenticated users SELECT on ticketsdata_listings_snapshots
-- Required for loadTdMarketsListings() in event.js (direct Supabase client query)
-- Pattern matches migration 20260527270000 (event_listing_snapshot_daily broker access)

GRANT SELECT ON public.ticketsdata_listings_snapshots TO authenticated;

-- Keep service_role policy intact (re-create explicitly)
DROP POLICY IF EXISTS "td_ls_service_only" ON public.ticketsdata_listings_snapshots;
CREATE POLICY "td_ls_service_only"
  ON public.ticketsdata_listings_snapshots
  FOR ALL
  TO service_role
  USING (true)
  WITH CHECK (true);

-- Authenticated broker users: read-only, @s4kent.com gate
CREATE POLICY "s4k_broker_select"
  ON public.ticketsdata_listings_snapshots
  FOR SELECT
  TO authenticated
  USING (auth.email() LIKE '%@s4kent.com');

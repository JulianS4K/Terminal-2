-- ============================================================================
-- Migration 20260622210000 — exos_public_* views: security_invoker + scoped anon
--
-- Lane:     D4 surface / A1 applies (DB-layer security — exos_* RLS)
-- Touches:  exos_public_orgs / exos_public_events / exos_public_tiers (ALTER VIEW
--           security_invoker=true) + column-scoped anon GRANTs + anon/auth
--           published-read RLS policies on exos_orgs / exos_events / exos_ticket_tiers
-- Pre-reqs: none
--
-- ⚠ AUTHORING-ONLY — REQUIRES D4 + A1 REVIEW BEFORE APPLY. This touches the
--   public storefront read boundary; a wrong scope either breaks the public site
--   (anon reads 0 rows) or over-exposes private columns. Apply only after D4
--   confirms the public column/row scope below matches product intent, then
--   verify the public storefront still lists orgs/events/tiers.
--
-- WHY (2026-06-22 audit / security advisor `security_definer_view` ERROR ×3):
--   exos_public_{orgs,events,tiers} were SECURITY DEFINER (run as owner, bypass
--   RLS) and anon-readable — the 3 ERRORs left after the AXS lockdown
--   (20260622180000) deliberately deferred them as D4-owned. The fix is
--   security_invoker=true (advisor convention), but anon currently has NO
--   base-table grant (it reads only the views), so a bare flip returns 0 rows.
--
-- DESIGN — restore EXACTLY the views' public scope under invoker:
--   • COLUMN-level anon GRANT = only the columns each view already exposes (so a
--     direct anon base-table query can't read private columns like exos_orgs.
--     owner_uid). `status`/`visibility` are added only where a view's WHERE needs
--     them; the published/public RLS policy means anon only ever sees rows where
--     those equal 'published'/'public', so reading them leaks nothing.
--   • RLS policy (TO anon, authenticated) = each view's row filter, so a logged-in
--     user browsing the public storefront still sees other orgs' published events
--     (the definer view did this before; their owner/staff policies are additive).
--   View column/row scope verified against pg_get_viewdef 2026-06-22.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- exos_public_orgs — all orgs, public columns only
-- ---------------------------------------------------------------------------
ALTER VIEW public.exos_public_orgs SET (security_invoker = true);
GRANT SELECT (id, name, slug, theme, description, followers_count, marketing)
  ON public.exos_orgs TO anon;
DROP POLICY IF EXISTS exos_orgs_public_read ON public.exos_orgs;
CREATE POLICY exos_orgs_public_read ON public.exos_orgs
  FOR SELECT TO anon, authenticated
  USING (true);

-- ---------------------------------------------------------------------------
-- exos_public_events — published events, public columns only (+ status for the filter)
-- ---------------------------------------------------------------------------
ALTER VIEW public.exos_public_events SET (security_invoker = true);
GRANT SELECT (id, org_id, name, slug, description, occurs_at_local, starts_at,
              doors_at, ends_at, timezone, currency, venue_name, venue_location,
              venue_address, primary_performer_name, performer_names, event_type,
              category, genres, subgenres, image_url, branding, purchase_limits,
              total_tickets, tickets_sold, status)
  ON public.exos_events TO anon;
DROP POLICY IF EXISTS exos_events_public_read ON public.exos_events;
CREATE POLICY exos_events_public_read ON public.exos_events
  FOR SELECT TO anon, authenticated
  USING (status = 'published');

-- ---------------------------------------------------------------------------
-- exos_public_tiers — public tiers of published events, public columns only
--   (+ visibility for the filter). The event-published constraint is enforced
--   both by the view's JOIN (runs as caller now) and by the EXISTS below so a
--   direct anon query on the table can't read tiers of an unpublished event.
-- ---------------------------------------------------------------------------
ALTER VIEW public.exos_public_tiers SET (security_invoker = true);
GRANT SELECT (id, event_id, name, description, price, capacity, sold,
              ticket_type, sales_start, sales_end, sort_order, visibility)
  ON public.exos_ticket_tiers TO anon;
DROP POLICY IF EXISTS exos_tiers_public_read ON public.exos_ticket_tiers;
CREATE POLICY exos_tiers_public_read ON public.exos_ticket_tiers
  FOR SELECT TO anon, authenticated
  USING (
    visibility = 'public'
    AND EXISTS (SELECT 1 FROM public.exos_events e
                WHERE e.id = event_id AND e.status = 'published')
  );

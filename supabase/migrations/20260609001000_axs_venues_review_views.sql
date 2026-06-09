-- Convenience views over public.axs_venues (the AXS.com primary-ticketer list).
-- v_axs_venues_mapped   — AXS venues exact-linked to a canonical venue (+ canon detail)
-- v_axs_venues_unmapped — AXS venues with no exact canonical match ("review later")

CREATE OR REPLACE VIEW public.v_axs_venues_mapped AS
SELECT a.axs_name, a.tevo_venue_id, a.matched_name,
       v.tevo_venue_name, v.tevo_city, v.tevo_state
FROM public.axs_venues a
JOIN public.v_canonical_venue v ON v.tevo_venue_id = a.tevo_venue_id
WHERE a.match_method = 'exact_norm';

CREATE OR REPLACE VIEW public.v_axs_venues_unmapped AS
SELECT a.axs_name, a.section
FROM public.axs_venues a
WHERE a.tevo_venue_id IS NULL
ORDER BY a.section, lower(a.axs_name);

COMMENT ON VIEW public.v_axs_venues_unmapped IS
  'AXS.com venues not exact-matched to a canonical venue (review-later list). Source: public.axs_venues.';

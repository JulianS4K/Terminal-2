-- Cowork migration. Captured into git by code (auditor) on 2026-05-08.
-- Originally applied to prod 2026-05-08 02:02 UTC.

CREATE OR REPLACE FUNCTION classify_performer_categories(
  p_cat text, p_parent text, p_grand text
) RETURNS TABLE(top_category text, genre text, event_type text)
LANGUAGE sql IMMUTABLE AS $$
  SELECT
    map_tevo_top_category(p_cat, p_parent, p_grand) AS top_category,
    map_tevo_category_to_genre(p_cat, p_parent) AS genre,
    map_top_category_to_event_type(map_tevo_top_category(p_cat, p_parent, p_grand)) AS event_type;
$$;
GRANT EXECUTE ON FUNCTION classify_performer_categories(text,text,text) TO authenticated, service_role;

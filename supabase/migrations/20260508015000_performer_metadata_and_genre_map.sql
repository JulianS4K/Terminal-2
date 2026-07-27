-- Cowork migration. Captured into git by code (auditor) on 2026-05-08.
-- Originally applied to prod 2026-05-08 02:01 UTC.
--
-- Cache TEvo performer metadata + derive a normalized genre + top_category.

CREATE TABLE IF NOT EXISTS performer_metadata (
  performer_id          bigint PRIMARY KEY,
  name                  text,
  slug                  text,
  popularity_score      numeric,
  keywords              text,
  category_id           text,
  category_name         text,
  parent_category_name  text,
  top_category_name     text,
  what_event_type       text,
  genre                 text,
  upcoming_first        timestamptz,
  upcoming_last         timestamptz,
  raw                   jsonb,
  fetched_at            timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS performer_metadata_genre_idx     ON performer_metadata (genre)         WHERE genre IS NOT NULL;
CREATE INDEX IF NOT EXISTS performer_metadata_what_idx      ON performer_metadata (what_event_type);
CREATE INDEX IF NOT EXISTS performer_metadata_top_cat_idx   ON performer_metadata (top_category_name);
CREATE INDEX IF NOT EXISTS performer_metadata_popularity_idx ON performer_metadata (popularity_score DESC NULLS LAST);

CREATE OR REPLACE FUNCTION map_tevo_category_to_genre(p_cat_name text, p_parent text DEFAULT NULL)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE
    WHEN p_cat_name IS NULL THEN NULL
    WHEN lower(p_cat_name) IN ('rock & pop','rock','pop','alternative','indie','indie rock') THEN 'rock'
    WHEN lower(p_cat_name) IN ('hard rock/metal','metal','heavy metal','punk') THEN 'metal'
    WHEN lower(p_cat_name) IN ('country') THEN 'country'
    WHEN lower(p_cat_name) IN ('hip hop/rap','hip-hop','rap') THEN 'hip-hop'
    WHEN lower(p_cat_name) IN ('r&b/urban soul','rnb','r&b','soul','urban') THEN 'rnb'
    WHEN lower(p_cat_name) IN ('jazz','blues') THEN 'jazz'
    WHEN lower(p_cat_name) IN ('electronic','dance','edm','house','techno','dubstep') THEN 'edm'
    WHEN lower(p_cat_name) IN ('latin','reggaeton','salsa','bachata','merengue') THEN 'latin'
    WHEN lower(p_cat_name) IN ('k-pop','j-pop','asian') THEN 'k-pop'
    WHEN lower(p_cat_name) IN ('classical','symphony','orchestra') THEN 'classical'
    WHEN lower(p_cat_name) IN ('reggae','world','folk','americana','bluegrass','singer/songwriter') THEN 'folk-world'
    WHEN lower(p_cat_name) LIKE '%comedy%' OR lower(p_cat_name) IN ('comedians','stand-up') THEN 'comedy'
    WHEN lower(p_cat_name) IN ('opera') THEN 'opera'
    WHEN lower(p_cat_name) IN ('musical','musicals','broadway') OR lower(p_parent) = 'broadway' THEN 'broadway'
    WHEN lower(p_cat_name) IN ('plays','play','theater','theatre') THEN 'theater'
    WHEN lower(p_cat_name) IN ('dance','ballet') THEN 'dance'
    WHEN lower(p_cat_name) IN ('family','kids','disney','circus','ice show','monster trucks') THEN 'family'
    WHEN lower(p_cat_name) IN ('festivals','festival') THEN 'festival'
    ELSE NULL
  END;
$$;

CREATE OR REPLACE FUNCTION map_tevo_top_category(p_cat_name text, p_parent text, p_grandparent text)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT COALESCE(
    CASE WHEN lower(coalesce(p_grandparent,'')) = 'sports'  THEN 'Sports' END,
    CASE WHEN lower(coalesce(p_parent,''))      = 'sports'  THEN 'Sports' END,
    CASE WHEN lower(coalesce(p_cat_name,''))    = 'sports'  THEN 'Sports' END,
    CASE WHEN lower(coalesce(p_grandparent,'')) = 'concerts' THEN 'Concerts' END,
    CASE WHEN lower(coalesce(p_parent,''))      = 'concerts' THEN 'Concerts' END,
    CASE WHEN lower(coalesce(p_cat_name,''))    = 'concerts' THEN 'Concerts' END,
    CASE WHEN lower(coalesce(p_grandparent,'')) IN ('comedy','comedians')   THEN 'Comedy' END,
    CASE WHEN lower(coalesce(p_parent,''))      IN ('comedy','comedians')   THEN 'Comedy' END,
    CASE WHEN lower(coalesce(p_cat_name,''))    IN ('comedy','comedians')   THEN 'Comedy' END,
    CASE WHEN lower(coalesce(p_grandparent,'')) IN ('theater','theatre')    THEN 'Theater' END,
    CASE WHEN lower(coalesce(p_parent,''))      IN ('theater','theatre')    THEN 'Theater' END,
    CASE WHEN lower(coalesce(p_cat_name,''))    IN ('theater','theatre')    THEN 'Theater' END,
    CASE WHEN lower(coalesce(p_parent,''))      IN ('family','kids')        THEN 'Family' END,
    CASE WHEN lower(coalesce(p_cat_name,''))    IN ('family','kids')        THEN 'Family' END
  );
$$;

CREATE OR REPLACE FUNCTION map_top_category_to_event_type(p_top text)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE p_top
    WHEN 'Sports'   THEN 'game'
    WHEN 'Concerts' THEN 'concert'
    WHEN 'Comedy'   THEN 'comedy'
    WHEN 'Theater'  THEN 'show'
    WHEN 'Family'   THEN 'family'
    ELSE NULL
  END;
$$;

GRANT SELECT ON performer_metadata TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION map_tevo_category_to_genre(text, text),
                          map_tevo_top_category(text, text, text),
                          map_top_category_to_event_type(text)
  TO authenticated, service_role;

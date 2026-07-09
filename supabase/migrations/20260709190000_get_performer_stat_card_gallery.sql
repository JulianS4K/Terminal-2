-- Migration 20260709190000 · lane:D0 (author) → A1 (apply) · writes:get_performer_stat_card_gallery · reads:performer_stat_card · pre:performer_stat_card (mig 20260709140000) · auth:OPERATOR-APPROVAL REQUIRED before apply_migration (creates a SECDEF read RPC; no DML)
--
-- D0 — performer stat-card GALLERY read for the redesigned performer landing.
--
-- Powers the card-gallery view (searchable/sortable grid of performer stat-cards
-- + compare basket) that replaces the old league-directory index. Returns full
-- cards (to_jsonb) so the gallery and the fold-in compare table share one shape.
-- Search = name ILIKE; sort = notional | market | owned | getin (cheapest) |
-- movers (30d %). @s4kent.com-gated SECDEF, capped at 200.

CREATE OR REPLACE FUNCTION public.get_performer_stat_card_gallery(
  p_search text    DEFAULT NULL,
  p_sort   text    DEFAULT 'notional',
  p_limit  integer DEFAULT 60,
  p_sports_only boolean DEFAULT false
)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, extensions, pg_temp
AS $func$
DECLARE
  v_email text;
  v_result jsonb;
BEGIN
  v_email := coalesce(auth.jwt()->>'email', '');
  IF v_email NOT LIKE '%@s4kent.com' THEN
    RAISE EXCEPTION 'forbidden: % is not an @s4kent.com email', v_email USING ERRCODE = '42501';
  END IF;

  WITH base AS (
    SELECT s.*,
      CASE p_sort
        WHEN 'market'  THEN s.market_tickets::numeric
        WHEN 'owned'   THEN s.owned_tickets::numeric
        WHEN 'getin'   THEN -coalesce(s.getin_median, 1e12)   -- cheapest get-in first
        WHEN 'movers'  THEN coalesce(s.price_d30_pct, -1e9)
        ELSE coalesce(s.owned_book_notional, 0)
      END AS sortval
    FROM public.performer_stat_card s
    WHERE (p_search IS NULL OR s.performer_name ILIKE '%'||p_search||'%')
      AND (NOT p_sports_only OR s.is_sports)
  ),
  top AS (
    SELECT * FROM base ORDER BY sortval DESC NULLS LAST LIMIT greatest(1, least(coalesce(p_limit,60), 200))
  )
  SELECT coalesce(jsonb_agg((to_jsonb(top) - 'sortval') ORDER BY top.sortval DESC NULLS LAST), '[]'::jsonb)
  INTO v_result FROM top;

  RETURN v_result;
END;
$func$;

REVOKE ALL ON FUNCTION public.get_performer_stat_card_gallery(text, text, integer, boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_performer_stat_card_gallery(text, text, integer, boolean) TO anon, authenticated;

COMMENT ON FUNCTION public.get_performer_stat_card_gallery(text, text, integer, boolean) IS
  'D0 performer stat-card gallery: searchable/sortable grid of performer_stat_card rows (notional|market|owned|getin|movers). @s4kent.com-gated SECDEF read.';

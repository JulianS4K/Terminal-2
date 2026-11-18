-- predict_event_clearing_price: per-game sold-to-ask ratio.
--
-- The ask signal (s_ask = base_ask * ratio) used one category-wide
-- sold_to_ask_ratio (~0.62 for sports). Sections with their own realized
-- sales were then pulled well under what they actually cleared at
-- (e.g. Nets sec 225: forecast $197 vs $259 realized). Once a section has
-- >= 3 realized sales, blend its own ratio (realized median / section ask,
-- clamped 0.3-1.5) with the category ratio, weighted n/(n+4) — the same
-- shrinkage the realized signal already uses. Below 3 sales nothing changes.
-- Output adds 'sold_to_ask_ratio_used'. Idempotent; asserts each fragment.
SET LOCAL lock_timeout = '10s';

DO $patch$
DECLARE
  v_def   text := pg_get_functiondef('public.predict_event_clearing_price(bigint,text)'::regprocedure);
  v_ratio text := '(CASE WHEN realized_n >= 3 AND section_ask > 0 AND realized_med IS NOT NULL'
               || ' THEN (realized_n * greatest(0.3, least(1.5, realized_med / section_ask))'
               || ' + 4 * coalesce(ratio, realized_med / section_ask)) / (realized_n + 4) ELSE ratio END)';
BEGIN
  IF position('sold_to_ask_ratio_used' in v_def) > 0 THEN
    RAISE NOTICE 'predict_event_clearing_price already has per-game ratio';
    RETURN;
  END IF;
  IF position('CASE WHEN base_ask IS NOT NULL AND ratio IS NOT NULL THEN base_ask * ratio END AS s_ask,' in v_def) = 0
     OR position($o$'sold_to_ask_ratio', ratio,$o$ in v_def) = 0 THEN
    RAISE EXCEPTION 'predict_event_clearing_price patch: fragment not found';
  END IF;
  v_def := replace(v_def,
    'CASE WHEN base_ask IS NOT NULL AND ratio IS NOT NULL THEN base_ask * ratio END AS s_ask,',
    'CASE WHEN base_ask IS NOT NULL AND ratio IS NOT NULL THEN base_ask * ' || v_ratio || ' END AS s_ask,');
  v_def := replace(v_def, $o$'sold_to_ask_ratio', ratio,$o$,
    $n$'sold_to_ask_ratio', ratio, 'sold_to_ask_ratio_used', round($n$ || v_ratio || $n$::numeric, 3),$n$);
  EXECUTE v_def;
END $patch$;

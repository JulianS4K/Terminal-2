-- The other half of the operator's distinction (2026-11-28): "differenciate from some seats
-- being non-transferrable and an entire event being untransferrable".
--
-- mig 20261128005000 made the EVENT-level rule whole-event only, so a mixed event is no longer
-- retired. This handles the mixed event properly: delivery_methods entries carry an offer_id,
-- and every listing carries its own offer_id, so the seats sold under a non-transferable offer
-- are dropped while the rest of the event keeps publishing.
--
-- Dropped rather than flagged, because the CRM feed has no transferability field -- the same
-- reasoning as mig 20261127250000, where the operator asked for non-transferable events to
-- leave the API rather than appear with a reason a consumer might not read.

DO $surgery$
DECLARE
  src text := pg_get_functiondef('public.axs_watch_parse(jsonb)'::regprocedure);
  old_tail CONSTANT text :=
    '           l->>''offer_id'' AS offer_id' || E'\n' ||
    '      FROM raw),';
  new_tail CONSTANT text :=
    '           l->>''offer_id'' AS offer_id' || E'\n' ||
    '      FROM raw' || E'\n' ||
    '     -- mig 20261128010000: seats sold under an offer whose delivery is non-transferable' || E'\n' ||
    '     -- cannot be resold, so they are not inventory even when the rest of the event is fine' || E'\n' ||
    '     WHERE coalesce(l->>''offer_id'', '''') <> ALL (public.axs_watch_nontransferable_offers(p_body))),';
  n int;
BEGIN
  IF position('axs_watch_nontransferable_offers' in src) > 0 THEN
    RAISE NOTICE 'the parse already drops non-transferable offers; nothing to do';
    RETURN;
  END IF;
  n := (length(src) - length(replace(src, old_tail, ''))) / length(old_tail);
  IF n <> 1 THEN
    RAISE EXCEPTION 'parse rows-CTE anchor matched % times, expected 1', n;
  END IF;
  EXECUTE replace(src, old_tail, new_tail);
END $surgery$;

DO $verify$
DECLARE
  body jsonb := jsonb_build_object(
    'delivery_methods', jsonb_build_array(
      jsonb_build_object('label','AXS Mobile ID','offer_id','OK1'),
      jsonb_build_object('label','AXS Mobile ID - Free (Non-Transferable)','offer_id','BAD1')),
    'listings', jsonb_build_array(
      jsonb_build_object('kind','primary','status','Open','section','A','row','1',
        'seats', jsonb_build_array('1','2'), 'quantity',2, 'offer_id','OK1',
        'pricing', jsonb_build_object('face',50,'fees_total',10,'all_in',60)),
      jsonb_build_object('kind','primary','status','Open','section','B','row','2',
        'seats', jsonb_build_array('3','4'), 'quantity',2, 'offer_id','BAD1',
        'pricing', jsonb_build_object('face',70,'fees_total',10,'all_in',80))));
  parsed jsonb;
BEGIN
  parsed := public.axs_watch_parse(body);
  IF jsonb_array_length(parsed->'listings') <> 1 THEN
    RAISE EXCEPTION 'expected 1 listing to survive, got %', jsonb_array_length(parsed->'listings');
  END IF;
  IF parsed->'listings'->0->>'section' <> 'A' THEN
    RAISE EXCEPTION 'the wrong listing survived: %', parsed->'listings'->0->>'section';
  END IF;
  parsed := public.axs_watch_parse(jsonb_set(body, '{delivery_methods}', jsonb_build_array(
    jsonb_build_object('label','AXS Mobile ID','offer_id','OK1'),
    jsonb_build_object('label','AXS Mobile ID','offer_id','BAD1'))));
  IF jsonb_array_length(parsed->'listings') <> 2 THEN
    RAISE EXCEPTION 'a fully transferable event must keep both listings, got %',
      jsonb_array_length(parsed->'listings');
  END IF;
END $verify$;

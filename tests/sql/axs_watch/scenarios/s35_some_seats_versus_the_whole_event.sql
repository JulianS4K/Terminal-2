-- Operator 2026-11-28: "differenciate from some seats being non-transferrable and an entire
-- event being untransferrable".
--
-- The first cut (mig 20261127240000) retired an event if ANY delivery method said
-- non-transferable. But delivery_methods entries each carry their own offer_id -- the
-- Trans-Siberian capture has five, one per offer -- so that label describes ONE OFFER. On the
-- loose rule the settle retired 27 events in 40 minutes, including "Houston Rockets vs.
-- Memphis Grizzlies" at Toyota Center, a regular-season NBA game.
--
--   whole event   description says so, or EVERY delivery method is non-transferable -> retire
--   some seats    only some offers          -> keep the event, drop only those offers' seats
\set QUIET on
\pset footer off
\pset null '-'
SET client_min_messages = warning;

\echo '--- A. the whole event: every delivery method, or the description'
SELECT public.axs_watch_non_transferable(jsonb_build_object('delivery_methods',
         jsonb_build_array(jsonb_build_object('label','AXS Mobile ID - Free (Non-Transferable)',
                                              'offer_id','1')))) AS every_method,
       public.axs_watch_non_transferable(jsonb_build_object(
         'event', jsonb_build_object('description','TICKETS FOR THIS EVENT ARE NON-TRANSFERABLE.'),
         'delivery_methods', jsonb_build_array(
           jsonb_build_object('label','AXS Mobile ID','offer_id','1')))) AS description_wins;

\echo '--- B. some seats only: the event is NOT retired'
SELECT public.axs_watch_non_transferable(jsonb_build_object('delivery_methods',
         jsonb_build_array(jsonb_build_object('label','AXS Mobile ID','offer_id','1'),
                           jsonb_build_object('label','AXS Mobile ID - Free (Non-Transferable)',
                                              'offer_id','2')))) AS mixed_event_retired,
       public.axs_watch_nontransferable_offers(jsonb_build_object('delivery_methods',
         jsonb_build_array(jsonb_build_object('label','AXS Mobile ID','offer_id','1'),
                           jsonb_build_object('label','AXS Mobile ID - Free (Non-Transferable)',
                                              'offer_id','2')))) AS offers_to_drop;

\echo '--- C. and the parse drops exactly those seats, keeping the rest'
WITH body AS (
  SELECT jsonb_build_object(
    'delivery_methods', jsonb_build_array(
      jsonb_build_object('label','AXS Mobile ID','offer_id','OK1'),
      jsonb_build_object('label','AXS Mobile ID - Free (Non-Transferable)','offer_id','BAD1')),
    'listings', jsonb_build_array(
      jsonb_build_object('kind','primary','status','Open','section','A','row','1',
        'seats', jsonb_build_array('1','2'),'quantity',2,'offer_id','OK1',
        'pricing', jsonb_build_object('face',50,'fees_total',10,'all_in',60)),
      jsonb_build_object('kind','primary','status','Open','section','B','row','2',
        'seats', jsonb_build_array('3','4'),'quantity',2,'offer_id','BAD1',
        'pricing', jsonb_build_object('face',70,'fees_total',10,'all_in',80)))) AS b)
SELECT jsonb_array_length(p->'listings') AS kept,
       p->'listings'->0->>'section' AS section_kept,
       p->'price_min' AS price_min, p->'price_max' AS price_max
  FROM (SELECT public.axs_watch_parse(b) p FROM body) x;

\echo '--- D. a fully transferable event loses nothing'
WITH body AS (
  SELECT jsonb_build_object(
    'delivery_methods', jsonb_build_array(
      jsonb_build_object('label','AXS Mobile ID','offer_id','OK1'),
      jsonb_build_object('label','AXS Mobile ID','offer_id','OK2')),
    'listings', jsonb_build_array(
      jsonb_build_object('kind','primary','status','Open','section','A','row','1',
        'seats', jsonb_build_array('1','2'),'quantity',2,'offer_id','OK1',
        'pricing', jsonb_build_object('face',50,'fees_total',10,'all_in',60)),
      jsonb_build_object('kind','primary','status','Open','section','B','row','2',
        'seats', jsonb_build_array('3','4'),'quantity',2,'offer_id','OK2',
        'pricing', jsonb_build_object('face',70,'fees_total',10,'all_in',80)))) AS b)
SELECT jsonb_array_length((public.axs_watch_parse(b))->'listings') AS kept FROM body;

\echo '--- E. a listing with no offer_id is never dropped by attribution we do not have'
WITH body AS (
  SELECT jsonb_build_object(
    'delivery_methods', jsonb_build_array(
      jsonb_build_object('label','AXS Mobile ID - Free (Non-Transferable)','offer_id','BAD1')),
    'listings', jsonb_build_array(
      jsonb_build_object('kind','primary','status','Open','section','C','row','9',
        'seats', jsonb_build_array('1'),'quantity',1,
        'pricing', jsonb_build_object('face',40,'fees_total',5,'all_in',45)))) AS b)
SELECT jsonb_array_length((public.axs_watch_parse(b))->'listings') AS kept FROM body;

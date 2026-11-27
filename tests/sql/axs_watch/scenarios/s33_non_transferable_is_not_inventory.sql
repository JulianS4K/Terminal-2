-- Amy Grant & Vince Gill at the Ryman: "TICKETS FOR THIS EVENT ARE NON-TRANSFERABLE UNDER ANY
-- CIRCUMSTANCE. RESALE WILL NOT BE PERMITTED." We were publishing four of those shows to the
-- CRM as ordinary sellable inventory. A broker who buys them cannot deliver them.
--
-- The tell is the delivery-method label, with event.description confirming in prose. The four
-- flags that sound like they mean this -- secondaryEnabled, is_resale_enabled, marketplace,
-- isOnlyForMembers -- are identical on transferable and non-transferable events and are NOT
-- used (mig 20261127240000).
\set QUIET on
\pset footer off
\pset null '-'
SET client_min_messages = warning;

\echo '--- A. the label is the signal; the look-alike flags are not consulted'
SELECT public.axs_watch_non_transferable(jsonb_build_object(
         'delivery_methods', jsonb_build_array(jsonb_build_object(
           'label', 'AXS Mobile ID - Free (Non-Transferable)')))) AS ryman,
       public.axs_watch_non_transferable(jsonb_build_object(
         'delivery_methods', jsonb_build_array(jsonb_build_object(
           'label', 'AXS Mobile ID')))) AS tso;

\echo '--- B. the description alone is enough, and spelling variants are caught'
SELECT public.axs_watch_non_transferable(jsonb_build_object(
         'event', jsonb_build_object('description',
           'TICKETS FOR THIS EVENT ARE NON-TRANSFERABLE UNDER ANY CIRCUMSTANCE.'))) AS hyphen,
       public.axs_watch_non_transferable(jsonb_build_object(
         'event', jsonb_build_object('description', 'These are non transferable.'))) AS spaced,
       public.axs_watch_non_transferable(jsonb_build_object(
         'event', jsonb_build_object('description', 'Resale will not be permitted.'))) AS resale_clause;

\echo '--- C. an event that says nothing about it is left alone'
SELECT public.axs_watch_non_transferable('{}'::jsonb) AS empty_body,
       public.axs_watch_non_transferable(jsonb_build_object(
         'event', jsonb_build_object('description', 'Doors at 7. Mobile delivery only.'))) AS ordinary,
       public.axs_watch_non_transferable(jsonb_build_object(
         'delivery_methods', 'not an array')) AS malformed;

\echo '--- D. the settle retires one, and the fill will not take it back'
SELECT position('axs_watch_non_transferable' in s) > 0 AS settle_calls_detector,
       position('non_transferable = true, watch = false' in s) > 0 AS settle_retires,
       position('non_transferable' in f) > 0 AS fill_excludes
  FROM (SELECT pg_get_functiondef(
          'public.axs_watch_settle_one(text,integer,jsonb,boolean,text,boolean,text)'::regprocedure) s,
               pg_get_functiondef('public.axs_watch_fill(boolean)'::regprocedure) f) x;

\echo '--- E. the feed reports it, ahead of not_polled, and keeps security_invoker'
SELECT strpos(d, 'non_transferable') > 0 AS reason_present,
       strpos(d, 'non_transferable') < strpos(d, 'not_polled') AS ahead_of_not_polled,
       (SELECT reloptions @> ARRAY['security_invoker=true'] FROM pg_class
         WHERE relname = 'v_primary_poll_events_feed') AS security_invoker_kept
  FROM (SELECT pg_get_viewdef('v_primary_poll_events_feed'::regclass) d) v;

-- Toyota Center reads as AXS primary (mig 20261125170500): the label is forced at write time, so it survives
-- an export pass that carries TicketsData's own type, and only AXS-sold rows are relabelled.
\set QUIET on
\pset footer off
\pset null '-'
SET client_min_messages = warning;

\echo '--- A. the override list as seeded'
SELECT venue_id, venue_name, forced_type, set_by FROM public.axs_export_type_override ORDER BY venue_id;

\echo '--- B. an insert carrying another brand is relabelled when AXS sells it, and left alone when it does not'
INSERT INTO public.axs_export_event (axs_event_id, type, ticketer, axs_ticketed, status, event_title,
       venue_id, venue_name, venue_country, event_date_local, event_date_utc, event_url)
VALUES (701, 'other_ticketer', 'nba',          true,  'Buy Tickets', 'Rockets vs Someone',   101329, 'Toyota Center', 'US', '2027-01-10T19:00:00', '2027-01-11T01:00:00Z', 'https://www.axs.com/events/701/tickets'),
       (702, 'other_ticketer', 'toyotacenter', true,  'Buy Tickets', 'A Toyota Center Show', 101329, 'Toyota Center', 'US', '2027-01-11T19:00:00', '2027-01-12T01:00:00Z', 'https://www.axs.com/events/702/tickets'),
       (703, 'other_ticketer', 'ticketmaster', false, 'Buy Tickets', 'Not AXS Sold',         101329, 'Toyota Center', 'US', '2027-01-12T19:00:00', '2027-01-13T01:00:00Z', 'https://www.axs.com/events/703/tickets'),
       (704, 'other_ticketer', 'nba',          true,  'Buy Tickets', 'Another Venue Game',   101242, 'Crypto.com Arena', 'US', '2027-01-13T19:00:00', '2027-01-14T01:00:00Z', 'https://www.axs.com/events/704/tickets');
SELECT axs_event_id, venue_name, ticketer, axs_ticketed, type FROM public.axs_export_event
 WHERE axs_event_id IN (701,702,703,704) ORDER BY axs_event_id;

\echo '--- C. an export pass that re-sends the original type does not undo it (the UPDATE path)'
UPDATE public.axs_export_event SET type = 'other_ticketer', status = 'Buy Tickets' WHERE axs_event_id IN (701,702,703);
SELECT axs_event_id, ticketer, axs_ticketed, type FROM public.axs_export_event
 WHERE axs_event_id IN (701,702,703) ORDER BY axs_event_id;

\echo '--- D. an event that stops being AXS-sold keeps the type the feed gives it'
UPDATE public.axs_export_event SET axs_ticketed = false, type = 'other_ticketer' WHERE axs_event_id = 701;
SELECT axs_event_id, axs_ticketed, type FROM public.axs_export_event WHERE axs_event_id = 701;

\echo '--- E. a venue not on the override list is never touched'
UPDATE public.axs_export_event SET type = 'other_ticketer' WHERE axs_event_id = 704;
SELECT axs_event_id, venue_name, type FROM public.axs_export_event WHERE axs_event_id = 704;

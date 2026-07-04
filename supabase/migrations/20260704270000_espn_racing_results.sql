-- ESPN per-race finishing order for F1 + NASCAR Cup/Xfinity/Truck.
--
-- The scoreboard event we already store (espn_racing_events.meta) embeds the
-- full result in competitions[0].competitors[] — each driver's finishing `order`
-- + `winner` flag + athlete (name, country). Verified 100% coverage across every
-- completed race. So results need NO separate pipeline and NOT the summary
-- endpoint (which is gzip-only and returns 404/502 unreliably from the edge fn).
-- This read helper surfaces the finishing order + race header for a race id
-- straight from that stored meta, so it is always in sync with the calendar.

drop table if exists public.espn_racing_results;   -- exploratory table, superseded by meta-derived results

create or replace function get_espn_racing_results(p_event_id text)
returns jsonb language sql stable security definer set search_path to 'public','pg_temp' as $$
  select jsonb_build_object(
    'event', (select to_jsonb(e) from (
        select series, espn_event_id, name, short_name, event_date, status_name, venue, completed
        from public.espn_racing_events where espn_event_id = p_event_id limit 1) e),
    'results', coalesce((
        select jsonb_agg(jsonb_build_object(
                 'finish_position', (c->>'order')::int,
                 'driver_name',     c#>>'{athlete,displayName}',
                 'driver_id',       c->>'id',
                 'winner',          coalesce((c->>'winner')::boolean, false),
                 'country',         c#>>'{athlete,flag,alt}')
               order by (c->>'order')::int nulls last)
        from public.espn_racing_events ev,
             lateral jsonb_array_elements(ev.meta#>'{competitions,0,competitors}') c
        where ev.espn_event_id = p_event_id), '[]'::jsonb));
$$;
comment on function get_espn_racing_results is
  'Finishing order (from the stored scoreboard meta) + race header for a racing event id.';

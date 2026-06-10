-- AXS performer-tour discovery via TicketsData /events.
--
-- /events?performer_url=<axs.com/artists/<id>/<slug>-tickets>&platform=axs returns
-- a performer's full AXS tour with each event's URL + axs_ticketed (primary) /
-- axs_marketplace (resale) flags — a cleaner primary signal than the /fetch probe.
-- axs_ingest_performer_events() parses a landed response: adds the AXS-PRIMARY,
-- non-parking events to the pull list (axs_events, source_sheets='performer_discovery')
-- and links any matching axs_event_requests rows (same venue + date ±1d).
--
-- Fire (server-side, creds from vault):
--   select net.http_get('https://ticketsdata.com/events', jsonb_build_object(
--     'performer_url', '<axs artist url>', 'platform','axs',
--     'username', public.get_app_secret(p_name=>'TICKETSDATA_USERNAME'),
--     'password', public.get_app_secret(p_name=>'TICKETSDATA_PASSWORD')), '{}', 60000);
-- then: select * from public.axs_ingest_performer_events(<request_id>);

create or replace function public.axs_ingest_performer_events(p_response_id bigint)
returns table(primary_events int, added_to_pull int, requests_linked int)
language plpgsql security definer set search_path = public, net, extensions, pg_temp as $$
declare v_added int := 0; v_linked int := 0; v_prim int := 0;
begin
  select count(*) into v_prim
  from net._http_response r, jsonb_array_elements(public.safe_jsonb(r.content)->'body'->'items') it
  where r.id=p_response_id and (it->>'axs_ticketed')::boolean and (it->>'event_title') !~* 'parking';

  with ins as (
    insert into public.axs_events (axs_event_id, event_url, source_sheets, active)
    select it->>'event_id', it->>'event_url', 'performer_discovery', true
    from net._http_response r, jsonb_array_elements(public.safe_jsonb(r.content)->'body'->'items') it
    where r.id=p_response_id
      and (it->>'axs_ticketed')::boolean and (it->>'event_title') !~* 'parking'
    on conflict (axs_event_id) do update set active=true
    returning xmax=0 as inserted
  ) select count(*) filter (where inserted) into v_added from ins;

  with lk as (
    update public.axs_event_requests rq
    set axs_event_id = it->>'event_id', status='discovered'
    from net._http_response r, jsonb_array_elements(public.safe_jsonb(r.content)->'body'->'items') it
    where r.id=p_response_id
      and (it->>'axs_ticketed')::boolean and (it->>'event_title') !~* 'parking'
      and rq.axs_event_id is null
      and public.venue_norm(rq.venue_name) = public.venue_norm(it->>'venue_name')
      and (it->>'event_date_local')::date between rq.event_date - 1 and rq.event_date + 1
    returning 1
  ) select count(*) into v_linked from lk;

  return query select v_prim, v_added, v_linked;
end $$;

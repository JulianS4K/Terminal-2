-- Migration 20260603180000 · lane:A1 (author, operator-routed D0 FE work) → PENDING operator apply · writes:alert_metric_catalog + user_alerts tables + user-alert mgmt RPCs · reads:auth.uid()
--
-- ## NOT YET APPLIED TO PROD — authored as a file only (CLAUDE.md lockdown rule 1).
--    Phase 1 of the user alert system: the CREATE/MANAGE surface behind the D0
--    terminal "Alerts" tab (event / performer / venue). Lets an authenticated
--    terminal user (auth.uid()) subscribe to ANY tracked dataset as an alert
--    trigger and choose email / SMS.
--
--    Phase 2 (separate, gated migration — NOT in this file): evaluate_user_alerts()
--    on the snapshot tick + Twilio/ESP delivery + TCPA/CAN-SPAM consent fields.
--    Sending is outward-facing → operator-gated go-live.
--
-- Design notes:
--  * alert_metric_catalog — the data-driven trigger list. One row per alertable
--    metric per scope level. The FE builds its dropdowns from
--    get_alert_metric_catalog(); making a new tracked dataset alertable is an
--    INSERT here, no code change ("all tracked datasets are valid alert reasons").
--  * user_alerts — one subscription per row, owned by auth.uid(), RLS-isolated.
--  * Operators: drop_pct / rise_pct (manual % — the user-entered number),
--    below / above (manual threshold in the metric's unit), available (qty > 0),
--    any_change, crosses_into (e.g. enters top movers). Whether a threshold is
--    required is derived from the operator (alert_operator_needs_threshold()).

begin;

-- ----------------------------------------------------------------------------
-- 1. metric catalog (data-driven trigger list)
-- ----------------------------------------------------------------------------
create table if not exists public.alert_metric_catalog (
  metric_key        text primary key,
  scope_type        text not null check (scope_type in ('event','performer','venue')),
  label             text not null,
  value_kind        text not null,                 -- price | count | pct | index | temp | event | signal
  allowed_operators text[] not null,
  default_operator  text not null,
  threshold_unit    text,                          -- '$' | '%' | '°F' | 'tickets' | 'sales' | null
  param_kind        text,                          -- null | 'zone' | 'section' | 'city'
  source_note       text,                          -- which table/RPC backs this (for catalogue/lineage)
  sort_order        int not null default 100,
  active            boolean not null default true
);
comment on table public.alert_metric_catalog is
  'Data-driven catalog of alertable metrics per scope level (event/performer/venue). FE dropdowns build from get_alert_metric_catalog(). Add a row to make a new tracked dataset alertable — no code change. Phase 1 of the user alert system (mig 20260603180000).';

insert into public.alert_metric_catalog
  (metric_key, scope_type, label, value_kind, allowed_operators, default_operator, threshold_unit, param_kind, source_note, sort_order)
values
  -- EVENT level ------------------------------------------------------------
  ('evt_price_floor',      'event','Lowest ask price',              'price','{drop_pct,rise_pct,below,above}','drop_pct','$',      null,     'event_metrics.min_price / get_event_zones_public',        10),
  ('evt_price_median',     'event','Median ask price',              'price','{drop_pct,rise_pct,below,above}','below',   '$',      null,     'event_metrics median',                                    20),
  ('evt_get_in',           'event','Get-in (cheapest, any qty)',    'price','{below,drop_pct}',              'below',   '$',      null,     'listings_snapshots floor',                                30),
  ('evt_zone_floor',       'event','Lowest ask in a zone',          'price','{below,drop_pct,available}',    'below',   '$',      'zone',   'zone_metrics / get_event_zones_public',                   40),
  ('evt_section_available','event','Any ticket in a section',       'count','{available}',                   'available','tickets','section','event_section_row_snapshots',                             50),
  ('evt_listings_total',   'event','Total active listings',         'count','{below,above,any_change}',      'below',   'tickets',null,     'event_metrics.listing_count',                             60),
  ('evt_listings_sg',      'event','SeatGeek listing count',        'count','{below,above,any_change}',      'any_change','tickets',null,   'seatgeek_event_metrics',                                  70),
  ('evt_listings_evo',     'event','TEvo listing count',            'count','{below,above,any_change}',      'any_change','tickets',null,   'event_metrics (evo)',                                     80),
  ('evt_listings_td',      'event','TicketsData listing count',     'count','{below,above,any_change}',      'any_change','tickets',null,   'ticketsdata_listings_snapshots',                          90),
  ('evt_new_sale',         'event','New sale recorded',             'event','{any_change}',                  'any_change',null,    null,     'seatgeek_sales_snapshots / evo_orders',                  100),
  ('evt_sales_velocity',   'event','Sales in last 24h',             'count','{above,below}',                 'above',   'sales',  null,     'seatgeek_event_metrics.sold_*',                          110),
  ('evt_mover',            'event','Enters top movers',             'index','{crosses_into}',                'crosses_into',null,  null,     'event_movers_index',                                     120),
  ('evt_weather_temp',     'event','Forecast temperature',          'temp', '{below,above}',                 'below',   '°F',     null,     'weather_forecast / get_event_weather_localized',         130),
  ('evt_weather_precip',   'event','Precipitation chance',          'pct',  '{above}',                       'above',   '%',      null,     'weather_forecast',                                       140),
  ('evt_sentiment',        'event','Event sentiment score',         'index','{drop_pct,rise_pct,below,above,any_change}','any_change',null,null,'event_sentiment',                                   150),
  ('evt_injury',           'event','New injury (linked teams)',     'signal','{any_change}',                 'any_change',null,    null,     'espn_injuries_snapshots',                                160),
  ('evt_news',             'event','New news item',                 'signal','{any_change}',                 'any_change',null,    null,     'espn_news',                                              170),
  ('evt_arb_gap',          'event','Cross-source value gap appears','signal','{any_change,available}',       'any_change',null,    null,     'discovery_gap_alerts',                                   180),
  -- PERFORMER level --------------------------------------------------------
  ('perf_new_event',       'performer','New event announced',       'event','{any_change,available}',        'any_change',null,    'city',   'events / search_events_by_date',                          10),
  ('perf_portfolio_move',  'performer','Portfolio median price move','price','{drop_pct,rise_pct}',          'drop_pct','%',       null,     'get_broker_performer_page',                               20),
  ('perf_any_event_floor', 'performer','Any upcoming event floor drops','price','{drop_pct,below}',          'drop_pct','%',       null,     'event_metrics across performer',                          30),
  ('perf_mover',           'performer','Becomes a top mover',        'index','{crosses_into}',               'crosses_into',null,  null,     'event_movers_index',                                      40),
  ('perf_injury',          'performer','New injury',                'signal','{any_change}',                 'any_change',null,    null,     'espn_injuries_snapshots',                                 50),
  ('perf_news',            'performer','New news item',             'signal','{any_change}',                 'any_change',null,    null,     'espn_news',                                               60),
  ('perf_popularity',      'performer','Popularity score change',   'index','{rise_pct,drop_pct,any_change}','any_change','%',     null,     'performer_metadata.popularity_score',                     70),
  -- VENUE level ------------------------------------------------------------
  ('ven_new_event',        'venue','New event at venue',            'event','{any_change,available}',        'any_change',null,    null,     'get_events_by_venue_public',                              10),
  ('ven_competing',        'venue','Competing event added nearby',  'event','{any_change}',                  'any_change',null,    null,     'find_competing_events',                                   20),
  ('ven_owned_price',      'venue','Owned inventory price move',    'price','{drop_pct,below}',              'drop_pct','%',       null,     'event_metrics owned',                                     30),
  ('ven_availability',     'venue','Availability across venue',     'count','{below,above,any_change}',      'any_change','tickets',null,    'listings_snapshots by venue',                             40),
  ('ven_mover',            'venue','A venue event enters top movers','index','{crosses_into}',               'crosses_into',null,  null,     'event_movers_index',                                      50)
on conflict (metric_key) do update set
  scope_type        = excluded.scope_type,
  label             = excluded.label,
  value_kind        = excluded.value_kind,
  allowed_operators = excluded.allowed_operators,
  default_operator  = excluded.default_operator,
  threshold_unit    = excluded.threshold_unit,
  param_kind        = excluded.param_kind,
  source_note       = excluded.source_note,
  sort_order        = excluded.sort_order,
  active            = excluded.active;

-- ----------------------------------------------------------------------------
-- 2. user subscriptions
-- ----------------------------------------------------------------------------
create table if not exists public.user_alerts (
  id               bigint generated always as identity primary key,
  owner_id         uuid not null default auth.uid(),
  scope_type       text not null check (scope_type in ('event','performer','venue')),
  scope_id         bigint not null,
  scope_label      text,                                              -- denormalized for display
  metric_key       text not null references public.alert_metric_catalog(metric_key),
  operator         text not null check (operator in ('drop_pct','rise_pct','below','above','available','any_change','crosses_into')),
  threshold        numeric,                                           -- required iff operator needs it
  params           jsonb  not null default '{}'::jsonb,               -- e.g. {"zone":"100 Level"} / {"city":"New York"}
  channels         text[] not null default '{email}'::text[] check (channels <@ array['email','sms'] and array_length(channels,1) >= 1),
  notify_email     text,
  notify_phone     text,
  cooldown_minutes int  not null default 720 check (cooldown_minutes >= 0),
  active           boolean not null default true,
  last_fired_at    timestamptz,
  expires_at       timestamptz,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);
comment on table public.user_alerts is
  'User-defined alert subscriptions, owned by auth.uid() and RLS-isolated. One row = one trigger on one scope (event/performer/venue). Created/managed via the D0 terminal Alerts tab. Phase 2 evaluator (gated) scans active rows on the snapshot tick. Mig 20260603180000.';

create index if not exists user_alerts_owner_scope_idx on public.user_alerts (owner_id, scope_type, scope_id) where active;
create index if not exists user_alerts_scope_idx       on public.user_alerts (scope_type, scope_id)           where active;  -- evaluator scan (phase 2)

-- ----------------------------------------------------------------------------
-- 3. RLS — defense in depth (the RPCs below are SECDEF and filter by auth.uid(),
--    but RLS protects any direct PostgREST table access).
-- ----------------------------------------------------------------------------
alter table public.user_alerts          enable row level security;
alter table public.alert_metric_catalog enable row level security;

drop policy if exists user_alerts_owner_all on public.user_alerts;
create policy user_alerts_owner_all on public.user_alerts
  for all to authenticated
  using (owner_id = auth.uid()) with check (owner_id = auth.uid());

drop policy if exists alert_catalog_read on public.alert_metric_catalog;
create policy alert_catalog_read on public.alert_metric_catalog
  for select to authenticated using (active);

-- ----------------------------------------------------------------------------
-- 4. helpers + management RPCs (SECDEF, granted to authenticated)
-- ----------------------------------------------------------------------------
create or replace function public.alert_operator_needs_threshold(p_operator text)
returns boolean language sql immutable as
$$ select p_operator in ('drop_pct','rise_pct','below','above') $$;

create or replace function public.get_alert_metric_catalog(p_scope_type text)
returns setof public.alert_metric_catalog
language sql stable security definer set search_path = public, pg_temp as
$$ select * from public.alert_metric_catalog
   where active and scope_type = p_scope_type
   order by sort_order, label $$;

create or replace function public.list_user_alerts(p_scope_type text, p_scope_id bigint)
returns setof public.user_alerts
language sql stable security definer set search_path = public, pg_temp as
$$ select * from public.user_alerts
   where owner_id = auth.uid() and scope_type = p_scope_type and scope_id = p_scope_id
   order by created_at desc $$;

create or replace function public.create_user_alert(
  p_scope_type       text,
  p_scope_id         bigint,
  p_metric_key       text,
  p_operator         text,
  p_threshold        numeric     default null,
  p_params           jsonb       default '{}'::jsonb,
  p_channels         text[]      default array['email'],
  p_notify_email     text        default null,
  p_notify_phone     text        default null,
  p_cooldown_minutes int         default 720,
  p_scope_label      text        default null,
  p_expires_at       timestamptz default null
) returns public.user_alerts
language plpgsql security definer set search_path = public, pg_temp as
$$
declare
  v_uid    uuid := auth.uid();
  v_metric public.alert_metric_catalog;
  v_row    public.user_alerts;
begin
  if v_uid is null then
    raise exception 'not authenticated';
  end if;

  select * into v_metric from public.alert_metric_catalog
   where metric_key = p_metric_key and scope_type = p_scope_type and active;
  if not found then
    raise exception 'unknown or inactive metric % for scope %', p_metric_key, p_scope_type;
  end if;

  if not (p_operator = any (v_metric.allowed_operators)) then
    raise exception 'operator % not allowed for metric %', p_operator, p_metric_key;
  end if;

  if public.alert_operator_needs_threshold(p_operator) and p_threshold is null then
    raise exception 'operator % requires a threshold', p_operator;
  end if;

  if 'sms' = any (p_channels) and coalesce(nullif(trim(p_notify_phone), ''), '') = '' then
    raise exception 'SMS channel requires a phone number';
  end if;
  if 'email' = any (p_channels) and coalesce(nullif(trim(p_notify_email), ''), '') = '' then
    raise exception 'email channel requires an email address';
  end if;

  insert into public.user_alerts
    (owner_id, scope_type, scope_id, scope_label, metric_key, operator, threshold,
     params, channels, notify_email, notify_phone, cooldown_minutes, expires_at)
  values
    (v_uid, p_scope_type, p_scope_id, p_scope_label, p_metric_key, p_operator, p_threshold,
     coalesce(p_params, '{}'::jsonb), p_channels, p_notify_email, p_notify_phone,
     p_cooldown_minutes, p_expires_at)
  returning * into v_row;

  return v_row;
end $$;

create or replace function public.set_user_alert_active(p_id bigint, p_active boolean)
returns public.user_alerts
language plpgsql security definer set search_path = public, pg_temp as
$$
declare v_row public.user_alerts;
begin
  update public.user_alerts
     set active = p_active, updated_at = now()
   where id = p_id and owner_id = auth.uid()
  returning * into v_row;
  if not found then raise exception 'alert % not found', p_id; end if;
  return v_row;
end $$;

create or replace function public.delete_user_alert(p_id bigint)
returns boolean
language plpgsql security definer set search_path = public, pg_temp as
$$
declare n int;
begin
  delete from public.user_alerts where id = p_id and owner_id = auth.uid();
  get diagnostics n = row_count;
  return n > 0;
end $$;

-- ----------------------------------------------------------------------------
-- 5. grants
-- ----------------------------------------------------------------------------
grant select on public.alert_metric_catalog to authenticated;
grant execute on function public.alert_operator_needs_threshold(text)                                              to authenticated;
grant execute on function public.get_alert_metric_catalog(text)                                                    to authenticated;
grant execute on function public.list_user_alerts(text, bigint)                                                    to authenticated;
grant execute on function public.create_user_alert(text, bigint, text, text, numeric, jsonb, text[], text, text, int, text, timestamptz) to authenticated;
grant execute on function public.set_user_alert_active(bigint, boolean)                                            to authenticated;
grant execute on function public.delete_user_alert(bigint)                                                         to authenticated;

commit;

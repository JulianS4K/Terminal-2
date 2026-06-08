-- Migration 20260608210200 · lane:D0 (Fantasy feature, Phase 2) → PENDING operator apply · writes:fantasy management RPCs (create/join/draft/pick/lineup/schedule + reads) · reads:auth.uid() / espn_athletes / fantasy_*
--
-- ## NOT YET APPLIED TO PROD — authored as a file only (CLAUDE.md lockdown rule 1).
--
-- Phase 2 of the Fantasy League feature — user-facing SECDEF RPCs. These are
-- the WRITE surface, called from the browser via TerminalAuth.client.rpc(...)
-- where auth.uid() resolves (the FastAPI service_role path cannot see it).
-- Tables/RLS: 20260608210100. Scoring engine: 20260608210300.

begin;

-- ----------------------------------------------------------------------------
-- helpers
-- ----------------------------------------------------------------------------
create or replace function public.fantasy_gen_join_code()
returns text language sql volatile as
$$ select upper(substr(encode(gen_random_bytes(5), 'hex'), 1, 6)) $$;

-- _require_commissioner: raises unless caller owns the league.
create or replace function public.fantasy_assert_commissioner(p_league_id uuid)
returns void language plpgsql security definer set search_path = public, pg_temp as
$$
begin
  if not exists (select 1 from public.fantasy_leagues
                  where id = p_league_id and owner_id = auth.uid()) then
    raise exception 'not the commissioner of league %', p_league_id;
  end if;
end $$;

-- ----------------------------------------------------------------------------
-- create / join
-- ----------------------------------------------------------------------------
create or replace function public.fantasy_create_league(
  p_name           text,
  p_espn_league    text,
  p_team_name      text,
  p_roster_slots   jsonb default null,
  p_scoring_rules_id bigint default null,
  p_draft_type     text default 'snake',
  p_format         text default 'h2h',
  p_season_start   date default null,
  p_season_end     date default null
) returns public.fantasy_leagues
language plpgsql security definer set search_path = public, pg_temp as
$$
declare
  v_uid    uuid := auth.uid();
  v_league public.fantasy_leagues;
  v_rules  bigint := p_scoring_rules_id;
  v_slots  jsonb := p_roster_slots;
  v_mid    bigint;
begin
  if v_uid is null then raise exception 'not authenticated'; end if;

  -- default scoring preset for the league if none supplied
  if v_rules is null then
    select id into v_rules from public.fantasy_scoring_rules
     where is_preset and espn_league = p_espn_league order by id limit 1;
  end if;

  -- a sensible default roster template per league family if none supplied
  if v_slots is null then
    v_slots := case p_espn_league
      when 'NBA'  then '{"PG":1,"SG":1,"SF":1,"PF":1,"C":1,"UTIL":2,"BENCH":3}'::jsonb
      when 'WNBA' then '{"G":2,"F":2,"C":1,"UTIL":1,"BENCH":3}'::jsonb
      when 'NFL'  then '{"QB":1,"RB":2,"WR":2,"TE":1,"FLEX":1,"K":1,"DST":1,"BENCH":3}'::jsonb
      when 'NHL'  then '{"C":2,"LW":2,"RW":2,"D":2,"G":1,"BENCH":3}'::jsonb
      when 'MLB'  then '{"C":1,"1B":1,"2B":1,"3B":1,"SS":1,"OF":3,"UTIL":1,"P":2,"BENCH":3}'::jsonb
      else '{"UTIL":7,"BENCH":3}'::jsonb end;
  end if;

  insert into public.fantasy_leagues
    (name, espn_league, owner_id, format, roster_slots, scoring_rules_id,
     draft_type, status, season_start, season_end, join_code)
  values
    (p_name, p_espn_league, v_uid, p_format, v_slots, v_rules,
     p_draft_type, 'forming', p_season_start, p_season_end, public.fantasy_gen_join_code())
  returning * into v_league;

  -- commissioner becomes the first manager (+ their roster)
  insert into public.fantasy_memberships (league_id, user_id, team_name, role)
  values (v_league.id, v_uid, coalesce(p_team_name, 'Commissioner'), 'commissioner')
  returning id into v_mid;
  insert into public.fantasy_rosters (league_id, membership_id) values (v_league.id, v_mid);

  return v_league;
end $$;

create or replace function public.fantasy_join_league(
  p_join_code text,
  p_team_name text
) returns public.fantasy_memberships
language plpgsql security definer set search_path = public, pg_temp as
$$
declare
  v_uid uuid := auth.uid();
  v_league public.fantasy_leagues;
  v_mid bigint;
  v_row public.fantasy_memberships;
begin
  if v_uid is null then raise exception 'not authenticated'; end if;
  select * into v_league from public.fantasy_leagues
   where join_code = upper(p_join_code);
  if not found then raise exception 'no league with that code'; end if;
  if v_league.status <> 'forming' then
    raise exception 'league % is no longer accepting members (%).', v_league.id, v_league.status;
  end if;

  begin
    insert into public.fantasy_memberships (league_id, user_id, team_name, role)
    values (v_league.id, v_uid, p_team_name, 'manager')
    returning id into v_mid;
  exception when unique_violation then
    raise exception 'already a member of this league';
  end;

  insert into public.fantasy_rosters (league_id, membership_id) values (v_league.id, v_mid);
  select * into v_row from public.fantasy_memberships where id = v_mid;
  return v_row;
end $$;

-- ----------------------------------------------------------------------------
-- draft: start (snake order) + pick
-- ----------------------------------------------------------------------------
create or replace function public.fantasy_start_draft(p_league_id uuid)
returns public.fantasy_draft
language plpgsql security definer set search_path = public, pg_temp as
$$
declare
  v_league public.fantasy_leagues;
  v_members bigint[];
  v_n int;
  v_rounds int;
  v_order bigint[] := array[]::bigint[];
  v_round int;
  v_draft public.fantasy_draft;
  v_slot_total int;
begin
  perform public.fantasy_assert_commissioner(p_league_id);
  select * into v_league from public.fantasy_leagues where id = p_league_id;
  if v_league.status not in ('forming','drafting') then
    raise exception 'league % cannot start a draft from status %', p_league_id, v_league.status;
  end if;

  -- assign draft positions in join order (stable, simple; randomize later if wanted)
  with ordered as (
    select id, row_number() over (order by joined_at, id) as pos
      from public.fantasy_memberships where league_id = p_league_id
  )
  update public.fantasy_memberships m set draft_position = ordered.pos
    from ordered where m.id = ordered.id;

  select array_agg(id order by draft_position) into v_members
    from public.fantasy_memberships where league_id = p_league_id;
  v_n := coalesce(array_length(v_members, 1), 0);
  if v_n < 2 then raise exception 'need at least 2 managers to draft (have %)', v_n; end if;

  -- rounds = total roster slots
  select coalesce(sum((value)::int), 10) into v_slot_total
    from jsonb_each_text(v_league.roster_slots);
  v_rounds := greatest(v_slot_total, 1);

  -- materialize serpentine order: round 1 forward, round 2 reverse, ...
  for v_round in 1..v_rounds loop
    if v_round % 2 = 1 then
      v_order := v_order || v_members;
    else
      v_order := v_order || (select array_agg(v_members[i] order by i desc)
                               from generate_subscripts(v_members, 1) g(i));
    end if;
  end loop;

  insert into public.fantasy_draft (league_id, status, current_pick_no, total_rounds, pick_order, started_at)
  values (p_league_id, 'in_progress', 1, v_rounds, to_jsonb(v_order), now())
  on conflict (league_id) do update
    set status = 'in_progress', current_pick_no = 1, total_rounds = excluded.total_rounds,
        pick_order = excluded.pick_order, started_at = now(), completed_at = null
  returning * into v_draft;

  update public.fantasy_leagues set status = 'drafting' where id = p_league_id;
  return v_draft;
end $$;

create or replace function public.fantasy_make_pick(
  p_league_id       uuid,
  p_espn_athlete_id text,
  p_slot            text
) returns public.fantasy_roster_players
language plpgsql security definer set search_path = public, pg_temp as
$$
declare
  v_uid uuid := auth.uid();
  v_draft public.fantasy_draft;
  v_league public.fantasy_leagues;
  v_on_clock bigint;
  v_my_mid bigint;
  v_athlete public.espn_athletes;
  v_roster_id bigint;
  v_round int;
  v_row public.fantasy_roster_players;
begin
  select * into v_league from public.fantasy_leagues where id = p_league_id;
  select * into v_draft from public.fantasy_draft where league_id = p_league_id;
  if v_draft.status <> 'in_progress' then raise exception 'draft is not in progress'; end if;

  v_on_clock := (v_draft.pick_order ->> (v_draft.current_pick_no - 1))::bigint;  -- jsonb array 0-indexed
  select id into v_my_mid from public.fantasy_memberships
   where league_id = p_league_id and user_id = v_uid;
  if v_my_mid is null then raise exception 'not a member of this league'; end if;
  if v_my_mid <> v_on_clock then raise exception 'not your pick (membership % is on the clock)', v_on_clock; end if;

  -- athlete must exist and belong to the league
  select * into v_athlete from public.espn_athletes
   where espn_athlete_id = p_espn_athlete_id and espn_league = v_league.espn_league;
  if not found then
    raise exception 'athlete % not found in league %', p_espn_athlete_id, v_league.espn_league;
  end if;

  -- slot must exist in the roster template; BENCH/UTIL/FLEX accept anyone,
  -- otherwise the athlete's position_abbr must match the slot.
  if not (v_league.roster_slots ? p_slot) then
    raise exception 'slot % is not part of this league''s roster', p_slot;
  end if;
  if p_slot not in ('BENCH','UTIL','FLEX')
     and coalesce(v_athlete.position_abbr,'') <> p_slot
     -- allow multi-eligible umbrella slots (OF for LF/CF/RF, G for PG/SG, etc.)
     and not (p_slot = 'OF'  and v_athlete.position_abbr in ('LF','CF','RF','OF'))
     and not (p_slot = 'G'   and v_athlete.position_abbr in ('PG','SG','G'))
     and not (p_slot = 'F'   and v_athlete.position_abbr in ('SF','PF','F'))
     and not (p_slot = 'P'   and v_athlete.position_abbr in ('SP','RP','P')) then
    raise exception 'athlete position % not eligible for slot %', v_athlete.position_abbr, p_slot;
  end if;

  -- round = ceil(pick_no / num_members); num_members = total_picks / total_rounds
  v_round := ceil(v_draft.current_pick_no::numeric /
                  (jsonb_array_length(v_draft.pick_order)::numeric / v_draft.total_rounds))::int;

  select id into v_roster_id from public.fantasy_rosters
   where league_id = p_league_id and membership_id = v_my_mid;

  -- uniqueness enforced by fantasy_roster_players_league_espn unique + draft unique
  begin
    insert into public.fantasy_roster_players
      (roster_id, league_id, espn_athlete_id, espn_team_id, espn_league, slot, acquired_via)
    values
      (v_roster_id, p_league_id, p_espn_athlete_id, v_athlete.espn_team_id, v_league.espn_league, p_slot, 'draft')
    returning * into v_row;
  exception when unique_violation then
    raise exception 'athlete % is already drafted in this league', p_espn_athlete_id;
  end;

  insert into public.fantasy_draft_picks
    (draft_id, league_id, pick_no, round, membership_id, espn_athlete_id)
  values (v_draft.id, p_league_id, v_draft.current_pick_no, v_round, v_my_mid, p_espn_athlete_id);

  -- advance the clock; complete + schedule when done
  if v_draft.current_pick_no >= jsonb_array_length(v_draft.pick_order) then
    update public.fantasy_draft set status='complete', completed_at=now(),
           current_pick_no = current_pick_no + 1 where id = v_draft.id;
    update public.fantasy_leagues set status='active' where id = p_league_id;
    perform public.fantasy_generate_schedule(p_league_id);
  else
    update public.fantasy_draft set current_pick_no = current_pick_no + 1 where id = v_draft.id;
  end if;

  return v_row;
end $$;

-- ----------------------------------------------------------------------------
-- lineup management
-- ----------------------------------------------------------------------------
create or replace function public.fantasy_set_lineup(
  p_league_id text,
  p_starters  bigint[]      -- roster_player ids to mark as starters; the rest -> bench
) returns int
language plpgsql security definer set search_path = public, pg_temp as
$$
declare v_mid bigint; v_roster bigint; n int;
begin
  select id into v_mid from public.fantasy_memberships
   where league_id = p_league_id::uuid and user_id = auth.uid();
  if v_mid is null then raise exception 'not a member of this league'; end if;
  select id into v_roster from public.fantasy_rosters
   where league_id = p_league_id::uuid and membership_id = v_mid;

  update public.fantasy_roster_players
     set is_starter = (id = any(p_starters))
   where roster_id = v_roster;
  get diagnostics n = row_count;
  return n;
end $$;

-- ----------------------------------------------------------------------------
-- H2H schedule generator (circle method round-robin over weekly periods)
-- ----------------------------------------------------------------------------
create or replace function public.fantasy_generate_schedule(p_league_id uuid)
returns int
language plpgsql security definer set search_path = public, pg_temp as
$$
declare
  v_league public.fantasy_leagues;
  v_ids bigint[];
  v_n int; v_slots int; v_rounds int;
  v_start timestamptz; v_period int := 0; v_r int; v_i int;
  v_a bigint; v_b bigint; v_pid bigint;
  v_rot bigint[];
begin
  select * into v_league from public.fantasy_leagues where id = p_league_id;
  select array_agg(id order by draft_position) into v_ids
    from public.fantasy_memberships where league_id = p_league_id;
  v_n := coalesce(array_length(v_ids,1),0);
  if v_n < 2 then return 0; end if;

  -- odd team count → add a NULL "bye" slot
  if v_n % 2 = 1 then v_ids := v_ids || array[null::bigint]; v_n := v_n + 1; end if;
  v_slots := v_n;
  v_rounds := v_n - 1;                       -- a full single round-robin

  v_start := coalesce(v_league.season_start::timestamptz,
                      date_trunc('week', now()) + interval '1 week');

  v_rot := v_ids;
  for v_r in 1..v_rounds loop
    v_period := v_period + 1;
    insert into public.fantasy_scoring_periods (league_id, period_no, starts_at, ends_at)
    values (p_league_id, v_period,
            v_start + ((v_period-1) || ' weeks')::interval,
            v_start + (v_period || ' weeks')::interval - interval '1 second')
    on conflict (league_id, period_no) do update set status = 'open'
    returning id into v_pid;

    -- pair i with n-1-i within the current rotation
    for v_i in 1..(v_slots/2) loop
      v_a := v_rot[v_i];
      v_b := v_rot[v_slots + 1 - v_i];
      if v_a is not null or v_b is not null then
        insert into public.fantasy_matchups
          (league_id, period_id, home_membership_id, away_membership_id)
        values (p_league_id, v_pid, coalesce(v_a, v_b), case when v_a is null then null else v_b end)
        on conflict do nothing;
      end if;
    end loop;

    -- rotate: fix first element, move the rest clockwise
    v_rot := array[v_rot[1]] || array[v_rot[v_slots]] || v_rot[2:v_slots-1];
  end loop;

  update public.fantasy_leagues set current_period = 1 where id = p_league_id;
  return v_period;
end $$;

-- ----------------------------------------------------------------------------
-- reads: my leagues + available draft pool
-- ----------------------------------------------------------------------------
create or replace function public.fantasy_my_leagues()
returns table (
  league_id uuid, name text, espn_league text, status text,
  role text, team_name text, membership_id bigint, join_code text, member_count bigint
)
language sql stable security definer set search_path = public, pg_temp as
$$
  select l.id, l.name, l.espn_league, l.status, m.role, m.team_name, m.id, l.join_code,
         (select count(*) from public.fantasy_memberships mm where mm.league_id = l.id)
    from public.fantasy_memberships m
    join public.fantasy_leagues l on l.id = m.league_id
   where m.user_id = auth.uid()
   order by l.created_at desc
$$;

create or replace function public.fantasy_available_players(
  p_league_id uuid,
  p_position  text default null,
  p_q         text default null,
  p_limit     int  default 50
) returns table (
  espn_athlete_id text, full_name text, position_abbr text, jersey text,
  status text, espn_team_id text, headshot_url text
)
language sql stable security definer set search_path = public, pg_temp as
$$
  select a.espn_athlete_id, a.full_name, a.position_abbr, a.jersey,
         a.status, a.espn_team_id, a.headshot_url
    from public.espn_athletes a
    join public.fantasy_leagues l on l.id = p_league_id
   where a.espn_league = l.espn_league
     and (p_position is null or a.position_abbr = p_position)
     and (p_q is null or a.full_name ilike '%'||p_q||'%')
     and a.espn_athlete_id not in (
       select espn_athlete_id from public.fantasy_roster_players where league_id = p_league_id)
   order by a.full_name
   limit greatest(p_limit, 1)
$$;

-- ----------------------------------------------------------------------------
-- grants
-- ----------------------------------------------------------------------------
grant execute on function public.fantasy_gen_join_code() to authenticated;
grant execute on function public.fantasy_assert_commissioner(uuid) to authenticated;
grant execute on function public.fantasy_create_league(text,text,text,jsonb,bigint,text,text,date,date) to authenticated;
grant execute on function public.fantasy_join_league(text,text) to authenticated;
grant execute on function public.fantasy_start_draft(uuid) to authenticated;
grant execute on function public.fantasy_make_pick(uuid,text,text) to authenticated;
grant execute on function public.fantasy_set_lineup(text,bigint[]) to authenticated;
grant execute on function public.fantasy_generate_schedule(uuid) to authenticated;
grant execute on function public.fantasy_my_leagues() to authenticated;
grant execute on function public.fantasy_available_players(uuid,text,text,int) to authenticated;

commit;

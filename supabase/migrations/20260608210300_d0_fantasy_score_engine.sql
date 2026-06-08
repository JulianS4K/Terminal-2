-- Migration 20260608210300 · lane:D0 (Fantasy feature, Phase 2) → PENDING operator apply · writes:fantasy scoring engine (compute helpers + fantasy_score_period + fantasy_score_due_periods) · reads:player_game_stats / espn_event_snapshots / espn_injuries_snapshots
--
-- ## NOT YET APPLIED TO PROD — authored as a file only (CLAUDE.md lockdown rule 1).
--
-- Phase 2 of the Fantasy League feature — the PLUGGABLE scoring engine. Tables:
-- 20260608210100. RPCs: 20260608210200. Cron: 20260608210400.
--
-- Source dispatch (rules->>'source'):
--   player_box_v1  — real per-player box scores from player_game_stats (Phase 1).
--   team_result_v1 — fallback for leagues/periods lacking player stats: derive
--                    points from the player's TEAM result (espn_event_snapshots)
--                    + availability (espn_injuries_snapshots). Every rostered
--                    player on a team gets the same base team-result points,
--                    differentiated by availability — an intentional v1
--                    approximation, surfaced in the UI.
--
-- Extension point: a future player-stat source (e.g. a richer feed) adds a new
-- `source` value + a compute helper here; fantasy_player_scores already stores
-- points + a free-form components jsonb, so nothing downstream changes.
--
-- Idempotency: gated on period.status='scored' (unless p_force) + upsert on
-- (period_id, roster_player_id). Re-runs converge.
--
-- Landmine: espn_team_id is LEAGUE-SCOPED — every team read filters
-- (espn_team_id, espn_league) together.

begin;

-- ----------------------------------------------------------------------------
-- player_box_v1 — weight a player's aggregated stat line by the rules components
-- ----------------------------------------------------------------------------
create or replace function public.fantasy_compute_player_box(
  p_espn_athlete_id text,
  p_league          text,
  p_from            timestamptz,
  p_to              timestamptz,
  p_components      jsonb
) returns table (points numeric, components jsonb)
language sql stable security definer set search_path = public, pg_temp as
$$
  with agg as (   -- sum each numeric stat across all games in the window
    select kv.key as stat, sum((kv.value)::numeric) as total
      from public.player_game_stats s
      cross join lateral jsonb_each_text(s.stats) kv
     where s.espn_athlete_id = p_espn_athlete_id
       and s.league = p_league
       and s.game_date >= p_from::date
       and s.game_date <= p_to::date
       and kv.value ~ '^-?[0-9]+(\.[0-9]+)?$'   -- numeric stats only
     group by kv.key
  ),
  weighted as (
    select a.stat,
           round(a.total * (p_components ->> a.stat)::numeric, 3) as contribution
      from agg a
     where p_components ? a.stat                  -- only stats this ruleset scores
  )
  select coalesce(sum(contribution), 0) as points,
         coalesce(jsonb_object_agg(stat, contribution), '{}'::jsonb) as components
    from weighted
$$;

-- ----------------------------------------------------------------------------
-- team_result_v1 — fallback from the team's game result + availability
-- ----------------------------------------------------------------------------
create or replace function public.fantasy_compute_team_result(
  p_espn_athlete_id text,
  p_espn_team_id    text,
  p_league          text,
  p_from            timestamptz,
  p_to              timestamptz,
  p_rules           jsonb
) returns table (points numeric, components jsonb)
language plpgsql stable security definer set search_path = public, pg_temp as
$$
declare
  c jsonb := p_rules -> 'components';
  v_pts numeric := 0;
  v_comp jsonb := '{}'::jsonb;
  g record;
  is_home boolean; won boolean; drew boolean; margin numeric; favored boolean;
  v_avail_status text;
begin
  if p_espn_team_id is null then
    return query select 0::numeric, '{}'::jsonb; return;
  end if;

  -- latest snapshot per finished game for this team in the window
  for g in
    select distinct on (espn_event_id) *
      from public.espn_event_snapshots
     where espn_league = p_league
       and (home_team_id = p_espn_team_id or away_team_id = p_espn_team_id)
       and state = coalesce(p_rules->>'settle_state','post')
       and captured_at >= p_from and captured_at <= p_to + interval '1 day'
     order by espn_event_id, captured_at desc
  loop
    is_home := (g.home_team_id = p_espn_team_id);
    drew := (g.home_score = g.away_score);
    won  := (is_home and g.home_score > g.away_score) or ((not is_home) and g.away_score > g.home_score);
    margin := abs(coalesce(g.home_score,0) - coalesce(g.away_score,0));
    favored := case when is_home then coalesce(g.home_ml,0) < 0 else coalesce(g.away_ml,0) < 0 end;

    if drew then
      v_pts := v_pts + coalesce((c->>'draw')::numeric, 0);
    elsif won then
      v_pts := v_pts + coalesce((c->>'win')::numeric, 0)
                     + case when favored then coalesce((c->'favored_win'->>'points')::numeric,
                                                        (c->>'favored_win')::numeric, 0)
                            else coalesce((c->'underdog_win'->>'points')::numeric,
                                          (c->>'underdog_win')::numeric, 0) end
                     + least(margin * coalesce((c->'margin'->>'per_point')::numeric, 0),
                             coalesce((c->'margin'->>'cap')::numeric, 1e9));
    end if;
  end loop;

  -- availability: latest injury status in the window
  select status into v_avail_status
    from public.espn_injuries_snapshots
   where athlete_id = p_espn_athlete_id
   order by captured_at desc limit 1;
  if v_avail_status is not null
     and v_avail_status = any (coalesce(
       array(select jsonb_array_elements_text(c->'availability'->'statuses_out')), array[]::text[])) then
    v_pts := v_pts + coalesce((c->'availability'->>'out')::numeric, 0);
    v_comp := v_comp || jsonb_build_object('availability', coalesce((c->'availability'->>'out')::numeric,0));
  else
    v_pts := v_pts + coalesce((c->'availability'->>'active')::numeric, 0);
    v_comp := v_comp || jsonb_build_object('availability', coalesce((c->'availability'->>'active')::numeric,0));
  end if;

  return query select round(v_pts,3), v_comp || jsonb_build_object('team_result', round(v_pts,3));
end $$;

-- ----------------------------------------------------------------------------
-- fantasy_score_period — score one period, idempotently
-- ----------------------------------------------------------------------------
create or replace function public.fantasy_score_period(
  p_league_id uuid,
  p_period_id bigint,
  p_force     boolean default false
) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as
$$
declare
  v_league public.fantasy_leagues;
  v_period public.fantasy_scoring_periods;
  v_rules jsonb;
  v_source text;
  rp record;
  v_points numeric; v_comp jsonb;
  v_players int := 0; v_teams int := 0;
begin
  select * into v_league from public.fantasy_leagues where id = p_league_id;
  select * into v_period from public.fantasy_scoring_periods where id = p_period_id and league_id = p_league_id;
  if not found then raise exception 'period % not in league %', p_period_id, p_league_id; end if;
  if v_period.status = 'scored' and not p_force then
    return jsonb_build_object('skipped', true, 'reason', 'already scored');
  end if;

  select rules into v_rules from public.fantasy_scoring_rules where id = v_league.scoring_rules_id;
  v_rules := coalesce(v_rules, '{"source":"team_result_v1","components":{"win":5}}'::jsonb);
  v_source := coalesce(v_rules->>'source', 'player_box_v1');

  -- score each starter on each roster in the league
  for rp in
    select frp.* from public.fantasy_roster_players frp
     where frp.league_id = p_league_id and frp.is_starter
  loop
    if v_source = 'player_box_v1' then
      select points, components into v_points, v_comp
        from public.fantasy_compute_player_box(
          rp.espn_athlete_id, v_league.espn_league,
          v_period.starts_at, v_period.ends_at, v_rules->'components');
      -- if no player stats exist for this athlete/window, fall back to team result
      if coalesce(v_points,0) = 0 and v_comp = '{}'::jsonb then
        select points, components into v_points, v_comp
          from public.fantasy_compute_team_result(
            rp.espn_athlete_id, rp.espn_team_id, v_league.espn_league,
            v_period.starts_at, v_period.ends_at,
            (select rules from public.fantasy_scoring_rules
              where is_preset and espn_league is null and rules->>'source'='team_result_v1' limit 1));
      end if;
    else
      select points, components into v_points, v_comp
        from public.fantasy_compute_team_result(
          rp.espn_athlete_id, rp.espn_team_id, v_league.espn_league,
          v_period.starts_at, v_period.ends_at, v_rules);
    end if;

    insert into public.fantasy_player_scores
      (league_id, period_id, roster_player_id, espn_athlete_id, points, components)
    values
      (p_league_id, p_period_id, rp.id, rp.espn_athlete_id, coalesce(v_points,0), coalesce(v_comp,'{}'::jsonb))
    on conflict (period_id, roster_player_id) do update
      set points = excluded.points, components = excluded.components, computed_at = now();
    v_players := v_players + 1;
  end loop;

  -- roll up to team scores (sum of starters per membership)
  insert into public.fantasy_team_scores (league_id, period_id, membership_id, points)
  select p_league_id, p_period_id, r.membership_id, coalesce(sum(ps.points),0)
    from public.fantasy_rosters r
    join public.fantasy_roster_players frp on frp.roster_id = r.id
    left join public.fantasy_player_scores ps
      on ps.roster_player_id = frp.id and ps.period_id = p_period_id
   where r.league_id = p_league_id
   group by r.membership_id
  on conflict (period_id, membership_id) do update set points = excluded.points;
  get diagnostics v_teams = row_count;

  -- resolve H2H matchups for the period
  update public.fantasy_matchups m set
    home_points = hs.points,
    away_points = aws.points,
    winner_membership_id = case
      when m.away_membership_id is null then m.home_membership_id          -- bye
      when hs.points > coalesce(aws.points,0) then m.home_membership_id
      when coalesce(aws.points,0) > hs.points then m.away_membership_id
      else null end                                                        -- tie
  from public.fantasy_team_scores hs
  left join public.fantasy_team_scores aws
    on aws.period_id = m.period_id and aws.membership_id = m.away_membership_id
  where m.period_id = p_period_id
    and hs.period_id = p_period_id and hs.membership_id = m.home_membership_id;

  update public.fantasy_scoring_periods
     set status = 'scored', scored_at = now() where id = p_period_id;

  return jsonb_build_object('players_scored', v_players, 'teams_scored', v_teams,
                            'source', v_source, 'period_status', 'scored');
end $$;

-- ----------------------------------------------------------------------------
-- fantasy_score_due_periods — score every open period past its end (cron entry)
-- ----------------------------------------------------------------------------
create or replace function public.fantasy_score_due_periods()
returns jsonb
language plpgsql security definer set search_path = public, pg_temp as
$$
declare p record; n int := 0;
begin
  for p in
    select id, league_id from public.fantasy_scoring_periods
     where status = 'open' and ends_at < now()
  loop
    perform public.fantasy_score_period(p.league_id, p.id, false);
    n := n + 1;
  end loop;
  return jsonb_build_object('periods_scored', n, 'ran_at', now());
end $$;

-- grants: commissioner can trigger scoring from the browser; cron uses service_role.
grant execute on function public.fantasy_compute_player_box(text,text,timestamptz,timestamptz,jsonb) to authenticated;
grant execute on function public.fantasy_compute_team_result(text,text,text,timestamptz,timestamptz,jsonb) to authenticated;
grant execute on function public.fantasy_score_period(uuid,bigint,boolean) to authenticated;
grant execute on function public.fantasy_score_due_periods() to authenticated;

commit;

-- Migration 20260605180000 · lane:A1 · writes: event_signal_value + event_signal_latest_at
--   + event_signal_detail + evaluate_user_signal_alerts · reads: v_event_espn_injuries,
--   v_event_espn_news, event_sentiment, v_event_weather, user_alerts · enqueues: alert_mail
--   · pre: 20260605170000_alert_evaluator_performer_venue
--
-- SIGNAL-metric evaluator — makes the non-numeric catalog metrics firable. Kept as a
-- SEPARATE function so the working numeric evaluate_user_alerts() is untouched. Event scope.
--   change-detection (any_change): evt_injury, evt_news — fire on a NEW item since the
--     alert's reference time (last_fired_at, else now-cooldown).
--   numeric thresholds: evt_sentiment (below/above/drop_pct/rise_pct/any_change),
--     evt_weather_temp (below/above °F), evt_weather_precip (above %).
-- Cron (applied live, operator-authorized 2026-06-05):
--   select cron.schedule('evaluate_user_signal_alerts_10min','3-59/10 * * * *',
--     $$ select public.evaluate_user_signal_alerts(); $$);
-- Verified: evt_injury on Wings@Storm → "New injury: Taina Mair — Out"; cooldown re-run 0.

create or replace function public.event_signal_value(p_event_id bigint, p_metric_key text, p_at timestamptz default null)
returns numeric language sql stable security definer set search_path=public,pg_temp as $$
  select case p_metric_key
    when 'evt_sentiment' then (
      select sentiment_index from public.event_sentiment
       where event_id=p_event_id and (p_at is null or captured_at <= p_at)
       order by captured_at desc limit 1)
    when 'evt_weather_temp' then (
      select temp_f from public.v_event_weather
       where tevo_event_id=p_event_id and is_forecast
       order by abs(coalesce(minutes_offset,0)) asc limit 1)
    when 'evt_weather_precip' then (
      select precip_pct from public.v_event_weather
       where tevo_event_id=p_event_id and is_forecast
       order by abs(coalesce(minutes_offset,0)) asc limit 1)
  end;
$$;
revoke all on function public.event_signal_value(bigint,text,timestamptz) from public, anon, authenticated;
grant execute on function public.event_signal_value(bigint,text,timestamptz) to service_role;

create or replace function public.event_signal_latest_at(p_event_id bigint, p_metric_key text)
returns timestamptz language sql stable security definer set search_path=public,pg_temp as $$
  select case p_metric_key
    when 'evt_injury' then (select max(captured_at)  from public.v_event_espn_injuries where tevo_event_id=p_event_id)
    when 'evt_news'   then (select max(published_at) from public.v_event_espn_news     where tevo_event_id=p_event_id)
  end;
$$;
revoke all on function public.event_signal_latest_at(bigint,text) from public, anon, authenticated;
grant execute on function public.event_signal_latest_at(bigint,text) to service_role;

create or replace function public.event_signal_detail(p_event_id bigint, p_metric_key text)
returns text language sql stable security definer set search_path=public,pg_temp as $$
  select case p_metric_key
    when 'evt_injury' then (select athlete_name||' — '||coalesce(status,'')||coalesce(' ('||injury_type||')','')
                            from public.v_event_espn_injuries where tevo_event_id=p_event_id order by captured_at desc limit 1)
    when 'evt_news'   then (select headline from public.v_event_espn_news where tevo_event_id=p_event_id order by published_at desc limit 1)
  end;
$$;
revoke all on function public.event_signal_detail(bigint,text) from public, anon, authenticated;
grant execute on function public.event_signal_detail(bigint,text) to service_role;

create or replace function public.evaluate_user_signal_alerts(p_lookback_hours int default 26)
returns int language plpgsql volatile security definer set search_path=public,pg_temp as $$
declare
  a record; m public.alert_metric_catalog;
  v_cur numeric; v_prior numeric; v_pct numeric; v_at timestamptz; v_ref timestamptz;
  v_fire boolean; v_cnt int := 0; v_unit text; v_desc text; v_subject text; v_html text; v_label text;
begin
  for a in
    select ua.* from public.user_alerts ua
    where ua.active and ua.scope_type='event'
      and (ua.expires_at is null or ua.expires_at > now())
      and (ua.last_fired_at is null or ua.last_fired_at < now() - make_interval(mins => ua.cooldown_minutes))
      and ua.metric_key in ('evt_injury','evt_news','evt_sentiment','evt_weather_temp','evt_weather_precip')
  loop
    v_fire := false; v_desc := null; v_cur := null; v_pct := null;
    v_label := coalesce(nullif(a.scope_label,''),'event '||a.scope_id);

    if a.metric_key in ('evt_injury','evt_news') then
      v_at := public.event_signal_latest_at(a.scope_id, a.metric_key);
      v_ref := coalesce(a.last_fired_at, now() - make_interval(mins => a.cooldown_minutes));
      if v_at is null or v_at <= v_ref then continue; end if;
      v_fire := true;
      v_desc := coalesce(public.event_signal_detail(a.scope_id, a.metric_key), 'new item');
    else
      v_cur := public.event_signal_value(a.scope_id, a.metric_key);
      if v_cur is null then continue; end if;
      if a.operator='below' then v_fire := a.threshold is not null and v_cur < a.threshold;
      elsif a.operator='above' then v_fire := a.threshold is not null and v_cur > a.threshold;
      elsif a.operator in ('drop_pct','rise_pct','any_change') then
        v_prior := public.event_signal_value(a.scope_id, a.metric_key, now() - make_interval(hours=>p_lookback_hours));
        if v_prior is null or v_prior=0 then continue; end if;
        v_pct := round((v_cur - v_prior)/v_prior*100.0, 1);
        if a.operator='drop_pct' then v_fire := (-v_pct) >= a.threshold;
        elsif a.operator='rise_pct' then v_fire := v_pct >= a.threshold;
        else v_fire := abs(v_pct) >= coalesce(a.threshold,10); end if;
      end if;
      if not v_fire then continue; end if;
    end if;

    select * into m from public.alert_metric_catalog where metric_key = a.metric_key;
    v_unit := coalesce(m.threshold_unit,'');
    if v_desc is not null then
      v_subject := '🔔 '||m.label||' — '||v_label;
      v_desc := m.label||': '||v_desc;
    else
      v_desc := m.label||' is '||(case when v_unit='$' then '$' else '' end)||to_char(v_cur,'FM999,990.0')||
                (case when v_unit not in ('$','') then ' '||v_unit else '' end)||
                (case when v_pct is not null then ' ('||v_pct||'% vs '||p_lookback_hours||'h)' else '' end);
      v_subject := '🔔 '||m.label||' '||
                   (case when a.operator='below' then 'below '||a.threshold when a.operator='above' then 'above '||a.threshold else 'moved' end)||
                   ' — '||v_label;
    end if;

    v_html :=
      '<div style="font-family:-apple-system,Segoe UI,Roboto,sans-serif;max-width:560px;margin:0 auto">'||
      '<div style="background:#0a0a0a;color:#fff;padding:16px 20px;border-radius:8px 8px 0 0">'||
      '<div style="font-size:11px;letter-spacing:1px;color:#9ab;text-transform:uppercase">S4K Terminal · Signal Alert</div>'||
      '<div style="font-size:18px;font-weight:700;margin-top:4px">'||v_label||'</div></div>'||
      '<div style="border:1px solid #eee;border-top:none;border-radius:0 0 8px 8px;padding:18px 20px">'||
      '<div style="font-size:15px;color:#111">'||v_desc||'</div>'||
      '<a href="https://vibepass-terminal-test.onrender.com/terminal/event.html?event='||a.scope_id||
        '" style="display:inline-block;margin-top:14px;background:#2563eb;color:#fff;text-decoration:none;padding:9px 16px;border-radius:6px;font-size:13px;font-weight:600">Open event</a></div></div>';

    if 'email' = any(a.channels) and coalesce(nullif(trim(a.notify_email),''),'') <> '' then
      insert into public.alert_mail (to_email, template, subject, html) values (a.notify_email,'user-alert-signal',v_subject,v_html);
      v_cnt := v_cnt + 1;
    end if;
    update public.user_alerts set last_fired_at = now() where id = a.id;
  end loop;
  return v_cnt;
end $$;
revoke all on function public.evaluate_user_signal_alerts(int) from public, anon, authenticated;
grant execute on function public.evaluate_user_signal_alerts(int) to service_role;

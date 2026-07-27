-- Migration 20260605170000 · lane:A1 · writes: performer_metric_value + venue_metric_value
--   + scope_metric_value + scope_alert_check + evaluate_user_alerts (generalized)
--   + alert_metric_catalog (perf_all, ven_all) · reads: events, event_metrics, user_alerts
--   · pre: 20260605160000_alert_evaluator_and_track_all
--
-- Extends the alert evaluator from event-only to PERFORMER + VENUE scope. The
-- resolvers aggregate event_metrics across a scope's UPCOMING events:
--   performer: portfolio median (median of per-event medians), cheapest event floor
--   venue:     owned median, total availability
-- evaluate_user_alerts() is generalized to loop all three scopes; each supports a
-- single metric OR the scope's "All metrics" pick (evt_all / perf_all / ven_all).
-- Applied to prod 2026-06-05; verified: performer + venue single-metric and *_all
-- both fire and render (Braves portfolio +2.0%, Truist Park multi-metric).

create or replace function public.performer_metric_value(p_performer_id bigint, p_metric_key text, p_at timestamptz default null)
returns numeric language sql stable security definer set search_path=public,pg_temp as $$
  with latest as (
    select v.retail_min, v.retail_median, v.owned_median_retail, v.tickets_count
    from public.events e,
    lateral (
      select em.retail_min, em.retail_median, em.owned_median_retail, em.tickets_count
      from public.event_metrics em
      where em.event_id = e.id and (p_at is null or em.captured_at <= p_at)
      order by em.captured_at desc limit 1
    ) v
    where e.primary_performer_id = p_performer_id and e.occurs_at_local::timestamptz > now()
  )
  select case p_metric_key
           when 'perf_any_event_floor' then min(retail_min)
           when 'perf_portfolio_move'  then percentile_cont(0.5) within group (order by retail_median)
         end
  from latest;
$$;
revoke all on function public.performer_metric_value(bigint,text,timestamptz) from public, anon, authenticated;
grant execute on function public.performer_metric_value(bigint,text,timestamptz) to service_role;

create or replace function public.venue_metric_value(p_venue_id bigint, p_metric_key text, p_at timestamptz default null)
returns numeric language sql stable security definer set search_path=public,pg_temp as $$
  with latest as (
    select v.retail_median, v.owned_median_retail, v.tickets_count
    from public.events e,
    lateral (
      select em.retail_median, em.owned_median_retail, em.tickets_count
      from public.event_metrics em
      where em.event_id = e.id and (p_at is null or em.captured_at <= p_at)
      order by em.captured_at desc limit 1
    ) v
    where e.venue_id = p_venue_id and e.occurs_at_local::timestamptz > now()
  )
  select case p_metric_key
           when 'ven_owned_price'  then percentile_cont(0.5) within group (order by owned_median_retail)
           when 'ven_availability' then sum(tickets_count)
         end
  from latest;
$$;
revoke all on function public.venue_metric_value(bigint,text,timestamptz) from public, anon, authenticated;
grant execute on function public.venue_metric_value(bigint,text,timestamptz) to service_role;

create or replace function public.scope_metric_value(p_scope_type text, p_scope_id bigint, p_metric_key text, p_at timestamptz default null)
returns numeric language sql stable security definer set search_path=public,pg_temp as $$
  select case p_scope_type
           when 'event'     then public.event_metric_value(p_scope_id, p_metric_key, p_at)
           when 'performer' then public.performer_metric_value(p_scope_id, p_metric_key, p_at)
           when 'venue'     then public.venue_metric_value(p_scope_id, p_metric_key, p_at)
         end;
$$;
revoke all on function public.scope_metric_value(text,bigint,text,timestamptz) from public, anon, authenticated;
grant execute on function public.scope_metric_value(text,bigint,text,timestamptz) to service_role;

create or replace function public.scope_alert_check(
  p_scope_type text, p_scope_id bigint, p_metric_key text, p_operator text, p_threshold numeric, p_lookback_hours int
) returns table(fired boolean, cur numeric, pct numeric)
language plpgsql stable security definer set search_path=public,pg_temp as $$
declare v_cur numeric; v_prior numeric; v_pct numeric; v_fire boolean := false;
begin
  v_cur := public.scope_metric_value(p_scope_type, p_scope_id, p_metric_key);
  if v_cur is null then return query select false, null::numeric, null::numeric; return; end if;
  if p_operator='below' then v_fire := p_threshold is not null and v_cur < p_threshold;
  elsif p_operator='above' then v_fire := p_threshold is not null and v_cur > p_threshold;
  elsif p_operator='available' then v_fire := v_cur > 0;
  elsif p_operator in ('drop_pct','rise_pct','any_change') then
    v_prior := public.scope_metric_value(p_scope_type, p_scope_id, p_metric_key, now()-make_interval(hours=>p_lookback_hours));
    if v_prior is null or v_prior=0 then return query select false, v_cur, null::numeric; return; end if;
    v_pct := round((v_cur-v_prior)/v_prior*100.0,1);
    if    p_operator='drop_pct'  then v_fire := (-v_pct) >= p_threshold;
    elsif p_operator='rise_pct'  then v_fire := v_pct    >= p_threshold;
    else  v_fire := abs(v_pct) >= coalesce(p_threshold,10); end if;
  end if;
  return query select v_fire, v_cur, v_pct;
end $$;
revoke all on function public.scope_alert_check(text,bigint,text,text,numeric,int) from public, anon, authenticated;
grant execute on function public.scope_alert_check(text,bigint,text,text,numeric,int) to service_role;

insert into public.alert_metric_catalog
  (metric_key, scope_type, label, value_kind, allowed_operators, default_operator, threshold_unit, param_kind, source_note, sort_order)
values
  ('perf_all','performer','⭐ All metrics (any significant move)','index','{any_change,drop_pct,rise_pct}','any_change','%',null,'event_metrics across performer (floor/portfolio median)',1),
  ('ven_all', 'venue','⭐ All metrics (any significant move)','index','{any_change,drop_pct,rise_pct}','any_change','%',null,'event_metrics across venue (owned median/availability)',1)
on conflict (metric_key) do update set
  label=excluded.label, allowed_operators=excluded.allowed_operators, default_operator=excluded.default_operator,
  threshold_unit=excluded.threshold_unit, source_note=excluded.source_note, sort_order=excluded.sort_order, active=true;

create or replace function public.evaluate_user_alerts(p_lookback_hours int default 26)
returns int language plpgsql volatile security definer set search_path=public,pg_temp as $$
declare
  a record; m public.alert_metric_catalog; mk text; c record;
  v_cur numeric; v_pct numeric; v_fire boolean; v_cnt int := 0;
  v_unit text; v_cmp text; v_subject text; v_html text; v_label text; v_rows text;
  k_arr text[]; all_key text; url_path text; lbl jsonb;
begin
  for a in
    select ua.* from public.user_alerts ua
    where ua.active
      and (ua.expires_at is null or ua.expires_at > now())
      and (ua.last_fired_at is null or ua.last_fired_at < now() - make_interval(mins => ua.cooldown_minutes))
  loop
    if a.scope_type='event' then
      k_arr := array['evt_price_floor','evt_get_in','evt_price_median','evt_price_p90','evt_listings_total','evt_owned_median','evt_owned_count'];
      all_key := 'evt_all'; url_path := 'event.html?event=';
      lbl := '{"evt_price_floor":"Floor","evt_get_in":"Get-in","evt_price_median":"Median","evt_price_p90":"P90","evt_listings_total":"Listings","evt_owned_median":"Owned median","evt_owned_count":"Owned qty"}'::jsonb;
    elsif a.scope_type='performer' then
      k_arr := array['perf_any_event_floor','perf_portfolio_move'];
      all_key := 'perf_all'; url_path := 'performer.html?performer=';
      lbl := '{"perf_any_event_floor":"Cheapest event floor","perf_portfolio_move":"Portfolio median"}'::jsonb;
    elsif a.scope_type='venue' then
      k_arr := array['ven_owned_price','ven_availability'];
      all_key := 'ven_all'; url_path := 'venue.html?venue=';
      lbl := '{"ven_owned_price":"Owned median","ven_availability":"Availability"}'::jsonb;
    else continue; end if;

    if a.metric_key <> all_key and not (a.metric_key = any(k_arr)) then continue; end if;
    v_label := coalesce(nullif(a.scope_label,''), a.scope_type||' '||a.scope_id);

    if a.metric_key = all_key then
      v_rows := ''; v_fire := false;
      foreach mk in array k_arr loop
        select * into c from public.scope_alert_check(a.scope_type, a.scope_id, mk, a.operator, a.threshold, p_lookback_hours);
        if c.fired then
          v_fire := true;
          v_rows := v_rows ||
            '<tr><td style="padding:6px 10px;border-bottom:1px solid #eee;font-size:13px">'||(lbl->>mk)||'</td>'||
            '<td style="padding:6px 10px;border-bottom:1px solid #eee;font-size:13px;text-align:right">'||coalesce(to_char(c.cur,'FM999,999,990.00'),'-')||'</td>'||
            '<td style="padding:6px 10px;border-bottom:1px solid #eee;font-size:13px;text-align:right;color:'||(case when coalesce(c.pct,0)<0 then '#c0392b' else '#0a7d2c' end)||'">'||coalesce(c.pct::text||'%','')||'</td></tr>';
        end if;
      end loop;
      if not v_fire then continue; end if;
      v_subject := '🔔 Multiple metrics moved — '||v_label;
      v_html :=
        '<div style="font-family:-apple-system,Segoe UI,Roboto,sans-serif;max-width:560px;margin:0 auto">'||
        '<div style="background:#0a0a0a;color:#fff;padding:16px 20px;border-radius:8px 8px 0 0">'||
        '<div style="font-size:11px;letter-spacing:1px;color:#9ab;text-transform:uppercase">S4K Terminal · Alert · All metrics</div>'||
        '<div style="font-size:18px;font-weight:700;margin-top:4px">'||v_label||'</div></div>'||
        '<div style="border:1px solid #eee;border-top:none;border-radius:0 0 8px 8px;padding:16px 20px">'||
        '<div style="font-size:14px;color:#111;margin-bottom:8px">These tracked metrics moved'||
          (case when a.operator='any_change' then ' ≥'||coalesce(a.threshold,10)||'%' when a.operator='drop_pct' then ' down ≥'||a.threshold||'%' else ' up ≥'||a.threshold||'%' end)||
          ' vs '||p_lookback_hours||'h ago:</div>'||
        '<table style="width:100%;border-collapse:collapse"><thead><tr style="background:#f7f7f8">'||
        '<th style="padding:6px 10px;text-align:left;font-size:10px;color:#888">METRIC</th>'||
        '<th style="padding:6px 10px;text-align:right;font-size:10px;color:#888">NOW</th>'||
        '<th style="padding:6px 10px;text-align:right;font-size:10px;color:#888">CHANGE</th></tr></thead><tbody>'||v_rows||'</tbody></table>'||
        '<a href="https://vibepass-terminal-test.onrender.com/terminal/'||url_path||a.scope_id||'" style="display:inline-block;margin-top:14px;background:#2563eb;color:#fff;text-decoration:none;padding:9px 16px;border-radius:6px;font-size:13px;font-weight:600">Open</a></div></div>';
      if 'email' = any(a.channels) and coalesce(nullif(trim(a.notify_email),''),'') <> '' then
        insert into public.alert_mail (to_email, template, subject, html) values (a.notify_email,'user-alert-all',v_subject,v_html);
        v_cnt := v_cnt + 1;
      end if;
      update public.user_alerts set last_fired_at = now() where id = a.id;
      continue;
    end if;

    select * into c from public.scope_alert_check(a.scope_type, a.scope_id, a.metric_key, a.operator, a.threshold, p_lookback_hours);
    if not c.fired then continue; end if;
    v_cur := c.cur; v_pct := c.pct;
    select * into m from public.alert_metric_catalog where metric_key = a.metric_key;
    v_unit := coalesce(m.threshold_unit,'');
    v_cmp := case
               when a.operator='below' then 'fell below '||(case when v_unit='$' then '$' else '' end)||a.threshold
               when a.operator='above' then 'rose above '||(case when v_unit='$' then '$' else '' end)||a.threshold
               when a.operator='drop_pct' then 'dropped '||abs(v_pct)||'% (>= '||a.threshold||'%)'
               when a.operator='rise_pct' then 'rose '||v_pct||'% (>= '||a.threshold||'%)'
               when a.operator='available' then 'is now available' end;
    v_subject := '🔔 '||m.label||' '||v_cmp||' — '||v_label;
    v_html :=
      '<div style="font-family:-apple-system,Segoe UI,Roboto,sans-serif;max-width:560px;margin:0 auto">'||
      '<div style="background:#0a0a0a;color:#fff;padding:16px 20px;border-radius:8px 8px 0 0">'||
      '<div style="font-size:11px;letter-spacing:1px;color:#9ab;text-transform:uppercase">S4K Terminal · Alert</div>'||
      '<div style="font-size:18px;font-weight:700;margin-top:4px">'||v_label||'</div></div>'||
      '<div style="border:1px solid #eee;border-top:none;border-radius:0 0 8px 8px;padding:18px 20px">'||
      '<div style="font-size:15px;color:#111"><b>'||m.label||'</b> '||v_cmp||'.</div>'||
      '<div style="font-size:13px;color:#555;margin-top:8px">Current: <b>'||(case when v_unit='$' then '$' else '' end)||to_char(v_cur,'FM999,999,990.00')||
        (case when v_unit not in ('$','') then ' '||v_unit else '' end)||'</b>'||
        (case when v_pct is not null then ' · '||v_pct||'% vs '||p_lookback_hours||'h ago' else '' end)||'</div>'||
      '<a href="https://vibepass-terminal-test.onrender.com/terminal/'||url_path||a.scope_id||'" style="display:inline-block;margin-top:14px;background:#2563eb;color:#fff;text-decoration:none;padding:9px 16px;border-radius:6px;font-size:13px;font-weight:600">Open</a></div></div>';
    if 'email' = any(a.channels) and coalesce(nullif(trim(a.notify_email),''),'') <> '' then
      insert into public.alert_mail (to_email, template, subject, html) values (a.notify_email,'user-alert',v_subject,v_html);
      v_cnt := v_cnt + 1;
    end if;
    update public.user_alerts set last_fired_at = now() where id = a.id;
  end loop;
  return v_cnt;
end $$;
revoke all on function public.evaluate_user_alerts(int) from public, anon, authenticated;
grant execute on function public.evaluate_user_alerts(int) to service_role;

-- Migration 20260605160000 · lane:A1 · writes: evaluate_user_alerts + event_alert_check
--   + event_metric_value + alert_metric_catalog (evt_price_p90/evt_owned_median/
--   evt_owned_count/evt_all) · reads: event_metrics, user_alerts · enqueues: alert_mail
--   · pre: 20260605150800_user_alerts, 20260604125000_alert_mail_queue
--
-- Phase-2 EVALUATOR for the user alert system — the piece that makes user_alerts
-- actually fire. Unifies on user_alerts (the rich per-metric model the Alerts-tab
-- FE creates); the parallel event_watchlist digest path is NOT used by this.
--
-- For each active, off-cooldown, non-expired EVENT-scope alert on a numeric metric,
-- resolve the current value from event_metrics (latest captured_at), compare per
-- operator (below / above / drop_pct / rise_pct / available), and on trigger enqueue
-- a rendered email into alert_mail + stamp last_fired_at. Cooldown makes it idempotent.
--
-- "Track one OR all": a user can pick a single metric, or the catalog's evt_all
-- ("⭐ All metrics") — one subscription that fires if ANY tracked numeric metric
-- moves (any_change uses a default 10% sensitivity unless a threshold is set).
-- The Alerts-tab dropdown is data-driven from get_alert_metric_catalog(), so the
-- new rows below appear automatically with no FE change.
--
-- Cron (applied live, operator-authorized 2026-06-05):
--   select cron.schedule('evaluate_user_alerts_10min','*/10 * * * *',
--     $$ select public.evaluate_user_alerts(); $$);   -- jobid 362
--
-- Delivery: alert_mail is drained by the alert-mail-drain edge fn (separate). That
-- needs a Resend key + verified sender configured before anything actually sends.

-- ── current value of a numeric event metric (optionally as-of a timestamp) ───
create or replace function public.event_metric_value(p_event_id bigint, p_metric_key text, p_at timestamptz default null)
returns numeric language sql stable security definer set search_path=public,pg_temp as $$
  select case p_metric_key
           when 'evt_price_floor'    then em.retail_min
           when 'evt_get_in'         then coalesce(em.getin_price, em.retail_min)
           when 'evt_price_median'   then em.retail_median
           when 'evt_price_p90'      then em.retail_p90
           when 'evt_listings_total' then em.tickets_count::numeric
           when 'evt_owned_median'   then em.owned_median_retail
           when 'evt_owned_count'    then em.owned_tickets_count::numeric
         end
  from public.event_metrics em
  where em.event_id = p_event_id
    and (p_at is null or em.captured_at <= p_at)
  order by em.captured_at desc
  limit 1;
$$;
revoke all on function public.event_metric_value(bigint,text,timestamptz) from public, anon, authenticated;
grant execute on function public.event_metric_value(bigint,text,timestamptz) to service_role;

-- ── reusable per-metric condition check ──────────────────────────────────────
create or replace function public.event_alert_check(
  p_event_id bigint, p_metric_key text, p_operator text, p_threshold numeric, p_lookback_hours int
) returns table(fired boolean, cur numeric, pct numeric)
language plpgsql stable security definer set search_path=public,pg_temp as $$
declare v_cur numeric; v_prior numeric; v_pct numeric; v_fire boolean := false;
begin
  v_cur := public.event_metric_value(p_event_id, p_metric_key);
  if v_cur is null then return query select false, null::numeric, null::numeric; return; end if;
  if p_operator='below' then v_fire := p_threshold is not null and v_cur < p_threshold;
  elsif p_operator='above' then v_fire := p_threshold is not null and v_cur > p_threshold;
  elsif p_operator='available' then v_fire := v_cur > 0;
  elsif p_operator in ('drop_pct','rise_pct','any_change') then
    v_prior := public.event_metric_value(p_event_id, p_metric_key, now()-make_interval(hours=>p_lookback_hours));
    if v_prior is null or v_prior=0 then return query select false, v_cur, null::numeric; return; end if;
    v_pct := round((v_cur-v_prior)/v_prior*100.0,1);
    if    p_operator='drop_pct'  then v_fire := (-v_pct) >= p_threshold;
    elsif p_operator='rise_pct'  then v_fire := v_pct    >= p_threshold;
    else  v_fire := abs(v_pct) >= coalesce(p_threshold,10); end if;   -- any_change
  end if;
  return query select v_fire, v_cur, v_pct;
end $$;
revoke all on function public.event_alert_check(bigint,text,text,numeric,int) from public, anon, authenticated;
grant execute on function public.event_alert_check(bigint,text,text,numeric,int) to service_role;

-- ── catalog: new firable numeric metrics + the "All metrics" pick ────────────
insert into public.alert_metric_catalog
  (metric_key, scope_type, label, value_kind, allowed_operators, default_operator, threshold_unit, param_kind, source_note, sort_order)
values
  ('evt_all',         'event','⭐ All metrics (any significant move)','index','{any_change,drop_pct,rise_pct}','any_change','%',null,'event_metrics (floor/get-in/median/p90/listings/owned)',1),
  ('evt_price_p90',   'event','90th-percentile ask price','price','{drop_pct,rise_pct,below,above}','above','$',null,'event_metrics.retail_p90',25),
  ('evt_owned_median','event','Our owned median price','price','{drop_pct,rise_pct,below,above}','below','$',null,'event_metrics.owned_median_retail',35),
  ('evt_owned_count', 'event','Our owned ticket count','count','{below,above,any_change}','below','tickets',null,'event_metrics.owned_tickets_count',36)
on conflict (metric_key) do update set
  label=excluded.label, allowed_operators=excluded.allowed_operators, default_operator=excluded.default_operator,
  threshold_unit=excluded.threshold_unit, source_note=excluded.source_note, sort_order=excluded.sort_order, active=true;

-- ── the evaluator: single metric OR evt_all (expands across the numeric set) ──
create or replace function public.evaluate_user_alerts(p_lookback_hours int default 26)
returns int language plpgsql volatile security definer set search_path=public,pg_temp as $$
declare
  a record; m public.alert_metric_catalog; mk text;
  v_cur numeric; v_pct numeric; v_fire boolean; v_cnt int := 0;
  v_unit text; v_cmp text; v_subject text; v_html text; v_label text; v_rows text;
  c record;
  k_all text[] := array['evt_price_floor','evt_get_in','evt_price_median','evt_price_p90','evt_listings_total','evt_owned_median','evt_owned_count'];
  k_lbl jsonb := '{"evt_price_floor":"Floor","evt_get_in":"Get-in","evt_price_median":"Median","evt_price_p90":"P90","evt_listings_total":"Listings","evt_owned_median":"Owned median","evt_owned_count":"Owned qty"}'::jsonb;
begin
  for a in
    select ua.* from public.user_alerts ua
    where ua.active and ua.scope_type='event'
      and (ua.expires_at is null or ua.expires_at > now())
      and (ua.last_fired_at is null or ua.last_fired_at < now() - make_interval(mins => ua.cooldown_minutes))
      and ua.metric_key = any (k_all || array['evt_all'])
  loop
    if a.metric_key = 'evt_all' then
      v_rows := ''; v_fire := false;
      foreach mk in array k_all loop
        select * into c from public.event_alert_check(a.scope_id, mk, a.operator, a.threshold, p_lookback_hours);
        if c.fired then
          v_fire := true;
          v_rows := v_rows ||
            '<tr><td style="padding:6px 10px;border-bottom:1px solid #eee;font-size:13px">'||(k_lbl->>mk)||'</td>'||
            '<td style="padding:6px 10px;border-bottom:1px solid #eee;font-size:13px;text-align:right">'||coalesce(to_char(c.cur,'FM999,999,990.00'),'-')||'</td>'||
            '<td style="padding:6px 10px;border-bottom:1px solid #eee;font-size:13px;text-align:right;color:'||(case when coalesce(c.pct,0)<0 then '#c0392b' else '#0a7d2c' end)||'">'||coalesce(c.pct::text||'%','')||'</td></tr>';
        end if;
      end loop;
      if not v_fire then continue; end if;
      v_label := coalesce(nullif(a.scope_label,''),'event '||a.scope_id);
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
        '<a href="https://vibepass-terminal-test.onrender.com/terminal/event.html?event='||a.scope_id||'" style="display:inline-block;margin-top:14px;background:#2563eb;color:#fff;text-decoration:none;padding:9px 16px;border-radius:6px;font-size:13px;font-weight:600">Open event</a></div></div>';
      if 'email' = any(a.channels) and coalesce(nullif(trim(a.notify_email),''),'') <> '' then
        insert into public.alert_mail (to_email, template, subject, html) values (a.notify_email,'user-alert-all',v_subject,v_html);
        v_cnt := v_cnt + 1;
      end if;
      update public.user_alerts set last_fired_at = now() where id = a.id;
      continue;
    end if;

    -- single-metric path
    select * into c from public.event_alert_check(a.scope_id, a.metric_key, a.operator, a.threshold, p_lookback_hours);
    if not c.fired then continue; end if;
    v_cur := c.cur; v_pct := c.pct;
    select * into m from public.alert_metric_catalog where metric_key = a.metric_key;
    v_unit := coalesce(m.threshold_unit,'');
    v_label := coalesce(nullif(a.scope_label,''),'event '||a.scope_id);
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
      '<div style="font-size:11px;letter-spacing:1px;color:#9ab;text-transform:uppercase">S4K Terminal · Price Alert</div>'||
      '<div style="font-size:18px;font-weight:700;margin-top:4px">'||v_label||'</div></div>'||
      '<div style="border:1px solid #eee;border-top:none;border-radius:0 0 8px 8px;padding:18px 20px">'||
      '<div style="font-size:15px;color:#111"><b>'||m.label||'</b> '||v_cmp||'.</div>'||
      '<div style="font-size:13px;color:#555;margin-top:8px">Current: <b>'||(case when v_unit='$' then '$' else '' end)||to_char(v_cur,'FM999,999,990.00')||
        (case when v_unit not in ('$','') then ' '||v_unit else '' end)||'</b>'||
        (case when v_pct is not null then ' · '||v_pct||'% vs '||p_lookback_hours||'h ago' else '' end)||'</div>'||
      '<a href="https://vibepass-terminal-test.onrender.com/terminal/event.html?event='||a.scope_id||'" style="display:inline-block;margin-top:14px;background:#2563eb;color:#fff;text-decoration:none;padding:9px 16px;border-radius:6px;font-size:13px;font-weight:600">Open event</a></div></div>';
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

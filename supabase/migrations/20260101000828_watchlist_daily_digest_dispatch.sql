-- Migration 20260605200000 · lane:A1 · writes: event_digest_fragment +
--   build_watchlist_daily_email + dispatch_watchlist_daily · reads: event_watchlist,
--   events, event_listing_snapshot_daily, seatgeek_sales_snapshots · enqueues: alert_mail
--   · pre: 20260603190000_event_watchlist, 20260605190000_event_daily_digest_renderer
--
-- Per-user WATCHLIST daily digest: one email per person covering every event on
-- their event_watchlist (alert_enabled, upcoming), each rendered with the
-- per-source (TEvo/SeatGeek/TicketsData) 24h price + volume + sales table.
--
-- Cron (applied live, operator-authorized 2026-06-05):
--   select cron.schedule('dispatch_watchlist_daily_8am','0 13 * * *',
--     $$ select public.dispatch_watchlist_daily(); $$);   -- jobid 364, ~8-9am ET
-- Delivery of the enqueued alert_mail rows is handled separately (Gmail/Zapier
-- agent-driven today; a Zapier Catch-Hook or Resend automates it hands-off).
-- Verified live: 3-event watchlist for julian@s4kent.com rendered + emailed.

create or replace function public.event_digest_fragment(p_event_id bigint)
returns text language plpgsql stable security definer set search_path=public,pg_temp as $$
declare
  cur record; prv record; sg_qty int; sg_qty_prev int; sg_gross numeric;
  td_cur numeric; td_prev numeric;
begin
  select * into cur from public.event_listing_snapshot_daily where event_id=p_event_id order by captured_at desc limit 1;
  if cur.event_id is null then
    return '<div style="padding:8px 12px;font-size:12px;color:#999;border:1px solid #eee;border-top:none">No multi-source snapshot yet for this event.</div>';
  end if;
  select * into prv from public.event_listing_snapshot_daily
    where event_id=p_event_id and captured_at <= cur.captured_at - interval '20 hours' order by captured_at desc limit 1;
  select coalesce(sum(quantity),0) into sg_qty from public.seatgeek_sales_snapshots where tevo_event_id=p_event_id and sale_at_utc > now()-interval '24 hours';
  select coalesce(sum(quantity),0) into sg_qty_prev from public.seatgeek_sales_snapshots where tevo_event_id=p_event_id and sale_at_utc <= now()-interval '24 hours' and sale_at_utc > now()-interval '48 hours';
  select coalesce(sum(quantity*broadcast_price),0) into sg_gross from public.seatgeek_sales_snapshots where tevo_event_id=p_event_id and sale_at_utc > now()-interval '24 hours';
  td_cur  := coalesce(cur.td_sh_listings,0)+coalesce(cur.td_gt_listings,0)+coalesce(cur.td_vd_listings,0)+coalesce(cur.td_tp_listings,0)+coalesce(cur.td_tm_listings,0);
  td_prev := coalesce(prv.td_sh_listings,0)+coalesce(prv.td_gt_listings,0)+coalesce(prv.td_vd_listings,0)+coalesce(prv.td_tp_listings,0)+coalesce(prv.td_tm_listings,0);

  return
    '<table style="width:100%;border-collapse:collapse;border:1px solid #eee;border-top:none">'||
    '<thead><tr style="background:#fafafb">'||
    '<th style="padding:6px 10px;text-align:left;font-size:9px;color:#999;text-transform:uppercase">Source</th>'||
    '<th style="padding:6px 10px;text-align:right;font-size:9px;color:#999;text-transform:uppercase">Median</th>'||
    '<th style="padding:6px 10px;text-align:right;font-size:9px;color:#999;text-transform:uppercase">Get-in</th>'||
    '<th style="padding:6px 10px;text-align:right;font-size:9px;color:#999;text-transform:uppercase">Volume</th>'||
    '<th style="padding:6px 10px;text-align:right;font-size:9px;color:#999;text-transform:uppercase">Sold 24h</th></tr></thead><tbody>'||
    '<tr><td style="padding:7px 10px;border-bottom:1px solid #f0f0f0;font-size:12px;font-weight:600">TEvo</td>'||
      '<td style="padding:7px 10px;border-bottom:1px solid #f0f0f0;font-size:12px;text-align:right">'||public._digest_cell(cur.evo_retail_median, prv.evo_retail_median,'$',0)||'</td>'||
      '<td style="padding:7px 10px;border-bottom:1px solid #f0f0f0;font-size:12px;text-align:right">'||public._digest_cell(cur.evo_retail_getin, prv.evo_retail_getin,'$',0)||'</td>'||
      '<td style="padding:7px 10px;border-bottom:1px solid #f0f0f0;font-size:12px;text-align:right">'||public._digest_cell(cur.evo_tickets_count, prv.evo_tickets_count,'',0)||'</td>'||
      '<td style="padding:7px 10px;border-bottom:1px solid #f0f0f0;font-size:12px;text-align:right;color:#bbb">&mdash;</td></tr>'||
    '<tr><td style="padding:7px 10px;border-bottom:1px solid #f0f0f0;font-size:12px;font-weight:600">SeatGeek</td>'||
      '<td style="padding:7px 10px;border-bottom:1px solid #f0f0f0;font-size:12px;text-align:right">'||public._digest_cell(cur.sg_all_median, prv.sg_all_median,'$',0)||'</td>'||
      '<td style="padding:7px 10px;border-bottom:1px solid #f0f0f0;font-size:12px;text-align:right">'||public._digest_cell(cur.sg_all_getin, prv.sg_all_getin,'$',0)||'</td>'||
      '<td style="padding:7px 10px;border-bottom:1px solid #f0f0f0;font-size:12px;text-align:right">'||public._digest_cell(cur.sg_all_listings, prv.sg_all_listings,'',0)||'</td>'||
      '<td style="padding:7px 10px;border-bottom:1px solid #f0f0f0;font-size:12px;text-align:right">'||public._digest_cell(sg_qty, nullif(sg_qty_prev,0),'',0)||'</td></tr>'||
    '<tr><td style="padding:7px 10px;border-bottom:1px solid #f0f0f0;font-size:12px;font-weight:600">TicketsData</td>'||
      '<td style="padding:7px 10px;border-bottom:1px solid #f0f0f0;font-size:12px;text-align:right">'||public._digest_cell(cur.td_combined_median, prv.td_combined_median,'$',0)||'</td>'||
      '<td style="padding:7px 10px;border-bottom:1px solid #f0f0f0;font-size:12px;text-align:right">'||public._digest_cell(cur.amalgam_getin, prv.amalgam_getin,'$',0)||'</td>'||
      '<td style="padding:7px 10px;border-bottom:1px solid #f0f0f0;font-size:12px;text-align:right">'||public._digest_cell(td_cur, nullif(td_prev,0),'',0)||'</td>'||
      '<td style="padding:7px 10px;border-bottom:1px solid #f0f0f0;font-size:12px;text-align:right;color:#bbb">&mdash;</td></tr></tbody></table>'||
    case when sg_qty>0 then '<div style="padding:6px 12px;font-size:11px;color:#555;border:1px solid #eee;border-top:none">SeatGeek 24h sales: '||sg_qty||' tix'||case when sg_gross>0 then ' &middot; $'||to_char(round(sg_gross),'FM999,999,990') else '' end||'</div>' else '' end;
end $$;
revoke all on function public.event_digest_fragment(bigint) from public, anon, authenticated;
grant execute on function public.event_digest_fragment(bigint) to service_role;

create or replace function public.build_watchlist_daily_email(p_user_email text, p_limit int default 15)
returns table(subject text, html text)
language plpgsql stable security definer set search_path=public,pg_temp as $$
declare r record; v_body text := ''; n int := 0;
begin
  for r in
    select w.tevo_event_id, coalesce(e.name, w.event_name) nm,
           coalesce(e.venue_name, w.venue_name) vn, coalesce(e.occurs_at_local, w.occurs_at_local) dt
    from public.event_watchlist w
    left join public.events e on e.id = w.tevo_event_id
    where w.user_email = lower(p_user_email) and w.alert_enabled
      and coalesce(e.occurs_at_local, w.occurs_at_local) > to_char(now(),'YYYY-MM-DD')
    order by coalesce(e.occurs_at_local, w.occurs_at_local) asc
    limit p_limit
  loop
    n := n + 1;
    v_body := v_body ||
      '<div style="margin-top:16px"><div style="background:#1b1b1f;color:#fff;padding:10px 14px;border-radius:6px 6px 0 0">'||
      '<div style="font-size:14px;font-weight:700">'||coalesce(r.nm,'Event '||r.tevo_event_id)||'</div>'||
      '<div style="font-size:11px;color:#9aa">'||coalesce(r.vn,'')||case when r.dt is not null then ' &middot; '||left(r.dt,16) else '' end||'</div></div>'||
      public.event_digest_fragment(r.tevo_event_id)||'</div>';
  end loop;
  if n = 0 then return; end if;
  return query select
    '📊 Your watchlist — daily digest ('||n||' event'||case when n=1 then '' else 's' end||', 24h movement)',
    '<div style="font-family:-apple-system,Segoe UI,Roboto,sans-serif;max-width:680px;margin:0 auto;background:#fff;padding-bottom:8px">'||
    '<div style="background:#0a0a0a;color:#fff;padding:18px 22px;border-radius:8px 8px 0 0">'||
    '<div style="font-size:11px;letter-spacing:1px;color:#9ab;text-transform:uppercase">S4K Terminal &middot; Watchlist Daily Digest</div>'||
    '<div style="font-size:20px;font-weight:700;margin-top:4px">'||n||' tracked event'||case when n=1 then '' else 's' end||' &middot; 24h movement</div>'||
    '<div style="font-size:12px;color:#aaa;margin-top:3px">'||to_char(now(),'Dy Mon DD')||' &middot; per-source price, volume &amp; sales vs ~24h ago</div></div>'||
    v_body||
    '<div style="padding:14px 22px;font-size:11px;color:#999">Arrows = change vs ~24h ago. Manage your watchlist in the '||
    '<a href="https://vibepass-terminal-test.onrender.com/index.html" style="color:#2563eb">terminal</a>.</div></div>';
end $$;
revoke all on function public.build_watchlist_daily_email(text,int) from public, anon, authenticated;
grant execute on function public.build_watchlist_daily_email(text,int) to service_role;

create or replace function public.dispatch_watchlist_daily()
returns int language plpgsql volatile security definer set search_path=public,pg_temp as $$
declare u record; d record; v_cnt int := 0;
begin
  for u in select distinct user_email from public.event_watchlist where alert_enabled loop
    select * into d from public.build_watchlist_daily_email(u.user_email);
    if d.html is not null then
      insert into public.alert_mail (to_email, template, subject, html)
      values (u.user_email, 'watchlist-daily', d.subject, d.html);
      v_cnt := v_cnt + 1;
    end if;
  end loop;
  return v_cnt;
end $$;
revoke all on function public.dispatch_watchlist_daily() from public, anon, authenticated;
grant execute on function public.dispatch_watchlist_daily() to service_role;

-- Migration 20260605190000 · lane:A1 · writes: _digest_cell + render_event_daily_digest
--   · reads: events, event_listing_snapshot_daily, seatgeek_sales_snapshots
--   · pre: 20260604125000_alert_mail_queue
--
-- Daily-digest email renderer: per-source (TEvo / SeatGeek / TicketsData) price +
-- volume + sales movement over the last ~24h, for cadence='daily' alert emails.
-- Each cell shows the current value with a coloured up/down arrow + % vs ~24h ago
-- (arrows are HTML numeric entities &#9650;/&#9660; so they survive any transport
-- encoding — raw ▲/▼ unicode got mangled in testing).
--
-- Sources: event_listing_snapshot_daily (per-source median/get-in/volume,
-- 3 slots/day so "24h ago" = the snapshot closest to latest-24h) +
-- seatgeek_sales_snapshots (24h sold units & gross, vs the prior 24h).
-- Verified live on event 3346011 (Spurs@Knicks Finals): EVO median &#9650;12% /
-- vol &#9660;12%, SeatGeek &#9650;12% / &#9660;40% / 13 sold, TicketsData &#9660;1.4%.

create or replace function public._digest_cell(p_cur numeric, p_prev numeric, p_prefix text default '', p_decimals int default 0)
returns text language sql immutable as $$
  select case when p_cur is null then '<span style="color:#bbb">&mdash;</span>'
    else p_prefix || to_char(round(p_cur, p_decimals),
            'FM999,999,990' || case when p_decimals>0 then '.'||repeat('0',p_decimals) else '' end) ||
         case when p_prev is null or p_prev=0 then ''
              else ' <span style="font-size:11px;color:'||
                   case when p_cur>p_prev then '#0a7d2c' when p_cur<p_prev then '#c0392b' else '#999' end||'">'||
                   case when p_cur>=p_prev then '&#9650;' else '&#9660;' end||
                   abs(round((p_cur-p_prev)/nullif(p_prev,0)*100,1))||'%</span>' end
  end;
$$;

create or replace function public.render_event_daily_digest(p_event_id bigint)
returns table(subject text, html text)
language plpgsql stable security definer set search_path=public,pg_temp as $$
declare
  ev record; cur record; prv record;
  sg_qty int; sg_gross numeric; sg_qty_prev int;
  td_listings_cur numeric; td_listings_prev numeric;
  v_rows text; v_sub text;
begin
  select id,name,occurs_at_local,venue_name into ev from public.events where id=p_event_id;
  select * into cur from public.event_listing_snapshot_daily where event_id=p_event_id order by captured_at desc limit 1;
  if cur.event_id is null then return; end if;
  select * into prv from public.event_listing_snapshot_daily
    where event_id=p_event_id and captured_at <= cur.captured_at - interval '20 hours'
    order by captured_at desc limit 1;

  select coalesce(sum(quantity),0) into sg_qty from public.seatgeek_sales_snapshots
   where tevo_event_id=p_event_id and sale_at_utc > now()-interval '24 hours';
  select coalesce(sum(quantity),0) into sg_qty_prev from public.seatgeek_sales_snapshots
   where tevo_event_id=p_event_id and sale_at_utc <= now()-interval '24 hours' and sale_at_utc > now()-interval '48 hours';
  select coalesce(sum(quantity*broadcast_price),0) into sg_gross from public.seatgeek_sales_snapshots
   where tevo_event_id=p_event_id and sale_at_utc > now()-interval '24 hours';

  td_listings_cur  := coalesce(cur.td_sh_listings,0)+coalesce(cur.td_gt_listings,0)+coalesce(cur.td_vd_listings,0)+coalesce(cur.td_tp_listings,0)+coalesce(cur.td_tm_listings,0);
  td_listings_prev := coalesce(prv.td_sh_listings,0)+coalesce(prv.td_gt_listings,0)+coalesce(prv.td_vd_listings,0)+coalesce(prv.td_tp_listings,0)+coalesce(prv.td_tm_listings,0);

  v_rows :=
    '<tr><td style="padding:9px 10px;border-bottom:1px solid #eee;font-size:13px;font-weight:600">TEvo (EVO)</td>'||
      '<td style="padding:9px 10px;border-bottom:1px solid #eee;font-size:13px;text-align:right">'||public._digest_cell(cur.evo_retail_median, prv.evo_retail_median,'$',0)||'</td>'||
      '<td style="padding:9px 10px;border-bottom:1px solid #eee;font-size:13px;text-align:right">'||public._digest_cell(cur.evo_retail_getin, prv.evo_retail_getin,'$',0)||'</td>'||
      '<td style="padding:9px 10px;border-bottom:1px solid #eee;font-size:13px;text-align:right">'||public._digest_cell(cur.evo_tickets_count, prv.evo_tickets_count,'',0)||'</td>'||
      '<td style="padding:9px 10px;border-bottom:1px solid #eee;font-size:13px;text-align:right;color:#bbb">&mdash;</td></tr>'||
    '<tr><td style="padding:9px 10px;border-bottom:1px solid #eee;font-size:13px;font-weight:600">SeatGeek</td>'||
      '<td style="padding:9px 10px;border-bottom:1px solid #eee;font-size:13px;text-align:right">'||public._digest_cell(cur.sg_all_median, prv.sg_all_median,'$',0)||'</td>'||
      '<td style="padding:9px 10px;border-bottom:1px solid #eee;font-size:13px;text-align:right">'||public._digest_cell(cur.sg_all_getin, prv.sg_all_getin,'$',0)||'</td>'||
      '<td style="padding:9px 10px;border-bottom:1px solid #eee;font-size:13px;text-align:right">'||public._digest_cell(cur.sg_all_listings, prv.sg_all_listings,'',0)||'</td>'||
      '<td style="padding:9px 10px;border-bottom:1px solid #eee;font-size:13px;text-align:right">'||public._digest_cell(sg_qty, nullif(sg_qty_prev,0),'',0)||'</td></tr>'||
    '<tr><td style="padding:9px 10px;border-bottom:1px solid #eee;font-size:13px;font-weight:600">TicketsData</td>'||
      '<td style="padding:9px 10px;border-bottom:1px solid #eee;font-size:13px;text-align:right">'||public._digest_cell(cur.td_combined_median, prv.td_combined_median,'$',0)||'</td>'||
      '<td style="padding:9px 10px;border-bottom:1px solid #eee;font-size:13px;text-align:right">'||public._digest_cell(cur.amalgam_getin, prv.amalgam_getin,'$',0)||'</td>'||
      '<td style="padding:9px 10px;border-bottom:1px solid #eee;font-size:13px;text-align:right">'||public._digest_cell(td_listings_cur, nullif(td_listings_prev,0),'',0)||'</td>'||
      '<td style="padding:9px 10px;border-bottom:1px solid #eee;font-size:13px;text-align:right;color:#bbb">&mdash;</td></tr>';

  v_sub := '📊 Daily digest — '||ev.name||' (24h movement)';
  return query select v_sub,
    '<div style="font-family:-apple-system,Segoe UI,Roboto,sans-serif;max-width:680px;margin:0 auto;background:#fff">'||
    '<div style="background:#0a0a0a;color:#fff;padding:18px 22px;border-radius:8px 8px 0 0">'||
    '<div style="font-size:11px;letter-spacing:1px;color:#9ab;text-transform:uppercase">S4K Terminal &middot; Daily Digest &middot; 24h movement</div>'||
    '<div style="font-size:19px;font-weight:700;margin-top:4px">'||ev.name||'</div>'||
    '<div style="font-size:13px;color:#aaa;margin-top:3px">'||coalesce(ev.venue_name,'')||' &middot; '||coalesce(left(ev.occurs_at_local,16),'')||'</div></div>'||
    '<table style="width:100%;border-collapse:collapse;border:1px solid #eee;border-top:none">'||
    '<thead><tr style="background:#f7f7f8">'||
    '<th style="padding:8px 10px;text-align:left;font-size:10px;color:#888;text-transform:uppercase">Source</th>'||
    '<th style="padding:8px 10px;text-align:right;font-size:10px;color:#888;text-transform:uppercase">Median</th>'||
    '<th style="padding:8px 10px;text-align:right;font-size:10px;color:#888;text-transform:uppercase">Get-in</th>'||
    '<th style="padding:8px 10px;text-align:right;font-size:10px;color:#888;text-transform:uppercase">Volume</th>'||
    '<th style="padding:8px 10px;text-align:right;font-size:10px;color:#888;text-transform:uppercase">Sold 24h</th></tr></thead>'||
    '<tbody>'||v_rows||'</tbody></table>'||
    '<div style="padding:12px 22px;font-size:12px;color:#444;border:1px solid #eee;border-top:none">'||
    '<b>SeatGeek sales last 24h:</b> '||sg_qty||' tickets'||case when sg_gross>0 then ' &middot; $'||to_char(round(sg_gross),'FM999,999,990')||' gross' else '' end||
    ' (prior 24h: '||sg_qty_prev||')</div>'||
    '<div style="padding:12px 22px;font-size:11px;color:#999;border:1px solid #eee;border-top:none;border-radius:0 0 8px 8px">'||
    'Arrows = change vs ~24h ago. Price/volume from event_listing_snapshot_daily; sales from SeatGeek. '||
    '<a href="https://vibepass-terminal-test.onrender.com/terminal/event.html?event='||p_event_id||'" style="color:#2563eb">Open event &rarr;</a></div></div>';
end $$;
revoke all on function public.render_event_daily_digest(bigint) from public, anon, authenticated;
grant execute on function public.render_event_daily_digest(bigint) to service_role;

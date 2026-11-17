// D0 Terminal — Pickups page. The pricing desk's morning list, automated:
// future events with OUR daily order counts over the last few days, ranked
// relative to how far out the event is (🔥 SELLING HOT), plus the inverse —
// events where we still list tickets that won't clear by event day at the
// current pace (🧊 NOT SELLING). Backed by /api/broker/pickups →
// get_d0_pickups (mig 20261006170000). "COPY FOR CHAT" emits the same bullet
// format the desk posts in the pricing chat.

(function () {
  'use strict';

  const T = window.Terminal;
  const esc = (window.TermRender && window.TermRender.escapeHtml) || (s => String(s == null ? '' : s));

  const el = {
    body:    document.getElementById('pkBody'),
    note:    document.getElementById('pkNote'),
    explain: document.getElementById('pkExplain'),
    copy:    document.getElementById('pkCopy'),
  };

  const qs = new URLSearchParams(window.location.search);
  const state = {
    mode: qs.get('mode') === 'cold' ? 'cold' : 'hot',
    days: Math.max(1, Math.min(14, parseInt(qs.get('days') || '4', 10) || 4)),
    out:  qs.get('out') || '7-365',
    data: null,
    tevoAsOf: null,   // get_home_stats as_of.tevo_inventory — Listed/Pace freshness
  };

  // ---------- formatting ----------
  const num = (n) => Number(n == null ? NaN : n);
  const int = (n) => { const v = num(n); return Number.isFinite(v) ? v.toLocaleString(undefined, { maximumFractionDigits: 0 }) : '—'; };
  const money = (n) => { const v = num(n); return Number.isFinite(v) ? '$' + v.toLocaleString(undefined, { maximumFractionDigits: 0 }) : '—'; };
  const x = (n) => { const v = num(n); return Number.isFinite(v) ? v.toFixed(v < 10 ? 1 : 0) + '×' : '—'; };
  const md = (iso) => { // 'YYYY-MM-DD…' → 'M/D' without a timezone shift
    const m = /^(\d{4})-(\d{2})-(\d{2})/.exec(String(iso || ''));
    return m ? `${+m[2]}/${+m[3]}` : '';
  };
  const shortName = (name) => String(name || '')
    .replace(/^NBA Preseason - /i, '')
    .replace(/\b(Football|Basketball)\b/g, '')
    .replace(/\s{2,}/g, ' ').trim();

  const TREND = {
    spike:   { cls: 'pos',   label: 'spike' },
    rising:  { cls: 'pos',   label: 'rising' },
    falling: { cls: 'neg',   label: 'falling' },
    flat:    { cls: 'muted', label: 'flat' },
  };

  function bars(daily) {
    const vals = (daily || []).map(d => num(d.orders) || 0);
    const max = Math.max(1, ...vals);
    return '<span class="pk-bars" aria-hidden="true">' + (daily || []).map(d => {
      const h = Math.max(2, Math.round(((num(d.orders) || 0) / max) * 18));
      return `<span class="pk-bar" style="height:${h}px" title="${esc(md(d.d))}: ${int(d.orders)} orders · ${int(d.tix)} tix"></span>`;
    }).join('') + '</span>';
  }

  function marketChips(bm) {
    if (!bm) return '<span class="muted">—</span>';
    return Object.entries(bm).sort((a, b) => b[1] - a[1])
      .map(([k, v]) => `<span class="pk-chip">${esc(k)} ${int(v)}</span>`).join(' ');
  }

  // SeatGeek public sales feed (every SG sale on the event, ours included).
  // Untracked = the SG pollers don't cover the event → "—", never a false 0.
  function mktCell(r) {
    if (!r.mkt_tracked) return '<span class="muted" title="SeatGeek market feed does not cover this event">—</span>';
    const share = r.sg_share != null ? `<div class="muted small pk-share" title="our SeatGeek orders ÷ all SeatGeek sales in the window">ours ${Math.round(num(r.sg_share) * 100)}%</div>` : '';
    const tip = `${int(r.mkt_tix_window)} tix in ${int(r.mkt_sales_window)} SeatGeek sales · ${int(r.mkt_sales_today)} today`;
    return `<span title="${esc(tip)}">${int(r.mkt_sales_window)}</span>${share}`;
  }

  function paceCell(r) {
    if (!(num(r.open_qty) > 0)) return '<span class="muted" title="no listed tickets in the latest snapshot">sold out / unlisted</span>';
    const p = num(r.pace_ratio);
    const cls = p >= 1.5 ? 'pos' : p < 0.5 ? 'neg' : '';
    const tip = `listed ${int(r.open_qty)} · need ${num(r.needed_tix_per_day).toFixed(1)} tix/day to clear by event day`;
    return `<span class="${cls}" title="${esc(tip)}">${x(p)}</span>`;
  }

  function outcomeCell(r) {
    if (!(num(r.open_qty) > 0)) return '<span class="muted">—</span>';
    const sd = num(r.days_to_sellout);
    if (state.mode === 'cold' || !Number.isFinite(sd)) {
      return `<span class="neg">${int(r.projected_unsold)} left</span>`;
    }
    // Selling out well before the event = pricing may be too low.
    const early = sd < num(r.days_out) * 0.6;
    return `<span class="${early ? 'pos' : ''}" title="days until our listed qty is gone at this pace">${int(sd)}d${early ? ' ⚠ early' : ''}</span>`;
  }

  function render() {
    const d = state.data;
    if (!d) return;
    const rows = d.events || [];
    const daily0 = (rows[0] && rows[0].daily) || [];
    const span = daily0.length ? `${md(daily0[0].d)} → ${md(daily0[daily0.length - 1].d)}` : '';
    el.note.textContent = `${rows.length} events · daily orders ${span} · refreshed ${T.fmtDate(d.generated_at)}`;
    el.explain.innerHTML = state.mode === 'hot'
      ? 'Ranked by our orders × how far out the event is × lift vs its own prior-28-day pace — the further-out game people are chipping away at ranks above a game that is simply close. ' +
        '<b>Pace</b> = tickets/day sold ÷ tickets/day needed to clear our listed qty by event day; <b>sell-out</b> flags inventory that will be gone well before the event (room to raise).'
      : 'Events where we still list tickets that will NOT clear by event day at the current pace, ranked by projected leftover tickets, closer events first. ' +
        'Listed qty = our owned TEvo/SeatGeek listings in the latest daily snapshot — not a Bridge/POS export, so held-back tickets are not counted.';
    const tevoT = state.tevoAsOf ? new Date(state.tevoAsOf).getTime() : NaN;
    if (Number.isFinite(tevoT) && Date.now() - tevoT > 2 * 86400000) {
      el.explain.innerHTML += ` <span class="neg">⚠ <b>Listed</b> and <b>Pace</b> use our TEvo inventory as of ${esc(new Date(tevoT).toLocaleDateString(undefined, { month: 'numeric', day: 'numeric' }))} — terminal listing polls are paused, so tickets sold since then still count as listed. Order counts are live.</span>`;
    }
    el.explain.innerHTML += ' <b>SG mkt</b> = every SeatGeek sale on the event in the same window (all sellers, ours included) with our share of it; "—" = SeatGeek\'s sales feed doesn\'t cover that event.';

    if (!rows.length) { el.body.innerHTML = '<div class="empty">nothing matches this window</div>'; return; }

    const head = '<tr><th>EVENT</th><th>DATE</th><th class="num">OUT</th><th>DAILY ORDERS</th><th>TREND</th>' +
      '<th class="num">ORDERS</th><th class="num">TIX</th><th class="num">SALES</th><th class="num pk-opt">TODAY</th>' +
      '<th class="num pk-opt">LIFT</th><th class="num pk-opt2">LISTED</th><th class="num">PACE</th>' +
      '<th class="num" title="SeatGeek market sales (all sellers) in the same window">SG MKT</th>' +
      `<th class="num">${state.mode === 'cold' ? 'PROJ. LEFT' : 'SELL-OUT'}</th><th class="pk-opt">MARKETS</th></tr>`;
    // data-label feeds the phone card layout (style.css .pk-tbl ≤768px).
    const td = (label, html, cls) => `<td${cls ? ` class="${cls}"` : ''} data-label="${label}">${html}</td>`;
    const body = rows.map(r => {
      const tr = TREND[r.trend] || TREND.flat;
      const seq = (r.daily || []).map(v => int(v.orders)).join(', ');
      const mseq = r.mkt_tracked ? (r.daily || []).map(v => int(v.mkt)).join(', ') : '';
      return '<tr>' +
        `<td class="pk-name"><a href="event.html?event=${encodeURIComponent(r.tevo_event_id)}">${esc(r.event_name)}</a>` +
          (r.venue_name ? `<div class="muted small">${esc(r.venue_name)}</div>` : '') + '</td>' +
        td('Date', esc(md(r.occurs_at_local))) +
        td('Out', `${int(r.days_out)}d`, 'num') +
        td('Daily orders', `${bars(r.daily)} <span class="muted small">${esc(seq)}</span>` +
          (mseq ? `<div class="muted small" title="SeatGeek market sales per day">SG mkt ${esc(mseq)}</div>` : ''), 'pk-wide pk-daily') +
        td('Trend', `<span class="${tr.cls}">${tr.label}</span>`) +
        td('Orders', int(r.orders_window), 'num') +
        td('Tix', int(r.tix_window), 'num') +
        td('Sales', money(r.sales_window), 'num') +
        td('Today', int(r.orders_today), 'num pk-opt') +
        `<td class="num pk-opt" data-label="Lift" title="${int(r.orders_base_28d)} orders in the prior 28 days">${x(r.lift)}</td>` +
        td('Listed', num(r.open_qty) > 0 ? int(r.open_qty) : '—', 'num pk-opt2') +
        td('Pace', paceCell(r), 'num') +
        td('SG mkt', mktCell(r), 'num') +
        td(state.mode === 'cold' ? 'Proj. left' : 'Sell-out', outcomeCell(r), 'num') +
        td('Markets', marketChips(r.by_market), 'small pk-opt pk-wide') +
        '</tr>';
    }).join('');
    el.body.innerHTML = `<div class="pk-scroll"><table class="sales-tbl pk-tbl"><thead>${head}</thead><tbody>${body}</tbody></table></div>`;
  }

  // Chat-ready text in the desk's own format:
  //   • Chiefs at Falcons 11/15: 2, 0, 10, 15 — rising; 72 tix, $11,266 sales
  function chatText() {
    const d = state.data;
    if (!d || !(d.events || []).length) return '';
    const rows = d.events.slice(0, 15);
    const daily0 = rows[0].daily || [];
    const span = daily0.length ? `${md(daily0[0].d)} → ${md(daily0[daily0.length - 1].d)}` : '';
    const [lo] = state.out.split('-').map(Number);
    const scope = lo >= 15 ? 'past the next 2 weeks' : lo >= 7 ? 'past next week' : 'upcoming';
    const title = state.mode === 'hot'
      ? `Pickups for events ${scope}, daily orders ${span}:`
      : `Not selling vs proximity (events ${scope}), daily orders ${span}:`;
    const lines = rows.map(r => {
      const seq = (r.daily || []).map(v => int(v.orders)).join(', ');
      const tr = r.trend && r.trend !== 'flat' ? ` — ${r.trend}` : '';
      const mkt = r.mkt_tracked
        ? `; SG market ${int(r.mkt_sales_window)} sales` + (r.sg_share != null ? ` (ours ${Math.round(num(r.sg_share) * 100)}%)` : '')
        : '';
      const tail = (state.mode === 'hot'
        ? `${int(r.tix_window)} tix, ${money(r.sales_window)} sales`
        : `${int(r.open_qty)} listed, ~${int(r.projected_unsold)} left at this pace`) + mkt;
      return `• ${shortName(r.event_name)} ${md(r.occurs_at_local)}: ${seq}${tr}; ${tail}`;
    });
    return `${title}\n\n${lines.join('\n')}`;
  }

  async function load() {
    const [lo, hi] = state.out.split('-').map(Number);
    const p = new URLSearchParams({ mode: state.mode, days: String(state.days),
      min_days_out: String(lo || 0), max_days_out: String(hi || 365),
      limit: state.mode === 'cold' ? '60' : '50' });
    el.body.innerHTML = '<div class="empty">loading…</div>';
    try {
      state.data = await T.api('/api/broker/pickups?' + p.toString());
      render();
      T.setStatus(`${(state.data.events || []).length} events`, 'ok');
    } catch (e) {
      state.data = null;
      el.body.innerHTML = `<div class="empty neg">${esc(e.message)}</div>`;
      T.setStatus('error', 'err');
    }
    const u = new URL(window.location.href);
    u.searchParams.set('mode', state.mode); u.searchParams.set('days', state.days); u.searchParams.set('out', state.out);
    window.history.replaceState(null, '', u.toString());
  }

  function bindGroup(attr, key, parse) {
    const btns = document.querySelectorAll(`[data-${attr}]`);
    btns.forEach(b => {
      b.classList.toggle('is-active', String(parse(b.dataset[attr])) === String(state[key]));
      b.addEventListener('click', () => {
        state[key] = parse(b.dataset[attr]);
        btns.forEach(o => o.classList.toggle('is-active', o === b));
        load();
      });
    });
  }

  bindGroup('mode', 'mode', v => v);
  bindGroup('days', 'days', v => parseInt(v, 10));
  bindGroup('out', 'out', v => v);

  el.copy.addEventListener('click', async () => {
    const text = chatText();
    if (!text) return;
    try {
      await navigator.clipboard.writeText(text);
      el.copy.textContent = 'COPIED ✓';
    } catch (_) {
      window.prompt('Copy:', text);
    }
    setTimeout(() => { el.copy.textContent = 'COPY FOR CHAT'; }, 1500);
  });

  (async () => {
    if (window.TerminalAuth) await window.TerminalAuth.requireAuth();
    load();
    try {
      const r = await window.TerminalAuth.client.rpc('get_home_stats');
      if (!r.error && r.data && r.data.as_of) { state.tevoAsOf = r.data.as_of.tevo_inventory; render(); }
    } catch (_) { /* freshness note is best-effort */ }
  })();
})();

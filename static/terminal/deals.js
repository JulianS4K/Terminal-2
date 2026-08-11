// D0 Terminal — Deals LIVE FEED (GoTickets-only section outliers, ≥15% profit).
//
// A background scanner (scan_gotickets_deals, mig 20260811210000, 5-min cron)
// re-checks the freshest-scanned GoTickets events, flags section-level robust low
// outliers (median+MAD z≤-3.5) that clear a ≥15% projected profit (resale = section
// median discounted to event day by the clearing curve), and upserts
// gotickets_deals_feed. This page polls get_deals_feed and prepends new deals.
// Operator directives 2026-08-11: live feed · outliers not a majority · GoTickets
// only · ≥15% profit given assumed price degradation.

(function () {
  'use strict';
  const T = window.Terminal;
  const esc = window.TermRender.escapeHtml;
  const POLL_MS = 20000;
  const FULL_EVERY = 9;   // full resync every ~3 min to retire gone deals

  const state = {
    minRoi: 0.15,
    filter: '',
    live: true,
    deals: [],
    newestSeen: null,
    pollCount: 0,
    timer: 0,
  };

  const $r = v => (v != null && isFinite(+v) ? '$' + T.fmtNum(Math.round(+v)) : '—');
  const keyOf = d => d.tevo_event_id + ':' + d.gt_listing_id;

  async function init() {
    if (window.TerminalAuth) await window.TerminalAuth.requireAuth();
    wireControls();
    await fullRefresh();
    startPolling();
  }

  function wireControls() {
    document.querySelectorAll('[data-roi]').forEach(btn => btn.addEventListener('click', () => {
      document.querySelectorAll('[data-roi]').forEach(b => b.classList.remove('is-active'));
      btn.classList.add('is-active');
      state.minRoi = parseFloat(btn.dataset.roi);
      fullRefresh();
    }));
    const f = document.getElementById('dealsFilter');
    if (f) f.addEventListener('input', () => { state.filter = f.value.trim().toLowerCase(); render(); });
    const pause = document.getElementById('livePause');
    if (pause) pause.addEventListener('click', () => {
      state.live = !state.live;
      pause.textContent = state.live ? '⏸ Pause' : '▶ Resume';
      pause.classList.toggle('is-active', state.live);
      const dot = document.getElementById('liveDot');
      if (dot) dot.classList.toggle('paused', !state.live);
      if (state.live) startPolling(); else stopPolling();
    });
  }

  function startPolling() { stopPolling(); state.timer = setInterval(poll, POLL_MS); }
  function stopPolling() { if (state.timer) { clearInterval(state.timer); state.timer = 0; } }

  async function callFeed(params) {
    const Auth = window.TerminalAuth;
    if (!Auth || !Auth.client || !Auth.getAccessToken()) return { error: { message: 'not signed in' } };
    return Auth.client.rpc('get_deals_feed', params);
  }

  async function fullRefresh() {
    const body = document.getElementById('dealsBody');
    if (!state.deals.length && body) body.innerHTML = '<div class="empty">Connecting to the live deal feed…</div>';
    if (T && T.setStatus) T.setStatus('Loading…', '');
    const res = await callFeed({ p_limit: 200, p_min_roi: state.minRoi });
    if (res.error) { showError(res.error); return; }
    const d = res.data || {};
    state.deals = (d.deals || []).map(x => ({ ...x, _new: false }));
    state.newestSeen = state.deals.length ? state.deals[0].first_seen_at : state.newestSeen;
    state.pollCount = 0;
    if (T && T.setStatus) T.setStatus('Live', 'ok');
    updateScanMeta(d);
    render();
  }

  async function poll() {
    if (!state.live) return;
    state.pollCount++;
    if (state.pollCount % FULL_EVERY === 0) { await fullRefresh(); return; }
    const res = await callFeed({ p_limit: 100, p_since: state.newestSeen, p_min_roi: state.minRoi });
    if (res.error) { showError(res.error); return; }
    const d = res.data || {};
    updateScanMeta(d);
    const fresh = (d.deals || []);
    if (fresh.length) {
      const have = new Set(state.deals.map(keyOf));
      const add = fresh.filter(x => !have.has(keyOf(x))).map(x => ({ ...x, _new: true }));
      if (add.length) {
        state.deals = add.concat(state.deals);
        state.newestSeen = add[0].first_seen_at;
        pulseDot();
        render();
      }
    }
  }

  function showError(err) {
    const body = document.getElementById('dealsBody');
    const msg = err.code === '42883'
      ? 'DEALS feed RPC not deployed yet — pending migration 20260811210000'
      : (err.message || 'unavailable');
    if (T && T.setStatus) T.setStatus('error', 'err');
    if (body && !state.deals.length) body.innerHTML = `<div class="empty">RPC error: ${esc(msg)}</div>`;
  }

  function updateScanMeta(d) {
    const el = document.getElementById('dealsScanMeta');
    if (!el) return;
    const active = d.active_deals != null ? d.active_deals : '—';
    el.textContent = `${active} live deals · last scan ${ago(d.last_scan_at) || '—'}`;
  }

  function pulseDot() {
    const dot = document.getElementById('liveDot');
    if (!dot) return;
    dot.classList.remove('pulse'); void dot.offsetWidth; dot.classList.add('pulse');
  }

  function winClass(p) { return p >= 0.85 ? 'good' : (p >= 0.70 ? 'warn' : 'neutral'); }
  function confClass(c) { return c === 'high' ? 'good' : (c === 'med' ? 'warn' : 'neutral'); }

  function ago(iso) {
    if (!iso) return '';
    const s = Math.max(0, (Date.now() - new Date(iso).getTime()) / 1000);
    if (s < 60) return Math.floor(s) + 's ago';
    if (s < 3600) return Math.floor(s / 60) + 'm ago';
    if (s < 86400) return Math.floor(s / 3600) + 'h ago';
    return Math.floor(s / 86400) + 'd ago';
  }
  function fmtDate(iso) {
    if (!iso) return '';
    try { return new Date(iso + 'T00:00:00').toLocaleDateString(undefined, { month: 'short', day: 'numeric' }); }
    catch (_) { return ''; }
  }

  function visible() {
    if (!state.filter) return state.deals;
    const q = state.filter;
    return state.deals.filter(d =>
      (d.event_name || '').toLowerCase().includes(q) ||
      (d.section || '').toLowerCase().includes(q) ||
      (d.zone || '').toLowerCase().includes(q));
  }

  function render() {
    const body = document.getElementById('dealsBody');
    if (!body) return;
    const rows = visible();
    if (!rows.length) {
      body.innerHTML = `<div class="empty">${state.deals.length ? 'No deals match the filter.' : 'No live deals yet — the scanner runs every ~5 min. Lower the profit threshold or check back shortly.'}</div>`;
      return;
    }
    const html = rows.map(d => {
      const wc = winClass(+d.win_prob || 0);
      const cc = confClass(d.confidence);
      const acc = d.is_accessible ? ' <span class="deals-acc" title="accessible / wheelchair">♿</span>' : '';
      const evLink = `event.html?event=${encodeURIComponent(d.tevo_event_id)}`;
      const dt = d.event_date ? ` <span class="muted">· ${esc(fmtDate(d.event_date))}</span>` : '';
      const winPct = d.win_prob != null ? Math.round(d.win_prob * 100) + '%' : '—';
      return `<tr class="${d._new ? 'deals-row-new' : ''}">
        <td class="deals-when num">${d._new ? '<span class="deals-new-chip">NEW</span> ' : ''}${esc(ago(d.first_seen_at))}</td>
        <td class="deals-ev"><a href="${evLink}">${esc(d.event_name || ('event ' + d.tevo_event_id))}</a>${dt}</td>
        <td>${esc(d.section || '')}${d.row ? ' · ' + esc(String(d.row)) : ''}${acc}</td>
        <td class="num">${d.quantity != null ? esc(String(d.quantity)) : '—'}</td>
        <td class="num"><b>${$r(d.gt_price)}</b></td>
        <td class="num">${$r(d.realized_median)}${d.realized_n != null ? ' <span class="muted small">n' + d.realized_n + (d.resale_basis === 'historic_realized' ? '·hist' : '·live') + '</span>' : ''}</td>
        <td class="num">${$r(d.est_net_resale)}</td>
        <td class="num deals-below">${d.net_profit_pct != null ? '+' + d.net_profit_pct + '%' : '—'}</td>
        <td class="num"><span class="badge regime-${wc}">${winPct}</span></td>
        <td><span class="badge regime-${cc}">${esc(d.confidence || '')}</span></td>
      </tr>`;
    }).join('');
    body.innerHTML = `<table class="deals-tbl">
      <thead><tr>
        <th>Seen</th><th>Event</th><th>Section · Row</th><th class="num">Qty</th>
        <th class="num">Buy (GT)</th><th class="num">Realized med</th><th class="num">Est. net resale</th>
        <th class="num">Net profit</th><th class="num">Win odds</th><th>Conf</th>
      </tr></thead>
      <tbody>${html}</tbody></table>`;
    setTimeout(() => { state.deals.forEach(d => { d._new = false; }); }, 6000);
  }

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', init);
  else init();
})();

// D0 Terminal — Deals LIVE FEED (GoTickets + EVO zone outliers, realized-anchored).
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
    loadResults();
    loadSpells();
  }

  // RESULTS strip — get_deal_results(30): what we predicted vs what happened (mig 20260911162100).
  async function loadResults() {
    const Auth = window.TerminalAuth;
    const body = document.getElementById('dealsResultsBody');
    if (!body || !Auth || !Auth.client || !Auth.getAccessToken()) return;
    const res = await Auth.client.rpc('get_deal_results', { p_days: 30 });
    if (res.error) { body.innerHTML = `<div class="empty muted small">results unavailable: ${esc(res.error.message || '')}</div>`; return; }
    renderResults(res.data || {});
  }
  const pct = v => (v == null ? '—' : Math.round(+v * 100) + '%');
  function calTable(title, rows, extraKey, extraLabel) {
    if (!rows || !rows.length) return '';
    const tr = rows.map(r => `<tr><td>${esc(String(r.bucket).replace(/^[a-e] /, ''))}</td><td class="num">${r.n}</td><td class="num"><span class="badge regime-${+r.win_rate >= 0.5 ? 'good' : (+r.win_rate >= 0.3 ? 'warn' : 'neutral')}">${pct(r.win_rate)}</span></td>${extraKey ? `<td class="num">${r[extraKey] == null ? '—' : esc(String(r[extraKey]))}</td>` : ''}</tr>`).join('');
    return `<div class="deals-cal"><div class="muted small"><b>${esc(title)}</b></div><table class="deals-tbl small"><thead><tr><th>bucket</th><th class="num">n</th><th class="num">won</th>${extraKey ? `<th class="num">${esc(extraLabel)}</th>` : ''}</tr></thead><tbody>${tr}</tbody></table></div>`;
  }
  function renderResults(d) {
    const body = document.getElementById('dealsResultsBody'); const meta = document.getElementById('dealsResultsMeta');
    if (!body) return;
    const tot = d.totals || {}; const bys = d.by_source || {}; const pe = d.price_error || {}; const m = d.model || {};
    if (meta) meta.textContent = `${tot.graded || 0} graded · model ${m.version || '—'} on ${m.train_rows || 0} played event-zones` + (m.refreshed_at ? ` · refit ${ago(m.refreshed_at)}` : '');
    if (!tot.graded) { body.innerHTML = '<div class="empty muted small">No graded deals in the window yet — deals are graded the day after their event.</div>'; return; }
    const src = Object.keys(bys).map(k => `${k === 'evo' ? 'EVO' : 'GT'} ${bys[k].win}/${bys[k].graded} (${pct(bys[k].win_rate)})`).join(' · ');
    const errLine = pe.n_model ? `price model median error ${Math.round(Math.abs(+pe.model_median_abs_log) * 100)}% (bias ${Math.round(+pe.model_median_bias_log * 100)}%) vs legacy ${Math.round(Math.abs(+pe.legacy_median_abs_log) * 100)}% (bias ${Math.round(+pe.legacy_median_bias_log * 100)}%) on ${pe.n_model} deals`
                              : `price model has no graded deals yet (rows flagged before it went live carry no prediction); legacy estimate median error ${pe.legacy_median_abs_log != null ? Math.round(Math.abs(+pe.legacy_median_abs_log) * 100) + '%' : '—'}`;
    const recent = (d.recent || []).slice(0, 12).map(r => `<tr>
        <td><span class="badge regime-neutral">${r.source === 'evo' ? 'EVO' : 'GT'}</span> ${esc(r.event || '')} <span class="muted">· ${esc(fmtDate(r.event_date))}</span></td>
        <td>${esc(r.section || '')}</td><td class="num">${$r(r.cost)}</td>
        <td class="num">${r.pred_final != null ? $r(r.pred_final) : '—'}${r.pred_roi_pct != null ? ` <span class="muted small">${r.pred_roi_pct >= 0 ? '+' : ''}${r.pred_roi_pct}%</span>` : ''}</td>
        <td class="num">${r.pred_p15 != null ? pct(r.pred_p15) : '—'}</td>
        <td class="num">${r.score_v1 != null ? pct(r.score_v1) : '—'}</td>
        <td class="num">${$r(r.actual_final)} <span class="muted small">${r.actual_roi_pct != null ? (r.actual_roi_pct >= 0 ? '+' : '') + Math.round(r.actual_roi_pct) + '%' : ''}</span></td>
        <td><span class="badge regime-${r.outcome === 'WIN' ? 'good' : (r.outcome === 'FLAT' ? 'warn' : 'neutral')}">${esc(r.outcome || '')}</span></td>
      </tr>`).join('');
    body.innerHTML = `
      <div class="deals-results-head small">
        <b>${tot.win} won · ${tot.flat} flat · ${tot.loss} lost</b> of ${tot.graded} graded (${pct(tot.win_rate)} win rate, median realized ${tot.median_actual_roi_pct != null ? (tot.median_actual_roi_pct >= 0 ? '+' : '') + tot.median_actual_roi_pct + '%' : '—'})${src ? ' · ' + src : ''}<br/>
        <span class="muted">${errLine}</span>
      </div>
      <div class="deals-cal-row">
        ${calTable('by predicted P15', d.by_pred_p15, 'avg_p15', 'avg P15')}
        ${calTable('by predicted net ROI', d.by_pred_roi, 'median_actual_roi', 'median actual')}
        ${calTable('by Score v1', d.by_score_v1)}
      </div>
      <table class="deals-tbl small"><thead><tr><th>Event</th><th>Section</th><th class="num">Cost</th><th class="num">Pred final · ROI</th><th class="num">P15</th><th class="num">Score v1</th><th class="num">Actual final · ROI</th><th>Outcome</th></tr></thead><tbody>${recent}</tbody></table>`;
  }

  // LIFECYCLE strip — get_deal_spells(14): when each underpriced listing entered the feed, when it
  // went, and WHY. 'delisted' is the one that matters: it left the book while still underpriced.
  // 'window' and 'stale' are our own cadence, not the market, so they are shown apart (mig 20260911162300).
  async function loadSpells() {
    const Auth = window.TerminalAuth;
    const body = document.getElementById('dealsSpellsBody');
    if (!body || !Auth || !Auth.client || !Auth.getAccessToken()) return;
    const res = await Auth.client.rpc('get_deal_spells', { p_days: 14 });
    if (res.error) { body.innerHTML = `<div class="empty muted small">lifecycle unavailable: ${esc(res.error.message || '')}</div>`; return; }
    renderSpells(res.data || {});
  }
  const mins = v => {
    if (v == null) return '—';
    const n = +v;
    if (n < 90) return Math.round(n) + 'm';
    if (n < 60 * 48) return (n / 60).toFixed(1) + 'h';
    return (n / 1440).toFixed(1) + 'd';
  };
  function renderSpells(d) {
    const body = document.getElementById('dealsSpellsBody'); const meta = document.getElementById('dealsSpellsMeta');
    if (!body) return;
    const tot = d.totals || {}; const mix = d.exit_mix || {}; const dw = d.dwell || {};
    if (meta) meta.textContent = `${tot.spells || 0} tracked · ${tot.open || 0} still live`;
    const rows = d.recent || [];
    if (!rows.length) {
      body.innerHTML = '<div class="empty muted small">No listings tracked since the ledger went live — entries appear as the scanner flags them.</div>';
      return;
    }
    const market = (+mix.delisted || 0) + (+mix.repriced || 0);
    const mixLine = `<b>${mix.delisted || 0} left the book</b> · ${mix.repriced || 0} repriced out` +
      (market ? ` (${Math.round((+mix.delisted || 0) / market * 100)}% of market exits were a delist)` : '') +
      ` · <span class="muted">${mix.window || 0} crossed the 7-day floor, ${mix.stale || 0} lost polling — our cadence, not the market</span>`;
    const tr = rows.slice(0, 15).map(r => `<tr>
        <td><span class="badge regime-neutral">${r.source === 'evo' ? 'EVO' : 'GT'}</span> ${esc(r.event_name || '')} <span class="muted">· ${esc(fmtDate(r.event_date))}</span></td>
        <td>${esc(r.section || '')}${r.row ? ' <span class="muted">row ' + esc(r.row) + '</span>' : ''}</td>
        <td class="num">${$r(r.entry_price)}</td>
        <td class="num">${r.entry_roi_pct != null ? (r.entry_roi_pct >= 0 ? '+' : '') + Math.round(r.entry_roi_pct) + '%' : '—'}</td>
        <td class="muted small">${esc(ago(r.entered_at))}</td>
        <td class="num">${mins(r.dwell_minutes)}</td>
        <td>${r.exit_reason
              ? `<span class="badge regime-${r.exit_reason === 'delisted' ? 'good' : (r.exit_reason === 'repriced' ? 'warn' : 'neutral')}">${esc(r.exit_reason)}</span>`
              : '<span class="badge regime-warn">live</span>'}</td>
      </tr>`).join('');
    body.innerHTML = `
      <div class="deals-results-head small">
        ${mixLine}<br/>
        <span class="muted">median time on the board — delisted ${mins(dw.delisted_median_min)} · repriced ${mins(dw.repriced_median_min)} · still live ${mins(dw.open_median_min)}</span>
      </div>
      <table class="deals-tbl small"><thead><tr><th>Event</th><th>Seat</th><th class="num">Entry cost</th><th class="num">Entry net</th><th>Entered</th><th class="num">On board</th><th>Exit</th></tr></thead><tbody>${tr}</tbody></table>`;
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
    const bys = d.active_by_source || {};
    const srcs = (bys.gotickets != null || bys.evo != null) ? ` (GT ${bys.gotickets || 0} · EVO ${bys.evo || 0})` : '';
    const hidden = d.suppressed_n ? ` · ${d.suppressed_n} hidden (at-market / falling)` : '';
    const verify = d.verify_n ? ` · ${d.verify_n} to verify` : '';
    el.textContent = `${active} live deals${srcs}${hidden}${verify} · last scan ${ago(d.last_scan_at) || '—'}`;
  }

  function pulseDot() {
    const dot = document.getElementById('liveDot');
    if (!dot) return;
    dot.classList.remove('pulse'); void dot.offsetWidth; dot.classList.add('pulse');
  }

  function winClass(p) { return p >= 0.85 ? 'good' : (p >= 0.70 ? 'warn' : 'neutral'); }
  // score_v1 (market-only, label-calibrated, 7+ days out): ≥0.50 won 90% of the graded set, <0.15 won 2%.
  function scoreClass(p) { return p >= 0.5 ? 'good' : (p >= 0.3 ? 'warn' : 'neutral'); }
  function gateChip(d) {
    if (!d.gate || d.gate === 'OK') return d.timing ? `<span class="muted small" title="days to event when flagged (feed carries 7+ days only)">${esc(d.timing)}</span>` : '';
    const t = d.gate.startsWith('VERIFY') ? 'priced far below its zone/anchor — check the seat before buying' : d.gate;
    return `<span class="badge regime-warn" title="${esc(t)}">${esc(d.gate.replace(/^VERIFY\s*/, 'VERIFY '))}</span>`;
  }
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
      const isEvo = d.source === 'evo';
      const srcChip = isEvo
        ? `<span class="badge regime-neutral" title="TEvo listing · price = wholesale · ticket group ${esc(String(d.evo_ticket_group_id || ''))}">EVO</span>`
        : '<span class="badge regime-neutral" title="GoTickets listing · price = all-in">GT</span>';
      const gtBtn = (!isEvo && d.gt_event_id != null)
        ? `<a class="gt-open-btn" href="https://gotickets.com/tickets/${encodeURIComponent(d.gt_event_id)}" target="_blank" rel="noopener noreferrer" title="Open this event on GoTickets">GT&nbsp;↗</a>`
        : (isEvo ? `<a class="gt-open-btn" href="event.html?event=${encodeURIComponent(d.tevo_event_id)}" title="Open the event in the terminal (TEvo ticket group ${esc(String(d.evo_ticket_group_id || ''))})">EVO&nbsp;↗</a>` : '<span class="muted">—</span>');
      return `<tr class="${d._new ? 'deals-row-new' : ''}">
        <td class="deals-when num">${d._new ? '<span class="deals-new-chip">NEW</span> ' : ''}${esc(ago(d.first_seen_at))}</td>
        <td class="deals-ev"><a href="${evLink}">${esc(d.event_name || ('event ' + d.tevo_event_id))}</a>${dt}</td>
        <td>${srcChip} ${esc(d.section || '')}${d.row ? ' · ' + esc(String(d.row)) : ''}${acc}</td>
        <td class="num">${d.quantity != null ? esc(String(d.quantity)) : '—'}</td>
        <td class="num"><b title="${isEvo ? 'TEvo wholesale' : 'GoTickets all-in'}">${$r(d.gt_price)}</b></td>
        <td class="num">${$r(d.realized_median)}${d.realized_n != null ? ' <span class="muted small">n' + d.realized_n + (d.resale_basis === 'historic_realized' ? '·hist' : '·live') + '</span>' : ''}</td>
        <td class="num">${$r(d.est_net_resale)}</td>
        <td class="num deals-below">${d.net_profit_pct != null ? '+' + d.net_profit_pct + '%' : '—'}</td>
        <td class="num"><span class="badge regime-${wc}">${winPct}</span></td>
        <td class="num"><span class="badge regime-${d.score_v1 != null ? scoreClass(+d.score_v1) : 'neutral'}" title="market-only winner score for 7+ days out (resale velocity, weekend, 7d/14d trend, cost vs amalgam, moneyness, regime, days out, cost, lot)">${d.score_v1 != null ? Math.round(d.score_v1 * 100) + '%' : '—'}</span> ${gateChip(d)}</td>
        <td><span class="badge regime-${cc}">${esc(d.confidence || '')}</span></td>
        <td class="deals-open">${gtBtn}</td>
      </tr>`;
    }).join('');
    body.innerHTML = `<table class="deals-tbl">
      <thead><tr>
        <th>Seen</th><th>Event</th><th>Src · Section · Row</th><th class="num">Qty</th>
        <th class="num">Buy</th><th class="num">Realized med</th><th class="num">Est. net resale</th>
        <th class="num">Net profit</th><th class="num">Win odds</th><th class="num">Score v1</th><th>Conf</th><th>Open</th>
      </tr></thead>
      <tbody>${html}</tbody></table>`;
    setTimeout(() => { state.deals.forEach(d => { d._new = false; }); }, 6000);
  }

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', init);
  else init();
})();

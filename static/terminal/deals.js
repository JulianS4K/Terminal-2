// D0 Terminal — Deals page.
//
// GoTickets-EXCLUSIVE buyable deals, benchmarked against the OTHER sources'
// prices (EVO zone median). One SECDEF RPC:
//   get_gotickets_deals(p_event_id, p_max_age_hours, p_min_discount, p_min_zone_n, p_limit)
//   (mig 20260811203000). A GoTickets listing priced below the cross-market zone
//   median for the same event × zone is a deal; the event's 7-day-MA/DTE-curve
//   regime tags each OPPORTUNITY vs CAUTION (falling knife). Operator directive
//   2026-08-11: "deals should be exclusive to GoTickets for now, just use the data
//   from the other sites for metrics."
//
// Event is chosen via a search box (terminal_search RPC) or an ?event= param, so
// the same page deep-links from the global search / event page.

(function () {
  'use strict';
  const T = window.Terminal;
  const esc = window.TermRender.escapeHtml;

  const state = { eventId: null, minDiscount: 0.20 };

  const $r = v => (v != null && isFinite(+v) ? '$' + T.fmtNum(Math.round(+v)) : '—');

  async function init() {
    if (window.TerminalAuth) await window.TerminalAuth.requireAuth();
    wireControls();
    wireEventSearch();
    // Deep-link support: ?event=<tevo id> loads immediately.
    const q = new URLSearchParams(location.search);
    const ev = q.get('event');
    if (ev && /^\d+$/.test(ev)) { state.eventId = Number(ev); loadDeals(); }
    else if (T && T.setStatus) T.setStatus('Pick an event', 'ok');
  }

  function wireControls() {
    document.querySelectorAll('[data-disc]').forEach(btn => {
      btn.addEventListener('click', () => {
        document.querySelectorAll('[data-disc]').forEach(b => b.classList.remove('is-active'));
        btn.classList.add('is-active');
        state.minDiscount = parseFloat(btn.dataset.disc);
        if (state.eventId) loadDeals();
      });
    });
  }

  // ---------- Event search (reuses terminal_search) ----------
  function wireEventSearch() {
    const input = document.getElementById('dealsEventSearch');
    const sugg = document.getElementById('dealsEventSuggest');
    if (!input || !sugg) return;
    let debounceT = 0, lastQ = '';

    function close() { sugg.setAttribute('hidden', ''); }
    function open() { sugg.removeAttribute('hidden'); }

    async function run(qstr) {
      if (qstr === lastQ) return;
      lastQ = qstr;
      if (qstr.length < 2) { close(); return; }
      const Auth = window.TerminalAuth;
      if (!Auth || !Auth.client || !Auth.getAccessToken()) {
        sugg.innerHTML = '<div class="ts-empty">search needs auth — sign in with @s4kent.com</div>'; open(); return;
      }
      sugg.innerHTML = '<div class="ts-empty">searching…</div>'; open();
      const res = await Auth.client.rpc('terminal_search', { p_q: qstr, p_limit: 8 });
      if (res.error) { sugg.innerHTML = `<div class="ts-empty err">${esc(res.error.message || 'search error')}</div>`; return; }
      const evs = (res.data && res.data.events) || [];
      const players = (res.data && res.data.players) || [];
      // Flatten player→events too, so "Yankees" surfaces their games.
      const merged = [];
      evs.forEach(e => merged.push(e));
      players.forEach(pl => (pl.events || []).forEach(e => merged.push(e)));
      if (!merged.length) { sugg.innerHTML = `<div class="ts-empty">no events for &ldquo;${esc(qstr)}&rdquo;</div>`; return; }
      const seen = new Set();
      const rows = merged.filter(e => {
        const id = e.tevo_event_id; if (!id || seen.has(id)) return false; seen.add(id); return true;
      }).slice(0, 10).map(e => {
        const meta = [e.venue_name, fmtDate(e.occurs_at_local)].filter(Boolean).join(' · ');
        return `<a class="ts-row" href="#" data-ev="${e.tevo_event_id}">
            <span class="ts-name">${esc(e.name || '(unnamed)')}</span>
            <span class="ts-meta">${esc(meta)}</span></a>`;
      }).join('');
      sugg.innerHTML = rows;
      sugg.querySelectorAll('[data-ev]').forEach(a => {
        a.addEventListener('click', (ev) => {
          ev.preventDefault();
          state.eventId = Number(a.dataset.ev);
          input.value = a.querySelector('.ts-name').textContent;
          close();
          loadDeals();
        });
      });
    }

    input.addEventListener('input', () => {
      clearTimeout(debounceT);
      const qstr = input.value.trim();
      debounceT = setTimeout(() => run(qstr), 250);
    });
    input.addEventListener('focus', () => { if (lastQ.length >= 2 && sugg.innerHTML) open(); });
    document.addEventListener('click', (e) => { if (!sugg.contains(e.target) && e.target !== input) close(); });
  }

  function fmtDate(iso) {
    if (!iso) return '';
    try { return new Date(iso).toLocaleDateString(undefined, { month: 'short', day: 'numeric' }); }
    catch (_) { return ''; }
  }

  // ---------- Load + render ----------
  async function loadDeals() {
    const body = document.getElementById('dealsBody');
    const marketEl = document.getElementById('dealsMarket');
    const countEl = document.getElementById('dealsCount');
    if (body) body.innerHTML = '<div class="empty">Scanning GoTickets vs the cross-market book…</div>';
    if (marketEl) marketEl.innerHTML = '';
    if (countEl) countEl.textContent = '';
    if (T && T.setStatus) T.setStatus('Loading…', '');

    const Auth = window.TerminalAuth;
    const res = (Auth && Auth.client && Auth.getAccessToken())
      ? await Auth.client.rpc('get_gotickets_deals', { p_event_id: state.eventId, p_min_discount: state.minDiscount })
      : { error: { message: 'not signed in' } };

    if (res.error) {
      const code = res.error.code || '';
      const msg = code === '42883'
        ? 'DEALS RPC not deployed yet — pending migration 20260811203000'
        : (res.error.message || 'unavailable');
      if (T && T.setStatus) T.setStatus('error', 'err');
      if (body) body.innerHTML = `<div class="empty">RPC error: ${esc(msg)}</div>`;
      return;
    }
    if (T && T.setStatus) T.setStatus('Loaded', 'ok');
    render(res.data || {});
  }

  const REGIME_CLASS = { DUMPING: 'warn', SOFTENING: 'warn', STABLE: 'neutral', RISING: 'good', UNKNOWN: 'neutral' };

  function render(d) {
    const marketEl = document.getElementById('dealsMarket');
    const body = document.getElementById('dealsBody');
    const countEl = document.getElementById('dealsCount');
    const deals = d.deals || [];
    const m = d.market || {};

    if (countEl) countEl.textContent = `${d.n_deals || 0} deal${(d.n_deals === 1) ? '' : 's'}`;

    if (marketEl) {
      const nm = d.event_name || ('event ' + (d.event_id || ''));
      const reg = m.regime || 'UNKNOWN';
      const rc = REGIME_CLASS[reg] || 'mid';
      const bits = [];
      if (m.category) bits.push(esc(m.category));
      if (m.days_to_event != null) bits.push(`${m.days_to_event}d out`);
      if (m.actual_7d_pct != null) bits.push(`7d move ${m.actual_7d_pct > 0 ? '+' : ''}${m.actual_7d_pct}% (curve ${m.expected_7d_pct != null ? m.expected_7d_pct + '%' : '—'})`);
      marketEl.innerHTML = `<div class="deals-market-banner">
          <span class="deals-ev-name">${esc(nm)}</span>
          <span class="badge regime-${rc}">${esc(reg)}</span>
          <span class="muted small">${bits.join(' · ')}</span>
        </div>`;
    }

    if (!deals.length) {
      if (body) body.innerHTML = `<div class="empty">No GoTickets listing is priced ≥${Math.round(state.minDiscount * 100)}% below the market book for this event${d.n_deals === 0 ? '' : ''}. Try a lower threshold, or GoTickets may not cover this event.</div>`;
      return;
    }

    const rows = deals.map(x => {
      const verdictCls = x.verdict === 'OPPORTUNITY' ? 'good' : (x.verdict === 'CAUTION' ? 'warn' : 'neutral');
      const acc = x.is_accessible ? ' <span class="deals-acc" title="accessible / wheelchair">♿</span>' : '';
      return `<tr>
        <td>${esc(x.zone || '')}</td>
        <td>${esc(x.section || '')}${x.row ? ' · ' + esc(String(x.row)) : ''}${acc}</td>
        <td class="num">${x.quantity != null ? esc(String(x.quantity)) : '—'}</td>
        <td class="num"><b>${$r(x.gt_price)}</b></td>
        <td class="num">${$r(x.market_median)}</td>
        <td class="num deals-below">${x.vs_market_pct != null ? x.vs_market_pct + '%' : '—'}</td>
        <td><span class="badge regime-${verdictCls}">${esc(x.verdict || '')}</span></td>
      </tr>`;
    }).join('');

    if (body) {
      body.innerHTML = `<table class="deals-tbl">
        <thead><tr>
          <th>Zone</th><th>Section · Row</th><th class="num">Qty</th>
          <th class="num">GT price</th><th class="num">Market med</th><th class="num">Below</th><th>Verdict</th>
        </tr></thead>
        <tbody>${rows}</tbody></table>`;
    }
  }

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', init);
  else init();
})();

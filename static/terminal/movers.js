// D0 Terminal — Movers page.
// Calls /api/broker/movers?window_hours=<w>. Unions winner+loser lists into a
// single sortable table. Window selector + owned/all segment toggle.
// 5-bucket classifier is Phase 2 (not in endpoint yet).

(function () {
  'use strict';
  const T = window.Terminal;

  const state = {
    window: 24,
    segment: 'all', // 'all' | 'owned'
    rows: [],
    sortKey: 'delta_market_pct',
    sortDir: 'desc',
  };

  async function init() {
    if (window.TerminalAuth) await window.TerminalAuth.requireAuth();
    wireControls();
    load();
  }

  function wireControls() {
    document.querySelectorAll('[data-window]').forEach(btn => {
      btn.addEventListener('click', () => {
        document.querySelectorAll('[data-window]').forEach(b => b.classList.remove('is-active'));
        btn.classList.add('is-active');
        state.window = parseInt(btn.dataset.window, 10);
        load();
      });
    });
    document.querySelectorAll('[data-segment]').forEach(btn => {
      btn.addEventListener('click', () => {
        document.querySelectorAll('[data-segment]').forEach(b => b.classList.remove('is-active'));
        btn.classList.add('is-active');
        state.segment = btn.dataset.segment;
        render();
      });
    });
  }

  function load() {
    T.setStatus(`Loading movers · ${state.window}h…`);
    T.api(`/api/broker/movers?window_hours=${state.window}`)
      .then(data => {
        T.setStatus('Loaded', 'ok');
        const events = (data && data.events) || {};
        state.rows = unionRows([
          events.owned_winners, events.owned_losers,
          events.market_winners, events.market_losers,
          events.value_winners, events.value_losers,
          events.owned_value_winners, events.owned_value_losers,
        ]);
        render();
      })
      .catch(e => {
        T.setStatus(e.message, 'err');
        document.getElementById('moversBody').innerHTML = '<div class="empty">' + escapeHtml(e.message) + '</div>';
      });
  }

  function unionRows(lists) {
    const seen = new Map();
    lists.forEach(list => (list || []).forEach(r => {
      const id = r.event_id;
      if (id && !seen.has(id)) seen.set(id, r);
    }));
    return Array.from(seen.values());
  }

  // Blind-spot threshold matches home.js — sg_sales >= N AND owned_tix = 0
  // surfaces inventory we don't hold during active SG demand.
  const BLIND_SPOT_MIN_SG_SALES = 5;
  const BLIND_SPOT_MAX_ROWS     = 20;

  function renderBlindSpots() {
    const body = document.getElementById('blindSpotsBody');
    const countEl = document.getElementById('blindSpotsCount');
    if (!body) return;
    const candidates = state.rows
      .filter(r => (+r.sg_sales_window || 0) >= BLIND_SPOT_MIN_SG_SALES
                && (+r.cur_owned_tix || 0) === 0)
      .sort((a, b) => {
        const sa = +a.sg_sales_window || 0;
        const sb = +b.sg_sales_window || 0;
        if (sb !== sa) return sb - sa;
        return (+b.cur_market_tix || 0) - (+a.cur_market_tix || 0);
      });
    const n = candidates.length;
    if (countEl) countEl.textContent = n
      ? `${n} event${n === 1 ? '' : 's'} (showing top ${Math.min(n, BLIND_SPOT_MAX_ROWS)})`
      : '';
    if (!n) {
      body.innerHTML = '<div class="empty">no SG-only sales activity above threshold ✓</div>';
      return;
    }
    const tbl = document.createElement('table');
    tbl.className = 'blind-spots-tbl';
    tbl.innerHTML = `
      <thead><tr>
        <th>Event</th><th>Performer</th><th>Venue</th>
        <th class="num">T-days</th>
        <th class="num">SG sales</th>
        <th class="num">Mkt qty</th>
        <th class="num">Mkt median</th>
      </tr></thead>
      <tbody></tbody>`;
    const tb = tbl.querySelector('tbody');
    candidates.slice(0, BLIND_SPOT_MAX_ROWS).forEach(r => {
      const d = T.daysUntil(r.occurs_at_local || r.occurs_at);
      const tr = document.createElement('tr');
      tr.innerHTML = `
        <td><a href="event.html?event=${r.event_id}">${escapeHtml(r.name || r.event_name || ('Event ' + r.event_id))}</a></td>
        <td>${escapeHtml(r.performer_name || '—')}</td>
        <td>${escapeHtml(r.venue_name || '—')}</td>
        <td class="num">${d === null ? '—' : d}</td>
        <td class="num warn">${T.fmtNum(+r.sg_sales_window || 0)}</td>
        <td class="num">${T.fmtNum(+r.cur_market_tix || 0)}</td>
        <td class="num">${r.cur_market_med ? '$' + T.fmtNum(Math.round(+r.cur_market_med)) : '—'}</td>`;
      tb.appendChild(tr);
    });
    body.innerHTML = '';
    body.appendChild(tbl);
  }

  function render() {
    renderBlindSpots();
    const body = document.getElementById('moversBody');
    const filtered = state.segment === 'owned'
      ? state.rows.filter(r => (+r.cur_owned_tix || 0) > 0)
      : state.rows;

    document.getElementById('moversCount').textContent =
      filtered.length ? `${filtered.length} events` : '';

    if (!filtered.length) {
      body.innerHTML = '<div class="empty">no movers</div>';
      return;
    }

    const sorted = [...filtered].sort((a, b) => {
      const av = a[state.sortKey], bv = b[state.sortKey];
      if (av === null || av === undefined) return 1;
      if (bv === null || bv === undefined) return -1;
      return state.sortDir === 'desc' ? bv - av : av - bv;
    });

    const cols = [
      { key: null,                  label: 'Event',       align: 'left' },
      { key: null,                  label: 'Performer',   align: 'left' },
      { key: 'occurs_at_local',     label: 'T-days',      align: 'num' },
      { key: 'cur_market_tix',      label: 'Mkt qty',     align: 'num' },
      { key: 'cur_owned_tix',       label: 'Owned qty',   align: 'num' },
      { key: 'cur_market_med',      label: 'Mkt median',  align: 'num' },
      { key: 'cur_owned_med',       label: 'Own median',  align: 'num' },
      { key: 'sg_sales_window',     label: 'SG sales',    align: 'num' },
      { key: 'delta_market_pct',    label: 'Mkt %Δ',      align: 'num' },
      { key: 'delta_owned_pct',     label: 'Own %Δ',      align: 'num' },
      { key: 'delta_market_val',    label: 'Mkt Δ$',      align: 'num' },
      { key: 'delta_owned_val',     label: 'Own Δ$',      align: 'num' },
    ];

    body.innerHTML = '';
    const tbl = document.createElement('table');
    tbl.className = 'movers-tbl';
    const thead = document.createElement('thead');
    const trh = document.createElement('tr');
    cols.forEach(c => {
      const th = document.createElement('th');
      th.textContent = c.label;
      if (c.align === 'num') th.classList.add('num');
      if (c.key) {
        th.classList.add('sortable');
        th.dataset.sort = c.key;
        if (state.sortKey === c.key) th.classList.add('is-sorted', state.sortDir);
        th.addEventListener('click', () => {
          if (state.sortKey === c.key) state.sortDir = state.sortDir === 'desc' ? 'asc' : 'desc';
          else { state.sortKey = c.key; state.sortDir = 'desc'; }
          render();
        });
      }
      trh.appendChild(th);
    });
    thead.appendChild(trh);
    tbl.appendChild(thead);

    const tbody = document.createElement('tbody');
    sorted.slice(0, 100).forEach(r => {
      const tr = document.createElement('tr');
      tr.classList.add('clickable');
      tr.addEventListener('click', () => {
        window.location.href = 'event.html?event=' + r.event_id;
      });
      const d = T.daysUntil(r.occurs_at_local || r.occurs_at);
      const mDPct = +r.delta_market_pct;
      const oDPct = +r.delta_owned_pct;
      const mDVal = +r.delta_market_val;
      const oDVal = +r.delta_owned_val;
      const sg = +r.sg_sales_window || 0;
      const ownedTix = +r.cur_owned_tix || 0;
      const sgBlind = sg > BLIND_SPOT_MIN_SG_SALES && ownedTix === 0;
      tr.innerHTML = `
        <td><a href="event.html?event=${r.event_id}" onclick="event.stopPropagation()">${escapeHtml(r.name || r.event_name || ('Event ' + r.event_id))}</a></td>
        <td>${escapeHtml(r.performer_name || '—')}</td>
        <td class="num">${d === null ? '—' : d}</td>
        <td class="num">${T.fmtNum(+r.cur_market_tix || 0)}</td>
        <td class="num ${ownedTix > 0 ? 'ours' : ''}">${T.fmtNum(ownedTix)}</td>
        <td class="num">${r.cur_market_med ? '$' + T.fmtNum(Math.round(+r.cur_market_med)) : '—'}</td>
        <td class="num">${r.cur_owned_med ? '$' + T.fmtNum(Math.round(+r.cur_owned_med)) : '—'}</td>
        <td class="num ${sgBlind ? 'warn-cell' : ''}">${sg ? T.fmtNum(sg) : '—'}</td>
        <td class="num ${pctCls(mDPct)}">${Number.isFinite(mDPct) ? T.fmtPct(mDPct, 1) : '—'}</td>
        <td class="num ${pctCls(oDPct)}">${Number.isFinite(oDPct) ? T.fmtPct(oDPct, 1) : '—'}</td>
        <td class="num ${pctCls(mDVal)}">${fmtDelta(mDVal)}</td>
        <td class="num ${pctCls(oDVal)}">${fmtDelta(oDVal)}</td>
      `;
      tbody.appendChild(tr);
    });
    tbl.appendChild(tbody);
    body.appendChild(tbl);
  }

  function pctCls(v) {
    if (!Number.isFinite(v)) return '';
    return v > 0 ? 'pos' : v < 0 ? 'neg' : '';
  }

  function fmtDelta(v) {
    if (!Number.isFinite(v)) return '—';
    return (v >= 0 ? '+' : '−') + '$' + T.fmtNum(Math.round(Math.abs(v)));
  }

  function escapeHtml(s) {
    if (s === null || s === undefined) return '';
    return String(s).replace(/[&<>"']/g, c => ({
      '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;',
    }[c]));
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init);
  } else {
    init();
  }
})();

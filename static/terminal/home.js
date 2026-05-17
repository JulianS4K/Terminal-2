// D0 Terminal — Home page.
// One fetch: /api/broker/movers?window_hours=<window>. Derives coverage band,
// blind spots panel, full movers table (with window/segment controls), and
// the owned-events list from the single mover response.
//
// Movers table mirrors the standalone movers.html page — operator can change
// the window or segment from home without page-hopping.

(function () {
  'use strict';
  const T = window.Terminal;

  const state = {
    window: 24,
    segment: 'all',          // 'all' | 'owned'
    rows: [],
    sortKey: 'delta_market_pct',
    sortDir: 'desc',
  };

  async function init() {
    if (window.TerminalAuth) await window.TerminalAuth.requireAuth();
    wireMoversControls();
    load();
  }

  function load() {
    T.setStatus(`Loading home · ${state.window}h…`);
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
        renderCoverage(state.rows);
        renderBlindSpots(state.rows);
        renderMovers();
        renderOwnedEvents(state.rows);
      })
      .catch(e => {
        T.setStatus(e.message, 'err');
        const body = document.getElementById('moversBody');
        if (body) body.innerHTML = '<div class="empty">' + escapeHtml(e.message) + '</div>';
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

  // ---------- Coverage band ----------

  function renderCoverage(rows) {
    const now = Date.now();
    const day = 86400000;
    let total = 0, w30 = 0, w7 = 0, today = 0;
    rows.forEach(r => {
      total++;
      const t = new Date(r.occurs_at_local || r.occurs_at).getTime();
      if (!Number.isFinite(t)) return;
      const days = (t - now) / day;
      if (days <= 30) w30++;
      if (days <= 7)  w7++;
      if (days <= 1)  today++;
    });
    setText('cvTotal', T.fmtNum(total));
    setText('cv30d',   T.fmtNum(w30));
    setText('cv7d',    T.fmtNum(w7));
    setText('cvToday', T.fmtNum(today));
  }

  // ---------- Blind spots panel — SG selling, we're not ----------
  //
  // Filter: sg_sales_window >= BLIND_SPOT_MIN_SG_SALES AND cur_owned_tix == 0.
  // Operator can't capture revenue on inventory they don't hold; surface the
  // gap so they can investigate (procure, contact buyer, or list elsewhere).
  // The window matches the mover window selector — at 24h the chip threshold
  // is "5 SG sales in 24h"; at 7d it's "5 SG sales in 7d". Threshold 5 is a
  // tuning placeholder.

  const BLIND_SPOT_MIN_SG_SALES = 5;
  const BLIND_SPOT_MAX_ROWS     = 20;

  function renderBlindSpots(rows) {
    const body = document.getElementById('blindSpotsBody');
    const countEl = document.getElementById('blindSpotsCount');
    if (!body) return;
    const candidates = rows
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

  // ---------- Full movers table (mirrors movers.html) ----------

  function wireMoversControls() {
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
        renderMovers();
      });
    });
  }

  function renderMovers() {
    const body = document.getElementById('moversBody');
    if (!body) return;
    const filtered = state.segment === 'owned'
      ? state.rows.filter(r => (+r.cur_owned_tix || 0) > 0)
      : state.rows;

    const countEl = document.getElementById('moversCount');
    if (countEl) countEl.textContent = filtered.length ? `${filtered.length} events` : '';

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
          renderMovers();
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
      tr.addEventListener('click', () => { window.location.href = 'event.html?event=' + r.event_id; });
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
        <td class="num ${pctCls(oDVal)}">${fmtDelta(oDVal)}</td>`;
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

  // ---------- Owned events list (next 30d) ----------

  function renderOwnedEvents(rows) {
    const body = document.getElementById('ownedEventsBody');
    const countEl = document.getElementById('ownedEventCount');
    body.innerHTML = '';
    const now = Date.now();
    const day = 86400000;
    const upcoming = rows.filter(r => {
      if (!((+r.cur_owned_tix || 0) > 0)) return false;
      const t = new Date(r.occurs_at_local || r.occurs_at).getTime();
      if (!Number.isFinite(t)) return false;
      const days = (t - now) / day;
      return days >= -1 && days <= 30;
    }).sort((a, b) => {
      // Soonest-first by event date.
      const ta = new Date(a.occurs_at_local || a.occurs_at).getTime();
      const tb = new Date(b.occurs_at_local || b.occurs_at).getTime();
      if (!Number.isFinite(ta)) return 1;
      if (!Number.isFinite(tb)) return -1;
      return ta - tb;
    });

    countEl.textContent = upcoming.length ? `${upcoming.length} events` : '';

    if (!upcoming.length) {
      body.innerHTML = '<div class="empty">no owned events in the next 30d</div>';
      return;
    }

    const tbl = document.createElement('table');
    tbl.innerHTML = `
      <thead><tr>
        <th>Event</th>
        <th>Performer</th>
        <th class="num">T-days</th>
        <th class="num">Owned qty</th>
        <th class="num">Owned med</th>
        <th class="num">Notional</th>
        <th class="num">24h Δ$</th>
      </tr></thead>
      <tbody></tbody>
    `;
    const tb = tbl.querySelector('tbody');
    upcoming.slice(0, 30).forEach(r => {
      const ot = +r.cur_owned_tix || 0;
      const om = +r.cur_owned_med || 0;
      const notional = ot * om;
      const d = T.daysUntil(r.occurs_at_local || r.occurs_at);
      const dval = +r.delta_owned_val;
      const dvalCls = !Number.isFinite(dval) ? '' : dval > 0 ? 'pos' : dval < 0 ? 'neg' : '';
      const dvalTxt = !Number.isFinite(dval) ? '—' : (dval >= 0 ? '+' : '−') + '$' + T.fmtNum(Math.round(Math.abs(dval)));
      const tr = document.createElement('tr');
      tr.innerHTML = `
        <td><a href="event.html?event=${r.event_id}">${escapeHtml(r.name || r.event_name || ('Event ' + r.event_id))}</a></td>
        <td>${escapeHtml(r.performer_name || '—')}</td>
        <td class="num">${d === null ? '—' : d}</td>
        <td class="num">${T.fmtNum(ot)}</td>
        <td class="num">${om ? '$' + T.fmtNum(Math.round(om)) : '—'}</td>
        <td class="num">${notional ? '$' + T.fmtNum(Math.round(notional)) : '—'}</td>
        <td class="num ${dvalCls}">${dvalTxt}</td>
      `;
      tb.appendChild(tr);
    });
    body.appendChild(tbl);
  }

  // ---------- Util ----------

  function setText(id, txt) {
    const el = document.getElementById(id);
    if (el) el.textContent = txt;
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

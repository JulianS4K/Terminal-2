// D0 Terminal — Home page.
// One fetch: /api/broker/movers?window_hours=24. Derives coverage band,
// book summary, top-movers strip, and the owned-events list from the
// single mover response (one row per future-dated active event).

(function () {
  'use strict';
  const T = window.Terminal;

  async function init() {
    if (window.TerminalAuth) await window.TerminalAuth.requireAuth();
    T.setStatus('Loading home…');
    T.api('/api/broker/movers?window_hours=24')
      .then(data => {
        T.setStatus('Loaded', 'ok');
        const events = (data && data.events) || {};
        // owned_value_* and market_value_* are dedupe-disjoint top-10 lists,
        // each row carries the full event fields. Build a row index for the
        // coverage band / book summary by unioning across the lists.
        const allRows = unionRows([
          events.owned_winners, events.owned_losers,
          events.market_winners, events.market_losers,
          events.value_winners, events.value_losers,
          events.owned_value_winners, events.owned_value_losers,
        ]);
        renderCoverage(allRows);
        renderBook(allRows);
        renderMovers(events.owned_value_winners, events.owned_value_losers);
        renderOwnedEvents(allRows);
      })
      .catch(e => {
        T.setStatus(e.message, 'err');
        document.getElementById('moversGrid').innerHTML = '<div class="empty">' + escapeHtml(e.message) + '</div>';
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

  // ---------- Book summary ----------

  function renderBook(rows) {
    let ownedTix = 0, marketTix = 0, ownedNotional = 0, ownedEvents = 0;
    rows.forEach(r => {
      const ot = +r.cur_owned_tix || 0;
      const mt = +r.cur_market_tix || 0;
      const om = +r.cur_owned_med || 0;
      ownedTix += ot;
      marketTix += mt;
      ownedNotional += ot * om;
      if (ot > 0) ownedEvents++;
    });
    setText('bkOwnedTix',      T.fmtNum(ownedTix));
    setText('bkMarketTix',     T.fmtNum(marketTix));
    setText('bkOwnedEvents',   T.fmtNum(ownedEvents));
    setText('bkOwnedNotional', '$' + T.fmtNum(Math.round(ownedNotional)));
  }

  // ---------- Movers strip (6 cards) ----------

  function renderMovers(winners, losers) {
    const grid = document.getElementById('moversGrid');
    grid.innerHTML = '';
    const cards = [
      ...(winners || []).slice(0, 3).map(r => ({ row: r, sign: 'pos' })),
      ...(losers  || []).slice(0, 3).map(r => ({ row: r, sign: 'neg' })),
    ];
    if (!cards.length) {
      grid.innerHTML = '<div class="empty">no movers in the last 24h</div>';
      return;
    }
    cards.forEach(c => {
      const r = c.row;
      const d = T.daysUntil(r.occurs_at_local || r.occurs_at);
      const dval = +r.delta_owned_val;
      const dpct = +r.delta_owned_pct;
      const card = document.createElement('a');
      card.className = 'mover-card ' + c.sign;
      card.href = 'event.html?event=' + r.event_id;
      card.innerHTML = `
        <div class="mc-name">${escapeHtml(r.event_name || ('Event ' + r.event_id))}</div>
        <div class="mc-meta">${escapeHtml(r.performer_name || '')}${r.venue_name ? ' · ' + escapeHtml(r.venue_name) : ''}</div>
        <div class="mc-vals">
          <span class="mc-dval">${(dval >= 0 ? '+' : '') + '$' + T.fmtNum(Math.round(Math.abs(dval)))}</span>
          <span class="mc-dpct">${T.fmtPct(dpct, 1)}</span>
        </div>
        <div class="mc-foot">${d === null ? '' : (d <= 0 ? 'TODAY' : d === 1 ? 'TOMORROW' : 'T-' + d + 'd')} · ${T.fmtNum(+r.cur_owned_tix || 0)} owned</div>
      `;
      grid.appendChild(card);
    });
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
      // Sort by owned notional desc
      const na = (+a.cur_owned_tix || 0) * (+a.cur_owned_med || 0);
      const nb = (+b.cur_owned_tix || 0) * (+b.cur_owned_med || 0);
      return nb - na;
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
        <td><a href="event.html?event=${r.event_id}">${escapeHtml(r.event_name || ('Event ' + r.event_id))}</a></td>
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

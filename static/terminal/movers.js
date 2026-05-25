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
    // Blind spots is independent of /api/broker/movers — fires its own RPC.
    renderBlindSpots().catch(e => console.error('[blindSpots]', e));
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

  // Blind spots — calls get_blind_spots_sg_selling RPC (mig 20260520370000;
  // perf-fixed via matview mig 20260524120000). Same RPC + render shape as
  // home.js. See home.js comment block for design.
  // selling_score is a 0-4 composite (listings drop + price rise + sales accel
  // + sales above ask). Default 2 = "two independent signals agree" — a real
  // blind-spot, not single-signal noise. Lowered from 3 (audit 2026-05-24:
  // score>=3 essentially never reached given the live signal distribution).
  const BLIND_SPOT_MIN_SCORE = 2;
  const BLIND_SPOT_MAX_ROWS  = 20;
  // Threshold for the row-level "blindspot" highlight: SG sales activity
  // above this level with zero owned tickets flags the row warn-color.
  // Mirrors the legacy heuristic; matched declaration in home.js (PR fixing
  // ReferenceError on render).
  const BLIND_SPOT_MIN_SG_SALES = 5;

  async function renderBlindSpots() {
    const body = document.getElementById('blindSpotsBody');
    const countEl = document.getElementById('blindSpotsCount');
    if (!body) return;

    const Auth = window.TerminalAuth;
    if (!Auth || !Auth.client || !Auth.getAccessToken()) {
      body.innerHTML = '<div class="empty">not signed in</div>';
      return;
    }

    body.innerHTML = '<div class="empty">loading…</div>';

    let rows;
    try {
      const res = await Auth.client.rpc('get_blind_spots_sg_selling',
        { p_min_score: BLIND_SPOT_MIN_SCORE });
      if (res.error) throw new Error(res.error.message || 'RPC error');
      rows = res.data || [];
    } catch (e) {
      body.innerHTML = '<div class="empty">error: ' + escapeHtml(e.message) + '</div>';
      if (countEl) countEl.textContent = '';
      return;
    }

    const n = rows.length;
    if (countEl) countEl.textContent = n
      ? `${n} event${n === 1 ? '' : 's'} (showing top ${Math.min(n, BLIND_SPOT_MAX_ROWS)})`
      : '';

    if (!n) {
      body.innerHTML =
        '<div class="empty">no SG-selling signals at score &ge; ' + BLIND_SPOT_MIN_SCORE +
        '/4 (48h baseline accumulating)</div>';
      return;
    }

    const tbl = document.createElement('table');
    tbl.className = 'blind-spots-tbl';
    tbl.innerHTML = `
      <thead><tr>
        <th>Event</th><th>Venue</th>
        <th class="num">T-days</th>
        <th class="num" title="Composite 0-4 across listings drop + price rise + sales accel + sales above ask">Score</th>
        <th class="num" title="DISTINCT sg_sale_id in last 24h">Sales 24h</th>
        <th class="num" title="Sales velocity: last 24h vs prior 24h">Vel %</th>
        <th class="num">Listings</th>
        <th class="num" title="48h delta on distinct sglid count">L Δ%</th>
        <th class="num">Med px</th>
        <th class="num" title="48h delta on median listing price">P Δ%</th>
        <th class="num" title="Median sale 24h vs current median ask">Sale/Ask</th>
        <th class="num" title="Sales 24h / Listings now">Clear</th>
      </tr></thead>
      <tbody></tbody>`;
    const tb = tbl.querySelector('tbody');

    rows.slice(0, BLIND_SPOT_MAX_ROWS).forEach(r => {
      const d = T.daysUntil(r.sg_datetime_utc);
      const tr = document.createElement('tr');

      const eventLabel = r.tevo_event_id
        ? `<a href="event.html?event=${r.tevo_event_id}">${escapeHtml(r.sg_event_name || ('SG ' + r.sg_event_id))}</a>`
        : escapeHtml(r.sg_event_name || ('SG ' + r.sg_event_id));

      const signalsTitle = [
        (r.signal_listings_drop  ? '✓' : '✗') + ' listings shrinking ≥ 5%',
        (r.signal_price_rise     ? '✓' : '✗') + ' price rising ≥ 10%',
        (r.signal_sales_accel    ? '✓' : '✗') + ' sales accelerating ≥ 30%',
        (r.signal_sales_above_ask? '✓' : '✗') + ' sales clearing at/above ask'
      ].join(' · ');

      const pct = v => (v == null ? '—' : T.fmtPct(v));
      const cls = (cond, on, off) => cond ? on : (off || '');

      tr.innerHTML = `
        <td>${eventLabel}</td>
        <td>${escapeHtml(r.sg_venue_name || '—')}</td>
        <td class="num">${d === null ? '—' : d}</td>
        <td class="num" title="${signalsTitle}"><strong>${r.selling_score}/4</strong></td>
        <td class="num">${r.sales_24h_count || 0}</td>
        <td class="num ${cls(r.sales_velocity_pct > 0, 'pos', r.sales_velocity_pct < 0 ? 'neg' : '')}">${pct(r.sales_velocity_pct)}</td>
        <td class="num">${r.listings_now}</td>
        <td class="num ${cls(r.listings_pct_delta < 0, 'neg', r.listings_pct_delta > 0 ? 'pos' : '')}">${pct(r.listings_pct_delta)}</td>
        <td class="num">${r.median_now ? '$' + T.fmtNum(Math.round(+r.median_now)) : '—'}</td>
        <td class="num ${cls(r.price_pct_delta > 0, 'pos', r.price_pct_delta < 0 ? 'neg' : '')}">${pct(r.price_pct_delta)}</td>
        <td class="num ${cls(r.sale_vs_listing_pct > 0, 'pos', r.sale_vs_listing_pct < 0 ? 'neg' : '')}">${pct(r.sale_vs_listing_pct)}</td>
        <td class="num">${r.clearing_ratio != null ? T.fmtNum(Math.round(r.clearing_ratio * 100)) + '%' : '—'}</td>`;
      tb.appendChild(tr);
    });

    body.innerHTML = '';
    body.appendChild(tbl);
  }

  function render() {
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

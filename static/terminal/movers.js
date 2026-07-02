// D0 Terminal — Movers page.
//
// Two modes:
//   • v2 (default) — reads `event_movers_index` via Path-C Supabase RPCs
//       get_event_movers_v2(source, window_days, category, limit)
//       get_event_movers_index_summary(source, window_days)
//     (mig 20260527260000_movers_index_rpc_api). Source / window-days /
//     category controls drive the index slot. Cross-source median + spread
//     columns surface inter-platform arbitrage signals.
//   • legacy — keeps the original /api/broker/movers?window_hours=N path
//     (winner/loser/value list shape) for backward compat until home.js is
//     migrated and the legacy controls retired.
//
// Blind spots is independent — its own Path-C RPC.

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

  // V2 index mode state
  const v2State = {
    source: 'merged',
    windowDays: 7,
    category: null, // null = all categories
    data: null,
  };

  async function init() {
    if (window.TerminalAuth) await window.TerminalAuth.requireAuth();
    wireControls();
    // Blind spots is independent of /api/broker/movers — fires its own RPC.
    renderBlindSpots().catch(e => console.error('[blindSpots]', e));
    // Default to v2 index mode; switchMode triggers loadV2().
    switchMode('v2');
  }

  function wireControls() {
    // Mode toggle
    document.querySelectorAll('[data-mode]').forEach(btn => {
      btn.addEventListener('click', () => switchMode(btn.dataset.mode));
    });

    // V2 — source
    document.querySelectorAll('[data-source]').forEach(btn => {
      btn.addEventListener('click', () => {
        document.querySelectorAll('[data-source]').forEach(b => b.classList.remove('is-active'));
        btn.classList.add('is-active');
        v2State.source = btn.dataset.source;
        v2State.data = null; // force reload
        loadV2();
      });
    });
    // V2 — window (days horizon)
    document.querySelectorAll('[data-wdays]').forEach(btn => {
      btn.addEventListener('click', () => {
        document.querySelectorAll('[data-wdays]').forEach(b => b.classList.remove('is-active'));
        btn.classList.add('is-active');
        v2State.windowDays = parseInt(btn.dataset.wdays, 10);
        v2State.data = null;
        loadV2();
      });
    });
    // V2 — category
    document.querySelectorAll('[data-cat]').forEach(btn => {
      btn.addEventListener('click', () => {
        document.querySelectorAll('[data-cat]').forEach(b => b.classList.remove('is-active'));
        btn.classList.add('is-active');
        v2State.category = btn.dataset.cat || null;
        v2State.data = null;
        loadV2();
      });
    });

    // Legacy — window (hours)
    document.querySelectorAll('[data-window]').forEach(btn => {
      btn.addEventListener('click', () => {
        document.querySelectorAll('[data-window]').forEach(b => b.classList.remove('is-active'));
        btn.classList.add('is-active');
        state.window = parseInt(btn.dataset.window, 10);
        load();
      });
    });
    // Legacy — segment
    document.querySelectorAll('[data-segment]').forEach(btn => {
      btn.addEventListener('click', () => {
        document.querySelectorAll('[data-segment]').forEach(b => b.classList.remove('is-active'));
        btn.classList.add('is-active');
        state.segment = btn.dataset.segment;
        render();
      });
    });
  }

  // ============================================================
  // Mode switching — v2 / legacy
  // ============================================================
  function switchMode(mode) {
    document.querySelectorAll('[data-mode]').forEach(b => b.classList.toggle('is-active', b.dataset.mode === mode));
    const v2Ctrl    = document.getElementById('v2Controls');
    const legCtrl   = document.getElementById('legacyControls');
    const v2Sec     = document.getElementById('movers-v2');
    const legSec    = document.getElementById('legacyResults');
    if (mode === 'v2') {
      if (v2Ctrl)  v2Ctrl.removeAttribute('hidden');
      if (legCtrl) legCtrl.setAttribute('hidden', '');
      if (v2Sec)   v2Sec.removeAttribute('hidden');
      if (legSec)  legSec.setAttribute('hidden', '');
      if (!v2State.data) loadV2();
    } else {
      if (v2Ctrl)  v2Ctrl.setAttribute('hidden', '');
      if (legCtrl) legCtrl.removeAttribute('hidden');
      if (v2Sec)   v2Sec.setAttribute('hidden', '');
      if (legSec)  legSec.removeAttribute('hidden');
      load(); // fire legacy load
    }
  }

  // ============================================================
  // V2 — load + render (Path-C: direct Supabase RPCs)
  // ============================================================
  async function loadV2() {
    const body    = document.getElementById('v2Body');
    const countEl = document.getElementById('v2Count');
    if (body) body.innerHTML = '<div class="empty">loading…</div>';
    const stripEl = document.getElementById('v2SummaryStrip');
    if (stripEl) stripEl.innerHTML = '';

    T.setStatus(`Loading v2 movers · ${v2State.source} · ${v2State.windowDays}d…`);

    const Auth = window.TerminalAuth;
    if (!Auth || !Auth.client || !Auth.getAccessToken()) {
      if (body) body.innerHTML = '<div class="empty">not signed in</div>';
      T.setStatus('not signed in', 'err');
      return;
    }

    try {
      // Direct Path-C reads of the movers-index RPCs (mig 20260527260000) —
      // replaces the cross-origin T.api('/api/broker/movers?…') call. Same
      // pattern as renderBlindSpots's get_blind_spots_sg_selling call.
      // p_limit=200 safely covers 6 categories × 25 rank slots.
      const [eventsRes, summaryRes] = await Promise.all([
        Auth.client.rpc('get_event_movers_v2', {
          p_source: v2State.source,
          p_window_days: v2State.windowDays,
          p_category: v2State.category,  // null = all categories
          p_limit: 200,
        }),
        Auth.client.rpc('get_event_movers_index_summary', {
          p_source: v2State.source,
          p_window_days: v2State.windowDays,
        }),
      ]);
      if (eventsRes.error)  throw new Error(eventsRes.error.message  || 'movers RPC error');
      if (summaryRes.error) throw new Error(summaryRes.error.message || 'summary RPC error');

      const events  = eventsRes.data  || [];
      const summary = summaryRes.data || [];

      // Reshape flat rows → { event_count, events_by_category, summary } so the
      // existing renderV2Events / renderV2Summary keep working unchanged.
      const byCategory = {};
      events.forEach(r => {
        const cat = r.category || 'uncategorized';
        (byCategory[cat] = byCategory[cat] || []).push(r);
      });
      const data = {
        event_count: events.length,
        events_by_category: byCategory,
        summary: summary,
      };

      T.setStatus('Loaded', 'ok');
      v2State.data = data;
      if (countEl) countEl.textContent = data.event_count ? `${data.event_count} events` : '';
      renderV2Summary(data.summary || []);
      renderV2Events(data);
    } catch (e) {
      T.setStatus(e.message, 'err');
      if (body) body.innerHTML = '<div class="empty">' + escapeHtml(e.message) + '</div>';
    }
  }

  function renderV2Summary(summary) {
    const strip = document.getElementById('v2SummaryStrip');
    if (!strip || !summary.length) { if (strip) strip.innerHTML = ''; return; }
    strip.innerHTML = summary.map(s => {
      const sz  = s.index_size || 0;
      const cov = s.data_coverage_pct != null ? ` · ${Math.round(s.data_coverage_pct)}% cov` : '';
      const turn = ((s.entries_24h || 0) + (s.exits_24h || 0));
      const turnStr = turn ? ` · ${turn} Δ/24h` : '';
      return `<span class="badge" title="source=${escapeHtml(s.source)} window=${s.window_days}d">${escapeHtml(s.source)}·${s.window_days}d·${escapeHtml(s.category||'')}: ${sz}${cov}${turnStr}</span>`;
    }).join(' ');
  }

  function renderV2Events(data) {
    const body = document.getElementById('v2Body');
    if (!body) return;
    const byCategory = (data && data.events_by_category) || {};
    const categories = Object.keys(byCategory).sort();
    if (!categories.length) {
      body.innerHTML = '<div class="empty">no events in index for this source + window — data still accumulating</div>';
      return;
    }
    body.innerHTML = '';
    categories.forEach(cat => {
      const events = byCategory[cat] || [];
      if (!events.length) return;
      const section = document.createElement('div');
      section.className = 'v2-category-section';
      const hdr = document.createElement('div');
      hdr.className = 'panel-title row';
      hdr.innerHTML = `<span>${escapeHtml(cat.toUpperCase().replace(/_/g,' '))} <span class="tab-count">${events.length}</span></span>`;
      section.appendChild(hdr);
      section.appendChild(buildV2Table(events));
      body.appendChild(section);
    });
  }

  function buildV2Table(events) {
    const $p = v => v != null ? '$' + T.fmtNum(Math.round(+v)) : '—';
    const $spread = v => {
      if (v == null) return '';
      const n = +v;
      return `<span class="${n > 2 ? 'pos' : n < -2 ? 'neg' : 'muted small'}">${n > 0 ? '+' : ''}${n.toFixed(0)}%</span>`;
    };
    const $dpct = v => {
      if (v == null || !Number.isFinite(+v)) return '—';
      const n = +v;
      return `<span class="${n > 0 ? 'pos' : n < 0 ? 'neg' : ''}">${n > 0 ? '+' : ''}${n.toFixed(1)}%</span>`;
    };

    const tbl = document.createElement('table');
    tbl.className = 'movers-v2-tbl';
    tbl.innerHTML = `
      <thead><tr>
        <th class="num">#</th>
        <th>Event</th>
        <th class="num">T</th>
        <th class="num">EVO</th>
        <th class="num">SG</th>
        <th class="num">SH</th>
        <th class="num">GT</th>
        <th class="num">VD</th>
        <th class="num">SH/EVO</th>
        <th class="num">GT/SH</th>
        <th class="num">VD/SH</th>
        <th class="num">Cur $</th>
        <th class="num">Δ%</th>
        <th class="num" title="Market tickets available (cur_tix)">Mkt</th>
        <th class="num">Own</th>
        <th class="num">Score</th>
      </tr></thead><tbody></tbody>`;
    const tb = tbl.querySelector('tbody');

    [...events].sort((a, b) => (+a.rank || 99) - (+b.rank || 99)).forEach(r => {
      const tr = document.createElement('tr');
      tr.classList.add('clickable');
      tr.addEventListener('click', () => { window.location.href = 'event.html?event=' + r.event_id; });
      const ownedTix = +r.cur_owned || 0;
      tr.innerHTML = `
        <td class="num muted small">${r.rank}</td>
        <td><a href="event.html?event=${r.event_id}" onclick="event.stopPropagation()">${escapeHtml(r.event_name || ('Event ' + r.event_id))}</a></td>
        <td class="num">${r.days_to_event != null ? r.days_to_event : '—'}</td>
        <td class="num">${$p(r.evo_median)}</td>
        <td class="num">${$p(r.sg_median)}</td>
        <td class="num">${$p(r.td_sh_median)}</td>
        <td class="num">${$p(r.td_gt_median)}</td>
        <td class="num">${$p(r.td_vd_median)}</td>
        <td class="num">${$spread(r.sh_vs_evo_spread)}</td>
        <td class="num">${$spread(r.gt_vs_sh_spread)}</td>
        <td class="num">${$spread(r.vd_vs_sh_spread)}</td>
        <td class="num">${$p(r.cur_price)}</td>
        <td class="num">${$dpct(r.price_delta_pct)}</td>
        <td class="num">${r.cur_tix != null ? T.fmtNum(+r.cur_tix) : '—'}</td>
        <td class="num ${ownedTix > 0 ? 'ours' : ''}">${T.fmtNum(ownedTix)}</td>
        <td class="num muted small">${r.signal_score != null ? (+r.signal_score).toFixed(2) : '—'}</td>`;
      tb.appendChild(tr);
    });
    return tbl;
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

  const escapeHtml = window.TermRender.escapeHtml;

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init);
  } else {
    init();
  }
})();

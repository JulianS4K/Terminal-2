// D0 Terminal — Home page.
//
// Movers panel reads `event_movers_index` via Path-C RPCs (mig 20260527260000):
//   get_event_movers_v2(source, window_days, category, limit)
//   get_event_movers_index_summary(source, window_days)
// Coverage band, full movers table (source / window / segment controls), and
// owned-events list all derive from the v2 rows.
//
// Semantic shift from the prior /api/broker/movers?window_hours= path:
//   • OLD: events that moved in the last N hours (rolling-window delta).
//   • NEW: events currently in the mover index slot for an N-day horizon —
//     populated by the cross-source mover compute (price_up / price_down /
//     selling_fast / accumulating / value_gap / cross_gap categories).
// Source toggle lets operator pin to a single platform or use the merged
// composite. Owned/market deltas + SG sales / owned median / value cols
// from the legacy panel are NOT in v2 — they render as "—" honest empty.
// Blind spots fires its own RPC (get_blind_spots_sg_selling) — independent.

(function () {
  'use strict';
  const T = window.Terminal;

  const state = {
    source: 'merged',         // 'merged' | 'evo' | 'sg' | 'td_sh' | 'td_gt' | 'td_vd'
    windowDays: 7,            // 7 | 15 | 30 | 180 (rpc-supported buckets)
    segment: 'all',           // 'all' | 'owned'
    rows: [],
    sortKey: 'delta_market_pct',
    sortDir: 'desc',
  };

  async function init() {
    if (window.TerminalAuth) await window.TerminalAuth.requireAuth();
    wireMoversControls();
    // Blind spots fires its own RPC, independent of movers — runs in parallel.
    renderBlindSpots().catch(e => console.error('[blindSpots]', e));
    load();
  }

  // ---------- Path-C v2 movers load ----------

  async function load() {
    T.setStatus(`Loading home · ${state.source} · ${state.windowDays}d…`);
    const body = document.getElementById('moversBody');
    if (body) body.innerHTML = '<div class="empty">loading…</div>';

    const Auth = window.TerminalAuth;
    if (!Auth || !Auth.client || !Auth.getAccessToken()) {
      T.setStatus('not signed in', 'err');
      if (body) body.innerHTML = '<div class="empty">not signed in</div>';
      return;
    }

    try {
      const [eventsRes, summaryRes] = await Promise.all([
        Auth.client.rpc('get_event_movers_v2', {
          p_source:      state.source,
          p_window_days: state.windowDays,
          p_category:    null,   // all categories
          p_limit:       200,
        }),
        Auth.client.rpc('get_event_movers_index_summary', {
          p_source:      state.source,
          p_window_days: state.windowDays,
        }),
      ]);
      if (eventsRes.error)  throw new Error(eventsRes.error.message  || 'movers RPC error');
      if (summaryRes.error) throw new Error(summaryRes.error.message || 'summary RPC error');

      const rawRows = eventsRes.data  || [];
      const summary = summaryRes.data || [];

      // Reshape v2 columns to the legacy field aliases that renderMovers /
      // renderCoverage / renderOwnedEvents consume. Fields not in v2 become null
      // and render as "—".
      state.rows = rawRows.map(reshapeV2Row);

      T.setStatus('Loaded', 'ok');
      renderSummaryStrip(summary);
      renderCoverage(state.rows);
      renderMovers();
      renderOwnedEvents(state.rows);
    } catch (e) {
      T.setStatus(e.message, 'err');
      if (body) body.innerHTML = '<div class="empty">' + escapeHtml(e.message) + '</div>';
    }
  }

  // Map v2 RPC row → legacy field names used by the render functions.
  function reshapeV2Row(r) {
    return Object.assign({}, r, {
      // v2 → legacy alias
      name:             r.event_name || r.name || ('Event ' + r.event_id),
      occurs_at_local:  r.occurs_at  || r.occurs_at_local,
      cur_market_med:   r.cur_price  != null ? +r.cur_price  : null,
      delta_market_pct: r.price_delta_pct != null ? +r.price_delta_pct : null,
      cur_owned_tix:    r.cur_owned  != null ? +r.cur_owned  : 0,
      // v2 lacks these — null renders as "—" in the table
      cur_market_tix:   null,
      cur_owned_med:    null,
      sg_sales_window:  null,
      delta_owned_pct:  null,
      delta_market_val: null,
      delta_owned_val:  null,
      performer_name:   null,
    });
  }

  // Summary strip above movers table — same shape as movers.html v2SummaryStrip.
  function renderSummaryStrip(summary) {
    const strip = document.getElementById('moversSummaryStrip');
    if (!strip || !summary.length) { if (strip) strip.innerHTML = ''; return; }
    strip.innerHTML = summary.map(s => {
      const sz   = s.index_size || 0;
      const cov  = s.data_coverage_pct != null ? ` · ${Math.round(s.data_coverage_pct)}% cov` : '';
      const turn = (+s.entries_24h || 0) + (+s.exits_24h || 0);
      const turnStr = turn ? ` · ${turn} Δ/24h` : '';
      return `<span class="badge" title="source=${s.source} window=${s.window_days}d">${escapeHtml(s.source)}·${s.window_days}d·${escapeHtml(s.category || '')}: ${sz}${cov}${turnStr}</span>`;
    }).join(' ');
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
  // Calls get_blind_spots_sg_selling(p_min_score) RPC (mig 20260520370000).
  // Composite 0-4 score across:
  //   1. listings shrinking >= 5% over 48h
  //   2. price rising       >= 10% over 48h
  //   3. sales accelerating >= 30% (last 24h vs prior 24h)
  //   4. sales clearing at/above current ask
  // Surfaces events scoring >= 2/4 (two independent signals agreeing). Pool:
  // ~2,930 unmatched US SG events polled at 12h cadence (TRACK_BLINDSPOT tier).
  // RPC perf-fixed via matview mig 20260524120000 (was timing out >11s).
  //
  // Replaces the prior heuristic (sg_sales_window >= 5 AND cur_owned_tix == 0
  // pulled from /api/broker/movers) — that surfaced matched events with SG
  // activity but doesn't cover the unmatched-US cohort the new tracker targets.

  const BLIND_SPOT_MIN_SCORE = 2;  // was 3; audit 2026-05-24 found score>=3 ~never reached
  const BLIND_SPOT_MAX_ROWS  = 20;
  // BLIND_SPOT_MIN_SG_SALES removed: the movers panel is now v2 RPC-backed and
  // no longer uses sg_sales_window to highlight rows. The sg_selling blind-spot
  // RPC (renderBlindSpots) provides a dedicated panel for that signal.

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

      // Event cell links to event.html if we have a TEvo bridge, else plain text.
      const eventLabel = r.tevo_event_id
        ? `<a href="event.html?event=${r.tevo_event_id}">${escapeHtml(r.sg_event_name || ('SG ' + r.sg_event_id))}</a>`
        : escapeHtml(r.sg_event_name || ('SG ' + r.sg_event_id));

      // Score cell — hover reveals which signals are lit.
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

  // ---------- Full movers table (mirrors movers.html) ----------

  function wireMoversControls() {
    // Source toggle
    document.querySelectorAll('[data-src]').forEach(btn => {
      btn.addEventListener('click', () => {
        document.querySelectorAll('[data-src]').forEach(b => b.classList.remove('is-active'));
        btn.classList.add('is-active');
        state.source = btn.dataset.src;
        load();
      });
    });
    // Window (days)
    document.querySelectorAll('[data-wdays]').forEach(btn => {
      btn.addEventListener('click', () => {
        document.querySelectorAll('[data-wdays]').forEach(b => b.classList.remove('is-active'));
        btn.classList.add('is-active');
        state.windowDays = parseInt(btn.dataset.wdays, 10);
        load();
      });
    });
    // Segment
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

    // v2 RPC cols available: event_name, occurs_at, cur_price (→ cur_market_med),
    // price_delta_pct (→ delta_market_pct), cur_owned (→ cur_owned_tix), category,
    // rank, signal_score, evo_median, sg_median, td_sh/gt/vd_median, *_spread.
    // Legacy cols not in v2 (cur_market_tix, cur_owned_med, sg_sales_window,
    // delta_owned_pct, delta_market_val, delta_owned_val) are dropped from the
    // header to avoid a table of "—".
    const cols = [
      { key: null,               label: 'Event',      align: 'left' },
      { key: null,               label: 'Category',   align: 'left' },
      { key: null,               label: 'T-days',     align: 'num'  },
      { key: 'cur_owned_tix',    label: 'Owned',      align: 'num'  },
      { key: 'cur_market_med',   label: 'Cur $',      align: 'num'  },
      { key: 'delta_market_pct', label: '%Δ',         align: 'num'  },
      { key: 'signal_score',     label: 'Score',      align: 'num'  },
      { key: 'rank',             label: 'Rank',       align: 'num'  },
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
      const mDPct = r.delta_market_pct != null ? +r.delta_market_pct : NaN;
      const ownedTix = +r.cur_owned_tix || 0;
      const score = r.signal_score != null ? (+r.signal_score).toFixed(2) : '—';
      tr.innerHTML = `
        <td><a href="event.html?event=${r.event_id}" onclick="event.stopPropagation()">${escapeHtml(r.name || r.event_name || ('Event ' + r.event_id))}</a> ${T.temporalChipHtml(r.occurs_at_local || r.occurs_at)}</td>
        <td class="muted small">${escapeHtml((r.category || '—').replace(/_/g, ' '))}</td>
        <td class="num">${d === null ? '—' : d}</td>
        <td class="num ${ownedTix > 0 ? 'ours' : ''}">${T.fmtNum(ownedTix)}</td>
        <td class="num">${r.cur_market_med != null ? '$' + T.fmtNum(Math.round(+r.cur_market_med)) : '—'}</td>
        <td class="num ${pctCls(mDPct)}">${Number.isFinite(mDPct) ? T.fmtPct(mDPct, 1) : '—'}</td>
        <td class="num muted small">${score}</td>
        <td class="num muted small">${r.rank != null ? r.rank : '—'}</td>`;
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

    // v2 RPC: cur_owned_med / delta_owned_val not available.
    // Show qty + cur price (cur_market_med alias) + %Δ + mover chip.
    const tbl = document.createElement('table');
    tbl.innerHTML = `
      <thead><tr>
        <th>Event</th>
        <th class="num">T-days</th>
        <th class="num">Owned qty</th>
        <th class="num">Cur $</th>
        <th class="num">%Δ</th>
        <th class="num">Category</th>
      </tr></thead>
      <tbody></tbody>
    `;
    const tb = tbl.querySelector('tbody');
    upcoming.slice(0, 30).forEach(r => {
      const ot = +r.cur_owned_tix || 0;
      const d  = T.daysUntil(r.occurs_at_local || r.occurs_at);
      const mDPct = r.delta_market_pct != null ? +r.delta_market_pct : NaN;
      const tr = document.createElement('tr');
      tr.innerHTML = `
        <td><a href="event.html?event=${r.event_id}">${escapeHtml(r.name || r.event_name || ('Event ' + r.event_id))}</a></td>
        <td class="num">${d === null ? '—' : d}</td>
        <td class="num ours">${T.fmtNum(ot)}</td>
        <td class="num">${r.cur_market_med != null ? '$' + T.fmtNum(Math.round(+r.cur_market_med)) : '—'}</td>
        <td class="num ${pctCls(mDPct)}">${Number.isFinite(mDPct) ? T.fmtPct(mDPct, 1) : '—'}</td>
        <td class="muted small">${escapeHtml((r.category || '—').replace(/_/g, ' '))}</td>
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

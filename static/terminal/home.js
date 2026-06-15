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
// Top-50 chart fires its own RPC (get_sg_market_chart) — independent.

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
    gapMap: new Map(),        // event_id → [{ gap_type, detail, signal_score }]
    chartTab: 'top',          // 'top' (rank 1-50) | 'rest' (rank 51+)
  };

  async function init() {
    if (window.TerminalAuth) await window.TerminalAuth.requireAuth();
    wireMoversControls();
    // Watchlist is the first table — the user's own tracked events. Independent
    // RPC, runs in parallel with movers/blind-spots.
    loadWatchlist().catch(e => console.error('[watchlist]', e));
    // Top-50 chart fires its own RPC, independent of movers — runs in parallel.
    wireChartTabs();
    renderMarketChart().catch(e => console.error('[sgChart]', e));
    load();
  }

  // ---------- Watchlist (first table; max 50/page, client-paged) ----------
  const WL_PAGE_SIZE = 50;
  let _wlItems = [];
  let _wlPage = 0;
  let _wlBasis = null;   // 'bell' (since today's 12:00 ET open) | '24h' — drives the Δ caption

  async function loadWatchlist() {
    const body = document.getElementById('watchlistBody');
    const Auth = window.TerminalAuth;
    if (!Auth || !Auth.client || !Auth.getAccessToken()) {
      if (body) body.innerHTML = '<div class="empty">not signed in</div>';
      return;
    }
    const res = await Auth.client.rpc('event_watchlist_list');
    if (res.error) {
      // RPC not applied yet → honest empty state, no crash.
      if (/does not exist/i.test(res.error.message || '') || res.error.code === '42883') {
        if (body) body.innerHTML = '<div class="empty">watchlist not enabled yet</div>';
        return;
      }
      console.error('[watchlist] rpc', res.error);
      if (body) body.innerHTML = '<div class="empty">failed to load watchlist</div>';
      return;
    }
    _wlItems = (res.data && res.data.items) || [];
    _wlBasis = (res.data && res.data.basis) || null;
    _wlPage = 0;
    renderWatchlistPage();
  }

  function renderWatchlistPage() {
    const body = document.getElementById('watchlistBody');
    const countEl = document.getElementById('watchlistCount');
    const pager = document.getElementById('watchlistPager');
    if (!body) return;

    // Autohide past events: daysUntil < 0 means the event is more than ~a day
    // in the past (day-of stays visible at 0). Unknown dates (null) are kept.
    const items = _wlItems.filter(it => {
      const d = T.daysUntil(it.occurs_at_local);
      return d === null || d >= 0;
    });
    const hidden = _wlItems.length - items.length;

    if (countEl) {
      const dLbl = _wlBasis === 'bell' ? ' · Δ since opening bell (12:00 ET)'
                 : _wlBasis === '24h'  ? ' · Δ vs 24h ago' : '';
      const hLbl = hidden ? ` · ${hidden} past hidden` : '';
      countEl.textContent = items.length ? `${items.length} events${dLbl}${hLbl}` : '';
    }
    if (!items.length) {
      body.innerHTML = _wlItems.length
        ? '<div class="empty">All tracked events are in the past.</div>'
        : '<div class="empty">No tracked events yet — open an event and tap ★ Track to add it.</div>';
      if (pager) pager.hidden = true;
      return;
    }

    const pages = Math.ceil(items.length / WL_PAGE_SIZE);
    _wlPage = Math.max(0, Math.min(_wlPage, pages - 1));
    const slice = items.slice(_wlPage * WL_PAGE_SIZE, (_wlPage + 1) * WL_PAGE_SIZE);

    const dHint = _wlBasis === 'bell' ? 'since today’s 12:00 ET open' : 'vs 24h ago';
    const tbl = document.createElement('table');
    tbl.innerHTML = `
      <thead><tr>
        <th>Event</th>
        <th class="num">T-days</th>
        <th class="num" title="Cheapest listing — TEvo market">Get-in</th>
        <th class="num" title="Change in get-in ${dHint}">Δ Get-in</th>
        <th class="num" title="Median listing price — TEvo market">Median</th>
        <th class="num" title="90th-percentile price — TEvo market">P90</th>
        <th class="num" title="Tickets available — TEvo market">Tickets</th>
        <th class="num">Alerts</th>
        <th class="num"></th>
      </tr></thead>
      <tbody></tbody>`;
    const tb = tbl.querySelector('tbody');
    const money = v => (v == null ? '—' : '$' + T.fmtNum(Math.round(+v)));
    slice.forEach(it => {
      const d = T.daysUntil(it.occurs_at_local);
      const m = it.metrics || null;
      const venueLine = [it.venue_name || it.venue_location, it.performer].filter(Boolean).join(' · ');
      // Headline Δ on the get-in (resale floor). pos/neg class on the <td> (matches
      // the table td.pos/.neg rule); abs $ + %; flat/no-baseline → muted dash.
      let dCls = '', dInner = '<span class="muted">—</span>';
      if (m && m.d_getin != null) {
        dCls = pctCls(+m.d_getin);
        const pct = (m.d_getin_pct != null) ? ` <span class="small">(${T.fmtPct(+m.d_getin_pct, 1)})</span>` : '';
        dInner = `${fmtDelta(+m.d_getin)}${pct}`;
      }
      // EVO/TEvo events deep-link to the event page; SeatGeek-native events
      // (e.g. World Cup) have no TEvo page, so render the title as plain text
      // with an "SG" badge. Row actions key on whichever id the row carries.
      const isSg = it.tevo_event_id == null;
      const title = escapeHtml(it.event_name || (isSg ? ('SG ' + it.sg_event_id) : ('Event ' + it.tevo_event_id)));
      // SG-native rows (e.g. World Cup) open the event page in SeatGeek mode (?sg=).
      const titleHtml = isSg
        ? `<a href="event.html?sg=${it.sg_event_id}">${title}</a> <span class="src-badge sg" title="SeatGeek-native (FIFA primary)">SG</span>`
        : `<a href="event.html?event=${it.tevo_event_id}">${title}</a>`;
      const dataAttrs = `data-tevo="${it.tevo_event_id ?? ''}" data-sg="${it.sg_event_id ?? ''}"`;
      const tr = document.createElement('tr');
      tr.innerHTML = `
        <td>${titleHtml}
            ${venueLine ? `<div class="muted small">${escapeHtml(venueLine)}</div>` : ''}</td>
        <td class="num">${d === null ? '—' : d}</td>
        <td class="num">${money(m && m.getin)}</td>
        <td class="num ${dCls}" title="${escapeHtml(dHint)}">${dInner}</td>
        <td class="num">${money(m && m.median)}</td>
        <td class="num">${money(m && m.p90)}</td>
        <td class="num">${m && m.tickets != null ? T.fmtNum(m.tickets) : '—'}</td>
        <td class="num">
          <button class="wl-alert-btn ${it.alert_enabled ? 'on' : 'off'}" ${dataAttrs}
                  title="${it.alert_enabled ? 'Alerts on — click to mute' : 'Alerts muted — click to enable'}">
            ${it.alert_enabled ? '🔔' : '🔕'}</button>
        </td>
        <td class="num"><button class="wl-remove-btn" ${dataAttrs} title="Remove from watchlist">✕</button></td>`;
      tb.appendChild(tr);
    });
    body.innerHTML = '';
    body.appendChild(tbl);
    wireWatchlistRowActions(body);
    renderWatchlistPager(pages);
  }

  function renderWatchlistPager(pages) {
    const pager = document.getElementById('watchlistPager');
    if (!pager) return;
    if (pages <= 1) { pager.hidden = true; pager.innerHTML = ''; return; }
    pager.hidden = false;
    pager.innerHTML =
      `<button class="wl-page-btn" data-dir="-1" ${_wlPage === 0 ? 'disabled' : ''}>‹ Prev</button>` +
      `<span class="muted small">Page ${_wlPage + 1} of ${pages} · showing ${WL_PAGE_SIZE}/page</span>` +
      `<button class="wl-page-btn" data-dir="1" ${_wlPage >= pages - 1 ? 'disabled' : ''}>Next ›</button>`;
    pager.querySelectorAll('.wl-page-btn').forEach(b =>
      b.addEventListener('click', () => { _wlPage += parseInt(b.getAttribute('data-dir'), 10); renderWatchlistPage(); }));
  }

  function wireWatchlistRowActions(scope) {
    const Auth = window.TerminalAuth;
    // A row is keyed by its TEvo id (EVO primary) when present, else its
    // SeatGeek id (secondary) — pick the matching RPC variant per row.
    const rowKey = b => {
      const tevo = b.getAttribute('data-tevo');
      const sg = b.getAttribute('data-sg');
      return tevo ? { isSg: false, id: parseInt(tevo, 10) } : { isSg: true, id: parseInt(sg, 10) };
    };
    const matches = (x, k) => k.isSg ? x.sg_event_id === k.id : x.tevo_event_id === k.id;
    scope.querySelectorAll('.wl-remove-btn').forEach(b =>
      b.addEventListener('click', async () => {
        const k = rowKey(b);
        b.disabled = true;
        const res = k.isSg
          ? await Auth.client.rpc('event_watchlist_set_sg', { p_sg_event_id: k.id, p_on: false })
          : await Auth.client.rpc('event_watchlist_set',    { p_event_id: k.id,    p_on: false });
        if (res.error) { b.disabled = false; console.error('[watchlist] remove', res.error); return; }
        _wlItems = _wlItems.filter(x => !matches(x, k));
        renderWatchlistPage();
      }));
    scope.querySelectorAll('.wl-alert-btn').forEach(b =>
      b.addEventListener('click', async () => {
        const k = rowKey(b);
        const item = _wlItems.find(x => matches(x, k));
        if (!item) return;
        const next = !item.alert_enabled;
        b.disabled = true;
        const res = k.isSg
          ? await Auth.client.rpc('event_watchlist_set_alert_sg', { p_sg_event_id: k.id, p_on: next })
          : await Auth.client.rpc('event_watchlist_set_alert',    { p_event_id: k.id,    p_on: next });
        b.disabled = false;
        if (res.error) { console.error('[watchlist] alert', res.error); return; }
        item.alert_enabled = next;
        renderWatchlistPage();
      }));
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
      state.gapMap = new Map();   // reset on each load

      T.setStatus('Loaded', 'ok');
      renderSummaryStrip(summary);
      renderCoverage(state.rows);
      renderMovers();
      renderOwnedEvents(state.rows);
      // Phase 2: batch-load gap alerts for all mover event_ids, then re-render
      // so GapChips appear in the table without blocking the initial paint.
      loadGapMap(state.rows).catch(e => console.error('[gapMap]', e));
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
      return `<span class="badge" title="source=${escapeHtml(s.source)} window=${s.window_days}d">${escapeHtml(s.source)}·${s.window_days}d·${escapeHtml(s.category || '')}: ${sz}${cov}${turnStr}</span>`;
    }).join(' ');
  }

  // ---------- Phase 2: GapChip batch loader ----------
  // discovery_gap_alerts has no RLS (relrowsecurity=false) — direct read OK.
  // Queries all active gaps for the current mover rows in one round-trip, then
  // re-renders the movers table so gap badges appear in event name cells.

  async function loadGapMap(rows) {
    if (!rows || !rows.length) return;
    const Auth = window.TerminalAuth;
    if (!Auth || !Auth.client) return;
    const ids = [...new Set(rows.map(r => r.event_id).filter(Boolean))];
    if (!ids.length) return;
    const { data, error } = await Auth.client
      .from('discovery_gap_alerts')
      .select('event_id,gap_type,detail,signal_score')
      .in('event_id', ids)
      .is('resolved_at', null)
      .order('signal_score', { ascending: false });
    if (error || !data) return;
    const m = new Map();
    data.forEach(g => {
      if (!m.has(g.event_id)) m.set(g.event_id, []);
      m.get(g.event_id).push(g);
    });
    state.gapMap = m;
    renderMovers();  // re-render now that gap badges are available
  }

  // Returns HTML for up to 2 gap chips for an event (compact — avoid badge overflow).
  function gapBadgesHtml(eventId) {
    const gaps = state.gapMap.get(eventId);
    if (!gaps || !gaps.length) return '';
    return gaps.slice(0, 2).map(g =>
      `<span class="badge gap-chip" title="${escapeHtml(g.detail || '')}">${escapeHtml((g.gap_type || '').replace(/_/g, ' '))}</span>`
    ).join(' ');
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

  // ---------- TOP 50 — SG SELLING, WE'RE NOT IN ----------
  //
  // Billboard-style daily chart of SG market events we hold ZERO owned
  // inventory in, ranked by sales ACTIVITY. Calls get_sg_market_chart(offset,
  // limit) RPC (mig 20260606120000), which reads the daily-rebuilt
  // sg_market_chart table.
  //
  //   chart_score = percent_rank(7d-MA daily volume)
  //               + percent_rank(7d-MA sales median)        (0..2)
  //
  // High on EITHER axis charts; high on BOTH tops it. Eligibility:
  // owned_count_last_7d = 0, future event, >= 2 days of sales in trailing 7d.
  // Each row carries prev_rank / peak_rank / days_on_chart for movement.
  // Two tabs: "Top 50" (rank 1-50) and "The Rest" (rank 51+, capped server-side).

  const CHART_PAGE = 50;        // tab 1 size = top 50
  const CHART_REST_LIMIT = 200; // tab 2: ranks 51..250

  function wireChartTabs() {
    document.querySelectorAll('[data-chart-tab]').forEach(btn => {
      btn.addEventListener('click', () => {
        if (btn.classList.contains('is-active')) return;
        document.querySelectorAll('[data-chart-tab]').forEach(b => b.classList.remove('is-active'));
        btn.classList.add('is-active');
        state.chartTab = btn.dataset.chartTab;
        renderMarketChart().catch(e => console.error('[sgChart]', e));
      });
    });
  }

  // Movement glyph from rank_delta (prev_rank - rank): + = climbed.
  function movementCell(r) {
    if (r.is_new) return '<span class="chart-move new" title="new entry">NEW</span>';
    const d = r.rank_delta;
    if (d == null) return '<span class="chart-move flat">—</span>';
    if (d > 0)  return `<span class="chart-move up"   title="up ${d} from #${r.prev_rank}">▲ ${d}</span>`;
    if (d < 0)  return `<span class="chart-move down" title="down ${-d} from #${r.prev_rank}">▼ ${-d}</span>`;
    return '<span class="chart-move flat" title="no change">=</span>';
  }

  async function renderMarketChart() {
    const body = document.getElementById('sgChartBody');
    const metaEl = document.getElementById('sgChartMeta');
    if (!body) return;

    const Auth = window.TerminalAuth;
    if (!Auth || !Auth.client || !Auth.getAccessToken()) {
      body.innerHTML = '<div class="empty">not signed in</div>';
      return;
    }

    body.innerHTML = '<div class="empty">loading…</div>';

    const isRest = state.chartTab === 'rest';
    const args = isRest
      ? { p_offset: CHART_PAGE, p_limit: CHART_REST_LIMIT }
      : { p_offset: 0,          p_limit: CHART_PAGE };

    let payload;
    try {
      const res = await Auth.client.rpc('get_sg_market_chart', args);
      if (res.error) throw new Error(res.error.message || 'RPC error');
      payload = res.data || {};
    } catch (e) {
      body.innerHTML = '<div class="empty">error: ' + escapeHtml(e.message) + '</div>';
      if (metaEl) metaEl.textContent = '';
      return;
    }

    const rows = payload.rows || [];
    const total = payload.total || 0;
    const charted = payload.chart_date ? ` · ${escapeHtml(payload.chart_date)}` : '';
    if (metaEl) {
      metaEl.textContent = total
        ? (isRest ? `ranks 51–${Math.min(total, CHART_PAGE + rows.length)} of ${total}${charted}`
                  : `${total} non-owned events charting${charted}`)
        : '';
    }

    if (!rows.length) {
      body.innerHTML = isRest
        ? '<div class="empty">no events beyond the top 50</div>'
        : '<div class="empty">chart not built yet (rebuilds daily @ 11:05 UTC)</div>';
      return;
    }

    const tbl = document.createElement('table');
    tbl.className = 'blind-spots-tbl chart-tbl';
    tbl.innerHTML = `
      <thead><tr>
        <th class="num">#</th>
        <th title="Movement vs yesterday's chart">+/-</th>
        <th>Event</th><th>Venue</th>
        <th class="num">T-days</th>
        <th class="num" title="Blended 7-day MA daily sales: SeatGeek + SeatData (treats unknown SeatData qty as 1)">Vol/day</th>
        <th class="num" title="Volume-weighted blended 7-day MA median price across SeatGeek + SeatData">Med px</th>
        <th class="num" title="Blended 7-day MA daily gross: SeatGeek + SeatData sold comps">GMV/day</th>
        <th class="num" title="Chart score = percentile(volume) + percentile(median), 0–2. Blended percentiles when SeatData present, else SeatGeek-only.">Score</th>
        <th class="num" title="Best rank achieved · days on chart">Peak·On</th>
      </tr></thead>
      <tbody></tbody>`;
    const tb = tbl.querySelector('tbody');

    rows.forEach(r => {
      const d = T.daysUntil(r.sg_datetime_utc);
      const tr = document.createElement('tr');

      const eventLabel = r.tevo_event_id
        ? `<a href="event.html?event=${r.tevo_event_id}">${escapeHtml(r.sg_event_name || ('SG ' + r.sg_event_id))}</a>`
        : escapeHtml(r.sg_event_name || ('SG ' + r.sg_event_id));

      const money = v => (v == null ? '—' : '$' + T.fmtNum(Math.round(+v)));
      const hasSd = (r.score_basis === 'blended');
      const effScore = hasSd ? r.blended_score : r.chart_score;
      const score = (effScore == null) ? '—' : (+effScore).toFixed(2);
      // tooltip breakdowns: SG raw vs SD raw (the single columns show the blend)
      const volTip   = `SG ${r.ma7_volume == null ? '—' : T.fmtNum(Math.round(+r.ma7_volume))}` +
                       ` · SD ${r.sd_ma7_volume == null ? '—' : T.fmtNum(Math.round(+r.sd_ma7_volume))}`;
      const medTip   = `SG ${money(r.ma7_median)} · SD ${money(r.sd_ma7_median)}`;
      const grossTip = `SG ${money(r.ma7_gross)} · SD ${money(r.sd_ma7_gross)}` +
                       (r.sd_sales_7d == null ? ' (no SeatData sales yet)' : ` · ${r.sd_sales_7d} SD rows/7d`);
      const scoreTip = hasSd
        ? `blended ${(r.blended_score == null ? '—' : (+r.blended_score).toFixed(2))} · SG-only ${(r.chart_score == null ? '—' : (+r.chart_score).toFixed(2))}`
        : `SG-only ${(r.chart_score == null ? '—' : (+r.chart_score).toFixed(2))} (no SeatData)`;
      const peakOn = `${r.peak_rank ?? '—'}·${r.days_on_chart ?? '—'}`;

      tr.innerHTML = `
        <td class="num chart-rank">${r.rank}</td>
        <td>${movementCell(r)}</td>
        <td>${eventLabel}</td>
        <td>${escapeHtml(r.sg_venue_name || '—')}</td>
        <td class="num">${d === null ? '—' : d}</td>
        <td class="num" title="${volTip}">${r.ma7_volume_blended == null ? '—' : T.fmtNum(Math.round(+r.ma7_volume_blended))}</td>
        <td class="num" title="${medTip}">${money(r.ma7_median_blended)}</td>
        <td class="num" title="${grossTip}">${money(r.ma7_gross_blended)}</td>
        <td class="num" title="${scoreTip}"><strong>${score}</strong>${hasSd ? '' : '<sup title="SeatGeek-only basis">sg</sup>'}</td>
        <td class="num" title="peak rank · consecutive days on chart">${peakOn}</td>`;
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
        <td><a href="event.html?event=${r.event_id}" onclick="event.stopPropagation()">${escapeHtml(r.name || r.event_name || ('Event ' + r.event_id))}</a> ${T.temporalChipHtml(r.occurs_at_local || r.occurs_at)} ${gapBadgesHtml(r.event_id)}</td>
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

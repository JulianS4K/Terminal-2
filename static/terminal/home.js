// D0 Terminal — Home page.
//
// Three panels (operator directive 2026-06-17 — Movers + S4K-owned panels removed):
//   • My watchlist — the user's own tracked events (event_watchlist_list RPC).
//   • Coverage band — active-future-sports counts, derived from the cross-source
//     mover index (get_event_movers_v2) which still drives the at-a-glance totals.
//   • Top-50 chart — "SG SELLING, WE'RE NOT IN" (get_sg_market_chart RPC).
//
// The full Movers cross-source table now lives only on its dedicated page
// (movers.html); the home page keeps just the coverage roll-up it feeds.

(function () {
  'use strict';
  const T = window.Terminal;

  const state = {
    // Coverage band reads the merged 7d mover index — the same default the
    // dedicated Movers page opens with.
    source: 'merged',
    windowDays: 7,
    chartTab: 'top',          // 'top' (rank 1-50) | 'rest' (rank 51+)
  };

  async function init() {
    if (window.TerminalAuth) await window.TerminalAuth.requireAuth();
    // Watchlist is the first table — the user's own tracked events. Independent
    // RPC, runs in parallel with the coverage roll-up / chart.
    loadWatchlist().catch(e => console.error('[watchlist]', e));
    // Top-50 chart fires its own RPC — runs in parallel.
    wireChartTabs();
    renderMarketChart().catch(e => console.error('[sgChart]', e));
    // Coverage band counts (active future sports) from the mover index.
    loadCoverage().catch(e => console.error('[coverage]', e));
  }

  // ---------- Watchlist (first table; max 25/page, client-paged) ----------
  const WL_PAGE_SIZE = 25;
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

  // ---------- Coverage band ----------
  // Counts active future events from the merged 7d mover index — the at-a-glance
  // roll-up that headed the (now-removed) Movers panel.

  async function loadCoverage() {
    const Auth = window.TerminalAuth;
    if (!Auth || !Auth.client || !Auth.getAccessToken()) return;
    const res = await Auth.client.rpc('get_event_movers_v2', {
      p_source:      state.source,
      p_window_days: state.windowDays,
      p_category:    null,
      p_limit:       200,
    });
    if (res.error) { console.error('[coverage] rpc', res.error); return; }
    renderCoverage(res.data || []);
  }

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
  // SG owned_count_last_7d = 0 AND EVO owned_tickets_count = 0 (operator
  // directive 2026-06-17 — exclude events where EVO holds owned tickets),
  // future event, >= 2 days of sales in trailing 7d.
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

  // ---------- Util ----------

  function pctCls(v) {
    if (!Number.isFinite(v)) return '';
    return v > 0 ? 'pos' : v < 0 ? 'neg' : '';
  }
  function fmtDelta(v) {
    if (!Number.isFinite(v)) return '—';
    return (v >= 0 ? '+' : '−') + '$' + T.fmtNum(Math.round(Math.abs(v)));
  }

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

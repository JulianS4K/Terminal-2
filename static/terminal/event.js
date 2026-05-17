// D0 Terminal — Event Detail page · Phase 2a.
// ONE call to supabase.rpc('get_broker_event_page_v2', {p_event_id, p_chart_hours}).
// v2 extends v1 with 7 payload keys + bridge_ids:
//   sales_tape / weather / espn / event_alerts / sg_side_by_side / splits / freshness
// Path A fallback (legacy /api/broker/*) kept for localhost AUTH_DISABLED dev only;
// the fallback fills v1 keys but the v2 panels render their empty/hidden states.
// Migration 20260516050000 — PR #150. Contract: PROJECT_BIBLE.md §3 + §7.

(function () {
  'use strict';

  const T = window.Terminal;
  const DEFAULT_HOURS = 168;
  let CHART_HOURS = DEFAULT_HOURS;
  let _chartInstance = null;
  let _lastPayload = null;

  async function init() {
    if (window.TerminalAuth) await window.TerminalAuth.requireAuth();
    const eventId = T.getEventId();
    if (!eventId) {
      T.setStatus('No event id — pass ?event=<id>', 'err');
      return;
    }
    const Auth = window.TerminalAuth;
    if (Auth && !isLocalhost() && !Auth.isAllowedEmail(Auth.getEmail())) {
      T.setStatus(`Not signed in with @s4kent.com — sign in first`, 'err');
      return;
    }

    wireRangeSelector(eventId);
    await loadAndRender(eventId);
  }

  function isLocalhost() {
    const h = location.hostname;
    return h === 'localhost' || h === '127.0.0.1' || h === '';
  }

  async function loadAndRender(eventId) {
    T.setStatus(`Loading event ${eventId}…`);
    try {
      const data = await fetchPayload(eventId);
      _lastPayload = data;
      T.setStatus(`Loaded event ${eventId}`, 'ok');

      const bridge = data.bridge_ids || {};
      const overview = adaptOverview(data.overview);
      const chart    = adaptChart(data.chart_data);
      const zones    = data.zones || {};
      const orders   = adaptOrders(data.orders, eventId);
      const cadences = adaptCadences(data.cadences);

      safe('hero',       () => renderHero(overview, bridge));
      safe('eventMode',  () => renderEventMode(bridge, data));
      safe('kpiGrid',    () => renderKPIGrid(chart, data.sg_side_by_side));
      safe('chart',      () => renderChart(chart, data.event_alerts));
      safe('chartLegend',() => renderChartLegend());
      safe('splits',     () => renderSplits(data.splits));
      safe('zones',      () => renderZones(zones));
      safe('salesTape',  () => renderSalesTape(data.sales_tape, bridge));
      safe('espn',       () => renderEspn(data.espn));
      safe('weather',    () => renderWeather(data.weather));
      safe('orders',     () => renderOrders(orders));
      safe('coverage',   () => renderCoverage(cadences, overview, data.freshness, bridge));
      safe('freshness',  () => renderFreshness(data.freshness));
      safe('alerts',     () => renderAlerts(data.event_alerts));
    } catch (e) {
      handleRpcError(e);
    }
  }

  function safe(label, fn) {
    try { fn(); } catch (e) { console.error('[' + label + ']', e); }
  }

  function wireRangeSelector(eventId) {
    const sel = document.getElementById('chartRange');
    if (!sel) return;
    sel.addEventListener('change', async () => {
      CHART_HOURS = parseInt(sel.value, 10) || DEFAULT_HOURS;
      const lbl = document.getElementById('chartRangeLabel');
      if (lbl) lbl.textContent = sel.options[sel.selectedIndex].textContent;
      const aw = document.getElementById('alertsWindow');
      if (aw) aw.textContent = sel.options[sel.selectedIndex].textContent;
      await loadAndRender(eventId);
    });
  }

  // ---------- Fetch (Path C primary, Path A fallback) ----------

  async function fetchPayload(eventId) {
    const Auth = window.TerminalAuth;
    if (Auth && Auth.client && Auth.getAccessToken()) {
      const { data, error } = await Auth.client
        .rpc('get_broker_event_page_v2', { p_event_id: eventId, p_chart_hours: CHART_HOURS });
      if (error) {
        const err = new Error(error.message || 'RPC error');
        err.code = error.code; err.details = error.details; err.hint = error.hint;
        throw err;
      }
      return data;
    }
    // Path A fallback (localhost dev only). Returns v1 shape; v2 panels render empty states.
    const idStr = String(eventId);
    const [overview, chartData, zones, orders, cadences] = await Promise.all([
      T.api(`/api/broker/event/${idStr}/overview`),
      T.api(`/api/broker/event/${idStr}/chart-data?hours=${CHART_HOURS}`),
      T.api(`/api/broker/event/${idStr}/zones`),
      T.api(`/api/broker/event/${idStr}/orders`),
      T.api(`/api/broker/event/${idStr}/cadences`),
    ]);
    return legacyToV2Shape(overview, chartData, zones, orders, cadences, eventId);
  }

  function handleRpcError(e) {
    if (e && e.code === '42501') {
      T.setStatus('Access denied — JWT email is not @s4kent.com', 'err');
    } else if (e && e.code === 'P0002') {
      T.setStatus(`Event not found in broker data`, 'err');
    } else if (e && e.code === 'PGRST301') {
      T.setStatus('Unauthorized — sign in again', 'err');
    } else {
      T.setStatus((e && e.message) || 'Failed to load event', 'err');
    }
    console.error(e);
  }

  // ---------- Shape adapters (v1 base) ----------

  function adaptOverview(o) {
    if (!o) return { event: {}, lifecycle: null };
    return {
      event: o.event || {},
      lifecycle: o.lifecycle || null,
      cadence_seconds: o.cadence_seconds || null,
      last_pull_at: o.last_pull_at || null,
    };
  }

  function adaptChart(c) {
    if (!c) return { prices_owned: [], prices_market: [], prices_nonowned: [], counts_owned: [], counts_market: [] };
    const rows = c.event_metrics_series || [];
    const slice = (col) => rows.map(r => ({ t: r.captured_at, v: r[col] == null ? null : Number(r[col]) }));
    return {
      prices_owned:    slice('owned_median_retail'),
      prices_market:   slice('retail_median'),
      prices_nonowned: slice('nonowned_median_retail'),
      counts_owned:    slice('owned_tickets_count'),
      counts_market:   slice('tickets_count'),
      range: c.range || null,
    };
  }

  function adaptOrders(o, eventId) {
    if (!o) return { event_id: eventId, items: [], orders: [], summary: null };
    const items = o.items || [];
    const orders = o.orders || [];
    if (!items.length) return { event_id: eventId, items, orders, summary: null };
    const stateById = new Map(orders.map(x => [x.evo_order_id, x.state || 'unknown']));
    const byState = {}; let ticketsSold = 0, grossSold = 0; let lastUpdate = null;
    items.forEach(it => {
      const st = stateById.get(it.evo_order_id) || 'unknown';
      byState[st] = (byState[st] || 0) + 1;
      if ((st === 'accepted' || st === 'completed') && it.quantity && it.price) {
        ticketsSold += Number(it.quantity);
        grossSold += Number(it.price) * Number(it.quantity);
      }
    });
    orders.forEach(o => {
      if (o.evo_updated_at && (!lastUpdate || o.evo_updated_at > lastUpdate)) lastUpdate = o.evo_updated_at;
    });
    return {
      event_id: eventId, items, orders,
      summary: {
        total_items: items.length, by_state: byState,
        tickets_sold: ticketsSold, gross_sold: Math.round(grossSold * 100) / 100,
        last_update_at: lastUpdate,
      },
    };
  }

  function adaptCadences(c) {
    if (!c) return { sections: {} };
    return { sections: c };
  }

  function legacyToV2Shape(overview, chartData, zones, orders, cadences, eventId) {
    return {
      v: 'v1-fallback',
      bridge_ids: { tevo_event_id: eventId, sg_event_id: null, espn_event_id: null,
                    aq_short_event_id: null, espn_league: null, venue_tevo_id: null },
      overview: overview ? {
        event: overview.event, lifecycle: overview.lifecycle,
        cadence_seconds: overview.cadence_seconds, last_pull_at: overview.last_pull_at,
      } : null,
      chart_data: chartData ? { event_metrics_series: buildSeriesFromLegacy(chartData) } : null,
      zones: zones || null,
      orders: orders || null,
      cadences: cadences && cadences.sections ? cadences.sections : (cadences || {}),
      sales_tape: [],
      weather:    { hidden: true, reason: 'path_a_fallback' },
      espn:       { hidden: true, reason: 'path_a_fallback' },
      event_alerts:    [],
      sg_side_by_side: { hidden: true, reason: 'path_a_fallback' },
      splits:     { owned: {}, market: {} },
      freshness:  {},
    };
  }

  function buildSeriesFromLegacy(c) {
    const byT = new Map();
    const pull = (series, col) => (series || []).forEach(p => {
      let row = byT.get(p.t);
      if (!row) { row = { captured_at: p.t }; byT.set(p.t, row); }
      row[col] = p.v;
    });
    pull(c.prices_owned,    'owned_median_retail');
    pull(c.prices_market,   'retail_median');
    pull(c.prices_nonowned, 'nonowned_median_retail');
    pull(c.counts_owned,    'owned_tickets_count');
    pull(c.counts_market,   'tickets_count');
    return Array.from(byT.values()).sort((a, b) => a.captured_at.localeCompare(b.captured_at));
  }

  // ---------- Hero ----------

  function renderHero(overview, bridge) {
    if (!overview) return;
    const ev = overview.event || {};
    document.getElementById('evTitle').textContent = ev.name || `Event ${ev.id || ''}`;
    document.getElementById('evVenue').textContent = ev.venue_name || ev.venue || '—';
    document.getElementById('evDate').textContent  = T.fmtDate(ev.occurs_at_local || ev.occurs_at);

    const badges = document.getElementById('evBadges');
    badges.innerHTML = '';

    const days = T.daysUntil(ev.occurs_at_local || ev.occurs_at);
    if (days !== null) {
      const b = document.createElement('span');
      b.className = 'badge countdown';
      b.textContent = days <= 0 ? 'TODAY' : days === 1 ? 'TOMORROW' : `T-${days}d`;
      badges.appendChild(b);
    }
    const lc = overview.lifecycle;
    if (lc) {
      const status = lc.status || lc.classification;
      if (status) {
        const b = document.createElement('span');
        const cls = (/active|live|on_sale/i.test(status)) ? 'lifecycle-active'
                  : (/ghost|postponed|cancelled/i.test(status)) ? 'lifecycle-ghost'
                  : (/complete|past/i.test(status)) ? 'lifecycle-complete'
                  : '';
        b.className = 'badge ' + cls;
        b.textContent = String(status).toUpperCase();
        badges.appendChild(b);
      }
    }
    if (overview.cadence_seconds) {
      const b = document.createElement('span');
      b.className = 'badge';
      b.textContent = `POLL ${Math.round(overview.cadence_seconds / 60)}m`;
      badges.appendChild(b);
    }
    if (bridge && bridge.espn_league) {
      const b = document.createElement('span');
      b.className = 'badge';
      b.textContent = String(bridge.espn_league).toUpperCase();
      badges.appendChild(b);
    }
  }

  function renderEventMode(bridge, data) {
    const el = document.getElementById('eventMode');
    if (!el) return;
    el.innerHTML = '';
    if (!bridge) return;
    if (bridge.sg_event_id == null) {
      el.innerHTML = '<span class="mode-chip warn">TEvo-only · no SG bridge</span>';
    } else if (data && data.v === 'v1-fallback') {
      el.innerHTML = '<span class="mode-chip dim">v1 fallback (localhost)</span>';
    }
  }

  // ---------- KPI grid (8 cells, TEvo + SG side-by-side where applicable) ----------

  function renderKPIGrid(chart, sgSxs) {
    // Owned Premium %
    const owned    = T.latestNonNull(chart.prices_owned);
    const nonowned = T.latestNonNull(chart.prices_nonowned);
    const market   = T.latestNonNull(chart.prices_market);
    const qtyMkt   = T.latestNonNull(chart.counts_market);
    const qtyOwn   = T.latestNonNull(chart.counts_owned);

    const opVal = document.getElementById('kpiOwnedPremiumVal');
    const opSub = document.getElementById('kpiOwnedPremiumSub');
    if (owned && nonowned) {
      const pct = (owned / nonowned - 1) * 100;
      opVal.textContent = T.fmtPct(pct, 1);
      opVal.className = 'kpi-val ' + colorBucket(pct);
      opSub.textContent = `our $${T.fmtNum(owned, { max: 0 })} vs $${T.fmtNum(nonowned, { max: 0 })}`;
    } else {
      opVal.textContent = 'n/a';
      opSub.textContent = !nonowned ? 'no market without us' : 'no owned median';
    }

    // SG side-by-side: pull current snapshot (cost_* columns)
    const sg = (sgSxs && !sgSxs.hidden && sgSxs.current) ? sgSxs.current : null;
    const sgPrev = (sgSxs && !sgSxs.hidden && sgSxs.d24h_ago) ? sgSxs.d24h_ago : null;
    const sgHidden = !sgSxs || sgSxs.hidden;

    // Retail Median  (TEvo retail_median + SG cost_median)
    setKpi('kpiRetailMedianVal', market != null ? '$' + T.fmtNum(market, { max: 0 }) : '—');
    setKpiSg('kpiRetailMedianSG', sg && sg.cost_median, sgPrev && sgPrev.cost_median, '$', 0, sgHidden);

    // Qty Available  (TEvo counts_market + SG listings_count)
    setKpi('kpiQtyAvailableVal', qtyMkt != null ? T.fmtNum(qtyMkt) : '—');
    setKpiSg('kpiQtyAvailableSG', sg && sg.tickets_count, sgPrev && sgPrev.tickets_count, '', 0, sgHidden);

    // Qty Owned  (counts_owned + share)
    setKpi('kpiQtyOwnedVal', qtyOwn != null ? T.fmtNum(qtyOwn) : '—');
    const share = (qtyOwn && qtyMkt && qtyMkt > 0) ? (qtyOwn / qtyMkt * 100) : null;
    setKpiSub('kpiQtyOwnedSub', share != null ? `${share.toFixed(1)}% of market` : '');

    // Get-in (cheapest available ticket): prefer SG cost_min, fall back to TEvo
    // splits.market.singles.min_px (smallest 1-tix market lot). Keeps the cell
    // populated for TEvo-only events instead of "—".
    let getinVal = sg && sg.cost_min != null ? sg.cost_min : null;
    let getinSrc = sg && sg.cost_min != null ? 'SG' : null;
    if (getinVal == null && _lastPayload && _lastPayload.splits) {
      const marketSingles = _lastPayload.splits.market && _lastPayload.splits.market.singles;
      if (marketSingles && marketSingles.min_px != null) {
        getinVal = marketSingles.min_px;
        getinSrc = 'TEvo';
      }
    }
    setKpi('kpiGetinVal', getinVal != null ? '$' + T.fmtNum(getinVal, { max: 0 }) : '—');
    const getinSub = document.getElementById('kpiGetinSG');
    if (getinSub) {
      getinSub.textContent = getinSrc ? getinSrc.toLowerCase() === 'sg' ? '' : 'src: TEvo singles' : '';
      getinSub.className = 'kpi-sg';
    }

    // Owned Median (our retail)
    setKpi('kpiOwnedMedianVal', owned != null ? '$' + T.fmtNum(owned, { max: 0 }) : '—');

    // Non-owned Median
    setKpi('kpiNonownedMedianVal', nonowned != null ? '$' + T.fmtNum(nonowned, { max: 0 }) : '—');

    // Owned Share (qty %)
    document.getElementById('kpiOwnedShareVal').textContent = share != null ? share.toFixed(1) + '%' : '—';
    document.getElementById('kpiOwnedShareSub').textContent = (qtyOwn != null && qtyMkt != null)
      ? `${T.fmtNum(qtyOwn)} of ${T.fmtNum(qtyMkt)}` : '';
  }

  function setKpi(id, value) {
    const el = document.getElementById(id); if (!el) return;
    el.textContent = value;
  }
  function setKpiSub(id, value) {
    const el = document.getElementById(id); if (!el) return;
    el.textContent = value;
  }
  function setKpiSg(id, val, prevVal, prefix, max, hidden) {
    const el = document.getElementById(id); if (!el) return;
    if (hidden || val == null) { el.textContent = ''; el.className = 'kpi-sg'; return; }
    const v = `${prefix}${T.fmtNum(val, { max })}`;
    let delta = '';
    if (prevVal != null && prevVal !== 0) {
      const pct = (val / prevVal - 1) * 100;
      delta = ` (${pct >= 0 ? '+' : ''}${pct.toFixed(1)}%)`;
      el.className = 'kpi-sg ' + (pct >= 0 ? 'pos' : 'neg');
    } else {
      el.className = 'kpi-sg';
    }
    el.textContent = `SG ${v}${delta}`;
  }

  function colorBucket(pct) {
    const a = Math.abs(pct);
    if (a <= 15) return 'pos';
    if (a <= 30) return 'warn';
    return 'neg';
  }

  // ---------- Chart (8 series + event_alerts markers) ----------

  function renderChart(chart, alerts) {
    const host = document.getElementById('chartHost');
    host.innerHTML = '';
    if (!chart || !window.uPlot) return;

    const seriesSpecs = [
      { key: 'prices_owned',    label: 'Owned median',    color: '#fbbf24', scale: 'y',   width: 2,   dash: null },
      { key: 'prices_market',   label: 'Market median',   color: '#737373', scale: 'y',   width: 1.5, dash: [4, 4] },
      { key: 'prices_nonowned', label: 'Non-owned median',color: '#a78bfa', scale: 'y',   width: 1.5, dash: [6, 3] },
      { key: 'counts_owned',    label: 'Owned qty',       color: '#60a5fa', scale: 'qty', width: 1,   dash: null, fill: 'rgba(96,165,250,0.08)' },
      { key: 'counts_market',   label: 'Market qty',      color: '#94a3b8', scale: 'qty', width: 1,   dash: [2, 2] },
    ];

    // Build unified time axis
    const tset = new Set();
    seriesSpecs.forEach(s => (chart[s.key] || []).forEach(p => tset.add(p.t)));
    const ts = [...tset].sort();
    const xs = ts.map(t => Math.round(new Date(t).getTime() / 1000));
    const idx = new Map(ts.map((t, i) => [t, i]));
    const project = (s) => {
      const arr = new Array(ts.length).fill(null);
      (s || []).forEach(p => { const i = idx.get(p.t); if (i != null) arr[i] = p.v; });
      return arr;
    };

    const data = [xs, ...seriesSpecs.map(s => project(chart[s.key]))];

    // Pick a tick-friendly width (re-render on resize)
    const rect = host.getBoundingClientRect();
    const w = Math.max(800, rect.width || host.clientWidth || 1200);
    const h = Math.max(280, (rect.height || 320) - 20);

    const opts = {
      width: w, height: h,
      cursor: { drag: { x: true, y: false } },
      scales: { x: { time: true }, y: {}, qty: {} },
      axes: [
        { stroke: 'var(--muted)', grid: { stroke: 'var(--line-2)', width: 1 } },
        { scale: 'y',   stroke: 'var(--muted)', grid: { stroke: 'var(--line-2)', width: 1 },
          values: (u, v) => v.map(x => x === null ? '' : '$' + Math.round(x)) },
        { scale: 'qty', side: 1, stroke: 'var(--muted)', grid: { show: false },
          values: (u, v) => v.map(x => x === null ? '' : Math.round(x)) },
      ],
      series: [
        { label: 'time' },
        ...seriesSpecs.map(s => ({
          label: s.label, stroke: s.color, width: s.width, scale: s.scale,
          spanGaps: true, dash: s.dash || undefined, fill: s.fill || undefined,
        })),
      ],
      hooks: {
        draw: [
          (u) => drawAlertsMarkers(u, alerts || []),
        ],
      },
    };

    _chartInstance = new window.uPlot(opts, data, host);

    if (!host.__resizeWired) {
      host.__resizeWired = true;
      let resizeTimer;
      window.addEventListener('resize', () => {
        clearTimeout(resizeTimer);
        resizeTimer = setTimeout(() => renderChart(chart, alerts), 200);
      });
    }
  }

  function drawAlertsMarkers(u, alerts) {
    if (!alerts || !alerts.length) return;
    const ctx = u.ctx;
    if (!ctx) return;
    ctx.save();
    alerts.forEach(a => {
      if (!a.fired_at) return;
      const tSec = Math.round(new Date(a.fired_at).getTime() / 1000);
      const x = u.valToPos(tSec, 'x', true);
      if (x < u.bbox.left || x > u.bbox.left + u.bbox.width) return;
      const top = u.bbox.top + 4;
      const bot = u.bbox.top + u.bbox.height - 4;
      // vertical line
      ctx.strokeStyle = severityColor(a.severity);
      ctx.globalAlpha = 0.35;
      ctx.beginPath(); ctx.moveTo(x, top); ctx.lineTo(x, bot); ctx.stroke();
      // triangle marker at top
      ctx.globalAlpha = 1;
      ctx.fillStyle = severityColor(a.severity);
      ctx.beginPath();
      ctx.moveTo(x, top); ctx.lineTo(x - 4, top - 6); ctx.lineTo(x + 4, top - 6); ctx.closePath();
      ctx.fill();
    });
    ctx.restore();
  }

  function severityColor(sev) {
    if (sev === 'critical' || sev === 'high') return '#ef4444';
    if (sev === 'medium' || sev === 'warn')   return '#f59e0b';
    return '#60a5fa';
  }

  function renderChartLegend() {
    const el = document.getElementById('chartLegend');
    if (!el) return;
    const items = [
      ['#fbbf24', 'Owned'],
      ['#737373', 'Market'],
      ['#a78bfa', 'Non-owned'],
      ['#60a5fa', 'Owned qty'],
      ['#94a3b8', 'Mkt qty'],
    ];
    el.innerHTML = items.map(([c, l]) =>
      `<span><i style="background:${c}"></i> ${l}</span>`).join('');
  }

  // ---------- Splits ----------

  function renderSplits(splits) {
    const body = document.getElementById('splitsBody');
    body.innerHTML = '';
    if (!splits) {
      body.innerHTML = '<div class="empty">no splits data</div>';
      return;
    }
    const owned = splits.owned || {};
    const market = splits.market || {};
    const buckets = ['singles', 'pairs', 'triples', 'quads', 'five_plus'];
    const totalOwnedTg = sumTg(owned);
    const totalMarketTg = sumTg(market);

    if (totalOwnedTg === 0 && totalMarketTg === 0) {
      body.innerHTML = '<div class="empty">no recent TEvo listings (last 24h) — possibly stale collector</div>';
      return;
    }

    const tbl = document.createElement('table');
    tbl.className = 'splits-tbl';
    tbl.innerHTML = `
      <thead><tr>
        <th>Split</th>
        <th class="num">Ours TG</th>
        <th class="num">Ours tix</th>
        <th class="num">Ours avg $</th>
        <th class="num">Mkt TG</th>
        <th class="num">Mkt tix</th>
        <th class="num">Mkt avg $</th>
      </tr></thead>
      <tbody></tbody>
    `;
    const tb = tbl.querySelector('tbody');
    buckets.forEach(b => {
      const ob = owned[b] || {};
      const mb = market[b] || {};
      if (!ob.tg_count && !mb.tg_count) return;
      const tr = document.createElement('tr');
      tr.innerHTML = `
        <td class="split-name">${labelForBucket(b)}</td>
        <td class="num ours">${fmtIntCell(ob.tg_count)}</td>
        <td class="num ours">${fmtIntCell(ob.tix_count)}</td>
        <td class="num ours">${fmtPxCell(ob.avg_px)}</td>
        <td class="num">${fmtIntCell(mb.tg_count)}</td>
        <td class="num">${fmtIntCell(mb.tix_count)}</td>
        <td class="num">${fmtPxCell(mb.avg_px)}</td>
      `;
      tb.appendChild(tr);
    });
    body.appendChild(tbl);
  }

  function labelForBucket(b) {
    return { singles: 'singles (1)', pairs: 'pairs (2)', triples: 'triples (3)',
             quads: 'quads (4)', five_plus: '5+ pack' }[b] || b;
  }
  function sumTg(o) {
    return Object.values(o || {}).reduce((s, b) => s + (b && b.tg_count || 0), 0);
  }
  function fmtIntCell(n) { return (n === null || n === undefined) ? '—' : T.fmtNum(n); }
  function fmtPxCell(n)  { return (n === null || n === undefined) ? '—' : '$' + T.fmtNum(n, { max: 0 }); }

  // ---------- Zones (carried from v1) ----------

  function renderZones(zones) {
    const body = document.getElementById('zonesBody');
    body.innerHTML = '';
    if (!zones) {
      body.innerHTML = '<div class="empty">zones unavailable</div>';
      return;
    }
    const rows = zones.zones || [];
    if (!rows.length) {
      body.innerHTML = '<div class="empty">no zone data</div>';
      return;
    }
    const tbl = document.createElement('table');
    tbl.innerHTML = `
      <thead><tr>
        <th>Zone</th>
        <th class="num">Qty</th>
        <th class="num">Median</th>
        <th class="num">Ours qty</th>
        <th class="num">Ours %</th>
      </tr></thead><tbody></tbody>`;
    const tb = tbl.querySelector('tbody');
    rows.slice(0, 30).forEach(r => {
      const tr = document.createElement('tr');
      const ourPct = (r.owned_share !== null && r.owned_share !== undefined)
        ? T.fmtPct(r.owned_share * 100, 0) : '—';
      tr.innerHTML = `
        <td class="zone-name">${escapeHtml(r.zone || '—')}</td>
        <td class="num">${T.fmtNum(r.tickets_count)}</td>
        <td class="num">$${T.fmtNum(r.retail_median, { max: 0 })}</td>
        <td class="num ours">${T.fmtNum(r.owned_tickets_count)}</td>
        <td class="num ours">${ourPct}</td>`;
      tb.appendChild(tr);
    });
    body.appendChild(tbl);
  }

  // ---------- Sales tape (SG, deduped already by RPC) ----------

  function renderSalesTape(rows, bridge) {
    const body = document.getElementById('salesTapeBody');
    body.innerHTML = '';
    if (!rows || !rows.length) {
      const reason = bridge && bridge.sg_event_id == null
        ? 'no SG bridge for this event'
        : 'no recent SG sales';
      body.innerHTML = `<div class="empty">${reason}</div>`;
      return;
    }
    const tbl = document.createElement('table');
    tbl.className = 'sales-tbl';
    tbl.innerHTML = `
      <thead><tr>
        <th>Sold at</th>
        <th>Section</th>
        <th>Row</th>
        <th class="num">Lot qty</th>
        <th class="num">Px / tix</th>
        <th>Stock</th>
      </tr></thead><tbody></tbody>`;
    const tb = tbl.querySelector('tbody');
    rows.forEach(r => {
      const tr = document.createElement('tr');
      tr.innerHTML = `
        <td>${T.fmtDate(r.sale_at_utc)}</td>
        <td>${escapeHtml(r.section || '—')}</td>
        <td>${escapeHtml(r.row || '—')}</td>
        <td class="num">${r.quantity != null ? T.fmtNum(r.quantity) : '—'}</td>
        <td class="num">${r.broadcast_price != null ? '$' + T.fmtNum(r.broadcast_price, { max: 2 }) : '—'}</td>
        <td class="muted">${escapeHtml(r.stock_type || '')}</td>`;
      tb.appendChild(tr);
    });
    body.appendChild(tbl);
  }

  // ---------- ESPN ----------

  function renderEspn(espn) {
    const section = document.getElementById('espn');
    const body = document.getElementById('espnBody');
    const subtitle = document.getElementById('espnSubtitle');
    if (!body) return;
    if (!espn || espn.hidden) {
      section.style.display = 'none';
      return;
    }
    section.style.display = '';
    if (subtitle) {
      const lg = espn.espn_league ? String(espn.espn_league).toUpperCase() : '';
      subtitle.textContent = `${lg} · ${espn.home_team_id || '?'} vs ${espn.away_team_id || '?'}`;
    }
    body.innerHTML = '';

    const teams = espn.team_standings || [];
    const injuries = espn.injuries || [];
    const recents = espn.recent_results || [];

    const grid = document.createElement('div');
    grid.className = 'espn-grid';
    // Standings cards
    teams.forEach(t => {
      const card = document.createElement('div');
      card.className = 'espn-card';
      const rec = t.record_summary || `${t.wins || 0}-${t.losses || 0}${t.ties ? '-' + t.ties : ''}`;
      card.innerHTML = `
        <div class="espn-card-hd">${escapeHtml(t.espn_team_id || '')}</div>
        <div class="espn-card-row"><span class="lbl">record</span><span class="val">${rec}</span></div>
        <div class="espn-card-row"><span class="lbl">win %</span><span class="val">${t.win_pct != null ? (t.win_pct * 100).toFixed(1) + '%' : '—'}</span></div>
        <div class="espn-card-row"><span class="lbl">streak</span><span class="val">${escapeHtml(t.streak || '—')}</span></div>
        <div class="espn-card-row"><span class="lbl">seed</span><span class="val">${t.playoff_seed || '—'}</span></div>
        <div class="espn-card-foot">${escapeHtml(t.standing_summary || '')}</div>
      `;
      grid.appendChild(card);
    });
    body.appendChild(grid);

    // Injuries
    if (injuries.length) {
      const inj = document.createElement('div');
      inj.className = 'espn-injuries';
      inj.innerHTML = '<div class="espn-sublabel">ACTIVE INJURIES (' + injuries.length + ')</div>';
      const ul = document.createElement('ul');
      injuries.slice(0, 12).forEach(i => {
        const li = document.createElement('li');
        const sev = (i.status || '').toLowerCase();
        const dot = sev === 'out' || sev === 'ir' ? '◯' : sev === 'questionable' || sev === 'q' ? '▲' : '●';
        li.innerHTML = `<span class="inj-dot ${injuryClass(sev)}">${dot}</span> <strong>${escapeHtml(i.athlete_name || '')}</strong> <span class="inj-pos">${escapeHtml(i.position || '')}</span> <span class="inj-status">${escapeHtml(i.status || '')}</span> <span class="muted">${escapeHtml(i.injury_type || '')}</span>`;
        ul.appendChild(li);
      });
      inj.appendChild(ul);
      body.appendChild(inj);
    }

    // Recent results
    if (recents.length) {
      const rr = document.createElement('div');
      rr.className = 'espn-recent';
      rr.innerHTML = '<div class="espn-sublabel">RECENT RESULTS (' + recents.length + ')</div>';
      const ul = document.createElement('ul');
      recents.slice(0, 5).forEach(r => {
        const li = document.createElement('li');
        li.innerHTML = `<span class="muted">${T.fmtDate(r.captured_at)}</span> ${escapeHtml(r.away_team_id || '?')} ${r.away_score != null ? r.away_score : '—'} @ ${escapeHtml(r.home_team_id || '?')} ${r.home_score != null ? r.home_score : '—'}`;
        ul.appendChild(li);
      });
      rr.appendChild(ul);
      body.appendChild(rr);
    }
  }

  function injuryClass(sev) {
    if (sev === 'out' || sev === 'ir') return 'inj-out';
    if (sev === 'questionable' || sev === 'q') return 'inj-q';
    return 'inj-p';
  }

  // ---------- Weather ----------

  function renderWeather(w) {
    const section = document.getElementById('weather');
    const body = document.getElementById('weatherBody');
    const subtitle = document.getElementById('weatherSubtitle');
    if (!body) return;
    if (!w || w.hidden) {
      section.style.display = 'none';
      return;
    }
    section.style.display = '';
    body.innerHTML = '';
    if (subtitle) subtitle.textContent = w.event_at ? `event ${T.fmtDate(w.event_at)}` : '';

    const fc = w.forecast || [];
    const obs = w.recent_obs || [];
    const alerts = w.nws_alerts || [];

    if (fc.length) {
      const fcWrap = document.createElement('div');
      fcWrap.className = 'wx-forecast';
      fcWrap.innerHTML = '<div class="wx-sublabel">FORECAST · NEAREST TO EVENT TIME</div>';
      const row = document.createElement('div');
      row.className = 'wx-row';
      fc.forEach(f => {
        const cell = document.createElement('div');
        cell.className = 'wx-cell';
        cell.innerHTML = `
          <div class="wx-time">${shortHour(f.observed_at)}</div>
          <div class="wx-temp">${f.temp_f != null ? Math.round(f.temp_f) + '°' : '—'}</div>
          <div class="wx-precip">${f.precip_pct != null ? Math.round(f.precip_pct) + '%' : '—'} ${f.precip_in != null ? `· ${f.precip_in.toFixed(2)}"` : ''}</div>
          <div class="wx-wind">${f.wind_mph != null ? Math.round(f.wind_mph) + ' mph' : '—'}${f.gust_mph != null ? ` · g${Math.round(f.gust_mph)}` : ''}</div>
          <div class="wx-summary">${escapeHtml(f.weather_summary || '')}</div>
        `;
        row.appendChild(cell);
      });
      fcWrap.appendChild(row);
      body.appendChild(fcWrap);
    }

    if (obs.length) {
      const obsWrap = document.createElement('div');
      obsWrap.className = 'wx-obs';
      obsWrap.innerHTML = `<div class="wx-sublabel">RECENT OBSERVATIONS (${obs.length})</div>`;
      const ul = document.createElement('ul');
      obs.forEach(o => {
        const li = document.createElement('li');
        li.innerHTML = `<span class="muted">${T.fmtDate(o.observed_at)}</span> ${o.temp_f != null ? Math.round(o.temp_f) + '°F' : '—'} · ${o.precip_pct != null ? o.precip_pct + '% precip' : '—'} · ${escapeHtml(o.weather_summary || '')}`;
        ul.appendChild(li);
      });
      obsWrap.appendChild(ul);
      body.appendChild(obsWrap);
    }

    if (alerts.length) {
      const aw = document.createElement('div');
      aw.className = 'wx-alerts';
      aw.innerHTML = `<div class="wx-sublabel">NWS ALERTS (${alerts.length})</div>`;
      const ul = document.createElement('ul');
      alerts.forEach(a => {
        const li = document.createElement('li');
        li.innerHTML = `<strong>${escapeHtml(a.event || '')}</strong> <span class="muted">${escapeHtml(a.severity || '')} · expires ${T.fmtDate(a.expires_at)}</span> — ${escapeHtml(a.headline || '')}`;
        ul.appendChild(li);
      });
      aw.appendChild(ul);
      body.appendChild(aw);
    }
  }

  function shortHour(iso) {
    if (!iso) return '—';
    try {
      const d = new Date(iso);
      return d.toLocaleString(undefined, { weekday: 'short', hour: 'numeric' });
    } catch (_) { return iso; }
  }

  // ---------- Orders strip ----------

  function renderOrders(orders) {
    const body = document.getElementById('ordersBody');
    body.innerHTML = '';
    if (!orders) {
      body.innerHTML = '<div class="empty">orders unavailable</div>';
      return;
    }
    if (!orders.summary || orders.summary.total_items === 0) {
      body.innerHTML = '<div class="empty">no orders for this event</div>';
      return;
    }
    const byState = orders.summary.by_state || {};
    const stateOrder = ['pending', 'accepted', 'completed', 'rejected', 'pending_sub', 'unknown'];

    const bar = document.createElement('div');
    bar.className = 'order-bar';
    stateOrder.forEach(st => {
      const n = byState[st] || 0;
      if (!n) return;
      const seg = document.createElement('div');
      seg.className = 'seg ' + st;
      seg.style.flex = String(n);
      seg.textContent = n >= 3 ? n : '';
      seg.title = `${st}: ${n}`;
      bar.appendChild(seg);
    });
    body.appendChild(bar);

    const legend = document.createElement('div');
    legend.className = 'order-legend';
    stateOrder.forEach(st => {
      const n = byState[st] || 0;
      if (!n) return;
      const row = document.createElement('div');
      row.className = 'row ' + st;
      row.innerHTML = `<span class="lbl">${st}</span><span class="num">${n}</span>`;
      legend.appendChild(row);
    });
    body.appendChild(legend);

    const summary = document.createElement('div');
    summary.className = 'order-summary';
    summary.innerHTML = `
      <span class="lbl">items</span><span class="val">${T.fmtNum(orders.summary.total_items)}</span>
      <span class="lbl">tickets sold</span><span class="val">${T.fmtNum(orders.summary.tickets_sold)}</span>
      <span class="lbl">gross sold</span><span class="val">$${T.fmtNum(orders.summary.gross_sold, { max: 0 })}</span>
      <span class="lbl">last update</span><span class="val">${T.fmtDate(orders.summary.last_update_at)}</span>
    `;
    body.appendChild(summary);
  }

  // ---------- Coverage + freshness ----------

  function renderCoverage(cadences, overview, freshness, bridge) {
    if (!cadences) return;
    const sections = cadences.sections || {};
    const tevoFresh = isFreshFromTs(freshness && freshness.tevo_listings_latest, 3 * 3600);
    const sgFresh   = bridge && bridge.sg_event_id != null
      ? isFreshFromTs(freshness && (freshness.sg_listings_latest || freshness.sg_sales_latest), 6 * 3600)
      : null;
    const sdFresh   = isFreshFromTs(freshness && freshness.sd_sales_latest, 7 * 24 * 3600);
    const espnFresh = isFresh(sections.espn_team) || isFresh(sections.espn_injuries)
      || isFreshFromTs(freshness && (freshness.espn_team_latest || freshness.espn_inj_latest), 24 * 3600);

    setLight('tevo',     tevoFresh);
    setLight('seatgeek', sgFresh);
    setLight('seatdata', sdFresh);
    setLight('espn',     espnFresh);
  }

  function setLight(src, fresh) {
    const el = document.querySelector(`#coverage .light[data-src="${src}"]`);
    if (!el) return;
    el.classList.remove('lit', 'stale');
    if (fresh === true) el.classList.add('lit');
    else if (fresh === false) el.classList.add('stale');
  }

  function isFresh(section) {
    if (!section || !section.last_pull_at) return null;
    const ageSec = (Date.now() - new Date(section.last_pull_at).getTime()) / 1000;
    if (!Number.isFinite(ageSec)) return null;
    const limit = (section.cadence_seconds || 3600) * 3;
    return ageSec <= limit;
  }
  function isFreshFromTs(iso, limitSec) {
    if (!iso) return null;
    const age = (Date.now() - new Date(iso).getTime()) / 1000;
    if (!Number.isFinite(age)) return null;
    return age <= limitSec;
  }

  function renderFreshness(fr) {
    if (!fr) return;
    // Weather: prefer obs latest, fall back to most-recent forecast time so
    // outdoor events with forecast-only data don't render a misleading dim chip.
    const weatherTs = fr.weather_latest || latestForecastTs();
    // ESPN: max of team + injuries timestamps (NOT first non-null — team
    // snapshots are gameday-batched and often 3d stale even when injuries
    // ingested 6 min ago).
    const espnTs = maxTs(fr.espn_team_latest, fr.espn_inj_latest);
    const map = {
      'tevo':     fr.tevo_listings_latest,
      'sg-lst':   fr.sg_listings_latest,
      'sg-sales': fr.sg_sales_latest,
      'weather':  weatherTs,
      'espn':     espnTs,
    };
    Object.entries(map).forEach(([src, ts]) => {
      const el = document.querySelector(`.fr-chip[data-src="${src}"]`);
      if (!el) return;
      const label = chipLabel(src);
      el.classList.remove('fresh', 'stale', 'dim');
      if (!ts) {
        el.textContent = `${label} —`;
        el.classList.add('dim');
        return;
      }
      const ageMin = Math.round((Date.now() - new Date(ts).getTime()) / 60000);
      el.textContent = `${label} ${formatAge(ageMin)}`;
      const stale = ageMin > staleLimit(src);
      el.classList.add(stale ? 'stale' : 'fresh');
      el.title = `${label}: ${T.fmtDate(ts)}`;
    });
  }
  function maxTs(...tss) {
    let best = null;
    for (const t of tss) {
      if (!t) continue;
      if (best == null || new Date(t).getTime() > new Date(best).getTime()) best = t;
    }
    return best;
  }
  function latestForecastTs() {
    const w = _lastPayload && _lastPayload.weather;
    if (!w || w.hidden) return null;
    const fc = w.forecast || [];
    if (!fc.length) return null;
    return fc.reduce((acc, f) => maxTs(acc, f.observed_at), null);
  }
  function chipLabel(src) {
    return { tevo: 'TEvo', 'sg-lst': 'SG L', 'sg-sales': 'SG S', weather: 'Wx', espn: 'ESPN' }[src] || src;
  }
  function staleLimit(src) {
    return { tevo: 180, 'sg-lst': 60, 'sg-sales': 30, weather: 360, espn: 1440 }[src] || 360;
  }
  function formatAge(min) {
    if (min < 1)   return 'now';
    if (min < 60)  return `${min}m`;
    if (min < 1440) return `${Math.round(min / 60)}h`;
    return `${Math.round(min / 1440)}d`;
  }

  // ---------- Event alerts list ----------

  function renderAlerts(alerts) {
    const body = document.getElementById('alertsBody');
    const count = document.getElementById('alertsCount');
    body.innerHTML = '';
    if (!alerts || !alerts.length) {
      body.innerHTML = '<div class="empty">no event alerts in window</div>';
      if (count) count.textContent = '0 alerts';
      return;
    }

    // Operator audit 2026-05-17: alerts panel listed 5×(competing_event_added)
    // + 4×(tevo_getin_drop/surge_1h) with near-identical messages. Visual noise.
    // Group by rule_key + collapse messages with the same dollar pattern; show
    // count chip per group + the most recent firing time. Expand-on-click via
    // <details> so the raw list is still one click away.
    const groups = new Map();  // rule_key → { rule, severity, items: [], latest_at }
    for (const a of alerts) {
      const rule = a.rule_key || 'unknown';
      if (!groups.has(rule)) {
        groups.set(rule, {
          rule,
          severity: a.severity || 'info',
          items: [],
          latest_at: a.fired_at,
        });
      }
      const g = groups.get(rule);
      g.items.push(a);
      if (a.fired_at && (!g.latest_at || a.fired_at > g.latest_at)) {
        g.latest_at = a.fired_at;
        // Severity worsens over time? Track max severity per group.
        if (severityRank(a.severity) > severityRank(g.severity)) g.severity = a.severity;
      }
    }
    // Sort groups by latest firing desc.
    const groupArr = Array.from(groups.values())
      .sort((x, y) => (y.latest_at || '').localeCompare(x.latest_at || ''));

    if (count) {
      count.textContent = `${alerts.length} alert${alerts.length === 1 ? '' : 's'} · ${groupArr.length} rule${groupArr.length === 1 ? '' : 's'}`;
    }

    groupArr.forEach(g => {
      const det = document.createElement('details');
      det.className = 'alerts-group sev-' + g.severity;
      // Auto-expand when only 1 item — same UX as flat list before
      if (g.items.length === 1) det.open = true;
      const summary = document.createElement('summary');
      // Dedup messages: surface the latest message + " ×N" if N>1 same-pattern firings
      const latestMsg = g.items
        .slice()
        .sort((a, b) => (b.fired_at || '').localeCompare(a.fired_at || ''))[0].message || '';
      summary.innerHTML = `
        <span class="al-rule">${escapeHtml(g.rule)}</span>
        ${g.items.length > 1 ? `<span class="al-count">×${g.items.length}</span>` : ''}
        <span class="al-msg">${escapeHtml(latestMsg)}</span>
        <span class="al-time muted">latest ${T.fmtDate(g.latest_at)}</span>`;
      det.appendChild(summary);
      // Expanded body — full chronological list
      const ul = document.createElement('ul');
      ul.className = 'alerts-list';
      g.items
        .slice()
        .sort((a, b) => (b.fired_at || '').localeCompare(a.fired_at || ''))
        .forEach(a => {
          const li = document.createElement('li');
          li.className = 'alert-row sev-' + (a.severity || 'info');
          li.innerHTML = `
            <span class="al-time muted">${T.fmtDate(a.fired_at)}</span>
            <span class="al-msg">${escapeHtml(a.message || '')}</span>`;
          ul.appendChild(li);
        });
      det.appendChild(ul);
      body.appendChild(det);
    });
  }

  function severityRank(sev) {
    return { info: 0, low: 1, medium: 2, warn: 2, high: 3, critical: 4 }[sev] || 0;
  }

  // ---------- Util ----------

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

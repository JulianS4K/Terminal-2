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
  // Chart-extension state cache (mig 20260519150000 / get_event_chart_extended):
  // fetched in parallel with v3; merges 5 SG series + 2 ESPN annotation arrays
  // into the chart whenever it lands. Same state-machine pattern as splits/zones.
  let _chartExtState = { payload: undefined };
  let _chartExtAlerts = []; // cached for re-renders after extended payload arrives

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
    wireTabs(eventId);
    wireSalesWindow(eventId);
    // Path-C-only enrichment RPCs fire in parallel — render even when
    // fetchPayload (Path A / Path C v3) fails. PR #205 cross-source +
    // PR redesign localized weather + SG zones/splits all independent.
    loadCrossSourceMetrics(eventId).catch(e => console.error('[crossSource]', e));
    loadWeatherLocalized(eventId).catch(e => console.error('[weatherLocalized]', e));
    loadSgZonesSplits(eventId).catch(e => console.error('[sgZonesSplits]', e));
    loadChartExtended(eventId).catch(e => console.error('[chartExtended]', e));
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

      safe('hero',       () => renderHero(overview, bridge, data.performer));
      safe('eventMode',  () => renderEventMode(bridge, data));
      safe('kpiGrid',    () => renderKPIGrid(chart, data.sg_side_by_side, data.velocity));
      safe('chart',      () => renderChart(chart, data.event_alerts));
      safe('chartLegend',() => renderChartLegend());
      // Splits + Zones — TEvo side rendered now; SG side merged in by loadSgZonesSplits.
      // Splits + Zones: feed only the TEvo side here. The SG side lives in a
      // module-level cache populated by loadSgZonesSplits (parallel fetch);
      // each panel re-renders whenever either side updates.
      safe('splits',     () => setSplitsTevo(data.splits));
      safe('zones',      () => setZonesTevo(zones, data.zone_deltas));
      safe('salesTape',  () => renderSalesTape(data.sales_tape, bridge));
      safe('espn',       () => renderEspn(data.espn));
      // Weather now lazy-loaded via loadWeatherLocalized (drops global-alert path).
      safe('allOrders',  () => renderAllOrders(orders, data.cross_source_orders));
      safe('coverage',   () => renderCoverage(cadences, overview, data.freshness, bridge));
      safe('freshness',  () => renderFreshness(data.freshness));
      safe('alerts',     () => renderAlerts(data.event_alerts));
      // v3 enrichments
      safe('sgBrokerSales',    () => renderSgBrokerSales(data.sg_broker_sales));
      safe('velocityChips',    () => renderVelocityChips(data.velocity));
      safe('competingEvents',  () => renderCompetingEvents(data.competing_events));
      safe('recentListings',   () => renderRecentListings(data.recent_listings));
      safe('performerEspn',    () => renderPerformerEspn(data.performer_espn_context, data.performer));
      safe('lastSnapshot',     () => renderLastSnapshot(data.chart_data));
      // Cross-source panel: re-render now that we have v3's sg_broker_sales
      // available (overrides sold_price_median for "Realized sale median" row).
      safe('crossSourceRerender', () => rerenderCrossSourceWithV3(data));
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
      // Drop stale extended payload so series don't render mismatched windows
      _chartExtState.payload = undefined;
      // Re-fire both fetches; renderChart re-runs when each lands
      loadChartExtended(eventId).catch(e => console.error('[chartExtended]', e));
      await loadAndRender(eventId);
    });
  }

  // ---------- Fetch (Path C primary, Path A fallback) ----------

  async function fetchPayload(eventId) {
    const Auth = window.TerminalAuth;
    if (Auth && Auth.client && Auth.getAccessToken()) {
      // Try v3 first (9 enrichment keys); fall back to v2 if v3 isn't applied
      // yet on this Supabase project. Both shapes are forward-compatible —
      // renderers no-op or empty-state when their keys aren't in the payload.
      let res = await Auth.client
        .rpc('get_broker_event_page_v3', { p_event_id: eventId, p_chart_hours: CHART_HOURS });
      if (res.error && (res.error.code === '42883' || /does not exist/i.test(res.error.message || ''))) {
        // v3 not applied yet — fall back to v2
        res = await Auth.client
          .rpc('get_broker_event_page_v2', { p_event_id: eventId, p_chart_hours: CHART_HOURS });
      }
      if (res.error) {
        const err = new Error(res.error.message || 'RPC error');
        err.code = res.error.code; err.details = res.error.details; err.hint = res.error.hint;
        throw err;
      }
      return res.data;
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

  function renderHero(overview, bridge, performer) {
    // v3: paint logo + brand color + league badge from performer payload
    // before laying out title/badges so the hero border applies correctly.
    try { renderHeroV3Branding(performer); } catch (e) { console.error('heroBranding', e); }
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

    // Cache alerts for re-renders triggered by extended-payload arrival
    _chartExtAlerts = alerts || [];

    // Merge the SG-side series from _chartExtState (lands in parallel — may be
    // undefined on first paint; chart redraws when it arrives). Reading via
    // the cache instead of an explicit arg matches the splits/zones pattern.
    const ext = _chartExtState.payload || null;
    const extSeries = (ext && ext.series) || {};
    const sgListMed   = extSeries.sg_listings_median       || [];
    const sgListOwnMed= extSeries.sg_listings_owned_median || [];
    const sgListCt    = extSeries.sg_listings_count        || [];
    const sgSaleMed   = extSeries.sg_sales_median          || [];
    const sgSaleCt    = extSeries.sg_sales_count           || [];

    const seriesSpecs = [
      // TEvo (existing 5)
      { key: 'prices_owned',    label: 'TEvo Owned',     color: '#fbbf24', scale: 'y',   width: 2,   dash: null,    data: chart.prices_owned },
      { key: 'prices_market',   label: 'TEvo Market',    color: '#737373', scale: 'y',   width: 1.5, dash: [4, 4],  data: chart.prices_market },
      { key: 'prices_nonowned', label: 'TEvo Non-owned', color: '#a78bfa', scale: 'y',   width: 1.5, dash: [6, 3],  data: chart.prices_nonowned },
      { key: 'counts_owned',    label: 'TEvo Owned qty', color: '#60a5fa', scale: 'qty', width: 1,   dash: null,    fill: 'rgba(96,165,250,0.08)', data: chart.counts_owned },
      { key: 'counts_market',   label: 'TEvo Mkt qty',   color: '#94a3b8', scale: 'qty', width: 1,   dash: [2, 2],  data: chart.counts_market },
      // SG (new 5, from extended RPC payload)
      { key: 'sg_list_med',     label: 'SG list med',    color: '#22d3ee', scale: 'y',   width: 1.5, dash: null,    data: sgListMed },
      { key: 'sg_own_med',      label: 'SG owned med',   color: '#fb7185', scale: 'y',   width: 1.5, dash: [3, 3],  data: sgListOwnMed },
      { key: 'sg_sale_med',     label: 'SG sale med',    color: '#84cc16', scale: 'y',   width: 1.5, dash: [5, 2],  data: sgSaleMed },
      { key: 'sg_list_ct',      label: 'SG list qty',    color: '#22d3ee', scale: 'qty', width: 1,   dash: [2, 2],  data: sgListCt },
      { key: 'sg_sale_ct',      label: 'SG sale ct',     color: '#84cc16', scale: 'sgct',width: 1.5, dash: null,    data: sgSaleCt, points: { show: true, size: 4 } },
    ];

    // Build unified time axis
    const tset = new Set();
    seriesSpecs.forEach(s => (s.data || []).forEach(p => tset.add(p.t)));
    const ts = [...tset].sort();
    const xs = ts.map(t => Math.round(new Date(t).getTime() / 1000));
    const idx = new Map(ts.map((t, i) => [t, i]));
    const project = (s) => {
      const arr = new Array(ts.length).fill(null);
      (s || []).forEach(p => { const i = idx.get(p.t); if (i != null) arr[i] = p.v; });
      return arr;
    };

    const data = [xs, ...seriesSpecs.map(s => project(s.data))];

    // Pick a tick-friendly width (re-render on resize)
    const rect = host.getBoundingClientRect();
    const w = Math.max(800, rect.width || host.clientWidth || 1200);
    const h = Math.max(280, (rect.height || 320) - 20);

    const opts = {
      width: w, height: h,
      cursor: { drag: { x: true, y: false } },
      scales: { x: { time: true }, y: {}, qty: {}, sgct: {} },
      axes: [
        { stroke: 'var(--muted)', grid: { stroke: 'var(--line-2)', width: 1 } },
        { scale: 'y',   stroke: 'var(--muted)', grid: { stroke: 'var(--line-2)', width: 1 },
          values: (u, v) => v.map(x => x === null ? '' : '$' + Math.round(x)) },
        { scale: 'qty', side: 1, stroke: 'var(--muted)', grid: { show: false },
          values: (u, v) => v.map(x => x === null ? '' : Math.round(x)) },
        // Hidden axis: sg sale count shares the right-side gutter implicitly via
        // its own scale (sgct), but we don't draw a separate axis to keep the
        // chart visually clean. uPlot still scales it correctly.
      ],
      series: [
        { label: 'time' },
        ...seriesSpecs.map(s => ({
          label: s.label, stroke: s.color, width: s.width, scale: s.scale,
          spanGaps: true, dash: s.dash || undefined, fill: s.fill || undefined,
          points: s.points || undefined,
        })),
      ],
      hooks: {
        draw: [
          (u) => drawAlertsMarkers(u, alerts || []),
          (u) => drawInjuryMarkers(u, ext && ext.annotations && ext.annotations.injuries),
          (u) => drawGameStateMarkers(u, ext && ext.annotations && ext.annotations.game_state),
        ],
        ready: [
          (u) => renderAnnotationTooltips(u, host, ext && ext.annotations),
        ],
        setSize: [
          (u) => renderAnnotationTooltips(u, host, ext && ext.annotations),
        ],
      },
    };

    _chartInstance = new window.uPlot(opts, data, host);

    if (!host.__resizeWired) {
      host.__resizeWired = true;
      let resizeTimer;
      window.addEventListener('resize', () => {
        clearTimeout(resizeTimer);
        resizeTimer = setTimeout(() => renderChart(chart, _chartExtAlerts), 200);
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

  // Injury transition canvas marker — small "+" near top of chart, magenta.
  // Same canvas-px coordinate convention as drawAlertsMarkers (canPos=true).
  function drawInjuryMarkers(u, injuries) {
    if (!injuries || !injuries.length || !u.ctx) return;
    const ctx = u.ctx;
    ctx.save();
    ctx.strokeStyle = '#ec4899'; // pink/magenta — distinct from yellow/red alert palette
    ctx.lineWidth = 2;
    injuries.forEach(a => {
      if (!a.at) return;
      const tSec = Math.round(new Date(a.at).getTime() / 1000);
      const x = u.valToPos(tSec, 'x', true);
      if (x < u.bbox.left || x > u.bbox.left + u.bbox.width) return;
      const y = u.bbox.top + 14;
      // small cross
      ctx.beginPath();
      ctx.moveTo(x - 3, y); ctx.lineTo(x + 3, y);
      ctx.moveTo(x, y - 3); ctx.lineTo(x, y + 3);
      ctx.stroke();
    });
    ctx.restore();
  }

  // Game-state transition canvas marker — small square near top of chart, teal.
  function drawGameStateMarkers(u, states) {
    if (!states || !states.length || !u.ctx) return;
    const ctx = u.ctx;
    ctx.save();
    ctx.fillStyle = '#14b8a6'; // teal
    states.forEach(s => {
      if (!s.at) return;
      const tSec = Math.round(new Date(s.at).getTime() / 1000);
      const x = u.valToPos(tSec, 'x', true);
      if (x < u.bbox.left || x > u.bbox.left + u.bbox.width) return;
      const y = u.bbox.top + 26;
      ctx.fillRect(x - 3, y - 3, 6, 6);
    });
    ctx.restore();
  }

  // DOM-overlay tooltips for annotations (canvas can't host hover tooltips natively).
  // Sibling absolute-positioned dots over the chart canvas; native title= attribute
  // for hover text. Cheap + zero plugin deps. Re-run on uPlot ready + setSize.
  function renderAnnotationTooltips(u, host, annotations) {
    if (!annotations) return;
    let overlay = host.querySelector('.chart-anno-host');
    if (!overlay) {
      // Ensure host is positioned for absolute children
      const cs = window.getComputedStyle(host);
      if (cs.position === 'static') host.style.position = 'relative';
      overlay = document.createElement('div');
      overlay.className = 'chart-anno-host';
      host.appendChild(overlay);
    }
    overlay.innerHTML = '';
    const inj = annotations.injuries || [];
    const gs  = annotations.game_state || [];
    const addDot = (t, kind, tip) => {
      const tSec = Math.round(new Date(t).getTime() / 1000);
      // canPos=false → CSS pixels (matches DOM coordinate space)
      const x = u.valToPos(tSec, 'x');
      if (x < u.bbox.left || x > u.bbox.left + u.bbox.width) return;
      const yOffset = kind === 'inj' ? 12 : 24;
      const dot = document.createElement('div');
      dot.className = 'chart-anno-dot anno-' + kind;
      dot.style.left = (x - 5) + 'px';
      dot.style.top = (u.bbox.top + yOffset - 5) + 'px';
      dot.title = tip;
      overlay.appendChild(dot);
    };
    inj.forEach(a => addDot(a.at, 'inj',
      `${a.athlete_name || a.athlete_id || '?'} (${a.position || '?'} · team ${a.espn_team_id || '?'}): ${a.prev_status || '—'} → ${a.new_status || '—'}`));
    gs.forEach(s => addDot(s.at, 'gs',
      `Game state: ${s.prev_status || '—'} → ${s.new_status || '—'}${s.state ? ' (' + s.state + ')' : ''}`));
  }

  function renderChartLegend() {
    const el = document.getElementById('chartLegend');
    if (!el) return;
    const ext = _chartExtState.payload;
    const hasSg = ext && !ext.sg_hidden;
    const items = [
      ['#fbbf24', 'TEvo Owned'],
      ['#737373', 'TEvo Mkt'],
      ['#a78bfa', 'TEvo Non-own'],
      ['#60a5fa', 'TEvo Own qty'],
      ['#94a3b8', 'TEvo Mkt qty'],
    ];
    if (hasSg) {
      items.push(
        ['#22d3ee', 'SG list med'],
        ['#fb7185', 'SG owned med'],
        ['#84cc16', 'SG sale med'],
        ['#22d3ee', 'SG list qty', 'dashed'],
        ['#84cc16', 'SG sale ct'],
      );
    }
    let html = items.map(([c, l, mod]) =>
      `<span><i style="background:${c}${mod === 'dashed' ? ';opacity:.5' : ''}"></i> ${l}</span>`).join('');
    if (ext && (
      (ext.annotations && ext.annotations.injuries && ext.annotations.injuries.length) ||
      (ext.annotations && ext.annotations.game_state && ext.annotations.game_state.length)
    )) {
      html += '<span class="legend-sep">|</span>';
      html += '<span><i class="anno-inj-i"></i> Injury</span>';
      html += '<span><i class="anno-gs-i"></i> State</span>';
    }
    el.innerHTML = html;
  }

  // ---------- Splits ----------

  // Splits + Zones use a module-level state cache so the two parallel data
  // sources (v3 fetchPayload for TEvo + get_event_sg_zones_splits for SG)
  // can update independently without clobbering each other on re-render.
  // Each setter writes its side then triggers a unified render reading both.
  const _splitsState = { tevo: undefined, sg: undefined };
  const _zonesState  = { tevo: undefined, deltas: undefined, sg: undefined };

  function setSplitsTevo(splits)   { _splitsState.tevo = splits; renderSplits(); }
  function setSplitsSg(sgSplits)   { _splitsState.sg   = sgSplits; renderSplits(); }
  function setZonesTevo(zones, deltas) {
    _zonesState.tevo = zones; _zonesState.deltas = deltas; renderZones();
  }
  function setZonesSg(sgZones)     { _zonesState.sg   = sgZones; renderZones(); }

  // Renders TEvo splits + SG splits side-by-side from the module state cache.
  // Either or both sides may still be `undefined` (loading) when this fires.
  function renderSplits() {
    const body = document.getElementById('splitsBody');
    if (!body) return;
    body.innerHTML = '';
    const left = document.createElement('div');
    left.className = 'dual-src-col';
    left.innerHTML = '<div class="dual-src-hdr">TEvo</div>';
    left.appendChild(buildTevoSplitsTable(_splitsState.tevo));
    const right = document.createElement('div');
    right.className = 'dual-src-col';
    right.innerHTML = '<div class="dual-src-hdr">SG</div>';
    right.appendChild(buildSgSplitsTable(_splitsState.sg));
    body.appendChild(left);
    body.appendChild(right);
  }

  function buildTevoSplitsTable(splits) {
    const wrap = document.createElement('div');
    if (splits === undefined) { wrap.innerHTML = '<div class="empty">loading TEvo…</div>'; return wrap; }
    if (!splits) { wrap.innerHTML = '<div class="empty">no TEvo splits data</div>'; return wrap; }
    const owned = splits.owned || {};
    const market = splits.market || {};
    const buckets = ['singles', 'pairs', 'triples', 'quads', 'five_plus'];
    const totalOwnedTg = sumTg(owned);
    const totalMarketTg = sumTg(market);
    if (totalOwnedTg === 0 && totalMarketTg === 0) {
      wrap.innerHTML = '<div class="empty">no recent TEvo listings (last 24h)</div>'; return wrap;
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
      </tr></thead><tbody></tbody>`;
    const tb = tbl.querySelector('tbody');
    buckets.forEach(b => {
      const ob = owned[b] || {}; const mb = market[b] || {};
      if (!ob.tg_count && !mb.tg_count) return;
      const tr = document.createElement('tr');
      tr.innerHTML = `
        <td class="split-name">${labelForBucket(b)}</td>
        <td class="num ours">${fmtIntCell(ob.tg_count)}</td>
        <td class="num ours">${fmtIntCell(ob.tix_count)}</td>
        <td class="num ours">${fmtPxCell(ob.avg_px)}</td>
        <td class="num">${fmtIntCell(mb.tg_count)}</td>
        <td class="num">${fmtIntCell(mb.tix_count)}</td>
        <td class="num">${fmtPxCell(mb.avg_px)}</td>`;
      tb.appendChild(tr);
    });
    wrap.appendChild(tbl);
    return wrap;
  }

  function buildSgSplitsTable(sgSplits) {
    const wrap = document.createElement('div');
    if (sgSplits === undefined) { wrap.innerHTML = '<div class="empty">loading SG…</div>'; return wrap; }
    if (sgSplits === null || sgSplits.hidden) {
      const reason = sgSplits && sgSplits.reason === 'no_sg_bridge' ? 'no SG bridge for this event' : 'SG unavailable';
      wrap.innerHTML = `<div class="empty">${escapeHtml(reason)}</div>`; return wrap;
    }
    const buckets = ['singles','pairs','triples','quads','five_plus'];
    const splits = sgSplits.splits || {};
    const nonEmpty = buckets.some(b => splits[b]);
    if (!nonEmpty) { wrap.innerHTML = '<div class="empty">no recent SG listings (last 24h)</div>'; return wrap; }
    const tbl = document.createElement('table');
    tbl.className = 'splits-tbl';
    tbl.innerHTML = `
      <thead><tr>
        <th>Split</th>
        <th class="num">Groups</th>
        <th class="num">Tickets</th>
        <th class="num">Avg $</th>
      </tr></thead><tbody></tbody>`;
    const tb = tbl.querySelector('tbody');
    buckets.forEach(b => {
      const r = splits[b]; if (!r) return;
      const tr = document.createElement('tr');
      tr.innerHTML = `
        <td class="split-name">${labelForBucket(b)}</td>
        <td class="num">${fmtIntCell(r.groups)}</td>
        <td class="num">${fmtIntCell(r.tickets)}</td>
        <td class="num">${fmtPxCell(r.avg_price)}</td>`;
      tb.appendChild(tr);
    });
    wrap.appendChild(tbl);
    return wrap;
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

  // TEvo zones + SG sections side-by-side. Reads from the module state
  // cache (_zonesState) so parallel TEvo + SG updates don't clobber each
  // other (race fix — was passing null clobbered SG-already-rendered).
  function renderZones() {
    const body = document.getElementById('zonesBody');
    if (!body) return;
    body.innerHTML = '';
    const left = document.createElement('div');
    left.className = 'dual-src-col';
    left.innerHTML = '<div class="dual-src-hdr">TEvo (zones)</div>';
    left.appendChild(buildTevoZonesTable(_zonesState.tevo, _zonesState.deltas));
    const right = document.createElement('div');
    right.className = 'dual-src-col';
    right.innerHTML = '<div class="dual-src-hdr">SG (sections)</div>';
    right.appendChild(buildSgZonesTable(_zonesState.sg));
    body.appendChild(left);
    body.appendChild(right);
  }

  function buildTevoZonesTable(zones, deltas) {
    const wrap = document.createElement('div');
    if (zones === undefined) { wrap.innerHTML = '<div class="empty">loading TEvo…</div>'; return wrap; }
    if (!zones) { wrap.innerHTML = '<div class="empty">zones unavailable</div>'; return wrap; }
    const rows = zones.zones || [];
    if (!rows.length) { wrap.innerHTML = '<div class="empty">no zone data</div>'; return wrap; }
    const deltaByZone = {};
    if (Array.isArray(deltas)) deltas.forEach(d => { if (d && d.zone) deltaByZone[d.zone] = d; });
    const tbl = document.createElement('table');
    tbl.innerHTML = `
      <thead><tr>
        <th>Zone</th>
        <th class="num">Qty</th>
        <th class="num">Δ qty 24h</th>
        <th class="num">Median</th>
        <th class="num">Δ% 24h</th>
        <th class="num">Ours qty</th>
        <th class="num">Ours %</th>
      </tr></thead><tbody></tbody>`;
    const tb = tbl.querySelector('tbody');
    rows.slice(0, 30).forEach(r => {
      const tr = document.createElement('tr');
      const ourPct = (r.owned_share !== null && r.owned_share !== undefined)
        ? T.fmtPct(r.owned_share * 100, 0) : '—';
      const d = deltaByZone[r.zone];
      const dQtyCell = d && d.delta_tix_abs != null
        ? `<span class="${d.delta_tix_abs > 0 ? 'pos' : d.delta_tix_abs < 0 ? 'neg' : 'muted'}">${d.delta_tix_abs >= 0 ? '+' : ''}${T.fmtNum(d.delta_tix_abs)}</span>`
        : '—';
      const dMedCell = d && d.delta_median_pct != null
        ? `<span class="${d.delta_median_pct > 0 ? 'pos' : d.delta_median_pct < 0 ? 'neg' : 'muted'}">${d.delta_median_pct >= 0 ? '+' : ''}${Number(d.delta_median_pct).toFixed(1)}%</span>`
        : '—';
      tr.innerHTML = `
        <td class="zone-name">${escapeHtml(r.zone || '—')}</td>
        <td class="num">${T.fmtNum(r.tickets_count)}</td>
        <td class="num">${dQtyCell}</td>
        <td class="num">$${T.fmtNum(r.retail_median, { max: 0 })}</td>
        <td class="num">${dMedCell}</td>
        <td class="num ours">${T.fmtNum(r.owned_tickets_count)}</td>
        <td class="num ours">${ourPct}</td>`;
      tb.appendChild(tr);
    });
    wrap.appendChild(tbl);
    return wrap;
  }

  function buildSgZonesTable(sgZones) {
    const wrap = document.createElement('div');
    if (sgZones === undefined) { wrap.innerHTML = '<div class="empty">loading SG…</div>'; return wrap; }
    if (sgZones === null || sgZones.hidden) {
      const reason = sgZones && sgZones.reason === 'no_sg_bridge' ? 'no SG bridge for this event' : 'SG unavailable';
      wrap.innerHTML = `<div class="empty">${escapeHtml(reason)}</div>`; return wrap;
    }
    const rows = sgZones.zones || [];
    if (!rows.length) { wrap.innerHTML = '<div class="empty">no SG section data (last 24h)</div>'; return wrap; }
    const tbl = document.createElement('table');
    tbl.innerHTML = `
      <thead><tr>
        <th>Section</th>
        <th class="num">Listings</th>
        <th class="num">Tickets</th>
        <th class="num">Min</th>
        <th class="num">Median</th>
        <th class="num">Max</th>
        <th class="num">Owned</th>
      </tr></thead><tbody></tbody>`;
    const tb = tbl.querySelector('tbody');
    rows.slice(0, 30).forEach(r => {
      const tr = document.createElement('tr');
      tr.innerHTML = `
        <td class="zone-name">${escapeHtml(r.section || '—')}</td>
        <td class="num">${T.fmtNum(r.listings)}</td>
        <td class="num">${T.fmtNum(r.tickets)}</td>
        <td class="num">${r.min != null ? '$' + T.fmtNum(Math.round(r.min)) : '—'}</td>
        <td class="num">${r.median != null ? '$' + T.fmtNum(Math.round(r.median)) : '—'}</td>
        <td class="num">${r.max != null ? '$' + T.fmtNum(Math.round(r.max)) : '—'}</td>
        <td class="num ${r.owned_listings > 0 ? 'ours' : ''}">${T.fmtNum(r.owned_listings)}</td>`;
      tb.appendChild(tr);
    });
    wrap.appendChild(tbl);
    return wrap;
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

  // ---------- Weather (localized via get_event_weather_localized) ----------
  //
  // Renders the full weather panel + the compact hero card. RPC returns:
  //   forecast: { temp_f, summary, precip_pct, precip_in, wind_mph,
  //               weather_kind, days_to_event, is_indoor }
  //   alerts:   [{ alert_id, severity, urgency, alert_event, headline,
  //                area_desc, onset_at, expires_at, matched_zone_kind }]
  // weather_kind in {'none','forecast_indoor','forecast_outdoor','climatology_outdoor'}.

  function renderWeather(d) {
    const section = document.getElementById('weather');
    const body = document.getElementById('weatherBody');
    const subtitle = document.getElementById('weatherSubtitle');
    if (!body) return;
    body.innerHTML = '';
    const f = (d && d.forecast) || null;
    const alerts = (d && d.alerts) || [];
    if (!f && !alerts.length) {
      if (section) section.style.display = 'none';
      return;
    }
    if (section) section.style.display = '';
    if (subtitle) {
      const dte = (f && f.days_to_event != null) ? `T-${f.days_to_event}d` : '';
      const kind = (f && f.weather_kind && f.weather_kind !== 'none') ? f.weather_kind.replace(/_/g, ' ') : '';
      subtitle.textContent = [dte, kind].filter(Boolean).join(' · ');
    }
    // Single forecast strip — single row card derived from the resolved
    // top-level fcst columns on v_event_weather_with_fallback.
    if (f && f.weather_kind !== 'none') {
      const fcWrap = document.createElement('div');
      fcWrap.className = 'wx-forecast';
      const kindLbl = f.weather_kind === 'climatology_outdoor'
        ? 'CLIMATOLOGY FALLBACK · OUTDOOR'
        : f.weather_kind === 'forecast_indoor'
        ? 'FORECAST · INDOOR (no outdoor signal)'
        : 'FORECAST · OUTDOOR';
      fcWrap.innerHTML = `<div class="wx-sublabel">${kindLbl}</div>`;
      const row = document.createElement('div');
      row.className = 'wx-row';
      const cell = document.createElement('div');
      cell.className = 'wx-cell';
      cell.innerHTML = `
        <div class="wx-temp">${f.temp_f != null ? Math.round(f.temp_f) + '°' : '—'}</div>
        <div class="wx-precip">${f.precip_pct != null ? Math.round(f.precip_pct) + '%' : '—'}${f.precip_in != null ? ` · ${Number(f.precip_in).toFixed(2)}"` : ''}</div>
        <div class="wx-wind">${f.wind_mph != null ? Math.round(f.wind_mph) + ' mph' : '—'}</div>
        <div class="wx-summary">${escapeHtml(f.summary || '')}</div>`;
      row.appendChild(cell);
      fcWrap.appendChild(row);
      body.appendChild(fcWrap);
    }
    if (alerts.length) {
      const aw = document.createElement('div');
      aw.className = 'wx-alerts';
      aw.innerHTML = `<div class="wx-sublabel">NWS ALERTS (${alerts.length}) · venue-scoped</div>`;
      const ul = document.createElement('ul');
      alerts.forEach(a => {
        const li = document.createElement('li');
        const sev = String(a.severity || '').toLowerCase();
        const sevCls = (sev === 'extreme' || sev === 'severe') ? 'neg' : (sev === 'moderate' ? 'warn' : 'muted');
        li.innerHTML = `<strong>${escapeHtml(a.alert_event || '')}</strong> <span class="${sevCls}">${escapeHtml(a.severity || '')}</span> · <span class="muted">expires ${T.fmtDate(a.expires_at)}</span> — ${escapeHtml(a.headline || '')} <span class="muted small">[${escapeHtml(a.matched_zone_kind || '')}]</span>`;
        ul.appendChild(li);
      });
      aw.appendChild(ul);
      body.appendChild(aw);
    } else {
      const noneEl = document.createElement('div');
      noneEl.className = 'muted small';
      noneEl.style.marginTop = '8px';
      noneEl.textContent = 'no active NWS alerts for venue';
      body.appendChild(noneEl);
    }
  }

  function renderHeroWeather(forecast) {
    const host = document.getElementById('hero-weather');
    if (!host) return;
    if (!forecast || forecast.weather_kind === 'none' || forecast.weather_kind === 'forecast_indoor' || forecast.temp_f == null) {
      host.setAttribute('hidden', '');
      return;
    }
    host.removeAttribute('hidden');
    const tEl = document.getElementById('hwTemp');
    const sEl = document.getElementById('hwSummary');
    const pEl = document.getElementById('hwPrecip');
    const wEl = document.getElementById('hwWind');
    const kEl = document.getElementById('hwKindBadge');
    if (tEl) tEl.textContent = Math.round(forecast.temp_f);
    if (sEl) sEl.textContent = forecast.summary || '—';
    if (pEl) pEl.textContent = forecast.precip_pct != null ? Math.round(forecast.precip_pct) + '% precip' : '—';
    if (wEl) wEl.textContent = forecast.wind_mph != null ? Math.round(forecast.wind_mph) + ' mph' : '—';
    if (kEl) {
      if (forecast.weather_kind === 'climatology_outdoor') {
        kEl.removeAttribute('hidden');
        kEl.textContent = 'climo';
      } else {
        kEl.setAttribute('hidden', '');
      }
    }
  }

  // ---------- All Orders (unified — EVO + TickPick + Vivid) ----------
  //
  // Replaces the legacy #order-strip (EVO state-mix bar) + #cross-source-orders
  // (TP+Vivid separate panel). Single sortable table with a Source column.
  // Shows ALL order states (pending/accepted/completed/rejected/etc.), not
  // just pending. Sorted by created_at DESC, capped 30.

  function renderAllOrders(orders, crossSource) {
    const body = document.getElementById('allOrdersBody');
    const countEl = document.getElementById('allOrdersCount');
    if (!body) return;
    const rows = [];
    // EVO line-items
    const items   = (orders && orders.items) || [];
    const ordList = (orders && orders.orders) || [];
    const stateById = new Map(ordList.map(o => [o.evo_order_id, o]));
    items.forEach(it => {
      const o = stateById.get(it.evo_order_id) || {};
      rows.push({
        source: 'evo',
        order_id: it.evo_order_id,
        status: o.state || 'unknown',
        section: it.ticket_group_section || it.section,
        row:     it.ticket_group_row     || it.row,
        quantity: it.quantity,
        total:    it.price != null && it.quantity != null ? Number(it.price) * Number(it.quantity) : null,
        created_at: o.evo_created_at || o.evo_updated_at || it.pulled_at,
      });
    });
    // TickPick
    ((crossSource && crossSource.tickpick) || []).forEach(o => {
      rows.push({
        source: 'tickpick',
        order_id: o.tp_order_id || o.order_id,
        status: o.status || o.order_status || 'unknown',
        section: o.section, row: o.row,
        quantity: o.quantity,
        total: o.total,
        created_at: o.ordered_at,
      });
    });
    // Vivid
    ((crossSource && crossSource.vivid) || []).forEach(o => {
      rows.push({
        source: 'vivid',
        order_id: o.vivid_order_id || o.order_id,
        status: o.status || 'unknown',
        section: o.section, row: o.row,
        quantity: o.quantity,
        total: o.total,
        created_at: o.ordered_at,
      });
    });
    rows.sort((a, b) => {
      const ta = a.created_at ? new Date(a.created_at).getTime() : 0;
      const tb = b.created_at ? new Date(b.created_at).getTime() : 0;
      return tb - ta;
    });
    if (countEl) {
      const evoN = rows.filter(r => r.source === 'evo').length;
      const tpN  = rows.filter(r => r.source === 'tickpick').length;
      const vvN  = rows.filter(r => r.source === 'vivid').length;
      const parts = [];
      if (evoN) parts.push(`EVO ${evoN}`);
      if (tpN)  parts.push(`TP ${tpN}`);
      if (vvN)  parts.push(`Vivid ${vvN}`);
      if (rows.length) parts.push(`· ${rows.length} total`);
      countEl.textContent = parts.join(' · ');
    }
    body.innerHTML = '';
    if (!rows.length) {
      body.innerHTML = '<div class="empty">no orders for this event from any source</div>';
      return;
    }
    const tbl = document.createElement('table');
    tbl.className = 'orders-tbl';
    tbl.innerHTML = `
      <thead><tr>
        <th>Source</th><th>Order</th><th>Status</th>
        <th>Section</th><th>Row</th>
        <th class="num">Qty</th><th class="num">Total</th>
        <th>Created</th>
      </tr></thead><tbody></tbody>`;
    const tb = tbl.querySelector('tbody');
    rows.slice(0, 30).forEach(r => {
      const tr = document.createElement('tr');
      const statusCls = r.status ? 'status-' + String(r.status).toLowerCase().replace(/[^a-z0-9]+/g, '-') : '';
      const srcCls = 'src-' + r.source;
      tr.innerHTML = `
        <td><span class="src-pill ${srcCls}">${escapeHtml(r.source)}</span></td>
        <td>${escapeHtml(String(r.order_id || '—'))}</td>
        <td><span class="status-pill ${statusCls}">${escapeHtml(r.status || '—')}</span></td>
        <td>${escapeHtml(r.section || '—')}</td>
        <td>${escapeHtml(r.row || '—')}</td>
        <td class="num">${T.fmtNum(r.quantity)}</td>
        <td class="num">${r.total != null ? '$' + T.fmtNum(Math.round(r.total)) : '—'}</td>
        <td class="muted">${T.fmtDate(r.created_at)}</td>`;
      tb.appendChild(tr);
    });
    body.appendChild(tbl);
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

  // ============================================================
  // v3 enrichment renderers (PR pending; v3 RPC adds 6 new panels)
  // ============================================================

  // ---------- SG broker sales aggregate ----------
  function renderSgBrokerSales(s) {
    const section = document.getElementById('sg-broker-sales');
    const body = document.getElementById('sgBrokerSalesBody');
    if (!body) return;
    if (!s || s.hidden) {
      if (section) section.style.display = 'none';
      return;
    }
    if (section) section.style.display = '';
    const gmv = Number(s.gross_estimate) || 0;
    const tix = Number(s.tickets_sold) || 0;
    const sales = Number(s.sales_count) || 0;
    const avgPx = sales ? Math.round(gmv / Math.max(tix, 1)) : null;
    body.innerHTML = `
      <div class="kpi-strip">
        <div class="kpi-strip-cell"><span class="kpi-lbl">SALES</span><span class="kpi-val">${T.fmtNum(sales)}</span></div>
        <div class="kpi-strip-cell"><span class="kpi-lbl">TIX SOLD</span><span class="kpi-val">${T.fmtNum(tix)}</span></div>
        <div class="kpi-strip-cell"><span class="kpi-lbl">EST GMV</span><span class="kpi-val">$${T.fmtNum(Math.round(gmv))}</span></div>
        <div class="kpi-strip-cell"><span class="kpi-lbl">MIN</span><span class="kpi-val">${s.min_sale_price != null ? '$' + T.fmtNum(Math.round(s.min_sale_price)) : '—'}</span></div>
        <div class="kpi-strip-cell"><span class="kpi-lbl">MEDIAN</span><span class="kpi-val">${s.median_sale_price != null ? '$' + T.fmtNum(Math.round(s.median_sale_price)) : '—'}</span></div>
        <div class="kpi-strip-cell"><span class="kpi-lbl">MAX</span><span class="kpi-val">${s.max_sale_price != null ? '$' + T.fmtNum(Math.round(s.max_sale_price)) : '—'}</span></div>
        <div class="kpi-strip-cell"><span class="kpi-lbl">SECTIONS</span><span class="kpi-val">${T.fmtNum(s.distinct_sections)}</span></div>
        <div class="kpi-strip-cell"><span class="kpi-lbl">LATEST</span><span class="kpi-val small">${T.fmtDate(s.latest_sale_at)}</span></div>
      </div>`;
  }

  // (renderSgListingsSummary removed — deprecated cost_* fields per operator
  // metrics inventory; CROSS-SOURCE METRICS panel covers the SG ask
  // distribution via listings_all_* from PR #204.)


  // ---------- Velocity chips (inline strip) ----------
  function renderVelocityChips(v) {
    const host = document.getElementById('velocityChips');
    if (!host) return;
    if (!v || v.hidden) {
      host.innerHTML = '<span class="muted small">velocity n/a</span>';
      return;
    }
    function chip(label, delta, fmt) {
      if (delta == null || delta === 0) return '';
      const positive = delta > 0;
      const cls = positive ? 'pos' : 'neg';
      const fmtVal = fmt === 'pct' ? (delta >= 0 ? '+' : '') + delta.toFixed(1) + '%'
                   : (delta >= 0 ? '+' : '') + T.fmtNum(Math.abs(delta), { max: 0 });
      return `<span class="velocity-chip ${cls}">${label}: ${fmtVal}</span>`;
    }
    host.innerHTML = [
      chip('TEvo tix 1h', v.tevo_tix_d1h),
      chip('TEvo tix 24h', v.tevo_tix_d24h),
      chip('TEvo getin 24h', v.tevo_getin_d24h_pct, 'pct'),
      chip('SG getin 24h', v.sg_getin_d24h),
    ].filter(Boolean).join('') || '<span class="muted small">no movement detected in window</span>';
  }

  // ---------- Competing events ----------
  function renderCompetingEvents(c) {
    const body = document.getElementById('competingEventsBody');
    if (!body) return;
    if (!c || !c.events || c.events.length === 0) {
      body.innerHTML = '<div class="empty">no competing events within +/-24h / 20mi</div>';
      return;
    }
    const ul = document.createElement('ul');
    ul.className = 'competing-list';
    c.events.slice(0, 10).forEach(e => {
      const li = document.createElement('li');
      const eid = e.event_id || e.id;
      const name = e.name || e.event_name || ('Event ' + eid);
      const dist = e.distance_miles != null ? `${Number(e.distance_miles).toFixed(1)}mi` : '';
      const venue = e.venue_name || e.venue || '';
      const when = T.fmtDate(e.occurs_at_local || e.occurs_at || e.starts_at);
      li.innerHTML = `<a href="event.html?event=${eid}">${escapeHtml(name)}</a> <span class="muted">${escapeHtml(venue)}${venue && dist ? ' · ' : ''}${dist} · ${escapeHtml(when)}</span>`;
      ul.appendChild(li);
    });
    body.innerHTML = '';
    body.appendChild(ul);
  }

  // ---------- Recent TEvo listings (firehose snippet) ----------
  function renderRecentListings(rows) {
    const body = document.getElementById('recentListingsBody');
    if (!body) return;
    if (!rows || !rows.length) {
      body.innerHTML = '<div class="empty">no listings in last 24h</div>';
      return;
    }
    const tbl = document.createElement('table');
    tbl.className = 'recent-listings-tbl';
    tbl.innerHTML = `
      <thead><tr>
        <th>Captured</th><th>Section</th><th>Row</th>
        <th class="num">Qty</th><th class="num">Retail</th><th>Source</th>
      </tr></thead><tbody></tbody>`;
    const tb = tbl.querySelector('tbody');
    rows.forEach(r => {
      const tr = document.createElement('tr');
      const sourceLabel = r.is_owned ? 'ours' : (r.brokerage_name || 'market');
      tr.innerHTML = `
        <td>${T.fmtDate(r.captured_at)}</td>
        <td>${escapeHtml(r.section || '—')}</td>
        <td>${escapeHtml(r.row || '—')}</td>
        <td class="num">${T.fmtNum(r.quantity)}</td>
        <td class="num">${r.retail_price != null ? '$' + T.fmtNum(Math.round(r.retail_price)) : '—'}</td>
        <td class="${r.is_owned ? 'ours' : 'muted'}">${escapeHtml(sourceLabel)}</td>`;
      tb.appendChild(tr);
    });
    body.innerHTML = '';
    body.appendChild(tbl);
  }

  // (renderCrossSourceOrders removed — folded into renderAllOrders which
  // unifies EVO + TickPick + Vivid into a single sortable table.)


  // ---------- Performer ESPN context (next 5 games) ----------
  function renderPerformerEspn(ctx, performer) {
    const section = document.getElementById('performer-espn');
    const body = document.getElementById('performerEspnBody');
    if (!body) return;
    if (!ctx || ctx.hidden) {
      if (section) section.style.display = 'none';
      return;
    }
    if (!Array.isArray(ctx) || ctx.length === 0) {
      // ctx could be the raw array OR wrapped — handle both
      const arr = Array.isArray(ctx) ? ctx : (ctx.events || []);
      if (!arr.length) {
        if (section) section.style.display = 'none';
        return;
      }
    }
    if (section) section.style.display = '';
    const arr = Array.isArray(ctx) ? ctx : (ctx.events || []);
    const teamId = (performer && performer.espn_team_id) || '';
    const league = (performer && performer.espn_league) || '';
    body.innerHTML = `<div class="muted small">${escapeHtml(league)}${teamId ? ` · team ${escapeHtml(teamId)}` : ''} — next ${arr.length} games (this event has no ESPN xref)</div>`;
    const ul = document.createElement('ul');
    ul.className = 'performer-espn-list';
    arr.slice(0, 5).forEach(g => {
      const li = document.createElement('li');
      const opp = g.is_home ? g.away_team_id : g.home_team_id;
      const venueHint = g.is_home ? 'HOME' : '@';
      li.innerHTML = `<span class="muted">${T.fmtDate(g.game_at_utc)}</span> ${venueHint} <strong>${escapeHtml(opp || '?')}</strong> <span class="muted small">${escapeHtml(g.status_short || '')}</span>`;
      ul.appendChild(li);
    });
    body.appendChild(ul);
  }

  // ============================================================
  // v3 extensions to existing renderers (hero/kpi/zones/orders)
  // ============================================================

  // renderHero — extended in-place via renderHeroV3Branding hook
  function renderHeroV3Branding(performer) {
    if (!performer || performer.hidden) return;
    const logoUrl = performer.logo_default_url || performer.logo_dark_url || performer.logo_4k_primary_url;
    if (logoUrl) {
      let img = document.getElementById('heroPerformerLogo');
      if (!img) {
        img = document.createElement('img');
        img.id = 'heroPerformerLogo';
        img.className = 'hero-performer-logo';
        img.alt = performer.name || 'performer';
        const heroMain = document.querySelector('.hero-main');
        if (heroMain) heroMain.insertBefore(img, heroMain.firstChild);
      }
      img.src = logoUrl;
    }
    if (performer.color_primary) {
      const hero = document.getElementById('hero');
      if (hero) hero.style.borderLeft = `4px solid ${performer.color_primary}`;
    }
    // Add a league badge to the existing badges row
    if (performer.espn_league) {
      const badges = document.getElementById('evBadges');
      if (badges && !badges.querySelector('.badge.league')) {
        const b = document.createElement('span');
        b.className = 'badge league';
        b.textContent = String(performer.espn_league).toUpperCase();
        badges.appendChild(b);
      }
    }
  }

  // ============================================================
  // Tab navigation + lazy-load (Phase 2a Tabs — mig 20260517180000)
  // ============================================================
  const _tabState = { loaded: {
    'sg-listings': false, 'evo-listings': false, 'sg-sales': false,
    'our-orders': false,
  } };

  function wireTabs(eventId) {
    const nav = document.getElementById('eventTabs');
    if (!nav) return;
    nav.addEventListener('click', async (e) => {
      const btn = e.target.closest('.event-tab');
      if (!btn) return;
      const tabId = btn.dataset.tab;
      activateTab(tabId);
      if (tabId === 'sg-listings' && !_tabState.loaded['sg-listings']) {
        await loadSgListingsFull(eventId);
      } else if (tabId === 'evo-listings' && !_tabState.loaded['evo-listings']) {
        await loadEvoListingsFull(eventId);
      } else if (tabId === 'sg-sales' && !_tabState.loaded['sg-sales']) {
        await loadSgSalesFull(eventId);
      } else if (tabId === 'our-orders' && !_tabState.loaded['our-orders']) {
        // Merged tab — fire all 3 broker-order RPCs in parallel, render each
        // into its own stacked sub-section inside #paneOurOrders.
        _tabState.loaded['our-orders'] = true;
        await Promise.all([
          loadEvoOrdersFull(eventId),
          loadSgSellerOrdersFull(eventId),
          loadCrossBrokerFull(eventId),
        ]);
        updateOurOrdersTabCount();
      }
    });
  }

  function activateTab(tabId) {
    document.querySelectorAll('.event-tab').forEach(b => {
      const on = b.dataset.tab === tabId;
      b.classList.toggle('active', on);
      b.setAttribute('aria-selected', on ? 'true' : 'false');
    });
    const paneIds = {
      'overview':     'paneOverview',
      'sg-listings':  'paneSgListings',
      'evo-listings': 'paneEvoListings',
      'sg-sales':     'paneSgSales',
      'our-orders':   'paneOurOrders',
    };
    Object.entries(paneIds).forEach(([id, paneId]) => {
      const pane = document.getElementById(paneId);
      if (!pane) return;
      if (id === tabId) {
        pane.removeAttribute('hidden');
        pane.classList.add('active');
      } else {
        pane.setAttribute('hidden', '');
        pane.classList.remove('active');
      }
    });
  }

  // Aggregate the 3 sub-section counts into the merged Our Orders tab chip.
  function updateOurOrdersTabCount() {
    const chip = document.getElementById('tabCountOurOrders');
    if (!chip) return;
    const evo  = parseInt(document.getElementById('tabCountEvoOrders')?.textContent || '0', 10) || 0;
    const sg   = parseInt(document.getElementById('tabCountSgSellerOrders')?.textContent || '0', 10) || 0;
    const xb   = parseInt(document.getElementById('tabCountCrossBroker')?.textContent || '0', 10) || 0;
    const total = evo + sg + xb;
    chip.textContent = total ? String(total) : '';
  }

  function wireSalesWindow(eventId) {
    const sel = document.getElementById('sgSalesWindow');
    if (!sel) return;
    sel.addEventListener('change', async () => {
      _tabState.loaded['sg-sales'] = false;
      const body = document.getElementById('sgSalesFullBody');
      if (body) body.innerHTML = '<div class="empty">Loading…</div>';
      await loadSgSalesFull(eventId);
    });
  }

  async function rpcOrNull(rpcName, args) {
    const Auth = window.TerminalAuth;
    if (!Auth || !Auth.client || !Auth.getAccessToken()) {
      return { error: { message: 'no auth — Path C unavailable (localhost dev)' } };
    }
    return Auth.client.rpc(rpcName, args);
  }

  // ---------- SG Listings (full) ----------
  async function loadSgListingsFull(eventId) {
    const body = document.getElementById('sgListingsFullBody');
    const meta = document.getElementById('sgListingsFullMeta');
    if (body) body.innerHTML = '<div class="empty">Loading SG listings…</div>';
    if (meta) meta.textContent = 'loading…';
    const t0 = performance.now();
    // Omit p_limit — RPC default is now 100000 (mig 20260518030000), surfaces all rows.
    const res = await rpcOrNull('get_event_sg_listings_full', { p_event_id: eventId });
    if (res.error) {
      if (meta) meta.textContent = 'error';
      if (body) body.innerHTML = `<div class="empty">RPC error: ${escapeHtml(res.error.message || '')}</div>`;
      return;
    }
    _tabState.loaded['sg-listings'] = true;
    renderSgListingsFull(res.data, performance.now() - t0);
  }

  function renderSgListingsFull(d, ms) {
    const body = document.getElementById('sgListingsFullBody');
    const meta = document.getElementById('sgListingsFullMeta');
    const countChip = document.getElementById('tabCountSgListings');
    if (!body) return;
    if (!d || d.hidden) {
      const reason = d && d.reason === 'no_sg_bridge' ? 'no SG bridge for this event' : 'hidden';
      body.innerHTML = `<div class="empty">${escapeHtml(reason)}</div>`;
      if (meta) meta.textContent = '0 rows';
      if (countChip) countChip.textContent = '0';
      return;
    }
    const rows = d.rows || [];
    if (meta) meta.textContent = `${rows.length} rows · ${ms.toFixed(0)}ms · sg_event_id ${d.sg_event_id}`;
    if (countChip) countChip.textContent = String(rows.length);
    if (!rows.length) {
      body.innerHTML = '<div class="empty">no SG listings in last 7 days</div>';
      return;
    }
    const host = document.createElement('div');
    host.className = 'full-list-host';
    const tbl = document.createElement('table');
    tbl.className = 'full-list-tbl';
    tbl.innerHTML = `
      <thead><tr>
        <th>Captured</th><th>Section</th><th>Row</th>
        <th class="num">Qty</th><th class="num">Retail (all-in)</th><th class="num">Bcst</th>
        <th>Stock</th><th>Delivery</th><th>Splits</th><th>In-hand</th>
        <th>Source</th><th>Type</th>
      </tr></thead><tbody></tbody>`;
    const tb = tbl.querySelector('tbody');
    rows.forEach(r => {
      const tr = document.createElement('tr');
      if (r.is_broker_owned) tr.className = 'owned-row';
      tr.innerHTML = `
        <td>${T.fmtDate(r.captured_at)}</td>
        <td>${escapeHtml(r.section || '—')}</td>
        <td>${escapeHtml(r.row || '—')}</td>
        <td class="num">${T.fmtNum(r.quantity)}</td>
        <td class="num">${r.retail_price_all_in != null ? '$' + T.fmtNum(Math.round(r.retail_price_all_in)) : '—'}</td>
        <td class="num">${r.broadcast_price != null ? '$' + T.fmtNum(Math.round(r.broadcast_price)) : '—'}</td>
        <td>${escapeHtml(r.stock_type || '—')}</td>
        <td>${escapeHtml(r.delivery_method || '—')}${r.is_instant_download ? ' <span class="pill">instant</span>' : ''}</td>
        <td>${escapeHtml(Array.isArray(r.splits) ? r.splits.join(',') : (r.splits || '—'))}</td>
        <td>${r.in_hand_date ? T.fmtDate(r.in_hand_date) : '—'}</td>
        <td>${escapeHtml(r.market_source || '—')}</td>
        <td>${r.is_broker_owned ? '<span class="pill broker">broker</span>' : '<span class="pill market">market</span>'}</td>`;
      tb.appendChild(tr);
    });
    host.appendChild(tbl);
    body.innerHTML = '';
    body.appendChild(host);
  }

  // ---------- EVO Listings (full) ----------
  async function loadEvoListingsFull(eventId) {
    const body = document.getElementById('evoListingsFullBody');
    const meta = document.getElementById('evoListingsFullMeta');
    if (body) body.innerHTML = '<div class="empty">Loading EVO listings…</div>';
    if (meta) meta.textContent = 'loading…';
    const t0 = performance.now();
    // Omit p_limit — RPC default 100000 (mig 20260518030000).
    const res = await rpcOrNull('get_event_evo_listings_full', { p_event_id: eventId });
    if (res.error) {
      if (meta) meta.textContent = 'error';
      if (body) body.innerHTML = `<div class="empty">RPC error: ${escapeHtml(res.error.message || '')}</div>`;
      return;
    }
    _tabState.loaded['evo-listings'] = true;
    renderEvoListingsFull(res.data, performance.now() - t0);
  }

  function renderEvoListingsFull(d, ms) {
    const body = document.getElementById('evoListingsFullBody');
    const meta = document.getElementById('evoListingsFullMeta');
    const countChip = document.getElementById('tabCountEvoListings');
    if (!body) return;
    const rows = (d && d.rows) || [];
    if (meta) meta.textContent = `${rows.length} rows · ${ms.toFixed(0)}ms`;
    if (countChip) countChip.textContent = String(rows.length);
    if (!rows.length) {
      body.innerHTML = '<div class="empty">no EVO listings in last 7 days</div>';
      return;
    }
    const ownedCount = rows.filter(r => r.is_owned).length;
    const host = document.createElement('div');
    host.className = 'full-list-host';
    const tbl = document.createElement('table');
    tbl.className = 'full-list-tbl';
    tbl.innerHTML = `
      <thead><tr>
        <th>Captured</th><th>Section</th><th>Row</th>
        <th class="num">Qty</th><th class="num">Retail</th><th class="num">Wholesale</th>
        <th class="num">Δ Retail</th><th class="num">Δ Qty</th>
        <th>Format</th><th>Splits</th><th>Type</th>
        <th>Brokerage</th><th>Office</th><th>Flags</th>
      </tr></thead><tbody></tbody>`;
    const tb = tbl.querySelector('tbody');
    rows.forEach(r => {
      const tr = document.createElement('tr');
      if (r.is_owned) tr.className = 'owned-row';
      const dRetail = (r.prev_retail_price != null && r.retail_price != null)
        ? (Number(r.retail_price) - Number(r.prev_retail_price)) : null;
      const dQty = (r.prev_quantity != null && r.quantity != null)
        ? (Number(r.quantity) - Number(r.prev_quantity)) : null;
      const dRetailHtml = dRetail == null ? '—'
        : `<span class="${dRetail >= 0 ? 'pos' : 'neg'}">${dRetail >= 0 ? '+' : ''}$${T.fmtNum(Math.round(dRetail))}</span>`;
      const dQtyHtml = dQty == null ? '—'
        : `<span class="${dQty >= 0 ? 'pos' : 'neg'}">${dQty >= 0 ? '+' : ''}${dQty}</span>`;
      const flags = [];
      if (r.is_ancillary) flags.push('ancillary');
      if (r.instant_delivery) flags.push('instant');
      if (r.eticket) flags.push('eticket');
      tr.innerHTML = `
        <td>${T.fmtDate(r.captured_at)}</td>
        <td>${escapeHtml(r.section || '—')}</td>
        <td>${escapeHtml(r.row || '—')}</td>
        <td class="num">${T.fmtNum(r.quantity)}</td>
        <td class="num">${r.retail_price != null ? '$' + T.fmtNum(Math.round(r.retail_price)) : '—'}</td>
        <td class="num">${r.wholesale_price != null ? '$' + T.fmtNum(Math.round(r.wholesale_price)) : '—'}</td>
        <td class="num">${dRetailHtml}</td>
        <td class="num">${dQtyHtml}</td>
        <td>${escapeHtml(r.format || '—')}</td>
        <td>${escapeHtml(Array.isArray(r.splits) ? r.splits.join(',') : (r.splits || '—'))}</td>
        <td>${escapeHtml(r.type || '—')}</td>
        <td>${escapeHtml(r.brokerage_name || (r.brokerage_id != null ? String(r.brokerage_id) : '—'))}</td>
        <td>${escapeHtml(r.office_name || '—')}</td>
        <td>${r.is_owned ? '<span class="pill owned">ours</span>' : flags.map(f => `<span class="pill">${f}</span>`).join(' ') || '<span class="pill market">market</span>'}</td>`;
      tb.appendChild(tr);
    });
    host.appendChild(tbl);
    body.innerHTML = '';
    body.appendChild(host);
    if (meta) meta.textContent = `${rows.length} rows (${ownedCount} ours) · ${ms.toFixed(0)}ms`;
  }

  // ---------- SG Sales (full) ----------
  async function loadSgSalesFull(eventId) {
    const body = document.getElementById('sgSalesFullBody');
    const meta = document.getElementById('sgSalesFullMeta');
    const sel = document.getElementById('sgSalesWindow');
    const windowDays = sel ? (parseInt(sel.value, 10) || 30) : 30;
    if (body) body.innerHTML = '<div class="empty">Loading SG sales…</div>';
    if (meta) meta.textContent = 'loading…';
    const t0 = performance.now();
    // Omit p_limit — RPC default 100000 (mig 20260518030000); keep window selector.
    const res = await rpcOrNull('get_event_sg_sales_full', {
      p_event_id: eventId, p_window_days: windowDays
    });
    if (res.error) {
      if (meta) meta.textContent = 'error';
      if (body) body.innerHTML = `<div class="empty">RPC error: ${escapeHtml(res.error.message || '')}</div>`;
      return;
    }
    _tabState.loaded['sg-sales'] = true;
    renderSgSalesFull(res.data, performance.now() - t0, windowDays);
  }

  function renderSgSalesFull(d, ms, windowDays) {
    const body = document.getElementById('sgSalesFullBody');
    const meta = document.getElementById('sgSalesFullMeta');
    const countChip = document.getElementById('tabCountSgSales');
    if (!body) return;
    if (!d || d.hidden) {
      const reason = d && d.reason === 'no_sg_bridge' ? 'no SG bridge for this event' : 'hidden';
      body.innerHTML = `<div class="empty">${escapeHtml(reason)}</div>`;
      if (meta) meta.textContent = '0 rows';
      if (countChip) countChip.textContent = '0';
      return;
    }
    const rows = d.rows || [];
    if (meta) meta.textContent = `${rows.length} rows · ${ms.toFixed(0)}ms · ${windowDays}d window · sg_event_id ${d.sg_event_id}`;
    if (countChip) countChip.textContent = String(rows.length);
    if (!rows.length) {
      body.innerHTML = `<div class="empty">no SG sales in last ${windowDays} days</div>`;
      return;
    }
    const host = document.createElement('div');
    host.className = 'full-list-host';
    const tbl = document.createElement('table');
    tbl.className = 'full-list-tbl';
    tbl.innerHTML = `
      <thead><tr>
        <th>Sold</th><th>Pulled</th><th>Section</th><th>Row</th>
        <th class="num">Qty</th><th class="num">Bcst Price</th>
        <th>Stock</th><th class="num">Days→Event</th>
      </tr></thead><tbody></tbody>`;
    const tb = tbl.querySelector('tbody');
    rows.forEach(r => {
      const tr = document.createElement('tr');
      tr.innerHTML = `
        <td>${T.fmtDate(r.sale_at_utc)}</td>
        <td class="muted">${T.fmtDate(r.pulled_at)}</td>
        <td>${escapeHtml(r.section || '—')}</td>
        <td>${escapeHtml(r.row || '—')}</td>
        <td class="num">${T.fmtNum(r.quantity)}</td>
        <td class="num">${r.broadcast_price != null ? '$' + T.fmtNum(Math.round(r.broadcast_price)) : '—'}</td>
        <td>${escapeHtml(r.stock_type || '—')}</td>
        <td class="num">${r.days_to_event_at_sale != null ? T.fmtNum(r.days_to_event_at_sale) : '—'}</td>`;
      tb.appendChild(tr);
    });
    host.appendChild(tbl);
    body.innerHTML = '';
    body.appendChild(host);
  }

  // ---------- Our TEvo Orders (full) ----------
  async function loadEvoOrdersFull(eventId) {
    const body = document.getElementById('evoOrdersFullBody');
    const meta = document.getElementById('evoOrdersFullMeta');
    if (body) body.innerHTML = '<div class="empty">Loading our TEvo orders…</div>';
    if (meta) meta.textContent = 'loading…';
    const t0 = performance.now();
    const res = await rpcOrNull('get_event_evo_orders_full', { p_event_id: eventId, p_limit: 500 });
    if (res.error) {
      if (meta) meta.textContent = 'error';
      if (body) body.innerHTML = `<div class="empty">RPC error: ${escapeHtml(res.error.message || '')}</div>`;
      return;
    }
    _tabState.loaded['evo-orders'] = true;
    renderEvoOrdersFull(res.data, performance.now() - t0);
  }

  function renderEvoOrdersFull(d, ms) {
    const body = document.getElementById('evoOrdersFullBody');
    const meta = document.getElementById('evoOrdersFullMeta');
    const countChip = document.getElementById('tabCountEvoOrders');
    if (!body) return;
    const rows = (d && d.rows) || [];
    const distinctOrders = (d && d.distinct_orders) || 0;
    if (meta) meta.textContent = `${rows.length} items · ${distinctOrders} orders · ${ms.toFixed(0)}ms`;
    if (countChip) countChip.textContent = String(distinctOrders);
    if (!rows.length) {
      body.innerHTML = '<div class="empty">no TEvo orders for this event</div>';
      return;
    }
    const host = document.createElement('div');
    host.className = 'full-list-host';
    const tbl = document.createElement('table');
    tbl.className = 'full-list-tbl';
    tbl.innerHTML = `
      <thead><tr>
        <th>Created</th><th>Order</th><th>State</th><th>Type</th>
        <th>Section</th><th>Row</th><th>Seats</th>
        <th class="num">Qty</th>
        <th class="num">Item $</th><th class="num">Retail</th><th class="num">Whsl</th>
        <th class="num">Total</th><th class="num">Fees</th>
        <th>Hold Expires</th>
        <th>Buyer Brokerage</th><th>Fraud</th>
      </tr></thead><tbody></tbody>`;
    const tb = tbl.querySelector('tbody');
    let lastOrderId = null;
    rows.forEach(r => {
      const tr = document.createElement('tr');
      const firstOfOrder = r.evo_order_id !== lastOrderId;
      lastOrderId = r.evo_order_id;
      const stateCls = r.state ? 'status-' + String(r.state).toLowerCase() : '';
      const seats = Array.isArray(r.ticket_group_seats) ? r.ticket_group_seats.join(',')
                  : (r.ticket_group_seats == null ? '' : JSON.stringify(r.ticket_group_seats));
      const holdExp = r.hold_expires_at ? T.fmtDate(r.hold_expires_at) : '—';
      tr.innerHTML = `
        <td>${firstOfOrder ? T.fmtDate(r.evo_created_at) : '<span class="muted">·</span>'}</td>
        <td>${firstOfOrder ? '<strong>' + escapeHtml(String(r.evo_order_id)) + '</strong>' : '<span class="muted">·</span>'}</td>
        <td>${firstOfOrder ? `<span class="pill ${stateCls}">${escapeHtml(r.state || '—')}</span>` : ''}</td>
        <td>${firstOfOrder ? escapeHtml(r.type || '—') : ''}</td>
        <td>${escapeHtml(r.ticket_group_section || '—')}</td>
        <td>${escapeHtml(r.ticket_group_row || '—')}</td>
        <td class="muted">${escapeHtml(seats)}</td>
        <td class="num">${T.fmtNum(r.item_quantity != null ? r.item_quantity : r.ticket_group_quantity)}</td>
        <td class="num">${r.item_price != null ? '$' + T.fmtNum(Math.round(r.item_price)) : '—'}</td>
        <td class="num">${r.ticket_group_retail_price != null ? '$' + T.fmtNum(Math.round(r.ticket_group_retail_price)) : '—'}</td>
        <td class="num">${r.ticket_group_wholesale_price != null ? '$' + T.fmtNum(Math.round(r.ticket_group_wholesale_price)) : '—'}</td>
        <td class="num">${firstOfOrder && r.total != null ? '$' + T.fmtNum(Math.round(r.total)) : ''}</td>
        <td class="num">${firstOfOrder && r.service_fee != null ? '$' + T.fmtNum(Math.round(r.service_fee)) : ''}</td>
        <td>${firstOfOrder ? holdExp : ''}</td>
        <td>${firstOfOrder ? escapeHtml(r.buyer_brokerage_name || '—') : ''}</td>
        <td>${firstOfOrder ? escapeHtml(r.fraud_check_status || '—') : ''}</td>`;
      tb.appendChild(tr);
    });
    host.appendChild(tbl);
    body.innerHTML = '';
    body.appendChild(host);
  }

  // ---------- Our SG SellerDirect Orders (full) ----------
  async function loadSgSellerOrdersFull(eventId) {
    const body = document.getElementById('sgSellerOrdersFullBody');
    const meta = document.getElementById('sgSellerOrdersFullMeta');
    if (body) body.innerHTML = '<div class="empty">Loading our SG SellerDirect orders…</div>';
    if (meta) meta.textContent = 'loading…';
    const t0 = performance.now();
    const res = await rpcOrNull('get_event_sg_seller_orders_full', { p_event_id: eventId, p_limit: 500 });
    if (res.error) {
      if (meta) meta.textContent = 'error';
      if (body) body.innerHTML = `<div class="empty">RPC error: ${escapeHtml(res.error.message || '')}</div>`;
      return;
    }
    _tabState.loaded['sg-seller-orders'] = true;
    renderSgSellerOrdersFull(res.data, performance.now() - t0);
  }

  function renderSgSellerOrdersFull(d, ms) {
    const body = document.getElementById('sgSellerOrdersFullBody');
    const meta = document.getElementById('sgSellerOrdersFullMeta');
    const countChip = document.getElementById('tabCountSgSellerOrders');
    if (!body) return;
    if (!d || d.hidden) {
      const reason = d && d.reason === 'no_sg_bridge' ? 'no SG bridge for this event' : 'hidden';
      body.innerHTML = `<div class="empty">${escapeHtml(reason)}</div>`;
      if (meta) meta.textContent = '0 rows';
      if (countChip) countChip.textContent = '0';
      return;
    }
    const rows = d.rows || [];
    if (meta) meta.textContent = `${rows.length} rows · ${ms.toFixed(0)}ms · sg_event_id ${d.sg_event_id}`;
    if (countChip) countChip.textContent = String(rows.length);
    if (!rows.length) {
      body.innerHTML = '<div class="empty">no SG SellerDirect orders for this event</div>';
      return;
    }
    const host = document.createElement('div');
    host.className = 'full-list-host';
    const tbl = document.createElement('table');
    tbl.className = 'full-list-tbl';
    tbl.innerHTML = `
      <thead><tr>
        <th>Created (SG)</th><th>Order</th><th>Status</th>
        <th>Section</th><th>Row</th>
        <th class="num">Qty</th><th class="num">Sale $</th>
        <th class="num">Payment Total</th><th class="num">Fees</th><th class="num">Tax</th>
        <th>Delivery</th><th>Stock</th>
        <th>Pulled</th>
      </tr></thead><tbody></tbody>`;
    const tb = tbl.querySelector('tbody');
    rows.forEach(r => {
      const tr = document.createElement('tr');
      const statusCls = r.status ? 'status-' + String(r.status).toLowerCase() : '';
      tr.innerHTML = `
        <td>${T.fmtDate(r.created_at_sg)}</td>
        <td><strong>${escapeHtml(String(r.sg_order_id || '—'))}</strong></td>
        <td><span class="pill ${statusCls}">${escapeHtml(r.status || '—')}</span></td>
        <td>${escapeHtml(r.sale_section || '—')}</td>
        <td>${escapeHtml(r.sale_row || '—')}</td>
        <td class="num">${T.fmtNum(r.sale_quantity)}</td>
        <td class="num">${r.sale_price != null ? '$' + T.fmtNum(Math.round(r.sale_price)) : '—'}</td>
        <td class="num">${r.payment_total != null ? '$' + T.fmtNum(Math.round(r.payment_total)) : '—'}</td>
        <td class="num">${r.payment_fees != null ? '$' + T.fmtNum(Math.round(r.payment_fees)) : '—'}</td>
        <td class="num">${r.payment_tax != null ? '$' + T.fmtNum(Math.round(r.payment_tax)) : '—'}</td>
        <td>${escapeHtml(r.delivery_method || r.delivery || '—')}</td>
        <td>${escapeHtml(r.stock_type || '—')}</td>
        <td class="muted">${T.fmtDate(r.pulled_at)}</td>`;
      tb.appendChild(tr);
    });
    host.appendChild(tbl);
    body.innerHTML = '';
    body.appendChild(host);
  }

  // ---------- Cross-Broker (TickPick + Vivid combined, full) ----------
  async function loadCrossBrokerFull(eventId) {
    const body = document.getElementById('crossBrokerFullBody');
    const meta = document.getElementById('crossBrokerFullMeta');
    if (body) body.innerHTML = '<div class="empty">Loading TickPick + Vivid…</div>';
    if (meta) meta.textContent = 'loading…';
    const t0 = performance.now();
    const res = await rpcOrNull('get_event_cross_broker_orders_full', { p_event_id: eventId, p_limit: 500 });
    if (res.error) {
      if (meta) meta.textContent = 'error';
      if (body) body.innerHTML = `<div class="empty">RPC error: ${escapeHtml(res.error.message || '')}</div>`;
      return;
    }
    _tabState.loaded['cross-broker'] = true;
    renderCrossBrokerFull(res.data, performance.now() - t0);
  }

  function renderCrossBrokerFull(d, ms) {
    const body = document.getElementById('crossBrokerFullBody');
    const meta = document.getElementById('crossBrokerFullMeta');
    const countChip = document.getElementById('tabCountCrossBroker');
    if (!body) return;
    const rows = (d && d.rows) || [];
    const tpN = (d && d.tickpick_count) || 0;
    const vvN = (d && d.vivid_count) || 0;
    if (meta) meta.textContent = `${rows.length} rows · TP ${tpN} · Vivid ${vvN} · ${ms.toFixed(0)}ms`;
    if (countChip) countChip.textContent = String(rows.length);
    if (!rows.length) {
      body.innerHTML = '<div class="empty">no TickPick or Vivid orders for this event<div class="muted small">(Vivid bridge requires aq_short_event_id → sg_event_id → tevo_event_id; bridge data may be incomplete)</div></div>';
      return;
    }
    const host = document.createElement('div');
    host.className = 'full-list-host';
    const tbl = document.createElement('table');
    tbl.className = 'full-list-tbl';
    tbl.innerHTML = `
      <thead><tr>
        <th>Source</th><th>Ordered</th><th>Order ID</th><th>Status</th>
        <th>Section</th><th>Row</th><th>Seats</th>
        <th class="num">Qty</th><th class="num">Total</th>
        <th>Notes / Match</th>
      </tr></thead><tbody></tbody>`;
    const tb = tbl.querySelector('tbody');
    rows.forEach(r => {
      const tr = document.createElement('tr');
      const statusCls = r.status ? 'status-' + String(r.status).toLowerCase() : '';
      const srcCls = 'src-' + String(r.source || '');
      const seats = Array.isArray(r.seat_numbers) ? r.seat_numbers.join(',') : '';
      const noteParts = [];
      if (r.notes) noteParts.push(r.notes);
      if (r.matched_via) noteParts.push(`match: ${r.matched_via}${r.match_confidence != null ? ' (' + Number(r.match_confidence).toFixed(2) + ')' : ''}`);
      tr.innerHTML = `
        <td><span class="pill ${srcCls}">${escapeHtml(r.source || '—')}</span></td>
        <td>${T.fmtDate(r.ordered_at)}</td>
        <td><strong>${escapeHtml(String(r.source_order_id || '—'))}</strong></td>
        <td><span class="pill ${statusCls}">${escapeHtml(r.status || r.order_status || '—')}</span></td>
        <td>${escapeHtml(r.section || '—')}</td>
        <td>${escapeHtml(r.row || '—')}</td>
        <td class="muted">${escapeHtml(seats)}</td>
        <td class="num">${T.fmtNum(r.quantity)}</td>
        <td class="num">${r.total != null ? '$' + T.fmtNum(Math.round(r.total)) : '—'}</td>
        <td class="muted">${escapeHtml(noteParts.join(' · '))}</td>`;
      tb.appendChild(tr);
    });
    host.appendChild(tbl);
    body.innerHTML = '';
    body.appendChild(host);
  }

  // ---------- Cross-source metrics (Overview tab) ----------
  // Calls get_event_cross_source_metrics (mig 20260518040000). The RPC
  // returns a pre-aligned `rows` array — FE just iterates + formats.
  // Uses listings_all_* / listings_owned_* from PR #204 (not deprecated cost_*).
  async function loadCrossSourceMetrics(eventId) {
    const body = document.getElementById('crossSourceBody');
    const meta = document.getElementById('crossSourceMeta');
    if (body) body.innerHTML = '<div class="empty">loading cross-source metrics…</div>';
    if (meta) meta.textContent = 'loading…';
    const t0 = performance.now();
    const res = await rpcOrNull('get_event_cross_source_metrics', { p_event_id: eventId });
    if (res.error) {
      if (body) body.innerHTML = `<div class="empty">RPC error: ${escapeHtml(res.error.message || '')}</div>`;
      if (meta) meta.textContent = 'error';
      return;
    }
    renderCrossSourceMetrics(res.data || {}, performance.now() - t0);
  }

  // Cache the last cross-source payload so we can re-render when v3 data
  // arrives later and we want to override sold_price_median with the v3
  // sg_broker_sales aggregate (which is what the SG BROKER SALES — AGGREGATE
  // panel renders, ensuring both panels show the same number).
  let _lastCrossSource = null;

  function renderCrossSourceMetrics(d, ms, overrides) {
    _lastCrossSource = d;
    const body = document.getElementById('crossSourceBody');
    const meta = document.getElementById('crossSourceMeta');
    if (!body) return;
    const rows = (d && d.rows) || [];
    const hasSg = d && d.sg_event_id != null;
    if (meta) {
      const parts = [`${ms != null ? ms.toFixed(0) + 'ms' : ''}`];
      if (hasSg) parts.unshift(`sg_event_id ${d.sg_event_id}`);
      else parts.unshift('no SG bridge — TEvo-only event');
      meta.textContent = parts.filter(Boolean).join(' · ');
    }
    if (!rows.length) {
      body.innerHTML = '<div class="empty">no metrics available</div>';
      return;
    }
    // Override "Realized sale median" SG cell with v3 sg_broker_sales aggregate
    // when available (the SG BROKER SALES — AGGREGATE panel's source of truth).
    const realizedOverride = overrides && overrides.realized_sale_median_sg;
    function fmtVal(v, isMoney) {
      if (v === null || v === undefined) return '<span class="dim">—</span>';
      const n = Number(v);
      if (!Number.isFinite(n)) return '<span class="dim">—</span>';
      if (isMoney) return '$' + T.fmtNum(Math.round(n));
      return T.fmtNum(n);
    }
    function deltaPct(tevo, sg) {
      if (tevo === null || tevo === undefined || sg === null || sg === undefined) return null;
      const t = Number(tevo), s = Number(sg);
      if (!Number.isFinite(t) || !Number.isFinite(s) || t === 0) return null;
      return ((s - t) / t) * 100;
    }
    function deltaCell(tevo, sg) {
      const p = deltaPct(tevo, sg);
      if (p === null) return '<span class="dim">—</span>';
      const cls = Math.abs(p) < 1 ? '' : (p > 0 ? 'pos' : 'neg');
      return `<span class="${cls}">${p >= 0 ? '+' : ''}${p.toFixed(1)}%</span>`;
    }
    const tbl = document.createElement('table');
    tbl.className = 'cross-src-tbl';
    tbl.innerHTML = `
      <thead><tr>
        <th>Metric</th>
        <th class="num">TEvo</th>
        <th class="num">SG</th>
        <th class="num">Δ SG vs TEvo</th>
      </tr></thead>
      <tbody></tbody>`;
    const tb = tbl.querySelector('tbody');
    rows.forEach(r => {
      const tr = document.createElement('tr');
      let sgVal = r.sg;
      if (r.label === 'Realized sale median' && realizedOverride != null) sgVal = realizedOverride;
      tr.innerHTML = `
        <td>${escapeHtml(r.label || '')}</td>
        <td class="num">${fmtVal(r.tevo, r.is_money)}</td>
        <td class="num">${fmtVal(sgVal, r.is_money)}</td>
        <td class="num">${deltaCell(r.tevo, sgVal)}</td>`;
      tb.appendChild(tr);
    });
    body.innerHTML = '';
    body.appendChild(tbl);
  }

  // Called after v3 RPC payload arrives — re-renders the cross-source panel
  // using the v3 sg_broker_sales.median_sale_price as the canonical
  // "Realized sale median" value (matches SG BROKER SALES — AGGREGATE).
  function rerenderCrossSourceWithV3(data) {
    if (!_lastCrossSource) return;
    const med = data && data.sg_broker_sales && data.sg_broker_sales.median_sale_price;
    renderCrossSourceMetrics(_lastCrossSource, null, {
      realized_sale_median_sg: med != null ? Number(med) : null,
    });
  }

  // ---------- Localized weather + NWS alerts (mig 20260519000000) ----------
  async function loadWeatherLocalized(eventId) {
    const res = await rpcOrNull('get_event_weather_localized', { p_event_id: eventId });
    if (res.error) {
      console.error('[weatherLocalized] RPC error:', res.error.message);
      // Hide hero card; full panel will still show whatever the v3 payload provides.
      const host = document.getElementById('hero-weather');
      if (host) host.setAttribute('hidden', '');
      return;
    }
    const d = res.data || {};
    renderHeroWeather(d.forecast);
    renderWeather(d);
  }

  // ---------- SG zones + splits (mig 20260519010000) ----------
  // Writes its result into the module state cache; renderZones/renderSplits
  // re-render reading from the cache. Race-safe: order of arrival between
  // this RPC and the v3 fetchPayload doesn't matter — either side can land
  // first and the other will paint when it arrives.
  async function loadSgZonesSplits(eventId) {
    const res = await rpcOrNull('get_event_sg_zones_splits', { p_event_id: eventId });
    let sgZones, sgSplits;
    if (res.error) {
      sgZones  = { hidden: true, reason: 'rpc_error' };
      sgSplits = { hidden: true, reason: 'rpc_error' };
    } else {
      const d = res.data || {};
      if (d.hidden) { sgZones = d; sgSplits = d; }
      else { sgZones = { zones: d.zones || [] }; sgSplits = { splits: d.splits || {} }; }
    }
    setZonesSg(sgZones);
    setSplitsSg(sgSplits);
  }

  // ---------- Chart Extended (mig 20260519150000 / get_event_chart_extended) ----------
  // Fetches 5 SG-side series + 2 ESPN annotation arrays in parallel with v3.
  // On arrival, updates _chartExtState and re-renders the chart (which reads
  // the cache and merges the new series + draws annotation markers).
  // No-ops gracefully if the RPC isn't deployed yet (errors silenced).
  async function loadChartExtended(eventId) {
    const res = await rpcOrNull('get_event_chart_extended', {
      p_event_id: eventId,
      p_chart_hours: CHART_HOURS,
    });
    if (res.error) {
      // 42883 = function not deployed (early/staged rollout) → no-op
      if (res.error.code === '42883' || /does not exist/i.test(res.error.message || '')) {
        return;
      }
      console.error('[chartExtended]', res.error);
      return;
    }
    setChartExtended(res.data || null);
  }

  function setChartExtended(payload) {
    _chartExtState.payload = payload;
    // Trigger chart re-render IFF the TEvo-side payload is already in.
    // adaptChart is idempotent; re-using the cached payload's chart_data.
    if (_lastPayload && _lastPayload.chart_data) {
      try {
        const chart = adaptChart(_lastPayload.chart_data);
        renderChart(chart, _chartExtAlerts);
        renderChartLegend();
      } catch (e) {
        console.error('[setChartExtended re-render]', e);
      }
    }
  }

  // ---------- Last event snapshot (Overview tab) ----------
  // Surfaces the latest non-null values from chart_data.event_metrics_series
  // — the most recent row written by the cron, across all metrics. This is
  // the "what does the event look like right now per our pull" panel.
  function renderLastSnapshot(chart) {
    const body = document.getElementById('lastSnapshotBody');
    const ageEl = document.getElementById('lastSnapshotAge');
    const section = document.getElementById('last-snapshot');
    if (!body) return;
    const rows = (chart && chart.event_metrics_series) || [];
    if (!rows.length) {
      if (section) section.style.display = 'none';
      return;
    }
    if (section) section.style.display = '';
    const latest = rows[rows.length - 1] || {};
    const captured = latest.captured_at;
    if (ageEl) {
      const ageMin = captured ? Math.round((Date.now() - new Date(captured).getTime()) / 60000) : null;
      ageEl.textContent = captured
        ? `latest ${T.fmtDate(captured)} (${ageMin}m ago)`
        : 'latest —';
    }

    // Walk back through rows to fill any null fields with the most recent
    // non-null value for that field. Some series (zone medians, SG side)
    // are populated less often than the headline market series.
    const fields = [
      ['tickets_count',          'TIX COUNT'],
      ['listings_count',         'LISTINGS'],
      ['owned_tickets_count',    'OUR TIX'],
      ['owned_listings_count',   'OUR LISTINGS'],
      ['retail_median',          'RETAIL MED', '$'],
      ['nonowned_median_retail', 'NONOWNED MED', '$'],
      ['owned_median_retail',    'OUR MED', '$'],
      ['min_retail',             'GET-IN', '$'],
      ['owned_min_retail',       'OUR MIN', '$'],
      ['cost_median',            'COST MED', '$'],
      ['retail_p25',             'P25', '$'],
      ['retail_p75',             'P75', '$'],
    ];
    function latestNonNullField(col) {
      for (let i = rows.length - 1; i >= 0; i--) {
        const v = rows[i] && rows[i][col];
        if (v !== null && v !== undefined && !Number.isNaN(Number(v))) {
          return { val: Number(v), at: rows[i].captured_at };
        }
      }
      return null;
    }
    const cells = fields.map(([col, label, prefix]) => {
      const found = latestNonNullField(col);
      const valHtml = found
        ? `<span class="last-snap-val">${prefix === '$' ? '$' : ''}${T.fmtNum(Math.round(found.val))}</span>`
        : `<span class="last-snap-val dim">—</span>`;
      return `<div class="last-snap-cell"><span class="last-snap-lbl">${label}</span>${valHtml}</div>`;
    }).join('');
    body.innerHTML = `<div class="last-snap-grid">${cells}</div>
      <div class="last-snap-meta">snapshot fields fall back to the most recent non-null value across the loaded window (${rows.length} pulls)</div>`;
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

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
  // V3 page-load p_chart_hours: bumped to 720 (30d) so both charts have full
  // TEvo history available even when their range selector is set to 30d.
  // Re-render cost is negligible; only the chart_data series array grows.
  const V3_LOAD_HOURS = 720;
  // Composite chart (WP-3, 2026-05-29): ONE #composite-chart section with two
  // stacked panes that share a range selector + per-source master toggles:
  //   price pane (#chartHostPrice) → medians on $-axis + ESPN annotations
  //   inventory pane (#chartHostInv) → qty lines (left axis) + SG sale BARS (right)
  // Two uPlot instances are kept so the $-axis and count axes stay readable;
  // each pane keeps its own state cache + tooltip. No cursor sync.
  let _chartInstances = { price: null, inv: null };
  let _lastPayload = null;
  // Per-chart window (hours). Default 168h (7d) on first load.
  let _chartPriceHours = DEFAULT_HOURS;
  let _chartInvHours   = DEFAULT_HOURS;
  // Per-chart extended-RPC payload caches (mig 20260519150000).
  // Each chart fetches at its own window independently.
  let _chartExtStatePrice = { payload: undefined };
  let _chartExtStateInv   = { payload: undefined };
  // Alerts cached for the price chart's annotation overlay re-renders.
  let _chartExtAlerts = [];
  // Alerts markers on the price chart are OFF by default (operator request 2026-05-18 —
  // arbitrage_opportunity fires ~17 alerts per cron tick, stacking to a dark vertical
  // bar that dominates the chart). Toggle via #chartPriceAlertsToggle; persisted in
  // localStorage so the preference survives reloads.
  const _ALERTS_LS_KEY = 'd0_chart_show_alerts';
  let _showAlerts = (typeof localStorage !== 'undefined' && localStorage.getItem(_ALERTS_LS_KEY) === '1');
  // Legend toggle state (session-scope, shared map — keys are globally unique).
  const _chartVisible = new Map();
  // Per-chart build caches so each tooltip can read its own series at cursor.idx.
  let _chartLastBuildPrice = null;
  let _chartLastBuildInv   = null;
  // TD per-source snapshot series for price chart overlay.
  // Populated by loadTdFreshness() (fire-and-forget after main load).
  // Shape: { sh: [{t,v}], gt: [{t,v}], vd: [{t,v}] }
  let _tdChartSeries = null;
  // Latest event_listing_snapshot_daily row — set by loadTdFreshness(),
  // used by renderLastSnapshot() to append a TD MARKETS section.
  let _lastTdSnap = null;
  // TD listing-count time series for the inventory chart overlay.
  // Shape: { sh: [{t,v}], gt: [{t,v}], vd: [{t,v}] } — counts not medians.
  let _tdInvCountSeries = null;
  // Initialize TD inv series as hidden by default (user-togglable in legend).
  ['td-sh-cnt', 'td-gt-cnt', 'td-vd-cnt'].forEach(k => _chartVisible.set(k, false));

  // Phase 1b: <MoverChip> — appends a movers-index chip to evBadges if this
  // event is currently in the merged-7d slot of event_movers_index. Async +
  // best-effort; no chip if the event is not in the index or preload fails.
  async function loadHeroMoverChip(eventId) {
    if (!eventId) return;
    await T.moversPreloadIndex();
    const chipHtml = T.moversChipHtml(eventId);
    if (!chipHtml) return;
    const badges = document.getElementById('evBadges');
    if (!badges) return;
    badges.insertAdjacentHTML('beforeend', ' ' + chipHtml);
  }

  // Phase 2: <GapChip> — appends discovery gap alert badges to evBadges.
  // discovery_gap_alerts has no RLS (relrowsecurity=false) — readable directly
  // via @s4kent.com JWT. Top-3 active alerts by signal_score. Best-effort async;
  // no chips if the event has no active gaps.
  async function loadHeroGapChips(eventId) {
    if (!eventId) return;
    const Auth = window.TerminalAuth;
    if (!Auth || !Auth.client) return;
    const { data, error } = await Auth.client
      .from('discovery_gap_alerts')
      .select('gap_type,detail,signal_score')
      .eq('event_id', eventId)
      .is('resolved_at', null)
      .order('signal_score', { ascending: false })
      .limit(3);
    if (error || !data || !data.length) return;
    const badges = document.getElementById('evBadges');
    if (!badges) return;
    data.forEach(g => {
      badges.insertAdjacentHTML('beforeend',
        ` <span class="badge gap-chip" title="${escapeHtml(g.detail || '')}">${escapeHtml((g.gap_type || '').replace(/_/g, ' '))}</span>`
      );
    });
  }

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

    wireRangeSelectorComposite(eventId);
    wireAlertsToggle();
    wireTabs(eventId);
    wireSalesWindow(eventId);
    // Path-C-only enrichment RPCs fire in parallel — render even when
    // fetchPayload (Path A / Path C v3) fails. PR #205 cross-source +
    // PR redesign localized weather + SG zones/splits all independent.
    loadCrossSourceMetrics(eventId).catch(e => console.error('[crossSource]', e));
    loadWeatherLocalized(eventId).catch(e => console.error('[weatherLocalized]', e));
    loadSgZonesSplits(eventId).catch(e => console.error('[sgZonesSplits]', e));
    loadCrossPlatformSales(eventId).catch(e => console.error('[crossSales]', e));
    loadHeroMoverChip(eventId).catch(e => console.error('[moverChip]', e));
    loadHeroGapChips(eventId).catch(e => console.error('[gapChips]', e));
    // Each chart fetches its own extended payload at its own window in parallel
    loadChartExtended('price', eventId, _chartPriceHours).catch(e => console.error('[chartExt price]', e));
    loadChartExtended('inv',   eventId, _chartInvHours  ).catch(e => console.error('[chartExt inv]', e));
    await loadAndRender(eventId);
    // Live updates (Supabase Realtime). Best-effort, post-render: if the socket
    // never connects or no pings arrive the page is unchanged from before.
    safe('realtime', () => wireRealtime(eventId));
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
      // Two independent chart sections (PR redesign v2)
      safe('chartPrice',       () => renderChartPrice(chart, data.event_alerts));
      safe('chartInventory',   () => renderChartInventory(chart));
      safe('chartLegends',     () => refreshChartLegends());
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
      safe('brokerSales',      () => setBrokerSalesData(data));
      safe('velocityChips',    () => renderVelocityChips(data.velocity));
      safe('competingEvents',  () => renderCompetingEvents(data.competing_events));
      safe('recentListings',   () => renderRecentListings(data.recent_listings));
      safe('performerEspn',    () => renderPerformerEspn(data.performer_espn_context, data.performer));
      safe('lastSnapshot',     () => renderLastSnapshot(data.chart_data));
      // Cross-source panel: re-render now that we have v3's sg_broker_sales
      // available (overrides sold_price_median for "Realized sale median" row).
      safe('crossSourceRerender', () => rerenderCrossSourceWithV3(data));
      // TD freshness + data-freshness table (fire-and-forget; non-blocking)
      loadTdFreshness(eventId).catch(e => console.error('[td-freshness]', e));
    } catch (e) {
      handleRpcError(e);
    }
  }

  function safe(label, fn) {
    try { fn(); } catch (e) { console.error('[' + label + ']', e); }
  }

  // ── Realtime live refresh (Phase: Supabase Realtime, slice #1) ────────────
  // Subscribe to a per-event Broadcast topic ("event:<id>"). The DB emits a
  // tiny, DATA-FREE "dirty" ping (see migration *_d0_event_realtime_dirty_ping)
  // when something page-worthy happens on this event (today: a warn/critical
  // alert; later: the per-event metrics refresh). On a ping we re-pull the
  // existing email-gated RPC and re-render — no polling, and no
  // event data ever rides the public channel (the ping carries only
  // {event_id, reason}). Re-fetch is throttled and pauses while the tab is
  // hidden. If Realtime is unavailable or silent, the page behaves exactly as
  // it did before (load-time render only) — this is purely additive.
  let _rtChannel = null;
  let _rtRefreshTimer = null;
  let _rtLastRefresh = 0;
  const _RT_MIN_INTERVAL_MS = 8000; // cap full re-fetch to <= 1 / 8s

  function wireRealtime(eventId) {
    const Auth = window.TerminalAuth;
    const client = Auth && Auth.client;
    if (!client || typeof client.channel !== 'function') return; // realtime unavailable → no-op
    const pill = ensureLivePill();
    _rtChannel = client
      .channel('event:' + eventId, { config: { broadcast: { self: false } } })
      .on('broadcast', { event: 'dirty' }, (msg) => scheduleLiveRefresh(eventId, msg && msg.payload))
      .subscribe((status) => setLivePill(pill, status));
    // Drop the socket when the page is dismissed (bfcache-friendly).
    window.addEventListener('pagehide', teardownRealtime, { once: true });
  }

  function teardownRealtime() {
    try {
      const client = window.TerminalAuth && window.TerminalAuth.client;
      if (_rtChannel && client) client.removeChannel(_rtChannel);
    } catch (_) { /* best-effort */ }
    _rtChannel = null;
  }

  function scheduleLiveRefresh(eventId, payload) {
    // Pause while the tab is hidden — the next ping after it's visible resumes.
    if (typeof document !== 'undefined' && document.hidden) return;
    if (_rtRefreshTimer) return; // a refresh is already queued — coalesce bursts
    const wait = Math.max(0, _RT_MIN_INTERVAL_MS - (Date.now() - _rtLastRefresh));
    flashLivePill('updating');
    _rtRefreshTimer = setTimeout(async () => {
      _rtRefreshTimer = null;
      _rtLastRefresh = Date.now();
      try {
        await loadAndRender(eventId);
        flashLivePill('updated', payload && payload.reason);
      } catch (e) {
        console.error('[realtime] refresh failed', e);
      }
    }, wait);
  }

  // ── live pill UI ──────────────────────────────────────────────────────────
  function ensureLivePill() {
    let pill = document.getElementById('livePill');
    if (pill) return pill;
    pill = document.createElement('span');
    pill.id = 'livePill';
    pill.className = 'live-pill';
    pill.title = 'Live updates via Supabase Realtime';
    pill.innerHTML = '<span class="live-dot"></span><span class="live-label">live</span>';
    const bar = document.querySelector('header.topbar') || document.body;
    bar.appendChild(pill);
    return pill;
  }

  function setLivePill(pill, status) {
    if (!pill) return;
    // supabase-js channel states: SUBSCRIBED | TIMED_OUT | CLOSED | CHANNEL_ERROR
    const ok = status === 'SUBSCRIBED';
    pill.classList.toggle('on', ok);
    pill.classList.toggle('off', !ok);
    pill.classList.remove('flash');
    const label = pill.querySelector('.live-label');
    if (label) label.textContent = ok ? 'live' : 'offline';
  }

  function flashLivePill(kind, reason) {
    const pill = document.getElementById('livePill');
    const label = pill && pill.querySelector('.live-label');
    if (!label) return;
    if (kind === 'updating') { pill.classList.add('flash'); label.textContent = 'updating…'; return; }
    label.textContent = reason ? ('updated · ' + String(reason).slice(0, 24)) : 'updated';
    setTimeout(() => {
      if (!pill.classList.contains('on')) return;
      pill.classList.remove('flash');
      const lbl = pill.querySelector('.live-label');
      if (lbl) lbl.textContent = 'live';
    }, 2500);
  }

  // Composite range selector (WP-3). ONE selector drives BOTH panes: it sets the
  // shared window for price + inventory, re-renders both from cached v3 data
  // immediately (new window clip), then re-fetches each pane's extended SG series
  // for the new window (re-renders on arrival). v3 is NOT re-fetched — its payload
  // was loaded at V3_LOAD_HOURS (720) which covers all default windows.
  function wireRangeSelectorComposite(eventId) {
    const sel = document.getElementById('chartCompositeRange');
    if (!sel) return;
    sel.addEventListener('change', async () => {
      const hrs = parseInt(sel.value, 10) || DEFAULT_HOURS;
      _chartPriceHours = hrs;
      _chartInvHours   = hrs;
      const lblTxt = sel.options[sel.selectedIndex].textContent;
      const lbl = document.getElementById('chartCompositeRangeLabel');
      if (lbl) lbl.textContent = lblTxt;
      const aw = document.getElementById('alertsWindow');
      if (aw) aw.textContent = lblTxt;
      _chartExtStatePrice.payload = undefined;
      _chartExtStateInv.payload   = undefined;
      // Re-render both panes immediately with the new window clip (cached v3 data)
      if (_lastPayload && _lastPayload.chart_data) {
        try {
          const chart = adaptChart(_lastPayload.chart_data);
          renderChartPrice(chart, _chartExtAlerts);
          renderChartInventory(chart);
          refreshChartLegends();
        } catch (e) { console.error('[compositeRangeRender]', e); }
      }
      // Then fetch fresh SG series for the new window — each re-renders on arrival
      loadChartExtended('price', eventId, _chartPriceHours)
        .catch(e => console.error('[chartExt price]', e));
      loadChartExtended('inv', eventId, _chartInvHours)
        .catch(e => console.error('[chartExt inv]', e));
    });
  }

  function wireAlertsToggle() {
    const cb = document.getElementById('chartPriceAlertsToggle');
    if (!cb) return;
    cb.checked = _showAlerts;
    cb.addEventListener('change', () => {
      _showAlerts = !!cb.checked;
      try { localStorage.setItem(_ALERTS_LS_KEY, _showAlerts ? '1' : '0'); } catch (_) {}
      const inst = _chartInstances.price;
      if (inst && typeof inst.redraw === 'function') inst.redraw(false, true);
    });
  }

  // ---------- Fetch (Path C primary, Path A fallback) ----------

  async function fetchPayload(eventId) {
    const Auth = window.TerminalAuth;
    if (Auth && Auth.client && Auth.getAccessToken()) {
      // Try v3 first (9 enrichment keys); fall back to v2 if v3 isn't applied
      // yet on this Supabase project. Both shapes are forward-compatible —
      // renderers no-op or empty-state when their keys aren't in the payload.
      // v3 fetched ONCE at V3_LOAD_HOURS (720h). Range selectors clip per-chart
      // X-axis afterward; no v3 re-fetch on window flips.
      let res = await Auth.client
        .rpc('get_broker_event_page_v3', { p_event_id: eventId, p_chart_hours: V3_LOAD_HOURS });
      // Fall back to the lighter/faster v2 when v3 is either (a) not applied on
      // this project (42883 / "does not exist") OR (b) times out (57014 /
      // "statement timeout"/"canceling statement"). v3 (~5.8s on heavy events
      // like Yankees) can exceed PostgREST's 8s cap under concurrent load and
      // blank the whole header; v2 (~185ms) still fills the core page and the
      // 9 v3-only enrichment panels just render their empty states. (QA 2026-05-24.)
      const isTimeout = (r) => !!(r && r.error && (
        r.error.code === '57014' ||
        /statement timeout|canceling statement/i.test(r.error.message || '')
      ));
      const isMissing = (r) => !!(r && r.error && (
        r.error.code === '42883' ||
        /does not exist/i.test(r.error.message || '')
      ));
      if (res.error && (isMissing(res) || isTimeout(res))) {
        res = await Auth.client
          .rpc('get_broker_event_page_v2', { p_event_id: eventId, p_chart_hours: V3_LOAD_HOURS });
        // Cold-cache hardening (2026-05-25): a first open after cache eviction /
        // long idle can time out BOTH v3 and v2 — Postgres reads ~8 tables incl. the
        // SG/listings firehoses (10.5GB) but shared_buffers is only 256MB, so the cold
        // first-hit blows PostgREST's 8s cap. The v3+v2 attempts warm those pages, so
        // ONE immediate v2 retry then completes (warm v2 is sub-second; measured
        // steady-state event-page reads ≤2.7s). Root-cause fix (event-page matview,
        // hot path stops scanning the firehoses) is queued for the next checkpoint.
        if (isTimeout(res)) {
          res = await Auth.client
            .rpc('get_broker_event_page_v2', { p_event_id: eventId, p_chart_hours: V3_LOAD_HOURS });
        }
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
      T.api(`/api/broker/event/${idStr}/chart-data?hours=${V3_LOAD_HOURS}`),
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

    // Phase 3: TemporalChip — richer than the old "T-Xd" badge
    const tempChip = T.temporalChipHtml(ev.occurs_at_local || ev.occurs_at);
    if (tempChip) badges.insertAdjacentHTML('beforeend', tempChip);
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
    const chips = [];
    if (bridge.sg_event_id == null) {
      chips.push('<span class="mode-chip warn">TEvo-only · no SG bridge</span>');
    } else if (data && data.v === 'v1-fallback') {
      chips.push('<span class="mode-chip dim">v1 fallback (localhost)</span>');
    }
    // Honest empty-state: no TEvo listings pulled for this event yet (common for
    // far-out events — freshness.tevo_listings_latest is null). Explains why the
    // TEvo KPI cells read "—" instead of leaving the page looking broken/blank.
    const fr = (data && data.freshness) || {};
    if (fr.tevo_listings_latest == null) {
      chips.push('<span class="mode-chip warn" title="No TEvo listings pulled for this event yet (common for far-out events). TEvo market metrics populate after the first pull; SeatGeek data shown where available.">No TEvo market yet · pull pending</span>');
    }
    // SG staleness flag: the SG side-by-side summary lags the raw SG feed when the
    // SG metrics-refresh is behind. Surface its as-of date when >24h stale.
    const sgCur = (data && data.sg_side_by_side && !data.sg_side_by_side.hidden)
      ? data.sg_side_by_side.current : null;
    if (sgCur && sgCur.captured_at) {
      const ageDays = (Date.now() - new Date(sgCur.captured_at).getTime()) / 86400000;
      if (ageDays >= 1) {
        const asOf = new Date(sgCur.captured_at).toLocaleDateString(undefined, { month: 'short', day: 'numeric' });
        chips.push('<span class="mode-chip dim" title="SeatGeek side-by-side metrics are stale; the raw SG feed may be newer.">SG as of ' + asOf + ' · ' + Math.round(ageDays) + 'd stale</span>');
      }
    }
    el.innerHTML = chips.join(' ');
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
    setKpiSg('kpiRetailMedianSG', sgVal(sg, 'listings_all_median', 'cost_median'), sgVal(sgPrev, 'listings_all_median', 'cost_median'), '$', 0, sgHidden);

    // Qty Available  (TEvo counts_market + SG listings_count)
    setKpi('kpiQtyAvailableVal', qtyMkt != null ? T.fmtNum(qtyMkt) : '—');
    setKpiSg('kpiQtyAvailableSG', sgVal(sg, 'listings_all_tickets', 'tickets_count'), sgVal(sgPrev, 'listings_all_tickets', 'tickets_count'), '', 0, sgHidden);

    // Qty Owned  (counts_owned + share)
    setKpi('kpiQtyOwnedVal', qtyOwn != null ? T.fmtNum(qtyOwn) : '—');
    const share = (qtyOwn && qtyMkt && qtyMkt > 0) ? (qtyOwn / qtyMkt * 100) : null;
    setKpiSub('kpiQtyOwnedSub', share != null ? `${share.toFixed(1)}% of market` : '');

    // Get-in (cheapest available ticket): prefer SG cost_min, fall back to TEvo
    // splits.market.singles.min_px (smallest 1-tix market lot). Keeps the cell
    // populated for TEvo-only events instead of "—".
    let getinVal = sgVal(sg, 'listings_all_min', 'cost_min');
    let getinSrc = getinVal != null ? 'SG' : null;
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

  // SG side-by-side columns were renamed server-side (cost_*→listings_all_*); read
  // the current name first, fall back to the legacy one, so the SG cells populate
  // regardless of payload vintage. (Prior code read only the dropped cost_* names,
  // so the SG side-by-side cells were silently blank on every event.)
  function sgVal(o, primary, legacy) {
    if (!o) return null;
    if (o[primary] != null) return o[primary];
    return (legacy && o[legacy] != null) ? o[legacy] : null;
  }

  function colorBucket(pct) {
    const a = Math.abs(pct);
    if (a <= 15) return 'pos';
    if (a <= 30) return 'warn';
    return 'neg';
  }

  // ---------- Chart — 3-pane stacked (Price / Inventory / Volume bars) ----------
  //
  // TradingView/Bloomberg-style stacked layout (operator redesign 2026-05-18).
  // Replaces the single-pane multi-scale chart that PR #237 grew to 10 series.
  // Each pane is an independent uPlot instance; X-axis synced via cursor.sync.
  //
  //   Price (60%)     — 6 medians ($-axis) + ESPN/alert annotations
  //   Inventory (20%) — 3 ticket-count lines (integer axis)
  //   Volume (20%)    — SG sale-count bars (histogram)
  //
  // Series specs carry a `pane` field so the tooltip + legend can route
  // visibility across the right instance.

  // Shared axis styling — canvas-drawn so we set fonts/strokes directly.
  // The old `#chart .uplot text { fill }` CSS doesn't apply because uPlot
  // draws axis labels on canvas, not SVG.
  const AXIS_FONT = '11px ui-monospace, SFMono-Regular, Menlo, monospace';
  const AXIS_STROKE = '#a3a3a3';     // lighter than --muted so it's readable on #0a0a0a
  const AXIS_GRID = '#262626';
  const AXIS_TICKS = '#404040';
  const X_AXIS = {
    stroke: AXIS_STROKE, font: AXIS_FONT,
    grid: { stroke: AXIS_GRID, width: 1 },
    ticks: { stroke: AXIS_TICKS, size: 6 },
  };

  // Helpers shared by both chart renderers
  function buildSeriesData(specs) {
    // Time-axis union for the chart's specs, then project each series onto it.
    const tset = new Set();
    specs.forEach(s => (s.data || []).forEach(p => tset.add(p.t)));
    const ts = [...tset].sort();
    const xs = ts.map(t => Math.round(new Date(t).getTime() / 1000));
    const idxByT = new Map(ts.map((t, i) => [t, i]));
    specs.forEach(s => {
      const arr = new Array(ts.length).fill(null);
      (s.data || []).forEach(p => { const i = idxByT.get(p.t); if (i != null) arr[i] = p.v; });
      s.projected = arr;
    });
    return { xs, specs };
  }

  // X-axis clip range for a given hours window. Returns [minSec, maxSec].
  // If the series data is older than the window, uPlot clips to the window
  // (showing an empty area for the missing time); if newer, the data fits.
  function clipRangeForHours(hours, xs) {
    if (!xs || !xs.length) return undefined;
    const nowSec = Math.floor(Date.now() / 1000);
    const minSec = nowSec - hours * 3600;
    const dataMax = xs[xs.length - 1];
    // Right edge: max(now, dataMax) so a future-dated event still shows its
    // most recent snapshot inside the window.
    return [minSec, Math.max(nowSec, dataMax)];
  }

  // ---------- PRICE CHART ----------
  // 6 line series on a single $-axis. ESPN injury/state crosses + alert
  // triangles via canvas hooks. Hover tooltip via #chartPriceTooltip.
  function renderChartPrice(chart, alerts) {
    const host = document.getElementById('chartHostPrice');
    if (!host) return;
    host.innerHTML = '';
    if (!chart || !window.uPlot) return;

    _chartExtAlerts = alerts || [];
    const ext = _chartExtStatePrice.payload || null;
    const extSeries = (ext && ext.series) || {};

    const tdS = _tdChartSeries || {};
    const specs = [
      { key: 'prices_owned',    label: 'TEvo Owned',     color: '#fbbf24', width: 2,   dash: null,   data: chart.prices_owned },
      { key: 'prices_market',   label: 'TEvo Market',    color: '#737373', width: 1.5, dash: [4, 4], data: chart.prices_market },
      { key: 'prices_nonowned', label: 'TEvo Non-owned', color: '#a78bfa', width: 1.5, dash: [6, 3], data: chart.prices_nonowned },
      { key: 'sg_list_med',     label: 'SG list med',    color: '#22d3ee', width: 1.5, dash: null,   data: extSeries.sg_listings_median       || [] },
      { key: 'sg_own_med',      label: 'SG owned med',   color: '#fb7185', width: 1.5, dash: [3, 3], data: extSeries.sg_listings_owned_median || [] },
      { key: 'sg_sale_med',     label: 'SG sale med',    color: '#84cc16', width: 1.5, dash: [5, 2], data: extSeries.sg_sales_median          || [] },
      { key: 'td_sh_med',       label: 'SH median',      color: '#f97316', width: 1.5, dash: [8, 3], data: tdS.sh || [] },
      { key: 'td_gt_med',       label: 'GT median',      color: '#34d399', width: 1.5, dash: [8, 3], data: tdS.gt || [] },
      { key: 'td_vd_med',       label: 'VD median',      color: '#c084fc', width: 1.5, dash: [8, 3], data: tdS.vd || [] },
    ];
    const { xs } = buildSeriesData(specs);
    _chartLastBuildPrice = { specs, xs };

    const xRange = clipRangeForHours(_chartPriceHours, xs);
    const data = [xs, ...specs.map(s => s.projected)];
    const { w, h } = paneSize(host);
    const opts = {
      width: w, height: h,
      cursor: { drag: { x: true, y: false } },
      scales: {
        x: { time: true, range: xRange ? (() => xRange) : undefined },
        y: { range: robustYRange },
      },
      axes: [
        X_AXIS,
        { scale: 'y', stroke: AXIS_STROKE, font: AXIS_FONT,
          grid: { stroke: AXIS_GRID, width: 1 },
          ticks: { stroke: AXIS_TICKS, size: 6 },
          values: (u, v) => v.map(x => x == null ? '' : '$' + Math.round(x)),
          size: 56 },
      ],
      series: [
        { label: 'time' },
        ...specs.map(s => ({
          label: s.label, stroke: s.color, width: s.width, scale: 'y',
          spanGaps: true, dash: s.dash || undefined,
          show: _chartVisible.get(s.key) !== false,
        })),
      ],
      hooks: {
        draw: [
          // Read _showAlerts at draw time so the toggle takes effect via redraw()
          // without rebuilding the chart instance.
          (u) => drawAlertsMarkers(u, _showAlerts ? (_chartExtAlerts || []) : []),
          (u) => drawInjuryMarkers(u, ext && ext.annotations && ext.annotations.injuries),
          (u) => drawGameStateMarkers(u, ext && ext.annotations && ext.annotations.game_state),
        ],
        ready:   [(u) => renderAnnotationTooltips(u, host, ext && ext.annotations)],
        setSize: [(u) => renderAnnotationTooltips(u, host, ext && ext.annotations)],
        setCursor: [(u) => updateChartTooltipFor('price', u)],
      },
    };
    _chartInstances.price = new window.uPlot(opts, data, host);

    if (!host.__resizeWired) {
      host.__resizeWired = true;
      let resizeTimer;
      window.addEventListener('resize', () => {
        clearTimeout(resizeTimer);
        resizeTimer = setTimeout(() => renderChartPrice(chart, _chartExtAlerts), 200);
      });
    }
  }

  // Robust Y-axis range. uPlot's default auto-scale spans data min→max, so a
  // single outlier (e.g. a $500+ suite sale spiking a median bucket) blows the
  // axis out and compresses the $4-60 trading band into an unreadable sliver.
  // This clips the top to ~p95 ONLY when a real outlier exists (real max > 1.5×
  // p95); otherwise it shows the full range. Lines above the cap clip off-top.
  function robustYRange(u, initMin, initMax) {
    var fallback = [0, (initMax == null || !isFinite(initMax)) ? 1 : initMax];
    if (!u || !u.series || !u.data) return fallback;
    var vals = [];
    for (var i = 1; i < u.series.length; i++) {
      if (u.series[i] && u.series[i].show === false) continue;
      var d = u.data[i]; if (!d) continue;
      for (var j = 0; j < d.length; j++) {
        var v = d[j]; if (v != null && isFinite(v)) vals.push(v);
      }
    }
    if (!vals.length) return fallback;
    vals.sort(function (a, b) { return a - b; });
    var p95 = vals[Math.min(vals.length - 1, Math.floor(vals.length * 0.95))];
    var realMax = vals[vals.length - 1];
    var top = (realMax <= p95 * 1.5) ? realMax * 1.08 : Math.max(p95 * 1.1, 1);
    return [0, top > 0 ? top : 1];
  }

  // ---------- INVENTORY CHART ----------
  // 3 line series on left Y-axis (integer ticket counts) + 1 bar series on
  // right Y-axis (SG sale count). uPlot supports per-series scales natively;
  // right axis registered as scale 'yr' with side=1.
  function renderChartInventory(chart) {
    const host = document.getElementById('chartHostInv');
    if (!host) return;
    host.innerHTML = '';
    if (!chart || !window.uPlot) return;

    const ext = _chartExtStateInv.payload || null;
    const extSeries = (ext && ext.series) || {};

    const specs = [
      { key: 'counts_owned',  label: 'TEvo Owned qty', color: '#60a5fa', width: 1.5, dash: null,   scale: 'y',  fill: 'rgba(96,165,250,0.08)', data: chart.counts_owned },
      { key: 'counts_market', label: 'TEvo Mkt qty',   color: '#94a3b8', width: 1,   dash: [2,2],  scale: 'y',  data: chart.counts_market },
      { key: 'sg_list_ct',    label: 'SG list qty',    color: '#22d3ee', width: 1.5, dash: null,   scale: 'y',  data: extSeries.sg_listings_count || [] },
      { key: 'sg_sale_ct',    label: 'SG sale ct',     color: '#84cc16', width: 1,   dash: null,   scale: 'yr', bars: true, data: extSeries.sg_sales_count || [] },
    ];
    // Overlay TD listing-count series (dashed, hidden by default — user-togglable)
    if (_tdInvCountSeries) {
      if (_tdInvCountSeries.sh.length) specs.push(
        { key: 'td-sh-cnt', label: 'SH listings', color: '#f97316', width: 1, dash: [4, 3], scale: 'y', data: _tdInvCountSeries.sh });
      if (_tdInvCountSeries.gt.length) specs.push(
        { key: 'td-gt-cnt', label: 'GT listings', color: '#2dd4bf', width: 1, dash: [4, 3], scale: 'y', data: _tdInvCountSeries.gt });
      if (_tdInvCountSeries.vd.length) specs.push(
        { key: 'td-vd-cnt', label: 'VD listings', color: '#a855f7', width: 1, dash: [4, 3], scale: 'y', data: _tdInvCountSeries.vd });
    }
    const { xs } = buildSeriesData(specs);
    _chartLastBuildInv = { specs, xs };

    const xRange = clipRangeForHours(_chartInvHours, xs);
    const data = [xs, ...specs.map(s => s.projected)];
    const { w, h } = paneSize(host);
    const barsPath = window.uPlot.paths && window.uPlot.paths.bars
      ? window.uPlot.paths.bars({ size: [0.6, 32, 1] })
      : undefined;

    const opts = {
      width: w, height: h,
      cursor: { drag: { x: true, y: false } },
      scales: {
        x:  { time: true, range: xRange ? (() => xRange) : undefined },
        y:  { range: robustYRange },
        yr: { range: (u, dataMin, dataMax) => [0, Math.max(dataMax || 1, 1)] },
      },
      axes: [
        X_AXIS,
        { scale: 'y',  side: 3, stroke: AXIS_STROKE, font: AXIS_FONT,
          grid: { stroke: AXIS_GRID, width: 1 },
          ticks: { stroke: AXIS_TICKS, size: 6 },
          values: (u, v) => v.map(x => x == null ? '' : Math.round(x)),
          size: 56 },
        { scale: 'yr', side: 1, stroke: AXIS_STROKE, font: AXIS_FONT,
          grid: { show: false },
          ticks: { stroke: AXIS_TICKS, size: 6 },
          values: (u, v) => v.map(x => x == null ? '' : Math.round(x)),
          size: 48 },
      ],
      series: [
        { label: 'time' },
        ...specs.map(s => ({
          label: s.label, stroke: s.color, width: s.width, scale: s.scale,
          spanGaps: true, dash: s.dash || undefined,
          fill: s.bars ? s.color : (s.fill || undefined),
          paths: s.bars ? barsPath : undefined,
          points: s.bars ? { show: false } : undefined,
          show: _chartVisible.get(s.key) !== false,
        })),
      ],
      hooks: {
        setCursor: [(u) => updateChartTooltipFor('inv', u)],
      },
    };
    _chartInstances.inv = new window.uPlot(opts, data, host);

    if (!host.__resizeWired) {
      host.__resizeWired = true;
      let resizeTimer;
      window.addEventListener('resize', () => {
        clearTimeout(resizeTimer);
        resizeTimer = setTimeout(() => renderChartInventory(chart), 200);
      });
    }
  }

  function paneSize(host) {
    const rect = host.getBoundingClientRect();
    const w = Math.max(400, rect.width || host.clientWidth || 1200);
    // Subtract a small budget for the host's own padding; uPlot wants exact px.
    const h = Math.max(40, Math.floor(rect.height || host.clientHeight || 120));
    return { w, h };
  }

  // Per-chart tooltip — reads value at cursor idx from that chart's build cache
  // and renders a compact floating table inside that chart's section.
  function updateChartTooltipFor(chartKey, srcInstance) {
    const tipId     = chartKey === 'price' ? 'chartPriceTooltip' : 'chartInvTooltip';
    const build     = chartKey === 'price' ? _chartLastBuildPrice : _chartLastBuildInv;
    const tip       = document.getElementById(tipId);
    // Anchor to this pane's own block (composite layout, WP-3) so the tooltip
    // stays aligned to the pane the cursor is over.
    const section   = tip ? tip.closest('.composite-pane-block') : null;
    if (!tip || !section || !build || !srcInstance || !srcInstance.cursor) return;
    const idx = srcInstance.cursor.idx;
    if (idx == null || idx < 0 || idx >= build.xs.length) {
      tip.hidden = true;
      return;
    }
    const tSec = build.xs[idx];
    const ts = new Date(tSec * 1000);
    const rows = [];
    build.specs.forEach(s => {
      if (_chartVisible.get(s.key) === false) return;
      const v = s.projected[idx];
      if (v == null) return;
      const fmt = chartKey === 'price' ? '$' + Math.round(v) : Math.round(v).toString();
      rows.push(
        `<div class="tt-row"><i style="background:${s.color}"></i>` +
        `<span class="tt-label">${escapeHtml(s.label)}</span>` +
        `<span class="tt-val">${fmt}</span></div>`
      );
    });
    if (!rows.length) { tip.hidden = true; return; }
    const tStr = ts.toLocaleString(undefined, {
      month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit',
    });
    tip.innerHTML = `<div class="tt-time">${escapeHtml(tStr)}</div>` + rows.join('');
    // Position relative to this section's bounding box
    const sectionRect = section.getBoundingClientRect();
    const srcCanvas = srcInstance.root;
    const srcRect = srcCanvas.getBoundingClientRect();
    const px = (srcInstance.cursor.left || 0) + (srcRect.left - sectionRect.left);
    tip.style.left = '0px';
    tip.style.top  = '0px';
    tip.hidden = false;
    const tipWidth = tip.offsetWidth;
    const maxLeft = sectionRect.width - tipWidth - 8;
    const desiredLeft = px + 12;
    tip.style.left = Math.max(8, Math.min(desiredLeft, maxLeft)) + 'px';
    // Float just below this pane's label (composite layout, WP-3).
    const lbl = section.querySelector('.pane-label');
    tip.style.top  = ((lbl ? lbl.offsetHeight : 0) + 6) + 'px';
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

  // Shared legend renderer — chartKey selects which build cache + DOM target.
  // Toggle clicks call uPlot.setSeries({show}) on that chart's instance only.
  function renderChartLegendFor(chartKey) {
    const elId    = chartKey === 'price' ? 'chartPriceLegend' : 'chartInvLegend';
    const build   = chartKey === 'price' ? _chartLastBuildPrice : _chartLastBuildInv;
    const ext     = chartKey === 'price' ? _chartExtStatePrice.payload : _chartExtStateInv.payload;
    const instance = _chartInstances[chartKey];
    const el = document.getElementById(elId);
    if (!el) return;
    const hasSg = ext && !ext.sg_hidden;

    let html = '';
    if (build && build.specs && build.specs.length) {
      const visibleSpecs = build.specs.filter(s => hasSg || !s.key.startsWith('sg_'));
      html = visibleSpecs.map(s => {
        const isOn = _chartVisible.get(s.key) !== false;
        const opa = isOn ? '1' : '0.35';
        return `<span class="legend-item" data-key="${escapeHtml(s.key)}" style="opacity:${opa};cursor:pointer" title="Click to toggle">` +
               `<i style="background:${s.color}"></i> ${escapeHtml(s.label)}</span>`;
      }).join('');
    } else {
      // Fallback static legend pre-first-render
      const items = chartKey === 'price'
        ? [['#fbbf24', 'TEvo Owned'], ['#737373', 'TEvo Mkt'], ['#a78bfa', 'TEvo Non-own']]
        : [['#60a5fa', 'TEvo Own qty'], ['#94a3b8', 'TEvo Mkt qty']];
      html = items.map(([c, l]) =>
        `<span><i style="background:${c}"></i> ${escapeHtml(l)}</span>`).join('');
    }

    // Annotation chips only on the price legend
    if (chartKey === 'price' && ext && (
      (ext.annotations && ext.annotations.injuries && ext.annotations.injuries.length) ||
      (ext.annotations && ext.annotations.game_state && ext.annotations.game_state.length)
    )) {
      html += '<span class="legend-sep">|</span>';
      html += '<span class="legend-anno"><i class="anno-inj-i"></i> Injury</span>';
      html += '<span class="legend-anno"><i class="anno-gs-i"></i> State</span>';
    }
    el.innerHTML = html;

    // Wire click handlers on this legend's items only
    el.querySelectorAll('.legend-item').forEach(node => {
      node.addEventListener('click', () => {
        const key = node.getAttribute('data-key');
        const cur = _chartVisible.get(key) !== false;
        _chartVisible.set(key, !cur);
        if (instance && build) {
          const idx = build.specs.findIndex(s => s.key === key);
          if (idx >= 0) instance.setSeries(idx + 1 /* +1 for time series */, { show: !cur });
        }
        renderChartLegendFor(chartKey);   // refresh this legend's opacity
        renderChartSourceToggles();        // keep source master toggles in sync
      });
    });
  }
  function renderChartLegendPrice() { renderChartLegendFor('price'); }
  function renderChartLegendInv()   { renderChartLegendFor('inv');   }

  // ---------- Composite chart: per-source master toggles + overlay slots (WP-3) ----------
  // Each source groups its price-pane + inventory-pane series under one swatch.
  // Clicking a source chip hides/shows ALL of that source's series across BOTH
  // panes at once — a coarse control above the existing per-series legends.
  const CHART_SOURCE_GROUPS = [
    { src: 'TEvo', color: '#fbbf24', keys: ['prices_owned', 'prices_market', 'prices_nonowned', 'counts_owned', 'counts_market'] },
    { src: 'SG',   color: '#22d3ee', keys: ['sg_list_med', 'sg_own_med', 'sg_sale_med', 'sg_list_ct', 'sg_sale_ct'] },
    { src: 'SH',   color: '#f97316', keys: ['td_sh_med', 'td-sh-cnt'] },
    { src: 'GT',   color: '#34d399', keys: ['td_gt_med', 'td-gt-cnt'] },
    { src: 'VD',   color: '#c084fc', keys: ['td_vd_med', 'td-vd-cnt'] },
  ];

  // Which series keys currently carry real data (scanning both build caches).
  // Used so the source toggles omit a source with no chart series (D3 honesty).
  function chartKeysWithData() {
    const present = new Set();
    [_chartLastBuildPrice, _chartLastBuildInv].forEach(b => {
      if (b && b.specs) b.specs.forEach(s => {
        const has = (s.data && s.data.length) ||
                    (s.projected && s.projected.some(v => v != null));
        if (has) present.add(s.key);
      });
    });
    return present;
  }

  // Toggle one series' visibility on whichever pane owns it (price or inv).
  function setSeriesVisible(key, show) {
    _chartVisible.set(key, show);
    const tryPane = (build, inst) => {
      if (!build || !build.specs || !inst) return false;
      const i = build.specs.findIndex(s => s.key === key);
      if (i < 0) return false;
      inst.setSeries(i + 1 /* +1 for time series */, { show });
      return true;
    };
    if (tryPane(_chartLastBuildPrice, _chartInstances.price)) return;
    tryPane(_chartLastBuildInv, _chartInstances.inv);
  }

  function renderChartSourceToggles() {
    const el = document.getElementById('chartSourceToggles');
    if (!el) return;
    const present = chartKeysWithData();
    const chips = CHART_SOURCE_GROUPS.map(g => {
      const keys = g.keys.filter(k => present.has(k));
      if (!keys.length) return ''; // omit sources with no chart series (D3)
      const anyOn = keys.some(k => _chartVisible.get(k) !== false);
      return `<span class="source-toggle" data-src="${escapeHtml(g.src)}" ` +
             `style="opacity:${anyOn ? '1' : '0.3'}" title="Toggle all ${escapeHtml(g.src)} series">` +
             `<i style="background:${g.color}"></i>${escapeHtml(g.src)}</span>`;
    }).filter(Boolean).join('');
    el.innerHTML = chips || '<span class="muted small">no chart series yet</span>';
    el.querySelectorAll('.source-toggle').forEach(node => {
      node.addEventListener('click', () => {
        const g = CHART_SOURCE_GROUPS.find(x => x.src === node.getAttribute('data-src'));
        if (!g) return;
        const presentNow = chartKeysWithData();
        const keys = g.keys.filter(k => presentNow.has(k));
        if (!keys.length) return;
        const next = !keys.some(k => _chartVisible.get(k) !== false); // any on → all off; else all on
        keys.forEach(k => setSeriesVisible(k, next));
        refreshChartLegends();
      });
    });
  }

  // Reserved overlay-layer legend (plan Part F layered-canvas). ESPN markers are
  // already drawn on the price pane via canvas hooks; Weather/Macro/Signals are
  // reserved slots later phases drop into. Honest status: ● live vs ○ pending —
  // never a fake "live" for an unwired layer.
  function renderChartOverlayLegend() {
    const el = document.getElementById('chartOverlayLegend');
    if (!el) return;
    const ext = _chartExtStatePrice.payload || null;
    const ann = ext && ext.annotations;
    const hasEspn = !!(ann && (
      (ann.injuries && ann.injuries.length) ||
      (ann.game_state && ann.game_state.length)));
    const slots = [
      { label: 'ESPN',    live: hasEspn, hint: hasEspn ? 'injury / game-state markers on price pane' : 'no ESPN markers for this event' },
      { label: 'Weather', live: false,   hint: 'reserved — NWS alert windows (pending)' },
      { label: 'Macro',   live: false,   hint: 'reserved — UMCSENT background band (pending)' },
      { label: 'Signals', live: false,   hint: 'reserved — movers / gap markers (pending)' },
    ];
    el.innerHTML = '<span class="overlay-legend-lbl">overlays</span>' + slots.map(s =>
      `<span class="overlay-chip ${s.live ? 'live' : 'pending'}" title="${escapeHtml(s.hint)}">` +
      `${escapeHtml(s.label)} ${s.live ? '●' : '○'}</span>`).join('');
  }

  // Refresh every chart legend surface at once — the two detailed per-series
  // legends plus the per-source master toggles and the overlay-slot legend.
  function refreshChartLegends() {
    renderChartLegendPrice();
    renderChartLegendInv();
    renderChartSourceToggles();
    renderChartOverlayLegend();
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

  // Renders TEvo splits + SG splits + TD splits side-by-side from the module state cache.
  // Any side may still be `undefined` (loading) when this fires.
  // WP-7: split DENSITY (lot format — singles/pairs/…) has real backing only for
  // TEvo (v3 `splits`) and SG (get_event_sg_zones_splits, already wired). EVO /
  // SeatData / TP / Vivid / TD have NO split-density source → omitted (D3), with a
  // footnote naming them (never a fake/empty column). Mirrors the WP-4 zones layout.
  function renderSplits() {
    const body = document.getElementById('splitsBody');
    if (!body) return;
    body.innerHTML = '';
    const grid = document.createElement('div');
    grid.className = 'dual-src cols-2';
    const left = document.createElement('div');
    left.className = 'dual-src-col';
    left.innerHTML = '<div class="dual-src-hdr">TEvo</div>';
    left.appendChild(buildTevoSplitsTable(_splitsState.tevo));
    const right = document.createElement('div');
    right.className = 'dual-src-col';
    right.innerHTML = '<div class="dual-src-hdr">SG</div>';
    right.appendChild(buildSgSplitsTable(_splitsState.sg));
    grid.appendChild(left);
    grid.appendChild(right);
    body.appendChild(grid);
    const note = document.createElement('div');
    note.className = 'cross-src-note muted small';
    note.textContent = 'EVO · SeatData · TP · Vivid · TD — no split-density backing (omitted)';
    body.appendChild(note);
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
    // Side-by-side source columns — only sources with real zone-price backing
    // render (D3). EVO/TEvo (broker_event_zones + zone_deltas) and SG
    // (get_event_sg_zones_splits) are both live. SeatData/TP/Vivid/TD have no
    // zone-price backing → omitted (noted below), never shown as empty columns.
    const grid = document.createElement('div');
    grid.className = 'dual-src cols-2';
    const left = document.createElement('div');
    left.className = 'dual-src-col';
    left.innerHTML = '<div class="dual-src-hdr">TEvo (zones)</div>';
    left.appendChild(buildTevoZonesTable(_zonesState.tevo, _zonesState.deltas));
    const right = document.createElement('div');
    right.className = 'dual-src-col';
    right.innerHTML = '<div class="dual-src-hdr">SG (sections)</div>';
    right.appendChild(buildSgZonesTable(_zonesState.sg));
    grid.appendChild(left);
    grid.appendChild(right);
    body.appendChild(grid);
    const note = document.createElement('div');
    note.className = 'cross-src-note muted small';
    note.textContent = 'SeatData · TP · Vivid · TD — no zone-price backing (omitted)';
    body.appendChild(note);
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
    return {
      tevo: 'TEvo', 'sg-lst': 'SG L', 'sg-sales': 'SG S',
      weather: 'Wx', espn: 'ESPN',
      'td-sh': 'SH', 'td-gt': 'GT', 'td-vd': 'VD',
    }[src] || src;
  }
  function staleLimit(src) {
    return {
      tevo: 180, 'sg-lst': 60, 'sg-sales': 30, weather: 360, espn: 1440,
      'td-sh': 1440, 'td-gt': 1440, 'td-vd': 1440,
    }[src] || 360;
  }
  function formatAge(min) {
    if (min < 1)   return 'now';
    if (min < 60)  return `${min}m`;
    if (min < 1440) return `${Math.round(min / 60)}h`;
    return `${Math.round(min / 1440)}d`;
  }

  // ---------- TD per-source freshness (event_listing_snapshot_daily) ----------

  async function loadTdFreshness(eventId) {
    const Auth = window.TerminalAuth;
    if (!Auth || !Auth.client) return;
    // Fetch full snapshot history for this event (up to 90 rows = ~30 days × 3 slots)
    // Used for: (a) fr-chips freshness, (b) data-freshness table, (c) price chart TD overlay
    const { data: rows, error } = await Auth.client
      .from('event_listing_snapshot_daily')
      .select('snapshot_date,snapshot_slot,evo_retail_median,sg_all_median,td_sh_listings,td_sh_median,td_gt_listings,td_gt_median,td_vd_listings,td_vd_median,td_tp_listings,td_tp_median,td_tm_listings,td_tm_median,td_tm_resale_listings,td_tm_resale_median,td_combined_median')
      .eq('event_id', eventId)
      .order('snapshot_date', { ascending: false })
      .order('snapshot_slot', { ascending: false })
      .limit(90);
    if (error) { console.error('[td-freshness] sb', error); return; }
    // Latest row for chips + freshness table
    const snap = rows && rows.length ? rows[0] : null;
    // Convert snapshot_date + slot to approx UTC timestamp for age calc
    // Slots: morning≈09:00, midday≈14:00, evening≈19:00 UTC
    const slotHourMap = { morning: 9, midday: 14, evening: 19 };
    const rowTs = (r) => {
      const h = slotHourMap[r.snapshot_slot] ?? 12;
      return `${r.snapshot_date}T${String(h).padStart(2, '0')}:00:00Z`;
    };
    const snapTs = snap ? rowTs(snap) : null;
    // Update the TD fr-chips in the hero
    const tdMap = { 'td-sh': snap?.td_sh_listings, 'td-gt': snap?.td_gt_listings, 'td-vd': snap?.td_vd_listings };
    for (const [src, listings] of Object.entries(tdMap)) {
      const el = document.querySelector(`.fr-chip[data-src="${src}"]`);
      if (!el) continue;
      const label = chipLabel(src);
      el.classList.remove('fresh', 'stale', 'dim');
      if (!snapTs) {
        el.textContent = `${label} —`;
        el.classList.add('dim');
        continue;
      }
      const ageMin = Math.round((Date.now() - new Date(snapTs).getTime()) / 60000);
      const noData = listings == null || listings === 0;
      el.textContent = `${label} ${formatAge(ageMin)}${noData ? ' ∅' : ''}`;
      el.classList.add(ageMin > staleLimit(src) ? 'stale' : 'fresh');
      el.title = `${label}: snapshot ${snap.snapshot_date} ${snap.snapshot_slot}${noData ? ' (no listings)' : ` — ${listings} listings`}`;
    }
    // Render full per-source freshness table (into #data-freshness inside TD Markets pane)
    renderDataFreshness(snap, snapTs);
    // Store latest snapshot row for renderLastSnapshot() TD section
    _lastTdSnap = snap;

    // Build chart series from full history (both price medians and listing counts)
    if (rows && rows.length > 1) {
      const sh = [], gt = [], vd = [];
      const ish = [], igt = [], ivd = [];
      for (const r of rows) {
        const ts = rowTs(r);
        if (r.td_sh_median   != null) sh.push({ t: ts, v: +r.td_sh_median });
        if (r.td_gt_median   != null) gt.push({ t: ts, v: +r.td_gt_median });
        if (r.td_vd_median   != null) vd.push({ t: ts, v: +r.td_vd_median });
        if (r.td_sh_listings != null) ish.push({ t: ts, v: +r.td_sh_listings });
        if (r.td_gt_listings != null) igt.push({ t: ts, v: +r.td_gt_listings });
        if (r.td_vd_listings != null) ivd.push({ t: ts, v: +r.td_vd_listings });
      }
      // Reverse so series are chronological (we fetched newest-first)
      _tdChartSeries    = { sh: sh.reverse(),  gt: gt.reverse(),  vd: vd.reverse() };
      _tdInvCountSeries = { sh: ish.reverse(), gt: igt.reverse(), vd: ivd.reverse() };

      if (_lastPayload && _lastPayload.chart_data) {
        try {
          const chart = adaptChart(_lastPayload.chart_data);
          // Re-render price chart with TD median overlay
          renderChartPrice(chart, _chartExtAlerts);
          // Re-render inventory chart with TD listing-count overlay
          renderChartInventory(chart);
          // TD sources are now present — refresh legends + source toggles
          refreshChartLegends();
        } catch (e) { console.error('[td-chart-overlay]', e); }
      }
    }

    // Re-render last snapshot to show TD MARKETS section now that snap is cached
    if (_lastPayload && _lastPayload.chart_data) {
      try {
        renderLastSnapshot(adaptChart(_lastPayload.chart_data));
      } catch (e) { console.error('[td-snap-rerender]', e); }
    }
    // Re-render the unified CROSS-SOURCE table so its TD per-source columns
    // (SH/GT/VD) paint now that _lastTdSnap is cached (WP-2). No new
    // fetch — feeds the cached daily snapshot into the Listings/Price section.
    try { rerenderCrossSource(); } catch (e) { console.error('[td-crosssource-rerender]', e); }
  }

  function renderDataFreshness(tdSnap, tdTs) {
    const body = document.getElementById('dataFreshnessBody');
    if (!body) return;
    const fr = (_lastPayload && _lastPayload.freshness) || {};
    // Weather: prefer obs, fall back to latest forecast
    const weatherTs = fr.weather_latest || latestForecastTs();
    const espnTs    = maxTs(fr.espn_team_latest, fr.espn_inj_latest);
    const rows = [
      { src: 'tevo',     label: 'TEvo listings',  ts: fr.tevo_listings_latest,  listings: null, median: null },
      { src: 'sg-lst',   label: 'SG listings',    ts: fr.sg_listings_latest,    listings: null, median: null },
      { src: 'sg-sales', label: 'SG sales',       ts: fr.sg_sales_latest,       listings: null, median: null },
      { src: 'espn',     label: 'ESPN / team',    ts: fr.espn_team_latest,      listings: null, median: null },
      { src: 'espn',     label: 'ESPN / injuries',ts: fr.espn_inj_latest,       listings: null, median: null },
      { src: 'weather',  label: 'Weather',        ts: weatherTs,                listings: null, median: null },
      {
        src: 'td-sh', label: 'StubHub (SH)',
        ts: tdTs,
        listings: tdSnap ? tdSnap.td_sh_listings : null,
        median:   tdSnap ? tdSnap.td_sh_median   : null,
      },
      {
        src: 'td-gt', label: 'GameTime (GT)',
        ts: tdTs,
        listings: tdSnap ? tdSnap.td_gt_listings : null,
        median:   tdSnap ? tdSnap.td_gt_median   : null,
      },
      {
        src: 'td-vd', label: 'VividSeats (VD)',
        ts: tdTs,
        listings: tdSnap ? tdSnap.td_vd_listings : null,
        median:   tdSnap ? tdSnap.td_vd_median   : null,
      },
    ];
    const meta = document.getElementById('dataFreshnessMeta');
    const freshCount = rows.filter(r => r.ts && Math.round((Date.now() - new Date(r.ts).getTime()) / 60000) <= staleLimit(r.src)).length;
    const staleCount = rows.filter(r => r.ts && Math.round((Date.now() - new Date(r.ts).getTime()) / 60000) > staleLimit(r.src)).length;
    const missingCount = rows.filter(r => !r.ts).length;
    if (meta) meta.textContent = `${freshCount} fresh · ${staleCount} stale · ${missingCount} missing`;
    const cols = ['Source', 'Last updated', 'Age', 'Status', 'Listings', 'Median'];
    let html = `<table class="data-freshness-tbl"><thead><tr>${cols.map(c => `<th>${c}</th>`).join('')}</tr></thead><tbody>`;
    for (const row of rows) {
      let ageMin = null, status = 'dim', statusLabel = '—';
      if (row.ts) {
        ageMin = Math.round((Date.now() - new Date(row.ts).getTime()) / 60000);
        const isStale = ageMin > staleLimit(row.src);
        status = isStale ? 'stale' : 'fresh';
        statusLabel = isStale ? 'stale' : 'fresh';
      }
      const lastUpdated = row.ts ? T.fmtDate(row.ts) : '—';
      const ageStr      = ageMin != null ? formatAge(ageMin) : '—';
      const listStr     = row.listings != null ? row.listings.toLocaleString() : (row.ts ? '—' : '');
      const medStr      = row.median != null ? `$${Number(row.median).toFixed(0)}` : (row.ts ? '—' : '');
      html += `<tr>
        <td>${row.label}</td>
        <td class="muted small">${lastUpdated}</td>
        <td>${ageStr}</td>
        <td><span class="fr-status ${status}">${statusLabel}</span></td>
        <td class="muted">${listStr}</td>
        <td>${medStr}</td>
      </tr>`;
    }
    html += '</tbody></table>';
    body.innerHTML = html;
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

  // ---------- Broker sales — by source (WP-5 + WP-6) ----------
  // Generalizes the former SG-only renderSgBrokerSales into a source-toggle panel.
  //   SG     = market broker-sales aggregate (v3 sg_broker_sales) — deepest live data,
  //            default source. Renders the original 8 KPI tiles unchanged.
  //   EVO    = OUR realized sales on the TEvo exchange (~99% seller=S4K). Aggregated
  //            CLIENT-SIDE from the v3 payload's data.orders {items, orders} — the same
  //            evo_orders ⨯ evo_order_items the All-Orders table already uses. No new
  //            RPC/fetch: get_event_evo_orders_full (mig 20260517220000) + the v3 page
  //            payload already expose this (WP-6 investigation; bot_chat 866). Only the
  //            accepted/completed states count as realized (matches adaptOrders).
  //   TP/Vivid = OUR order book on that platform (v3 cross_source_orders.{tickpick,vivid}).
  //            Shallower: only the tiles those order objects support render (D3 — omit
  //            tiles they lack, never fake zeros). Distinct labels (ORDERS/NOTIONAL) +
  //            a footnote keep the semantics honest (our orders ≠ market-wide sold).
  //   SeatData / TD = omitted (no orders backing) per W6.
  let _brokerSalesData = { sg: null, evo: null, tp: [], vivid: [] };
  let _brokerSalesSource = 'sg';

  function setBrokerSalesData(data) {
    const cso = data.cross_source_orders || {};
    _brokerSalesData = {
      sg:    data.sg_broker_sales || null,
      evo:   aggregateEvoBrokerSales(data.orders), // client-side from v3 payload (WP-6)
      tp:    Array.isArray(cso.tickpick) ? cso.tickpick : [],
      vivid: Array.isArray(cso.vivid)    ? cso.vivid    : [],
    };
    // Default to SG (deepest live data); if SG is empty but a peer has data, fall back.
    const live = brokerLiveSources();
    if (!live.includes(_brokerSalesSource)) _brokerSalesSource = live[0] || 'sg';
    renderBrokerSales(_brokerSalesSource);
  }

  // EVO realized-sales KPIs aggregated from the v3 data.orders payload (evo_orders ⨯
  // evo_order_items). Returns an object shaped like sg_broker_sales (so the SG tile
  // strip renders it) or null when the event has no accepted/completed EVO orders.
  function aggregateEvoBrokerSales(ordersPayload) {
    const items   = (ordersPayload && ordersPayload.items)  || [];
    const ordList = (ordersPayload && ordersPayload.orders) || [];
    if (!items.length) return null;
    const ordById = new Map(ordList.map(o => [o.evo_order_id, o]));
    const SOLD = new Set(['accepted', 'completed']); // realized — matches adaptOrders
    let tix = 0, gross = 0, latest = null;
    const px = [], sections = new Set(), orderIds = new Set();
    items.forEach(it => {
      const o = ordById.get(it.evo_order_id) || {};
      if (!SOLD.has(o.state)) return;
      const q = it.quantity != null ? Number(it.quantity) : null;
      const p = it.price    != null ? Number(it.price)    : null;
      orderIds.add(it.evo_order_id);
      if (q != null && !isNaN(q)) tix += q;
      if (p != null && q != null && !isNaN(p) && !isNaN(q)) gross += p * q;
      if (p != null && !isNaN(p)) px.push(p);
      const sec = it.ticket_group_section || it.section;
      if (sec != null && String(sec).trim() !== '') sections.add(String(sec).trim());
      const ts = o.evo_created_at || o.evo_updated_at || it.pulled_at;
      const tms = ts ? new Date(ts).getTime() : NaN;
      if (!isNaN(tms) && (latest == null || tms > latest)) latest = tms;
    });
    if (!orderIds.size) return null;
    px.sort((a, b) => a - b);
    return {
      sales_count:       orderIds.size,
      tickets_sold:      tix,
      gross_estimate:    gross,
      min_sale_price:    px.length ? px[0] : null,
      median_sale_price: px.length ? px[Math.floor((px.length - 1) / 2)] : null,
      max_sale_price:    px.length ? px[px.length - 1] : null,
      distinct_sections: sections.size,
      latest_sale_at:    latest != null ? new Date(latest).toISOString() : null,
    };
  }

  // Which LIVE sources actually have data for this event (D3 — drives which toggles show).
  function brokerLiveSources() {
    const d = _brokerSalesData;
    const out = [];
    const sgHas = d.sg && !d.sg.hidden &&
      (d.sg.sales_count != null || d.sg.gross_estimate != null || d.sg.tickets_sold != null);
    if (sgHas)               out.push('sg');
    if (d.evo)               out.push('evo');
    if (d.tp && d.tp.length) out.push('tp');
    if (d.vivid && d.vivid.length) out.push('vivid');
    return out;
  }

  function renderBrokerSales(source) {
    const section = document.getElementById('sg-broker-sales');
    const body = document.getElementById('sgBrokerSalesBody');
    const toggleHost = document.getElementById('brokerSalesSrcToggle');
    if (!body) return;
    const live = brokerLiveSources();
    // No live broker-sales data at all → hide the panel (preserves prior behavior).
    if (!live.length) {
      if (section) section.style.display = 'none';
      return;
    }
    if (section) section.style.display = '';
    if (!live.includes(source)) source = live[0];
    _brokerSalesSource = source;

    // ---- source-toggle row (only live sources; D3 — no fake/pending columns) ----
    if (toggleHost) {
      const LBL = { sg: 'SG', evo: 'EVO', tp: 'TP', vivid: 'Vivid' };
      toggleHost.innerHTML = live.map(k =>
        `<button type="button" class="broker-src-btn${k === source ? ' active' : ''}" data-bsrc="${k}">${LBL[k]}</button>`
      ).join('');
      toggleHost.querySelectorAll('.broker-src-btn').forEach(b =>
        b.addEventListener('click', () => renderBrokerSales(b.dataset.bsrc))
      );
    }

    // ---- body ----
    if (source === 'sg') {
      body.innerHTML = brokerKpiStripSg(_brokerSalesData.sg) +
        '<div class="cross-src-note muted small">SG = market broker-sales aggregate (all sellers, inferred from metrics)</div>';
      return;
    }
    if (source === 'evo') {
      // EVO aggregate shares the sg_broker_sales key shape → reuse the SG tile strip.
      body.innerHTML = brokerKpiStripSg(_brokerSalesData.evo) +
        '<div class="cross-src-note muted small">EVO = our realized sales on the TEvo exchange (accepted + completed orders; ~99% seller=S4K — our sell-through, not market-wide)</div>';
      return;
    }
    const arr = source === 'tp' ? _brokerSalesData.tp : _brokerSalesData.vivid;
    body.innerHTML = brokerKpiStripOrders(arr) +
      `<div class="cross-src-note muted small">${source === 'tp' ? 'TP' : 'Vivid'} = our order book on this platform (our orders, not market-wide sold)</div>`;
  }

  function brokerTile(lbl, val, small) {
    return `<div class="kpi-strip-cell"><span class="kpi-lbl">${lbl}</span><span class="kpi-val${small ? ' small' : ''}">${val}</span></div>`;
  }

  // SG market aggregate → the original 8-tile strip (tiles unchanged).
  function brokerKpiStripSg(s) {
    if (!s) return '<div class="empty">no SG broker-sales data</div>';
    const gmv = Number(s.gross_estimate) || 0;
    const tix = Number(s.tickets_sold) || 0;
    const sales = Number(s.sales_count) || 0;
    const money = v => (v != null ? '$' + T.fmtNum(Math.round(v)) : '—');
    return '<div class="kpi-strip">' + [
      brokerTile('SALES', T.fmtNum(sales)),
      brokerTile('TIX SOLD', T.fmtNum(tix)),
      brokerTile('EST GMV', '$' + T.fmtNum(Math.round(gmv))),
      brokerTile('MIN', money(s.min_sale_price)),
      brokerTile('MEDIAN', money(s.median_sale_price)),
      brokerTile('MAX', money(s.max_sale_price)),
      brokerTile('SECTIONS', T.fmtNum(s.distinct_sections)),
      brokerTile('LATEST', T.fmtDate(s.latest_sale_at), true),
    ].join('') + '</div>';
  }

  // TP/Vivid order array → only the tiles the order objects support (D3: omit lacking).
  function brokerKpiStripOrders(arr) {
    if (!arr || !arr.length) return '<div class="empty">no orders on this platform for this event</div>';
    let tix = 0, tixSeen = false, gmv = 0, gmvSeen = false, latest = null;
    const pxPer = [];
    const sections = new Set();
    arr.forEach(o => {
      const q = o.quantity != null ? Number(o.quantity) : null;
      const t = o.total != null ? Number(o.total) : null;
      if (q != null && !isNaN(q)) { tix += q; tixSeen = true; }
      if (t != null && !isNaN(t)) { gmv += t; gmvSeen = true; }
      if (t != null && q != null && q > 0 && !isNaN(t) && !isNaN(q)) pxPer.push(t / q);
      if (o.section != null && String(o.section).trim() !== '') sections.add(String(o.section).trim());
      const ts = o.ordered_at ? new Date(o.ordered_at).getTime() : NaN;
      if (!isNaN(ts) && (latest == null || ts > latest)) latest = ts;
    });
    pxPer.sort((a, b) => a - b);
    const median = pxPer.length ? pxPer[Math.floor((pxPer.length - 1) / 2)] : null;
    const cells = [brokerTile('ORDERS', T.fmtNum(arr.length))];
    if (tixSeen) cells.push(brokerTile('TIX', T.fmtNum(tix)));
    if (gmvSeen) cells.push(brokerTile('NOTIONAL', '$' + T.fmtNum(Math.round(gmv))));
    if (pxPer.length) {
      cells.push(brokerTile('MIN', '$' + T.fmtNum(Math.round(pxPer[0]))));
      cells.push(brokerTile('MEDIAN', '$' + T.fmtNum(Math.round(median))));
      cells.push(brokerTile('MAX', '$' + T.fmtNum(Math.round(pxPer[pxPer.length - 1]))));
    }
    if (sections.size) cells.push(brokerTile('SECTIONS', T.fmtNum(sections.size)));
    if (latest != null) cells.push(brokerTile('LATEST', T.fmtDate(new Date(latest).toISOString()), true));
    return '<div class="kpi-strip">' + cells.join('') + '</div>';
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
    'sg-listings': false, 'evo-listings': false,
    'sh-listings': false, 'gt-listings': false, 'vd-listings': false,
    'tp-listings': false, 'tm-listings': false,
    'sg-sales': false, 'our-orders': false,
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
      } else if (tabId === 'sh-listings' && !_tabState.loaded['sh-listings']) {
        _tabState.loaded['sh-listings'] = true;
        await loadTdPlatformListings(eventId, 'SH');
        updateTdListingsTabCount();
      } else if (tabId === 'gt-listings' && !_tabState.loaded['gt-listings']) {
        _tabState.loaded['gt-listings'] = true;
        await loadTdPlatformListings(eventId, 'GT');
        updateTdListingsTabCount();
      } else if (tabId === 'vd-listings' && !_tabState.loaded['vd-listings']) {
        _tabState.loaded['vd-listings'] = true;
        await loadTdPlatformListings(eventId, 'VD');
        updateTdListingsTabCount();
      } else if (tabId === 'tp-listings' && !_tabState.loaded['tp-listings']) {
        _tabState.loaded['tp-listings'] = true;
        await loadTdPlatformListings(eventId, 'TP');
        updateTdListingsTabCount();
      } else if (tabId === 'tm-listings' && !_tabState.loaded['tm-listings']) {
        _tabState.loaded['tm-listings'] = true;
        await loadTdPlatformListings(eventId, 'TM');
        updateTdListingsTabCount();
      } else if (tabId === 'sg-sales' && !_tabState.loaded['sg-sales']) {
        await loadSgSalesFull(eventId);
      } else if (tabId === 'td-markets' && !_tabState.loaded['td-markets']) {
        await loadTdMarketsFull(eventId);
      } else if (tabId === 'seatmap' && !_tabState.loaded['seatmap']) {
        await loadSeatmap(eventId);
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
      'sh-listings':  'paneShListings',
      'gt-listings':  'paneGtListings',
      'vd-listings':  'paneVdListings',
      'tp-listings':  'paneTpListings',
      'tm-listings':  'paneTmListings',
      'sg-sales':     'paneSgSales',
      'td-markets':   'paneTdMarkets',
      'seatmap':      'paneSeatmap',
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

  // ---------- Seat Map (interactive TEvo venue map as a section/price filter) ----------
  // The vendored @ticketevolution/seatmaps-client UMD bundle exposes window.Tevomaps.
  // venueId/configurationId come straight from public.events; the section→floor
  // ticketGroups are derived from the EVO listings firehose (reusing the same RPC the
  // "EVO Listings" tab uses). Clicking a section on the SVG calls onSelection, which
  // filters the per-section listing table on the right. Lazy-loaded on first activation.
  let _seatmapApi = null;
  let _seatmapRows = [];        // raw EVO listing rows for the per-section table
  let _seatmapSelected = [];    // section names currently selected on the map
  let _seatmapResetWired = false;
  const SEATMAP_MAPS_DOMAIN = 'https://maps.ticketevolution.com';  // lib default; we read the same manifest

  // Parking / non-seated pseudo-sections never match an SVG path (bible §3 parking
  // skip) — drop them so the legend's price scale isn't skewed by $30 parking spots.
  function _seatmapIsParking(section) {
    return /parking|garage|valet|\blot\b|min walk|mi from venue|shuttle|tailgate/i.test(section || '');
  }

  // The map MANIFEST keys sections by full descriptive names ("Lower Level Corner 104",
  // "Chase Bridges 316", "Floor 2"); our listings store only the trailing token ("104").
  // Reduce either form to a comparable "tail" — trailing digits + a short letter suffix —
  // so "Lower Level Corner 104"→"104", "105 WC"→"105wc", our "105WC"→"105wc", "Floor 2"→"2".
  function _seatmapTail(s) {
    const str = String(s == null ? '' : s).trim();
    const m = str.match(/(\d+)\s*([A-Za-z]{0,4})\s*$/);
    return m ? (m[1] + m[2]).toLowerCase() : str.toLowerCase();
  }

  // Fetch the venue/config manifest and build tail→fullKey. The library matches
  // ticketGroups' tevo_section_name EXACTLY against these keys (lowercased), so we must
  // hand it the full names, not the bare numbers. Tails that map to >1 key (e.g. "2" →
  // both "Floor 2" and "Event Level Suites 2") are dropped as ambiguous — those sections
  // stay uncolored but still appear in the listing table. Returns Map or null on failure.
  async function _seatmapBuildSectionRemap(venueId, configurationId) {
    try {
      const resp = await fetch(`${SEATMAP_MAPS_DOMAIN}/${venueId}/${configurationId}/manifest.json`);
      if (!resp.ok) return null;
      const manifest = await resp.json();
      const sections = (manifest && manifest.sections) || {};
      const tailToKey = new Map();
      const ambiguous = new Set();
      Object.keys(sections).forEach(k => {
        const t = _seatmapTail(k);
        if (!t) return;
        if (tailToKey.has(t)) ambiguous.add(t);
        else tailToKey.set(t, k);
      });
      ambiguous.forEach(t => tailToKey.delete(t));
      return tailToKey;
    } catch (_) { return null; }
  }

  // Collapse listing rows → one ticketGroup per section at its lowest retail floor (what
  // the map colors by), remapping our bare section token → the manifest's full section
  // name via `remap`. With a manifest, unmatched/ambiguous tails are skipped (left grey);
  // without one (fetch failed), we fall back to passing the bare token.
  function _seatmapTicketGroups(rows, remap) {
    const floorByTail = new Map();
    rows.forEach(r => {
      const sec = (r.section || '').trim();
      if (!sec || _seatmapIsParking(sec)) return;
      const price = Number(r.retail_price);
      if (!isFinite(price) || price <= 0) return;
      const t = _seatmapTail(sec);
      const prev = floorByTail.get(t);
      if (prev == null || price < prev) floorByTail.set(t, price);
    });
    const out = [];
    floorByTail.forEach((price, tail) => {
      const name = remap ? remap.get(tail) : tail;
      if (remap && !name) return;   // unmatched / ambiguous → skip (stays grey, still listed)
      out.push({ tevo_section_name: name || tail, retail_price: price });
    });
    return out;
  }

  async function loadSeatmap(eventId) {
    _tabState.loaded['seatmap'] = true;
    const meta = document.getElementById('seatmapMeta');
    const host = document.getElementById('seatmapHost');
    const listBody = document.getElementById('seatmapListBody');
    if (meta) meta.textContent = 'loading…';
    if (listBody) listBody.innerHTML = '<div class="empty">Loading listings…</div>';

    if (!window.Tevomaps || !window.Tevomaps.SeatmapFactory) {
      if (meta) meta.textContent = 'seatmap library not loaded';
      if (host) host.innerHTML = '<div class="empty">tevomaps.bundle.js failed to load</div>';
      return;
    }
    const Auth = window.TerminalAuth;
    if (!Auth || !Auth.client) {
      if (meta) meta.textContent = 'no auth (Path C unavailable on localhost)';
      if (host) host.innerHTML = '<div class="empty">Seat map needs an @s4kent.com session.</div>';
      return;
    }

    // (1) venue_id + configuration_id for this event (direct events read — RLS-OK).
    const evRes = await Auth.client
      .from('events')
      .select('venue_id, configuration_id, configuration_name, venue_name')
      .eq('id', eventId)
      .maybeSingle();
    if (evRes.error || !evRes.data) {
      if (meta) meta.textContent = 'event lookup failed';
      if (host) host.innerHTML = `<div class="empty">${escapeHtml(evRes.error?.message || 'no event row')}</div>`;
      return;
    }
    const venueId = evRes.data.venue_id;
    const configurationId = evRes.data.configuration_id;
    if (venueId == null || configurationId == null) {
      if (meta) meta.textContent = 'no map for this event';
      if (host) host.innerHTML = '<div class="empty">This event has no TEvo venue_id / configuration_id — no seat map available.</div>';
      if (listBody) listBody.innerHTML = '';
      return;
    }

    // (2) EVO listing floors → ticketGroups (reuses the EVO Listings tab RPC), remapped
    //     from our bare section tokens to the manifest's full section names.
    const lstRes = await rpcOrNull('get_event_evo_listings_full', { p_event_id: eventId });
    _seatmapRows = (lstRes && lstRes.data && lstRes.data.rows) || [];
    const remap = await _seatmapBuildSectionRemap(venueId, configurationId);
    const ticketGroups = _seatmapTicketGroups(_seatmapRows, remap);
    const ourTails = new Set(
      _seatmapRows.filter(r => r.section && !_seatmapIsParking(r.section)).map(r => _seatmapTail(r.section)),
    );

    // (3) Build the interactive map. build() is async in v5 → may resolve undefined.
    host.innerHTML = '';
    try {
      const factory = new window.Tevomaps.SeatmapFactory({
        venueId: String(venueId),
        configurationId: String(configurationId),
        ticketGroups,
        showLegend: true,
        showControls: true,
        mouseControlEnabled: true,
        onSelection: (sections) => onSeatmapSelection(sections),
      });
      _seatmapApi = await factory.build('seatmapHost');
    } catch (e) {
      if (meta) meta.textContent = 'map render error';
      host.innerHTML = `<div class="empty">Seat map failed to render: ${escapeHtml(String((e && e.message) || e))}</div>`;
      return;
    }

    if (meta) {
      const mapped = remap
        ? `${ticketGroups.length}/${ourTails.size} sections on map`
        : `${ticketGroups.length} sections (manifest unavailable — no coloring)`;
      meta.textContent = `venue ${venueId} · config ${configurationId}`
        + (evRes.data.configuration_name ? ` (${evRes.data.configuration_name})` : '')
        + ` · ${mapped}`;
    }
    _seatmapSelected = [];
    renderSeatmapList();
    wireSeatmapReset();
  }

  // Library fires this with the full set of currently-selected section names.
  function onSeatmapSelection(sections) {
    _seatmapSelected = Array.isArray(sections) ? sections.slice() : [];
    const label = document.getElementById('seatmapSelLabel');
    const reset = document.getElementById('seatmapResetBtn');
    if (label) {
      label.textContent = _seatmapSelected.length
        ? `Filtering ${_seatmapSelected.length} section${_seatmapSelected.length > 1 ? 's' : ''}: ${_seatmapSelected.join(', ')}`
        : 'Click a section to filter listings';
    }
    if (reset) reset.hidden = _seatmapSelected.length === 0;
    renderSeatmapList();
  }

  // The library returns selected sections as full manifest names; our rows carry bare
  // tokens — compare both via _seatmapTail so the filter matches regardless of form.
  function renderSeatmapList() {
    const body = document.getElementById('seatmapListBody');
    if (!body) return;
    const selTails = _seatmapSelected.map(_seatmapTail);
    let rows = _seatmapRows.filter(r => r.section && !_seatmapIsParking(r.section));
    if (selTails.length) rows = rows.filter(r => selTails.includes(_seatmapTail(r.section)));
    rows = rows.slice().sort((a, b) => Number(a.retail_price) - Number(b.retail_price));

    if (!rows.length) {
      body.innerHTML = `<div class="empty">${sel.length ? 'No EVO listings in the selected section(s).' : 'No EVO listings to show.'}</div>`;
      return;
    }
    const host = document.createElement('div');
    host.className = 'full-list-host';
    const tbl = document.createElement('table');
    tbl.className = 'full-list-tbl';
    tbl.innerHTML = `
      <thead><tr>
        <th>Section</th><th>Row</th><th class="num">Qty</th>
        <th class="num">Retail</th><th>Type</th>
      </tr></thead><tbody></tbody>`;
    const tb = tbl.querySelector('tbody');
    rows.slice(0, 300).forEach(r => {
      const tr = document.createElement('tr');
      if (r.is_owned) tr.className = 'owned-row';
      tr.innerHTML = `
        <td>${escapeHtml(r.section || '—')}</td>
        <td>${escapeHtml(r.row || '—')}</td>
        <td class="num">${T.fmtNum(r.quantity)}</td>
        <td class="num">${r.retail_price != null ? '$' + T.fmtNum(Math.round(r.retail_price)) : '—'}</td>
        <td>${r.is_owned ? '<span class="pill owned">ours</span>' : '<span class="pill market">market</span>'}</td>`;
      tb.appendChild(tr);
    });
    host.appendChild(tbl);
    body.innerHTML = '';
    body.appendChild(host);
  }

  function wireSeatmapReset() {
    if (_seatmapResetWired) return;
    const btn = document.getElementById('seatmapResetBtn');
    if (!btn) return;
    btn.addEventListener('click', () => {
      // Deselect each section on the map; the lib echoes onSelection back to us.
      if (_seatmapApi && typeof _seatmapApi.deselectSection === 'function') {
        _seatmapSelected.slice().forEach(s => {
          try { _seatmapApi.deselectSection(s); } catch (_) { /* ignore */ }
        });
      }
      onSeatmapSelection([]);
    });
    _seatmapResetWired = true;
  }

  // ---------- TD Listings per-platform (full) ----------
  // Queries ticketsdata_listings_snapshots for one platform (SH|GT|VD), last 26h ordered
  // newest-first so the limit captures the most-recent collection batch. Client-side filter
  // keeps only rows within 15 minutes of max(captured_at) for that platform — timing-agnostic
  // so both the 03:00 UTC and 16:20 UTC SH batches work correctly regardless of query time.
  async function loadTdPlatformListings(eventId, platform) {
    // DB stores platform uppercase (SH/GT/VD) — used for the .eq('platform', …) filter.
    // DOM IDs are title-case (tdListingsShBody / …ShMeta), so derive a title-case key.
    const platTitle = platform.charAt(0) + platform.slice(1).toLowerCase();
    const body = document.getElementById('tdListings' + platTitle + 'Body');
    const meta = document.getElementById('tdListings' + platTitle + 'Meta');
    if (body) body.innerHTML = '<div class="empty">Loading ' + escapeHtml(platform) + ' listings…</div>';
    if (meta) meta.textContent = 'loading…';
    const Auth = window.TerminalAuth;
    if (!Auth || !Auth.client || !Auth.getAccessToken()) {
      if (body) body.innerHTML = '<div class="empty">not signed in</div>';
      return;
    }
    const t0 = performance.now();
    // ticketsdata_listings_snapshots is keyed by each platform's OWN TD event id, not tevo.
    // RPC maps tevo -> TD-event-id (ticketsdata_event_xref <- aq_event_map <- sg_events_canonical)
    // and returns the latest 15-min batch, non-parking, price-sorted. (RPC get_event_td_listings)
    const res = await Auth.client.rpc('get_event_td_listings', {
      p_tevo_event_id: eventId, p_platform: platform, p_hours: 26
    });
    const elapsed = performance.now() - t0;
    if (res.error) {
      if (body) body.innerHTML = `<div class="empty">error: ${escapeHtml(res.error.message)}</div>`;
      if (meta) meta.textContent = 'error';
      return;
    }
    const rows = res.data || [];
    if (!rows.length) {
      if (body) body.innerHTML = `<div class="empty">No ${escapeHtml(platform)} listings in the latest collection batch (last 26h).</div>`;
      if (meta) meta.textContent = '0 rows';
      return;
    }
    const maxAt = rows.reduce((m, r) => (r.captured_at > m ? r.captured_at : m), rows[0].captured_at);
    const batchDate = T.fmtDate ? T.fmtDate(maxAt) : maxAt.slice(0, 16).replace('T', ' ') + ' UTC';
    // Compute summary stats
    const prices = rows.map(r => +r.list_price).filter(v => isFinite(v) && v > 0).sort((a, b) => a - b);
    const med = prices.length ? prices[Math.floor(prices.length / 2)] : null;
    const getIn = prices.length ? prices[0] : null;
    if (meta) meta.textContent =
      `${rows.length} rows · get-in ${getIn != null ? '$' + Math.round(getIn) : '—'} · med ${med != null ? '$' + Math.round(med) : '—'} · batch ${batchDate} · ${elapsed.toFixed(0)}ms`;

    const host = document.createElement('div');
    host.className = 'full-list-host';
    const tbl = document.createElement('table');
    tbl.className = 'full-list-tbl td-listings-tbl';
    tbl.innerHTML = `
      <thead><tr>
        <th>Section</th><th>Row</th>
        <th class="num">Qty</th><th class="num">List $</th><th class="num">All-in $</th>
        <th>Captured</th>
      </tr></thead><tbody></tbody>`;
    const tb = tbl.querySelector('tbody');
    const $p = v => (v != null && +v > 0 ? '$' + T.fmtNum(Math.round(+v)) : '—');
    rows.forEach(r => {
      const tr = document.createElement('tr');
      tr.innerHTML = `
        <td>${escapeHtml(r.section || '—')}</td>
        <td>${escapeHtml(r.row || '—')}</td>
        <td class="num">${r.quantity != null ? T.fmtNum(+r.quantity) : '—'}</td>
        <td class="num">${$p(r.list_price)}</td>
        <td class="num">${$p(r.price_with_fees)}</td>
        <td class="muted small">${T.fmtDate(r.captured_at)}</td>`;
      tb.appendChild(tr);
    });
    host.appendChild(tbl);
    if (body) { body.innerHTML = ''; body.appendChild(host); }
  }

  // Per-source row-count chips for the 3 top-level TD tabs (SH/GT/VD). Reads the
  // count each loadTdPlatformListings() writes into its section meta ("<n> rows · …").
  // Idempotent: updates all three chips on every call.
  function updateTdListingsTabCount() {
    for (const plat of ['Sh', 'Gt', 'Vd', 'Tp', 'Tm']) {
      const chip = document.getElementById('tabCount' + plat + 'Listings');
      if (!chip) continue;
      const meta = document.getElementById('tdListings' + plat + 'Meta');
      let n = 0;
      if (meta) {
        const m = meta.textContent.match(/^(\d+)\s+rows/);
        if (m) n = parseInt(m[1], 10);
      }
      chip.textContent = n ? String(n) : '';
    }
  }

  // ---------- Cross-Platform Sales panel (Overview tab) ----------
  // Aggregates: EVO sold metrics + SG fill_rate/sold + TD listing velocity + TP/Vivid order counts
  async function loadCrossPlatformSales(eventId) {
    const body = document.getElementById('crossSalesBody');
    const meta = document.getElementById('crossSalesMeta');
    if (body) body.innerHTML = '<div class="empty">loading…</div>';
    const Auth = window.TerminalAuth;
    if (!Auth || !Auth.client || !Auth.getAccessToken()) {
      if (body) body.innerHTML = '<div class="empty">not signed in</div>';
      return;
    }
    // Fire 4 queries in parallel
    const [evoFullRes, sgRes, tdSnapRes, xbRes] = await Promise.all([
      // EVO: realized sales aggregated from OUR TEvo orders (evo_orders ⨯ items).
      // event_metrics has NO sold_* columns — EVO sales velocity lives only in the
      // walled evo_orders, surfaced via this existing SECDEF RPC (WP-6; bot_chat 866).
      // (The prior event_metrics.sold_* query referenced columns that never existed,
      //  so the EVO sales column silently never rendered — this fixes that.)
      rpcOrNull('get_event_evo_orders_full', { p_event_id: eventId, p_limit: 500 }),
      // SG: top-20 rows — listings and sales are separate INSERT rows so we merge best-available
      // from each: listings_all_count from the most-recent listings row, sold_quantity from
      // the most-recent sales row. .limit(20) ensures we span both row types.
      Auth.client
        .from('seatgeek_event_metrics')
        .select('fill_rate,sold_quantity,sold_gross,sold_price_median,tickets_count,listings_all_count,captured_at')
        .eq('tevo_event_id', eventId)
        .order('captured_at', { ascending: false })
        .limit(20),
      // TD: last 2 snapshot rows to compute listing-count delta (proxy for sales velocity)
      Auth.client
        .from('event_listing_snapshot_daily')
        .select('snapshot_date,snapshot_slot,td_sh_listings,td_gt_listings,td_vd_listings')
        .eq('event_id', eventId)
        .order('snapshot_date', { ascending: false })
        .order('snapshot_slot', { ascending: false })
        .limit(2),
      // TP + Vivid: via SECURITY DEFINER RPC (tickpick_orders + vivid_orders are service_role only)
      rpcOrNull('get_event_cross_broker_orders_full', { p_event_id: eventId, p_limit: 500 }),
    ]);
    // Merge split SG rows: listings and sales are inserted separately by different cron functions.
    // Pick the most-recent non-null value for each field across all returned rows.
    const sgRows = sgRes.data || [];
    function sgBest(field) { return (sgRows.find(r => r[field] != null) || {})[field] ?? null; }
    const sgMerged = sgRows.length ? {
      fill_rate:         sgBest('fill_rate'),
      sold_quantity:     sgBest('sold_quantity'),
      sold_gross:        sgBest('sold_gross'),
      sold_price_median: sgBest('sold_price_median'),
      listings_all_count:sgBest('listings_all_count'),
      captured_at:       sgRows[0]?.captured_at ?? null,
    } : null;
    renderCrossPlatformSales({
      evo:    evoFullRes.error ? null : evoSalesFromFullRows(evoFullRes.data),
      sg:     sgMerged,
      tdSnap: tdSnapRes.data || [],
      xb:     xbRes.error ? null : (xbRes.data || null),
    }, meta);
  }

  // Aggregate get_event_evo_orders_full rows → the {sold_quantity, sold_gross,
  // sold_price_median, captured_at} shape the CROSS-SOURCE Sales/Velocity EVO cell
  // expects. Realized = accepted/completed states (matches adaptOrders + Broker Sales).
  // Returns null when no realized EVO orders → EVO column omitted (D3, never fake zeros).
  function evoSalesFromFullRows(full) {
    const rows = (full && full.rows) || [];
    if (!rows.length) return null;
    const SOLD = new Set(['accepted', 'completed']);
    let qty = 0, gross = 0, latest = null, any = false;
    const px = [];
    rows.forEach(r => {
      if (!SOLD.has(r.state)) return;
      any = true;
      const q = r.item_quantity != null ? Number(r.item_quantity) : null;
      const p = r.item_price    != null ? Number(r.item_price)    : null;
      if (q != null && !isNaN(q)) qty += q;
      if (p != null && q != null && !isNaN(p) && !isNaN(q)) gross += p * q;
      if (p != null && !isNaN(p)) px.push(p);
      const tms = r.evo_created_at ? new Date(r.evo_created_at).getTime() : NaN;
      if (!isNaN(tms) && (latest == null || tms > latest)) latest = tms;
    });
    if (!any) return null;
    px.sort((a, b) => a - b);
    return {
      sold_quantity:     qty,
      sold_gross:        Math.round(gross),
      sold_price_median: px.length ? px[Math.floor((px.length - 1) / 2)] : null,
      captured_at:       latest != null ? new Date(latest).toISOString() : null,
    };
  }

  function renderCrossPlatformSales(d, metaEl) {
    const body = document.getElementById('crossSalesBody');
    if (!body) return;

    const evo    = d.evo    || {};
    const sg     = d.sg     || {};
    const tdSnap = d.tdSnap || [];
    const xbRows = (d.xb && d.xb.rows) ? d.xb.rows : [];

    // TD listing-count delta (velocity proxy): newest − prior snapshot. Negative
    // means listings disappeared (likely sold = green); positive = new listings.
    const tdLatest = tdSnap[0] || null;
    const tdPrior  = tdSnap[1] || null;
    function tdPlatDelta(p) {
      const col = `td_${p}_listings`;
      if (!tdLatest || tdLatest[col] == null || !tdPrior || tdPrior[col] == null) return null;
      return tdLatest[col] - tdPrior[col];
    }
    let tdComb = null;
    for (const p of ['sh', 'gt', 'vd']) {
      const dv = tdPlatDelta(p);
      if (dv != null) tdComb = (tdComb || 0) + dv;
    }

    const tpOrders = xbRows.filter(r => (r.source || '').toLowerCase() === 'tickpick');
    const vvOrders = xbRows.filter(r => (r.source || '').toLowerCase() === 'vivid');

    // Which source columns have data (D3 — omit empty columns, never fake zeros).
    const evoHas = evo.sold_quantity != null || evo.sold_gross != null || evo.sold_price_median != null;
    const sgHas  = sg.sold_quantity != null || sg.sold_gross != null || sg.sold_price_median != null || sg.fill_rate != null;
    const xbOk   = d.xb !== null;        // RPC succeeded → our TP/Vivid order count known
    const tdHas  = tdComb != null;
    const cols = [];
    if (evoHas) cols.push('EVO');
    if (sgHas)  cols.push('SG');
    if (xbOk)   cols.push('TP');
    if (xbOk)   cols.push('Vivid');
    if (tdHas)  cols.push('TD vel');

    if (!cols.length) {
      body.innerHTML = '<div class="empty">no cross-platform sales data available</div>';
      if (metaEl) metaEl.textContent = '';
      return;
    }

    const money = v => (v == null ? '<span class="dim">—</span>' : '$' + T.fmtNum(Math.round(+v)));
    const num   = v => (v == null ? '<span class="dim">—</span>' : T.fmtNum(+v || 0));
    const pct   = v => (v == null ? '<span class="dim">—</span>' : (+(v) * 100).toFixed(1) + '%');
    function vel(v) {
      if (v == null) return '<span class="dim">—</span>';
      const cls = v < 0 ? 'pos' : v > 0 ? 'neg' : '';
      return `<span class="${cls}">${v >= 0 ? '+' : ''}${T.fmtNum(v)}</span>`;
    }

    // Per-source cell values keyed by metric. TP/Vivid carry only our order count;
    // TD carries the listing-Δ velocity proxy — the rest are — (honest gaps).
    const cell = {
      'EVO':    { qty: num(evo.sold_quantity),       med: money(evo.sold_price_median), gross: money(evo.sold_gross), fill: '<span class="dim">—</span>' },
      'SG':     { qty: num(sg.sold_quantity),        med: money(sg.sold_price_median),  gross: money(sg.sold_gross),  fill: pct(sg.fill_rate) },
      'TP':     { qty: num(tpOrders.length || null), med: '<span class="dim">—</span>', gross: '<span class="dim">—</span>', fill: '<span class="dim">—</span>' },
      'Vivid':  { qty: num(vvOrders.length || null), med: '<span class="dim">—</span>', gross: '<span class="dim">—</span>', fill: '<span class="dim">—</span>' },
      'TD vel': { qty: vel(tdComb),                  med: '<span class="dim">—</span>', gross: '<span class="dim">—</span>', fill: '<span class="dim">—</span>' },
    };
    const metricRows = [
      ['Sold / net qty', 'qty'],
      ['Sold median $',  'med'],
      ['Sold gross $',   'gross'],
      ['Fill rate',      'fill'],
    ];

    const tbl = document.createElement('table');
    tbl.className = 'cross-src-tbl cross-sales-tbl';
    tbl.innerHTML =
      `<thead><tr><th>Metric</th>${cols.map(c => `<th class="num">${escapeHtml(c)}</th>`).join('')}</tr></thead>` +
      `<tbody>${metricRows.map(([label, key]) =>
        `<tr><td>${escapeHtml(label)}</td>${cols.map(c => `<td class="num">${cell[c][key]}</td>`).join('')}</tr>`
      ).join('')}</tbody>`;
    body.innerHTML = '';
    body.appendChild(tbl);

    // Mixed-semantics footnote (sources measure different things) + TD per-platform detail.
    const notes = [];
    if (evoHas) notes.push('EVO = our realized sales (accepted/completed orders)');
    if (sgHas)  notes.push('SG = market sold (inferred from metrics)');
    if (xbOk)   notes.push('TP/Vivid = our order count');
    if (tdHas) {
      const detail = [];
      for (const p of ['sh', 'gt', 'vd']) {
        const dv = tdPlatDelta(p);
        if (dv != null) detail.push(`${p.toUpperCase()} ${dv >= 0 ? '+' : ''}${dv}`);
      }
      notes.push(`TD vel = listing-Δ proxy${detail.length ? ' (' + detail.join(' · ') + ')' : ''}; negative = likely sold`);
    }
    if (notes.length) {
      const note = document.createElement('div');
      note.className = 'cross-src-note muted small';
      note.textContent = notes.join(' · ');
      body.appendChild(note);
    }

    const parts = [];
    if (evo.captured_at) parts.push(`EVO ${T.fmtDate(evo.captured_at)}`);
    if (sg.captured_at)  parts.push(`SG ${T.fmtDate(sg.captured_at)}`);
    if (tdLatest)        parts.push(`TD ${tdLatest.snapshot_date} ${tdLatest.snapshot_slot}`);
    if (metaEl) metaEl.textContent = parts.join(' · ');
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

  // Cache the last cross-source payload + overrides so we can re-render when v3
  // data arrives (override sold_price_median with the v3 sg_broker_sales
  // aggregate, matching the BROKER SALES panel) or when _lastTdSnap arrives
  // (paint the TD per-source columns). Both re-renders go through the same fn.
  let _lastCrossSource = null;
  let _lastCrossSourceOverrides = null;

  function renderCrossSourceMetrics(d, ms, overrides) {
    _lastCrossSource = d;
    if (overrides) _lastCrossSourceOverrides = overrides;
    const body = document.getElementById('crossSourceBody');
    const meta = document.getElementById('crossSourceMeta');
    if (!body) return;
    const rows = (d && d.rows) || [];
    const hasSg  = d && d.sg_event_id != null;

    // TD per-source columns (SH/GT/VD — individual sub-sources only) are fed FE-only
    // from the cached daily snapshot (_lastTdSnap ← event_listing_snapshot_daily via
    // loadTdFreshness) — NOT this RPC. That table carries median + listing-count only
    // (no get-in / spread), so those rows show — for TD and are never fabricated (WP-2).
    const td = _lastTdSnap || null;
    // TD sub-source columns are DYNAMIC: each appears only if it has data in the latest
    // daily snapshot (D3 — omit empty, never fake). SH/GT/VD live now; TP/TM/TMr arrive
    // once A1's compute_event_listing_snapshot rollup populates them (cols added 2026-05-29).
    // TM = box-office FACE VALUE (primary, NOT a resale floor); TMr = verified resale —
    // labeled distinctly per PROJECT_BIBLE §3 landmine.
    const TD_SUBS = [
      { label: 'SH',  med: 'td_sh_median',        cnt: 'td_sh_listings' },
      { label: 'GT',  med: 'td_gt_median',        cnt: 'td_gt_listings' },
      { label: 'VD',  med: 'td_vd_median',        cnt: 'td_vd_listings' },
      { label: 'TP',  med: 'td_tp_median',        cnt: 'td_tp_listings' },
      { label: 'TM',  med: 'td_tm_median',        cnt: 'td_tm_listings' },
      { label: 'TMr', med: 'td_tm_resale_median', cnt: 'td_tm_resale_listings' },
    ];
    const tdCols = td ? TD_SUBS.filter(s => td[s.med] != null || td[s.cnt] != null) : [];
    const hasTd = tdCols.length > 0;
    const hasTmCols = tdCols.some(s => s.label === 'TM' || s.label === 'TMr');
    // Per-row TD value for a sub-source column; only median + listing-count have
    // per-source backing in the daily table (get-in/spread/etc → — for TD).
    function tdCellVal(sub, label) {
      if (!td) return null;
      if (label === 'Median price')   return td[sub.med];
      if (label === 'Listings count') return td[sub.cnt];
      return null;
    }

    if (meta) {
      const parts = [];
      if (hasSg) parts.push(`sg_event_id ${d.sg_event_id}`);
      else        parts.push('no SG bridge — TEvo-only event');
      if (hasTd) {
        const tdHint = tdCols
          .filter(s => td[s.cnt] != null)
          .map(s => `${s.label} ${T.fmtNum(Number(td[s.cnt]))}`).join(' · ');
        if (tdHint) parts.push('TD: ' + tdHint);
      }
      if (ms != null) parts.push(ms.toFixed(0) + 'ms');
      meta.textContent = parts.filter(Boolean).join(' · ');
    }
    if (!rows.length) {
      body.innerHTML = '<div class="empty">no metrics available</div>';
      return;
    }
    // Override "Realized sale median" SG cell with v3 sg_broker_sales aggregate
    // when available (the BROKER SALES panel's source of truth).
    const realizedOverride = overrides && overrides.realized_sale_median_sg;
    function fmtVal(v, isMoney) {
      if (v === null || v === undefined) return '<span class="dim">—</span>';
      const n = Number(v);
      if (!Number.isFinite(n)) return '<span class="dim">—</span>';
      if (isMoney) return '$' + T.fmtNum(Math.round(n));
      return T.fmtNum(n);
    }
    const tdHead = tdCols.map(s => `<th class="num td-mkt-col">${escapeHtml(s.label)}</th>`).join('');
    const tbl = document.createElement('table');
    tbl.className = 'cross-src-tbl';
    tbl.innerHTML = `
      <thead><tr>
        <th>Metric</th>
        <th class="num">TEvo</th>
        <th class="num">SG</th>
        ${tdHead}
      </tr></thead>
      <tbody></tbody>`;
    const tb = tbl.querySelector('tbody');
    rows.forEach(r => {
      const tr = document.createElement('tr');
      let sgVal = r.sg;
      if (r.label === 'Realized sale median' && realizedOverride != null) sgVal = realizedOverride;
      let tdCells = '';
      if (hasTd) {
        tdCells = tdCols.map(s =>
          `<td class="num td-mkt-col">${fmtVal(tdCellVal(s, r.label), r.is_money)}</td>`
        ).join('');
      }
      tr.innerHTML = `
        <td>${escapeHtml(r.label || '')}</td>
        <td class="num">${fmtVal(r.tevo, r.is_money)}</td>
        <td class="num">${fmtVal(sgVal,  r.is_money)}</td>
        ${tdCells}`;
      tb.appendChild(tr);
    });
    body.innerHTML = '';
    body.appendChild(tbl);
    // Honesty note when Ticketmaster columns are present: TM is box-office face value,
    // not a resale floor like the other TD sources (PROJECT_BIBLE §3 landmine).
    if (hasTmCols) {
      const note = document.createElement('div');
      note.className = 'cross-src-note muted small';
      note.textContent = 'TM = Ticketmaster box-office face value (primary); TMr = verified resale';
      body.appendChild(note);
    }
  }

  // Re-render the cross-source table from cached state — used after _lastTdSnap
  // arrives (paint TD per-source columns) while re-applying any v3 override.
  function rerenderCrossSource() {
    if (!_lastCrossSource) return;
    renderCrossSourceMetrics(_lastCrossSource, null, _lastCrossSourceOverrides || undefined);
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
  // Per-chart fetcher: each chart calls this with its own window. Updates the
  // matching cache (_chartExtStatePrice or _chartExtStateInv) and re-renders
  // ONLY that chart. PR redesign v2 — two fully independent loaders.
  async function loadChartExtended(chartKey, eventId, hours) {
    const res = await rpcOrNull('get_event_chart_extended', {
      p_event_id: eventId,
      p_chart_hours: hours || DEFAULT_HOURS,
    });
    if (res.error) {
      if (res.error.code === '42883' || /does not exist/i.test(res.error.message || '')) {
        return;
      }
      console.error('[chartExtended ' + chartKey + ']', res.error);
      return;
    }
    setChartExtended(chartKey, res.data || null);
  }

  function setChartExtended(chartKey, payload) {
    if (chartKey === 'price') _chartExtStatePrice.payload = payload;
    else                       _chartExtStateInv.payload   = payload;
    // Trigger re-render of the matching chart only IF the TEvo-side payload
    // is already in. adaptChart is idempotent.
    if (_lastPayload && _lastPayload.chart_data) {
      try {
        const chart = adaptChart(_lastPayload.chart_data);
        if (chartKey === 'price') {
          renderChartPrice(chart, _chartExtAlerts);
        } else {
          renderChartInventory(chart);
        }
        // Refresh both detailed legends + the source-toggle + overlay legends
        // (source presence can change once SG/ext series arrive).
        refreshChartLegends();
      } catch (e) {
        console.error('[setChartExtended ' + chartKey + ' re-render]', e);
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

    // Append TD MARKETS section if snapshot data is already loaded
    if (_lastTdSnap) {
      const tdSnap = _lastTdSnap;
      // All 5 TD platforms + TM resale split; TM MED = box-office face value (primary),
      // TMr = verified resale (PROJECT_BIBLE §3 landmine). Only tiles with data render
      // (D3) — TP/TM appear once A1's daily rollup populates them (cols added 2026-05-29).
      const tdFieldDefs = [
        ['td_sh_listings',        'SH LISTINGS',  null],
        ['td_sh_median',          'SH MED',       '$'],
        ['td_gt_listings',        'GT LISTINGS',  null],
        ['td_gt_median',          'GT MED',       '$'],
        ['td_vd_listings',        'VD LISTINGS',  null],
        ['td_vd_median',          'VD MED',       '$'],
        ['td_tp_listings',        'TP LISTINGS',  null],
        ['td_tp_median',          'TP MED',       '$'],
        ['td_tm_listings',        'TM LISTINGS',  null],
        ['td_tm_median',          'TM FACE',      '$'],
        ['td_tm_resale_listings', 'TMr LISTINGS', null],
        ['td_tm_resale_median',   'TMr MED',      '$'],
        ['td_combined_median',    'TD COMBINED',  '$'],
      ];
      const tdFields = tdFieldDefs.filter(([col]) => tdSnap[col] != null);
      const tdCells = tdFields.map(([col, label, prefix]) => {
        const v = tdSnap[col];
        const valHtml = (v != null)
          ? `<span class="last-snap-val">${prefix === '$' ? '$' : ''}${T.fmtNum(Math.round(+v))}</span>`
          : `<span class="last-snap-val dim">—</span>`;
        return `<div class="last-snap-cell"><span class="last-snap-lbl">${label}</span>${valHtml}</div>`;
      }).join('');
      const tdSection = document.createElement('div');
      tdSection.innerHTML =
        `<div class="last-snap-divider">TD MARKETS — ${escapeHtml(tdSnap.snapshot_date || '')} ${escapeHtml(tdSnap.snapshot_slot || '')}</div>` +
        `<div class="last-snap-grid">${tdCells}</div>`;
      body.appendChild(tdSection);
    }
  }

  // ---------- TD Markets — raw per-listing data from ticketsdata_listings_snapshots ----------
  // Shows the latest fetch window of individual listing rows per platform (SH · GT · VD),
  // mirroring the EVO Listings and SG Listings tabs. Non-parking only.
  async function loadTdMarketsListings(eventId) {
    const body  = document.getElementById('tdMarketsListingsBody');
    const meta  = document.getElementById('tdMarketsListingsMeta');
    if (body) body.innerHTML = '<div class="empty">Loading TD listings…</div>';
    const Auth = window.TerminalAuth;
    if (!Auth || !Auth.client || !Auth.getAccessToken()) {
      if (body) body.innerHTML = '<div class="empty">not signed in</div>';
      return;
    }
    // Fetch the last 24h of listing rows (non-parking), newest first, limit 500
    const since = new Date(Date.now() - 24 * 3600 * 1000).toISOString();
    const res = await Auth.client
      .from('ticketsdata_listings_snapshots')
      .select('platform,section,row,quantity,list_price,price_with_fees,captured_at,is_parking')
      .eq('event_id', eventId)
      .eq('is_parking', false)
      .gte('captured_at', since)
      .order('captured_at', { ascending: false })
      .order('platform')
      .order('list_price')
      .limit(500);
    if (res.error) {
      if (body) body.innerHTML = `<div class="empty">error: ${escapeHtml(res.error.message)}</div>`;
      if (meta) meta.textContent = 'error';
      return;
    }
    const rows = res.data || [];
    if (!rows.length) {
      if (body) body.innerHTML = '<div class="empty">No TD listing rows in the last 24h for this event. Data started 2026-05-27 — sparse initially.</div>';
      if (meta) meta.textContent = '0 rows';
      return;
    }
    // Group by platform for summary header
    const byPlatform = {};
    for (const r of rows) {
      (byPlatform[r.platform] = byPlatform[r.platform] || []).push(r);
    }
    const platforms = Object.keys(byPlatform).sort();
    const summaryParts = platforms.map(p => {
      const ps = byPlatform[p];
      const prices = ps.map(r => +r.list_price).filter(v => isFinite(v) && v > 0).sort((a, b) => a - b);
      const median = prices.length ? prices[Math.floor(prices.length / 2)] : null;
      return `${p}: ${ps.length} listings${median ? ' · $' + Math.round(median) + ' median' : ''}`;
    });
    if (meta) meta.textContent = `${rows.length} rows · ${summaryParts.join(' · ')}`;
    const $p  = v => (v != null && +v > 0 ? '$' + T.fmtNum(Math.round(+v)) : '—');
    const tbl = document.createElement('table');
    tbl.className = 'td-listings-tbl';
    tbl.innerHTML = `
      <thead><tr>
        <th>Platform</th><th>Section</th><th>Row</th>
        <th class="num">Qty</th><th class="num">List $</th><th class="num">All-in $</th>
        <th>Captured</th>
      </tr></thead><tbody></tbody>`;
    const tb = tbl.querySelector('tbody');
    rows.forEach(r => {
      const tr = document.createElement('tr');
      const platCls = r.platform === 'SH' ? 'td-sh' : r.platform === 'GT' ? 'td-gt' : r.platform === 'VD' ? 'td-vd' : '';
      tr.innerHTML = `
        <td><span class="badge ${platCls}">${escapeHtml(r.platform)}</span></td>
        <td>${escapeHtml(r.section || '—')}</td>
        <td>${escapeHtml(r.row || '—')}</td>
        <td class="num">${r.quantity != null ? T.fmtNum(+r.quantity) : '—'}</td>
        <td class="num">${$p(r.list_price)}</td>
        <td class="num">${$p(r.price_with_fees)}</td>
        <td class="muted small">${T.fmtDate(r.captured_at)}</td>`;
      tb.appendChild(tr);
    });
    if (body) { body.innerHTML = ''; body.appendChild(tbl); }
  }

  // ---------- Util ----------

  // ---------- TD Markets (full) ----------
  // Reads event_listing_snapshot_daily for this event (event_id = tevo_event_id).
  // Shows: (a) latest snapshot KPI strip with cross-source medians + spreads,
  //        (b) full history table ordered newest-first.
  // TD data started 2026-05-27 — table will be sparse initially.
  async function loadTdMarketsFull(eventId) {
    _tabState.loaded['td-markets'] = true;
    const snapBody   = document.getElementById('tdMarketsSnapshotBody');
    const latestBody = document.getElementById('tdMarketsLatestBody');
    const meta       = document.getElementById('tdMarketsSnapshotMeta');
    const countEl    = document.getElementById('tabCountTdMarkets');
    if (snapBody)   snapBody.innerHTML   = '<div class="empty">Loading…</div>';
    if (latestBody) latestBody.innerHTML = '<div class="empty">Loading…</div>';
    // Fire listings fetch in parallel (separate table, separate auth check)
    loadTdMarketsListings(eventId).catch(e => console.error('[td-listings]', e));
    const Auth = window.TerminalAuth;
    if (!Auth || !Auth.client || !Auth.getAccessToken()) {
      if (snapBody) snapBody.innerHTML = '<div class="empty">not signed in</div>';
      return;
    }
    const res = await Auth.client
      .from('event_listing_snapshot_daily')
      .select('snapshot_date,snapshot_slot,evo_retail_median,sg_all_median,td_sh_listings,td_sh_median,td_gt_listings,td_gt_median,td_vd_listings,td_vd_median,td_combined_median,captured_at')
      .eq('event_id', eventId)
      .order('snapshot_date', { ascending: false })
      .order('snapshot_slot', { ascending: false })
      .limit(30);
    if (res.error) {
      if (snapBody) snapBody.innerHTML = '<div class="empty">error: ' + escapeHtml(res.error.message) + '</div>';
      return;
    }
    const rows = res.data || [];
    if (meta) meta.textContent = rows.length ? rows.length + ' snapshot rows' : 'no data yet';
    if (countEl) countEl.textContent = rows.length ? String(rows.length) : '';
    if (!rows.length) {
      const msg = '<div class="empty">No TD market snapshots yet — data started 2026-05-27, accumulating daily.</div>';
      if (snapBody)   snapBody.innerHTML   = msg;
      if (latestBody) latestBody.innerHTML = msg;
      return;
    }
    // Latest row KPI strip
    const lat = rows[0];
    const $p  = v => (v != null ? '$' + T.fmtNum(Math.round(+v)) : '—');
    const $n  = v => (v != null ? T.fmtNum(+v) : '—');
    const spread = (a, b) => {
      if (a == null || b == null || +b === 0) return '—';
      return (((+a - +b) / +b) * 100).toFixed(1) + '%';
    };
    if (latestBody) latestBody.innerHTML = `
      <div class="kpi-strip">
        <div class="kpi-strip-cell"><span class="kpi-lbl">EVO RETAIL</span><span class="kpi-val">${$p(lat.evo_retail_median)}</span></div>
        <div class="kpi-strip-cell"><span class="kpi-lbl">SG ALL</span><span class="kpi-val">${$p(lat.sg_all_median)}</span></div>
        <div class="kpi-strip-cell"><span class="kpi-lbl">SH MEDIAN</span><span class="kpi-val">${$p(lat.td_sh_median)}<br><span class="muted small">${$n(lat.td_sh_listings)} listings</span></span></div>
        <div class="kpi-strip-cell"><span class="kpi-lbl">GT MEDIAN</span><span class="kpi-val">${$p(lat.td_gt_median)}<br><span class="muted small">${$n(lat.td_gt_listings)} listings</span></span></div>
        <div class="kpi-strip-cell"><span class="kpi-lbl">VD MEDIAN</span><span class="kpi-val">${$p(lat.td_vd_median)}<br><span class="muted small">${$n(lat.td_vd_listings)} listings</span></span></div>
        <div class="kpi-strip-cell"><span class="kpi-lbl">TD BEST</span><span class="kpi-val">${$p(lat.td_combined_median)}</span></div>
        <div class="kpi-strip-cell"><span class="kpi-lbl">SH÷EVO</span><span class="kpi-val">${spread(lat.td_sh_median, lat.evo_retail_median)}</span></div>
        <div class="kpi-strip-cell"><span class="kpi-lbl">GT÷SH</span><span class="kpi-val">${spread(lat.td_gt_median, lat.td_sh_median)}</span></div>
        <div class="kpi-strip-cell"><span class="kpi-lbl">VD÷SH</span><span class="kpi-val">${spread(lat.td_vd_median, lat.td_sh_median)}</span></div>
      </div>
      <div class="muted small" style="margin-top:4px">Snapshot: ${escapeHtml(lat.snapshot_date)} ${escapeHtml(lat.snapshot_slot)}</div>`;
    // History table
    const tbl = document.createElement('table');
    tbl.className = 'td-markets-tbl';
    tbl.innerHTML = `
      <thead><tr>
        <th>Date</th><th>Slot</th>
        <th class="num">EVO</th><th class="num">SG</th>
        <th class="num">SH L</th><th class="num">SH $</th>
        <th class="num">GT L</th><th class="num">GT $</th>
        <th class="num">VD L</th><th class="num">VD $</th>
        <th class="num">TD Best</th>
        <th class="num">SH÷EVO%</th><th class="num">GT÷SH%</th><th class="num">VD÷SH%</th>
      </tr></thead><tbody></tbody>`;
    const tb = tbl.querySelector('tbody');
    rows.forEach(r => {
      const spd = (a, b) => {
        if (a == null || b == null || +b === 0) return '—';
        const v = ((+a - +b) / +b) * 100;
        return '<span class="' + (v > 0 ? 'pos' : v < 0 ? 'neg' : '') + '">' + v.toFixed(1) + '%</span>';
      };
      const tr = document.createElement('tr');
      tr.innerHTML = `
        <td>${escapeHtml(r.snapshot_date)}</td>
        <td>${escapeHtml(r.snapshot_slot)}</td>
        <td class="num">${$p(r.evo_retail_median)}</td>
        <td class="num">${$p(r.sg_all_median)}</td>
        <td class="num">${$n(r.td_sh_listings)}</td><td class="num">${$p(r.td_sh_median)}</td>
        <td class="num">${$n(r.td_gt_listings)}</td><td class="num">${$p(r.td_gt_median)}</td>
        <td class="num">${$n(r.td_vd_listings)}</td><td class="num">${$p(r.td_vd_median)}</td>
        <td class="num">${$p(r.td_combined_median)}</td>
        <td class="num">${spd(r.td_sh_median, r.evo_retail_median)}</td>
        <td class="num">${spd(r.td_gt_median, r.td_sh_median)}</td>
        <td class="num">${spd(r.td_vd_median, r.td_sh_median)}</td>`;
      tb.appendChild(tr);
    });
    if (snapBody) { snapBody.innerHTML = ''; snapBody.appendChild(tbl); }
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

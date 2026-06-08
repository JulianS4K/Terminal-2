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
  // ESPN overlay markers (injury / game-state) ON by default; toggle via the
  // ESPN chip in the overlay legend, persisted in localStorage.
  const _ESPN_LS_KEY = 'd0_chart_show_espn';
  let _showEspn = !(typeof localStorage !== 'undefined' && localStorage.getItem(_ESPN_LS_KEY) === '0');
  // Cached v2 `espn` payload (team_standings / injuries / recent_results) — used
  // by the chart's ESPN context strip + marker tooltips for team-name lookup.
  let _espnInfo = null;
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
  // Durable cross-source daily series (event_listing_snapshot_daily — INDEFINITE
  // retention per the 2026-05-31 ladder, mig 20260531180000). This is the
  // LONG-HORIZON backbone: it is spliced in BEFORE the fine-grained series so a
  // line keeps going past the 30d firehose / 120d event_metrics sweep windows
  // instead of cutting off (the retention-mismatch fix). The table is young
  // (started 2026-05-27) so depth is shallow today and deepens as it fills.
  // Shape: { med:{evo_owned,evo_mkt,sg_list,sg_own,sh,gt,vd}, cnt:{evo_own,evo_tix,sg_tix,sh,gt,vd} }.
  let _dailyDurable = null;
  // TD inv listing-count series: StubHub shows by default; the other five
  // (GT/VD/TP/TM/TMr) start hidden and are user-togglable in the legend
  // (operator request 2026-06-08 — keep first paint clean, SH as the reference).
  ['td-gt-cnt', 'td-vd-cnt',
   'td-tp-cnt', 'td-tm-cnt', 'td-tmr-cnt'].forEach(k => _chartVisible.set(k, false));
  // Declutter the default view (UI rebuild 2026-06-03): the redundant/secondary
  // medians start hidden — the user opts them in from the legend. Keeps the
  // first paint to one clean line per source instead of 9 overlapping lines.
  ['prices_nonowned', 'sg_own_med'].forEach(k => _chartVisible.set(k, false));

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
    wireSeatdataSalesWindow(eventId);
    // Path-C-only enrichment RPCs fire in parallel — render even when
    // fetchPayload (Path A / Path C v3) fails. PR #205 cross-source +
    // PR redesign localized weather + SG zones/splits all independent.
    loadCrossSourceMetrics(eventId).catch(e => console.error('[crossSource]', e));
    loadSeatmapTabVisibility(eventId).catch(e => console.error('[seatmapTab]', e));
    loadWeatherLocalized(eventId).catch(e => console.error('[weatherLocalized]', e));
    loadSgZonesSplits(eventId).catch(e => console.error('[sgZonesSplits]', e));
    loadCrossPlatformSales(eventId).catch(e => console.error('[crossSales]', e));
    loadHeroMoverChip(eventId).catch(e => console.error('[moverChip]', e));
    loadHeroGapChips(eventId).catch(e => console.error('[gapChips]', e));
    loadSourceLinks(eventId).catch(e => console.error('[sourceLinks]', e));
    wireTrackButton(eventId).catch(e => console.error('[track]', e));
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
      updateLayerHint(hrs);
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
    updateLayerHint(_chartPriceHours);
  }

  // Data-layer hint: above the 30d firehose sweep window the durable daily
  // snapshot is the only history, so emphasize that the line goes hybrid. ≤30d
  // is purely high-resolution. Honest about which layer the user is looking at.
  function updateLayerHint(hours) {
    const el = document.getElementById('chartLayerHint');
    if (!el) return;
    const hybrid = (hours || DEFAULT_HOURS) > 720;
    el.classList.toggle('hybrid', hybrid);
    el.innerHTML = hybrid
      ? '● hourly &nbsp;+&nbsp; <b>○ daily history</b>'
      : '● hourly';
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
    _eventStartMs = Date.parse(ev.occurs_at_local || ev.occurs_at || '') || NaN;

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
  // Top (price) pane x-axis: keep the vertical gridlines + ticks for alignment,
  // but blank the date labels — only the bottom (inventory) pane shows the date
  // row, so the shared time axis isn't printed twice between the stacked panes.
  const X_AXIS_TOP = Object.assign({}, X_AXIS, {
    values: (u, splits) => splits.map(() => ''),
    size: 16,
  });

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

  // Splice a durable daily series UNDER a fine-grained series (retention-mismatch
  // fix, UI rebuild 2026-06-03). `fine` = high-resolution recent points
  // (event_metrics / SG firehose, capped at the source's sweep window); `daily` =
  // low-resolution but INDEFINITELY-retained points from
  // event_listing_snapshot_daily. We keep every fine point and prepend only the
  // daily points OLDER than the earliest fine point, yielding ONE continuous line
  // per source whose history depth = max(both layers) — so SG no longer stops at
  // 30d while TEvo runs to 120d. Both inputs are chronological {t,v}.
  function mergeDurable(fine, daily) {
    fine = fine || []; daily = daily || [];
    if (!daily.length) return fine;
    if (!fine.length) return daily;
    let firstFineMs = Infinity;
    for (const p of fine) { const ms = new Date(p.t).getTime(); if (ms < firstFineMs) firstFineMs = ms; }
    const older = daily.filter(p => new Date(p.t).getTime() < firstFineMs);
    return older.length ? older.concat(fine) : fine;
  }

  // Convenience: pull a durable median/count series by key, [] when not loaded yet.
  function durMed(key) { return (_dailyDurable && _dailyDurable.med && _dailyDurable.med[key]) || []; }
  function durCnt(key) { return (_dailyDurable && _dailyDurable.cnt && _dailyDurable.cnt[key]) || []; }

  // X-axis clip range for a given hours window. Returns [minSec, maxSec].
  // The left edge is the requested window start clamped FORWARD to the first
  // data point, so a window wider than the available history (esp. ALL =
  // 4320h/180d) never pads the axis with empty pre-data space. The axis then
  // spans only the days we actually have chart data for — selecting ALL fits
  // to all-available-data instead of a fixed 180-day frame.
  function clipRangeForHours(hours, xs) {
    if (!xs || !xs.length) return undefined;
    const nowSec = Math.floor(Date.now() / 1000);
    const reqMin = nowSec - hours * 3600;
    const dataMin = xs[0];                 // xs is chronological (buildSeriesData sorts)
    const dataMax = xs[xs.length - 1];
    // Fit-to-history (UI rebuild 2026-06-03): when the window is WIDER than the
    // history we actually have (e.g. 1y/ALL on the young durable table), clamp
    // the left edge to the earliest real point so we don't render a vast empty
    // gutter with the data crammed at the right. When we have MORE history than
    // the window (short ranges), reqMin wins and the window is honored as before.
    const minSec = Math.max(reqMin, dataMin);
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
    // Each median line splices its durable daily history (long horizon, indefinite)
    // under its fine-grained recent points so the line is continuous past the
    // firehose/event_metrics sweep windows. TD lines ARE the daily series already.
    // Visual rebuild: one hue per source (owned = solid bold, market = thin solid,
    // secondary = dotted), no more competing dash patterns.
    const specs = [
      { key: 'prices_owned',    label: 'TEvo owned',  color: '#fbbf24', width: 2,   dash: null,    data: mergeDurable(chart.prices_owned,    durMed('evo_owned')) },
      { key: 'prices_market',   label: 'TEvo market', color: '#a8a29e', width: 1.25, dash: null,   data: mergeDurable(chart.prices_market,   durMed('evo_mkt')) },
      { key: 'prices_nonowned', label: 'TEvo non-own',color: '#a78bfa', width: 1,   dash: [2, 3],  data: chart.prices_nonowned },
      { key: 'sg_list_med',     label: 'SG market',   color: '#22d3ee', width: 1.5, dash: null,    data: mergeDurable(extSeries.sg_listings_median       || [], durMed('sg_list')) },
      { key: 'sg_own_med',      label: 'SG owned',    color: '#fb7185', width: 1,   dash: [2, 3],  data: mergeDurable(extSeries.sg_listings_owned_median || [], durMed('sg_own')) },
      { key: 'sg_sale_med',     label: 'SG sales',    color: '#84cc16', width: 1.5, dash: [6, 3],  data: extSeries.sg_sales_median          || [] },
      { key: 'sd_sale_med',     label: 'SeatData sales', color: '#f59e0b', width: 1.5, dash: [6, 3], data: extSeries.sd_sales_median        || [] },
      { key: 'td_sh_med',       label: 'StubHub',     color: '#f97316', width: 1.25, dash: null,   data: tdS.sh || durMed('sh') },
      { key: 'td_gt_med',       label: 'GameTime',    color: '#34d399', width: 1.25, dash: null,   data: tdS.gt || durMed('gt') },
      { key: 'td_vd_med',       label: 'VividSeats',  color: '#c084fc', width: 1.25, dash: null,   data: tdS.vd || durMed('vd') },
    ];
    const { xs } = buildSeriesData(specs);

    // "Overall median" — quantity-weighted, carry-forward consensus across all
    // listing sources: EVO (live) + SG (live) + the six TicketsData books
    // (SH/GT/VD/TP/TM/TMr, carried at their own cadence). Weighted by each
    // source's listing count; slow books are assumed-till-next-refresh and only
    // dropped when stranded past 3×τ. Drawn last (bold white) as the headline.
    const tdF = _tdFamily || {};
    const tdSrc = (k) => ({ med: (tdF[k] && tdF[k].med) || [], cnt: (tdF[k] && tdF[k].cnt) || [] });
    const overallProjected = buildOverallConsensus(xs, [
      { cad: 'EVO', med: chart.prices_market || [],               cnt: chart.counts_market || [] },
      { cad: 'SG',  med: extSeries.sg_listings_median || [],       cnt: extSeries.sg_listings_count || [] },
      { cad: 'SH',  ...tdSrc('sh') },
      { cad: 'GT',  ...tdSrc('gt') },
      { cad: 'VD',  ...tdSrc('vd') },
      { cad: 'TP',  ...tdSrc('tp') },
      { cad: 'TM',  ...tdSrc('tm') },
      { cad: 'TMr', ...tdSrc('tmr') },
    ]);
    specs.push({ key: 'overall_med', label: 'Overall median', color: '#ffffff',
                 width: 3, dash: null, data: [], projected: overallProjected });

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
        X_AXIS_TOP,
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
          // Off-peak (after-hours) shading first so it sits under the markers.
          (u) => drawOffPeakBands(u),
          // Read _showAlerts at draw time so the toggle takes effect via redraw()
          // without rebuilding the chart instance.
          (u) => drawAlertsMarkers(u, _showAlerts ? (_chartExtAlerts || []) : []),
        ],
        // ESPN markers are visible + hoverable DOM glyphs (not canvas) so the
        // hit-target always lines up with the glyph. Re-place them on ready /
        // resize / scale-change (drag-zoom) so they track the data.
        ready:    [(u) => renderEspnMarkers(u, host)],
        setSize:  [(u) => renderEspnMarkers(u, host)],
        setScale: [(u) => renderEspnMarkers(u, host)],
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

  // Y-axis range — always 10% above the maximum value currently in view.
  //
  // `initMax` is supplied by uPlot already scoped to (a) only the series on THIS
  // scale and (b) only the points inside the current x-window, so the top tracks
  // the on-screen data as the time range changes or prices climb toward the
  // event — no line is ever clipped, and a single spike just lifts the top.
  function robustYRange(u, initMin, initMax) {
    var mx = (initMax != null && isFinite(initMax)) ? initMax : 1;
    return [0, mx > 0 ? mx * 1.1 : 1];
  }

  // Count-axis range — for the inventory pane's integer count scales (left 'y'
  // lines + right 'yr' bars). uPlot's initMax is already per-scale + in-view, so
  // this is adaptive and (unlike robustYRange) never folds the other axis's
  // series into the range. 10% headroom (matches the price pane) keeps the
  // tallest line/bar off the frame.
  function countYRange(u, initMin, initMax) {
    var mx = (initMax != null && isFinite(initMax)) ? initMax : 1;
    return [0, mx > 0 ? mx * 1.1 : 1];
  }

  // Integer-only tick increments for count axes — prevents uPlot from picking
  // fractional steps (0.5, 0.2…) that round to duplicate labels ("1,1,2,2").
  const COUNT_INCRS = [1, 2, 5, 10, 20, 50, 100, 200, 500, 1000, 2000, 5000, 10000, 20000];

  // ---------- Overall (cross-source) market median ----------
  // Quantity-weighted consensus across all listing sources, with after-hours
  // carry-forward: each source contributes its LATEST reading (assumed to hold
  // until its next refresh), weighted by its listing count. A source drops out
  // only once it's stale past 3× its expected refresh interval τ — and τ is
  // per-source from OBSERVED cadence (EVO 15min live · SG ~1h · TicketsData
  // SH~90m/VD~180m/GT·TM~6h/TP·TMr~8h), not the cron schedule. Off-peak (ET
  // 0-11) the slow books are simply carried = the "after-hours" session.
  let _tdFamily = null;     // { sh:{med,cnt}, gt, vd, tp, tm, tmr } from loadTdFreshness
  let _eventStartMs = NaN;  // event start (horizon-aware τ for EVO/SG)
  let _overallShade = null; // [{x0,x1}] off-peak spans (sec) for the draw hook

  function _isPeakEt(ms) {
    // Peak = ET 12:00–23:59 (matches collector_band). DST-correct via Intl.
    const h = parseInt(new Date(ms).toLocaleString('en-US',
      { timeZone: 'America/New_York', hour: 'numeric', hour12: false }), 10);
    return h >= 12 && h <= 23;
  }
  // Expected refresh interval (minutes) — the basis for the stranded cut-off
  // (stranded once age > 3×τ). NOTE: these are tuned to the data the CLIENT
  // actually has: EVO/SG from the live payloads, but TicketsData from the
  // 3-slot/day DAILY ROLLUP (≈14 h overnight gap), so TD τ must be loose enough
  // to carry overnight rather than strand. The SERVER/firehose version (which
  // reads ticketsdata_listings_snapshots at the real per-platform 3–19×/day
  // cadence) uses the tighter per-platform τ. Values err toward CARRYING so the
  // line stays continuous; a source drops only on genuine multi-cycle absence.
  function _tauMin(cad, hrs, isPeak) {
    if (cad === 'EVO') {
      if (hrs <= 168) return 120;          // ~2 h grace ⇒ stranded ~6 h
      if (hrs <= 336) return isPeak ? 180 : 240;
      if (hrs <= 720) return 360;
      return 1440;
    }
    if (cad === 'SG') {
      if (hrs <= 168) return 180;          // stranded ~9 h
      if (hrs <= 336) return 360;
      return 1440;
    }
    return 600;                            // TicketsData (rollup) ⇒ stranded ~30 h
  }
  // Forward-fill (carry) a [{t,v}] series onto the seconds axis xs, tracking the
  // timestamp of the last real observation per bucket (for staleness/age).
  function _carryProject(pts, xs) {
    const obs = (pts || [])
      .map(p => ({ t: Math.round(new Date(p.t).getTime() / 1000), v: +p.v }))
      .filter(o => isFinite(o.v))
      .sort((a, b) => a.t - b.t);
    const val = new Array(xs.length).fill(null);
    const obsT = new Array(xs.length).fill(null);
    let j = 0, lv = null, lt = null;
    for (let i = 0; i < xs.length; i++) {
      while (j < obs.length && obs[j].t <= xs[i]) { lv = obs[j].v; lt = obs[j].t; j++; }
      val[i] = lv; obsT[i] = lt;
    }
    return { val, obsT };
  }
  function _wMedian(pairs) {   // pairs: [{m, w}] — lower weighted median
    if (!pairs.length) return null;
    pairs.sort((a, b) => a.m - b.m);
    const total = pairs.reduce((s, p) => s + p.w, 0);
    if (total <= 0) return null;
    let cum = 0;
    for (const p of pairs) { cum += p.w; if (cum >= total / 2) return p.m; }
    return pairs[pairs.length - 1].m;
  }
  // sources: [{ cad, med:[{t,v}], cnt:[{t,v}] }] → per-bucket quantity-weighted
  // median (null where no source is live). Also records off-peak spans for shading.
  function buildOverallConsensus(xs, sources) {
    const K = 3; // grace: drop a source once age > K×τ (stranded)
    const prep = sources.map(s => ({ cad: s.cad, mP: _carryProject(s.med, xs), cP: _carryProject(s.cnt, xs) }));
    const med = new Array(xs.length).fill(null);
    const shade = [];
    let runStart = null;
    for (let i = 0; i < xs.length; i++) {
      const ms = xs[i] * 1000;
      const isPeak = _isPeakEt(ms);
      const hrs = isFinite(_eventStartMs) ? Math.max(0, (_eventStartMs - ms) / 3600000) : 9999;
      const pairs = [];
      for (const p of prep) {
        const m = p.mP.val[i], c = p.cP.val[i], ot = p.mP.obsT[i];
        if (m == null || c == null || c <= 0 || ot == null) continue;
        if ((xs[i] - ot) / 60 > K * _tauMin(p.cad, hrs, isPeak)) continue; // stranded
        pairs.push({ m: m, w: c });
      }
      med[i] = _wMedian(pairs);
      if (!isPeak && med[i] != null) { if (runStart == null) runStart = xs[i]; }
      else if (runStart != null) { shade.push({ x0: runStart, x1: xs[i] }); runStart = null; }
    }
    if (runStart != null) shade.push({ x0: runStart, x1: xs[xs.length - 1] });
    _overallShade = shade;
    return med;
  }
  // Faint background tint over off-peak (after-hours) spans on the price pane.
  function drawOffPeakBands(u) {
    if (!_overallShade || !_overallShade.length || !u.ctx) return;
    const ctx = u.ctx;
    ctx.save();
    ctx.fillStyle = 'rgba(120,130,170,0.05)';
    _overallShade.forEach(b => {
      const x0 = u.valToPos(b.x0, 'x', true);
      const x1 = u.valToPos(b.x1, 'x', true);
      ctx.fillRect(x0, u.bbox.top, Math.max(1, x1 - x0), u.bbox.height);
    });
    ctx.restore();
  }
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
      { key: 'counts_owned',  label: 'TEvo owned qty', color: '#60a5fa', width: 1.5, dash: null,   scale: 'y',  fill: 'rgba(96,165,250,0.08)', data: mergeDurable(chart.counts_owned,  durCnt('evo_own')) },
      { key: 'counts_market', label: 'TEvo mkt qty',   color: '#94a3b8', width: 1,   dash: [2,2],  scale: 'y',  data: mergeDurable(chart.counts_market, durCnt('evo_tix')) },
      { key: 'sg_list_ct',    label: 'SG mkt qty',     color: '#22d3ee', width: 1.5, dash: null,   scale: 'y',  data: mergeDurable(extSeries.sg_listings_count || [], durCnt('sg_tix')) },
      { key: 'sg_sale_ct',    label: 'SG sale ct',     color: '#84cc16', width: 1,   dash: null,   scale: 'yr', bars: true, data: extSeries.sg_sales_count || [] },
      // SeatData market sales (right axis count) — parallel to SG sale ct.
      // Keyed on tevo_event_id server-side, so present even when SG is hidden.
      { key: 'sd_sale_ct',    label: 'SeatData sale ct', color: '#f59e0b', width: 1, dash: null, scale: 'yr', bars: true, data: extSeries.sd_sales_count || [] },
      // OUR sell-through — combined EVO+TickPick+Vivid tickets sold per bucket.
      { key: 'our_sale_ct',   label: 'Our sales ct',   color: '#ec4899', width: 1,   dash: null,   scale: 'yr', bars: true, data: extSeries.orders_count || [] },
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
    // TP / TM / TM-resale listing-count overlays (from the full TD family, hidden
    // by default — user-togglable). Counts live in _tdFamily[*].cnt, not the
    // sh/gt/vd-only _tdInvCountSeries above.
    if (_tdFamily) {
      const famCnt = (k) => (_tdFamily[k] && _tdFamily[k].cnt) || [];
      if (famCnt('tp').length) specs.push(
        { key: 'td-tp-cnt',  label: 'TP listings',  color: '#eab308', width: 1, dash: [4, 3], scale: 'y', data: famCnt('tp') });
      if (famCnt('tm').length) specs.push(
        { key: 'td-tm-cnt',  label: 'TM listings',  color: '#38bdf8', width: 1, dash: [4, 3], scale: 'y', data: famCnt('tm') });
      if (famCnt('tmr').length) specs.push(
        { key: 'td-tmr-cnt', label: 'TMr listings', color: '#fb7185', width: 1, dash: [4, 3], scale: 'y', data: famCnt('tmr') });
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
        y:  { range: countYRange },
        yr: { range: countYRange },
      },
      axes: [
        X_AXIS,
        { scale: 'y',  side: 3, stroke: AXIS_STROKE, font: AXIS_FONT,
          grid: { stroke: AXIS_GRID, width: 1 },
          ticks: { stroke: AXIS_TICKS, size: 6 },
          incrs: COUNT_INCRS,
          values: (u, v) => v.map(x => x == null ? '' : Math.round(x)),
          size: 56 },
        { scale: 'yr', side: 1, stroke: AXIS_STROKE, font: AXIS_FONT,
          grid: { show: false },
          ticks: { stroke: AXIS_TICKS, size: 6 },
          incrs: COUNT_INCRS,
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

  // ESPN annotation markers — pink "+" (injury status change) + teal "◆" (game
  // state change) near the top of the price pane. Rendered as VISIBLE, hoverable
  // DOM glyphs in the .chart-anno-host overlay (the prior implementation drew a
  // canvas glyph but put the hover hit-target in a host-spanning overlay WITHOUT
  // the y-axis-gutter offset, so the target sat ~1 axis-width left of the glyph
  // and hover almost never landed). Positioning now adds u.over's offset so the
  // glyph == the hit-target, and it is re-placed on ready/setSize/setScale.
  function injMarkerTip(a) {
    const team = espnTeamName(a.espn_team_id);
    return `${a.athlete_name || a.athlete_id || '?'} (${a.position || '?'}${team ? ' · ' + team : ''}): ` +
           `${a.prev_status || '—'} → ${a.new_status || '—'}`;
  }
  function gsMarkerTip(s) {
    return `Game state: ${s.prev_status || '—'} → ${s.new_status || '—'}${s.state ? ' (' + s.state + ')' : ''}`;
  }
  function renderEspnMarkers(u, host) {
    let overlay = host.querySelector('.chart-anno-host');
    if (!overlay) {
      const cs = window.getComputedStyle(host);
      if (cs.position === 'static') host.style.position = 'relative';
      overlay = document.createElement('div');
      overlay.className = 'chart-anno-host';
      host.appendChild(overlay);
    }
    overlay.innerHTML = '';
    if (!_showEspn || !u.over) return;
    const ext = _chartExtStatePrice.payload;
    const ann = ext && ext.annotations;
    if (!ann) return;
    const ox = u.over.offsetLeft, oy = u.over.offsetTop, ow = u.over.offsetWidth;
    const place = (t, cls, glyph, tip) => {
      if (!t) return;
      const tSec = Math.round(new Date(t).getTime() / 1000);
      const px = u.valToPos(tSec, 'x'); // CSS px relative to the plot area
      if (px < 0 || px > ow) return;
      const el = document.createElement('div');
      el.className = 'espn-marker ' + cls;
      el.style.left = (ox + px) + 'px';
      el.style.top  = (oy + (cls === 'em-gs' ? 22 : 7)) + 'px';
      el.title = tip;
      el.textContent = glyph;
      overlay.appendChild(el);
    };
    // De-noise: skip first-seen "transitions" (prev_status == null) — those are
    // just players already injured when the window opened, not status-change
    // events, and they pile into an indistinct cluster at the window's left edge.
    (ann.injuries || []).forEach(a => { if (a.prev_status != null) place(a.at, 'em-inj', '+', injMarkerTip(a)); });
    (ann.game_state || []).forEach(s => place(s.at, 'em-gs', '◆', gsMarkerTip(s)));
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
      { key: 'espn', label: 'ESPN', live: hasEspn, toggle: hasEspn, on: _showEspn,
        hint: hasEspn ? (_showEspn ? 'ESPN markers ON — click to hide' : 'ESPN markers HIDDEN — click to show')
                      : 'no ESPN markers for this event' },
      { label: 'Weather', live: false, hint: 'reserved — NWS alert windows (pending)' },
      { label: 'Macro',   live: false, hint: 'reserved — UMCSENT background band (pending)' },
      { label: 'Signals', live: false, hint: 'reserved — movers / gap markers (pending)' },
    ];
    el.innerHTML = '<span class="overlay-legend-lbl">overlays</span>' + slots.map(s => {
      const cls = s.toggle ? (s.on ? 'live' : 'off') + ' toggleable' : (s.live ? 'live' : 'pending');
      const dot = !s.live ? '○' : (s.toggle && !s.on ? '◍' : '●');
      return `<span class="overlay-chip ${cls}"${s.key ? ` data-overlay="${s.key}"` : ''} title="${escapeHtml(s.hint)}">` +
             `${escapeHtml(s.label)} ${dot}</span>`;
    }).join('');
    const espnChip = el.querySelector('.overlay-chip.toggleable[data-overlay="espn"]');
    if (espnChip) {
      espnChip.addEventListener('click', () => {
        _showEspn = !_showEspn;
        try { localStorage.setItem(_ESPN_LS_KEY, _showEspn ? '1' : '0'); } catch (_) {}
        const inst = _chartInstances.price;
        const host = document.getElementById('chartHostPrice');
        if (inst && host) renderEspnMarkers(inst, host);
        renderChartOverlayLegend();
      });
    }
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

  // Resolve team names from the event title ("AWAY at HOME") + the espn payload's
  // home/away ids, so ESPN surfaces show "Yankees" not "team 10". No RPC needed.
  function espnTeams() {
    const info = _espnInfo || {};
    const titleEl = document.getElementById('evTitle');
    const title = titleEl ? (titleEl.textContent || '') : '';
    let awayName = '', homeName = '';
    const parts = title.split(/\s+at\s+/i);
    if (parts.length === 2) { awayName = parts[0].trim(); homeName = parts[1].trim(); }
    return {
      homeId: String(info.home_team_id != null ? info.home_team_id : ''),
      awayId: String(info.away_team_id != null ? info.away_team_id : ''),
      homeName, awayName,
    };
  }
  function espnTeamName(teamId) {
    if (teamId == null) return '';
    const id = String(teamId), t = espnTeams();
    if (id === t.homeId && t.homeName) return t.homeName;
    if (id === t.awayId && t.awayName) return t.awayName;
    return 'team ' + id;
  }
  function espnShortName(n) {
    if (!n) return '';
    const parts = n.trim().split(/\s+/);
    return parts[parts.length - 1]; // nickname, e.g. "Yankees"
  }

  // ESPN context strip in the chart section — per-team record / win% / seed /
  // streak / injuries + last game, styled distinct from the market chart.
  function renderEspnChartStrip() {
    const el = document.getElementById('espnChartStrip');
    if (!el) return;
    const info = _espnInfo;
    if (!info || info.hidden) { el.hidden = true; el.innerHTML = ''; return; }
    const t = espnTeams();
    const byId = {};
    (info.team_standings || []).forEach(s => { byId[String(s.espn_team_id)] = s; });
    const results = info.recent_results || [];
    const injuries = info.injuries || [];
    const injCount = id => injuries.filter(i => String(i.espn_team_id) === id).length;
    const lastGame = id => {
      const g = results.find(r => String(r.home_team_id) === id || String(r.away_team_id) === id);
      if (!g) return '';
      const isHome = String(g.home_team_id) === id;
      const me = isHome ? g.home_score : g.away_score;
      const opp = isHome ? g.away_score : g.home_score;
      if (me == null || opp == null) return '';
      const wl = me > opp ? 'w' : me < opp ? 'l' : 't';
      const oppName = espnShortName(espnTeamName(isHome ? g.away_team_id : g.home_team_id));
      return `<span class="espn-wl espn-wl-${wl}">${wl.toUpperCase()}</span> ${me}-${opp} ` +
             `<span class="muted">${isHome ? 'vs' : '@'} ${escapeHtml(oppName)}</span>`;
    };
    const card = (id, name, tag) => {
      const s = byId[id] || {};
      const rec = s.record_summary || `${s.wins || 0}-${s.losses || 0}`;
      const wp = s.win_pct != null ? Number(s.win_pct).toFixed(3).replace(/^0/, '') : '';
      const seed = s.playoff_seed != null ? '#' + s.playoff_seed : '';
      const inj = injCount(id);
      const last = lastGame(id);
      return `<div class="espn-team">` +
        `<div class="espn-team-hd"><span class="espn-tag">${tag}</span> <span class="espn-team-nm">${escapeHtml(name || ('team ' + id))}</span></div>` +
        `<div class="espn-team-line">` +
          `<span class="espn-rec">${escapeHtml(rec)}</span>` +
          (wp ? `<span class="muted">${wp}</span>` : '') +
          (seed ? `<span class="espn-seed">${escapeHtml(seed)}</span>` : '') +
          (s.streak ? `<span class="espn-streak">${escapeHtml(s.streak)}</span>` : '') +
          (inj ? `<span class="espn-inj-chip" title="${inj} active injuries">&oplus; ${inj}</span>` : '') +
        `</div>` +
        `<div class="espn-team-last">${last || '<span class="muted">—</span>'}</div>` +
      `</div>`;
    };
    const lg = info.espn_league ? String(info.espn_league).toUpperCase() : '';
    el.innerHTML =
      `<span class="espn-strip-badge">ESPN</span>` +
      (lg ? `<span class="espn-strip-lg">${escapeHtml(lg)}</span>` : '') +
      card(t.awayId, t.awayName, 'AWAY') +
      `<span class="espn-strip-at">@</span>` +
      card(t.homeId, t.homeName, 'HOME');
    el.hidden = false;
  }

  function renderEspn(espn) {
    _espnInfo = (espn && !espn.hidden) ? espn : null;
    renderEspnChartStrip();
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

  // ---------- Track button (per-user watchlist) ----------
  // The ★ toggle adds/removes this event from the signed-in user's watchlist
  // (event_watchlist_set; identity = their Google-OAuth email server-side). On
  // load we read the user's list once to reflect current state. Hidden entirely
  // if the watchlist RPCs aren't applied yet.
  async function wireTrackButton(eventId) {
    const btn = document.getElementById('trackBtn');
    if (!btn) return;
    const Auth = window.TerminalAuth;
    if (!Auth || !Auth.client || !Auth.getAccessToken()) return;

    let tracked = false;
    const listRes = await rpcOrNull('event_watchlist_list', {});
    if (listRes.error) {
      // RPC not applied yet → leave the button hidden (no half-feature).
      if (/does not exist/i.test(listRes.error.message || '') || listRes.error.code === '42883') return;
    } else {
      const items = (listRes.data && listRes.data.items) || [];
      tracked = items.some(it => String(it.tevo_event_id) === String(eventId));
    }
    paintTrackBtn(btn, tracked);
    btn.hidden = false;

    btn.addEventListener('click', async () => {
      const next = !(btn.getAttribute('aria-pressed') === 'true');
      btn.disabled = true;
      const res = await rpcOrNull('event_watchlist_set', { p_event_id: eventId, p_on: next });
      btn.disabled = false;
      if (res.error) { console.error('[track] set', res.error); T.setStatus('Track failed', 'err'); return; }
      paintTrackBtn(btn, next);
    });
  }

  function paintTrackBtn(btn, tracked) {
    btn.setAttribute('aria-pressed', tracked ? 'true' : 'false');
    btn.classList.toggle('on', tracked);
    btn.textContent = tracked ? '★ Tracking' : '☆ Track';
    btn.title = tracked ? 'On your watchlist — click to remove' : 'Track this event on your watchlist';
  }

  // ---------- Watchlist & Alerts tab ----------
  // A dedicated event-page tab: track/alert controls for THIS event, the alert
  // destination (the signed-in Google email), recent fired alerts for this event,
  // and the user's full watchlist. Re-renders on every activation so toggles
  // stay live. Reuses the same SECDEF RPCs as the hero ★ and the home table.
  async function loadAlertsTab(eventId) {
    await renderAlertsThisEvent(eventId);
    renderAlertsRecent();
    await renderAlertsWatchlist(eventId);
  }

  function _wlRpcMissing(res) {
    return !!(res && res.error && (res.error.code === '42883' || /does not exist/i.test(res.error.message || '')));
  }

  async function renderAlertsThisEvent(eventId) {
    const body = document.getElementById('alertsThisEventBody');
    if (!body) return;
    const Auth = window.TerminalAuth;
    const email = (Auth && Auth.getEmail && Auth.getEmail()) || '';
    let tracked = false, alertOn = false, cadence = 'instant';
    const res = await rpcOrNull('event_watchlist_list', {});
    if (_wlRpcMissing(res)) {
      body.innerHTML = '<div class="empty">Watchlist not enabled yet (RPC pending apply).</div>';
      return;
    }
    if (!res.error) {
      const me = ((res.data && res.data.items) || []).find(it => String(it.tevo_event_id) === String(eventId));
      tracked = !!me;
      alertOn = me ? me.alert_enabled !== false : false;
      cadence = (me && me.alert_cadence) || 'instant';
    }
    body.innerHTML =
      '<div class="alerts-ctl">' +
        `<button id="alTrackBtn" class="track-btn ${tracked ? 'on' : ''}">${tracked ? '★ Tracking' : '☆ Track'}</button>` +
        `<button id="alAlertBtn" class="wl-alert-btn ${alertOn ? 'on' : 'off'}" ${tracked ? '' : 'disabled'} title="Mute / unmute alerts for this event">${alertOn ? '🔔 Alerts on' : '🔕 Alerts off'}</button>` +
        `<label class="al-cadence">delivery&nbsp;` +
          `<select id="alCadence" ${tracked && alertOn ? '' : 'disabled'} title="How often you're emailed about this event">` +
            `<option value="instant">Instant</option>` +
            `<option value="hourly">Hourly summary</option>` +
            `<option value="daily">Daily summary</option>` +
          `</select></label>` +
        `<span class="alerts-dest muted small">Alerts → <b>${escapeHtml(email || 'your login email')}</b></span>` +
      '</div>' +
      `<div class="muted small" style="margin-top:8px">Tracking adds this event to your watchlist (home screen). ` +
      `Instant = emailed as alerts fire; Hourly/Daily = one digest so you're not spammed. ` +
      `Delivery goes to the email above${tracked ? '.' : ' — track the event first.'}</div>` +
      '<div style="margin-top:10px"><button id="alPreviewBtn" class="wl-page-btn">Preview alert email</button></div>' +
      '<div id="alPreviewHost" class="alert-preview" hidden></div>';
    const cadSel = document.getElementById('alCadence');
    if (cadSel) cadSel.value = cadence;

    const trackBtn = document.getElementById('alTrackBtn');
    const alertBtn = document.getElementById('alAlertBtn');
    trackBtn.addEventListener('click', async () => {
      const next = !tracked;
      trackBtn.disabled = true;
      const r = await rpcOrNull('event_watchlist_set', { p_event_id: eventId, p_on: next });
      if (r.error) { trackBtn.disabled = false; console.error('[alerts track]', r.error); return; }
      const hero = document.getElementById('trackBtn'); if (hero) paintTrackBtn(hero, next);
      await renderAlertsThisEvent(eventId);
      await renderAlertsWatchlist(eventId);
    });
    alertBtn.addEventListener('click', async () => {
      if (!tracked) return;
      const next = !alertOn;
      alertBtn.disabled = true;
      const r = await rpcOrNull('event_watchlist_set_alert', { p_event_id: eventId, p_on: next });
      if (r.error) { alertBtn.disabled = false; console.error('[alerts toggle]', r.error); return; }
      await renderAlertsThisEvent(eventId);
    });
    if (cadSel) cadSel.addEventListener('change', async () => {
      cadSel.disabled = true;
      const r = await rpcOrNull('event_watchlist_set_cadence', { p_event_id: eventId, p_cadence: cadSel.value });
      cadSel.disabled = false;
      if (r.error) { console.error('[alerts cadence]', r.error); }
    });
    wireAlertPreview(eventId);
  }

  // Render the exact alert email (the user will receive) inside the tab so the
  // template is reviewable in-app. Server returns the rendered HTML (real alerts
  // if any, else a labelled sample). We inject it directly — inline styles only,
  // permitted by style-src 'unsafe-inline'; the email's own dark wrapper shows.
  function wireAlertPreview(eventId) {
    const btn  = document.getElementById('alPreviewBtn');
    const host = document.getElementById('alPreviewHost');
    if (!btn || !host) return;
    btn.addEventListener('click', async () => {
      btn.disabled = true; const label = btn.textContent; btn.textContent = 'Rendering…';
      const r = await rpcOrNull('preview_event_alert_email', { p_event_id: eventId });
      btn.disabled = false; btn.textContent = label;
      host.hidden = false;
      if (r.error) {
        host.innerHTML = _wlRpcMissing(r)
          ? '<div class="empty">Preview RPC pending apply.</div>'
          : '<div class="empty">Preview failed.</div>';
        return;
      }
      const data = r.data || {};
      host.innerHTML = '<div class="muted small" style="margin:6px 0">Subject: <b>' +
        escapeHtml(data.subject || '') + '</b>' + (data.is_sample ? ' · sample (no live alerts)' : '') + '</div>';
      const frame = document.createElement('div');
      frame.className = 'alert-preview-frame';
      frame.innerHTML = data.html || '';
      host.appendChild(frame);
    });
  }

  function renderAlertsRecent() {
    const body = document.getElementById('alertsRecentBody');
    const meta = document.getElementById('alertsRecentMeta');
    const chip = document.getElementById('tabCountAlerts');
    if (!body) return;
    const alerts = (_lastPayload && _lastPayload.event_alerts) || [];
    if (meta) meta.textContent = alerts.length ? `${alerts.length} recent` : '';
    if (chip) chip.textContent = alerts.length ? String(alerts.length) : '';
    if (!alerts.length) { body.innerHTML = '<div class="empty">No alerts fired for this event recently.</div>'; return; }
    const rows = alerts.slice(0, 50).map(a =>
      '<tr>' +
      `<td class="muted small">${a.fired_at ? escapeHtml(T.fmtDate(a.fired_at)) : '—'}</td>` +
      `<td><span class="badge ${_sevClass(a.severity)}">${escapeHtml(String(a.severity || '').toUpperCase())}</span></td>` +
      `<td class="muted small">${escapeHtml(a.rule_key || a.rule || '')}</td>` +
      `<td>${escapeHtml(a.message || '')}</td>` +
      '</tr>').join('');
    body.innerHTML = `<table><thead><tr><th>When</th><th>Severity</th><th>Rule</th><th>Message</th></tr></thead><tbody>${rows}</tbody></table>`;
  }
  function _sevClass(s) {
    s = String(s || '').toLowerCase();
    if (/crit|critical/.test(s)) return 'lifecycle-ghost';
    if (/warn|warning/.test(s)) return 'gap-chip';
    return '';
  }

  async function renderAlertsWatchlist(eventId) {
    const body = document.getElementById('alertsWatchlistBody');
    const meta = document.getElementById('alertsWatchlistMeta');
    if (!body) return;
    const res = await rpcOrNull('event_watchlist_list', {});
    if (_wlRpcMissing(res)) { body.innerHTML = '<div class="empty">Watchlist not enabled yet.</div>'; return; }
    if (res.error) { body.innerHTML = '<div class="empty">Failed to load watchlist.</div>'; return; }
    const items = (res.data && res.data.items) || [];
    if (meta) meta.textContent = items.length ? `${items.length} events${items.length > 50 ? ' · showing 50' : ''}` : '';
    if (!items.length) { body.innerHTML = '<div class="empty">No tracked events yet — ★ Track above to add this one.</div>'; return; }
    const rows = items.slice(0, 50).map(it => {
      const d = T.daysUntil(it.occurs_at_local);
      const cur = String(it.tevo_event_id) === String(eventId);
      return `<tr${cur ? ' class="wl-cur"' : ''}>` +
        `<td><a href="event.html?event=${it.tevo_event_id}">${escapeHtml(it.event_name || ('Event ' + it.tevo_event_id))}</a>` +
        `${cur ? ' <span class="muted small">(this event)</span>' : ''}</td>` +
        `<td class="num">${d === null ? '—' : d}</td>` +
        `<td class="muted small">${escapeHtml(it.venue_name || it.venue_location || '—')}</td>` +
        `<td class="num">${it.alert_enabled ? '🔔 ' + escapeHtml(it.alert_cadence || 'instant') : '🔕'}</td>` +
        '</tr>';
    }).join('');
    body.innerHTML = `<table><thead><tr><th>Event</th><th class="num">T-days</th><th>Venue</th><th class="num">Alerts</th></tr></thead><tbody>${rows}</tbody></table>` +
      (items.length > 50 ? '<div class="muted small" style="margin-top:6px">Showing 50 — full paged list on the home screen.</div>' : '');
  }

  // ---------- Per-source event URLs (spot-check links on each data tab) ----------
  // Resolves every source's id + marketplace URL off the canonical aq_event_map
  // hub via the email-gated get_event_source_links RPC, then stamps a "↗ source"
  // link into each data tab's header so the operator can click straight through
  // and spot-check our captured data against the live book. Fire-and-forget;
  // degrades silently if the RPC isn't applied yet (rpcOrNull returns an error).
  const _SRC_LINK_TABS = [
    { pane: 'paneSgListings', label: 'SeatGeek',     url: d => d.sg_url },
    { pane: 'paneSgSales',    label: 'SeatGeek',     url: d => d.sg_url },
    { pane: 'paneShListings', label: 'StubHub',      url: d => d.td && d.td.SH },
    { pane: 'paneGtListings', label: 'GameTime',     url: d => d.td && d.td.GT },
    { pane: 'paneVdListings', label: 'VividSeats',   url: d => d.td && d.td.VD },
    // TP source-link removed 2026-06-07: paneTpListings deleted (TickPick demoted to opt-in)
    { pane: 'paneTmListings', label: 'Ticketmaster', url: d => d.td && d.td.TM },
  ];

  async function loadSourceLinks(eventId) {
    const res = await rpcOrNull('get_event_source_links', { p_event_id: eventId });
    if (!res || res.error || !res.data) return;
    const d = res.data;
    _SRC_LINK_TABS.forEach(t => attachSrcLink(t.pane, t.label, t.url(d)));
    // TD Markets aggregates every available source link into one row.
    attachSrcLinksMulti('paneTdMarkets', d);
  }

  // First <span> inside a pane's first .panel-title — we append the link there
  // so it sits inline next to the title text (the .panel-title.row container is
  // a 2-child space-between flex; appending into the title span avoids breaking
  // that layout). Returns null when the pane/title isn't present.
  function paneTitleSpan(paneId) {
    const pane = document.getElementById(paneId);
    if (!pane) return null;
    const title = pane.querySelector('.panel-title');
    if (!title) return null;
    return title.querySelector('span') || title;
  }

  // Idempotent single "↗ <label>" link in a pane title.
  function attachSrcLink(paneId, label, url) {
    if (!url) return;
    const host = paneTitleSpan(paneId);
    if (!host) return;
    let link = host.querySelector('a.src-link[data-single]');
    if (!link) {
      link = document.createElement('a');
      link.className = 'src-link';
      link.setAttribute('data-single', '1');
      link.target = '_blank';
      link.rel = 'noopener noreferrer';
      host.appendChild(link);
    }
    link.href = url;
    link.title = 'Open this event on ' + label + ' — spot-check our captured data against the live book';
    link.innerHTML = '↗ ' + escapeHtml(label);
  }

  // All available source links in one row (TD Markets aggregate tab).
  function attachSrcLinksMulti(paneId, d) {
    const host = paneTitleSpan(paneId);
    if (!host) return;
    const links = [
      ['SeatGeek', d.sg_url],
      ['StubHub', d.td && d.td.SH], ['GameTime', d.td && d.td.GT],
      ['VividSeats', d.td && d.td.VD], ['TickPick', d.td && d.td.TP],
      ['Ticketmaster', d.td && d.td.TM],
    ].filter(([, u]) => !!u);
    let row = host.querySelector('.src-link-row');
    if (!row) {
      row = document.createElement('span');
      row.className = 'src-link-row';
      host.appendChild(row);
    }
    row.innerHTML = links.map(([lbl, u]) =>
      `<a class="src-link" target="_blank" rel="noopener noreferrer" href="${escapeHtml(u)}" ` +
      `title="Open on ${escapeHtml(lbl)}">↗ ${escapeHtml(lbl)}</a>`).join('');
  }

  // ---------- TD per-source freshness (event_listing_snapshot_daily) ----------

  async function loadTdFreshness(eventId) {
    const Auth = window.TerminalAuth;
    if (!Auth || !Auth.client) return;
    // Fetch full snapshot history for this event (up to 90 rows = ~30 days × 3 slots)
    // Used for: (a) fr-chips freshness, (b) data-freshness table, (c) price chart TD overlay
    const { data: rows, error } = await Auth.client
      .from('event_listing_snapshot_daily')
      .select('snapshot_date,snapshot_slot,evo_retail_median,evo_owned_median,evo_tickets_count,evo_owned_tickets,sg_all_median,sg_owned_median,sg_all_tickets,td_sh_listings,td_sh_median,td_gt_listings,td_gt_median,td_vd_listings,td_vd_median,td_tp_listings,td_tp_median,td_tm_listings,td_tm_median,td_tm_resale_listings,td_tm_resale_median,td_combined_median')
      .eq('event_id', eventId)
      .order('snapshot_date', { ascending: false })
      .order('snapshot_slot', { ascending: false })
      .limit(1200);   // ~2yr of durable history (3 slots/day); cheap, indefinite table
    if (error) { console.error('[td-freshness] sb', error); return; }
    // Latest row for chips + freshness table
    // Slots: morning≈09:00, midday≈14:00, evening≈19:00 UTC. NOTE: the slot names do
    // NOT sort chronologically as text ("morning" > "midday" > "evening" alphabetically),
    // so a SQL `order by snapshot_slot desc` returns the EARLIEST (morning) slot. Sort
    // chronologically client-side instead, or the panel shows the morning partial.
    const slotHourMap = { morning: 9, midday: 14, evening: 19 };
    const slotRank = (r) => slotHourMap[r.snapshot_slot] ?? 12;
    const rowTs = (r) => `${r.snapshot_date}T${String(slotRank(r)).padStart(2, '0')}:00:00Z`;
    if (rows && rows.length) {
      rows.sort((a, b) => a.snapshot_date !== b.snapshot_date
        ? (a.snapshot_date < b.snapshot_date ? 1 : -1)   // newest date first
        : slotRank(b) - slotRank(a));                    // then newest slot first
    }
    // The collector writes a slot even mid-pull, so the latest slot can show 0 for a
    // platform that simply hadn't pulled yet. Build `snap` from the latest row but
    // fill each platform from the freshest recent slot where it actually has a book
    // (>0), keeping listings+median from the SAME slot. Bounded to the latest ~6 rows
    // (~2 days) so a genuinely-empty platform doesn't carry a stale value forever.
    let snap = rows && rows.length ? { ...rows[0] } : null;
    if (snap) {
      const recent = rows.slice(0, 6);
      const PLATS = [
        ['td_sh_listings', 'td_sh_median'], ['td_gt_listings', 'td_gt_median'],
        ['td_vd_listings', 'td_vd_median'], ['td_tp_listings', 'td_tp_median'],
        ['td_tm_listings', 'td_tm_median'], ['td_tm_resale_listings', 'td_tm_resale_median'],
      ];
      for (const [lf, mf] of PLATS) {
        if (snap[lf] == null || +snap[lf] === 0) {
          const hit = recent.find(r => r[lf] != null && +r[lf] > 0);
          if (hit) { snap[lf] = hit[lf]; snap[mf] = hit[mf]; }
        }
      }
    }
    const snapTs = snap ? rowTs(rows[0]) : null;
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
      // Durable cross-source backbone (long-horizon splice — retention fix).
      const dm = { evo_owned: [], evo_mkt: [], sg_list: [], sg_own: [], sh: [], gt: [], vd: [] };
      const dc = { evo_own: [], evo_tix: [], sg_tix: [], sh: [], gt: [], vd: [] };
      const push = (arr, ts, v) => { if (v != null) arr.push({ t: ts, v: +v }); };
      for (const r of rows) {
        const ts = rowTs(r);
        if (r.td_sh_median   != null) sh.push({ t: ts, v: +r.td_sh_median });
        if (r.td_gt_median   != null) gt.push({ t: ts, v: +r.td_gt_median });
        if (r.td_vd_median   != null) vd.push({ t: ts, v: +r.td_vd_median });
        if (r.td_sh_listings != null) ish.push({ t: ts, v: +r.td_sh_listings });
        if (r.td_gt_listings != null) igt.push({ t: ts, v: +r.td_gt_listings });
        if (r.td_vd_listings != null) ivd.push({ t: ts, v: +r.td_vd_listings });
        // EVO + SG durable medians/counts (these feed the long-horizon splice).
        push(dm.evo_owned, ts, r.evo_owned_median);
        push(dm.evo_mkt,   ts, r.evo_retail_median);
        push(dm.sg_list,   ts, r.sg_all_median);
        push(dm.sg_own,    ts, r.sg_owned_median);
        push(dm.sh, ts, r.td_sh_median); push(dm.gt, ts, r.td_gt_median); push(dm.vd, ts, r.td_vd_median);
        push(dc.evo_own, ts, r.evo_owned_tickets);
        push(dc.evo_tix, ts, r.evo_tickets_count);
        push(dc.sg_tix,  ts, r.sg_all_tickets);
        push(dc.sh, ts, r.td_sh_listings); push(dc.gt, ts, r.td_gt_listings); push(dc.vd, ts, r.td_vd_listings);
      }
      // Reverse so series are chronological (we fetched newest-first)
      _tdChartSeries    = { sh: sh.reverse(),  gt: gt.reverse(),  vd: vd.reverse() };
      _tdInvCountSeries = { sh: ish.reverse(), gt: igt.reverse(), vd: ivd.reverse() };
      // Full TicketsData family (median + count per platform) for the overall
      // consensus — includes TP / TM primary / TM resale, which the chart
      // overlays don't draw but the weighted median should weigh in.
      const fam = { sh:{med:[],cnt:[]}, gt:{med:[],cnt:[]}, vd:{med:[],cnt:[]},
                    tp:{med:[],cnt:[]}, tm:{med:[],cnt:[]}, tmr:{med:[],cnt:[]} };
      for (const r of rows) {
        const ts = rowTs(r);
        const add = (k, mv, cv) => {
          if (mv != null) fam[k].med.push({ t: ts, v: +mv });
          if (cv != null) fam[k].cnt.push({ t: ts, v: +cv });
        };
        add('sh',  r.td_sh_median,        r.td_sh_listings);
        add('gt',  r.td_gt_median,        r.td_gt_listings);
        add('vd',  r.td_vd_median,        r.td_vd_listings);
        add('tp',  r.td_tp_median,        r.td_tp_listings);
        add('tm',  r.td_tm_median,        r.td_tm_listings);
        add('tmr', r.td_tm_resale_median, r.td_tm_resale_listings);
      }
      Object.values(fam).forEach(o => { o.med.reverse(); o.cnt.reverse(); });
      _tdFamily = fam;
      Object.keys(dm).forEach(k => dm[k].reverse());
      Object.keys(dc).forEach(k => dc[k].reverse());
      _dailyDurable = { med: dm, cnt: dc };

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
    'tm-listings': false,  // tp-listings removed 2026-06-07: TP demoted to opt-in, TM replaces it
    'sg-sales': false, 'seatdata-sales': false, 'our-orders': false, 'alerts': false,
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
      } else if (tabId === 'tm-listings' && !_tabState.loaded['tm-listings']) {
        _tabState.loaded['tm-listings'] = true;
        await loadTdPlatformListings(eventId, 'TM');
        updateTdListingsTabCount();
      } else if (tabId === 'sg-sales' && !_tabState.loaded['sg-sales']) {
        await loadSgSalesFull(eventId);
      } else if (tabId === 'seatdata-sales' && !_tabState.loaded['seatdata-sales']) {
        await loadSeatdataSalesFull(eventId);
      } else if (tabId === 'td-markets' && !_tabState.loaded['td-markets']) {
        await loadTdMarketsFull(eventId);
      } else if (tabId === 'alerts') {
        // Re-render every activation (cheap; reflects track/alert toggles).
        await loadAlertsTab(eventId);
      } else if (tabId === 'seatmap' && !_tabState.loaded['seatmap']) {
        await loadSeatmap(eventId);
      } else if (tabId === 'our-orders' && !_tabState.loaded['our-orders']) {
        // Merged tab — fire all 3 broker-order RPCs in parallel, render each
        // into its own stacked sub-section inside #paneOurOrders.
        _tabState.loaded['our-orders'] = true;
        await Promise.all([
          loadSgSellerListingsFull(eventId),
          loadEvoOrdersFull(eventId),
          loadSgSellerOrdersFull(eventId),
          loadCrossBrokerFull(eventId),
        ]);
        updateOurOrdersTabCount();
      } else if (tabId === 'alerts' && !_tabState.loaded['alerts']) {
        _tabState.loaded['alerts'] = true;
        const label = document.getElementById('evTitle')?.textContent || '';
        window.TerminalAlerts?.mount('event', eventId, label, document.querySelector('#paneAlerts .alerts-root'));
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
      'tm-listings':  'paneTmListings',
      'sg-sales':     'paneSgSales',
      'seatdata-sales': 'paneSeatdataSales',
      'td-markets':   'paneTdMarkets',
      'alerts':       'paneAlerts',
      'seatmap':      'paneSeatmap',
      'our-orders':   'paneOurOrders',
      'alerts':       'paneAlerts',
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

  function wireSeatdataSalesWindow(eventId) {
    const sel = document.getElementById('seatdataSalesWindow');
    if (!sel) return;
    sel.addEventListener('change', async () => {
      _tabState.loaded['seatdata-sales'] = false;
      const body = document.getElementById('seatdataSalesFullBody');
      if (body) body.innerHTML = '<div class="empty">Loading…</div>';
      await loadSeatdataSalesFull(eventId);
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
    const allRows = d.rows || [];
    // RPC dedups DISTINCT ON (sglid) across a 7-day window, so a listing keeps
    // its LAST-SEEN captured_at — listings that vanished days ago still appear,
    // stamped with stale pull times. That's the "multiple captured" symptom.
    // Limit to the last pull: each poll writes one uniform captured_at, so the
    // current board = rows whose captured_at equals the max across the result.
    const lastPull = allRows.reduce((m, r) => (r.captured_at > m ? r.captured_at : m), '');
    const rows = lastPull ? allRows.filter(r => r.captured_at === lastPull) : allRows;
    const pullLabel = lastPull ? T.fmtDate(lastPull) : '—';
    if (meta) meta.textContent = `${rows.length} listings · last pull ${pullLabel} · ${ms.toFixed(0)}ms · sg_event_id ${d.sg_event_id}`;
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

  // ---------- Seat Map (interactive TEvo venue map · multi-source section/price filter) ----------
  // The vendored @ticketevolution/seatmaps-client UMD bundle exposes window.Tevomaps.
  // venueId/configurationId come from public.events; the map is rendered once, then the
  // SOURCE SELECTOR (TEvo · SeatGeek · StubHub · GameTime · VividSeats) re-colors it by
  // ONE source's floors at a time via updateTicketGroups() — never collectively. Each
  // source's per-section floors are joined to the map's manifest section names via the
  // trailing-token remap. Clicking a section filters the per-source listing table below.
  // All sources' RPCs take the tevo event_id and resolve the cross-source bridge server-side.
  let _seatmapApi = null;
  let _seatmapEventId = null;
  let _seatmapRemap = null;     // tail → full manifest section name (venue/config-scoped, cached)
  let _seatmapSource = 'EVO';   // which source currently colors the map
  let _seatmapRowsBySource = {};// key → normalized rows [{section,row,quantity,retail_price,is_owned}]
  let _seatmapSelected = [];    // section names currently selected on the map
  let _seatmapWired = false;    // selector + reset listeners attached once
  let _seatmapUserPicked = false; // user clicked a source → stop auto-picking
  let _seatmapConfigName = '';
  let _seatmapVenueLabel = '';
  const SEATMAP_MAPS_DOMAIN = 'https://maps.ticketevolution.com';  // lib default; we read the same manifest
  // Source registry — TM excluded (primary/box-office, no section-level resale
  // listings for these events). TP is INCLUDED but is ZONE-ONLY: it lists whole
  // bands ("100s"/"Lower"/"Suites"), not sections, so it colors by zone expansion
  // (see _seatmapZoneKeys) rather than the per-section matcher. _seatmapIsZoneSource
  // flags which sources take the zone path.
  const SEATMAP_SOURCES = [
    { key: 'EVO', label: 'TEvo' },
    { key: 'SG',  label: 'SeatGeek' },
    { key: 'SH',  label: 'StubHub' },
    { key: 'GT',  label: 'GameTime' },
    { key: 'VD',  label: 'VividSeats' },
    { key: 'TP',  label: 'TickPick' },
  ];
  // Sources whose `section` is a ZONE label, not a seat section — colored by
  // expanding each zone to the manifest sections it covers (TickPick only today).
  function _seatmapIsZoneSource(key) { return key === 'TP'; }

  // Fetch one source's listings (by tevo event id — every RPC resolves the bridge itself)
  // and normalize to a common shape. Prices use each source's all-in field where available.
  async function _seatmapFetchSource(eventId, key) {
    if (key === 'EVO') {
      const r = await rpcOrNull('get_event_evo_listings_full', { p_event_id: eventId });
      return ((r && r.data && r.data.rows) || []).map(x => ({
        section: x.section, row: x.row, quantity: x.quantity,
        retail_price: x.retail_price, is_owned: !!x.is_owned,
      }));
    }
    if (key === 'SG') {
      const r = await rpcOrNull('get_event_sg_listings_full', { p_event_id: eventId });
      return ((r && r.data && r.data.rows) || []).map(x => ({
        section: x.section, row: x.row, quantity: x.quantity,
        retail_price: (x.retail_price_all_in != null ? x.retail_price_all_in : x.broadcast_price),
        is_owned: !!x.is_broker_owned,
      }));
    }
    // SH / GT / VD via TicketsData
    const r = await rpcOrNull('get_event_td_listings', { p_tevo_event_id: eventId, p_platform: key, p_hours: 26 });
    const rows = Array.isArray(r && r.data) ? r.data : [];
    return rows.map(x => ({
      section: x.section, row: x.row, quantity: x.quantity,
      retail_price: (x.price_with_fees != null && Number(x.price_with_fees) > 0 ? x.price_with_fees : x.list_price),
      is_owned: false,
    }));
  }

  function _seatmapSrcLabel(key) {
    const s = SEATMAP_SOURCES.find(x => x.key === key);
    return s ? s.label : key;
  }

  // Parking / non-seated pseudo-sections never match an SVG path (bible §3 parking
  // skip) — drop them so the legend's price scale isn't skewed by $30 parking spots.
  // Brokers also list off-site lots as STREET ADDRESSES ("1440 W Washington Blvd",
  // "1 Light St", "2121 S. Towne Center Pl") — number-first + a street suffix. Filter
  // those too (a real section like "Terrace 12" has the number LAST, so it's safe).
  function _seatmapIsParking(section) {
    const s = section || '';
    if (/parking|garage|valet|\blot\b|\blot[\s.\-]?[a-z0-9]|min walk|mi from venue|shuttle|tailgate/i.test(s)) return true;
    if (/^\s*\d[\d\s.,/&–-]*\s+\S.*\b(st|street|ave|avenue|blvd|boulevard|dr|drive|rd|road|pkwy|pkway|parkway|hwy|highway|ln|lane|ct|court|pl|place|plz|plaza|cir|circle|way)\b\.?/i.test(s)) return true;
    // number + compass direction + word = a street address even without a street suffix
    // ("840 N. Broadway", "61 E Elizabeth", "516 N. 2nd Ave"). Real sections aren't shaped this way.
    if (/^\s*\d+\s+[nsew]\b\.?\s+[a-z0-9]/i.test(s)) return true;
    return false;
  }

  // ----- Section → manifest matcher (venue-agnostic; manifest drives everything) -----
  // The map MANIFEST keys sections by full descriptive names that vary wildly by venue:
  // clean numeric+suffix ("014A", "320C"), named families ("Home Plate Box 10", "Club
  // House 22"), or descriptive ("Lower Level Corner 104"). Broker `section` text is messy
  // and venue-specific ("SEC10", "10", "Clubhouse Box 22", "FL5"). We match each listing
  // section to a manifest key with a CONFIDENCE-ORDERED tier chain — exact/specific first,
  // heuristics last and collision-gated — so clean venues resolve early (T1/T2) and never
  // touch the messy-venue logic (T3/T4). Output is ALWAYS a real manifest key; when unsure
  // we leave it unmatched (grey, still listed) rather than miscolor. No per-venue code.
  const _SM_PREMIUM = /suite|club|diamond|dugout|founders|mvp|legend|champion|hall|vista|porch|all\s*star|gold\s*glove|rookie|silver|platinum|party|\bpass\b/i;

  function _smNorm(s) {
    return String(s == null ? '' : s).toLowerCase().replace(/[^a-z0-9 ]/g, ' ').replace(/\s+/g, ' ').trim();
  }
  // Zone abbreviations brokers glue to a section number (esp. baseball): the manifest
  // spells these out as family words, so we expand them to align. Multi-token where a
  // level spans sub-families (Dodger field = Field Box / Infield Box / Preferred Field —
  // all carry "field" or "box"). Venue-agnostic: an expansion only helps when that
  // venue's manifest actually has the family; otherwise it's a harmless no-op.
  const SEATMAP_ZONES = {
    fd: 'field box', rs: 'reserve', lg: 'loge box', td: 'top deck',
    dg: 'dugout', pl: 'pavilion', pr: 'pavilion', bl: 'baseline', mvp: 'mvp',
    // middle level: brokers/SG call it M / Mezz / Mezzanine, the manifest may say
    // "Middle" OR "Mezzanine" — expand to both tokens so either naming matches.
    m: 'middle mezzanine', mez: 'middle mezzanine', mezz: 'middle mezzanine',
    mezzanine: 'middle mezzanine', drm: 'middle mezzanine',
    flga: 'floor', flrga: 'floor',  // floor-GA codes → the Floor family
  };
  // Parse a section/key → { num (leading-zeros stripped), suf (sub-section letter), fam }.
  // num = the section number; suf = a single A-H sub-section letter glued to the number
  // (Yankee "117A"≠"117B"); fam = remaining words with zone codes expanded and generic
  // markers (sec/section/ga) dropped. A trailing zone code (e.g. "12FD"→field) is treated
  // as FAMILY, not a suffix — distinguished from a real suffix by "<digit><single a-h>$".
  function _smParse(s) {
    const n = _smNorm(s);
    const numM = n.match(/\d+/);
    if (!numM) return { num: null, suf: '', fam: n };
    const num = String(parseInt(numM[0], 10));      // first digit run; "014" → "14"
    const sufM = n.match(/\d([a-h])$/);             // digit directly + one a-h letter = sub-section
    const suf = sufM ? sufM[1] : '';
    const nf = suf ? n.replace(/([a-h])$/, '') : n;
    const fam = [];
    (nf.match(/[a-z]+/g) || []).forEach(t => {
      if (SEATMAP_ZONES[t]) fam.push(...SEATMAP_ZONES[t].split(' '));
      else if (t === 'clubhouse') fam.push('club', 'house');
      else if (/^(sec|section|ga)$/.test(t)) { /* generic — carries no family */ }
      else fam.push(t);
    });
    return { num, suf, fam: fam.join(' ') };
  }

  // Build the per-venue manifest index (cached). Returns { byNumSuf, byNum, cache } or null.
  async function _seatmapBuildSectionRemap(venueId, configurationId) {
    try {
      const resp = await fetch(`${SEATMAP_MAPS_DOMAIN}/${venueId}/${configurationId}/manifest.json`);
      if (!resp.ok) return null;
      const manifest = await resp.json();
      const sections = (manifest && manifest.sections) || {};
      const byNumSuf = new Map(), byNum = new Map(), named = [];
      Object.keys(sections).forEach(k => {
        const p = _smParse(k);
        if (p.num == null) {                   // numberless keys (GA / Pit / Lawn / Stage / SRO)
          const nm = _smNorm(k);
          named.push({ key: k, norm: nm, toks: nm.split(' ').filter(Boolean) });
          return;
        }
        const rec = { key: k, fam: p.fam, suf: p.suf };
        const ek = p.num + '|' + p.suf;
        (byNumSuf.get(ek) || byNumSuf.set(ek, []).get(ek)).push(rec);
        (byNum.get(p.num)  || byNum.set(p.num, []).get(p.num)).push(rec);
      });
      return { byNumSuf, byNum, named, cache: new Map() };
    } catch (_) { return null; }
  }

  // T3 family align → T4 bowl-default (prefer non-premium). Returns a key or null (don't guess).
  function _smPick(parsed, cands) {
    const lt = parsed.fam ? parsed.fam.split(' ').filter(Boolean) : [];
    if (lt.length) {
      let best = null, bs = 0;
      for (const c of cands) {
        const s = c.fam.split(' ').filter(t => lt.includes(t)).length;
        if (s > bs) { bs = s; best = c; }
      }
      if (best) return best.key;               // T3
    }
    const bowl = cands.filter(c => !_SM_PREMIUM.test(c.key));
    if (bowl.length === 1) return bowl[0].key; // T4 — unique non-premium = the seating bowl
    // T4b — Floor N wins a bowl collision. Arenas number the courtside FLOOR 1..N AND
    // carry a parallel "VIP N" (also non-premium, so it survives the bowl filter) for the
    // SAME numbers → two non-premium candidates and we'd give up. Per the documented
    // tie-rule ("tail collisions prefer the Floor N key"), the bare/numeric listing is the
    // floor, so prefer the unique Floor-named candidate. (Fixes MSG floor 2/4/6/8/10/11/12.)
    if (bowl.length > 1) {
      const floor = bowl.filter(c => /(^|[^a-z])floor([^a-z]|$)/i.test(c.key));
      if (floor.length === 1) return floor[0].key;
    }
    return null;                               // still ambiguous → leave grey
  }

  // Match one listing section → manifest key (cached per venue). Tier chain:
  // numberless (GA/Pit/Lawn) → name exact, else name token-overlap;
  // numbered → T1/T2 exact (num+suffix) → T2b suffixed-but-only-numeric → T3 family → T4 bowl.
  function _seatmapMatchSection(section, idx) {
    if (!idx) return null;
    if (idx.cache.has(section)) return idx.cache.get(section);
    const p = _smParse(section);
    let key = null;
    if (p.num == null) {
      // numberless section (e.g. "General Admission", "GA Pit") → match named manifest keys.
      const nm = _smNorm(section);
      const named = idx.named || [];
      let hit = named.find(x => x.norm === nm);                // exact normalized
      if (!hit && named.length) {                              // else best token overlap (>0)
        const lt = nm.split(' ').filter(Boolean);
        let best = null, bs = 0;
        for (const x of named) {
          const ov = x.toks.filter(t => lt.includes(t)).length;
          if (ov > bs) { bs = ov; best = x; }
        }
        hit = best;
      }
      key = hit ? hit.key : null;
    } else {
      const exact = idx.byNumSuf.get(p.num + '|' + p.suf) || [];
      if (exact.length === 1) key = exact[0].key;             // T1/T2 — clean venues land here
      else if (exact.length > 1) key = _smPick(p, exact);     // same num+suf across families
      else {
        const numOnly = idx.byNum.get(p.num) || [];           // no exact suffix match
        if (numOnly.length === 1) key = numOnly[0].key;
        else if (numOnly.length > 1) key = _smPick(p, numOnly);
      }
    }
    idx.cache.set(section, key);
    return key;
  }

  // ----- Zone expansion (for zone-only sources like TickPick) -----
  // TickPick lists whole ZONES, not seat sections: a hundreds band ("100s"/"200s"/
  // "400s"/"100 level"), a named tier ("Lower"/"Upper"/"Middle"/"Floor"/"Suites"/
  // "Club"/"Lounge"/"Balcony"), or a bare section number. To color it we expand each
  // zone label to the SET of manifest section keys it covers and paint them all at the
  // zone's floor. Venue-agnostic: a band maps by the section number's hundreds digit;
  // a named tier maps by a word the manifest key contains; anything else falls back to
  // the single-section matcher. Overlapping zones resolve to the lowest floor per key.
  const _SM_ZONE_WORDS = {
    lower: 'lower', upper: 'upper', middle: 'middle', mezz: 'middle', mezzanine: 'middle',
    floor: 'floor', court: 'floor', courtside: 'floor', field: 'field',
    suite: 'suite', suites: 'suite', club: 'club', lounge: 'lounge', lounges: 'lounge',
    balcony: 'balcony', bridge: 'bridge', bridges: 'bridge', vip: 'vip', terrace: 'terrace',
  };
  function _seatmapAllKeys(idx) {
    if (idx._allKeys) return idx._allKeys;
    const keys = [];
    idx.byNum.forEach(arr => arr.forEach(r => keys.push(r.key)));
    (idx.named || []).forEach(x => keys.push(x.key));
    idx._allKeys = Array.from(new Set(keys));
    return idx._allKeys;
  }
  function _seatmapZoneKeys(label, idx) {
    if (!idx) return [];
    const cache = idx._zoneCache || (idx._zoneCache = new Map());
    if (cache.has(label)) return cache.get(label);
    const norm = _smNorm(label);
    let out = [];
    // hundreds band: "100", "100s", "100 level", "400s"
    const band = norm.match(/(^|\s)([1-9])0{2}\s*(s|level|lvl)?(\s|$)/);
    if (band) {
      const lo = parseInt(band[2], 10) * 100, hi = lo + 99;
      idx.byNum.forEach((arr, num) => {
        const v = parseInt(num, 10);
        if (v >= lo && v <= hi) arr.forEach(r => out.push(r.key));
      });
    }
    if (!out.length) {                                   // named tier
      const wants = new Set();
      norm.split(' ').filter(Boolean).forEach(t => { if (_SM_ZONE_WORDS[t]) wants.add(_SM_ZONE_WORDS[t]); });
      if (wants.size) {
        _seatmapAllKeys(idx).forEach(k => {
          const kn = _smNorm(k);
          for (const w of wants) { if (kn.indexOf(w) !== -1) { out.push(k); break; } }
        });
      }
    }
    if (!out.length) {                                   // bare number / unknown → one section
      const k = _seatmapMatchSection(label, idx);
      if (k) out = [k];
    }
    out = Array.from(new Set(out));
    cache.set(label, out);
    return out;
  }

  // Collapse listing rows → one ticketGroup per matched manifest section at its lowest floor
  // (what the map colors by). Unmatched sections are skipped (grey) but still appear in the
  // listing table. No manifest (fetch failed) → fall back to the raw section as the key.
  // zoneSrc=true (TickPick) expands each row's zone label to every section it covers.
  function _seatmapTicketGroups(rows, idx, zoneSrc) {
    const floorByKey = new Map();
    rows.forEach(r => {
      const sec = (r.section || '').trim();
      if (!sec || _seatmapIsParking(sec)) return;
      const price = Number(r.retail_price);
      if (!isFinite(price) || price <= 0) return;
      const keys = idx ? (zoneSrc ? _seatmapZoneKeys(sec, idx) : [_seatmapMatchSection(sec, idx)]) : [sec];
      keys.forEach(key => {
        if (!key) return;
        const prev = floorByKey.get(key);
        if (prev == null || price < prev) floorByKey.set(key, price);
      });
    });
    return Array.from(floorByKey, ([key, price]) => ({ tevo_section_name: key, retail_price: price }));
  }

  // Hide the Seat Map tab when the venue/config is known to have NO interactive map
  // (seatmap_manifest.has_map=false, populated by the seatmap-manifest-sync cron).
  // Conservative: only hides on a definitive negative — if the config isn't synced
  // yet (no row), the tab stays and the runtime fetch decides.
  async function loadSeatmapTabVisibility(eventId) {
    const Auth = window.TerminalAuth;
    if (!Auth || !Auth.client) return;
    const ev = await Auth.client.from('events')
      .select('venue_id, configuration_id').eq('id', eventId).maybeSingle();
    if (ev.error || !ev.data || ev.data.venue_id == null || ev.data.configuration_id == null) return;
    const mr = await Auth.client.from('seatmap_manifest')
      .select('has_map')
      .eq('venue_id', ev.data.venue_id)
      .eq('configuration_id', ev.data.configuration_id)
      .maybeSingle();
    if (!mr.error && mr.data && mr.data.has_map === false) {
      const btn = document.querySelector('.event-tab[data-tab="seatmap"]');
      if (btn) btn.style.display = 'none';
    }
  }

  async function loadSeatmap(eventId) {
    _tabState.loaded['seatmap'] = true;
    _seatmapEventId = eventId;
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
    _seatmapConfigName = evRes.data.configuration_name || '';
    _seatmapVenueLabel = `venue ${venueId} · config ${configurationId}` + (_seatmapConfigName ? ` (${_seatmapConfigName})` : '');

    // (2) Manifest remap (venue/config-scoped — built once, shared by every source).
    _seatmapRemap = await _seatmapBuildSectionRemap(venueId, configurationId);
    _seatmapRowsBySource = {};
    _seatmapSource = 'EVO';
    _seatmapSelected = [];
    _seatmapUserPicked = false;

    // (3) Default source = TEvo. Build the map ONCE with its floors; later source
    //     switches re-color via updateTicketGroups() rather than rebuilding the SVG.
    const evoRows = await _seatmapFetchSource(eventId, 'EVO');
    _seatmapRowsBySource['EVO'] = evoRows;
    const ticketGroups = _seatmapTicketGroups(evoRows, _seatmapRemap);

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

    wireSeatmapControls();
    renderSeatmapSelector();
    renderSeatmapList();
    updateSeatmapMeta(ticketGroups.length);
    _seatmapProbeSources(eventId);   // fire-and-forget: enable/disable + count the other sources
  }

  // Switch which source colors the map. Re-colors via updateTicketGroups() (no SVG rebuild)
  // and swaps the listing table to that source. One source at a time — never merged.
  async function selectSeatmapSource(key) {
    if (!_seatmapApi || key === _seatmapSource) return;
    _seatmapSource = key;
    _seatmapSelected = [];
    renderSeatmapSelector();
    const meta = document.getElementById('seatmapMeta');
    if (meta) meta.textContent = `${_seatmapVenueLabel} · loading ${_seatmapSrcLabel(key)}…`;

    let rows = _seatmapRowsBySource[key];
    if (!rows) {
      rows = await _seatmapFetchSource(_seatmapEventId, key);
      _seatmapRowsBySource[key] = rows;
    }
    const ticketGroups = _seatmapTicketGroups(rows, _seatmapRemap, _seatmapIsZoneSource(key));
    if (typeof _seatmapApi.updateTicketGroups === 'function') {
      try { _seatmapApi.updateTicketGroups(ticketGroups); } catch (_) { /* ignore */ }
    }
    renderSeatmapSelector();   // refresh active state
    renderSeatmapList();
    updateSeatmapMeta(ticketGroups.length);
  }

  // Build the source selector buttons (active = current source; disabled once a source
  // is known to have 0 listings for this event). Idempotent — re-rendered on every change.
  function renderSeatmapSelector() {
    const host = document.getElementById('seatmapSourceSel');
    if (!host) return;
    host.innerHTML = SEATMAP_SOURCES.map(s => {
      const rows = _seatmapRowsBySource[s.key];
      const known = rows !== undefined;
      const empty = known && rows.length === 0;
      const cnt = known ? ` <span class="sm-src-cnt">${rows.length}</span>` : '';
      const cls = ['sm-src-btn'];
      if (s.key === _seatmapSource) cls.push('active');
      if (empty) cls.push('disabled');
      return `<button type="button" class="${cls.join(' ')}" data-src="${s.key}"${empty ? ' disabled' : ''}>${escapeHtml(s.label)}${cnt}</button>`;
    }).join('');
  }

  // Probe the non-default sources in the background so the selector can show per-source
  // counts and disable empties — without blocking the initial TEvo render.
  async function _seatmapProbeSources(eventId) {
    for (const s of SEATMAP_SOURCES) {
      if (s.key === 'EVO' || _seatmapRowsBySource[s.key] !== undefined) continue;
      try {
        _seatmapRowsBySource[s.key] = await _seatmapFetchSource(eventId, s.key);
      } catch (_) {
        _seatmapRowsBySource[s.key] = [];
      }
      renderSeatmapSelector();
    }
    _seatmapAutoPickSource();
  }

  // Once all sources are fetched, default the map's coloring to whichever source maps
  // the MOST sections onto this venue's manifest (SG section text is usually cleaner
  // than EVO's broker free-text, but it's per-event, so we measure rather than assume).
  // SG breaks ties (cleaner on average). Skipped once the user has picked a source.
  function _seatmapAutoPickSource() {
    if (_seatmapUserPicked || !_seatmapRemap || !_seatmapApi) return;
    const tie = { SG: 0, EVO: 1, VD: 2, SH: 3, GT: 4 };   // lower = preferred on ties
    let best = _seatmapSource, bestN = -1;
    for (const s of SEATMAP_SOURCES) {
      if (_seatmapIsZoneSource(s.key)) continue;   // zone sources over-paint (whole bands) — never auto-win
      const rows = _seatmapRowsBySource[s.key];
      if (!rows || !rows.length) continue;
      const n = _seatmapTicketGroups(rows, _seatmapRemap).length;
      if (n > bestN || (n === bestN && (tie[s.key] ?? 9) < (tie[best] ?? 9))) { bestN = n; best = s.key; }
    }
    if (best !== _seatmapSource && bestN > 0) selectSeatmapSource(best);
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

  function updateSeatmapMeta(mappedCount) {
    const meta = document.getElementById('seatmapMeta');
    if (!meta) return;
    const rows = _seatmapRowsBySource[_seatmapSource] || [];
    const sections = new Set(rows.filter(r => r.section && !_seatmapIsParking(r.section)).map(r => r.section));
    const isZone = _seatmapIsZoneSource(_seatmapSource);
    const mapped = _seatmapRemap
      ? (isZone
          ? `${sections.size} zone${sections.size === 1 ? '' : 's'} → ${mappedCount} sections painted`
          : `${mappedCount}/${sections.size} sections on map`)
      : `${mappedCount} sections (manifest unavailable — no coloring)`;
    meta.textContent = `${_seatmapVenueLabel} · ${_seatmapSrcLabel(_seatmapSource)} · ${mapped}`;
  }

  // Does this row's section resolve to a manifest key (i.e. does the map color it)?
  // Zone sources resolve via zone expansion; section sources via the single matcher.
  // Returns null when there's no manifest to judge against (don't label as unmapped).
  function _seatmapRowMapped(r, zoneSrc) {
    if (!_seatmapRemap) return null;
    const keys = zoneSrc
      ? _seatmapZoneKeys(r.section, _seatmapRemap)
      : [_seatmapMatchSection(r.section, _seatmapRemap)];
    return keys.some(Boolean);
  }

  // Renders the CURRENT source's listings; clicking a map section filters by matched key
  // (the library returns full manifest names — we match each row's section the same way).
  // Any listing whose section does NOT resolve to a manifest section (so the map leaves it
  // grey) is tagged with an `unmapped` pill + row highlight so we can spot-check the misses.
  function renderSeatmapList() {
    const body = document.getElementById('seatmapListBody');
    if (!body) return;
    const sel = _seatmapSelected.map(s => String(s).toLowerCase());
    const all = _seatmapRowsBySource[_seatmapSource] || [];
    const zoneSrc = _seatmapIsZoneSource(_seatmapSource);
    let rows = all.filter(r => r.section && !_seatmapIsParking(r.section));
    if (sel.length) {
      rows = rows.filter(r => {
        const keys = zoneSrc
          ? _seatmapZoneKeys(r.section, _seatmapRemap)
          : [_seatmapMatchSection(r.section, _seatmapRemap)];
        return keys.some(k => k && sel.includes(String(k).toLowerCase()));
      });
    }
    rows = rows.slice().sort((a, b) => Number(a.retail_price) - Number(b.retail_price));

    if (!rows.length) {
      const src = _seatmapSrcLabel(_seatmapSource);
      body.innerHTML = `<div class="empty">${sel.length ? `No ${escapeHtml(src)} listings in the selected section(s).` : `No ${escapeHtml(src)} listings for this event.`}</div>`;
      return;
    }
    const host = document.createElement('div');
    host.className = 'full-list-host';
    const tbl = document.createElement('table');
    tbl.className = 'full-list-tbl';
    tbl.innerHTML = `
      <thead><tr>
        <th>Section</th><th>Row</th><th class="num">Qty</th>
        <th class="num">Price</th><th>Type</th>
      </tr></thead><tbody></tbody>`;
    const tb = tbl.querySelector('tbody');
    let unmappedCount = 0;
    rows.slice(0, 300).forEach(r => {
      const tr = document.createElement('tr');
      const mapped = _seatmapRowMapped(r, zoneSrc);   // true | false | null (no manifest)
      const cls = [];
      if (r.is_owned) cls.push('owned-row');
      if (mapped === false) { cls.push('unmapped-row'); unmappedCount++; }
      if (cls.length) tr.className = cls.join(' ');
      const ownPill = r.is_owned ? '<span class="pill owned">ours</span>' : '<span class="pill market">market</span>';
      const unmappedPill = mapped === false ? ' <span class="pill unmapped" title="section not on the venue map — not colored">unmapped</span>' : '';
      tr.innerHTML = `
        <td>${escapeHtml(r.section || '—')}</td>
        <td>${escapeHtml(r.row || '—')}</td>
        <td class="num">${T.fmtNum(r.quantity)}</td>
        <td class="num">${r.retail_price != null ? '$' + T.fmtNum(Math.round(r.retail_price)) : '—'}</td>
        <td>${ownPill}${unmappedPill}</td>`;
      tb.appendChild(tr);
    });
    if (unmappedCount) {
      const cap = document.createElement('div');
      cap.className = 'sm-unmapped-note';
      cap.textContent = `${unmappedCount} listing${unmappedCount === 1 ? '' : 's'} not on the venue map (grey — spot-check)`;
      host.appendChild(cap);
    }
    host.appendChild(tbl);
    body.innerHTML = '';
    body.appendChild(host);
  }

  // Wire the source selector + reset once (delegated; survives selector re-renders).
  function wireSeatmapControls() {
    if (_seatmapWired) return;
    const sel = document.getElementById('seatmapSourceSel');
    if (sel) {
      sel.addEventListener('click', (e) => {
        const btn = e.target.closest('.sm-src-btn');
        if (!btn || btn.disabled) return;
        _seatmapUserPicked = true;   // stop auto-pick once the user chooses
        selectSeatmapSource(btn.dataset.src);
      });
    }
    const reset = document.getElementById('seatmapResetBtn');
    if (reset) {
      reset.addEventListener('click', () => {
        if (_seatmapApi && typeof _seatmapApi.deselectSection === 'function') {
          _seatmapSelected.slice().forEach(s => {
            try { _seatmapApi.deselectSection(s); } catch (_) { /* ignore */ }
          });
        }
        onSeatmapSelection([]);
      });
    }
    _seatmapWired = true;
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
    for (const plat of ['Sh', 'Gt', 'Vd', 'Tm']) {  // Tp removed 2026-06-07 (demoted to opt-in)
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

  // ---------- SeatData Sales (full) — clone of SG Sales, keyed on tevo_event_id ----------
  async function loadSeatdataSalesFull(eventId) {
    const body = document.getElementById('seatdataSalesFullBody');
    const meta = document.getElementById('seatdataSalesFullMeta');
    const sel = document.getElementById('seatdataSalesWindow');
    const windowDays = sel ? (parseInt(sel.value, 10) || 30) : 30;
    if (body) body.innerHTML = '<div class="empty">Loading SeatData sales…</div>';
    if (meta) meta.textContent = 'loading…';
    const t0 = performance.now();
    const res = await rpcOrNull('get_event_seatdata_sales_full', {
      p_event_id: eventId, p_window_days: windowDays
    });
    if (res.error) {
      if (meta) meta.textContent = 'error';
      if (body) body.innerHTML = `<div class="empty">RPC error: ${escapeHtml(res.error.message || '')}</div>`;
      return;
    }
    _tabState.loaded['seatdata-sales'] = true;
    renderSeatdataSalesFull(res.data, performance.now() - t0, windowDays);
  }

  function renderSeatdataSalesFull(d, ms, windowDays) {
    const body = document.getElementById('seatdataSalesFullBody');
    const meta = document.getElementById('seatdataSalesFullMeta');
    const countChip = document.getElementById('tabCountSeatdataSales');
    if (!body) return;
    if (!d || d.hidden) {
      body.innerHTML = '<div class="empty">no SeatData sales for this event</div>';
      if (meta) meta.textContent = '0 rows';
      if (countChip) countChip.textContent = '0';
      return;
    }
    const rows = d.rows || [];
    const sdId = d.sd_event_id != null ? ` · sd_event_id ${d.sd_event_id}` : '';
    if (meta) meta.textContent = `${rows.length} rows · ${ms.toFixed(0)}ms · ${windowDays}d window${sdId}`;
    if (countChip) countChip.textContent = String(rows.length);
    if (!rows.length) {
      body.innerHTML = `<div class="empty">no SeatData sales in last ${windowDays} days</div>`;
      return;
    }
    const host = document.createElement('div');
    host.className = 'full-list-host';
    const tbl = document.createElement('table');
    tbl.className = 'full-list-tbl';
    tbl.innerHTML = `
      <thead><tr>
        <th>Sold</th><th>Zone</th><th>Section</th><th>Row</th>
        <th class="num">Qty</th><th class="num">Price</th>
      </tr></thead><tbody></tbody>`;
    const tb = tbl.querySelector('tbody');
    rows.forEach(r => {
      const tr = document.createElement('tr');
      tr.innerHTML = `
        <td>${T.fmtDate(r.sale_timestamp)}</td>
        <td>${escapeHtml(r.zone || '—')}</td>
        <td>${escapeHtml(r.section || '—')}</td>
        <td>${escapeHtml(r.row || '—')}</td>
        <td class="num">${T.fmtNum(r.quantity)}</td>
        <td class="num">${r.price != null ? '$' + T.fmtNum(Math.round(r.price)) : '—'}</td>`;
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

  // ---------- Our SG SellerDirect Listings (our inventory, AQ-mapped) ----------
  async function loadSgSellerListingsFull(eventId) {
    const body = document.getElementById('sgSellerListingsFullBody');
    const meta = document.getElementById('sgSellerListingsFullMeta');
    if (body) body.innerHTML = '<div class="empty">Loading our SG SellerDirect inventory…</div>';
    if (meta) meta.textContent = 'loading…';
    const t0 = performance.now();
    const res = await rpcOrNull('get_event_sg_seller_listings_full', { p_event_id: eventId, p_limit: 500 });
    if (res.error) {
      if (meta) meta.textContent = 'error';
      if (body) body.innerHTML = `<div class="empty">RPC error: ${escapeHtml(res.error.message || '')}</div>`;
      return;
    }
    _tabState.loaded['sg-seller-listings'] = true;
    renderSgSellerListingsFull(res.data, performance.now() - t0);
  }

  function renderSgSellerListingsFull(d, ms) {
    const body = document.getElementById('sgSellerListingsFullBody');
    const meta = document.getElementById('sgSellerListingsFullMeta');
    if (!body) return;
    if (!d || d.hidden) {
      const reason = d && d.reason === 'no_seller_listings'
        ? 'no SG SellerDirect inventory mapped to this event' : 'hidden';
      body.innerHTML = `<div class="empty">${escapeHtml(reason)}</div>`;
      if (meta) meta.textContent = '0 listings';
      return;
    }
    const rows = d.rows || [];
    const s = d.summary || {};
    if (meta) {
      const med = s.median_cost != null ? '$' + T.fmtNum(Math.round(s.median_cost)) : '—';
      meta.textContent = `${s.total_listings || rows.length} listings · ${s.total_tickets || 0} tix · median cost ${med} · ${ms.toFixed(0)}ms`;
    }
    if (!rows.length) {
      body.innerHTML = '<div class="empty">no SG SellerDirect inventory for this event</div>';
      return;
    }
    const host = document.createElement('div');
    host.className = 'full-list-host';
    const tbl = document.createElement('table');
    tbl.className = 'full-list-tbl';
    tbl.innerHTML = `
      <thead><tr>
        <th>Section</th><th>Row</th>
        <th class="num">Qty</th><th class="num">Cost</th>
        <th>In-Hand</th><th>Delivery</th><th>Notes</th>
        <th>Pulled</th>
      </tr></thead><tbody></tbody>`;
    const tb = tbl.querySelector('tbody');
    rows.forEach(r => {
      const tr = document.createElement('tr');
      const deliv = [r.is_instant ? 'instant' : null, r.is_edelivery ? 'edeliv' : null]
        .filter(Boolean).join('·') || '—';
      tr.innerHTML = `
        <td>${escapeHtml(r.section || '—')}</td>
        <td>${escapeHtml(r.row || '—')}</td>
        <td class="num">${T.fmtNum(r.quantity)}</td>
        <td class="num">${r.cost != null ? '$' + T.fmtNum(Math.round(r.cost)) : '—'}</td>
        <td>${r.in_hand_date ? T.fmtDate(r.in_hand_date) : '—'}</td>
        <td>${escapeHtml(deliv)}</td>
        <td class="muted">${escapeHtml(r.notes || '')}</td>
        <td>${r.pulled_at ? T.fmtDate(r.pulled_at) : '—'}</td>`;
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
    // Preferred: uniform per-source distribution computed on the fly for EVERY source
    // (mig 20260603120000). Falls back to the legacy TEvo/SG panel until A1 applies it,
    // so this is deploy-safe before the migration lands.
    const resU = await rpcOrNull('get_event_all_source_listing_metrics', { p_event_id: eventId });
    if (!resU.error && resU.data && Array.isArray(resU.data.sources) && resU.data.sources.length) {
      renderAllSourceMetrics(resU.data, performance.now() - t0);
      return;
    }
    // Legacy fallback (sets _lastCrossSource so the TD-snapshot / v3 re-render hooks work).
    const res = await rpcOrNull('get_event_cross_source_metrics', { p_event_id: eventId });
    if (res.error) {
      if (body) body.innerHTML = `<div class="empty">RPC error: ${escapeHtml(res.error.message || '')}</div>`;
      if (meta) meta.textContent = 'error';
      return;
    }
    renderCrossSourceMetrics(res.data || {}, performance.now() - t0);
  }

  // Uniform multi-source distribution table (mig 20260603120000): one consistent
  // methodology for every source (TEvo · SG · SH · GT · VD · TP · TM) — listings,
  // tickets, min, median, p90, owned median — computed live from each firehose's
  // latest batch. Metric rows × source columns; null cells render "—".
  function renderAllSourceMetrics(d, ms) {
    const body = document.getElementById('crossSourceBody');
    const meta = document.getElementById('crossSourceMeta');
    if (!body) return;
    const sources = (d && d.sources) || [];
    if (meta) {
      meta.textContent = (d && d.sg_event_id != null ? `sg_event_id ${d.sg_event_id} · ` : '')
        + `all-source live distribution${ms != null ? ` · ${ms.toFixed(0)}ms` : ''}`;
    }
    const METRICS = [
      { label: 'Listings count',    key: 'listings',     money: false },
      { label: 'Tickets available', key: 'tickets',      money: false },
      { label: 'Min price',         key: 'min',          money: true },
      { label: 'Median price',      key: 'median',       money: true },
      { label: 'P90 price',         key: 'p90',          money: true },
      { label: 'Owned median',      key: 'owned_median', money: true },
    ];
    const fmt = (v, money) => (v == null ? '—' : (money ? '$' + T.fmtNum(Math.round(v)) : T.fmtNum(v)));
    const tbl = document.createElement('table');
    tbl.className = 'cross-src-tbl';
    tbl.innerHTML = `<thead><tr><th>Metric</th>${sources.map(s => `<th class="num">${escapeHtml(s.label || s.key)}</th>`).join('')}</tr></thead><tbody></tbody>`;
    const tb = tbl.querySelector('tbody');
    METRICS.forEach(m => {
      const tr = document.createElement('tr');
      tr.innerHTML = `<td>${escapeHtml(m.label)}</td>`
        + sources.map(s => `<td class="num">${fmt(s[m.key], m.money)}</td>`).join('');
      tb.appendChild(tr);
    });
    body.innerHTML = '';
    body.appendChild(tbl);
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

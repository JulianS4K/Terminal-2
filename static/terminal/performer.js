// D0 Terminal — Performer page (two modes).
//
// INDEX mode  (no ?performer in URL): 4-league directory from
//   get_broker_performer_index. Click a row → DETAIL mode.
// DETAIL mode (?performer=<id>):      hero + portfolio rollup +
//   4 tabs (Overview / Upcoming Events / Blind Spots / ESPN Context).
//   Fetches /api/broker/performer/{id}/assets + /api/portfolio?performer_id
//   like before, plus get_broker_performer_page for the ESPN tab.
//
// ESPN tab is lazy-loaded on first click (one Path C RPC). Other tabs
// derive from the assets + portfolio payload already in memory.

(function () {
  'use strict';
  const T = window.Terminal;

  function getPerformerId() {
    const v = new URLSearchParams(location.search).get('performer');
    if (!v) return null;
    const n = parseInt(v, 10);
    return Number.isFinite(n) && n > 0 ? n : null;
  }

  // ?venue=<id> — a Broadway show's NYC house. When present, the page is scoped
  // to that venue (NYC performances only), because the show's franchise
  // performer (e.g. "Wicked - Musical") also covers the national tour.
  function getVenueScope() {
    const v = new URLSearchParams(location.search).get('venue');
    const n = parseInt(v, 10);
    return Number.isFinite(n) && n > 0 ? n : null;
  }

  async function init() {
    if (window.TerminalAuth) await window.TerminalAuth.requireAuth();
    const performerId = getPerformerId();
    if (!performerId) {
      showIndexMode();
      return;
    }
    showDetailMode(performerId);
  }

  // ============================================================
  // INDEX mode — 4-league directory
  // ============================================================
  async function showIndexMode() {
    const idx = document.getElementById('perf-index');
    if (idx) idx.removeAttribute('hidden');
    T.setStatus('Loading performer index…');
    const Auth = window.TerminalAuth;
    if (!Auth || !Auth.client || !Auth.getAccessToken()) {
      document.getElementById('perfIndexBody').innerHTML =
        '<div class="empty">index needs auth — sign in with @s4kent.com</div>';
      T.setStatus('Auth required', 'err');
      return;
    }
    const res = await Auth.client.rpc('get_broker_performer_index');
    if (res.error) {
      T.setStatus(res.error.message, 'err');
      document.getElementById('perfIndexBody').innerHTML =
        `<div class="empty">RPC error: ${escapeHtml(res.error.message)}</div>`;
      return;
    }
    T.setStatus('Loaded', 'ok');
    renderIndex(res.data || {});
  }

  function renderIndex(d) {
    const body = document.getElementById('perfIndexBody');
    const countsEl = document.getElementById('perfIndexCounts');
    const counts = d.counts || {};
    const leagues = d.leagues || {};
    // Directory columns, in order. Broadway is a category whose "teams" are
    // shows (link to the event Cast tab); WNBA joined the sports leagues.
    const LEAGUE_ORDER = ['NFL','NBA','MLB','MLS','WNBA','Broadway'];
    if (countsEl) {
      const parts = LEAGUE_ORDER
        .filter(l => counts[l])
        .map(l => `${l} ${counts[l]}`);
      if (counts.total) parts.push(`· ${counts.total} total`);
      countsEl.textContent = parts.join(' · ');
    }
    body.innerHTML = '';
    const grid = document.createElement('div');
    grid.className = 'entity-index-grid';
    LEAGUE_ORDER.forEach(league => {
      const teams = leagues[league] || [];
      if (!teams.length) return;
      const col = document.createElement('div');
      col.className = 'entity-index-col';
      col.innerHTML = `<div class="entity-index-col-hdr">${league} <span class="muted small">(${teams.length})</span></div>`;
      const ul = document.createElement('ul');
      ul.className = 'entity-index-list';
      teams.forEach(t => {
        const li = document.createElement('li');
        const upcoming = t.events_count_next_90d != null ? `<span class="entity-idx-count">${t.events_count_next_90d}</span>` : '';
        // Teams link to their performer page. Broadway shows link there too, but
        // with &venue=<nyc house> so the page scopes to NYC (the show's franchise
        // performer also tours). Fallback to a representative event if no id.
        let href = t.tevo_performer_id
          ? `performer.html?performer=${t.tevo_performer_id}`
          : (t.sample_event_id ? `event.html?event=${t.sample_event_id}` : '#');
        if (t.tevo_performer_id && t.tevo_venue_id) href += `&venue=${t.tevo_venue_id}`;
        li.innerHTML = `<a href="${href}">
            <span class="entity-idx-name">${escapeHtml(t.display_name || t.performer_name || '—')}</span>
            ${t.abbreviation ? `<span class="muted small">${escapeHtml(t.abbreviation)}</span>` : ''}
            ${upcoming}
          </a>`;
        ul.appendChild(li);
      });
      col.appendChild(ul);
      grid.appendChild(col);
    });
    body.appendChild(grid);
  }

  // ============================================================
  // DETAIL mode — hero + rollup + tabs (Overview default)
  // ============================================================
  function showDetailMode(performerId) {
    // Unhide DETAIL chrome; Overview pane is already active in HTML
    document.getElementById('perf-hero').removeAttribute('hidden');
    document.getElementById('perfTabs').removeAttribute('hidden');

    wireTabs(performerId);
    T.setStatus(`Loading performer ${performerId}…`);
    // Eager-load ESPN for form strip (non-blocking)
    loadEspnContext(performerId).catch(e => console.error('espn-eager', e));
    // Prediction markets (Kalshi/Polymarket) for this team; fire-and-forget,
    // hides itself when there's nothing to show.
    loadPerformerPredictionMarkets(performerId).catch(e => console.error('perf-pm', e));
    // Broadway cast get-in — reveals the Cast tab only for a show-as-performer.
    loadPerfCast(performerId).catch(e => console.error('perf-cast', e));
    // ESPN injury price-impact — reveals the Injuries tab only for a team.
    loadPerfInjury(performerId).catch(e => console.error('perf-injury', e));

    // NYC-Broadway scope: a show's franchise performer also tours, so when a
    // venue is pinned, load the portfolio by venue (NYC performances only) and
    // hide the Upcoming Events tab (a multi-city tour optimizer — irrelevant to
    // a single-house sit-down run and would surface tour cities).
    const venueScope = getVenueScope();
    if (venueScope) {
      const upBtn = document.querySelector('#perfTabs .event-tab[data-tab="upcoming"]');
      if (upBtn) { upBtn.hidden = true; upBtn.style.display = 'none'; }
    }
    const portfolioUrl = venueScope
      ? `/api/portfolio?venue_id=${venueScope}`
      : `/api/portfolio?performer_id=${performerId}`;

    Promise.all([
      T.api(`/api/broker/performer/${performerId}/assets`).catch(e => ({ __err: e })),
      T.api(portfolioUrl).catch(e => ({ __err: e })),
    ]).then(([assets, portfolio]) => {
      const firstErr = [assets, portfolio].find(r => r && r.__err);
      if (firstErr) T.setStatus(firstErr.__err.message, 'err');
      else T.setStatus('Loaded', 'ok');
      // Stash portfolio
      _tabState.portfolio = (portfolio && !portfolio.__err) ? portfolio : null;
      try { renderHero(assets, portfolio); }      catch (e) { console.error('hero', e); }
      try { renderRollup(portfolio); }            catch (e) { console.error('rollup', e); }
      try { initDailyMetrics(performerId, portfolio); } catch (e) { console.error('dailyMetrics', e); }
      try { renderEvents(portfolio); }            catch (e) { console.error('events', e); }
      try { renderBlindSpots(portfolio); }        catch (e) { console.error('blindSpots', e); }
    });
  }

  // ---------- Tab nav ----------
  const _tabState = { loaded: { espn: false, alerts: false, trip: false }, performerId: null, portfolio: null };

  function wireTabs(performerId) {
    _tabState.performerId = performerId;
    const nav = document.getElementById('perfTabs');
    if (!nav) return;
    nav.addEventListener('click', async (e) => {
      const btn = e.target.closest('.event-tab');
      if (!btn) return;
      const tabId = btn.dataset.tab;
      activateTab(tabId);
      if (tabId === 'espn' && !_tabState.loaded.espn) {
        await loadEspnContext(performerId);
      } else if (tabId === 'upcoming' && !_tabState.loaded.trip) {
        initTripPlanner(performerId);
      } else if (tabId === 'alerts' && !_tabState.loaded.alerts) {
        _tabState.loaded.alerts = true;
        const label = document.getElementById('phName')?.textContent || '';
        window.TerminalAlerts?.mount('performer', performerId, label, document.querySelector('#panePerfAlerts .alerts-root'));
      }
    });
  }

  const PERF_PANE_IDS = {
    overview:   'paneOverview',
    upcoming:   'paneUpcoming',
    blindspots: 'paneBlindspots',
    cast:       'panePerfCast',
    injury:     'panePerfInjury',
    futures:    'panePerfFutures',
    espn:       'paneEspn',
    alerts:     'panePerfAlerts',
  };

  // Broadway "who's playing the lead" — reveals the Cast tab ONLY for a
  // show-as-performer (broadway_show_ref.tevo_performer_id). Fire-and-forget;
  // hidden for teams. Shares window.CastPanel with the event page.
  async function loadPerfCast(performerId) {
    let data;
    try { data = await T.api(`/api/broker/performer/${performerId}/broadway-cast`); }
    catch (_) { return; }
    const parts = (data && data.participants) || [];
    if (!data || !data.applicable || !parts.length) return;  // not a Broadway show
    const btn = document.getElementById('perfCastTab');
    if (btn) { btn.hidden = false; btn.style.removeProperty('display'); }
    const cnt = document.getElementById('tabCountPerfCast');
    if (cnt) cnt.textContent = String(parts.length);
    const priced = parts.filter(p => p.measured).length;
    const meta = document.getElementById('perfCastMeta');
    if (meta) meta.textContent = `${parts.length} leads · ${priced} priced`;
    const ttl = document.getElementById('perfCastTitle');
    if (ttl && data.subject) ttl.textContent = `CAST — get-in by lead · ${data.subject.title}`;
    window.CastPanel.render(document.getElementById('perfCastBody'), data);
  }

  // ESPN injury price-impact — reveals the Injuries tab ONLY for a team with
  // current injuries. Same window.CastPanel, kind='espn'. Fire-and-forget.
  async function loadPerfInjury(performerId) {
    let data;
    try { data = await T.api(`/api/broker/performer/${performerId}/injury-getin`); }
    catch (_) { return; }
    const parts = (data && data.participants) || [];
    if (!data || !data.applicable || !parts.length) return;  // not a team / no injuries
    const btn = document.getElementById('perfInjuryTab');
    if (btn) { btn.hidden = false; btn.style.removeProperty('display'); }
    const cnt = document.getElementById('tabCountPerfInjury');
    if (cnt) cnt.textContent = String(parts.length);
    const priced = parts.filter(p => p.measured).length;
    const meta = document.getElementById('perfInjuryMeta');
    if (meta) meta.textContent = `${parts.length} out · ${priced} with priced games`;
    const ttl = document.getElementById('perfInjuryTitle');
    if (ttl && data.subject) ttl.textContent = `INJURIES — team get-in while out · ${data.subject.title}`;
    window.CastPanel.render(document.getElementById('perfInjuryBody'), data);
  }

  function activateTab(tabId) {
    document.querySelectorAll('#perfTabs .event-tab').forEach(b => {
      const on = b.dataset.tab === tabId;
      b.classList.toggle('active', on);
      b.setAttribute('aria-selected', on ? 'true' : 'false');
    });
    Object.entries(PERF_PANE_IDS).forEach(([id, paneId]) => {
      const pane = document.getElementById(paneId);
      if (!pane) return;
      if (id === tabId) { pane.removeAttribute('hidden'); pane.classList.add('active'); }
      else { pane.setAttribute('hidden', ''); pane.classList.remove('active'); }
    });
  }

  // ---------- Trip Planner (lazy-loaded tab) ----------
  // Calls /api/broker/performers/{id}/trip-plan (shared trip_planner module) and shows
  // the optimal multi-city itinerary vs the naive sort-by-date baseline.

  function initTripPlanner(performerId) {
    _tabState.loaded.trip = true;
    const slider = document.getElementById('tripBudget');
    const label = document.getElementById('tripBudgetLabel');
    if (slider && label) slider.addEventListener('input', () => { label.textContent = slider.value; });
    const go = document.getElementById('tripGo');
    if (go) go.addEventListener('click', () => runTripPlan(performerId));
    const tourGo = document.getElementById('tourGo');
    if (tourGo) tourGo.addEventListener('click', () => priceTour(performerId));
    runTripPlan(performerId);
  }

  // ---------- Retail tour package (dual-mode pricing) ----------
  async function priceTour(performerId) {
    const body = document.getElementById('tourBody');
    const stats = document.getElementById('tourStats');
    if (!body) return;
    const q = new URLSearchParams({
      home_lat: document.getElementById('tripLat').value,
      home_lon: document.getElementById('tripLon').value,
      home_name: document.getElementById('tripHome').value,
      qty: document.getElementById('tripQty').value || '3',
      budget_km: document.getElementById('tripBudget').value,
      side: document.getElementById('tourSide').value,
      days: '365',
    });
    const sec = document.getElementById('tourSection');
    if (sec && sec.value.trim()) q.set('section_like', sec.value.trim());
    const po = document.getElementById('tourPreferOwned');
    if (po && po.value) q.set('prefer_owned', 'true');
    body.innerHTML = '<div class="empty">pricing tour…</div>';
    if (stats) stats.hidden = true;
    try {
      const d = await T.api(`/api/broker/performers/${performerId}/tour-package?` + q.toString());
      renderTour(d);
    } catch (e) {
      body.innerHTML = `<div class="empty">error: ${escapeHtml(e.message || String(e))}</div>`;
    }
  }

  function _money(n) { return '$' + Math.round(n || 0).toLocaleString(); }

  function renderTour(d) {
    const body = document.getElementById('tourBody');
    const stats = document.getElementById('tourStats');
    const meta = document.getElementById('tourMeta');
    const pk = d.package || {};
    const modeLabel = d.mode === 'team_away' ? 'team · away games · market-sourced'
      : d.mode === 'team_home' ? 'team · home stand · owned-splits'
      : 'concert · owned-splits';
    if (meta) meta.textContent = `${modeLabel} · ${d.stops_available || 0} stops · ${d.qty_per_show} tix/show`;
    if (!d.stops_available || !pk.count) {
      if (stats) stats.hidden = true;
      body.innerHTML = '<div class="empty">no routable tour for this performer</div>';
      return;
    }
    const vsm = pk.vs_market;
    if (stats) {
      stats.hidden = false;
      stats.innerHTML =
        `<div><span class="ts-num">${_money(pk.fan_total_bundled)}</span><span class="ts-lbl">package · ${pk.count * d.qty_per_show} tix</span></div>` +
        `<div><span class="ts-num ${vsm < 0 ? 'gain' : ''}">${vsm < 0 ? _money(-vsm) : '+' + _money(vsm)}</span><span class="ts-lbl">${vsm < 0 ? 'fan saves vs market' : 'premium vs market'}</span></div>` +
        `<div><span class="ts-num">${pk.owned_moved ? pk.owned_moved : _money(pk.gross_margin || 0)}</span><span class="ts-lbl">${pk.owned_moved ? 'owned tix moved' : 'fulfillment margin'}</span></div>` +
        `<div><span class="ts-num">${pk.cities} / ${Math.round(pk.travel_km)}</span><span class="ts-lbl">cities / km</span></div>`;
    }
    const picked = new Set((pk.legs || []).map(l => l.event_id));
    const rows = (d.all_stops || []).map(l => {
      const on = picked.has(l.event_id);
      const src = l.unit_price == null ? '' : `<span class="tsrc ${l.sourcing === 'owned' ? 'owned' : 'market'}">${l.sourcing}</span>`;
      const px = l.unit_price == null ? '<span class="tr-px">n/a</span>' : `<span class="tr-px">${_money(l.unit_price)}</span>`;
      const mm = l.market_median != null ? `<span class="tr-mm">mkt ${_money(l.market_median)}</span>` : '<span class="tr-mm"></span>';
      const s = l.seats;
      const seat = s ? `<span class="muted small" title="auto-selected ticket group${s.is_owned ? ' (ours)' : ''}">${escapeHtml(s.section || 'GA')}${s.row ? ' ' + escapeHtml(s.row) : ''}${s.is_owned ? ' ·ours' : ''}</span>`
        : (l.selection === 'estimate' ? '<span class="muted small" style="opacity:.55">est</span>' : '');
      const hot = l.hot ? ' <span title="high demand">🔥</span>' : '';
      return `<div class="trip-row${on ? '' : ' skip'}">`
        + `<span class="tr-date">${escapeHtml(_tripDate(l.date))}</span>`
        + `<span class="tr-city">${escapeHtml(l.city || '—')}</span>`
        + `<span>${escapeHtml(l.event_name || l.venue || '')}${hot}</span>`
        + seat + src + px + mm + '</div>';
    }).join('');
    body.innerHTML = `<div class="trip-list">${rows}</div>`;
  }

  async function runTripPlan(performerId) {
    const body = document.getElementById('tripBody');
    const stats = document.getElementById('tripStats');
    if (!body) return;
    const q = new URLSearchParams({
      home_lat: document.getElementById('tripLat').value,
      home_lon: document.getElementById('tripLon').value,
      home_name: document.getElementById('tripHome').value,
      budget_km: document.getElementById('tripBudget').value,
      budget_usd: document.getElementById('tripUsd').value || '0',
      qty: document.getElementById('tripQty').value || '1',
      days: '365',
    });
    body.innerHTML = '<div class="empty">planning…</div>';
    if (stats) stats.hidden = true;
    try {
      const d = await T.api(`/api/broker/performers/${performerId}/trip-plan?` + q.toString());
      renderTripPlan(d);
    } catch (e) {
      body.innerHTML = `<div class="empty">error: ${escapeHtml(e.message || String(e))}</div>`;
    }
  }

  function _tripDate(iso) {
    try { return new Date(iso + 'T00:00:00').toLocaleDateString(undefined, { month: 'short', day: 'numeric', year: 'numeric' }); }
    catch (_) { return iso; }
  }

  // Build a self-contained SVG route map (no tiles / external libs — CSP-safe).
  // A simplified continental-US silhouette is drawn as the basemap on a FIXED
  // equirectangular frame, so the route always reads against a recognizable map.
  // Coarse lower-48 outline (clockwise [lat, lon]); approximate, for context only.
  const _US_OUTLINE = [
    [48.4, -124.7], [46.2, -124.1], [43.3, -124.4], [40.4, -124.4], [38.0, -123.0], [36.6, -121.9],
    [34.4, -120.5], [33.7, -118.4], [32.5, -117.1], [32.7, -114.5], [31.3, -111.1], [31.3, -108.2],
    [31.8, -106.5], [29.8, -104.0], [29.2, -102.8], [26.0, -99.2], [25.9, -97.1], [27.8, -97.0],
    [29.7, -93.8], [29.1, -90.1], [30.2, -88.0], [30.4, -86.5], [29.7, -84.0], [28.0, -82.8],
    [25.8, -81.5], [25.2, -80.3], [27.0, -80.1], [29.9, -81.3], [32.0, -80.9], [33.9, -78.0],
    [36.9, -76.0], [38.9, -75.0], [40.5, -74.0], [41.4, -71.5], [42.4, -70.6], [43.7, -70.0],
    [44.8, -67.0], [45.2, -67.8], [45.0, -71.5], [45.0, -74.7], [44.0, -76.5], [43.3, -79.2],
    [42.3, -83.0], [46.0, -84.4], [46.6, -88.4], [47.4, -90.5], [48.0, -89.5], [49.0, -95.2],
    [49.0, -104.0], [49.0, -114.0], [49.0, -122.8], [48.4, -124.7],
  ];

  function buildTripMap(d) {
    if (!d.all_dates || !d.all_dates.length) return '';
    const minLon = -125, maxLon = -66, minLat = 24, maxLat = 50;   // fixed continental frame
    const k = Math.cos(37 * Math.PI / 180);
    const pad = 8, W = 600;
    const scale = (W - 2 * pad) / ((maxLon - minLon) * k);
    const H = Math.round((maxLat - minLat) * scale + 2 * pad);
    const proj = (lat, lon) => [pad + (lon - minLon) * k * scale, pad + (maxLat - lat) * scale];

    const land = 'M' + _US_OUTLINE.map(p => { const [x, y] = proj(p[0], p[1]); return x.toFixed(1) + ' ' + y.toFixed(1); }).join(' L ') + ' Z';

    const [hx, hy] = proj(+d.home.lat, +d.home.lon);
    const going = d.optimal.events || [];
    const picked = new Set(going.map(e => e.event_id));

    const route = [[hx, hy], ...going.map(e => proj(+e.lat, +e.lon)), [hx, hy]];
    const routeD = route.map((p, i) => (i ? 'L' : 'M') + p[0].toFixed(1) + ' ' + p[1].toFixed(1)).join(' ');

    let dots = '';
    d.all_dates.forEach(e => {
      const [x, y] = proj(+e.lat, +e.lon);
      const on = picked.has(e.event_id);
      dots += `<circle cx="${x.toFixed(1)}" cy="${y.toFixed(1)}" r="${on ? 4.5 : 3}" class="${on ? 'tm-go' : 'tm-skip'}">`
        + `<title>${escapeHtml((e.city || '') + ' · ' + (e.venue || '') + ' · ' + e.date)}</title></circle>`;
    });

    let labels = ''; const seen = new Set();
    going.forEach(e => {
      if (seen.has(e.city)) return;
      seen.add(e.city);
      const [x, y] = proj(+e.lat, +e.lon);
      labels += `<text x="${(x + 6).toFixed(1)}" y="${(y + 3).toFixed(1)}" class="tm-lbl">${escapeHtml(e.city || '')}</text>`;
    });

    const home = `<g class="tm-home"><circle cx="${hx.toFixed(1)}" cy="${hy.toFixed(1)}" r="4.5"/>`
      + `<text x="${(hx + 6).toFixed(1)}" y="${(hy + 3).toFixed(1)}" class="tm-lbl tm-home-lbl">${escapeHtml(d.home.name || 'Home')}</text></g>`;

    return `<svg viewBox="0 0 ${W} ${H}" class="trip-map-svg" preserveAspectRatio="xMidYMid meet" role="img" aria-label="Trip route map">`
      + `<path d="${land}" class="tm-land"/><path d="${routeD}" class="tm-route"/>${dots}${home}${labels}</svg>`;
  }

  function renderTripPlan(d) {
    const body = document.getElementById('tripBody');
    const stats = document.getElementById('tripStats');
    const mapEl = document.getElementById('tripMap');
    const meta = document.getElementById('tripMeta');
    if (meta) {
      const cov = d.coord_coverage || {};
      const extra = [];
      if (d.qty_per_show) extra.push(`${d.qty_per_show} tix/show`);
      if (cov.city_fallback) extra.push(`${cov.city_fallback} ≈ city`);
      if (cov.dropped_no_coords) extra.push(`${cov.dropped_no_coords} no-coords dropped`);
      if (d.unpriced_events) extra.push(`${d.unpriced_events} no price`);
      meta.textContent = d.tour_date_count
        ? `${d.tour_date_count} dates · ${Math.round(d.budget_km)} km${d.budget_usd != null ? ' · $' + Math.round(d.budget_usd) : ''}${extra.length ? ' · ' + extra.join(', ') : ''}`
        : '';
    }
    if (!d.tour_date_count) {
      if (stats) stats.hidden = true;
      if (mapEl) mapEl.hidden = true;
      body.innerHTML = '<div class="empty">no upcoming geocoded dates for this performer</div>';
      return;
    }
    const o = d.optimal, b = d.baseline_by_date;
    if (mapEl) {
      const svg = buildTripMap(d);
      if (svg) { mapEl.innerHTML = svg; mapEl.hidden = false; }
      else { mapEl.hidden = true; }
    }
    if (stats) {
      const spendLbl = `ticket spend${d.budget_usd != null ? ' / $' + Math.round(d.budget_usd) : ''}`;
      stats.hidden = false;
      stats.innerHTML =
        `<div><span class="ts-num">${o.count}</span><span class="ts-lbl">optimal shows · ${Math.round(o.travel_km)} km</span></div>` +
        `<div><span class="ts-num">$${Math.round(o.spend_usd || 0).toLocaleString()}</span><span class="ts-lbl">${spendLbl}</span></div>` +
        `<div><span class="ts-num">${b.count}</span><span class="ts-lbl">sort-by-date · ${Math.round(b.travel_km)} km</span></div>` +
        `<div><span class="ts-num gain">+${d.shows_gained}</span><span class="ts-lbl">shows gained</span></div>`;
    }
    const picked = new Set(o.events.map(e => e.event_id));
    const cities = [...new Set(o.events.map(e => e.city))].filter(Boolean).join(' → ');
    const rows = (d.all_dates || []).map(e => {
      const on = picked.has(e.event_id);
      const approx = e.coord_source === 'city' ? ' <span class="muted small" title="approximate city-centroid location">≈</span>' : '';
      const owned = e.owned ? `<span class="tr-own" title="EVO owned tickets">own ${e.owned}</span>` : '';
      const price = e.getin != null ? `$${Math.round(e.getin)}` : (e.cost_known ? '' : '<span class="muted">n/a</span>');
      const cost = e.ticket_cost != null
        ? `<span class="tr-cost" title="get-in × max(0, qty − owned)">${e.ticket_cost === 0 ? 'free' : '$' + Math.round(e.ticket_cost).toLocaleString()}</span>`
        : '';
      return `<div class="trip-row${on ? '' : ' skip'}">`
        + `<span class="tr-date">${escapeHtml(_tripDate(e.date))}</span>`
        + `<span class="tr-city">${escapeHtml(e.city || '')}${approx}</span>`
        + `<span class="tr-venue">${escapeHtml(e.venue || '')}</span>`
        + `<span class="tr-px">${price}</span>${owned}${cost}`
        + (on ? '<span class="tr-go">● going</span>' : '')
        + '</div>';
    }).join('');
    body.innerHTML = (cities ? `<div class="muted small" style="margin:4px 0 6px">${escapeHtml(cities)}</div>` : '') + `<div class="trip-list">${rows}</div>`;
  }

  // ---------- Hero ----------

  function renderHero(assets, portfolio) {
    const a = assets && !assets.__err ? assets : {};
    const firstEvent = portfolio && !portfolio.__err && portfolio.events && portfolio.events[0];
    const nameFromPortfolio = firstEvent && firstEvent.primary_performer_name;
    const name = a.name || nameFromPortfolio || 'Performer';
    setText('phName', name);
    setText('phLeague', a.espn_league || '—');
    setText('phEventType', a.espn_team_id ? 'sports (ESPN linked)' : 'unlinked');

    const espnBadge = document.getElementById('phEspnBadge');
    if (a.espn_team_id) {
      espnBadge.classList.add('lifecycle-active');
      espnBadge.textContent = 'ESPN · ' + a.espn_team_id;
    } else {
      espnBadge.style.display = 'none';
    }

    const logo = document.getElementById('phLogo');
    const url = a.logo_default_url || a.logo_dark_url || a.logo_4k_primary_url;
    if (url) { logo.src = url; logo.alt = name + ' logo'; }
    else { logo.style.display = 'none'; }

    if (a.color_primary) {
      document.getElementById('perf-hero').style.borderLeft = `4px solid ${a.color_primary}`;
    }
  }

  // ---------- Rollup ----------

  function renderRollup(portfolio) {
    if (!portfolio || portfolio.__err) return;
    const ag = portfolio.aggregate || {};
    setText('ruEvents',         T.fmtNum(ag.events_count));
    setText('ruOwnedTix',       T.fmtNum(ag.owned_tickets_total));
    setText('ruOwnedNotional',  ag.owned_retail_value_total ? '$' + T.fmtNum(Math.round(ag.owned_retail_value_total)) : '—');
    setText('ruOwnedShare',     ag.owned_share_weighted != null ? T.fmtPct(ag.owned_share_weighted * 100, 1) : '—');
    setText('ruRetailMedAvg',   ag.retail_median_avg_weighted ? '$' + T.fmtNum(Math.round(ag.retail_median_avg_weighted)) : '—');
    setText('ruEventsWithOwned', T.fmtNum(ag.events_with_owned));
  }

  // ---------- Cross-event daily metrics (Overview) ----------
  //
  // Surfaces the STORED performer-level timeseries (performer_metrics_daily,
  // refreshed every 4h) via get_performer_metrics_daily(id, days, split). Unlike
  // the live PORTFOLIO ROLLUP above (computed from /api/portfolio at request time),
  // this is the persisted daily roll-up across ALL of the performer's events:
  // per-source inventory (EVO/SG, all + owned), amalgam price band (get-in
  // min/median, price min/median/p90), and owned-book notional — with day-over-day
  // deltas + 90d sparklines. Sports performers also get home/away splits.

  function initDailyMetrics(performerId, portfolio) {
    const isSports = !!(portfolio && !portfolio.__err && portfolio.is_sports_performer);
    const splitNav = document.getElementById('pdmSplit');
    if (splitNav) {
      if (isSports) {
        splitNav.removeAttribute('hidden');
        splitNav.addEventListener('click', (e) => {
          const b = e.target.closest('.event-tab');
          if (!b) return;
          splitNav.querySelectorAll('.event-tab').forEach((x) => {
            const on = x === b;
            x.classList.toggle('active', on);
            x.setAttribute('aria-selected', on ? 'true' : 'false');
          });
          loadDailyMetrics(performerId, b.dataset.split);
        });
      } else {
        splitNav.setAttribute('hidden', '');
      }
    }
    loadDailyMetrics(performerId, 'all');
  }

  async function loadDailyMetrics(performerId, split) {
    const sec = document.getElementById('perf-daily-metrics');
    const body = document.getElementById('pdmBody');
    if (!sec || !body) return;
    sec.removeAttribute('hidden');
    const Auth = window.TerminalAuth;
    if (!Auth || !Auth.client || !Auth.getAccessToken()) {
      body.innerHTML = '<div class="empty">daily metrics need auth — sign in with @s4kent.com</div>';
      return;
    }
    body.innerHTML = '<div class="empty">loading daily metrics…</div>';
    const res = await Auth.client.rpc('get_performer_metrics_daily', {
      p_performer_id: performerId, p_days: 90, p_split: split || 'all',
    });
    if (res.error) {
      body.innerHTML = `<div class="empty">RPC error: ${escapeHtml(res.error.message)}</div>`;
      return;
    }
    renderDailyMetrics(res.data || [], split || 'all');
  }

  function renderDailyMetrics(rows, split) {
    const body = document.getElementById('pdmBody');
    const meta = document.getElementById('pdmMeta');
    if (!body) return;
    if (!rows.length) {
      if (meta) meta.textContent = '';
      body.innerHTML = `<div class="empty">no daily metrics stored yet for this performer${split && split !== 'all' ? ' (' + escapeHtml(split) + ')' : ''}</div>`;
      return;
    }
    const latest = rows[rows.length - 1];
    const prev = rows.length > 1 ? rows[rows.length - 2] : null;
    if (meta) meta.textContent = `${rows.length} day${rows.length === 1 ? '' : 's'} · latest ${dayLabel(latest.snapshot_date)} · split: ${split || 'all'}`;

    const usd = (v) => (v != null && isFinite(v)) ? '$' + T.fmtNum(Math.round(v)) : '—';
    const cell = (num, lbl, extra) => `<div class="ru-cell"><span class="ru-num">${num}${extra || ''}</span><span class="ru-lbl">${lbl}</span></div>`;
    const d = (cur, prv) => prv ? deltaChip(cur, prv) : '';

    const kpis = [
      cell(T.fmtNum(latest.event_count), 'events'),
      cell(T.fmtNum(latest.evo_tickets_total), 'EVO tix (all)'),
      cell(T.fmtNum(latest.evo_owned_tickets_total), 'EVO tix (owned)'),
      cell(T.fmtNum(latest.sg_all_tickets_total), 'SG tix (all)'),
      cell(T.fmtNum(latest.sg_owned_tickets_total), 'SG tix (owned)'),
      cell(usd(latest.getin_min), 'get-in min', d(latest.getin_min, prev && prev.getin_min)),
      cell(usd(latest.getin_median), 'get-in median'),
      cell(usd(latest.price_min), 'price min'),
      cell(usd(latest.price_median), 'price median', d(latest.price_median, prev && prev.price_median)),
      cell(usd(latest.price_p90), 'price p90'),
      cell(usd(latest.owned_book_notional), 'owned book notional', d(latest.owned_book_notional, prev && prev.owned_book_notional)),
    ].join('');

    const sparkPrice = sparkline(rows.map((r) => numOrNull(r.price_median)));
    const sparkGetin = sparkline(rows.map((r) => numOrNull(r.getin_min)));
    const sparkInv   = sparkline(rows.map((r) => numOrNull(r.evo_owned_tickets_total)));
    const n = rows.length;
    const trends = `
      <div class="pdm-trends">
        ${sparkPrice ? `<div class="pdm-trend"><div class="pt-lbl">price median · last ${n}d</div><div class="pt-val">${usd(latest.price_median)}</div>${sparkPrice}</div>` : ''}
        ${sparkGetin ? `<div class="pdm-trend"><div class="pt-lbl">get-in min · last ${n}d</div><div class="pt-val">${usd(latest.getin_min)}</div>${sparkGetin}</div>` : ''}
        ${sparkInv   ? `<div class="pdm-trend"><div class="pt-lbl">owned EVO tix · last ${n}d</div><div class="pt-val">${T.fmtNum(latest.evo_owned_tickets_total)}</div>${sparkInv}</div>` : ''}
      </div>`;

    body.innerHTML = `<div class="rollup-grid">${kpis}</div>${trends}`;
  }

  function numOrNull(v) {
    if (v === null || v === undefined) return null;
    const n = Number(v);
    return Number.isFinite(n) ? n : null;
  }

  // Day-over-day percent-change chip (direction-coloured, like .chart-move).
  function deltaChip(cur, prv) {
    const a = numOrNull(cur), b = numOrNull(prv);
    if (a === null || b === null || b === 0) return '';
    const pct = (a - b) / Math.abs(b) * 100;
    if (Math.abs(pct) < 0.05) return '';
    const cls = pct >= 0 ? 'up' : 'down';
    return ` <span class="pdm-delta ${cls}">${pct >= 0 ? '▲' : '▼'} ${Math.abs(pct).toFixed(1)}%</span>`;
  }

  // Minimal CSP-safe inline sparkline (no external libs). Skips null gaps.
  function sparkline(series, w, h) {
    w = w || 240; h = h || 40;
    const pts = series.map((v, i) => [i, v]).filter((p) => p[1] !== null);
    if (pts.length < 2) return '';
    const xs = pts.map((p) => p[0]), ys = pts.map((p) => p[1]);
    const minX = Math.min(...xs), maxX = Math.max(...xs);
    const minY = Math.min(...ys), maxY = Math.max(...ys);
    const spanX = (maxX - minX) || 1, spanY = (maxY - minY) || 1;
    const pad = 3;
    const proj = (x, y) => [pad + (x - minX) / spanX * (w - 2 * pad), h - pad - (y - minY) / spanY * (h - 2 * pad)];
    const dPath = pts.map((p, i) => { const [px, py] = proj(p[0], p[1]); return (i ? 'L' : 'M') + px.toFixed(1) + ' ' + py.toFixed(1); }).join(' ');
    const lastP = pts[pts.length - 1];
    const [lx, ly] = proj(lastP[0], lastP[1]);
    return `<svg class="pdm-spark" viewBox="0 0 ${w} ${h}" preserveAspectRatio="none" role="img" aria-label="trend">`
      + `<path d="${dPath}"/><circle cx="${lx.toFixed(1)}" cy="${ly.toFixed(1)}" r="2"/></svg>`;
  }

  function dayLabel(d) {
    if (!d) return '—';
    try { return new Date(d + 'T00:00:00').toLocaleDateString(undefined, { month: 'short', day: 'numeric', year: 'numeric' }); }
    catch (_) { return d; }
  }

  // ---------- Events list ----------

  async function renderEvents(portfolio) {
    const body = document.getElementById('phEventsBody');
    const countEl = document.getElementById('phEventCount');
    const tabCount = document.getElementById('tabCountUpcoming');
    body.innerHTML = '';
    if (!portfolio || portfolio.__err) {
      body.innerHTML = '<div class="empty">portfolio unavailable</div>';
      return;
    }
    const events = portfolio.events || [];
    countEl.textContent = events.length ? `${events.length} events` : '';
    if (tabCount) tabCount.textContent = events.length ? String(events.length) : '';
    if (!events.length) {
      body.innerHTML = '<div class="empty">no upcoming events for this performer</div>';
      return;
    }
    // Phase 1b: ensure movers-index preload is done before row render so
    // T.moversChipHtml(e.id) can produce inline chips in the event-name cell.
    // Idempotent + cached — no extra cost if already preloaded by another panel.
    await T.moversPreloadIndex();
    const tbl = document.createElement('table');
    tbl.innerHTML = `
      <thead><tr>
        <th>Event</th>
        <th>Venue</th>
        <th class="num">T-days</th>
        <th class="num">Mkt qty</th>
        <th class="num">Mkt median</th>
        <th class="num">Owned qty</th>
        <th class="num">Owned med</th>
        <th class="num">Owned share</th>
        <th>Lifecycle</th>
        <th>Home?</th>
      </tr></thead>
      <tbody></tbody>
    `;
    const tb = tbl.querySelector('tbody');
    events.forEach(e => {
      const d = T.daysUntil(e.occurs_at_local);
      const lc = (e.lifecycle && e.lifecycle.status) || '—';
      const lcCls = e.lifecycle && e.lifecycle.is_active ? 'lifecycle-active'
                  : /ghost|cancel|postpon/i.test(lc) ? 'lifecycle-ghost'
                  : 'lifecycle-complete';
      const isHome = e.is_home === true ? 'HOME' : e.is_home === false ? 'AWAY' : '—';
      const ownedShare = e.owned_share != null ? T.fmtPct(e.owned_share * 100, 0) : '—';
      const tr = document.createElement('tr');
      tr.innerHTML = `
        <td><a href="event.html?event=${e.id}">${escapeHtml(e.name || ('Event ' + e.id))}</a> ${T.moversChipHtml(e.id)} ${T.temporalChipHtml(e.occurs_at_local)}</td>
        <td>${escapeHtml(e.venue_name || '—')}</td>
        <td class="num">${d === null ? '—' : d}</td>
        <td class="num">${T.fmtNum(e.tickets_count || 0)}</td>
        <td class="num">${e.retail_median ? '$' + T.fmtNum(Math.round(e.retail_median)) : '—'}</td>
        <td class="num ${(e.owned_tickets_count || 0) > 0 ? 'ours' : ''}">${T.fmtNum(e.owned_tickets_count || 0)}</td>
        <td class="num">${e.owned_median_retail ? '$' + T.fmtNum(Math.round(e.owned_median_retail)) : '—'}</td>
        <td class="num">${ownedShare}</td>
        <td><span class="badge ${lcCls}">${escapeHtml(String(lc).toUpperCase())}</span></td>
        <td>${isHome === '—' ? '—' : `<span class="badge ${isHome === 'HOME' ? 'lifecycle-active' : ''}">${isHome}</span>`}</td>
      `;
      tb.appendChild(tr);
    });
    body.appendChild(tbl);
  }

  // ---------- Blind spots ----------
  const BLIND_SPOT_MIN_MARKET_TIX = 50;
  const BLIND_SPOT_MAX_ROWS       = 20;

  function renderBlindSpots(portfolio) {
    const body = document.getElementById('phBlindSpotsBody');
    const countEl = document.getElementById('phBlindSpotsCount');
    const tabCount = document.getElementById('tabCountBlindspots');
    if (!body) return;
    body.innerHTML = '';
    if (!portfolio || portfolio.__err) {
      body.innerHTML = '<div class="empty">portfolio unavailable — cannot derive blind spots</div>';
      return;
    }
    const events = portfolio.events || [];
    const candidates = events.filter((e) => {
      const lifecycleActive = !e.lifecycle || e.lifecycle.is_active !== false;
      if (!lifecycleActive) return false;
      const owned = Number(e.owned_tickets_count || 0);
      const market = Number(e.tickets_count || 0);
      return owned === 0 && market > BLIND_SPOT_MIN_MARKET_TIX;
    });
    candidates.sort((a, b) => {
      const an = (Number(a.tickets_count) || 0) * (Number(a.retail_median) || 0);
      const bn = (Number(b.tickets_count) || 0) * (Number(b.retail_median) || 0);
      if (bn !== an) return bn - an;
      return (Number(b.tickets_count) || 0) - (Number(a.tickets_count) || 0);
    });
    const total = candidates.length;
    if (countEl) countEl.textContent = total
      ? `${total} blind spot${total === 1 ? '' : 's'} (showing top ${Math.min(total, BLIND_SPOT_MAX_ROWS)})`
      : '';
    if (tabCount) tabCount.textContent = total ? String(total) : '';
    if (!total) {
      body.innerHTML = '<div class="empty">no blind spots — we have inventory on every active upcoming game for this performer ✓</div>';
      return;
    }
    const tbl = document.createElement('table');
    tbl.innerHTML = `
      <thead><tr>
        <th>Event</th>
        <th>Venue</th>
        <th class="num">T-days</th>
        <th class="num">Mkt qty</th>
        <th class="num">Mkt median</th>
        <th class="num">Approx GMV</th>
      </tr></thead>
      <tbody></tbody>
    `;
    const tb = tbl.querySelector('tbody');
    candidates.slice(0, BLIND_SPOT_MAX_ROWS).forEach((e) => {
      const days = T.daysUntil(e.occurs_at_local);
      const qty = Number(e.tickets_count) || 0;
      const med = Number(e.retail_median) || 0;
      const gmv = qty * med;
      const tr = document.createElement('tr');
      tr.innerHTML = `
        <td><a href="event.html?event=${e.id}">${escapeHtml(e.name || ('Event ' + e.id))}</a></td>
        <td>${escapeHtml(e.venue_name || '—')}</td>
        <td class="num">${days === null ? '—' : days}</td>
        <td class="num">${T.fmtNum(qty)}</td>
        <td class="num">${med ? '$' + T.fmtNum(Math.round(med)) : '—'}</td>
        <td class="num">${gmv ? '$' + T.fmtNum(Math.round(gmv)) : '—'}</td>
      `;
      tb.appendChild(tr);
    });
    body.appendChild(tbl);
  }

  // ---------- Prediction markets (Kalshi/Polymarket) ----------
  // Panel below PORTFOLIO ROLLUP. Markets attributed to this performer (team):
  // its game moneylines (this panel) + season/champion futures (Futures tab),
  // from /api/broker/performer/{id}/prediction-markets.
  async function loadPerformerPredictionMarkets(performerId) {
    const d = await T.api(`/api/broker/performer/${performerId}/prediction-markets`).catch(() => null);
    renderPerformerPredictionMarkets(d);
  }

  function ppmPct(x) {
    const n = Number(x);
    return isFinite(n) ? (n * 100).toFixed(0) + '%' : '—';
  }
  function ppmRow(m) {
    const label = escapeHtml(m.subtitle || m.question || m.title || '');
    const date = m.event_date ? `<span class="pm-q muted small">${escapeHtml(String(m.event_date))}</span>` : '';
    const px = ppmPct(m.yes_price != null ? m.yes_price : m.last_price);
    const src = (m.source || '').toLowerCase();
    const srcLabel = src === 'kalshi' ? 'Kalshi' : src === 'polymarket' ? 'Polymarket' : escapeHtml(m.source || '?');
    const href = m.url ? ` href="${escapeHtml(m.url)}" target="_blank" rel="noopener noreferrer"` : '';
    return `<li class="pm-item"><a class="pm-link"${href}>` +
      `<span class="pm-side">${label}</span>${date}` +
      `<span class="pm-right"><span class="pm-prob">${px}</span>` +
      `<span class="pm-src pm-src-${escapeHtml(src)}">${srcLabel}</span></span></a></li>`;
  }
  function renderPerformerPredictionMarkets(d) {
    const section = document.getElementById('perf-prediction-markets');
    const body = document.getElementById('perfPmBody');
    const subtitle = document.getElementById('perfPmSubtitle');
    const markets = (d && Array.isArray(d.markets)) ? d.markets : [];
    // A market is a real "upcoming game" only if it's tagged game AND its date is
    // near-term. Some Polymarket season markets (win totals, division) carry a
    // gameStartTime that mislabels them market_type='game' with a season-far/past
    // date — those belong under Futures, not "Upcoming games".
    const nowMs = Date.now();
    const isUpcomingGame = (m) => {
      if (m.market_type !== 'game' || !m.event_date) return false;
      const t = new Date(m.event_date + 'T00:00:00Z').getTime();
      return isFinite(t) && (t - nowMs) > -2 * 864e5 && (t - nowMs) < 10 * 864e5;
    };
    const games = markets.filter(isUpcomingGame);
    const futures = markets.filter(m => !isUpcomingGame(m));
    // Futures now live on their own Futures tab (relocated from both this overview
    // panel and the individual event page). Render them there; this panel keeps
    // only upcoming-game moneylines.
    renderPerformerFutures(futures);
    if (!section || !body) return;
    if (!games.length) { section.hidden = true; return; }
    section.hidden = false;
    if (subtitle) {
      const srcs = Array.from(new Set(games.map(m => (m.source || '').toLowerCase()).filter(Boolean)));
      subtitle.textContent = srcs.length ? ('implied probability · ' + srcs.join(' + ')) : '';
    }
    let html = '';
    html += '<div class="pm-sublabel">UPCOMING GAMES — MONEYLINE</div>';
    html += '<ul class="pm-list">' + games.map(ppmRow).join('') + '</ul>';
    body.innerHTML = html;
  }

  // Futures tab — season/championship odds on this performer's team. Fed the
  // non-game bucket from the same prediction-markets pull as the overview panel.
  function renderPerformerFutures(futures) {
    const body = document.getElementById('perfFuturesBody');
    const meta = document.getElementById('perfFuturesMeta');
    const tabCount = document.getElementById('tabCountFutures');
    if (tabCount) tabCount.textContent = futures.length ? String(futures.length) : '';
    if (!body) return;
    if (!futures.length) {
      body.innerHTML = '<div class="empty">no season / championship futures for this performer</div>';
      if (meta) meta.textContent = '';
      return;
    }
    const srcs = Array.from(new Set(futures.map(m => (m.source || '').toLowerCase()).filter(Boolean)));
    if (meta) meta.textContent = srcs.length ? ('implied probability · ' + srcs.join(' + ')) : '';
    body.innerHTML = '<ul class="pm-list">' + futures.map(ppmRow).join('') + '</ul>';
  }

  // ---------- ESPN Context (lazy-loaded tab) ----------
  async function loadEspnContext(performerId) {
    const body = document.getElementById('phEspnContextBody');
    const meta = document.getElementById('phEspnContextMeta');
    if (body) body.innerHTML = '<div class="empty">loading ESPN context…</div>';
    if (meta) meta.textContent = 'loading…';
    const Auth = window.TerminalAuth;
    if (!Auth || !Auth.client || !Auth.getAccessToken()) {
      if (body) body.innerHTML = '<div class="empty">ESPN context needs auth — sign in with @s4kent.com</div>';
      if (meta) meta.textContent = '';
      return;
    }
    const t0 = performance.now();
    const res = await Auth.client.rpc('get_broker_performer_page', { p_performer_id: performerId });
    if (res.error) {
      if (body) body.innerHTML = `<div class="empty">RPC error: ${escapeHtml(res.error.message)}</div>`;
      if (meta) meta.textContent = 'error';
      return;
    }
    _tabState.loaded.espn = true;
    renderEspnContext(res.data || {}, performance.now() - t0);
    try { renderEspnSummary(res.data || {}); } catch (e) { console.error('espnSummary', e); }
  }

  function renderEspnContext(d, ms) {
    const body = document.getElementById('phEspnContextBody');
    const meta = document.getElementById('phEspnContextMeta');
    if (!body) return;
    if (d.hidden) {
      body.innerHTML = `<div class="empty">no ESPN xref for this performer (${escapeHtml(d.reason || 'hidden')})</div>`;
      if (meta) meta.textContent = '';
      return;
    }
    if (meta) meta.textContent = `${d.espn_league || ''} · team ${d.espn_team_id || ''} · ${ms.toFixed(0)}ms`;
    const standings = d.standings || null;
    const injuries  = d.injuries || [];
    const recent    = d.recent_results || [];
    const txns      = d.transactions || [];
    const att       = d.attendance || null;
    const leaders   = d.stat_leaders || [];
    const standingsHtml = !standings ? '<div class="empty">no standings snapshot</div>' : `
      <table class="espn-standings">
        <tbody>
          <tr><td class="lbl">RECORD</td><td>${standings.wins ?? '—'}-${standings.losses ?? '—'}${standings.ties ? '-' + standings.ties : ''}</td></tr>
          <tr><td class="lbl">WIN %</td><td>${standings.win_pct != null ? T.fmtPct(Number(standings.win_pct) * 100, 1) : '—'}</td></tr>
          <tr><td class="lbl">STREAK</td><td>${escapeHtml(standings.streak || '—')}</td></tr>
          <tr><td class="lbl">CONFERENCE RANK</td><td>${standings.conference_rank ?? '—'}</td></tr>
          <tr><td class="lbl">DIVISION RANK</td><td>${standings.division_rank ?? '—'}</td></tr>
          <tr><td class="lbl">PLAYOFF SEED</td><td>${standings.playoff_seed ?? '—'}</td></tr>
          <tr><td class="lbl">GAMES BACK</td><td>${standings.games_back ?? '—'}</td></tr>
          <tr><td class="lbl">SUMMARY</td><td class="muted">${escapeHtml(standings.standing_summary || standings.record_summary || '—')}</td></tr>
          <tr><td class="lbl">CAPTURED</td><td class="muted small">${T.fmtDate(standings.captured_at)}</td></tr>
        </tbody>
      </table>`;
    const injHtml = !injuries.length ? '<div class="empty">no current injury report</div>' : `
      <table class="espn-injuries">
        <thead><tr>
          <th>Athlete</th><th>Pos</th><th>Status</th><th>Injury</th><th>Return</th><th>Note</th>
        </tr></thead>
        <tbody>${injuries.map(i => `
          <tr>
            <td>${escapeHtml(i.athlete_name || '—')}</td>
            <td>${escapeHtml(i.position || '—')}</td>
            <td><span class="injury-status">${escapeHtml(i.status || '—')}</span></td>
            <td>${escapeHtml(i.injury_type || '—')}</td>
            <td>${i.return_date ? T.fmtDate(i.return_date) : '—'}</td>
            <td class="muted">${escapeHtml(i.short_comment || '')}</td>
          </tr>`).join('')}
        </tbody>
      </table>`;
    const recHtml = !recent.length ? '<div class="empty">no recent completed games</div>' : `
      <table class="espn-recent">
        <thead><tr>
          <th>When</th><th>vs</th><th>Score</th><th>Status</th>
        </tr></thead>
        <tbody>${recent.map(g => {
          const us = g.is_home ? g.home_score : g.away_score;
          const them = g.is_home ? g.away_score : g.home_score;
          return `
            <tr>
              <td class="muted">${T.fmtDate(g.captured_at)}</td>
              <td>${g.is_home ? 'vs' : '@'} <strong>${escapeHtml(g.opponent_team_id || '?')}</strong></td>
              <td class="num">${us ?? '—'} - ${them ?? '—'}</td>
              <td>${escapeHtml(g.status_short || '—')}</td>
            </tr>`;
        }).join('')}
        </tbody>
      </table>`;
    const txnHtml = !txns.length ? '<div class="empty">no recent transactions</div>' : `
      <table class="espn-recent">
        <thead><tr>
          <th>When</th><th>Move</th>
        </tr></thead>
        <tbody>${txns.map(t => `
          <tr>
            <td class="muted">${t.txn_date ? T.fmtDate(t.txn_date) : '—'}</td>
            <td>${escapeHtml(t.description || '—')}</td>
          </tr>`).join('')}
        </tbody>
      </table>`;
    const fmtN = n => (n == null ? '—' : Number(n).toLocaleString());
    const attHtml = !att ? '' : `
      <div class="espn-col-hdr" style="margin-top:10px">ATTENDANCE${att.season ? ' · ' + att.season : ''}</div>
      <table class="espn-standings">
        <tbody>
          <tr><td class="lbl">LEAGUE RANK</td><td>${att.rank != null ? '#' + att.rank : '—'}</td></tr>
          <tr><td class="lbl">HOME AVG</td><td>${fmtN(att.home_avg)}</td></tr>
          <tr><td class="lbl">HOME TOTAL</td><td>${fmtN(att.home_total)}</td></tr>
          ${att.home_pct ? `<tr><td class="lbl">CAPACITY</td><td>${att.home_pct}%</td></tr>` : ''}
          <tr><td class="lbl">CAPTURED</td><td class="muted small">${T.fmtDate(att.captured_at)}</td></tr>
        </tbody>
      </table>`;
    const ldrHtml = !leaders.length ? '<div class="empty">no player stats</div>' : `
      <table class="espn-recent">
        <thead><tr><th>Player</th><th>Pos</th><th>${escapeHtml(leaders[0].stat_label || 'STAT')}</th></tr></thead>
        <tbody>${leaders.map(p => `
          <tr>
            <td>${escapeHtml(p.athlete_name || '—')}</td>
            <td>${escapeHtml(p.position || '—')}</td>
            <td class="num">${escapeHtml(String(p.stat_display ?? '—'))}</td>
          </tr>`).join('')}
        </tbody>
      </table>`;
    body.innerHTML = `
      <div class="espn-grid">
        <div class="espn-col"><div class="espn-col-hdr">STANDINGS</div>${standingsHtml}${attHtml}</div>
        <div class="espn-col"><div class="espn-col-hdr">STAT LEADERS</div>${ldrHtml}</div>
        <div class="espn-col"><div class="espn-col-hdr">INJURY REPORT</div>${injHtml}</div>
        <div class="espn-col espn-col-wide"><div class="espn-col-hdr">RECENT — last 5</div>${recHtml}</div>
        <div class="espn-col espn-col-wide"><div class="espn-col-hdr">TRANSACTIONS</div>${txnHtml}</div>
      </div>`;
  }

  // ---------- ESPN summary strip (Overview — compact form + availability) ----------
  function renderEspnSummary(d) {
    const strip = document.getElementById('poEspnStrip');
    const sec   = document.getElementById('perf-espn-summary');
    const meta  = document.getElementById('poEspnMeta');
    if (!strip || !sec) return;
    if (!d || d.hidden) { sec.setAttribute('hidden', ''); return; }
    const s = d.standings || {};
    const inj = d.injuries || [];
    const cells = [];
    if (s.wins != null || s.losses != null) cells.push(['record', `${s.wins ?? '—'}-${s.losses ?? '—'}${s.ties ? '-' + s.ties : ''}`]);
    if (s.win_pct != null) cells.push(['win %', T.fmtPct(Number(s.win_pct) * 100, 1)]);
    if (s.streak) cells.push(['streak', String(s.streak)]);
    if (s.playoff_seed != null) cells.push(['seed', String(s.playoff_seed)]);
    else if (s.division_rank != null) cells.push(['div rank', String(s.division_rank)]);
    cells.push(['injuries', String(inj.length)]);
    strip.className = 'rollup-grid';
    strip.innerHTML = cells.map(c =>
      `<div class="ru-cell"><span class="ru-num">${escapeHtml(String(c[1]))}</span><span class="ru-lbl">${escapeHtml(c[0])}</span></div>`
    ).join('');
    if (meta) {
      const out = inj.slice(0, 3).map(i => escapeHtml(i.athlete_name || '')).filter(Boolean).join(', ');
      meta.textContent = [d.espn_league || '', out ? 'out: ' + out : ''].filter(Boolean).join(' · ');
    }
    sec.removeAttribute('hidden');
  }

  // ---------- Util ----------

  function setText(id, txt) {
    const el = document.getElementById(id);
    if (el) el.textContent = txt;
  }
  const escapeHtml = window.TermRender.escapeHtml;

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init);
  } else {
    init();
  }
})();

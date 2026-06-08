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
    if (countsEl) {
      const parts = ['NFL','NBA','MLB','MLS']
        .filter(l => counts[l])
        .map(l => `${l} ${counts[l]}`);
      if (counts.total) parts.push(`· ${counts.total} total`);
      countsEl.textContent = parts.join(' · ');
    }
    body.innerHTML = '';
    const grid = document.createElement('div');
    grid.className = 'entity-index-grid';
    ['NFL','NBA','MLB','MLS'].forEach(league => {
      const teams = leagues[league] || [];
      const col = document.createElement('div');
      col.className = 'entity-index-col';
      col.innerHTML = `<div class="entity-index-col-hdr">${league} <span class="muted small">(${teams.length})</span></div>`;
      const ul = document.createElement('ul');
      ul.className = 'entity-index-list';
      teams.forEach(t => {
        const li = document.createElement('li');
        const upcoming = t.events_count_next_90d != null ? `<span class="entity-idx-count">${t.events_count_next_90d}</span>` : '';
        li.innerHTML = `<a href="performer.html?performer=${t.tevo_performer_id}">
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

    Promise.all([
      T.api(`/api/broker/performer/${performerId}/assets`).catch(e => ({ __err: e })),
      T.api(`/api/portfolio?performer_id=${performerId}`).catch(e => ({ __err: e })),
    ]).then(([assets, portfolio]) => {
      const firstErr = [assets, portfolio].find(r => r && r.__err);
      if (firstErr) T.setStatus(firstErr.__err.message, 'err');
      else T.setStatus('Loaded', 'ok');
      // Stash portfolio
      _tabState.portfolio = (portfolio && !portfolio.__err) ? portfolio : null;
      try { renderHero(assets, portfolio); }      catch (e) { console.error('hero', e); }
      try { renderRollup(portfolio); }            catch (e) { console.error('rollup', e); }
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
    espn:       'paneEspn',
    alerts:     'panePerfAlerts',
  };

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
    runTripPlan(performerId);
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
  // Equirectangular projection with a cos(lat) longitude correction so the spread
  // looks geographically sane; plots home, every stop, and the optimizer's route.
  function _tripProjector(points, W, H, pad) {
    const lats = points.map(p => p.lat), lons = points.map(p => p.lon);
    const minLat = Math.min(...lats), maxLat = Math.max(...lats);
    const minLon = Math.min(...lons), maxLon = Math.max(...lons);
    const k = Math.cos(((minLat + maxLat) / 2) * Math.PI / 180) || 1;
    const minX = minLon * k, maxX = maxLon * k;
    const xr = (maxX - minX) || 1e-6, yr = (maxLat - minLat) || 1e-6;
    return (lat, lon) => [
      pad + (lon * k - minX) / xr * (W - 2 * pad),
      pad + (maxLat - lat) / yr * (H - 2 * pad),
    ];
  }

  function buildTripMap(d) {
    const W = 600, H = 340, pad = 42;
    const pts = [{ lat: +d.home.lat, lon: +d.home.lon }];
    (d.all_dates || []).forEach(e => pts.push({ lat: +e.lat, lon: +e.lon }));
    if (pts.length < 2) return '';
    const proj = _tripProjector(pts, W, H, pad);
    const [hx, hy] = proj(+d.home.lat, +d.home.lon);
    const going = d.optimal.events || [];
    const picked = new Set(going.map(e => e.event_id));

    const route = [[hx, hy], ...going.map(e => proj(+e.lat, +e.lon)), [hx, hy]];
    const routeD = route.map((p, i) => (i ? 'L' : 'M') + p[0].toFixed(1) + ' ' + p[1].toFixed(1)).join(' ');

    let dots = '';
    (d.all_dates || []).forEach(e => {
      const [x, y] = proj(+e.lat, +e.lon);
      const on = picked.has(e.event_id);
      dots += `<circle cx="${x.toFixed(1)}" cy="${y.toFixed(1)}" r="${on ? 5 : 3.5}" class="${on ? 'tm-go' : 'tm-skip'}">`
        + `<title>${escapeHtml((e.city || '') + ' · ' + (e.venue || '') + ' · ' + e.date)}</title></circle>`;
    });

    let labels = ''; const seen = new Set();
    going.forEach(e => {
      if (seen.has(e.city)) return;
      seen.add(e.city);
      const [x, y] = proj(+e.lat, +e.lon);
      labels += `<text x="${(x + 7).toFixed(1)}" y="${(y + 3).toFixed(1)}" class="tm-lbl">${escapeHtml(e.city || '')}</text>`;
    });

    const home = `<g class="tm-home"><circle cx="${hx.toFixed(1)}" cy="${hy.toFixed(1)}" r="5"/>`
      + `<text x="${(hx + 7).toFixed(1)}" y="${(hy + 3).toFixed(1)}" class="tm-lbl tm-home-lbl">${escapeHtml(d.home.name || 'Home')}</text></g>`;

    return `<svg viewBox="0 0 ${W} ${H}" class="trip-map-svg" preserveAspectRatio="xMidYMid meet" role="img" aria-label="Trip route map">`
      + `<path d="${routeD}" class="tm-route"/>${dots}${home}${labels}</svg>`;
  }

  function renderTripPlan(d) {
    const body = document.getElementById('tripBody');
    const stats = document.getElementById('tripStats');
    const mapEl = document.getElementById('tripMap');
    const meta = document.getElementById('tripMeta');
    if (meta) {
      const cov = d.coord_coverage || {};
      const extra = [];
      if (cov.city_fallback) extra.push(`${cov.city_fallback} ≈ city`);
      if (cov.dropped_no_coords) extra.push(`${cov.dropped_no_coords} no-coords dropped`);
      meta.textContent = d.tour_date_count
        ? `${d.tour_date_count} dates · budget ${Math.round(d.budget_km)} km${extra.length ? ' · ' + extra.join(', ') : ''}`
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
      stats.hidden = false;
      stats.innerHTML =
        `<div><span class="ts-num">${o.count}</span><span class="ts-lbl">optimal shows · ${Math.round(o.travel_km)} km</span></div>` +
        `<div><span class="ts-num">${b.count}</span><span class="ts-lbl">sort-by-date · ${Math.round(b.travel_km)} km</span></div>` +
        `<div><span class="ts-num gain">+${d.shows_gained}</span><span class="ts-lbl">shows gained</span></div>`;
    }
    const picked = new Set(o.events.map(e => e.event_id));
    const cities = [...new Set(o.events.map(e => e.city))].filter(Boolean).join(' → ');
    const rows = (d.all_dates || []).map(e => {
      const on = picked.has(e.event_id);
      const approx = e.coord_source === 'city' ? ' <span class="muted small" title="approximate city-centroid location">≈</span>' : '';
      return `<div class="trip-row${on ? '' : ' skip'}">`
        + `<span class="tr-date">${escapeHtml(_tripDate(e.date))}</span>`
        + `<span class="tr-city">${escapeHtml(e.city || '')}${approx}</span>`
        + `<span class="tr-venue">${escapeHtml(e.venue || '')}</span>`
        + (on ? '<span class="tr-go">● going</span>' : '')
        + '</div>';
    }).join('');
    body.innerHTML = (cities ? `<div class="muted small" style="margin:4px 0 8px">${escapeHtml(cities)}</div>` : '') + rows;
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
    body.innerHTML = `
      <div class="espn-grid">
        <div class="espn-col"><div class="espn-col-hdr">STANDINGS</div>${standingsHtml}</div>
        <div class="espn-col"><div class="espn-col-hdr">INJURY REPORT</div>${injHtml}</div>
        <div class="espn-col espn-col-wide"><div class="espn-col-hdr">RECENT — last 5</div>${recHtml}</div>
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

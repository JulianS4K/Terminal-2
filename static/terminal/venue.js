// D0 Terminal — Venue page (two modes).
//
// INDEX mode  (no ?venue in URL):   4-league venue directory from
//   get_broker_venue_index. Click a row → DETAIL mode.
// DETAIL mode (?venue=<id>):        hero + 4 tabs (Overview / Upcoming
//   Events / Owned Inventory / SG Activity). One Path C RPC call to
//   get_broker_venue_page returns all 4 tab payloads in one round-trip.
//
// Modeled on performer.js. Path C only — no Path A fallback.

(function () {
  'use strict';
  const T = window.Terminal;

  // State for lazy-loaded tabs
  const _vTabState = {
    marketLoaded:     false,
    competingLoaded:  false,
    venueEvents:      null,
    venueAggregate:   {},
    compRadius:       50,
    compWindow:       72,
    compEventId:      null,
  };

  function getVenueId() {
    const v = new URLSearchParams(location.search).get('venue');
    if (!v) return null;
    const n = parseInt(v, 10);
    return Number.isFinite(n) && n > 0 ? n : null;
  }

  async function init() {
    if (window.TerminalAuth) await window.TerminalAuth.requireAuth();
    const venueId = getVenueId();
    if (!venueId) return showIndexMode();
    return showDetailMode(venueId);
  }

  // ============================================================
  // INDEX mode — 4-league venue directory
  // ============================================================
  async function showIndexMode() {
    document.getElementById('venue-index').removeAttribute('hidden');
    T.setStatus('Loading venue index…');
    const Auth = window.TerminalAuth;
    if (!Auth || !Auth.client || !Auth.getAccessToken()) {
      document.getElementById('venueIndexBody').innerHTML =
        '<div class="empty">index needs auth — sign in with @s4kent.com</div>';
      T.setStatus('Auth required', 'err');
      return;
    }
    const res = await Auth.client.rpc('get_broker_venue_index');
    if (res.error) {
      T.setStatus(res.error.message, 'err');
      document.getElementById('venueIndexBody').innerHTML =
        `<div class="empty">RPC error: ${escapeHtml(res.error.message)}</div>`;
      return;
    }
    T.setStatus('Loaded', 'ok');
    renderIndex(res.data || {});
  }

  function renderIndex(d) {
    const body = document.getElementById('venueIndexBody');
    const countsEl = document.getElementById('venueIndexCounts');
    const counts = d.counts || {};
    const leagues = d.leagues || {};
    if (countsEl) {
      const parts = ['NFL','NBA','MLB','MLS']
        .filter(l => counts[l])
        .map(l => `${l} ${counts[l]}`);
      if (counts.total_distinct_venues) parts.push(`· ${counts.total_distinct_venues} distinct venues`);
      countsEl.textContent = parts.join(' · ');
    }
    body.innerHTML = '';
    const grid = document.createElement('div');
    grid.className = 'entity-index-grid';
    ['NFL','NBA','MLB','MLS'].forEach(league => {
      const venues = leagues[league] || [];
      const col = document.createElement('div');
      col.className = 'entity-index-col';
      col.innerHTML = `<div class="entity-index-col-hdr">${league} <span class="muted small">(${venues.length})</span></div>`;
      const ul = document.createElement('ul');
      ul.className = 'entity-index-list';
      venues.forEach(v => {
        const li = document.createElement('li');
        const location = [v.city, v.state].filter(Boolean).join(', ');
        const upcoming = v.events_count_next_90d != null ? `<span class="entity-idx-count">${v.events_count_next_90d}</span>` : '';
        li.innerHTML = `<a href="venue.html?venue=${v.tevo_venue_id}">
            <span class="entity-idx-name">${escapeHtml(v.venue_name || '—')}</span>
            ${location ? `<span class="muted small">${escapeHtml(location)}</span>` : ''}
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
  // DETAIL mode — hero + tabs (Market Carpet default)
  // ============================================================
  async function showDetailMode(venueId) {
    document.getElementById('venue-hero').removeAttribute('hidden');
    // Wire tabs early so nav works immediately (Market Carpet pane is already active in HTML)
    wireTabs();
    T.setStatus(`Loading venue ${venueId}…`);
    const Auth = window.TerminalAuth;
    if (!Auth || !Auth.client || !Auth.getAccessToken()) {
      T.setStatus('Auth required — sign in with @s4kent.com', 'err');
      return;
    }
    const res = await Auth.client.rpc('get_broker_venue_page', { p_venue_id: venueId });
    if (res.error) {
      T.setStatus(res.error.message, 'err');
      return;
    }
    T.setStatus('Loaded', 'ok');
    const d = res.data || {};
    if (d.hidden) {
      document.getElementById('vhName').textContent = 'venue not found';
      return;
    }
    safe('hero',   () => renderHero(d.venue));
    safe('rollup', () => renderRollup(d.aggregate));
    safe('events', () => renderEvents(d.events));
    safe('owned',  () => renderOwned(d.events, d.aggregate));
    safe('sg',     () => renderSg(d.sg_activity));
    // Stash events and auto-load Market Carpet (default view)
    _vTabState.venueEvents   = d.events || [];
    _vTabState.venueAggregate = d.aggregate || {};
    loadVenueMarketCarpet().catch(e => console.error('venueMarket', e));
  }

  function safe(label, fn) { try { fn(); } catch (e) { console.error('[' + label + ']', e); } }

  const VENUE_PANE_IDS = {
    overview:   'vPaneOverview',
    events:     'vPaneEvents',
    owned:      'vPaneOwned',
    sg:         'vPaneSg',
    competing:  'vPaneCompeting',
    market:     'vPaneMarket',
  };

  function wireTabs() {
    const nav = document.getElementById('venueTabs');
    if (!nav) return;
    // Guard against double-wiring
    if (nav.__wired) return;
    nav.__wired = true;
    nav.addEventListener('click', async (e) => {
      const btn = e.target.closest('.event-tab');
      if (!btn) return;
      const tabId = btn.dataset.tab;
      activateTab(tabId);
      if (tabId === 'market' && !_vTabState.marketLoaded) {
        await loadVenueMarketCarpet();
      }
      if (tabId === 'competing' && !_vTabState.competingLoaded) {
        initCompetingPanel();
      }
    });
    document.getElementById('venueTabs').removeAttribute('hidden');
  }

  function activateTab(tabId) {
    document.querySelectorAll('#venueTabs .event-tab').forEach(b => {
      const on = b.dataset.tab === tabId;
      b.classList.toggle('active', on);
      b.setAttribute('aria-selected', on ? 'true' : 'false');
    });
    Object.entries(VENUE_PANE_IDS).forEach(([id, paneId]) => {
      const pane = document.getElementById(paneId);
      if (!pane) return;
      if (id === tabId) { pane.removeAttribute('hidden'); pane.classList.add('active'); }
      else { pane.setAttribute('hidden', ''); pane.classList.remove('active'); }
    });
  }

  // ---------- Hero ----------
  function renderHero(v) {
    if (!v) return;
    setText('vhName', v.venue_name || 'Venue');
    setText('vhCity', [v.city, v.state, v.country].filter(Boolean).join(', ') || '—');
    setText('vhCapacity', v.capacity ? `cap ${T.fmtNum(v.capacity)}` : 'cap —');
    const indoorBadge = document.getElementById('vhIndoor');
    if (v.is_indoor === true) { indoorBadge.textContent = 'INDOOR'; indoorBadge.classList.add('lifecycle-active'); }
    else if (v.is_indoor === false) { indoorBadge.textContent = 'OUTDOOR'; indoorBadge.classList.add('lifecycle-ghost'); }
    else { indoorBadge.style.display = 'none'; }
    const mapsLink = document.getElementById('vhMapsLink');
    if (v.latitude && v.longitude) {
      mapsLink.href = `https://www.google.com/maps?q=${v.latitude},${v.longitude}`;
    } else {
      mapsLink.style.display = 'none';
    }
    const hero = document.getElementById('vhHero');
    if (v.hero_image_url) {
      hero.src = v.hero_image_url;
      hero.alt = (v.venue_name || 'venue') + ' photo';
    } else {
      hero.style.display = 'none';
    }
  }

  // ---------- Rollup ----------
  function renderRollup(ag) {
    if (!ag) return;
    setText('vrEvents',         T.fmtNum(ag.events_count));
    setText('vrPerformers',     T.fmtNum(ag.distinct_performers));
    setText('vrMarketTix',      T.fmtNum(ag.market_tickets_total));
    setText('vrOwnedTix',       T.fmtNum(ag.owned_tickets_total));
    setText('vrOwnedNotional',  ag.owned_notional ? '$' + T.fmtNum(Math.round(+ag.owned_notional)) : '—');
  }

  // ---------- Upcoming Events tab ----------
  async function renderEvents(events) {
    const body = document.getElementById('vEventsBody');
    const countEl = document.getElementById('vEventCount');
    const tabCount = document.getElementById('tabCountVenueEvents');
    if (!body) return;
    events = events || [];
    if (countEl) countEl.textContent = events.length ? `${events.length} events` : '';
    if (tabCount) tabCount.textContent = events.length ? String(events.length) : '';
    body.innerHTML = '';
    if (!events.length) {
      body.innerHTML = '<div class="empty">no upcoming events at this venue in the next 90d</div>';
      return;
    }
    // Phase 1b: ensure movers-index preload is done before row render so
    // T.moversChipHtml(e.id) can produce inline chips in the event-name cell.
    // Idempotent + cached.
    await T.moversPreloadIndex();
    const tbl = document.createElement('table');
    tbl.innerHTML = `
      <thead><tr>
        <th>Event</th><th>Performer</th><th class="num">T-days</th>
        <th class="num">Mkt qty</th><th class="num">Mkt median</th>
        <th class="num">Owned qty</th><th class="num">Owned med</th>
      </tr></thead><tbody></tbody>`;
    const tb = tbl.querySelector('tbody');
    events.forEach(e => {
      const d = T.daysUntil(e.occurs_at_local);
      const tr = document.createElement('tr');
      tr.innerHTML = `
        <td><a href="event.html?event=${e.id}">${escapeHtml(e.name || ('Event ' + e.id))}</a> ${T.moversChipHtml(e.id)} ${T.temporalChipHtml(e.occurs_at_local)}</td>
        <td>${escapeHtml(e.primary_performer_name || '—')}</td>
        <td class="num">${d === null ? '—' : d}</td>
        <td class="num">${T.fmtNum(e.tickets_count || 0)}</td>
        <td class="num">${e.retail_median ? '$' + T.fmtNum(Math.round(+e.retail_median)) : '—'}</td>
        <td class="num ${(e.owned_tickets_count || 0) > 0 ? 'ours' : ''}">${T.fmtNum(e.owned_tickets_count || 0)}</td>
        <td class="num">${e.owned_median_retail ? '$' + T.fmtNum(Math.round(+e.owned_median_retail)) : '—'}</td>`;
      tb.appendChild(tr);
    });
    body.appendChild(tbl);
  }

  // ---------- Owned Inventory tab ----------
  function renderOwned(events, agg) {
    const body = document.getElementById('vOwnedBody');
    if (!body) return;
    const owned = (events || []).filter(e => (+e.owned_tickets_count || 0) > 0);
    if (!owned.length) {
      body.innerHTML = '<div class="empty">no owned inventory at this venue</div>';
      return;
    }
    body.innerHTML = '';
    const summary = document.createElement('div');
    summary.className = 'venue-owned-summary';
    summary.innerHTML = `
      <div class="muted small">${owned.length} events with owned position · total ${T.fmtNum((agg && agg.owned_tickets_total) || 0)} tickets · notional ${agg && agg.owned_notional ? '$' + T.fmtNum(Math.round(+agg.owned_notional)) : '—'}</div>`;
    body.appendChild(summary);
    const tbl = document.createElement('table');
    tbl.innerHTML = `
      <thead><tr>
        <th>Event</th><th>Performer</th><th class="num">T-days</th>
        <th class="num">Owned qty</th><th class="num">Owned med</th><th class="num">Owned notional</th>
      </tr></thead><tbody></tbody>`;
    const tb = tbl.querySelector('tbody');
    owned.forEach(e => {
      const d = T.daysUntil(e.occurs_at_local);
      const ot = +e.owned_tickets_count || 0;
      const om = +e.owned_median_retail || 0;
      const notional = ot * om;
      const tr = document.createElement('tr');
      tr.innerHTML = `
        <td><a href="event.html?event=${e.id}">${escapeHtml(e.name || ('Event ' + e.id))}</a></td>
        <td>${escapeHtml(e.primary_performer_name || '—')}</td>
        <td class="num">${d === null ? '—' : d}</td>
        <td class="num ours">${T.fmtNum(ot)}</td>
        <td class="num">${om ? '$' + T.fmtNum(Math.round(om)) : '—'}</td>
        <td class="num">${notional ? '$' + T.fmtNum(Math.round(notional)) : '—'}</td>`;
      tb.appendChild(tr);
    });
    body.appendChild(tbl);
  }

  // ---------- SG Activity tab ----------
  function renderSg(sg) {
    const body = document.getElementById('vSgBody');
    const meta = document.getElementById('vSgMeta');
    if (!body) return;
    if (!sg || sg.sales_24h == null) {
      body.innerHTML = '<div class="empty">no SG sales data for this venue</div>';
      return;
    }
    if (meta) meta.textContent = `${sg.distinct_events_with_sales || 0} events with SG sales`;
    body.innerHTML = `
      <div class="kpi-strip">
        <div class="kpi-strip-cell"><span class="kpi-lbl">SALES 24H</span><span class="kpi-val">${T.fmtNum(sg.sales_24h)}</span></div>
        <div class="kpi-strip-cell"><span class="kpi-lbl">TIX 24H</span><span class="kpi-val">${T.fmtNum(sg.tickets_24h)}</span></div>
        <div class="kpi-strip-cell"><span class="kpi-lbl">GMV 24H</span><span class="kpi-val">${sg.gmv_24h ? '$' + T.fmtNum(Math.round(+sg.gmv_24h)) : '—'}</span></div>
        <div class="kpi-strip-cell"><span class="kpi-lbl">ACTIVE EVENTS</span><span class="kpi-val">${T.fmtNum(sg.distinct_events_with_sales)}</span></div>
      </div>`;
  }

  // ---------- Market Carpet — venue as stock ticker ----------
  // Auto-loaded on page open (default tab). Builds:
  //   1. Stock-ticker KPI strip: aggregate price, owned position, signals
  //   2. Per-event cross-source medians table
  async function loadVenueMarketCarpet() {
    _vTabState.marketLoaded = true;
    const tickerBody = document.getElementById('vMarketTickerBody');
    const body       = document.getElementById('vMarketBody');
    const meta       = document.getElementById('vMarketMeta');
    const countEl    = document.getElementById('tabCountVenueMarket');
    if (tickerBody) tickerBody.innerHTML = '<div class="empty">loading…</div>';
    if (body)       body.innerHTML       = '<div class="empty">Loading market data…</div>';

    const Auth = window.TerminalAuth;
    if (!Auth || !Auth.client || !Auth.getAccessToken()) {
      if (tickerBody) tickerBody.innerHTML = '<div class="empty">not signed in</div>';
      if (body)       body.innerHTML       = '<div class="empty">not signed in</div>';
      return;
    }
    const events = _vTabState.venueEvents || [];
    if (!events.length) {
      if (tickerBody) tickerBody.innerHTML = '<div class="empty">no events to analyze</div>';
      if (body)       body.innerHTML       = '<div class="empty">no events to analyze</div>';
      return;
    }
    const eventIds = events.map(e => e.id).filter(Boolean);

    // Parallel fetch: snapshots + movers + gaps
    const [snapRes, moversRes, gapsRes] = await Promise.all([
      Auth.client
        .from('event_listing_snapshot_daily')
        .select('event_id,snapshot_date,snapshot_slot,evo_retail_median,sg_all_median,td_sh_listings,td_sh_median,td_gt_listings,td_gt_median,td_vd_listings,td_vd_median,td_tp_listings,td_tp_median,td_tm_listings,td_tm_median,td_tm_resale_listings,td_tm_resale_median,td_combined_median')
        .in('event_id', eventIds)
        .order('snapshot_date', { ascending: false })
        .order('snapshot_slot', { ascending: false }),
      Auth.client
        .from('event_movers_index')
        .select('event_id,source,window_days,category,rank,price_delta_pct,signal_score')
        .in('event_id', eventIds)
        .order('signal_score', { ascending: false }),
      Auth.client
        .from('discovery_gap_alerts')
        .select('event_id,gap_type,detail,signal_score')
        .in('event_id', eventIds)
        .is('resolved_at', null),
    ]);

    // JS-dedup snapshots: keep first (latest) per event_id
    const snapByEvent = {};
    for (const r of (snapRes.data || [])) {
      if (!snapByEvent[r.event_id]) snapByEvent[r.event_id] = r;
    }

    // Group movers + gaps by event
    const moversByEvent = {};
    for (const r of (moversRes.data || [])) {
      (moversByEvent[r.event_id] = moversByEvent[r.event_id] || []).push(r);
    }
    const gapsByEvent = {};
    for (const r of (gapsRes.data || [])) {
      (gapsByEvent[r.event_id] = gapsByEvent[r.event_id] || []).push(r);
    }

    const snapCount = Object.keys(snapByEvent).length;
    if (meta)    meta.textContent    = `${events.length} events · ${snapCount} with snapshots`;
    if (countEl) countEl.textContent = String(events.length);

    // ── Stock Ticker: aggregate metrics ──────────────────────────────────────
    const ag = _vTabState.venueAggregate || {};
    let sumEvo = 0, sumSg = 0, sumSh = 0, sumGt = 0, sumVd = 0, sumTp = 0, sumTm = 0, wCount = 0;
    events.forEach(e => {
      const sn = snapByEvent[e.id];
      if (!sn) return;
      if (sn.evo_retail_median != null) sumEvo += +sn.evo_retail_median;
      if (sn.sg_all_median    != null) sumSg  += +sn.sg_all_median;
      if (sn.td_sh_median     != null) sumSh  += +sn.td_sh_median;
      if (sn.td_gt_median     != null) sumGt  += +sn.td_gt_median;
      if (sn.td_vd_median     != null) sumVd  += +sn.td_vd_median;
      if (sn.td_tp_median     != null) sumTp  += +sn.td_tp_median;
      if (sn.td_tm_median     != null) sumTm  += +sn.td_tm_median;
      wCount++;
    });
    const wavg = (sum) => wCount > 0 ? Math.round(sum / wCount) : null;
    const avgEvo = wavg(sumEvo), avgSg = wavg(sumSg);
    const avgSh  = wavg(sumSh),  avgGt = wavg(sumGt), avgVd = wavg(sumVd);
    const avgTp  = wavg(sumTp),  avgTm = wavg(sumTm);

    const allMovers = Object.values(moversByEvent).flat();
    const priceUp   = allMovers.filter(m => m.category === 'price_up').length;
    const priceDown = allMovers.filter(m => m.category === 'price_down').length;
    const allGaps   = Object.values(gapsByEvent).flat();
    const gapCount  = allGaps.length;

    const sgSpreadPct = (avgEvo && avgSg) ? ((avgSg - avgEvo) / avgEvo * 100) : null;
    const $p = v => (v != null ? '$' + T.fmtNum(v) : '—');

    if (tickerBody) {
      tickerBody.innerHTML = `
        <div class="market-ticker-strip">
          <div class="ticker-cell ticker-price">
            <span class="ticker-lbl">EVO MEDIAN</span>
            <span class="ticker-val">${$p(avgEvo)}</span>
            ${avgSg ? `<span class="ticker-sub ${sgSpreadPct && sgSpreadPct > 0 ? 'pos' : sgSpreadPct && sgSpreadPct < 0 ? 'neg' : ''}">${sgSpreadPct != null ? (sgSpreadPct >= 0 ? '+' : '') + sgSpreadPct.toFixed(1) + '% vs SG' : ''}</span>` : ''}
          </div>
          <div class="ticker-cell">
            <span class="ticker-lbl">PLATFORM MED</span>
            <span class="ticker-val">${$p(avgSg)}<span class="ticker-src"> SG</span></span>
            <span class="ticker-sub">${avgSh ? $p(avgSh) + ' SH' : '—'} · ${avgGt ? $p(avgGt) + ' GT' : '—'} · ${avgVd ? $p(avgVd) + ' VD' : '—'} · ${avgTp ? $p(avgTp) + ' TP' : '—'} · ${avgTm ? $p(avgTm) + ' TM' : '—'}</span>
          </div>
          <div class="ticker-cell">
            <span class="ticker-lbl">POSITION</span>
            <span class="ticker-val">${ag.owned_tickets_total ? T.fmtNum(ag.owned_tickets_total) + ' tix' : '—'}</span>
            <span class="ticker-sub">${ag.owned_notional ? '$' + T.fmtNum(Math.round(+ag.owned_notional)) + ' notional' : ''}</span>
          </div>
          <div class="ticker-cell">
            <span class="ticker-lbl">MARKET DEPTH</span>
            <span class="ticker-val">${events.length} events</span>
            <span class="ticker-sub">${ag.distinct_performers ? ag.distinct_performers + ' performers' : ''}</span>
          </div>
          <div class="ticker-cell">
            <span class="ticker-lbl">SIGNALS</span>
            <span class="ticker-val ${priceUp > priceDown ? 'pos' : priceDown > priceUp ? 'neg' : ''}">${priceUp > 0 ? '↑' + priceUp : ''}${priceDown > 0 ? ' ↓' + priceDown : ''}${!priceUp && !priceDown ? '—' : ''}</span>
            <span class="ticker-sub">${gapCount ? gapCount + ' gap' + (gapCount > 1 ? 's' : '') : 'no gaps'}</span>
          </div>
        </div>`;
    }

    // ── Per-event table ───────────────────────────────────────────────────────
    const spread = (a, b) => {
      if (a == null || b == null || +b === 0) return '';
      const v = ((+a - +b) / +b) * 100;
      return `<span class="${v > 2 ? 'pos' : v < -2 ? 'neg' : 'muted small'}">${v > 0 ? '+' : ''}${v.toFixed(0)}%</span>`;
    };

    const tbl = document.createElement('table');
    tbl.className = 'market-carpet-tbl';
    tbl.innerHTML = `
      <thead><tr>
        <th>Event</th>
        <th>Performer</th>
        <th class="num">T-days</th>
        <th class="num">EVO</th>
        <th class="num">SG</th>
        <th class="num">SH</th>
        <th class="num">GT</th>
        <th class="num">VD</th>
        <th class="num">TP</th>
        <th class="num">TM</th>
        <th class="num" title="Ticketmaster verified resale (secondary market)">TM-R</th>
        <th class="num">SH÷EVO</th>
        <th class="num">GT÷SH</th>
        <th class="num">VD÷SH</th>
        <th class="num" title="resale premium over TM primary face">TM-R÷TM</th>
        <th>Movers</th>
        <th>Gaps</th>
      </tr></thead><tbody></tbody>`;
    const tb = tbl.querySelector('tbody');

    events.forEach(e => {
      const sn  = snapByEvent[e.id]  || {};
      const mvs = moversByEvent[e.id] || [];
      const gps = gapsByEvent[e.id]  || [];
      const d   = T.daysUntil(e.occurs_at_local);
      const hasSn = !!snapByEvent[e.id];

      const moverHtml = mvs.slice(0, 3).map(m => {
        const mPct = m.price_delta_pct != null ? (m.price_delta_pct > 0 ? '+' : '') + (+m.price_delta_pct).toFixed(0) + '%' : '';
        const cls = m.category === 'price_up' ? 'pos' : m.category === 'price_down' ? 'neg' : 'muted small';
        return `<span class="badge ${cls}" title="${escapeHtml(m.source + ' ' + m.window_days + 'd')}">${escapeHtml(m.category.replace('_',' '))}${mPct ? ' ' + mPct : ''}</span>`;
      }).join(' ') || '—';

      const gapHtml = gps.slice(0, 4).map(g =>
        `<span class="badge" title="${escapeHtml(g.detail || '')}">${escapeHtml(g.gap_type.replace(/_/g,' '))}</span>`
      ).join(' ') || '—';

      const tr = document.createElement('tr');
      tr.className = hasSn ? '' : 'muted';
      tr.innerHTML = `
        <td><a href="event.html?event=${e.id}">${escapeHtml(e.name || ('Event ' + e.id))}</a></td>
        <td>${escapeHtml(e.primary_performer_name || '—')}</td>
        <td class="num">${d === null ? '—' : d}</td>
        <td class="num">${$p(sn.evo_retail_median)}</td>
        <td class="num">${$p(sn.sg_all_median)}</td>
        <td class="num">${$p(sn.td_sh_median)}</td>
        <td class="num">${$p(sn.td_gt_median)}</td>
        <td class="num">${$p(sn.td_vd_median)}</td>
        <td class="num">${$p(sn.td_tp_median)}</td>
        <td class="num">${$p(sn.td_tm_median)}</td>
        <td class="num">${$p(sn.td_tm_resale_median)}</td>
        <td class="num">${spread(sn.td_sh_median, sn.evo_retail_median)}</td>
        <td class="num">${spread(sn.td_gt_median, sn.td_sh_median)}</td>
        <td class="num">${spread(sn.td_vd_median, sn.td_sh_median)}</td>
        <td class="num">${spread(sn.td_tm_resale_median, sn.td_tm_median)}</td>
        <td>${moverHtml}</td>
        <td>${gapHtml}</td>`;
      tb.appendChild(tr);
    });

    if (body) { body.innerHTML = ''; body.appendChild(tbl); }
  }

  // ---------- Phase 12: Competing Events ----------
  //
  // find_competing_events(p_event_id, p_radius_miles, p_window_hours) queries
  // events + venue_assets (both @s4kent.com RLS-readable). Returns:
  //   competing_event_id, competing_event_name, competing_event_at,
  //   competing_venue, competing_city, competing_event_type,
  //   competing_performer, distance_miles, hours_offset

  function initCompetingPanel() {
    _vTabState.competingLoaded = true;
    const events = _vTabState.venueEvents || [];
    const sel = document.getElementById('vCompetingEventSel');
    if (!sel) return;

    // Populate anchor event dropdown from loaded venue events
    sel.innerHTML = '';
    if (!events.length) {
      sel.innerHTML = '<option value="">no upcoming events</option>';
    } else {
      events.slice(0, 20).forEach(e => {
        const d = T.daysUntil(e.occurs_at_local);
        const opt = document.createElement('option');
        opt.value = e.id;
        opt.textContent = (d !== null ? '+' + d + 'd · ' : '') +
          (e.name || ('Event ' + e.id));
        sel.appendChild(opt);
      });
    }
    // Default to first event
    if (sel.options.length > 0) {
      _vTabState.compEventId = +sel.options[0].value || null;
      loadCompetingEvents();
    }

    // Event selector change
    sel.addEventListener('change', () => {
      _vTabState.compEventId = +sel.value || null;
      loadCompetingEvents();
    });

    // Radius buttons
    document.querySelectorAll('[data-comp-radius]').forEach(btn => {
      btn.addEventListener('click', () => {
        document.querySelectorAll('[data-comp-radius]').forEach(b => b.classList.remove('is-active'));
        btn.classList.add('is-active');
        _vTabState.compRadius = +btn.dataset.compRadius;
        loadCompetingEvents();
      });
    });

    // Window buttons
    document.querySelectorAll('[data-comp-window]').forEach(btn => {
      btn.addEventListener('click', () => {
        document.querySelectorAll('[data-comp-window]').forEach(b => b.classList.remove('is-active'));
        btn.classList.add('is-active');
        _vTabState.compWindow = +btn.dataset.compWindow;
        loadCompetingEvents();
      });
    });
  }

  async function loadCompetingEvents() {
    const body    = document.getElementById('vCompetingBody');
    const countEl = document.getElementById('vCompetingCount');
    if (!body) return;
    const eventId = _vTabState.compEventId;
    if (!eventId) {
      body.innerHTML = '<div class="empty">select an anchor event above</div>';
      return;
    }
    body.innerHTML = '<div class="empty">loading…</div>';

    const Auth = window.TerminalAuth;
    if (!Auth || !Auth.client || !Auth.getAccessToken()) {
      body.innerHTML = '<div class="empty">not signed in</div>';
      return;
    }

    try {
      const res = await Auth.client.rpc('find_competing_events', {
        p_event_id:     eventId,
        p_radius_miles: _vTabState.compRadius,
        p_window_hours: _vTabState.compWindow,
      });
      if (res.error) throw new Error(res.error.message || 'RPC error');
      const rows = res.data || [];
      if (countEl) countEl.textContent = rows.length ? `${rows.length} events` : '';
      if (!rows.length) {
        body.innerHTML =
          `<div class="empty">no competing events within ${_vTabState.compRadius} mi ` +
          `and ±${_vTabState.compWindow}h of this event</div>`;
        return;
      }

      const tbl = document.createElement('table');
      tbl.className = 'competing-tbl';
      tbl.innerHTML = `
        <thead><tr>
          <th>Competing Event</th>
          <th>Venue</th>
          <th>City</th>
          <th class="num">Dist (mi)</th>
          <th class="num">Offset (h)</th>
          <th>Type</th>
          <th>Performer</th>
        </tr></thead>
        <tbody></tbody>`;
      const tb = tbl.querySelector('tbody');
      rows.forEach(r => {
        const tr = document.createElement('tr');
        const offsetAbs = Math.abs(+r.hours_offset || 0);
        const offsetCls = offsetAbs <= 4 ? 'warn-cell' : '';  // same-night conflicts
        tr.innerHTML = `
          <td><a href="event.html?event=${r.competing_event_id}">${escapeHtml(r.competing_event_name || ('Event ' + r.competing_event_id))}</a></td>
          <td>${escapeHtml(r.competing_venue || '—')}</td>
          <td>${escapeHtml(r.competing_city || '—')}</td>
          <td class="num">${r.distance_miles != null ? (+r.distance_miles).toFixed(1) : '—'}</td>
          <td class="num ${offsetCls}">${r.hours_offset != null ? (r.hours_offset >= 0 ? '+' : '') + (+r.hours_offset).toFixed(1) + 'h' : '—'}</td>
          <td class="muted small">${escapeHtml(r.competing_event_type || '—')}</td>
          <td class="muted small">${escapeHtml(r.competing_performer || '—')}</td>`;
        tb.appendChild(tr);
      });
      body.innerHTML = '';
      body.appendChild(tbl);
    } catch (e) {
      body.innerHTML = '<div class="empty">error: ' + escapeHtml(e.message) + '</div>';
      if (countEl) countEl.textContent = '';
    }
  }

  // ---------- Util ----------
  function setText(id, txt) { const el = document.getElementById(id); if (el) el.textContent = txt; }
  function escapeHtml(s) {
    if (s === null || s === undefined) return '';
    return String(s).replace(/[&<>"']/g, c => ({
      '&':'&amp;', '<':'&lt;', '>':'&gt;', '"':'&quot;', "'":'&#39;',
    }[c]));
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init);
  } else {
    init();
  }
})();

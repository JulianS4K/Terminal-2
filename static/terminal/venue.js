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
  // DETAIL mode — hero + rollup + 4 tabs
  // ============================================================
  async function showDetailMode(venueId) {
    document.getElementById('venue-hero').removeAttribute('hidden');
    document.getElementById('venueTabs').removeAttribute('hidden');
    document.getElementById('vPaneOverview').removeAttribute('hidden');
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
    safe('hero', () => renderHero(d.venue));
    safe('rollup', () => renderRollup(d.aggregate));
    safe('events', () => renderEvents(d.events));
    safe('owned', () => renderOwned(d.events, d.aggregate));
    safe('sg', () => renderSg(d.sg_activity));
  }

  function safe(label, fn) { try { fn(); } catch (e) { console.error('[' + label + ']', e); } }

  function wireTabs() {
    const nav = document.getElementById('venueTabs');
    if (!nav) return;
    nav.addEventListener('click', (e) => {
      const btn = e.target.closest('.event-tab');
      if (!btn) return;
      activateTab(btn.dataset.tab);
    });
  }

  function activateTab(tabId) {
    document.querySelectorAll('#venueTabs .event-tab').forEach(b => {
      const on = b.dataset.tab === tabId;
      b.classList.toggle('active', on);
      b.setAttribute('aria-selected', on ? 'true' : 'false');
    });
    const paneIds = {
      overview: 'vPaneOverview',
      events:   'vPaneEvents',
      owned:    'vPaneOwned',
      sg:       'vPaneSg',
    };
    Object.entries(paneIds).forEach(([id, paneId]) => {
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
  function renderEvents(events) {
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
        <td><a href="event.html?event=${e.id}">${escapeHtml(e.name || ('Event ' + e.id))}</a></td>
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

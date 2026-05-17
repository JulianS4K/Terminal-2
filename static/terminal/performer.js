// D0 Terminal — Performer detail page.
// URL: ?performer=<id>. Fetches /api/broker/performer/{id}/assets for the
// header + /api/portfolio?performer_id=<id> for the events list + rollup.
// Injuries / roster / news / xref deferred to the cross-source explorer page.

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
      T.setStatus('No performer id — pass ?performer=<id>', 'err');
      document.getElementById('phName').textContent = 'Pick a performer';
      document.getElementById('phEventsBody').innerHTML =
        '<div class="empty">Append <code>?performer=&lt;id&gt;</code> to the URL. Find performer ids via the Movers page (click a row) or via the <code>events</code> table.</div>';
      return;
    }
    T.setStatus(`Loading performer ${performerId}…`);

    Promise.all([
      T.api(`/api/broker/performer/${performerId}/assets`).catch(e => ({ __err: e })),
      T.api(`/api/portfolio?performer_id=${performerId}`).catch(e => ({ __err: e })),
    ]).then(([assets, portfolio]) => {
      const firstErr = [assets, portfolio].find(r => r && r.__err);
      if (firstErr) {
        T.setStatus(firstErr.__err.message, 'err');
      } else {
        T.setStatus(`Loaded`, 'ok');
      }
      try { renderHero(assets, portfolio); }      catch (e) { console.error('hero', e); }
      try { renderRollup(portfolio); }            catch (e) { console.error('rollup', e); }
      try { renderEvents(portfolio); }            catch (e) { console.error('events', e); }
      try { renderBlindSpots(portfolio); }        catch (e) { console.error('blindSpots', e); }
    });
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
    if (url) {
      logo.src = url;
      logo.alt = name + ' logo';
    } else {
      logo.style.display = 'none';
    }

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

  function renderEvents(portfolio) {
    const body = document.getElementById('phEventsBody');
    const countEl = document.getElementById('phEventCount');
    body.innerHTML = '';
    if (!portfolio || portfolio.__err) {
      body.innerHTML = '<div class="empty">portfolio unavailable</div>';
      return;
    }
    const events = portfolio.events || [];
    countEl.textContent = events.length ? `${events.length} events` : '';
    if (!events.length) {
      body.innerHTML = '<div class="empty">no upcoming events for this performer</div>';
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
        <td><a href="event.html?event=${e.id}">${escapeHtml(e.name || ('Event ' + e.id))}</a></td>
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

  // ---------- Blind spots — games we DON'T own ----------
  //
  // For each upcoming event under this performer where we hold zero
  // inventory AND the market has > MIN_MARKET_TIX tickets active, surface
  // the row sorted by approx market notional (qty × median). These are
  // games we could profitably enter — broker decision-support, no Phase
  // 2b/2c RPC needed (existing /api/portfolio events already carry
  // owned_tickets_count + tickets_count + retail_median per row).
  //
  // Aligns with the entity-level Blind Spots framing in Phase 2c E.1
  // (Snapshot/Motion/Coverage/Blind) — surfacing the "Coverage" gap at
  // the performer drill-down rather than waiting for the dedicated
  // /terminal/blind-spots page (Phase 2c proper, needs get_broker_
  // blind_spots RPC from A1).

  const BLIND_SPOT_MIN_MARKET_TIX = 50;
  const BLIND_SPOT_MAX_ROWS       = 20;

  function renderBlindSpots(portfolio) {
    const body = document.getElementById('phBlindSpotsBody');
    const countEl = document.getElementById('phBlindSpotsCount');
    if (!body) return;
    body.innerHTML = '';
    if (!portfolio || portfolio.__err) {
      body.innerHTML = '<div class="empty">portfolio unavailable — cannot derive blind spots</div>';
      return;
    }
    const events = portfolio.events || [];

    // Lifecycle gate first — speculative + ghost events surface elsewhere
    // already (and aren't real blind-spot candidates per consumer storefront
    // filter logic from PR #175). Then qty + ownership filter.
    const candidates = events.filter((e) => {
      const lifecycleActive = !e.lifecycle || e.lifecycle.is_active !== false;
      if (!lifecycleActive) return false;
      const owned = Number(e.owned_tickets_count || 0);
      const market = Number(e.tickets_count || 0);
      return owned === 0 && market > BLIND_SPOT_MIN_MARKET_TIX;
    });

    // Sort by approx market notional desc. Falls back to market qty when
    // retail_median missing (small event with no median yet → still surfaces).
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

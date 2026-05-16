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
      try { renderHero(assets, portfolio); } catch (e) { console.error('hero', e); }
      try { renderRollup(portfolio); }       catch (e) { console.error('rollup', e); }
      try { renderEvents(portfolio); }       catch (e) { console.error('events', e); }
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
        <td><a href="/static/terminal/event.html?event=${e.id}">${escapeHtml(e.name || ('Event ' + e.id))}</a></td>
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

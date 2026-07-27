// D0 Terminal — Paciolan / eVenue page. Browser twin of the AXS tab.
//
// Two surfaces, both backed by the service-role backend (the paciolan_* tables
// are RLS service-role-only, so — like AXS — the user-JWT client can't read
// them directly; it goes through T.api):
//
//   GET /api/paciolan/health  -> pull-loop health rollup (v_paciolan_pull_health)
//   GET /api/paciolan/events  -> URL layer, one row per captured event
//        (v_paciolan_events: latest snapshot + face band + AQ mapping + pull
//         status). ?active=true narrows to events the driver is still pulling.
//
// Paciolan/eVenue is a PRIMARY box office (not resale); collection is browser-
// extension-sourced (see paciolan_extension/) — this env can't reach evenue.net.

(function () {
  'use strict';
  const T = window.Terminal;

  const state = { active: false, hidePast: true, mappedOnly: false, filter: '' };
  let _rows = [];  // last fetched events, for client-side filtering

  function init() {
    wireControls();
    loadHealth().catch(e => console.error('[paciolan-health]', e));
    refreshEvents().catch(e => console.error('[paciolan]', e));
    setStatus('');
  }

  function setStatus(s) {
    const el = document.getElementById('status');
    if (el) el.textContent = s;
  }

  function wireControls() {
    // Auto-pulling toggle is server-side (re-fetch with ?active).
    document.querySelectorAll('[data-pac-active]').forEach(btn => {
      btn.addEventListener('click', () => {
        state.active = btn.dataset.pacActive === '1';
        document.querySelectorAll('[data-pac-active]').forEach(b => b.classList.remove('is-active'));
        btn.classList.add('is-active');
        refreshEvents();
      });
    });
    // Date + mapping + text filters are client-side over the fetched rows.
    document.querySelectorAll('[data-pac-past]').forEach(btn => {
      btn.addEventListener('click', () => {
        state.hidePast = btn.dataset.pacPast === '0';
        document.querySelectorAll('[data-pac-past]').forEach(b => b.classList.remove('is-active'));
        btn.classList.add('is-active');
        renderTable();
      });
    });
    document.querySelectorAll('[data-pac-mapped]').forEach(btn => {
      btn.addEventListener('click', () => {
        state.mappedOnly = btn.dataset.pacMapped === '1';
        document.querySelectorAll('[data-pac-mapped]').forEach(b => b.classList.remove('is-active'));
        btn.classList.add('is-active');
        renderTable();
      });
    });
    const filterEl = document.getElementById('pacFilter');
    if (filterEl) {
      let t = 0;
      filterEl.addEventListener('input', () => {
        clearTimeout(t);
        t = setTimeout(() => {
          state.filter = filterEl.value.trim().toLowerCase();
          renderTable();
        }, 150);
      });
    }
  }

  // ---------- health screen ----------
  async function loadHealth() {
    const body = document.getElementById('pacHealthCards');
    const when = document.getElementById('pacHealthWhen');
    if (!body) return;
    let h;
    try {
      h = await T.api('/api/paciolan/health');
    } catch (e) {
      body.innerHTML = '<div class="empty">error: ' + escapeHtml(e.message) + '</div>';
      return;
    }
    const n = v => T.fmtNum(v || 0);
    const errs = (h.error_24h || 0) + (h.expired_24h || 0);
    // badge classes: pos (green) for healthy, plain for neutral, muted for zero-ish
    const cards = [
      { lbl: 'Targets active', val: n(h.targets_active), cls: (h.targets_active > 0 ? 'pos' : 'muted') },
      { lbl: 'Captures', val: n(h.captures_total), cls: 'muted' },
      { lbl: 'Pending', val: n(h.pending), cls: (h.pending > 0 ? '' : 'muted') },
      { lbl: 'In-flight', val: n(h.inflight), cls: (h.inflight > 0 ? '' : 'muted') },
      { lbl: 'OK / 24h', val: n(h.ok_24h), cls: (h.ok_24h > 0 ? 'pos' : 'muted') },
      { lbl: 'Empty / 24h', val: n(h.empty_24h), cls: (h.empty_24h > 0 ? 'warn' : 'muted') },
      { lbl: 'Error / 24h', val: n(h.error_24h), cls: (h.error_24h > 0 ? 'neg' : 'muted') },
      { lbl: 'Expired / 24h', val: n(h.expired_24h), cls: (h.expired_24h > 0 ? 'neg' : 'muted') },
    ];
    body.innerHTML = cards.map(c =>
      `<div class="ctrl-group stat-card">
         <span class="ctrl-lbl">${escapeHtml(c.lbl)}</span>
         <span class="badge ${c.cls}">${c.val}</span>
       </div>`).join('');
    // Overall verdict + freshness line.
    if (when) {
      const last = h.last_resolved_at ? fmtDateTime(h.last_resolved_at) : 'never';
      const verdict = errs > 0 ? '🔴 errors in last 24h'
        : (h.ok_24h > 0 ? '🟢 healthy' : (h.targets_active > 0 ? '🟠 armed, no pulls yet' : '⚪ idle'));
      when.textContent = `${verdict} · last pull ${last}`;
    }
  }

  // ---------- events URL layer ----------
  async function refreshEvents() {
    const body    = document.getElementById('pacEventsBody');
    const countEl = document.getElementById('pacEventsCount');
    if (!body) return;
    body.innerHTML = '<div class="empty">loading…</div>';
    if (countEl) countEl.textContent = '';

    let data;
    try {
      data = await T.api(`/api/paciolan/events?active=${state.active ? 'true' : 'false'}`);
    } catch (e) {
      body.innerHTML = '<div class="empty">error: ' + escapeHtml(e.message) + '</div>';
      return;
    }

    _rows = (data && data.events) || [];
    const summaryEl = document.getElementById('pacEventsSummary');
    if (summaryEl) {
      summaryEl.innerHTML = _rows.length
        ? `<span class="badge">${data.count} captured</span> ` +
          `<span class="badge">${data.mapped} mapped → TEvo/EVO</span> ` +
          `<span class="badge pos">${data.pulling} auto-pulling</span> ` +
          (data.stale ? `<span class="badge neg">${data.stale} last pull failed</span>` : '')
        : '';
    }
    renderTable();
    // The health strip shares the queue — refresh it alongside a manual reload.
    loadHealth().catch(() => {});
  }

  function renderTable() {
    const body    = document.getElementById('pacEventsBody');
    const countEl = document.getElementById('pacEventsCount');
    if (!body) return;

    let rows = _rows;
    if (state.hidePast) rows = rows.filter(r => !isPast(r.occurs_at));
    if (state.mappedOnly) rows = rows.filter(r => r.mapped);
    if (state.filter) {
      rows = rows.filter(r =>
        (r.event_name || '').toLowerCase().includes(state.filter) ||
        (r.venue_name || '').toLowerCase().includes(state.filter) ||
        (r.tenant || '').toLowerCase().includes(state.filter) ||
        (r.event_code || '').toLowerCase().includes(state.filter));
    }

    // Sort: dated soonest-first, then undated by most-recent capture.
    rows = rows.slice().sort((a, b) => {
      const da = a.occurs_at ? Date.parse(a.occurs_at) : NaN;
      const db = b.occurs_at ? Date.parse(b.occurs_at) : NaN;
      const va = Number.isFinite(da), vb = Number.isFinite(db);
      if (va && vb) return da - db;
      if (va) return -1;
      if (vb) return 1;
      return (Date.parse(b.captured_at || 0) || 0) - (Date.parse(a.captured_at || 0) || 0);
    });

    if (countEl) {
      const total = _rows.length, shown = rows.length;
      countEl.textContent = total
        ? (shown === total ? `${total} event${total === 1 ? '' : 's'}`
                           : `${shown} of ${total} event${total === 1 ? '' : 's'}`)
        : '';
    }

    if (!rows.length) {
      body.innerHTML = _rows.length
        ? '<div class="empty">no events match the filter</div>'
        : '<div class="empty">no Paciolan events captured yet — scrape one with the extension</div>';
      return;
    }

    const tbl = document.createElement('table');
    tbl.className = 'full-list-tbl';
    tbl.innerHTML = `
      <thead><tr>
        <th>Event</th>
        <th>Venue</th>
        <th>Date</th>
        <th class="num" title="Cheapest available box-office face price">Face</th>
        <th class="num" title="Face price band (min–max)">Band</th>
        <th class="num" title="Available seats (latest capture)">Avail</th>
        <th class="num" title="Consecutive-seat blocks">Blk</th>
        <th title="Mapping to the canonical AQ hub → EVO/SeatGeek/StubHub">Map</th>
        <th title="Autonomous pull status">Pull</th>
        <th class="num" title="Last successful pull">Pulled</th>
        <th>Links</th>
      </tr></thead>
      <tbody></tbody>`;
    const tb = tbl.querySelector('tbody');

    rows.forEach(r => {
      const tr = document.createElement('tr');

      const name = r.event_name || `${escapeHtml(r.tenant || '?')} ${escapeHtml(r.event_code || '')}`;
      const nameCell = r.map_tevo_event_id
        ? `<a href="event.html?event=${r.map_tevo_event_id}">${escapeHtml(name)}</a>`
        : escapeHtml(name);
      const tenantChip = ` <span class="muted small">${escapeHtml(r.tenant || '')}</span>`;

      const band = (r.getin != null && r.price_max != null)
        ? `$${T.fmtNum(Math.round(r.getin))}–$${T.fmtNum(Math.round(r.price_max))}` : '—';

      // Mapping cell → EVO event link + confidence, or "unmapped".
      const mapCell = r.map_tevo_event_id
        ? `<a href="event.html?event=${r.map_tevo_event_id}" title="${escapeHtml(r.map_method || '')} ${r.map_confidence != null ? '(' + r.map_confidence + ')' : ''}">→ EVO ${r.map_tevo_event_id}</a>`
        : '<span class="badge muted" title="Not yet matched to a canonical TEvo event">unmapped</span>';

      // Pull status badge + live queue depth for this event.
      const st = r.last_status;
      const pullBadge = st
        ? `<span class="badge ${st === 'ok' ? 'pos' : (st === 'empty' ? 'warn' : 'neg')}"
             title="${escapeHtml(r.last_error || st)}">${escapeHtml(st)}</span>`
        : '<span class="muted small">—</span>';
      const depth = [];
      if (r.pending) depth.push(`${r.pending} queued`);
      if (r.inflight) depth.push(`${r.inflight} in-flight`);
      const pullCell = pullBadge + (depth.length ? ` <span class="muted small">${depth.join(' · ')}</span>` : '');

      const evHref = /^https?:\/\//i.test(r.source_url || '') ? r.source_url : null;
      const links = [];
      if (evHref) links.push(`<a href="${escapeHtml(evHref)}" target="_blank" rel="noopener">eVenue ↗</a>`);
      if (r.map_tevo_event_id) links.push(`<a href="event.html?event=${r.map_tevo_event_id}">EVENT</a>`);

      tr.innerHTML = `
        <td>${nameCell}${tenantChip}</td>
        <td>${escapeHtml(r.venue_name || '—')}</td>
        <td class="num">${r.occurs_at ? T.temporalChipHtml(r.occurs_at) : '<span class="muted small">—</span>'}</td>
        <td class="num">${r.getin != null ? '$' + T.fmtNum(Math.round(r.getin)) : '—'}</td>
        <td class="num muted small">${band}</td>
        <td class="num">${T.fmtNum(r.seats_available || 0)}</td>
        <td class="num">${T.fmtNum(r.blocks || 0)}</td>
        <td class="small">${mapCell}</td>
        <td class="small">${pullCell}</td>
        <td class="num muted small">${fmtDateShort(r.last_pulled_at)}</td>
        <td class="small">${links.join(' · ') || '—'}</td>`;
      tb.appendChild(tr);
    });

    body.replaceChildren(tbl);
  }

  // Past = a parseable event date strictly before the start of today (local).
  function isPast(iso) {
    if (!iso) return false;
    const t = Date.parse(iso);
    if (!Number.isFinite(t)) return false;
    const startOfToday = new Date();
    startOfToday.setHours(0, 0, 0, 0);
    return t < startOfToday.getTime();
  }

  function fmtDateShort(iso) {
    if (!iso) return '—';
    try {
      return new Date(iso).toLocaleDateString(undefined, {
        year: '2-digit', month: 'short', day: 'numeric',
      });
    } catch (_) { return '—'; }
  }
  function fmtDateTime(iso) {
    if (!iso) return '—';
    try {
      return new Date(iso).toLocaleString(undefined, {
        month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit',
      });
    } catch (_) { return '—'; }
  }

  const escapeHtml = window.TermRender.escapeHtml;

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init);
  } else {
    init();
  }
})();

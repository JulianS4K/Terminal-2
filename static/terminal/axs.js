// D0 Terminal — AXS Events page. Lists every event in the axs_events registry
// (AXS = PRIMARY box-office ticketer, not resale) enriched with its latest
// snapshot summary. Single panel, backed by the /api/axs/events route:
//
//   GET /api/axs/events?active=<0|1>
//     -> { count, linked, pulled, events: [ {axs_event_id, event_url,
//          tevo_event_id, linked, last_pulled_at, captured_at, event_name,
//          venue_name, occurs_at_local, currency, getin, price_min, price_max,
//          listings_count, sections_count, seats_primary, seats_resale,
//          onsale_now, ...} ] }
//
// The axs_* tables are RLS service-role-only, so unlike the Supabase-client
// panels (discovery/movers) this page goes through the backend (T.api) which
// holds the service-role client. Prices are already dollars (snapshot columns
// are normalized; the cents landmine is the raw payload only — CLAUDE §3).

(function () {
  'use strict';
  const T = window.Terminal;

  const state = { active: true, ownedOnly: false, filter: '' };
  let _rows = [];  // last fetched events, for client-side filtering

  function init() {
    wireControls();
    refreshAxsEvents().catch(e => console.error('[axs]', e));
    setStatus('');
  }

  function setStatus(s) {
    const el = document.getElementById('status');
    if (el) el.textContent = s;
  }

  function wireControls() {
    document.querySelectorAll('[data-axs-active]').forEach(btn => {
      btn.addEventListener('click', () => {
        state.active = btn.dataset.axsActive === '1';
        document.querySelectorAll('[data-axs-active]').forEach(b => b.classList.remove('is-active'));
        btn.classList.add('is-active');
        refreshAxsEvents();
      });
    });
    // Holdings filter is purely client-side over the already-fetched rows.
    document.querySelectorAll('[data-axs-owned]').forEach(btn => {
      btn.addEventListener('click', () => {
        state.ownedOnly = btn.dataset.axsOwned === '1';
        document.querySelectorAll('[data-axs-owned]').forEach(b => b.classList.remove('is-active'));
        btn.classList.add('is-active');
        renderTable();
      });
    });
    const filterEl = document.getElementById('axsFilter');
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

  async function refreshAxsEvents() {
    const body    = document.getElementById('axsEventsBody');
    const countEl = document.getElementById('axsEventsCount');
    if (!body) return;
    body.innerHTML = '<div class="empty">loading…</div>';
    if (countEl) countEl.textContent = '';

    let data;
    try {
      data = await T.api(`/api/axs/events?active=${state.active ? 'true' : 'false'}`);
    } catch (e) {
      body.innerHTML = '<div class="empty">error: ' + escapeHtml(e.message) + '</div>';
      return;
    }

    _rows = (data && data.events) || [];
    const summaryEl = document.getElementById('axsEventsSummary');
    if (summaryEl) {
      summaryEl.innerHTML = _rows.length
        ? `<span class="badge">${data.count} tracked</span> ` +
          `<span class="badge">${data.linked} mapped → TEvo</span> ` +
          `<span class="badge">${data.pulled} pulled</span> ` +
          `<span class="badge pos">${data.owned || 0} we hold tickets</span>`
        : '';
    }
    renderTable();
  }

  function renderTable() {
    const body    = document.getElementById('axsEventsBody');
    const countEl = document.getElementById('axsEventsCount');
    if (!body) return;

    let rows = _rows;
    if (state.ownedOnly) {
      rows = rows.filter(r => r.we_own);
    }
    if (state.filter) {
      rows = rows.filter(r =>
        (r.event_name || '').toLowerCase().includes(state.filter) ||
        (r.venue_name || '').toLowerCase().includes(state.filter) ||
        String(r.axs_event_id || '').toLowerCase().includes(state.filter));
    }

    // Sort: events with a known date first (soonest upcoming), then undated /
    // not-yet-pulled by most-recent pull.
    rows = rows.slice().sort((a, b) => {
      const da = a.occurs_at_local ? Date.parse(a.occurs_at_local) : NaN;
      const db = b.occurs_at_local ? Date.parse(b.occurs_at_local) : NaN;
      const va = Number.isFinite(da), vb = Number.isFinite(db);
      if (va && vb) return da - db;
      if (va) return -1;
      if (vb) return 1;
      return (Date.parse(b.last_pulled_at || 0) || 0) - (Date.parse(a.last_pulled_at || 0) || 0);
    });

    if (countEl) {
      const total = _rows.length;
      countEl.textContent = state.filter
        ? `${rows.length} of ${total} event${total === 1 ? '' : 's'}`
        : (total ? `${total} event${total === 1 ? '' : 's'}` : '');
    }

    if (!rows.length) {
      body.innerHTML = _rows.length
        ? '<div class="empty">no events match the filter</div>'
        : '<div class="empty">no AXS events tracked yet</div>';
      return;
    }

    const tbl = document.createElement('table');
    tbl.className = 'full-list-tbl';
    tbl.innerHTML = `
      <thead><tr>
        <th>Event</th>
        <th>Venue</th>
        <th>Date</th>
        <th class="num" title="Cheapest available primary box-office price">Get-in</th>
        <th class="num" title="Primary price band (min–max)">Price band</th>
        <th class="num" title="Total live listings">Listings</th>
        <th class="num" title="Sections with availability">Sec</th>
        <th class="num" title="Primary box-office seats">Prim</th>
        <th class="num" title="AXS Marketplace resale seats">Resale</th>
        <th class="num" title="Tickets WE hold for this event (S4K owned inventory, latest_event_metrics)">Owned</th>
        <th class="num" title="Last AXS pull">Pulled</th>
        <th>Links</th>
      </tr></thead>
      <tbody></tbody>`;
    const tb = tbl.querySelector('tbody');

    rows.forEach(r => {
      const tr = document.createElement('tr');
      const cur = curSymbol(r.currency);

      // Event name → terminal event page when mapped, else plain text.
      const name = r.event_name || `AXS ${escapeHtml(String(r.axs_event_id || '?'))}`;
      const nameCell = r.tevo_event_id
        ? `<a href="event.html?event=${r.tevo_event_id}">${escapeHtml(name)}</a>`
        : escapeHtml(name);
      const onsale = r.onsale_now ? ' <span class="badge pos" title="On sale now">on sale</span>' : '';
      const unmapped = r.tevo_event_id ? '' : ' <span class="badge muted" title="Not yet mapped to a canonical TEvo event">unmapped</span>';
      // We-hold-tickets flag: S4K owned inventory for the mapped TEvo event.
      const sharePct = (r.owned_share != null && Number.isFinite(+r.owned_share))
        ? ` · ${(+r.owned_share * 100).toFixed(0)}% of mkt` : '';
      const hold = r.we_own
        ? ` <span class="badge pos" title="We hold ${T.fmtNum(r.owned_tickets)} ticket(s)${sharePct}">HOLD</span>`
        : '';
      const ownedCell = r.we_own
        ? `<span class="pos">${T.fmtNum(r.owned_tickets)}</span>`
        : (r.linked ? '<span class="muted">0</span>' : '<span class="muted small">—</span>');

      const band = (r.price_min != null && r.price_max != null)
        ? `${cur}${T.fmtNum(Math.round(r.price_min))}–${cur}${T.fmtNum(Math.round(r.price_max))}`
        : '—';

      // External AXS listing link (scheme-validated) + terminal event link.
      const axsHref = /^https?:\/\//i.test(r.event_url || '') ? r.event_url : null;
      const links = [];
      if (axsHref) links.push(`<a href="${escapeHtml(axsHref)}" target="_blank" rel="noopener">AXS ↗</a>`);
      if (r.tevo_event_id) links.push(`<a href="event.html?event=${r.tevo_event_id}">EVENT</a>`);

      tr.innerHTML = `
        <td>${nameCell}${hold}${onsale}${unmapped}</td>
        <td>${escapeHtml(r.venue_name || '—')}</td>
        <td class="num">${r.occurs_at_local ? T.temporalChipHtml(r.occurs_at_local) : '<span class="muted small">—</span>'}</td>
        <td class="num">${r.getin != null ? cur + T.fmtNum(Math.round(r.getin)) : '—'}</td>
        <td class="num muted small">${band}</td>
        <td class="num">${T.fmtNum(r.listings_count)}</td>
        <td class="num">${T.fmtNum(r.sections_count)}</td>
        <td class="num">${T.fmtNum(r.seats_primary)}</td>
        <td class="num">${T.fmtNum(r.seats_resale)}</td>
        <td class="num">${ownedCell}</td>
        <td class="num muted small">${fmtDateShort(r.last_pulled_at)}</td>
        <td class="small">${links.join(' · ') || '—'}</td>`;
      tb.appendChild(tr);
    });

    body.replaceChildren(tbl);
  }

  function curSymbol(c) {
    if (!c || c === 'USD' || c === 'usd') return '$';
    if (c === 'CAD') return 'C$';
    if (c === 'GBP') return '£';
    if (c === 'EUR') return '€';
    return c + ' ';
  }

  function fmtDateShort(iso) {
    if (!iso) return '—';
    try {
      return new Date(iso).toLocaleDateString(undefined, {
        year: '2-digit', month: 'short', day: 'numeric',
      });
    } catch (_) { return '—'; }
  }

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

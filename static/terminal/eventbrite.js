// D0 Terminal — Eventbrite Events page. Lists every event discovered for the
// tracked Eventbrite organizer(s) via the TicketsData /events feed
// (td_discovered_events, platform='eventbrite'), enriched with the feed's face
// price band + sold-out / availability. Single panel, backed by the
// /api/eventbrite/events route:
//
//   GET /api/eventbrite/events?upcoming=<true|false>
//     -> { count, linked, on_sale, sold_out, events: [ {td_event_id, event_url,
//          event_name, event_date, venue_name, city, region, tevo_event_id,
//          linked, currency, price_min, price_max, is_free, sold_out,
//          has_tickets, waitlist, sales_status, event_status, age_restriction,
//          image_url, discovered_at} ] }
//
// td_discovered_events is RLS service-role-only, so — like the AXS panel — this
// page goes through the backend (T.api) which holds the service-role client.
// Eventbrite is a PRIMARY ticketer surfaced via discovery only (no seat-level
// /fetch pull yet); prices are the organizer's face band.

(function () {
  'use strict';
  const T = window.Terminal;

  const state = { hidePast: true, avail: 'all', filter: '' };
  let _rows = [];  // last fetched events, for client-side filtering

  function init() {
    wireControls();
    refreshEbEvents().catch(e => console.error('[eventbrite]', e));
    setStatus('');
  }

  function setStatus(s) {
    const el = document.getElementById('status');
    if (el) el.textContent = s;
  }

  function wireControls() {
    // Date filter (auto-hide past events) — purely client-side over fetched rows.
    document.querySelectorAll('[data-eb-past]').forEach(btn => {
      btn.addEventListener('click', () => {
        state.hidePast = btn.dataset.ebPast === '0';
        document.querySelectorAll('[data-eb-past]').forEach(b => b.classList.remove('is-active'));
        btn.classList.add('is-active');
        renderTable();
      });
    });
    // Availability filter — client-side over the already-fetched rows.
    document.querySelectorAll('[data-eb-avail]').forEach(btn => {
      btn.addEventListener('click', () => {
        state.avail = btn.dataset.ebAvail;
        document.querySelectorAll('[data-eb-avail]').forEach(b => b.classList.remove('is-active'));
        btn.classList.add('is-active');
        renderTable();
      });
    });
    const filterEl = document.getElementById('ebFilter');
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

  async function refreshEbEvents() {
    const body    = document.getElementById('ebEventsBody');
    const countEl = document.getElementById('ebEventsCount');
    if (!body) return;
    body.innerHTML = '<div class="empty">loading…</div>';
    if (countEl) countEl.textContent = '';

    let data;
    try {
      // Fetch the full set; date/availability filters are applied client-side.
      data = await T.api('/api/eventbrite/events?upcoming=false');
    } catch (e) {
      body.innerHTML = '<div class="empty">error: ' + escapeHtml(e.message) + '</div>';
      return;
    }

    _rows = (data && data.events) || [];
    const summaryEl = document.getElementById('ebEventsSummary');
    if (summaryEl) {
      summaryEl.innerHTML = _rows.length
        ? `<span class="badge">${data.count} discovered</span> ` +
          `<span class="badge pos">${data.on_sale || 0} on sale</span> ` +
          `<span class="badge muted">${data.sold_out || 0} sold out</span> ` +
          `<span class="badge">${data.linked || 0} mapped → TEvo</span>`
        : '';
    }
    renderTable();
  }

  function renderTable() {
    const body    = document.getElementById('ebEventsBody');
    const countEl = document.getElementById('ebEventsCount');
    if (!body) return;

    let rows = _rows;
    // Auto-hide events whose date is before today. Undated rows are kept.
    if (state.hidePast) {
      rows = rows.filter(r => !isPast(r.event_date));
    }
    if (state.avail === 'onsale') {
      rows = rows.filter(r => r.has_tickets && !r.sold_out);
    } else if (state.avail === 'soldout') {
      rows = rows.filter(r => r.sold_out);
    }
    if (state.filter) {
      rows = rows.filter(r =>
        (r.event_name || '').toLowerCase().includes(state.filter) ||
        (r.venue_name || '').toLowerCase().includes(state.filter) ||
        (r.city || '').toLowerCase().includes(state.filter));
    }

    // Sort: dated events soonest-first, undated last (by discovery recency).
    rows = rows.slice().sort((a, b) => {
      const da = a.event_date ? Date.parse(a.event_date) : NaN;
      const db = b.event_date ? Date.parse(b.event_date) : NaN;
      const va = Number.isFinite(da), vb = Number.isFinite(db);
      if (va && vb) return da - db;
      if (va) return -1;
      if (vb) return 1;
      return (Date.parse(b.discovered_at || 0) || 0) - (Date.parse(a.discovered_at || 0) || 0);
    });

    if (countEl) {
      const total = _rows.length;
      const shown = rows.length;
      countEl.textContent = total
        ? (shown === total
            ? `${total} event${total === 1 ? '' : 's'}`
            : `${shown} of ${total} event${total === 1 ? '' : 's'}`)
        : '';
    }

    if (!rows.length) {
      body.innerHTML = _rows.length
        ? '<div class="empty">no events match the filter</div>'
        : '<div class="empty">no Eventbrite events discovered yet</div>';
      return;
    }

    const tbl = document.createElement('table');
    tbl.className = 'full-list-tbl';
    tbl.innerHTML = `
      <thead><tr>
        <th>Event</th>
        <th>Venue</th>
        <th>City</th>
        <th>Date</th>
        <th class="num" title="Organizer face price band (min–max)">Price band</th>
        <th>Availability</th>
        <th class="num" title="Age restriction">Age</th>
        <th>Links</th>
      </tr></thead>
      <tbody></tbody>`;
    const tb = tbl.querySelector('tbody');

    rows.forEach(r => {
      const tr = document.createElement('tr');
      const cur = curSymbol(r.currency);

      // Event name → terminal event page. Mapped rows open the canonical TEvo
      // page; unmapped (primary-only) rows open the Eventbrite-source page
      // (event.html?eb=<td_event_id>) — a reduced primary-face view.
      const name = r.event_name || `Eventbrite ${escapeHtml(String(r.td_event_id || '?'))}`;
      // Source page only exists when we have a td_event_id to key it on; a row
      // without one (degenerate) stays plain text rather than a dead ?eb= link.
      const ebPage = r.td_event_id ? `event.html?eb=${encodeURIComponent(String(r.td_event_id))}` : null;
      const nameCell = r.tevo_event_id
        ? `<a href="event.html?event=${r.tevo_event_id}">${escapeHtml(name)}</a>`
        : (ebPage ? `<a href="${escapeHtml(ebPage)}">${escapeHtml(name)}</a>` : escapeHtml(name));
      const unmapped = r.tevo_event_id ? '' : ' <span class="badge muted" title="Primary-only — no canonical TEvo/secondary market; opens the Eventbrite-source page">primary-only</span>';

      // Price band. Free events flagged explicitly; otherwise min–max face.
      let band;
      if (r.is_free) {
        band = '<span class="pos">FREE</span>';
      } else if (r.price_min != null && r.price_max != null) {
        band = (Math.round(r.price_min) === Math.round(r.price_max))
          ? `${cur}${T.fmtNum(Math.round(r.price_min))}`
          : `${cur}${T.fmtNum(Math.round(r.price_min))}–${cur}${T.fmtNum(Math.round(r.price_max))}`;
      } else {
        band = '—';
      }

      // Availability badge from the feed's live flags.
      let avail;
      if (r.sold_out) {
        avail = r.waitlist
          ? '<span class="badge muted">sold out</span> <span class="badge">waitlist</span>'
          : '<span class="badge muted">sold out</span>';
      } else if (r.has_tickets) {
        avail = '<span class="badge pos">on sale</span>';
      } else if (r.sales_status === 'sales_ended') {
        avail = '<span class="badge muted">sales ended</span>';
      } else {
        avail = '<span class="muted small">—</span>';
      }

      // External Eventbrite listing link (scheme-validated) + terminal link.
      const ebHref = /^https?:\/\//i.test(r.event_url || '') ? r.event_url : null;
      const links = [];
      if (ebHref) links.push(`<a href="${escapeHtml(ebHref)}" target="_blank" rel="noopener">Eventbrite ↗</a>`);
      if (r.tevo_event_id) links.push(`<a href="event.html?event=${r.tevo_event_id}">EVENT</a>`);
      else if (ebPage) links.push(`<a href="${escapeHtml(ebPage)}">EVENT</a>`);

      tr.innerHTML = `
        <td>${nameCell}${unmapped}</td>
        <td>${escapeHtml(r.venue_name || '—')}</td>
        <td class="small">${escapeHtml([r.city, r.region].filter(Boolean).join(', ') || '—')}</td>
        <td class="num">${r.event_date ? T.temporalChipHtml(r.event_date) : '<span class="muted small">—</span>'}</td>
        <td class="num muted small">${band}</td>
        <td>${avail}</td>
        <td class="num muted small">${escapeHtml(r.age_restriction || '—')}</td>
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

  // Past = a parseable event date strictly before the start of today (local).
  // Undated rows (unparseable / null) are treated as not-past (kept).
  function isPast(iso) {
    if (!iso) return false;
    const t = Date.parse(iso);
    if (!Number.isFinite(t)) return false;
    const startOfToday = new Date();
    startOfToday.setHours(0, 0, 0, 0);
    return t < startOfToday.getTime();
  }

  const escapeHtml = window.TermRender.escapeHtml;

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init);
  } else {
    init();
  }
})();

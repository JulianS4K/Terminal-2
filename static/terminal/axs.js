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

  const state = { active: true, hidePast: true, ownedOnly: false, filter: '' };
  let _rows = [];  // last fetched events, for client-side filtering

  let _perfUnmatched = false;  // AXS performers panel: show only no-EVO-match acts

  function init() {
    wireControls();
    refreshAxsEvents().catch(e => console.error('[axs]', e));
    loadAxsPerformers().catch(e => console.error('[axs-perf]', e));
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
    // Date filter (auto-hide past events) — purely client-side over fetched rows.
    document.querySelectorAll('[data-axs-past]').forEach(btn => {
      btn.addEventListener('click', () => {
        state.hidePast = btn.dataset.axsPast === '0';
        document.querySelectorAll('[data-axs-past]').forEach(b => b.classList.remove('is-active'));
        btn.classList.add('is-active');
        renderTable();
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
    // AXS performers panel toggle (All artists / AXS-only).
    document.querySelectorAll('[data-axsp-unmatched]').forEach(btn => {
      btn.addEventListener('click', () => {
        _perfUnmatched = btn.dataset.axspUnmatched === '1';
        document.querySelectorAll('[data-axsp-unmatched]').forEach(b => b.classList.remove('is-active'));
        btn.classList.add('is-active');
        loadAxsPerformers().catch(e => console.error('[axs-perf]', e));
      });
    });
  }

  // ---------- AXS performers panel ----------
  // Direct Path-C RPC (get_axs_stat_cards is SECDEF @s4kent-gated, granted to
  // authenticated — so the user-JWT client can read it even though the
  // underlying axs_performer_stat_card table is RLS-locked).
  async function loadAxsPerformers() {
    const body    = document.getElementById('axsPerfBody');
    const countEl = document.getElementById('axsPerfCount');
    if (!body) return;
    const Auth = window.TerminalAuth;
    if (!Auth || !Auth.client || !Auth.getAccessToken()) {
      body.innerHTML = '<div class="empty">AXS performers need auth — sign in with @s4kent.com</div>';
      return;
    }
    body.innerHTML = '<div class="empty">loading…</div>';
    const res = await Auth.client.rpc('get_axs_stat_cards', { p_limit: 400, p_only_unmatched: _perfUnmatched });
    if (res.error) {
      body.innerHTML = `<div class="empty">RPC error: ${escapeHtml(res.error.message)}</div>`;
      return;
    }
    const rows = res.data || [];
    if (countEl) countEl.textContent = rows.length ? `${rows.length} artist${rows.length === 1 ? '' : 's'}` : '';
    renderAxsPerformers(rows);
  }

  function renderAxsPerformers(rows) {
    const body = document.getElementById('axsPerfBody');
    if (!body) return;
    if (!rows.length) {
      body.innerHTML = `<div class="empty">${_perfUnmatched ? 'no AXS-only artists' : 'no AXS performers matched yet'}</div>`;
      return;
    }
    const usd = v => (v != null && isFinite(v)) ? '$' + T.fmtNum(Math.round(v)) : '—';
    const trs = rows.map(r => {
      const evo = r.tevo_performer_id
        ? `<a href="performer.html?performer=${r.tevo_performer_id}">→ EVO ${r.tevo_performer_id}</a>`
        : '<span class="muted">AXS-only</span>';
      return `<tr>
        <td>${escapeHtml(r.axs_performer || '(unknown)')}</td>
        <td>${evo}</td>
        <td class="num">${T.fmtNum(r.event_count || 0)}</td>
        <td class="num">${usd(r.getin_min)}</td>
        <td class="num">${usd(r.getin_median)}</td>
        <td class="num">${T.fmtNum(r.listings_total || 0)}</td>
        <td class="num">${T.fmtNum(r.seats_primary_total || 0)}</td>
        <td class="num">${T.fmtNum(r.seats_resale_total || 0)}</td>
      </tr>`;
    }).join('');
    const tbl = document.createElement('table');
    tbl.className = 'full-list-tbl';
    tbl.innerHTML = `
      <thead><tr>
        <th>Performer</th>
        <th title="Canonical EVO/TEvo performer this AXS artist bridges to">EVO match</th>
        <th class="num" title="AXS events tracked for this artist">Events</th>
        <th class="num" title="Cheapest AXS get-in across the artist's events">Get-in</th>
        <th class="num" title="Median AXS get-in">Median</th>
        <th class="num" title="Total live AXS listings">Listings</th>
        <th class="num" title="Primary box-office seats">Prim</th>
        <th class="num" title="AXS Marketplace resale seats">Resale</th>
      </tr></thead>`;
    const tb = document.createElement('tbody');
    tb.innerHTML = trs;
    tbl.appendChild(tb);
    body.innerHTML = '';
    body.appendChild(tbl);
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
    // Auto-hide events whose date is before today. Undated rows (no parseable
    // occurs_at_local — never-pulled / no date returned) are kept: unknown ≠ past.
    if (state.hidePast) {
      rows = rows.filter(r => !isPast(r.occurs_at_local));
    }
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

  // Past = a parseable event date strictly before the start of today (local).
  // Times-of-day are ignored so everything happening TODAY stays visible, and
  // undated rows (unparseable / null) are treated as not-past (kept).
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

  const escapeHtml = window.TermRender.escapeHtml;

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init);
  } else {
    init();
  }
})();

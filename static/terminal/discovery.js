// D0 Terminal — Discovery page (TEvo blindspot + returning entities).
// Companion to movers.js; both consume Supabase RPCs through TerminalAuth.
//
// Two panels:
//   1. BLIND SPOTS — TEvo SELLING, WE'RE NOT
//      RPC: get_blind_spots_tevo_selling(min_conf, horizon, limit, venue, mode, band)
//      Backed by mig 20260519180000. 3-signal composite over broker pool
//      where we own 0 tickets, big 5 sports excluded. Confidence-sorted.
//   2. RETURNING — performers + venues back after dormancy
//      RPC: get_returning_entities(min_gap_days, source, entity_type, limit)
//      Backed by mig 20260519200000. TEvo perf+venue + SG venue today;
//      SG performer link deferred to v2.

(function () {
  'use strict';
  const T = window.Terminal;

  // ---- State shared across both panels (filter UI -> RPC params) ----
  const tevoState = { mode: 'selling', band: '', conf: 0.5 };
  const retState  = { gap: 90, source: '', entityType: '' };

  function init() {
    wireTevoControls();
    wireReturningControls();
    refreshTevoBlindSpots().catch(e => console.error('[tevo-blindspots]', e));
    refreshReturning().catch(e => console.error('[returning]', e));
    setStatus('');
  }

  function setStatus(s) {
    const el = document.getElementById('status');
    if (el) el.textContent = s;
  }

  // -------- TEvo blindspot panel ---------------------------------

  function wireTevoControls() {
    document.querySelectorAll('[data-tevo-mode]').forEach(btn => {
      btn.addEventListener('click', () => {
        tevoState.mode = btn.dataset.tevoMode;
        toggleActive(btn, '[data-tevo-mode]');
        refreshTevoBlindSpots();
      });
    });
    document.querySelectorAll('[data-tevo-band]').forEach(btn => {
      btn.addEventListener('click', () => {
        tevoState.band = btn.dataset.tevoBand || '';
        toggleActive(btn, '[data-tevo-band]');
        refreshTevoBlindSpots();
      });
    });
    document.querySelectorAll('[data-tevo-conf]').forEach(btn => {
      btn.addEventListener('click', () => {
        tevoState.conf = Number(btn.dataset.tevoConf);
        toggleActive(btn, '[data-tevo-conf]');
        refreshTevoBlindSpots();
      });
    });
  }

  async function refreshTevoBlindSpots() {
    const body = document.getElementById('tevoBlindSpotsBody');
    const countEl = document.getElementById('tevoBlindSpotsCount');
    if (!body) return;

    const Auth = window.TerminalAuth;
    if (!Auth || !Auth.client || !Auth.getAccessToken()) {
      body.innerHTML = '<div class="empty">not signed in</div>';
      return;
    }

    body.innerHTML = '<div class="empty">loading…</div>';

    let rows;
    try {
      const res = await Auth.client.rpc('get_blind_spots_tevo_selling', {
        p_min_confidence: tevoState.conf,
        p_horizon_days:   365,
        p_limit:          25,
        p_venue_pattern:  null,
        p_mode:           tevoState.mode,
        p_band:           tevoState.band || null,
      });
      if (res.error) throw new Error(res.error.message || 'RPC error');
      rows = res.data || [];
    } catch (e) {
      body.innerHTML = '<div class="empty">error: ' + escapeHtml(e.message) + '</div>';
      if (countEl) countEl.textContent = '';
      return;
    }

    const n = rows.length;
    if (countEl) countEl.textContent = n ? `${n} event${n === 1 ? '' : 's'}` : '';

    if (!n) {
      body.innerHTML =
        '<div class="empty">no signals at confidence &ge; ' + tevoState.conf +
        ' (mode: ' + tevoState.mode +
        (tevoState.band ? ', band: ' + tevoState.band : '') + ')</div>';
      return;
    }

    const tbl = document.createElement('table');
    tbl.className = 'blind-spots-tbl';
    tbl.innerHTML = `
      <thead><tr>
        <th>Event</th><th>Venue</th>
        <th class="num">T-days</th>
        <th class="num" title="Confidence: avg of fired-signal strengths, 0..1">Conf</th>
        <th class="num">Listed</th>
        <th class="num" title="24h listings delta">d24h</th>
        <th class="num" title="24h listings delta %">L Δ%</th>
        <th class="num" title="24h get-in % change">P Δ%</th>
        <th class="num" title="Parking-aware get-in">Get-in</th>
        <th>Signals</th>
      </tr></thead>
      <tbody></tbody>`;
    const tb = tbl.querySelector('tbody');

    rows.forEach(r => {
      const tr = document.createElement('tr');
      const eventLabel = r.tevo_event_id
        ? `<a href="event.html?event=${r.tevo_event_id}">${escapeHtml(r.event_name || ('TEvo ' + r.tevo_event_id))}</a>`
        : escapeHtml(r.event_name || ('TEvo ' + r.tevo_event_id));

      const sigParts = [];
      if (r.signal_listings_drop)  sigParts.push('drop');
      if (r.signal_listings_spike) sigParts.push('spike');
      if (r.signal_price_rise)     sigParts.push('rise');
      const sigText = sigParts.join(' · ') || '—';

      tr.innerHTML = `
        <td>${eventLabel}</td>
        <td>${escapeHtml(r.venue_name || '')} <span class="muted small">${escapeHtml(r.venue_location || '')}</span></td>
        <td class="num">${T.daysUntil(r.occurs_at_local) ?? '—'}</td>
        <td class="num">${fmtConf(r.confidence_score)}</td>
        <td class="num">${T.fmtNum(r.tickets_count)}</td>
        <td class="num">${T.fmtNum(r.tevo_tix_d24h)}</td>
        <td class="num">${T.fmtPct(r.tevo_tix_d24h_pct)}</td>
        <td class="num">${T.fmtPct(r.tevo_getin_d24h_pct)}</td>
        <td class="num">$${T.fmtNum(r.getin_no_parking)}</td>
        <td>${escapeHtml(sigText)}</td>`;
      tb.appendChild(tr);
    });

    body.replaceChildren(tbl);
  }

  // -------- Returning-entities panel -----------------------------

  function wireReturningControls() {
    document.querySelectorAll('[data-ret-gap]').forEach(btn => {
      btn.addEventListener('click', () => {
        retState.gap = Number(btn.dataset.retGap);
        toggleActive(btn, '[data-ret-gap]');
        refreshReturning();
      });
    });
    document.querySelectorAll('[data-ret-source]').forEach(btn => {
      btn.addEventListener('click', () => {
        retState.source = btn.dataset.retSource || '';
        toggleActive(btn, '[data-ret-source]');
        refreshReturning();
      });
    });
    document.querySelectorAll('[data-ret-type]').forEach(btn => {
      btn.addEventListener('click', () => {
        retState.entityType = btn.dataset.retType || '';
        toggleActive(btn, '[data-ret-type]');
        refreshReturning();
      });
    });
  }

  async function refreshReturning() {
    const body = document.getElementById('returningBody');
    const countEl = document.getElementById('returningCount');
    if (!body) return;

    const Auth = window.TerminalAuth;
    if (!Auth || !Auth.client || !Auth.getAccessToken()) {
      body.innerHTML = '<div class="empty">not signed in</div>';
      return;
    }

    body.innerHTML = '<div class="empty">loading…</div>';

    let rows;
    try {
      const res = await Auth.client.rpc('get_returning_entities', {
        p_min_gap_days: retState.gap,
        p_source:       retState.source || null,
        p_entity_type:  retState.entityType || null,
        p_limit:        50,
      });
      if (res.error) throw new Error(res.error.message || 'RPC error');
      rows = res.data || [];
    } catch (e) {
      body.innerHTML = '<div class="empty">error: ' + escapeHtml(e.message) + '</div>';
      if (countEl) countEl.textContent = '';
      return;
    }

    const n = rows.length;
    if (countEl) countEl.textContent = n ? `${n} entit${n === 1 ? 'y' : 'ies'}` : '';

    if (!n) {
      body.innerHTML =
        '<div class="empty">no returning entities at gap &ge; ' + retState.gap + ' days</div>';
      return;
    }

    const tbl = document.createElement('table');
    tbl.className = 'blind-spots-tbl';
    tbl.innerHTML = `
      <thead><tr>
        <th>Entity</th>
        <th>Type</th>
        <th>Source</th>
        <th>Location</th>
        <th class="num">Last seen</th>
        <th class="num">Next event</th>
        <th class="num" title="Days between last past event and next upcoming">Gap</th>
        <th class="num">Upcoming</th>
        <th class="num">Past</th>
      </tr></thead>
      <tbody></tbody>`;
    const tb = tbl.querySelector('tbody');

    rows.forEach(r => {
      const tr = document.createElement('tr');
      let nameCell;
      if (r.source === 'tevo' && r.entity_type === 'performer') {
        nameCell = `<a href="performer.html?performer=${escapeHtml(r.entity_id)}">${escapeHtml(r.entity_name || '')}</a>`;
      } else if (r.source === 'tevo' && r.entity_type === 'venue') {
        nameCell = `<a href="venue.html?venue=${escapeHtml(r.entity_id)}">${escapeHtml(r.entity_name || '')}</a>`;
      } else {
        // SG venue + future SG performer — no terminal drill page yet
        nameCell = escapeHtml(r.entity_name || '');
      }
      tr.innerHTML = `
        <td>${nameCell}</td>
        <td>${escapeHtml(r.entity_type)}</td>
        <td>${escapeHtml(r.source)}</td>
        <td>${escapeHtml(r.entity_location || '')}</td>
        <td class="num">${escapeHtml(fmtDateShort(r.latest_past_at))}</td>
        <td class="num">${escapeHtml(fmtDateShort(r.earliest_future_at))}</td>
        <td class="num">${T.fmtNum(r.gap_days)}d</td>
        <td class="num">${T.fmtNum(r.upcoming_count)}</td>
        <td class="num">${T.fmtNum(r.past_count)}</td>`;
      tb.appendChild(tr);
    });

    body.replaceChildren(tbl);
  }

  // -------- shared helpers ---------------------------------------

  function toggleActive(btn, selector) {
    document.querySelectorAll(selector).forEach(b => b.classList.remove('is-active'));
    btn.classList.add('is-active');
  }

  function fmtConf(v) {
    if (v === null || v === undefined) return '—';
    return Number(v).toFixed(2);
  }

  function fmtDateShort(iso) {
    if (!iso) return '';
    try {
      return new Date(iso).toLocaleDateString(undefined, {
        year: '2-digit', month: 'short', day: 'numeric',
      });
    } catch (_) { return ''; }
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

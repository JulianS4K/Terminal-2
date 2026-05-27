// D0 Terminal — Discovery page (gaps + TEvo blindspot + returning entities).
// Companion to movers.js; all panels consume Supabase RPCs/tables via TerminalAuth.
//
// Three panels:
//   1. DISCOVERY GAPS — cross-platform alert table
//      Table: discovery_gap_alerts (resolved_at IS NULL)
//      Backed by mig 20260527250000. Gap types: sg_no_evo, td_*_no_evo,
//      td_gt/vd_premium, evo_no_sg, value_gap_large, fill_rate_spike.
//      Populated by evo_sg_discovery_gaps() cron daily at 9am UTC.
//   2. BLIND SPOTS — TEvo SELLING, WE'RE NOT
//      RPC: get_blind_spots_tevo_selling(min_conf, horizon, limit, venue, mode, band)
//      Backed by mig 20260519180000. 3-signal composite over broker pool
//      where we own 0 tickets, big 5 sports excluded. Confidence-sorted.
//   3. RETURNING — performers + venues back after dormancy
//      RPC: get_returning_entities(min_gap_days, source, entity_type, limit)
//      Backed by mig 20260519200000. TEvo perf+venue + SG venue today;
//      SG performer link deferred to v2.

(function () {
  'use strict';
  const T = window.Terminal;

  // ---- State shared across both panels (filter UI -> RPC params) ----
  const tevoState = { mode: 'selling', band: '', conf: 0.5 };
  const retState  = { gap: 90, source: '', entityType: '' };
  const gapState  = { type: '' }; // '' = all gap types

  function init() {
    wireGapControls();
    wireTevoControls();
    wireReturningControls();
    refreshDiscoveryGaps().catch(e => console.error('[discovery-gaps]', e));
    refreshTevoBlindSpots().catch(e => console.error('[tevo-blindspots]', e));
    refreshReturning().catch(e => console.error('[returning]', e));
    setStatus('');
  }

  function setStatus(s) {
    const el = document.getElementById('status');
    if (el) el.textContent = s;
  }

  // -------- Discovery Gaps panel --------------------------------
  // Queries discovery_gap_alerts (resolved_at IS NULL) via Supabase client.
  // Groups by gap_type, enriches with event names from sg_events_canonical.
  // Populated by evo_sg_discovery_gaps() cron (mig 250000, daily 9am UTC).

  function wireGapControls() {
    document.querySelectorAll('[data-gap-type]').forEach(btn => {
      btn.addEventListener('click', () => {
        gapState.type = btn.dataset.gapType || '';
        toggleActive(btn, '[data-gap-type]');
        refreshDiscoveryGaps();
      });
    });
  }

  async function refreshDiscoveryGaps() {
    const body      = document.getElementById('discoveryGapsBody');
    const summaryEl = document.getElementById('discoveryGapsSummary');
    const countEl   = document.getElementById('discoveryGapsCount');
    if (!body) return;

    const Auth = window.TerminalAuth;
    if (!Auth || !Auth.client || !Auth.getAccessToken()) {
      body.innerHTML = '<div class="empty">not signed in</div>';
      return;
    }
    body.innerHTML = '<div class="empty">loading…</div>';

    try {
      // Fetch active gaps (optional type filter)
      let q = Auth.client
        .from('discovery_gap_alerts')
        .select('id,event_id,gap_type,detail,signal_score,detected_at')
        .is('resolved_at', null)
        .order('signal_score', { ascending: false })
        .limit(200);
      if (gapState.type) q = q.eq('gap_type', gapState.type);

      const gapsRes = await q;
      if (gapsRes.error) throw new Error(gapsRes.error.message);
      const gaps = gapsRes.data || [];

      // Enrich with event names from sg_events_canonical
      const eventIds = [...new Set(gaps.map(g => g.event_id).filter(Boolean))];
      const eventMeta = {};
      if (eventIds.length) {
        const metaRes = await Auth.client
          .from('sg_events_canonical')
          .select('tevo_event_id,sg_event_name,sg_datetime_utc')
          .in('tevo_event_id', eventIds);
        if (!metaRes.error) {
          (metaRes.data || []).forEach(e => { eventMeta[e.tevo_event_id] = e; });
        }
      }

      // Counts
      const total = gaps.length;
      const distinctEvents = new Set(gaps.map(g => g.event_id)).size;
      if (countEl) countEl.textContent = total ? `${total} gaps · ${distinctEvents} events` : '';

      // Summary chips by type
      const byType = {};
      gaps.forEach(g => { byType[g.gap_type] = (byType[g.gap_type] || 0) + 1; });
      if (summaryEl) {
        summaryEl.innerHTML = Object.entries(byType).length
          ? Object.entries(byType)
              .sort((a, b) => b[1] - a[1])
              .map(([t, n]) => `<span class="badge">${escapeHtml(t.replace(/_/g,' '))} ${n}</span>`)
              .join(' ')
          : '';
      }

      if (!total) {
        body.innerHTML = '<div class="empty">no active discovery gap alerts — cron runs daily at 9am UTC</div>';
        return;
      }

      // Group by gap_type and render
      const groups = {};
      gaps.forEach(g => { (groups[g.gap_type] = groups[g.gap_type] || []).push(g); });

      // Priority sort order for gap types
      const GAP_PRIORITY = [
        'value_gap_large', 'fill_rate_spike',
        'sg_no_evo', 'td_sh_no_evo', 'td_gt_no_evo', 'td_vd_no_evo',
        'td_gt_premium', 'td_vd_premium', 'td_sh_no_gt', 'evo_no_sg',
      ];
      const sortedTypes = Object.keys(groups).sort((a, b) => {
        const ia = GAP_PRIORITY.indexOf(a), ib = GAP_PRIORITY.indexOf(b);
        if (ia === -1 && ib === -1) return a.localeCompare(b);
        if (ia === -1) return 1;
        if (ib === -1) return -1;
        return ia - ib;
      });

      body.innerHTML = '';
      sortedTypes.forEach(gapType => {
        const items = groups[gapType];
        const section = document.createElement('div');
        section.className = 'v2-category-section';

        const hdr = document.createElement('div');
        hdr.className = 'panel-title row';
        hdr.innerHTML = `<span>${escapeHtml(gapType.toUpperCase().replace(/_/g,' '))} <span class="tab-count">${items.length}</span></span>`;
        section.appendChild(hdr);

        const tbl = document.createElement('table');
        tbl.className = 'discovery-gaps-tbl';
        tbl.innerHTML = `
          <thead><tr>
            <th>Event</th>
            <th class="num">T-days</th>
            <th class="num">Score</th>
            <th>Detail</th>
            <th class="num">Detected</th>
          </tr></thead><tbody></tbody>`;
        const tb = tbl.querySelector('tbody');

        items.forEach(g => {
          const meta     = eventMeta[g.event_id] || {};
          const eventName = meta.sg_event_name || ('Event ' + g.event_id);
          const eventLink = g.event_id
            ? `<a href="event.html?event=${g.event_id}">${escapeHtml(eventName)}</a>`
            : escapeHtml(eventName);
          const daysUntil = meta.sg_datetime_utc ? (T.daysUntil(meta.sg_datetime_utc) ?? '—') : '—';

          const tr = document.createElement('tr');
          tr.innerHTML = `
            <td>${eventLink}</td>
            <td class="num">${daysUntil}</td>
            <td class="num">${g.signal_score != null ? (+g.signal_score).toFixed(2) : '—'}</td>
            <td class="muted small">${escapeHtml(g.detail || '')}</td>
            <td class="num muted small">${fmtDateShort(g.detected_at)}</td>`;
          tb.appendChild(tr);
        });

        section.appendChild(tbl);
        body.appendChild(section);
      });

    } catch (e) {
      body.innerHTML = '<div class="empty">error: ' + escapeHtml(e.message) + '</div>';
      if (countEl) countEl.textContent = '';
    }
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

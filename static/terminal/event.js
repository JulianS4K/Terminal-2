// D0 Terminal — Event Detail page.
// Parallel-fetches 5 endpoints, renders hero / KPI / chart / zones / order strip.

(function () {
  'use strict';

  const T = window.Terminal;

  async function init() {
    if (window.TerminalAuth) await window.TerminalAuth.requireAuth();
    const eventId = T.getEventId();
    if (!eventId) {
      T.setStatus('No event id — pass ?event=<id>', 'err');
      return;
    }
    T.setStatus(`Loading event ${eventId}…`);

    Promise.all([
      T.api(`/api/broker/event/${eventId}/overview`).catch(e => ({ __err: e })),
      T.api(`/api/broker/event/${eventId}/chart-data?range=7d`).catch(e => ({ __err: e })),
      T.api(`/api/broker/event/${eventId}/zones`).catch(e => ({ __err: e })),
      T.api(`/api/broker/event/${eventId}/orders`).catch(e => ({ __err: e })),
      T.api(`/api/broker/event/${eventId}/cadences`).catch(e => ({ __err: e })),
    ]).then(([overview, chart, zones, orders, cadences]) => {
      // Surface first hard error if any.
      const firstErr = [overview, chart, zones, orders, cadences].find(r => r && r.__err);
      if (firstErr) {
        T.setStatus(firstErr.__err.message, 'err');
        // Still try to render whichever sections we got.
      } else {
        T.setStatus(`Loaded event ${eventId}`, 'ok');
      }

      try { renderHero(overview); } catch (e) { console.error('hero', e); }
      try { renderKPI(chart);      } catch (e) { console.error('kpi', e); }
      try { renderChart(chart);    } catch (e) { console.error('chart', e); }
      try { renderZones(zones);    } catch (e) { console.error('zones', e); }
      try { renderOrders(orders);  } catch (e) { console.error('orders', e); }
      try { renderCoverage(cadences, overview); } catch (e) { console.error('coverage', e); }
    });
  }

  // ---------- Hero ----------

  function renderHero(overview) {
    if (!overview || overview.__err) return;
    const ev = overview.event || {};
    document.getElementById('evTitle').textContent = ev.name || `Event ${ev.id || ''}`;
    document.getElementById('evVenue').textContent = ev.venue_name || ev.venue || '—';
    document.getElementById('evDate').textContent  = T.fmtDate(ev.occurs_at_local || ev.occurs_at);

    const badges = document.getElementById('evBadges');
    badges.innerHTML = '';

    const days = T.daysUntil(ev.occurs_at_local || ev.occurs_at);
    if (days !== null) {
      const b = document.createElement('span');
      b.className = 'badge countdown';
      b.textContent = days <= 0 ? 'TODAY' : days === 1 ? 'TOMORROW' : `T-${days}d`;
      badges.appendChild(b);
    }

    const lc = overview.lifecycle;
    if (lc) {
      const status = lc.status || lc.classification;
      if (status) {
        const b = document.createElement('span');
        const cls = (/active|live|on_sale/i.test(status)) ? 'lifecycle-active'
                  : (/ghost|postponed|cancelled/i.test(status)) ? 'lifecycle-ghost'
                  : (/complete|past/i.test(status)) ? 'lifecycle-complete'
                  : '';
        b.className = 'badge ' + cls;
        b.textContent = String(status).toUpperCase();
        badges.appendChild(b);
      }
    }

    if (overview.cadence_seconds) {
      const b = document.createElement('span');
      b.className = 'badge';
      const m = Math.round(overview.cadence_seconds / 60);
      b.textContent = `POLL ${m}m`;
      badges.appendChild(b);
    }
  }

  // ---------- KPI: owned_premium_pct (computed client-side) ----------

  function renderKPI(chart) {
    const valEl = document.getElementById('kpiVal');
    const subEl = document.getElementById('kpiSub');
    if (!chart || chart.__err) {
      valEl.textContent = '—';
      subEl.textContent = chart && chart.__err ? 'chart-data unavailable' : '';
      return;
    }
    const owned    = T.latestNonNull(chart.prices_owned);
    const nonowned = T.latestNonNull(chart.prices_nonowned);

    if (!owned || !nonowned) {
      valEl.textContent = 'n/a';
      valEl.className = 'kpi-value';
      subEl.textContent = !nonowned
        ? 'no nonowned median yet (we\'re alone in event)'
        : 'no owned median yet';
      return;
    }
    const pct = (owned / nonowned - 1) * 100;
    valEl.textContent = T.fmtPct(pct, 1);
    valEl.className = 'kpi-value ' + colorBucket(pct);
    subEl.textContent = `our $${T.fmtNum(owned, { max: 0 })} vs market $${T.fmtNum(nonowned, { max: 0 })}`;
  }

  // Sweet spot ±15 green, ±15-30 amber, beyond red.
  function colorBucket(pct) {
    const a = Math.abs(pct);
    if (a <= 15) return 'pos';
    if (a <= 30) return 'warn';
    return 'neg';
  }

  // ---------- Chart (uPlot) ----------

  function renderChart(chart) {
    const host = document.getElementById('chartHost');
    host.innerHTML = '';
    if (!chart || chart.__err || !window.uPlot) return;

    // Build a unified time axis from the union of timestamps across the
    // three series we care about. event_metrics rows are usually aligned
    // (they come from the same captured_at), so the union typically equals
    // any individual series.
    const series = [chart.prices_owned, chart.prices_market, chart.counts_owned];
    const tset = new Set();
    series.forEach(s => (s || []).forEach(p => tset.add(p.t)));
    const ts = [...tset].sort();
    const idx = new Map(ts.map((t, i) => [t, i]));

    function project(s) {
      const arr = new Array(ts.length).fill(null);
      (s || []).forEach(p => { arr[idx.get(p.t)] = p.v; });
      return arr;
    }
    const xs = ts.map(t => Math.round(new Date(t).getTime() / 1000));
    const data = [
      xs,
      project(chart.prices_owned),
      project(chart.prices_market),
      project(chart.counts_owned),
    ];

    const rect = host.getBoundingClientRect();
    const opts = {
      width: Math.max(800, rect.width || host.clientWidth || 1200),
      height: Math.max(280, (rect.height || 320) - 20),
      cursor: { drag: { x: true, y: false } },
      scales: {
        x: { time: true },
        y: {},
        qty: {},
      },
      axes: [
        { stroke: 'var(--muted)', grid: { stroke: 'var(--line-2)', width: 1 } },
        { scale: 'y',   stroke: 'var(--muted)', grid: { stroke: 'var(--line-2)', width: 1 },
          values: (u, v) => v.map(x => '$' + (x === null ? '' : Math.round(x))) },
        { scale: 'qty', side: 1, stroke: 'var(--muted)', grid: { show: false },
          values: (u, v) => v.map(x => x === null ? '' : Math.round(x)) },
      ],
      series: [
        { label: 'time' },
        { label: 'Owned median', stroke: '#fbbf24', width: 2,   scale: 'y',   spanGaps: true },
        { label: 'Market median', stroke: '#737373', width: 1.5, scale: 'y',   spanGaps: true, dash: [4, 4] },
        { label: 'Owned qty',     stroke: '#60a5fa', width: 1,   scale: 'qty', spanGaps: true, fill: 'rgba(96,165,250,0.08)' },
      ],
    };

    new window.uPlot(opts, data, host);

    // Resize on window resize.
    if (!host.__resizeWired) {
      host.__resizeWired = true;
      window.addEventListener('resize', () => renderChart(chart));
    }
  }

  // ---------- Zones table ----------

  function renderZones(zones) {
    const body = document.getElementById('zonesBody');
    body.innerHTML = '';
    if (!zones || zones.__err) {
      body.innerHTML = '<div class="empty">zones unavailable</div>';
      return;
    }
    const rows = zones.zones || [];
    if (!rows.length) {
      body.innerHTML = '<div class="empty">no zone data</div>';
      return;
    }

    const tbl = document.createElement('table');
    tbl.innerHTML = `
      <thead><tr>
        <th>Zone</th>
        <th class="num">Qty</th>
        <th class="num">Median</th>
        <th class="num">Ours qty</th>
        <th class="num">Ours %</th>
      </tr></thead>
      <tbody></tbody>
    `;
    const tb = tbl.querySelector('tbody');
    rows.slice(0, 30).forEach(r => {
      const tr = document.createElement('tr');
      const ourPct = (r.owned_share !== null && r.owned_share !== undefined)
        ? T.fmtPct(r.owned_share * 100, 0) : '—';
      tr.innerHTML = `
        <td class="zone-name">${escapeHtml(r.zone || '—')}</td>
        <td class="num">${T.fmtNum(r.tickets_count)}</td>
        <td class="num">$${T.fmtNum(r.retail_median, { max: 0 })}</td>
        <td class="num ours">${T.fmtNum(r.owned_tickets_count)}</td>
        <td class="num ours">${ourPct}</td>
      `;
      tb.appendChild(tr);
    });
    body.appendChild(tbl);

    if (zones.source) {
      const note = document.createElement('div');
      note.className = 'panel-title';
      note.style.marginTop = '8px';
      note.style.color = 'var(--dim)';
      note.textContent = `source: ${zones.source}` + (zones.parking_hidden ? ` · ${zones.parking_hidden} parking hidden` : '');
      body.appendChild(note);
    }
  }

  // ---------- Orders strip ----------

  function renderOrders(orders) {
    const body = document.getElementById('ordersBody');
    body.innerHTML = '';
    if (!orders || orders.__err) {
      body.innerHTML = '<div class="empty">orders unavailable</div>';
      return;
    }
    if (!orders.summary || orders.summary.total_items === 0) {
      body.innerHTML = '<div class="empty">no orders for this event</div>';
      return;
    }

    const byState = orders.summary.by_state || {};
    const total = orders.summary.total_items || 1;
    const stateOrder = ['pending', 'accepted', 'completed', 'rejected', 'pending_sub', 'unknown'];

    const bar = document.createElement('div');
    bar.className = 'order-bar';
    stateOrder.forEach(st => {
      const n = byState[st] || 0;
      if (!n) return;
      const seg = document.createElement('div');
      seg.className = 'seg ' + st;
      seg.style.flex = String(n);
      seg.textContent = n >= 3 ? n : '';
      seg.title = `${st}: ${n}`;
      bar.appendChild(seg);
    });
    body.appendChild(bar);

    const legend = document.createElement('div');
    legend.className = 'order-legend';
    stateOrder.forEach(st => {
      const n = byState[st] || 0;
      if (!n) return;
      const row = document.createElement('div');
      row.className = 'row ' + st;
      row.innerHTML = `<span class="lbl">${st}</span><span class="num">${n}</span>`;
      legend.appendChild(row);
    });
    body.appendChild(legend);

    const summary = document.createElement('div');
    summary.className = 'order-summary';
    summary.innerHTML = `
      <span class="lbl">items</span><span class="val">${T.fmtNum(orders.summary.total_items)}</span>
      <span class="lbl">tickets sold</span><span class="val">${T.fmtNum(orders.summary.tickets_sold)}</span>
      <span class="lbl">gross sold</span><span class="val">$${T.fmtNum(orders.summary.gross_sold, { max: 0 })}</span>
      <span class="lbl">last update</span><span class="val">${T.fmtDate(orders.summary.last_update_at)}</span>
    `;
    body.appendChild(summary);
  }

  // ---------- Coverage 4-light badge ----------

  function renderCoverage(cadences, overview) {
    if (!cadences || cadences.__err) return;
    const sections = cadences.sections || {};
    const lights = document.querySelectorAll('#coverage .light');
    const tevoFresh = isFresh(sections.overview);
    const espnFresh = isFresh(sections.espn_team) || isFresh(sections.espn_injuries);

    lights.forEach(el => {
      const src = el.dataset.src;
      el.classList.remove('lit', 'stale');
      if (src === 'tevo') {
        if (tevoFresh === true)  el.classList.add('lit');
        else if (tevoFresh === false) el.classList.add('stale');
      } else if (src === 'espn') {
        if (espnFresh === true)  el.classList.add('lit');
        else if (espnFresh === false) el.classList.add('stale');
      }
      // seatgeek + seatdata stay dim — Phase 2.
    });
  }

  function isFresh(section) {
    if (!section || !section.last_pull_at) return null;
    const ageSec = (Date.now() - new Date(section.last_pull_at).getTime()) / 1000;
    if (!Number.isFinite(ageSec)) return null;
    const limit = (section.cadence_seconds || 3600) * 3;
    return ageSec <= limit;
  }

  // ---------- Util ----------

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

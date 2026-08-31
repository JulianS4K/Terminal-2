// D0 Terminal — FLIGHTS: Google-Flights-shaped ticket search.
//
// Three panels, in the order Google Flights uses them:
//   1. the search box   — who / where / when / how many tickets
//   2. the price graph  — cheapest get-in per event DATE across the match set,
//                         click a bar to pin the list to that day
//   3. the results list — one row per event with the cheapest cross-market
//                         get-in, a "vs usual" verdict, and (on expand) the
//                         per-marketplace booking options + price history
//
// Backed by /api/broker/flights/* (routers/flights.py) — a service-role read
// over event_listing_snapshot_daily (breadth: price + history for every event)
// and the TicketsData live listing snapshots (depth: real per-site inventory
// for the credit-budgeted polled subset). No RPC — the TD tables are
// RLS-locked, so this page goes through the backend like axs/paciolan do.
//
// Price tracking is deliberately client-side (localStorage): starring an event
// records today's price in the browser so the list can show the move since you
// starred it. Nothing is written to the DB — a durable, alerting watchlist is
// a data-plane change (a table + a cron), tracked separately.

(function () {
  'use strict';
  const T = window.Terminal;

  const TRACK_KEY = 'flightsTracked';
  const SUGGEST_MS = 250;

  // Marketplace → the shared per-source hue (design-tokens.css). Keeping the
  // same hue per source across the terminal means a chip's color always names
  // its marketplace, on this page as on the event charts.
  const SRC_COLOR = {
    evo: 'var(--src-tevo)', sh: 'var(--src-sh)', gt: 'var(--src-gt)',
    vd: 'var(--src-vd)', tp: 'var(--src-tp)', tm: 'var(--src-tm)',
    sg: 'var(--src-sg)',
  };
  // What a price includes. The daily snapshot columns are pre-fee (except
  // TickPick, which is an all-in market), the live TicketsData listing layer is
  // all-in. Showing the tag is the difference between a comparison and a
  // coincidence, so every price on this page carries one.
  const BASIS_LABEL = { all_in: 'all-in', pre_fee: '+fees at checkout' };
  const BASIS_SHORT = { all_in: 'ALL-IN', pre_fee: 'PRE-FEE' };
  const SRC_LABEL = {
    evo: 'EVO', sh: 'StubHub', gt: 'Gametime', vd: 'VividSeats',
    tp: 'TickPick', tm: 'Ticketmaster', sg: 'SeatGeek',
  };
  const VERDICT_LABEL = {
    deal: 'Great price', low: 'Below usual', typical: 'Usual price',
    high: 'Above usual', unknown: 'No history yet',
  };

  const state = {
    who: '', where: '', from: '', to: '', qty: 2,
    maxPrice: null, minSources: 1, sort: 'best',
    dayFilter: null, trackedOnly: false, focused: null,
    results: [], calendar: [], meta: null,
    expanded: null, details: {},
    busy: false, suggestTimer: 0,
  };

  // ---------- tiny DOM builders (no innerHTML anywhere on this page) --------

  function el(tag, props, kids) {
    const node = document.createElement(tag);
    Object.entries(props || {}).forEach(([k, v]) => {
      if (v === null || v === undefined || v === false) return;
      if (k === 'class') node.className = v;
      else if (k === 'text') node.textContent = v;
      else if (k === 'style') node.setAttribute('style', v);
      else if (k.startsWith('on')) node.addEventListener(k.slice(2), v);
      else if (k === 'dataset') Object.assign(node.dataset, v);
      else node.setAttribute(k, v);
    });
    (kids || []).forEach(k => { if (k) node.appendChild(k); });
    return node;
  }
  function svg(tag, props) {
    const node = document.createElementNS('http://www.w3.org/2000/svg', tag);
    Object.entries(props || {}).forEach(([k, v]) => {
      if (v !== null && v !== undefined) node.setAttribute(k, v);
    });
    return node;
  }
  function clear(node) { while (node.firstChild) node.removeChild(node.firstChild); }

  const money = v => (v === null || v === undefined || !isFinite(+v))
    ? '—' : '$' + T.fmtNum(Math.round(+v));
  const pct = v => (v === null || v === undefined) ? '' : Math.round(Math.abs(v * 100)) + '%';

  function shortDate(day) {
    if (!day) return '—';
    const d = new Date(day + 'T12:00:00');
    return d.toLocaleDateString(undefined, { weekday: 'short', month: 'short', day: 'numeric' });
  }
  function eventWhen(iso) {
    if (!iso) return '—';
    try {
      return new Date(iso).toLocaleString(undefined, {
        weekday: 'short', month: 'short', day: 'numeric',
        hour: 'numeric', minute: '2-digit',
      });
    } catch (_) { return iso; }
  }

  // ---------- price tracking (localStorage) --------------------------------

  function tracked() {
    try { return JSON.parse(localStorage.getItem(TRACK_KEY) || '{}'); }
    catch (_) { return {}; }
  }
  function isTracked(id) { return Object.prototype.hasOwnProperty.call(tracked(), String(id)); }
  function toggleTrack(item) {
    const all = tracked();
    const key = String(item.event_id);
    if (all[key]) delete all[key];
    else all[key] = { name: item.name, price: item.price, at: new Date().toISOString() };
    try { localStorage.setItem(TRACK_KEY, JSON.stringify(all)); } catch (_) {}
    updateTrackedCount();
    render();
  }
  function updateTrackedCount() {
    const n = Object.keys(tracked()).length;
    const chip = document.getElementById('flTrackedN');
    if (chip) chip.textContent = n ? '(' + n + ')' : '';
  }

  // ---------- search -------------------------------------------------------

  function readControls() {
    state.who = document.getElementById('flWho').value.trim();
    state.where = document.getElementById('flWhere').value.trim();
    state.from = document.getElementById('flFrom').value;
    state.to = document.getElementById('flTo').value;
    state.qty = parseInt(document.getElementById('flQty').value, 10) || 1;
    const max = parseFloat(document.getElementById('flMax').value);
    state.maxPrice = isFinite(max) && max > 0 ? max : null;
    state.minSources = parseInt(document.getElementById('flMinSrc').value, 10) || 1;
  }

  function searchPath() {
    const p = new URLSearchParams();
    if (state.who) p.set('q', state.who);
    if (state.where) p.set('city', state.where);
    if (state.from) p.set('date_from', state.from);
    if (state.to) p.set('date_to', state.to);
    if (state.maxPrice) p.set('max_price', String(state.maxPrice));
    if (state.minSources > 1) p.set('min_sources', String(state.minSources));
    p.set('sort', state.sort);
    p.set('limit', '60');
    return '/api/broker/flights/search?' + p.toString();
  }

  async function search() {
    if (state.busy) return;
    readControls();
    if (state.focused) {
      state.focused = null;
      const graph = document.getElementById('fl-graph');
      if (graph) graph.hidden = false;
    }
    state.busy = true;
    state.expanded = null;
    state.details = {};
    T.setStatus('Searching…', '');
    try {
      const data = await T.api(searchPath());
      state.results = data.results || [];
      state.calendar = data.calendar || [];
      state.meta = data.meta || null;
      // A pinned day from a previous search rarely survives a new window.
      if (state.dayFilter && !state.calendar.some(d => d.date === state.dayFilter)) {
        state.dayFilter = null;
      }
      T.setStatus(state.results.length ? 'Live' : 'No priced events', state.results.length ? 'ok' : '');
    } catch (e) {
      T.setStatus(String(e.message || e), 'err');
      state.results = []; state.calendar = []; state.meta = null;
    } finally {
      state.busy = false;
      render();
    }
  }

  // Deep link from the event page (flights.html?event=<id>): show that one
  // event, already expanded, without making the operator re-find it by name.
  async function focusEvent(id) {
    T.setStatus('Loading…', '');
    try {
      const d = await T.api('/api/broker/flights/event/' + id + '?qty=' + state.qty);
      const ev = d.event || {};
      const options = d.options || [];
      state.details[id] = d;
      state.results = [{
        event_id: id, name: ev.name, performer: ev.performer,
        performer_id: ev.performer_id, venue: ev.venue, location: ev.location,
        occurs_at_local: ev.occurs_at_local, event_date: ev.event_date,
        days_out: ev.days_out,
        price: d.price, price_source: d.price_source, price_basis: d.price_basis,
        sources: options.map(o => ({
          source: o.source, label: o.label, getin: o.getin,
          median: o.median, depth: o.listings, basis: o.basis,
        })),
        source_count: options.length,
        insights: d.insights || {},
        spark: (d.history || []).slice(-21).map(p => p.price),
        reasons: [], score: 0,
      }];
      state.calendar = [];
      state.meta = null;
      state.expanded = id;
      state.focused = id;
      // The date grid compares events against each other — meaningless with a
      // set of one, so it stands down rather than rendering an empty panel.
      const graph = document.getElementById('fl-graph');
      if (graph) graph.hidden = true;
      T.setStatus('Live', 'ok');
    } catch (e) {
      T.setStatus(String(e.message || e), 'err');
    }
    render();
  }

  // ---------- price graph --------------------------------------------------

  function renderGraph() {
    const host = document.getElementById('flGraph');
    const meta = document.getElementById('flGraphMeta');
    clear(host);
    const days = state.calendar;
    if (!days.length) {
      host.appendChild(el('div', { class: 'empty', text: 'No dated prices for this search.' }));
      if (meta) meta.textContent = '';
      return;
    }
    const prices = days.map(d => d.price);
    const lo = Math.min.apply(null, prices);
    const hi = Math.max.apply(null, prices);
    if (meta) {
      meta.textContent = days.length + ' dates · ' + money(lo) + '–' + money(hi)
        + (state.dayFilter ? ' · pinned to ' + shortDate(state.dayFilter) : '');
    }

    const strip = el('div', { class: 'fl-bars' });
    days.forEach(d => {
      const span = hi - lo || 1;
      const h = 18 + Math.round(((d.price - lo) / span) * 62);
      const cls = 'fl-bar'
        + (d.is_cheapest ? ' is-cheapest' : '')
        + (state.dayFilter === d.date ? ' is-pinned' : '');
      const bar = el('button', {
        class: cls, type: 'button',
        title: shortDate(d.date) + ' · from ' + money(d.price) + ' · ' + d.events + ' event(s)',
        onclick: () => {
          state.dayFilter = state.dayFilter === d.date ? null : d.date;
          render();
        },
      }, [
        el('span', { class: 'fl-bar-price', text: money(d.price) }),
        el('span', { class: 'fl-bar-fill', style: 'height:' + h + 'px' }),
        el('span', { class: 'fl-bar-day', text: shortDate(d.date).replace(/^\w+, /, '') }),
      ]);
      strip.appendChild(bar);
    });
    host.appendChild(strip);
    if (state.dayFilter) {
      host.appendChild(el('button', {
        class: 'fl-clear', type: 'button', text: '× clear date pin',
        onclick: () => { state.dayFilter = null; render(); },
      }));
    }
  }

  // ---------- results ------------------------------------------------------

  function visibleResults() {
    let rows = state.results;
    if (state.dayFilter) rows = rows.filter(r => r.event_date === state.dayFilter);
    if (state.trackedOnly) rows = rows.filter(r => isTracked(r.event_id));
    return rows;
  }

  function verdictChip(insights) {
    const v = insights.verdict || 'unknown';
    const label = VERDICT_LABEL[v] || v;
    const delta = insights.delta_pct;
    const text = (delta === null || delta === undefined)
      ? label
      : label + ' · ' + (delta < 0 ? '−' : '+') + pct(delta) + ' vs usual';
    // The verdict is measured on ONE anchor market over the window (never a
    // day-by-day cheapest, which moves when coverage moves) — name it, so a
    // reader can see the comparison is like-for-like.
    const srcLabel = SRC_LABEL[insights.source] || insights.source;
    const title = srcLabel
      ? 'vs this event\u2019s own ' + srcLabel + ' price over the last '
        + (insights.days_observed || 0) + ' days'
      : 'no price history yet';
    return el('span', { class: 'fl-verdict fl-v-' + v, text: text, title: title });
  }

  function sparkline(values) {
    const w = 96, h = 26;
    const node = svg('svg', { class: 'fl-spark', width: w, height: h, viewBox: '0 0 ' + w + ' ' + h });
    if (!values || values.length < 2) return node;
    const lo = Math.min.apply(null, values);
    const hi = Math.max.apply(null, values);
    const span = hi - lo || 1;
    const pts = values.map((v, i) => {
      const x = (i / (values.length - 1)) * (w - 2) + 1;
      const y = h - 2 - ((v - lo) / span) * (h - 4);
      return x.toFixed(1) + ',' + y.toFixed(1);
    }).join(' ');
    const line = svg('polyline', {
      points: pts, fill: 'none', 'stroke-width': '1.5',
      stroke: values[values.length - 1] <= values[0] ? 'var(--pos)' : 'var(--warn)',
    });
    node.appendChild(line);
    return node;
  }

  function sourceChips(sources) {
    const row = el('span', { class: 'fl-srcs' });
    sources.slice(0, 7).forEach(s => {
      row.appendChild(el('span', {
        class: 'fl-src', style: 'border-color:' + (SRC_COLOR[s.source] || 'var(--line)'),
        title: s.label + (s.getin ? ' · from ' + money(s.getin) : ''),
        text: s.label,
      }));
    });
    return row;
  }

  function resultRow(item) {
    const star = el('button', {
      class: 'fl-star' + (isTracked(item.event_id) ? ' on' : ''), type: 'button',
      title: isTracked(item.event_id) ? 'Stop tracking this price' : 'Track this price',
      text: isTracked(item.event_id) ? '★' : '☆',
      onclick: (e) => { e.stopPropagation(); toggleTrack(item); },
    });

    const trackRec = tracked()[String(item.event_id)];
    const moveChip = (trackRec && isFinite(trackRec.price) && item.price !== trackRec.price)
      ? el('span', {
        class: 'fl-move ' + (item.price < trackRec.price ? 'down' : 'up'),
        text: (item.price < trackRec.price ? '↓ ' : '↑ ') + money(Math.abs(item.price - trackRec.price))
          + ' since tracked',
      })
      : null;

    const head = el('div', { class: 'fl-row-head', onclick: () => toggleExpand(item) }, [
      el('div', { class: 'fl-col-when' }, [
        el('div', { class: 'fl-when', text: eventWhen(item.occurs_at_local) }),
        el('div', { class: 'fl-out muted small', text: item.days_out === null ? '' : item.days_out + ' days out' }),
      ]),
      el('div', { class: 'fl-col-ev' }, [
        el('div', { class: 'fl-ev-name', text: item.name || '—' }),
        el('div', { class: 'fl-ev-meta muted small', text: [item.venue, item.location].filter(Boolean).join(' · ') }),
        el('div', { class: 'fl-reasons' }, (item.reasons || []).map(r =>
          el('span', { class: 'fl-reason', text: r }))),
      ]),
      el('div', { class: 'fl-col-src' }, [
        sourceChips(item.sources || []),
        el('div', { class: 'muted small', text: item.source_count + (item.source_count === 1 ? ' site' : ' sites') }),
      ]),
      el('div', { class: 'fl-col-spark' }, [sparkline(item.spark)]),
      el('div', { class: 'fl-col-price' }, [
        el('div', { class: 'fl-price' }, [
          el('span', { text: money(item.live_price !== undefined ? item.live_price : item.price) }),
          item.live_price !== undefined ? el('span', { class: 'fl-live-tag', text: 'LIVE' }) : null,
        ]),
        el('div', { class: 'fl-basis', title: 'what this number includes',
                    text: BASIS_LABEL[item.live_price !== undefined ? 'all_in' : item.price_basis] || '' }),
        item.live_price !== undefined
          ? el('div', { class: 'muted small', text: 'daily snapshot ' + money(item.price) })
          : null,
        verdictChip(item.insights || {}),
        moveChip,
      ]),
      el('div', { class: 'fl-col-act' }, [
        star,
        el('span', { class: 'fl-caret', text: state.expanded === item.event_id ? '▾' : '▸' }),
      ]),
    ]);

    const row = el('div', { class: 'fl-row' + (state.expanded === item.event_id ? ' is-open' : '') }, [head]);
    if (state.expanded === item.event_id) row.appendChild(detailPanel(item));
    return row;
  }

  function render() {
    updateTrackedCount();
    renderGraph();

    const host = document.getElementById('flResults');
    const meta = document.getElementById('flResultMeta');
    clear(host);
    const rows = visibleResults();
    if (meta) {
      const m = state.meta;
      meta.textContent = m
        ? rows.length + ' of ' + m.priced + ' priced events (' + m.candidates + ' scanned)'
          + (m.cheapest ? ' · from ' + money(m.cheapest) : '')
        : '';
    }
    if (!rows.length) {
      host.appendChild(el('div', {
        class: 'empty',
        text: state.meta ? 'No events match these filters.'
          : 'Search a team, artist or show to compare prices across marketplaces.',
      }));
      return;
    }
    rows.forEach(r => host.appendChild(resultRow(r)));
  }

  // ---------- expanded detail (booking options + history) ------------------

  function toggleExpand(item) {
    if (state.expanded === item.event_id) { state.expanded = null; render(); return; }
    state.expanded = item.event_id;
    render();
    if (!state.details[item.event_id]) loadDetail(item.event_id);
  }

  async function loadDetail(eventId) {
    state.details[eventId] = { loading: true };
    try {
      const d = await T.api('/api/broker/flights/event/' + eventId + '?qty=' + state.qty);
      state.details[eventId] = d;
      // Fare recheck: the list price is the daily cross-source snapshot, the
      // detail may have a fresher live poll. When they disagree materially,
      // the row shows the live number rather than quietly contradicting the
      // panel below it.
      const row = state.results.find(r => r.event_id === eventId);
      if (row && isFinite(d.price) && row.price
          && Math.abs(d.price - row.price) / row.price >= 0.02) {
        row.live_price = d.price;
        row.live_source = d.price_source;
      }
    } catch (e) {
      state.details[eventId] = { error: String(e.message || e) };
    }
    if (state.expanded === eventId) render();
  }

  function optionsTable(options) {
    const table = el('table', { class: 'fl-tbl' });
    const head = el('tr', {}, [
      el('th', { text: 'MARKETPLACE' }), el('th', { class: 'num', text: 'GET-IN' }),
      el('th', { text: 'PRICE IS' }),
      el('th', { class: 'num', text: 'MEDIAN' }), el('th', { class: 'num', text: 'LISTINGS' }),
      el('th', { class: 'num', text: 'TICKETS' }), el('th', { text: 'AS OF' }), el('th', { text: '' }),
    ]);
    table.appendChild(el('thead', {}, [head]));
    const body = el('tbody');
    const winner = options.find(o => o.getin !== null && o.getin !== undefined
      && (!options.some(x => x.basis === 'all_in' && x.getin !== null && x.getin !== undefined)
          || o.basis === 'all_in'));
    options.forEach((o) => {
      const link = o.event_url
        ? el('a', { href: window.TermRender.safeHref(o.event_url), target: '_blank',
                    rel: 'noopener noreferrer', text: 'open ↗' })
        : el('span', { class: 'muted small', text: '' });
      body.appendChild(el('tr', { class: o === winner ? 'fl-best-opt' : '' }, [
        el('td', {}, [
          el('span', { class: 'fl-dot', style: 'background:' + (SRC_COLOR[o.source] || 'var(--dim)') }),
          el('span', { text: ' ' + o.label }),
          o.live ? el('span', { class: 'fl-live-tag', text: 'LIVE' })
                 : el('span', { class: 'fl-snap-tag', text: 'DAILY' }),
        ]),
        el('td', { class: 'num', text: money(o.getin) }),
        el('td', {}, [el('span', { class: 'fl-basis-tag fl-basis-' + (o.basis || 'unknown'),
                                   text: BASIS_SHORT[o.basis] || '—' })]),
        el('td', { class: 'num', text: money(o.median) }),
        el('td', { class: 'num', text: o.listings === null || o.listings === undefined ? '—' : T.fmtNum(o.listings) }),
        el('td', { class: 'num', text: o.tickets === null || o.tickets === undefined ? '—' : T.fmtNum(o.tickets) }),
        el('td', { class: 'muted small', text: o.captured_at ? T.fmtDate(o.captured_at) : '—' }),
        el('td', {}, [link]),
      ]));
    });
    table.appendChild(body);
    return table;
  }

  function listingsTable(listings, qty) {
    if (!listings.length) {
      return el('div', {
        class: 'muted small',
        text: 'No live listing snapshot for this event — the cross-marketplace poll is credit-budgeted, '
          + 'so prices above come from the daily snapshot instead.',
      });
    }
    const table = el('table', { class: 'fl-tbl' });
    table.appendChild(el('thead', {}, [el('tr', {}, [
      el('th', { text: 'SITE' }), el('th', { text: 'SECTION' }), el('th', { text: 'ROW' }),
      el('th', { class: 'num', text: 'QTY' }), el('th', { class: 'num', text: 'EACH' }),
      el('th', { class: 'num', text: 'TOTAL × ' + qty }),
    ])]));
    const body = el('tbody');
    listings.slice(0, 12).forEach(l => {
      body.appendChild(el('tr', {}, [
        el('td', {}, [
          el('span', { class: 'fl-dot', style: 'background:' + (SRC_COLOR[(l.platform || '').toLowerCase()] || 'var(--dim)') }),
          el('span', { text: ' ' + l.label }),
        ]),
        el('td', { text: l.section || '—' }),
        el('td', { text: l.row || '—' }),
        el('td', { class: 'num', text: String(l.quantity) }),
        el('td', { class: 'num', text: money(l.price) }),
        el('td', { class: 'num', text: money(l.price * qty) }),
      ]));
    });
    table.appendChild(body);
    return table;
  }

  // Price history: the event's own daily get-in line over a typical-price band
  // (p25..p75). Same read as the verdict chip, drawn.
  function historyChart(history, insights) {
    const w = 620, h = 150, padL = 38, padB = 18, padT = 8;
    const node = svg('svg', { class: 'fl-hist', viewBox: '0 0 ' + w + ' ' + h,
                              width: '100%', height: h, preserveAspectRatio: 'none' });
    const pts = (history || []).filter(p => isFinite(p.price));
    if (pts.length < 2) {
      return el('div', { class: 'muted small', text: 'Not enough price history yet for this event.' });
    }
    const vals = pts.map(p => p.price);
    const band = [insights.band_low, insights.band_high].filter(v => isFinite(v));
    const lo = Math.min.apply(null, vals.concat(band));
    const hi = Math.max.apply(null, vals.concat(band));
    const span = hi - lo || 1;
    const x = i => padL + (i / (pts.length - 1)) * (w - padL - 6);
    const y = v => padT + (1 - (v - lo) / span) * (h - padT - padB);

    if (band.length === 2) {
      node.appendChild(svg('rect', {
        x: padL, y: y(insights.band_high), width: w - padL - 6,
        height: Math.max(1, y(insights.band_low) - y(insights.band_high)),
        fill: 'var(--shade)',
      }));
    }
    if (isFinite(insights.typical)) {
      node.appendChild(svg('line', {
        x1: padL, x2: w - 6, y1: y(insights.typical), y2: y(insights.typical),
        stroke: 'var(--dim)', 'stroke-dasharray': '3 3', 'stroke-width': 1,
      }));
    }
    node.appendChild(svg('polyline', {
      points: pts.map((p, i) => x(i).toFixed(1) + ',' + y(p.price).toFixed(1)).join(' '),
      fill: 'none', stroke: 'var(--accent)', 'stroke-width': 1.6,
    }));
    [[hi, padT + 8], [lo, h - padB]].forEach(([v, ty]) => {
      const label = svg('text', { x: 2, y: ty, fill: 'var(--muted)', 'font-size': '10' });
      label.textContent = money(v);
      node.appendChild(label);
    });
    [[pts[0].date, padL + 2, 'start'], [pts[pts.length - 1].date, w - 6, 'end']].forEach(([d, tx, anchor]) => {
      const label = svg('text', { x: tx, y: h - 4, fill: 'var(--muted)', 'font-size': '10', 'text-anchor': anchor });
      label.textContent = shortDate(d);
      node.appendChild(label);
    });
    return node;
  }

  function insightLine(insights, price) {
    const bits = [];
    const srcLabel = SRC_LABEL[insights.source] || insights.source;
    if (srcLabel) bits.push('measured on ' + srcLabel);
    if (isFinite(insights.typical)) {
      bits.push('Usually ' + money(insights.typical)
        + (isFinite(insights.band_low) && isFinite(insights.band_high)
          ? ' (' + money(insights.band_low) + '–' + money(insights.band_high) + ' band)' : ''));
    }
    if (isFinite(price) && isFinite(insights.typical)) {
      const diff = price - insights.typical;
      bits.push(diff <= 0 ? money(Math.abs(diff)) + ' cheaper than usual'
                          : money(diff) + ' pricier than usual');
    }
    if (insights.trend && insights.trend !== 'flat') {
      bits.push('prices ' + insights.trend + ' ' + pct(insights.trend_pct) + ' this week');
    }
    if (isFinite(insights.cheapest_seen)) bits.push('cheapest seen ' + money(insights.cheapest_seen));
    if (insights.days_observed) bits.push(insights.days_observed + ' days of history');
    return el('div', { class: 'fl-insight', text: bits.join(' · ') || 'No price history yet.' });
  }

  function detailPanel(item) {
    const d = state.details[item.event_id];
    if (!d || d.loading) return el('div', { class: 'fl-detail', text: 'Loading booking options…' });
    if (d.error) return el('div', { class: 'fl-detail err', text: d.error });

    return el('div', { class: 'fl-detail' }, [
      el('div', { class: 'fl-detail-grid' }, [
        el('div', { class: 'fl-detail-col' }, [
          el('div', { class: 'fl-sub', text: 'BOOKING OPTIONS' }),
          optionsTable(d.options || []),
          el('div', { class: 'fl-sub', text: 'CHEAPEST LISTINGS SEATING ' + (d.listings_qty || state.qty) }),
          listingsTable(d.listings || [], d.listings_qty || state.qty),
        ]),
        el('div', { class: 'fl-detail-col' }, [
          el('div', { class: 'fl-sub', text: 'PRICE HISTORY' }),
          historyChart(d.history || [], d.insights || {}),
          insightLine(d.insights || {}, d.price),
          el('div', { class: 'fl-links' }, [
            el('a', { href: 'event.html?event=' + item.event_id, text: 'open on the event page →' }),
          ]),
        ]),
      ]),
    ]);
  }

  // ---------- typeahead ----------------------------------------------------

  function wireSuggest() {
    const input = document.getElementById('flWho');
    const box = document.getElementById('flSuggest');
    input.addEventListener('input', () => {
      clearTimeout(state.suggestTimer);
      const q = input.value.trim();
      if (q.length < 2) { box.hidden = true; return; }
      state.suggestTimer = setTimeout(async () => {
        try {
          const data = await T.api('/api/broker/flights/suggest?q=' + encodeURIComponent(q));
          clear(box);
          const list = data.suggestions || [];
          if (!list.length) { box.hidden = true; return; }
          list.forEach(s => box.appendChild(el('button', {
            class: 'fl-suggest-item', type: 'button',
            onclick: () => { input.value = s.name; box.hidden = true; search(); },
          }, [
            el('span', { text: s.name }),
            el('span', { class: 'muted small', text: ' ' + s.events + ' events' }),
          ])));
          box.hidden = false;
        } catch (_) { box.hidden = true; }
      }, SUGGEST_MS);
    });
    input.addEventListener('keydown', e => {
      if (e.key === 'Enter') { box.hidden = true; search(); }
      if (e.key === 'Escape') box.hidden = true;
    });
    document.addEventListener('click', e => {
      if (!box.contains(e.target) && e.target !== input) box.hidden = true;
    });
  }

  function wireControls() {
    document.getElementById('flGo').addEventListener('click', search);
    document.getElementById('flWhere').addEventListener('keydown', e => {
      if (e.key === 'Enter') search();
    });
    document.querySelectorAll('[data-span]').forEach(btn => btn.addEventListener('click', () => {
      document.querySelectorAll('[data-span]').forEach(b => b.classList.remove('is-active'));
      btn.classList.add('is-active');
      const days = parseInt(btn.dataset.span, 10);
      const from = new Date();
      const to = new Date(Date.now() + days * 86400000);
      document.getElementById('flFrom').value = from.toISOString().slice(0, 10);
      document.getElementById('flTo').value = to.toISOString().slice(0, 10);
      search();
    }));
    document.querySelectorAll('[data-sort]').forEach(btn => btn.addEventListener('click', () => {
      document.querySelectorAll('[data-sort]').forEach(b => b.classList.remove('is-active'));
      btn.classList.add('is-active');
      state.sort = btn.dataset.sort;
      search();
    }));
    ['flMax', 'flMinSrc'].forEach(id =>
      document.getElementById(id).addEventListener('change', search));
    document.getElementById('flQty').addEventListener('change', () => {
      readControls();
      state.details = {};   // cheapest-listings depends on the ticket count
      if (state.expanded) loadDetail(state.expanded);
      render();
    });
    const trackedBtn = document.getElementById('flTracked');
    trackedBtn.addEventListener('click', () => {
      state.trackedOnly = !state.trackedOnly;
      trackedBtn.classList.toggle('is-active', state.trackedOnly);
      render();
    });
  }

  async function init() {
    if (window.TerminalAuth) await window.TerminalAuth.requireAuth();
    const from = new Date();
    const to = new Date(Date.now() + 30 * 86400000);
    document.getElementById('flFrom').value = from.toISOString().slice(0, 10);
    document.getElementById('flTo').value = to.toISOString().slice(0, 10);
    wireControls();
    wireSuggest();
    updateTrackedCount();

    // Deep links: ?event=<id> (one event, expanded — from the event page's
    // COMPARE ON FLIGHTS badge) or ?q=Knicks&city=New+York (a pre-run search).
    const qs = new URLSearchParams(location.search);
    const focusId = parseInt(qs.get('event') || '', 10);
    if (Number.isFinite(focusId) && focusId > 0) {
      await focusEvent(focusId);
      return;
    }
    if (qs.get('q')) document.getElementById('flWho').value = qs.get('q');
    if (qs.get('city')) document.getElementById('flWhere').value = qs.get('city');
    await search();
  }

  // A rejected init must not surface as an uncaught pageerror — the status
  // pill is where a failure belongs (and the frontend smoke test treats any
  // pageerror as a defect, correctly).
  const boot = () => init().catch(e => T.setStatus(String(e.message || e), 'err'));
  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', boot);
  } else {
    boot();
  }
})();

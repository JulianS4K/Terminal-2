// VibePass Prices — public get-in price tracker. One script for all /prices
// pages; <body data-page="home|event|list"> picks the initializer.
// Data: /api/prices/{events,event/:id,search} (routers/prices.py).
// Requires /static/lib/s4k.js (loaded first by every page).
(function () {
  'use strict';

  // ---------- helpers ----------
  const $ = (sel, root) => (root || document).querySelector(sel);
  // All markup goes through S4K (static/lib/s4k.js): values are escaped with
  // esc() and written only via the one sanctioned sink, setHTML().
  const esc = S4K.esc;
  const setHTML = S4K.setTrustedHTML;
  const money = (v) => (v == null || isNaN(+v) ? '—' : '$' + Math.round(+v).toLocaleString('en-US'));

  async function getJSON(url) {
    const res = await fetch(url, { headers: { Accept: 'application/json' } });
    if (!res.ok) {
      const err = new Error('HTTP ' + res.status);
      err.status = res.status;
      throw err;
    }
    return res.json();
  }

  function ago(iso) {
    if (!iso) return '—';
    const s = Math.max(0, (Date.now() - new Date(iso).getTime()) / 1000);
    if (s < 90) return 'just now';
    const m = s / 60; if (m < 60) return Math.round(m) + ' minutes ago';
    const h = m / 60; if (h < 36) return Math.round(h) + (Math.round(h) === 1 ? ' hour ago' : ' hours ago');
    const d = h / 24; return Math.round(d) + (Math.round(d) === 1 ? ' day ago' : ' days ago');
  }
  const isStale = (iso) => !iso || Date.now() - new Date(iso).getTime() > 6 * 3600 * 1000;

  // occurs_at_local is the venue's wall-clock time ("YYYY-MM-DDTHH:MM:SS[±HH:MM]").
  // Render it as-is — never convert to the viewer's zone.
  const DOW = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];
  function localParts(s) {
    const m = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2})/.exec(s || '');
    if (!m) return null;
    const [y, mo, d, hh, mi] = m.slice(1).map(Number);
    const dow = new Date(Date.UTC(y, mo - 1, d)).getUTCDay();
    return { y, mo, d, hh, mi, dow };
  }
  function fmtLocal(s, long) {
    const p = localParts(s);
    if (!p) return '—';
    const h12 = ((p.hh + 11) % 12) + 1;
    const ampm = p.hh < 12 ? 'AM' : 'PM';
    const pad = (n) => String(n).padStart(2, '0');
    if (long) {
      const MON = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
      return `${DOW[p.dow]}, ${MON[p.mo - 1]} ${p.d}, ${p.y} · ${h12}:${pad(p.mi)} ${ampm}`;
    }
    return `${DOW[p.dow]}, ${pad(p.mo)}/${pad(p.d)}/${p.y} ${pad(h12)}:${pad(p.mi)} ${ampm}`;
  }
  const cityOf = (loc) => (loc || '').split(',')[0].trim() || '—';

  const ARROW_UP = '<svg width="14" height="14" viewBox="0 0 16 16" aria-hidden="true"><path d="M1.5 12 6 7.5l3 3L14.5 5M10.5 5h4v4" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"/></svg>';
  const ARROW_DN = '<svg width="14" height="14" viewBox="0 0 16 16" aria-hidden="true"><path d="M1.5 4 6 8.5l3-3L14.5 11M10.5 11h4V7" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"/></svg>';
  const EXT = '<svg width="14" height="14" viewBox="0 0 16 16" aria-hidden="true"><path d="M9 2h5v5M14 2 7.5 8.5M12 9.5V13a1 1 0 0 1-1 1H3a1 1 0 0 1-1-1V5a1 1 0 0 1 1-1h3.5" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"/></svg>';

  function chgHTML(pct) {
    if (pct == null || isNaN(+pct)) return '<span class="chg flat">—</span>';
    const v = +pct;
    if (Math.abs(v) < 0.5) return '<span class="chg flat">Flat</span>';
    const up = v > 0;
    return `<span class="chg ${up ? 'up' : 'down'}">${up ? ARROW_UP : ARROW_DN}${Math.round(Math.abs(v))}%</span>`;
  }

  const eventUrl = (id) => '/prices/event/' + encodeURIComponent(id);
  const performerUrl = (id) => '/prices/performer/' + encodeURIComponent(id);
  const venueUrl = (id) => '/prices/venue/' + encodeURIComponent(id);

  // Watchlist — per-browser convenience only (localStorage can be unavailable).
  const WATCH_KEY = 'vp_prices_watch_v1';
  function readWatch() {
    try { return JSON.parse(localStorage.getItem(WATCH_KEY) || '[]') || []; } catch (e) { return []; }
  }
  function writeWatch(list) {
    try { localStorage.setItem(WATCH_KEY, JSON.stringify(list.slice(0, 50))); } catch (e) { /* storage off */ }
  }

  // ---------- search box ----------
  function wireSearch(root) {
    const input = $('input', root);
    const box = document.createElement('div');
    box.className = 'search-results';
    box.hidden = true;
    root.appendChild(box);
    let timer = null, seq = 0, active = -1;

    function links() { return Array.from(box.querySelectorAll('a')); }
    function setActive(i) {
      const ls = links();
      ls.forEach((a, j) => a.classList.toggle('is-active', j === i));
      active = i;
    }
    async function run(q) {
      const my = ++seq;
      let data;
      try { data = await getJSON('/api/prices/search?q=' + encodeURIComponent(q)); } catch (e) { data = null; }
      if (my !== seq) return;
      if (!data) { setHTML(box, '<div class="empty">Search is unavailable right now.</div>'); box.hidden = false; return; }
      const parts = [];
      if (data.performers && data.performers.length) {
        parts.push('<h4>Teams &amp; performers</h4>' + data.performers.map((p) =>
          `<a href="${performerUrl(p.id)}"><span>${esc(p.name)}</span><span class="sub">${p.n} events</span></a>`).join(''));
      }
      if (data.venues && data.venues.length) {
        parts.push('<h4>Venues</h4>' + data.venues.map((v) =>
          `<a href="${venueUrl(v.id)}"><span>${esc(v.name)}</span><span class="sub">${esc(v.location || '')}</span></a>`).join(''));
      }
      if (data.events && data.events.length) {
        parts.push('<h4>Events</h4>' + data.events.map((e) =>
          `<a href="${eventUrl(e.id)}"><span>${esc(e.name)}</span><span class="sub">${esc(fmtLocal(e.occurs_at_local).slice(5, 15))}</span></a>`).join(''));
      }
      setHTML(box, parts.join('') || '<div class="empty">No matches.</div>');
      box.hidden = false;
      active = -1;
    }
    input.addEventListener('input', () => {
      clearTimeout(timer);
      const q = input.value.trim();
      if (q.length < 2) { box.hidden = true; return; }
      timer = setTimeout(() => run(q), 250);
    });
    input.addEventListener('keydown', (ev) => {
      const ls = links();
      if (box.hidden || !ls.length) return;
      if (ev.key === 'ArrowDown') { ev.preventDefault(); setActive(Math.min(active + 1, ls.length - 1)); }
      else if (ev.key === 'ArrowUp') { ev.preventDefault(); setActive(Math.max(active - 1, 0)); }
      else if (ev.key === 'Enter') { ev.preventDefault(); (ls[active] || ls[0]).click(); }
      else if (ev.key === 'Escape') { box.hidden = true; }
    });
    document.addEventListener('click', (ev) => { if (!root.contains(ev.target)) box.hidden = true; });
  }

  // ---------- events table ----------
  // opts: {mount, rows, total, showMeta, emptyText}
  function EventsTable(mount) {
    const st = { rows: [], win: '3d', sortKey: null, sortDir: 1, total: 0, label: 'events' };
    const cols = [
      { key: 'name', label: 'Event' },
      { key: 'date', label: 'Date', sortable: true },
      { key: 'performer', label: 'Performer', cls: 'hide-sm' },
      { key: 'venue', label: 'Venue', sortable: true, cls: 'hide-sm' },
      { key: 'city', label: 'City', cls: 'hide-sm hide-md' },
      { key: 'change', label: 'Change', sortable: true },
      { key: 'getin', label: 'Get-in Price', sortable: true },
      { key: 'upd', label: 'Last Updated', cls: 'hide-sm' },
    ];
    const val = {
      date: (r) => r.occurs_at_local || '',
      venue: (r) => (r.venue_name || '').toLowerCase(),
      change: (r) => (r.change && r.change[st.win] != null ? +r.change[st.win] : null),
      getin: (r) => (r.getin != null ? +r.getin : null),
    };
    function sorted() {
      if (!st.sortKey) return st.rows;
      const f = val[st.sortKey];
      return st.rows.slice().sort((a, b) => {
        const x = f(a), y = f(b);
        if (x == null && y == null) return 0;
        if (x == null) return 1;
        if (y == null) return -1;
        return (x < y ? -1 : x > y ? 1 : 0) * st.sortDir;
      });
    }
    function render() {
      const rows = sorted();
      const head = cols.map((c) => {
        const on = st.sortKey === c.key;
        const arrow = c.sortable ? (on ? (st.sortDir > 0 ? ' ↑' : ' ↓') : ' ⇅') : '';
        let label = esc(c.label) + arrow;
        if (c.key === 'change') {
          label = `${{ '3d': '3 Day', '7d': '7 Day', '14d': '14 Day', '30d': '30 Day' }[st.win]} Change${arrow}` +
            '<div class="win">' + ['3d', '7d', '14d', '30d'].map((w) =>
              `<button type="button" data-win="${w}" class="${w === st.win ? 'is-on' : ''}">${w.toUpperCase()}</button>`).join('') + '</div>';
        }
        return `<th class="${c.cls || ''} ${c.sortable ? 'sortable' : ''} ${on ? 'sorted' : ''}" ${c.sortable ? `data-sort="${c.key}"` : ''}>${label}</th>`;
      }).join('');
      const body = rows.length ? rows.map((r) => `<tr>
          <td class="ev trunc"><a href="${eventUrl(r.id)}" title="${esc(r.name)}">${esc(r.name)}</a></td>
          <td class="date">${esc(fmtLocal(r.occurs_at_local))}</td>
          <td class="lnk trunc hide-sm">${r.performer_id ? `<a href="${performerUrl(r.performer_id)}">${esc(r.performer_name || '')}</a>` : esc(r.performer_name || '—')}</td>
          <td class="lnk trunc hide-sm">${r.venue_id ? `<a href="${venueUrl(r.venue_id)}">${esc(r.venue_name || '')}</a>` : esc(r.venue_name || '—')}</td>
          <td class="city hide-sm hide-md">${esc(cityOf(r.venue_location))}</td>
          <td>${chgHTML(r.change ? r.change[st.win] : null)}</td>
          <td class="price">${money(r.getin)}</td>
          <td class="upd hide-sm">${esc(r.captured_at ? ago(r.captured_at) : '—')}</td>
        </tr>`).join('') : `<tr><td colspan="${cols.length}" class="empty-row">${esc(st.emptyText || 'No events match these filters.')}</td></tr>`;
      const shown = rows.length;
      setHTML(mount, `<div class="card table-card">
          <div class="table-meta"><span>Showing ${shown}${st.total > shown ? ' of ' + st.total : ''} ${esc(st.label)}</span><span class="extra"></span></div>
          <div class="table-scroll"><table class="events"><thead><tr>${head}</tr></thead><tbody>${body}</tbody></table></div>
        </div>`);
      mount.querySelectorAll('[data-win]').forEach((b) => b.addEventListener('click', (ev) => {
        ev.stopPropagation(); st.win = b.dataset.win; render();
      }));
      mount.querySelectorAll('th[data-sort]').forEach((th) => th.addEventListener('click', () => {
        const k = th.dataset.sort;
        if (st.sortKey === k) st.sortDir = -st.sortDir;
        else { st.sortKey = k; st.sortDir = k === 'date' || k === 'venue' ? 1 : -1; }
        render();
      }));
    }
    return {
      set(rows, total, label, emptyText) {
        st.rows = rows || []; st.total = total || 0; st.label = label || 'events'; st.emptyText = emptyText;
        render();
      },
      loading() { setHTML(mount, '<div class="card table-card"><div class="empty-row">Loading…</div></div>'); },
      error(msg) { setHTML(mount, `<div class="card table-card"><div class="empty-row">${esc(msg)}</div></div>`); },
    };
  }

  // ---------- price chart (inline SVG; one axis; crosshair tooltip) ----------
  const SERIES_VARS = ['--series-1', '--series-2', '--series-3', '--series-4', '--series-5', '--series-6', '--series-7', '--series-8'];
  const cssVar = (name) => getComputedStyle(document.documentElement).getPropertyValue(name).trim();

  function niceTicks(lo, hi, n) {
    const span = Math.max(hi - lo, 1);
    const step0 = span / n;
    const mag = Math.pow(10, Math.floor(Math.log10(step0)));
    const step = [1, 2, 2.5, 5, 10].map((m) => m * mag).find((s) => span / s <= n) || 10 * mag;
    const start = Math.floor(lo / step) * step;
    const out = [];
    for (let v = start; v <= hi + step * 0.5; v += step) out.push(v);
    return out;
  }

  // series: [{name, color, points:[[ms, value]], hero}]
  function drawChart(box, series, range, emptyMsg) {
    // Draw at the container's real width so axis text stays legible on phones.
    const W = Math.max(300, Math.round(box.clientWidth || 860));
    const H = W < 600 ? 260 : 380;
    const P = { l: 52, r: 12, t: 14, b: 30 };
    const x0 = range[0], x1 = range[1];
    const vis = series.map((s) => ({ ...s, points: s.points.filter((p) => p[0] >= x0 && p[0] <= x1) }));
    // Carry the last known value into the window so a flat stretch still draws.
    series.forEach((s, i) => {
      const before = s.points.filter((p) => p[0] < x0);
      if (before.length) vis[i].points.unshift([x0, before[before.length - 1][1]]);
    });
    const all = vis.flatMap((s) => s.points.map((p) => p[1]));
    setHTML(box, '');
    if (!all.length) {
      setHTML(box, `<svg viewBox="0 0 ${W} ${H}" role="img" aria-label="No data"></svg><div class="chart-empty">${esc(emptyMsg)}</div>`);
      return;
    }
    let lo = Math.min(...all), hi = Math.max(...all);
    const pad = Math.max((hi - lo) * 0.15, hi * 0.05, 5);
    lo = Math.max(0, lo - pad); hi = hi + pad;
    const ticks = niceTicks(lo, hi, 5);
    lo = Math.min(lo, ticks[0]); hi = Math.max(hi, ticks[ticks.length - 1]);
    const sx = (t) => P.l + ((t - x0) / Math.max(x1 - x0, 1)) * (W - P.l - P.r);
    const sy = (v) => H - P.b - ((v - lo) / Math.max(hi - lo, 1)) * (H - P.t - P.b);

    const spanDays = (x1 - x0) / 86400000;
    const MON = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    const xt = [];
    if (spanDays > 70) {
      // Long ranges: one tick per month boundary (thinned to fit), never repeats.
      const d = new Date(x0); d.setDate(1); d.setHours(0, 0, 0, 0); d.setMonth(d.getMonth() + 1);
      const months = [];
      while (d.getTime() <= x1) { months.push(new Date(d)); d.setMonth(d.getMonth() + 1); }
      const every = Math.max(1, Math.ceil(months.length / (W < 600 ? 4 : 8)));
      months.forEach((m, i) => {
        if (i % every) return;
        xt.push([m.getTime(), MON[m.getMonth()] + (spanDays > 400 ? ' ' + String(m.getFullYear()).slice(2) : '')]);
      });
    } else {
      const nX = W < 600 ? 3 : 6;
      for (let i = 0; i <= nX; i++) {
        const t = x0 + ((x1 - x0) * i) / nX;
        const d = new Date(t);
        xt.push([t, spanDays <= 2 ? d.toLocaleTimeString('en-US', { hour: 'numeric' }) : `${MON[d.getMonth()]} ${d.getDate()}`]);
      }
    }

    // Step-after paths: a get-in holds until the next check.
    const path = (pts) => pts.map((p, i) => (i ? `H${sx(p[0]).toFixed(1)}V${sy(p[1]).toFixed(1)}` : `M${sx(p[0]).toFixed(1)},${sy(p[1]).toFixed(1)}`)).join('');
    const extendTo = (pts) => (pts.length ? pts.concat([[Math.min(x1, Date.now()), pts[pts.length - 1][1]]]) : pts);

    let svg = `<svg viewBox="0 0 ${W} ${H}" role="img" aria-label="Get-in price history">`;
    svg += '<g class="grid">' + ticks.map((v) => `<line x1="${P.l}" x2="${W - P.r}" y1="${sy(v)}" y2="${sy(v)}"/>`).join('') + '</g>';
    svg += '<g class="axis">' + ticks.map((v) => `<text x="${P.l - 8}" y="${sy(v) + 4}" text-anchor="end">${money(v)}</text>`).join('') +
      xt.map(([t, l]) => {
        const x = sx(t);
        const anchor = x < P.l + 20 ? 'start' : x > W - P.r - 20 ? 'end' : 'middle';
        return `<text x="${x.toFixed(1)}" y="${H - 8}" text-anchor="${anchor}">${esc(l)}</text>`;
      }).join('') + '</g>';
    vis.forEach((s) => {
      if (!s.points.length) return;
      const pts = extendTo(s.points);
      const d = path(pts);
      if (s.hero && vis.length === 1) {
        const area = `${d}V${sy(lo)}H${sx(pts[0][0])}Z`;
        svg += `<path d="${area}" fill="var(--area)" stroke="none"/>`;
      }
      svg += `<path d="${d}" fill="none" stroke="${s.color}" stroke-width="${s.hero ? 2.25 : 2}" stroke-linejoin="round" stroke-linecap="round"/>`;
      const last = pts[pts.length - 1];
      if (s.hero) svg += `<circle cx="${sx(last[0])}" cy="${sy(last[1])}" r="4.5" fill="${s.color}" stroke="var(--surface)" stroke-width="2"/>`;
    });
    svg += `<line class="xhair" x1="0" x2="0" y1="${P.t}" y2="${H - P.b}" stroke="var(--muted)" stroke-dasharray="3 3" visibility="hidden"/>`;
    svg += `<rect class="hit" x="${P.l}" y="${P.t}" width="${W - P.l - P.r}" height="${H - P.t - P.b}" fill="transparent"/>`;
    svg += '</svg>';
    setHTML(box, svg);

    const el = box.querySelector('svg');
    const xh = el.querySelector('.xhair');
    const tip = document.createElement('div');
    tip.className = 'tip'; tip.hidden = true;
    box.appendChild(tip);
    const valueAt = (pts, t) => {
      let v = null;
      for (const p of pts) { if (p[0] <= t) v = p[1]; else break; }
      return v;
    };
    function move(ev) {
      const r = el.getBoundingClientRect();
      const px = ((ev.clientX - r.left) / r.width) * W;
      if (px < P.l || px > W - P.r) { leave(); return; }
      const t = x0 + ((px - P.l) / (W - P.l - P.r)) * (x1 - x0);
      if (t > Date.now()) { leave(); return; }
      xh.setAttribute('x1', px); xh.setAttribute('x2', px); xh.setAttribute('visibility', 'visible');
      const rowsH = vis.map((s) => [s, valueAt(s.points, t)]).filter((x) => x[1] != null);
      if (!rowsH.length) { tip.hidden = true; return; }
      const d = new Date(t);
      setHTML(tip, `<div class="t">${esc(d.toLocaleString('en-US', { month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit' }))}</div>` +
        rowsH.map(([s, v]) => `<div class="r"><span><i style="background:${s.color}"></i>${esc(s.name)}</span><b>${money(v)}</b></div>`).join(''));
      tip.hidden = false;
      const bx = box.getBoundingClientRect();
      const left = ev.clientX - bx.left;
      tip.style.left = (left > bx.width - 200 ? left - tip.offsetWidth - 12 : left + 12) + 'px';
      tip.style.top = Math.max(0, ev.clientY - bx.top - tip.offsetHeight - 10) + 'px';
    }
    function leave() { xh.setAttribute('visibility', 'hidden'); tip.hidden = true; }
    el.addEventListener('pointermove', move);
    el.addEventListener('pointerleave', leave);
  }

  // ---------- page: event ----------
  async function initEvent() {
    const id = (location.pathname.match(/\/prices\/event\/(\d+)/) || [])[1];
    const status = $('#status');
    let data;
    try { data = await getJSON('/api/prices/event/' + id); } catch (e) {
      status.textContent = e.status === 404 ? 'We couldn’t find that event.' : 'Price data is temporarily unavailable. Please try again shortly.';
      status.hidden = false;
      return;
    }
    const ev = data.event, cur = data.current || {};
    document.title = `${ev.name} Ticket Prices — VibePass Prices`;
    $('#evTitle').textContent = ev.name;
    setHTML($('#evMeta'), [
      ev.performer_id ? `<a href="${performerUrl(ev.performer_id)}">${esc(ev.performer_name)}</a>` : null,
      ev.venue_id ? `<a href="${venueUrl(ev.venue_id)}">${esc(ev.venue_name)}</a>` : esc(ev.venue_name),
      esc(ev.venue_location || ''),
      esc(fmtLocal(ev.occurs_at_local, true)),
    ].filter(Boolean).join('<span class="sep">|</span>'));
    $('#content').hidden = false;

    // Stat cards.
    setHTML($('#getin'), cur.getin != null ? `${money(cur.getin)}<small>per ticket</small>` : '—');
    setHTML($('#getinNote'), cur.captured_at
      ? `<span class="dot ${isStale(cur.captured_at) ? 'stale' : ''}"></span>Checked ${esc(ago(cur.captured_at))}`
      : 'No price checks yet');
    setHTML($('#chg3'), chgHTML(cur.change_3d_pct));
    const p3 = cur.prior_3d, g = cur.getin;
    $('#chg3Note').textContent = p3 != null && g != null
      ? (Math.abs(g - p3) < 0.5 ? `Get-in price is unchanged at ${money(g)} over the past 3 days`
        : `Get-in price is ${g > p3 ? 'up' : 'down'} from ${money(p3)} to ${money(g)} over the past 3 days`)
      : 'Not enough price history yet';
    renderGauge(data.forecast || {});
    renderWeather(data.weather, ev);

    // Chart.
    const hist = (data.history || []).map((p) => [p[0] * 1000, +p[1]]);
    const zones = data.zones || [];
    const st = { range: 'all', zones: false };
    const firstT = hist.length ? hist[0][0] : Date.now() - 86400000;
    const RANGES = { '1d': 1, '3d': 3, '1w': 7, '1m': 30, '6m': 182 };
    function draw() {
      const now = Date.now();
      const x0 = st.range === 'all' ? Math.min(firstT, now - 86400000) : now - RANGES[st.range] * 86400000;
      const series = [];
      const hero = cssVar('--series-hero');
      if (st.zones) {
        series.push({ name: 'Get-in (all zones)', color: hero, hero: true, points: hist });
        zones.forEach((z, i) => series.push({
          name: z.zone, color: cssVar(SERIES_VARS[i % SERIES_VARS.length]),
          points: (z.history || []).map((p) => [p[0] * 1000, +p[1]]),
        }));
      } else {
        series.push({ name: 'Get-in price', color: cssVar('--accent'), hero: true, points: hist });
      }
      setHTML($('#legend'), series.map((s) => `<span><i style="background:${s.color}"></i>${esc(s.name)}</span>`).join(''));
      const last = cur.captured_at ? ` Last check: ${ago(cur.captured_at)}.` : '';
      drawChart($('#chart'), series, [x0, now], `No price checks in this window.${last}`);
    }
    document.querySelectorAll('#ranges button').forEach((b) => b.addEventListener('click', () => {
      document.querySelectorAll('#ranges button').forEach((x) => x.classList.toggle('is-on', x === b));
      st.range = b.dataset.range; draw();
    }));
    const zt = $('#zonesToggle');
    if (!zones.length) zt.closest('label').hidden = true;
    zt.addEventListener('change', () => { st.zones = zt.checked; draw(); });
    draw();
    let rz = null, lastW = $('#chart').clientWidth;
    window.addEventListener('resize', () => {
      clearTimeout(rz);
      rz = setTimeout(() => { const w = $('#chart').clientWidth; if (w !== lastW) { lastW = w; draw(); } }, 150);
    });
    if (window.matchMedia) {
      const mq = window.matchMedia('(prefers-color-scheme: dark)');
      if (mq.addEventListener) mq.addEventListener('change', draw);
    }

    // Zone table.
    if (zones.length) {
      $('#zonesCard').hidden = false;
      setHTML($('#zonesBody'), zones.map((z) => `<tr><td>${esc(z.zone)}</td><td>${money(z.getin)}</td><td>${z.tickets != null ? (+z.tickets).toLocaleString('en-US') : '—'}</td></tr>`).join(''));
    }

    // Buy links (outbound only; we never proxy a purchase).
    const links = data.links || [];
    const resale = links.filter((l) => l.kind === 'resale');
    const primary = links.filter((l) => l.kind === 'primary');
    const linkHTML = (l) => `<a class="buy" href="${S4K.safeHref(l.url)}" target="_blank" rel="noopener noreferrer nofollow"><span>${esc(l.name)}</span>${EXT}</a>`;
    setHTML($('#buyBody'), links.length
      ? (resale.length ? '<h4>Resale marketplaces</h4>' + resale.map(linkHTML).join('') : '') +
        (primary.length ? '<h4>Primary market</h4>' + primary.map(linkHTML).join('') : '')
      : '<p class="muted small" style="margin:0">No marketplace links for this event yet.</p>');

    // Watch (this browser only).
    const btn = $('#watchBtn');
    const isOn = () => readWatch().some((w) => w.id === ev.id);
    const paint = () => { btn.classList.toggle('is-on', isOn()); btn.lastChild.textContent = isOn() ? ' Watching' : ' Watch Event'; };
    btn.addEventListener('click', () => {
      let list = readWatch();
      if (isOn()) list = list.filter((w) => w.id !== ev.id);
      else list.unshift({ id: ev.id, name: ev.name, occurs_at_local: ev.occurs_at_local });
      writeWatch(list); paint();
    });
    paint();
  }

  function renderGauge(fc) {
    const dir = fc.direction || 'unknown';
    const angle = { decrease: -55, flat: 0, increase: 55 }[dir];
    const closed = dir === 'closed' || dir === 'unknown';
    const label = {
      decrease: 'Prices likely to dip', increase: 'Prices likely to rise', flat: 'Prices likely to hold',
      closed: 'Forecast closed', unknown: 'Not enough data',
    }[dir];
    const R = 46, cx = 60, cy = 56;
    const arc = (a0, a1) => {
      const p = (a) => [cx + R * Math.cos((a - 90) * Math.PI / 180), cy + R * Math.sin((a - 90) * Math.PI / 180)];
      const [x0, y0] = p(a0), [x1, y1] = p(a1);
      return `M${x0.toFixed(1)},${y0.toFixed(1)}A${R},${R} 0 0 1 ${x1.toFixed(1)},${y1.toFixed(1)}`;
    };
    const needle = closed ? '' : (() => {
      const a = (angle - 90) * Math.PI / 180;
      return `<line x1="${cx}" y1="${cy}" x2="${(cx + (R - 8) * Math.cos(a)).toFixed(1)}" y2="${(cy + (R - 8) * Math.sin(a)).toFixed(1)}" stroke="var(--text)" stroke-width="3" stroke-linecap="round"/><circle cx="${cx}" cy="${cy}" r="4" fill="var(--text)"/>`;
    })();
    setHTML($('#gauge'), `<div class="side">Prices will decrease</div>
      <svg width="120" height="66" viewBox="0 0 120 66" role="img" aria-label="${esc(label)}">
        <path d="${arc(-90, -32)}" fill="none" stroke="var(--down)" stroke-opacity=".55" stroke-width="12"/>
        <path d="${arc(-28, 28)}" fill="none" stroke="var(--line)" stroke-width="12"/>
        <path d="${arc(32, 90)}" fill="none" stroke="var(--up)" stroke-opacity=".55" stroke-width="12"/>
        ${needle}
      </svg>
      <div class="side">Prices will increase</div>`);
    $('#gaugeLabel').textContent = label + (dir !== 'closed' && fc.spike_up_prob_pct != null ? ` · ${Math.round(fc.spike_up_prob_pct)}% spike risk` : '');
  }

  function renderWeather(w, ev) {
    const p = localParts(ev.occurs_at_local);
    if (p) $('#wxLbl').textContent = `Weather at ${((p.hh + 11) % 12) + 1}:${String(p.mi).padStart(2, '0')} ${p.hh < 12 ? 'AM' : 'PM'}`;
    if (w && w.is_indoor) { $('#wx').textContent = 'Indoors'; $('#wxNote').textContent = 'Indoor venue — weather won’t matter'; return; }
    if (!w || w.temp_f == null) { $('#wx').textContent = '—'; $('#wxNote').textContent = 'Forecast not available yet'; return; }
    setHTML($('#wx'), `${Math.round(w.temp_f)}°<small>${esc(w.weather_summary || '')}</small>`);
    const bits = [];
    if (w.precip_pct != null) bits.push(`${Math.round(w.precip_pct)}% chance of rain`);
    if (w.wind_mph != null) bits.push(`Wind ${Math.round(w.wind_mph)} mph`);
    if (w.weather_kind === 'climo') bits.push('typical for the date');
    $('#wxNote').textContent = bits.join(' · ');
  }

  // ---------- shared list filters (performer + venue pages) ----------
  function applyClientFilters(rows, f) {
    return rows.filter((r) => {
      const p = localParts(r.occurs_at_local);
      if (!p) return true;
      if (f.days.size && !f.days.has(p.dow)) return false;
      if (f.time === 'day' && p.hh >= 17) return false;
      if (f.time === 'night' && p.hh < 17) return false;
      if (f.side !== 'all' && f.performerName) {
        const name = r.name || '';
        const at = name.toLowerCase().indexOf(' at ');
        if (at >= 0) {
          const home = name.slice(at + 4).toLowerCase().startsWith(f.performerName.toLowerCase());
          if (f.side === 'home' && !home) return false;
          if (f.side === 'away' && home) return false;
        } else if (f.side === 'away') return false;
      }
      return true;
    });
  }

  function wirePills(root, onPick) {
    root.querySelectorAll('button').forEach((b) => b.addEventListener('click', () => {
      root.querySelectorAll('button').forEach((x) => x.classList.toggle('is-on', x === b));
      onPick(b.dataset.v);
    }));
  }

  function wireDow(root, onChange) {
    const btn = $('button', root), menu = $('.dow-menu', root);
    btn.addEventListener('click', (e) => { e.stopPropagation(); menu.hidden = !menu.hidden; });
    document.addEventListener('click', (e) => { if (!root.contains(e.target)) menu.hidden = true; });
    menu.addEventListener('change', () => {
      const days = new Set(Array.from(menu.querySelectorAll('input:checked')).map((i) => +i.value));
      btn.firstChild.textContent = days.size ? `Days (${days.size}) ` : 'Days of Week ';
      onChange(days);
    });
  }

  // ---------- page: performer / venue ----------
  async function initList() {
    const m = location.pathname.match(/\/prices\/(performer|venue)\/(\d+)/);
    if (!m) return;
    const kind = m[1], id = m[2];
    const table = EventsTable($('#table'));
    const f = { when: 'upcoming', days: new Set(), time: 'all', side: 'all', performerName: null };
    let data = null;
    const redraw = () => {
      if (!data) return;
      const rows = applyClientFilters(data.rows || [], f);
      table.set(rows, rows.length, `${f.when === 'all' ? '' : f.when + ' '}events`,
        f.when === 'upcoming' ? 'No upcoming events match these filters.' : 'No events match these filters.');
    };
    async function load() {
      table.loading();
      const q = new URLSearchParams({ when: f.when, sort: 'date', limit: '200' });
      q.set(kind === 'performer' ? 'performer_id' : 'venue_id', id);
      try { data = await getJSON('/api/prices/events?' + q); } catch (e) {
        table.error('Price data is temporarily unavailable. Please try again shortly.'); return;
      }
      const ent = data.entity || {};
      const name = ent.name || (kind === 'venue' ? 'Venue' : 'Performer');
      document.title = `${name} Ticket Prices — VibePass Prices`;
      $('#title').textContent = `${name} Ticket Prices`;
      if (kind === 'performer') {
        f.performerName = ent.name || null;
        const anyAt = (data.rows || []).some((r) => / at /i.test(r.name || ''));
        $('#sidePills').hidden = !anyAt;
      }
      const place = kind === 'venue' && ent.location ? ` in ${ent.location}` : '';
      const up = f.when === 'upcoming';
      $('#lede').textContent = data.total
        ? `${name} tickets${place} ${data.min_getin != null ? 'start at ' + money(data.min_getin) : 'are listed'} across ${data.total} ${up ? 'upcoming ' : ''}event${data.total === 1 ? '' : 's'}. See whether get-in prices are rising or falling.`
        : `No ${up ? 'upcoming ' : ''}events for ${name} right now.`;
      redraw();
    }
    wirePills($('#whenPills'), (v) => { f.when = v; load(); });
    wirePills($('#timePills'), (v) => { f.time = v; redraw(); });
    wirePills($('#sidePills'), (v) => { f.side = v; redraw(); });
    wireDow($('#dow'), (days) => { f.days = days; redraw(); });
    load();
  }

  // ---------- page: home ----------
  function dayWindow(key) {
    const d = new Date();
    const iso = (x) => `${x.getFullYear()}-${String(x.getMonth() + 1).padStart(2, '0')}-${String(x.getDate()).padStart(2, '0')}`;
    const add = (n) => { const x = new Date(d); x.setDate(x.getDate() + n); return x; };
    if (key === 'today') return [iso(d), iso(d)];
    if (key === 'tomorrow') return [iso(add(1)), iso(add(1))];
    if (key === 'weekend') {
      const dow = d.getDay();
      const toFri = dow === 0 ? -2 : dow === 6 ? -1 : 5 - dow;
      return [iso(add(Math.max(toFri, 0))), iso(add(toFri + 2))];
    }
    if (key === 'week') return [iso(d), iso(add(6))];
    return [iso(d), iso(add(29))];
  }

  async function initHome() {
    const table = EventsTable($('#table'));
    const f = { cat: null, when: 'today' };
    async function load() {
      table.loading();
      const [from, to] = dayWindow(f.when);
      const q = new URLSearchParams({ day_from: from, day_to: to, sort: 'price', limit: '100' });
      if (f.cat) q.set('category', f.cat);
      let data;
      try { data = await getJSON('/api/prices/events?' + q); } catch (e) {
        table.error('Price data is temporarily unavailable. Please try again shortly.'); return;
      }
      table.set(data.rows, data.total, 'events', 'No events with prices in this window. Try a wider date range.');
    }
    wirePills($('#catChips'), (v) => { f.cat = v || null; load(); });
    $('#when').addEventListener('change', (e) => { f.when = e.target.value; load(); });
    document.querySelectorAll('[data-league]').forEach((a) => a.addEventListener('click', (e) => {
      e.preventDefault();
      const v = a.dataset.league;
      document.querySelectorAll('#catChips button').forEach((b) => b.classList.toggle('is-on', b.dataset.v === v));
      f.cat = v; f.when = 'month'; $('#when').value = 'month';
      load();
      $('#hot').scrollIntoView({ behavior: 'smooth', block: 'start' });
    }));
    load();

    const watch = readWatch();
    if (watch.length) {
      $('#watchSec').hidden = false;
      setHTML($('#watchList'), watch.map((w) =>
        `<a class="chip" href="${eventUrl(w.id)}">${esc(w.name)} · ${esc(fmtLocal(w.occurs_at_local).slice(5, 15))}</a>`).join(''));
    }
  }

  // ---------- boot ----------
  document.querySelectorAll('.search').forEach(wireSearch);
  const page = document.body.dataset.page;
  if (page === 'event') initEvent();
  else if (page === 'list') initList();
  else if (page === 'home') initHome();
})();

// D0 Terminal — Orders page (inline unified order book).
//
// Renders the D2 order surface directly inside the terminal instead of
// linking out to a separate d2-orders-dashboard service. The d2_dashboard
// router is mounted same-origin into this FastAPI shell (app.py —
// `app.include_router(d2_router)`), so /api/d2/orders is reachable with the
// terminal's own Supabase JWT (TerminalAuth) via Terminal.api(). The order
// sources (evo / seatgeek_sales / tickpick / vivid) come from
// public.unified_orders — SQL-only, read-only (2026-05-13 lockdown). The
// view excludes seatdata: it's a third-party completed-sales market feed,
// not our broker order book (see HIDDEN_SOURCES).

(function () {
  'use strict';
  const T = window.Terminal;

  // Source pills. ids match unified_orders.source values; `all` is the FE
  // catch-all (no server-side source filter — we filter the page client-side).
  const SOURCE_LABELS = {
    evo: 'EVO',
    seatgeek_sales: 'SG',
    tickpick: 'TickPick',
    vivid: 'Vivid',
  };

  // Sources hidden from this view. seatdata is third-party completed-sales
  // analytics (a market feed), not our broker order book — exclude its rows
  // and freshness chip entirely.
  const HIDDEN_SOURCES = new Set(['seatdata']);

  const state = {
    source: 'all',        // 'all' | one of SOURCE_LABELS keys
    includeTerminal: 0,   // 0 = active-only, 1 = all states
    perPage: 100,
  };

  let lastPayload = null; // cache the last /api/d2/orders response for re-filter

  function init() {
    if (window.TerminalAuth) {
      window.TerminalAuth.requireAuth().then(wire).catch(() => wire());
    } else {
      wire();
    }
  }

  function wire() {
    // Source pills — client-side filter, no refetch needed.
    document.querySelectorAll('[data-source]').forEach(btn => {
      btn.addEventListener('click', () => {
        setActive('[data-source]', btn);
        state.source = btn.dataset.source;
        if (lastPayload) renderRows(lastPayload);
      });
    });
    // State toggle — Active vs All changes the server query (include_terminal).
    document.querySelectorAll('[data-term]').forEach(btn => {
      btn.addEventListener('click', () => {
        setActive('[data-term]', btn);
        state.includeTerminal = +btn.dataset.term;
        load();
      });
    });
    const refresh = document.getElementById('refreshBtn');
    if (refresh) refresh.addEventListener('click', load);
    load();
  }

  function setActive(selector, btn) {
    document.querySelectorAll(selector).forEach(b => b.classList.remove('is-active'));
    btn.classList.add('is-active');
  }

  async function load() {
    const body = document.getElementById('ordersBody');
    if (body) body.innerHTML = '<div class="empty">loading…</div>';
    if (T && T.setStatus) T.setStatus('loading orders…', '');
    const qs = `per_page=${state.perPage}&page=1&include_terminal=${state.includeTerminal}`;
    try {
      const data = await T.api(`/api/d2/orders?${qs}`);
      lastPayload = data;
      renderRows(data);
      renderFreshness(data.sources || []);
      // Cron cadence is a separate, slower poll — enrich the chips when it lands.
      loadCronFreshness();
      const n = (data.rows || []).length;
      if (T && T.setStatus) T.setStatus(`${n} order${n === 1 ? '' : 's'}`, 'ok');
    } catch (e) {
      lastPayload = null;
      if (body) body.innerHTML = `<div class="empty">${esc(e.message)}</div>`;
      if (T && T.setStatus) T.setStatus(e.message, 'err');
    }
  }

  function renderRows(data) {
    const body = document.getElementById('ordersBody');
    const countEl = document.getElementById('ordersCount');
    if (!body) return;
    // Drop hidden sources (seatdata — third-party market feed) before any
    // count or per-source filtering so they never surface in this view.
    const visible = (data.rows || []).filter(r => !HIDDEN_SOURCES.has(r.source));
    let rows = visible;
    if (state.source !== 'all') rows = rows.filter(r => r.source === state.source);

    if (countEl) {
      const total = visible.length;
      countEl.textContent = state.source === 'all'
        ? `${total} row${total === 1 ? '' : 's'} · ${state.includeTerminal ? 'all states' : 'active only'}`
        : `${rows.length} of ${total} · ${SOURCE_LABELS[state.source] || state.source}`;
    }

    if (!rows.length) {
      body.innerHTML = '<div class="empty">no orders for this source + state filter</div>';
      return;
    }

    const tbl = document.createElement('table');
    tbl.innerHTML = `
      <thead><tr>
        <th>Source</th>
        <th>Event</th>
        <th>Date</th>
        <th class="num">Qty</th>
        <th>Status</th>
        <th class="num">Amount</th>
        <th>Ordered</th>
      </tr></thead>`;
    const tbody = document.createElement('tbody');
    rows.forEach(r => {
      const tr = document.createElement('tr');
      tr.innerHTML = `
        <td><span class="badge muted">${esc(SOURCE_LABELS[r.source] || r.source || '—')}</span></td>
        <td>${esc(r.event_name || '—')}</td>
        <td class="muted small">${r.event_date ? esc(T.fmtDate(r.event_date)) : '—'}</td>
        <td class="num">${r.qty != null ? r.qty : '—'}</td>
        <td>${statusBadge(r)}</td>
        <td class="num">${fmtAmount(r.amount, r.currency)}</td>
        <td class="muted small" title="${esc(r.ordered_at || '')}">${ago(r.ordered_at)}</td>`;
      tbody.appendChild(tr);
    });
    tbl.appendChild(tbody);
    body.innerHTML = '';
    body.appendChild(tbl);
  }

  // Active = pending / accepted / substitution; terminal = fulfilled / rejected
  // / cancelled (mirror d2_dashboard _ACTIVE_STATUSES / _TERMINAL_STATUSES).
  const POS_STATUS = new Set(['accepted', 'fulfilled']);
  const NEG_STATUS = new Set(['rejected', 'cancelled']);

  function statusBadge(r) {
    const canon = r.canonical_status;
    const raw = r.status;
    const label = canon || raw || '—';
    let cls = '';
    if (POS_STATUS.has(canon)) cls = 'pos';
    else if (NEG_STATUS.has(canon)) cls = 'neg';
    const title = (raw && raw !== canon) ? ` title="raw: ${esc(raw)}"` : '';
    return `<span class="badge ${cls}"${title}>${esc(label)}</span>`;
  }

  function renderFreshness(sources) {
    const strip = document.getElementById('freshStrip');
    if (!strip) return;
    sources = sources.filter(s => !HIDDEN_SOURCES.has(s.source));
    if (!sources.length) { strip.innerHTML = ''; return; }
    strip.innerHTML = sources.map(s => {
      const lbl = SOURCE_LABELS[s.source] || s.source;
      const okCls = s.ok ? '' : 'neg';
      const age = s.as_of ? ago(s.as_of) : 'no data';
      return `<span class="badge ${okCls}" data-fresh="${esc(s.source)}" `
        + `title="${esc(s.source)} · ${s.count} row(s) · last seen ${esc(s.as_of || 'never')}">`
        + `${esc(lbl)} · ${s.count} · ${esc(age)}</span>`;
    }).join('');
  }

  // Best-effort cadence overlay — adds "· every 30m" to each freshness chip
  // when the cron-freshness RPC reports a schedule. Silent on failure (the
  // chips still show count + last-seen age without it).
  async function loadCronFreshness() {
    try {
      const data = await T.api('/api/d2/cron-freshness');
      const bySource = data.sources || {};
      Object.keys(bySource).forEach(src => {
        const chip = document.querySelector(`[data-fresh="${cssEsc(src)}"]`);
        if (!chip) return;
        const sched = bySource[src] && bySource[src].schedule;
        if (sched) chip.textContent += ` · ${cronCadence(sched)}`;
      });
    } catch (_) { /* cadence is decorative — ignore */ }
  }

  // Compress a cron expression to a human cadence for the chip suffix.
  function cronCadence(expr) {
    if (!expr) return '';
    const m = /^\*\/(\d+)\s/.exec(expr);
    if (m) return `every ${m[1]}m`;
    if (/^0\s\*\//.test(expr)) {
      const h = /^0\s\*\/(\d+)\s/.exec(expr);
      if (h) return `every ${h[1]}h`;
    }
    return expr;
  }

  function fmtAmount(amount, currency) {
    if (amount === null || amount === undefined || Number.isNaN(amount)) return '—';
    const sym = currency === 'USD' || !currency ? '$' : '';
    return sym + T.fmtNum(amount, { min: 0, max: 0 });
  }

  function ago(iso) {
    if (!iso) return '—';
    const ms = Date.now() - new Date(iso).getTime();
    if (!Number.isFinite(ms)) return '—';
    if (ms < 0) return 'just now';
    const m = Math.round(ms / 60000);
    if (m < 1) return 'just now';
    if (m < 60) return m + 'm ago';
    const h = Math.round(m / 60);
    if (h < 24) return h + 'h ago';
    const d = Math.round(h / 24);
    return d + 'd ago';
  }

  function esc(s) {
    if (s === null || s === undefined) return '';
    return String(s).replace(/[&<>"']/g, c => ({
      '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;',
    }[c]));
  }

  // Escape a value for use inside an attribute-equals CSS selector.
  function cssEsc(s) {
    return String(s).replace(/["\\]/g, '\\$&');
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init);
  } else {
    init();
  }
})();

// D0 Terminal — Compare page (stock-compare window for performers).
//
// Add up to 5 performers and line their Statistics stat-cards up side-by-side:
// performers are columns, metrics are rows, grouped MARKET / POSITION / TREND.
// The leader in each row is highlighted. Data = get_performer_stat_cards (one
// round-trip over the persisted performer_stat_card table); the picker reuses
// the global terminal_search RPC. Selection persists in the URL (?ids=a,b,c)
// so a comparison is shareable.

(function () {
  'use strict';
  const T = window.Terminal;
  const escapeHtml = window.TermRender.escapeHtml;
  const MAX = 5;

  // Metric row config. better: 'max' | 'min' | null (which column leads).
  // delta: a second field rendered as a signed % / count chip next to the value.
  const GROUPS = [
    { title: 'Market', rows: [
      { key: 'event_count',   label: 'Active events',      fmt: 'num',  better: 'max' },
      { key: 'getin_min',     label: 'Get-in (min)',       fmt: 'usd2', better: 'min' },
      { key: 'getin_median',  label: 'Get-in (median)',    fmt: 'usd',  better: 'min' },
      { key: 'price_median',  label: 'Price median',       fmt: 'usd',  better: 'max' },
      { key: 'price_p90',     label: 'Ceiling (p90)',      fmt: 'usd',  better: 'max' },
      { key: 'spread_ratio',  label: 'Spread (p90÷get-in)',fmt: 'mult', better: null  },
      { key: 'market_tickets',label: 'Market float (tix)', fmt: 'num',  better: 'max' },
      { key: 'median_median_price', label: 'Median · all events', fmt: 'usd', better: 'max' },
    ]},
    { title: 'Position', rows: [
      { key: 'owned_tickets',      label: 'Owned tickets',   fmt: 'num', better: 'max', delta: 'owned_tickets_d30', deltaFmt: 'num' },
      { key: 'owned_book_notional',label: 'Owned notional',  fmt: 'usd', better: 'max' },
      { key: 'owned_share',        label: 'Owned share (EVO)',fmt: 'pct', better: 'max' },
    ]},
    { title: 'Trend', rows: [
      { key: 'price_d7_pct',     label: 'Price Δ 7d',   fmt: 'spct', better: 'max' },
      { key: 'price_d30_pct',    label: 'Price Δ 30d',  fmt: 'spct', better: 'max' },
      { key: 'getin_d7_pct',     label: 'Get-in Δ 7d',  fmt: 'spct', better: null  },
      { key: 'home_price_median',label: 'Home price median', fmt: 'usd',  better: 'max', sportsOnly: true },
      { key: 'away_price_median',label: 'Away price median', fmt: 'usd',  better: 'max', sportsOnly: true },
    ]},
    { title: 'Top event (highest median)', rows: [
      { key: 'top_event_name',  label: 'Event',         fmt: 'text', better: null },
      { key: 'top_event_median',label: 'Median',        fmt: 'usd',  better: 'max' },
      { key: '_seasonphase',    label: 'Season · phase', fmt: 'text', better: null },
    ]},
    { title: 'AXS (merged source)', optional: true, probe: 'axs_event_count', rows: [
      { key: 'axs_event_count', label: 'AXS events',   fmt: 'num',  better: 'max' },
      { key: 'axs_getin_min',   label: 'AXS get-in',   fmt: 'usd2', better: 'min' },
      { key: 'axs_listings',    label: 'AXS listings', fmt: 'num',  better: 'max' },
    ]},
  ];

  // selected: [{ id, name }]
  let selected = [];
  let cards = {};   // id -> stat-card row

  // ---------- URL state ----------
  function idsFromUrl() {
    const raw = new URLSearchParams(location.search).get('ids') || '';
    return raw.split(',').map(s => parseInt(s, 10)).filter(n => Number.isFinite(n) && n > 0).slice(0, MAX);
  }
  function syncUrl() {
    const ids = selected.map(s => s.id).join(',');
    const url = new URL(location.href);
    if (ids) url.searchParams.set('ids', ids); else url.searchParams.delete('ids');
    history.replaceState(null, '', url);
  }

  // ---------- Formatters ----------
  const num  = v => (v != null && isFinite(v)) ? T.fmtNum(v) : '—';
  const usd  = v => (v != null && isFinite(v)) ? '$' + T.fmtNum(Math.round(v)) : '—';
  const usd2 = v => (v != null && isFinite(v)) ? '$' + Number(v).toFixed(2) : '—';
  const mult = v => (v != null && isFinite(v)) ? Number(v).toFixed(2) + '×' : '—';
  const pct  = v => (v != null && isFinite(v)) ? T.fmtPct(v * 100, 1) : '—';
  function spct(v) {  // signed %, already a percent number (e.g. 2.1)
    if (v == null || !isFinite(v)) return '—';
    const cls = v > 0 ? 'up' : (v < 0 ? 'down' : '');
    const arw = v > 0 ? '▲ ' : (v < 0 ? '▼ ' : '');
    return `<span class="sc-delta ${cls}">${arw}${Math.abs(v).toFixed(1)}%</span>`;
  }
  const text = v => (v != null && v !== '') ? escapeHtml(String(v)) : '—';
  const FMT = { num, usd, usd2, mult, pct, spct, text };

  function fmtVal(row, card) {
    const raw = card ? card[row.key] : null;
    let html = FMT[row.fmt](raw);
    if (row.delta && card) {
      const dv = card[row.delta];
      if (dv != null && isFinite(dv) && dv !== 0) {
        const cls = dv > 0 ? 'up' : 'down', arw = dv > 0 ? '▲' : '▼';
        const dt = row.deltaFmt === 'num' ? num(Math.abs(dv)) : Math.abs(dv).toFixed(1) + '%';
        html += ` <span class="sc-delta ${cls}">${arw} ${dt}</span>`;
      }
    }
    return html;
  }

  // leader index/indices for a row (which columns lead); null when no basis
  function leaders(row) {
    if (!row.better) return new Set();
    const vals = selected.map(s => {
      const c = cards[s.id];
      const v = c ? c[row.key] : null;
      return (v != null && isFinite(v)) ? Number(v) : null;
    });
    const present = vals.filter(v => v != null);
    if (present.length < 2) return new Set();  // nothing to lead vs
    const best = row.better === 'max' ? Math.max(...present) : Math.min(...present);
    const set = new Set();
    vals.forEach((v, i) => { if (v === best) set.add(i); });
    return set;
  }

  // ---------- Compare table ----------
  function renderTable() {
    const body = document.getElementById('cmpBody');
    if (!selected.length) {
      body.innerHTML = '<div class="empty">add up to 5 performers above to compare</div>';
      return;
    }
    const anySports = selected.some(s => cards[s.id] && cards[s.id].is_sports);

    const head = ['<tr><th class="cmp-corner">Metric</th>'];
    selected.forEach(s => {
      const c = cards[s.id];
      const asOf = c && c.as_of ? c.as_of : '';
      head.push(`<th><a href="performer.html?performer=${s.id}">${escapeHtml(s.name)}</a>` +
        (asOf ? `<span class="th-sub">as of ${escapeHtml(asOf)}</span>` : `<span class="th-sub">no stored card</span>`) + `</th>`);
    });
    head.push('</tr>');

    const rows = [];
    GROUPS.forEach(g => {
      // optional group (e.g. AXS) — skip entirely if no selected performer has data
      if (g.optional && !selected.some(s => cards[s.id] && cards[s.id][g.probe] != null)) return;
      rows.push(`<tr class="cmp-grouphdr"><td colspan="${selected.length + 1}">${g.title}</td></tr>`);
      g.rows.forEach(row => {
        if (row.sportsOnly && !anySports) return;
        const lead = leaders(row);
        const cells = selected.map((s, i) => {
          const c = cards[s.id];
          const val = (row.sportsOnly && c && !c.is_sports) ? '—' : fmtVal(row, c);
          return `<td class="cmp-val${lead.has(i) ? ' leader' : ''}${row.fmt === 'text' ? ' txt' : ''}">${val}</td>`;
        }).join('');
        rows.push(`<tr><td class="cmp-lbl">${escapeHtml(row.label)}</td>${cells}</tr>`);
      });
    });

    body.innerHTML = `<div class="cmp-table-scroll"><table class="cmp-table">
      <thead>${head.join('')}</thead><tbody>${rows.join('')}</tbody></table></div>`;
  }

  function renderChips() {
    const wrap = document.getElementById('cmpChips');
    document.getElementById('cmpMeta').textContent = `${selected.length}/${MAX} · Statistics side-by-side`;
    wrap.innerHTML = selected.map(s =>
      `<span class="cmp-chip">${escapeHtml(s.name)}<button data-remove="${s.id}" title="remove">×</button></span>`).join('');
    wrap.querySelectorAll('button[data-remove]').forEach(b =>
      b.addEventListener('click', () => removePerformer(parseInt(b.dataset.remove, 10))));
  }

  // ---------- Selection ----------
  async function addPerformer(id, name) {
    id = parseInt(id, 10);
    if (!Number.isFinite(id) || id <= 0) return;
    if (selected.find(s => s.id === id)) return;
    if (selected.length >= MAX) { T.setStatus(`max ${MAX} performers`, 'err'); return; }
    selected.push({ id, name: name || ('#' + id) });
    renderChips(); syncUrl();
    await loadCards();
  }
  function removePerformer(id) {
    selected = selected.filter(s => s.id !== id);
    delete cards[id];
    renderChips(); syncUrl(); renderTable();
  }

  async function loadCards() {
    const ids = selected.map(s => s.id);
    if (!ids.length) { renderTable(); return; }
    const Auth = window.TerminalAuth;
    if (!Auth || !Auth.client || !Auth.getAccessToken()) {
      document.getElementById('cmpBody').innerHTML = '<div class="empty">compare needs auth — sign in with @s4kent.com</div>';
      return;
    }
    T.setStatus('Loading cards…');
    const res = await Auth.client.rpc('get_performer_stat_cards', { p_ids: ids });
    if (res.error) {
      document.getElementById('cmpBody').innerHTML = `<div class="empty">RPC error: ${escapeHtml(res.error.message)}</div>`;
      T.setStatus(res.error.message, 'err');
      return;
    }
    (res.data || []).forEach(c => {
      c._seasonphase = [c.top_event_season, c.top_event_phase].filter(Boolean).join(' · ');
      cards[c.performer_id] = c;
    });
    // backfill names from the card if we only had an id (URL restore)
    selected.forEach(s => { const c = cards[s.id]; if (c && c.performer_name) s.name = c.performer_name; });
    renderChips(); renderTable();
    T.setStatus('Loaded', 'ok');
  }

  // ---------- Picker (terminal_search) ----------
  function initPicker() {
    const input = document.getElementById('cmpSearch');
    const sugg  = document.getElementById('cmpSuggest');
    let debT = 0, lastQ = '';

    function close() { sugg.setAttribute('hidden', ''); }
    function open()  { sugg.removeAttribute('hidden'); }

    async function run(q) {
      if (q === lastQ) return;
      lastQ = q;
      if (q.length < 2) { close(); return; }
      const Auth = window.TerminalAuth;
      if (!Auth || !Auth.client || !Auth.getAccessToken()) {
        sugg.innerHTML = '<div class="cs-empty">search needs auth — sign in with @s4kent.com</div>'; open(); return;
      }
      sugg.innerHTML = '<div class="cs-empty">searching…</div>'; open();
      const res = await Auth.client.rpc('terminal_search', { p_q: q, p_limit: 6 });
      if (res.error) { sugg.innerHTML = `<div class="cs-empty">${escapeHtml(res.error.message)}</div>`; return; }
      renderSuggest(res.data || {});
    }

    function renderSuggest(d) {
      // Merge performer-bearing results: PERFORMERS + PLAYERS (their team performer).
      const seen = new Set(selected.map(s => s.id));
      const items = [];
      (d.performers || []).forEach(p => {
        if (p.tevo_performer_id == null || seen.has(p.tevo_performer_id)) return;
        seen.add(p.tevo_performer_id);
        items.push({ id: p.tevo_performer_id, name: p.performer_name, meta: p.category || 'performer' });
      });
      (d.players || []).forEach(pl => {
        if (pl.tevo_performer_id == null || seen.has(pl.tevo_performer_id)) return;
        seen.add(pl.tevo_performer_id);
        const meta = [pl.team_name, pl.espn_league].filter(Boolean).join(' · ') || 'team';
        items.push({ id: pl.tevo_performer_id, name: pl.team_name || pl.full_name, meta });
      });
      if (!items.length) { sugg.innerHTML = `<div class="cs-empty">no performer matches for &ldquo;${escapeHtml(d.q || '')}&rdquo;</div>`; return; }
      sugg.innerHTML = items.map(it =>
        `<div class="cs-row" data-id="${it.id}" data-name="${escapeHtml(it.name || '')}">
           <span class="cs-name">${escapeHtml(it.name || '(unnamed)')}</span>
           <span class="cs-meta">${escapeHtml(it.meta)}</span>
         </div>`).join('');
      sugg.querySelectorAll('.cs-row').forEach(r => r.addEventListener('click', () => {
        addPerformer(r.dataset.id, r.dataset.name);
        input.value = ''; lastQ = ''; close(); input.focus();
      }));
    }

    input.addEventListener('input', () => { clearTimeout(debT); const q = input.value.trim(); debT = setTimeout(() => run(q), 250); });
    input.addEventListener('focus', () => { if (lastQ.length >= 2 && sugg.innerHTML) open(); });
    document.addEventListener('click', e => { if (e.target !== input && !sugg.contains(e.target)) close(); });
  }

  // ---------- Boot ----------
  async function init() {
    if (window.TerminalAuth) await window.TerminalAuth.requireAuth();
    initPicker();
    // Restore selection from URL (?ids=a,b,c) — names backfill from the cards.
    idsFromUrl().forEach(id => selected.push({ id, name: '#' + id }));
    renderChips();
    await loadCards();
  }

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', init);
  else init();
})();

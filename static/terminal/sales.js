// D0 Terminal — Sales page. Realized-sales analytics over the d0_sales_fact
// snapshot (docs/d0-sales-reports.md), via the /api/d0/sales/* service-role
// endpoints (routers/d0_sales.py). Three surfaces:
//   1. League dashboard  — /api/d0/sales/leagues  (click a row → §2)
//   2. Away-team board    — /api/d0/sales/leagues/{league}/visiting-teams
//   3. Performer report   — /api/d0/sales/performers/{id}[/by-source|/sections]
// Plus a refresh-health strip (/api/d0/sales/health) with a >24h staleness flag.

(function () {
  'use strict';

  const T = window.Terminal;
  const esc = (window.TermRender && window.TermRender.escapeHtml) || (s => String(s == null ? '' : s));

  const el = {
    health:    document.getElementById('healthStrip'),
    leagues:   document.getElementById('leaguesBody'),
    visLeague: document.getElementById('visLeague'),
    visNote:   document.getElementById('visNote'),
    visitors:  document.getElementById('visitorsBody'),
    perfForm:  document.getElementById('perfForm'),
    perfInput: document.getElementById('perfInput'),
    performer: document.getElementById('performerBody'),
  };

  // ---------- formatting ----------
  const num = (n) => Number(n == null ? NaN : n);
  const money = (n) => {
    const v = num(n);
    if (!Number.isFinite(v)) return '—';
    return '$' + v.toLocaleString(undefined, { maximumFractionDigits: 0 });
  };
  const price = (n) => {
    const v = num(n);
    if (!Number.isFinite(v)) return '—';
    return '$' + v.toLocaleString(undefined, { minimumFractionDigits: 2, maximumFractionDigits: 2 });
  };
  const int = (n) => T.fmtNum(num(n), { max: 0 });

  function kpi(lbl, val, small) {
    return `<div class="kpi-strip-cell"><span class="kpi-lbl">${esc(lbl)}</span>` +
           `<span class="kpi-val${small ? ' small' : ''}">${val}</span></div>`;
  }

  // ---------- refresh health ----------
  async function loadHealth() {
    try {
      const d = await T.api('/api/d0/sales/health');
      const runs = d.runs || [];
      const nightly = runs.find(r => (r.jobname || '').includes('nightly')) || runs[0];
      if (!nightly) { el.health.textContent = 'refresh health: no runs recorded yet'; return; }
      const start = nightly.start_time ? new Date(nightly.start_time) : null;
      const ageH = start ? (Date.now() - start.getTime()) / 3.6e6 : null;
      const stale = ageH != null && ageH > 24;
      const okMark = nightly.status === 'succeeded' && !stale;
      el.health.innerHTML =
        `refresh: <span class="${okMark ? 'pos' : 'neg'}">${esc(nightly.status || 'unknown')}</span>` +
        (start ? ` · ${T.fmtDate(nightly.start_time)}` : '') +
        (nightly.duration_secs != null ? ` · ${num(nightly.duration_secs).toFixed(1)}s` : '') +
        (stale ? ' · <span class="neg">STALE &gt;24h</span>' : '');
    } catch (e) {
      el.health.innerHTML = `<span class="neg">refresh health error: ${esc(e.message)}</span>`;
    }
  }

  // ---------- league dashboard ----------
  let selectedLeague = null;

  async function loadLeagues() {
    try {
      const d = await T.api('/api/d0/sales/leagues');
      const rows = d.leagues || [];
      if (!rows.length) { el.leagues.innerHTML = '<div class="empty">no league sales</div>'; return; }
      el.leagues.innerHTML =
        '<table class="sales-tbl"><thead><tr>' +
        '<th>LEAGUE</th><th class="r">REVENUE</th><th class="r">TICKETS</th>' +
        '<th class="r">MEDIAN</th><th class="r">WTD MEDIAN</th><th class="r">AVG</th>' +
        '<th class="r">SALE LINES</th></tr></thead><tbody>' +
        rows.map(r => `<tr class="lg-row" data-league="${esc(r.league)}" tabindex="0" role="button">` +
          `<td class="lg-name">${esc(r.league)}</td>` +
          `<td class="r">${money(r.total_revenue)}</td>` +
          `<td class="r">${int(r.tickets_sold)}</td>` +
          `<td class="r">${price(r.median_price)}</td>` +
          `<td class="r">${price(r.weighted_median_price)}</td>` +
          `<td class="r">${price(r.avg_price)}</td>` +
          `<td class="r muted">${int(r.sale_lines)}</td></tr>`).join('') +
        '</tbody></table>';
      el.leagues.querySelectorAll('.lg-row').forEach(tr => {
        const go = () => selectLeague(tr.dataset.league);
        tr.addEventListener('click', go);
        tr.addEventListener('keydown', e => { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); go(); } });
      });
      T.setStatus('ready', 'ok');
      // Auto-select the top league so the board isn't empty on first load.
      if (!selectedLeague && rows[0]) selectLeague(rows[0].league);
    } catch (e) {
      el.leagues.innerHTML = `<div class="empty neg">${esc(e.message)}</div>`;
      T.setStatus(e.message, 'err');
    }
  }

  async function selectLeague(league) {
    selectedLeague = league;
    el.visLeague.textContent = league;
    el.leagues.querySelectorAll('.lg-row').forEach(tr =>
      tr.classList.toggle('active', tr.dataset.league === league));
    el.visitors.innerHTML = '<div class="empty">loading…</div>';
    try {
      const d = await T.api(`/api/d0/sales/leagues/${encodeURIComponent(league)}/visiting-teams?limit=50`);
      const rows = d.visiting_teams || [];
      el.visNote.textContent = `${rows.length} away teams`;
      if (!rows.length) { el.visitors.innerHTML = '<div class="empty">no away-team sales</div>'; return; }
      el.visitors.innerHTML =
        '<table class="sales-tbl"><thead><tr>' +
        '<th>#</th><th>VISITING TEAM</th><th class="r">AWAY REVENUE</th>' +
        '<th class="r">AWAY TIX</th><th class="r">AWAY MEDIAN</th></tr></thead><tbody>' +
        rows.map(r => `<tr class="perf-link" data-perf="${esc(r.visiting_performer_id)}" tabindex="0" role="button">` +
          `<td class="muted">${esc(r.rank_by_revenue)}</td>` +
          `<td>${esc(r.visiting_team)}</td>` +
          `<td class="r">${money(r.away_revenue)}</td>` +
          `<td class="r">${int(r.away_tickets)}</td>` +
          `<td class="r">${price(r.away_median_price)}</td></tr>`).join('') +
        '</tbody></table>';
      el.visitors.querySelectorAll('.perf-link').forEach(tr => {
        const go = () => loadPerformer(tr.dataset.perf);
        tr.addEventListener('click', go);
        tr.addEventListener('keydown', e => { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); go(); } });
      });
    } catch (e) {
      el.visitors.innerHTML = `<div class="empty neg">${esc(e.message)}</div>`;
    }
  }

  // ---------- performer report ----------
  function roleBlock(role, ha, ps, wtd, sections) {
    const rev = role === 'home' ? ha.home_revenue : ha.away_revenue;
    const tix = role === 'home' ? ha.home_tickets : ha.away_tickets;
    const med = role === 'home' ? ha.home_median_price : ha.away_median_price;
    if (rev == null && tix == null) return ''; // home-less club: skip absent role
    const s = ps || {};
    const secRows = (sections || []).filter(x => x.role === role).slice(0, 5);
    return `<div class="role-block">
      <div class="panel-title small"><span>${role.toUpperCase()}</span></div>
      <div class="kpi-strip">
        ${kpi('Revenue', money(rev))}
        ${kpi('Tickets', int(tix))}
        ${kpi('Median (per-sale)', price(med))}
        ${kpi('Wtd median', price(wtd))}
        ${kpi('P25 · P75', s.p25 != null ? price(s.p25) + ' · ' + price(s.p75) : '—', true)}
        ${kpi('Max', price(s.max_price), true)}
      </div>
      ${secRows.length ? `<table class="sales-tbl compact"><thead><tr>
        <th>TOP SECTION</th><th class="r">TIX</th><th class="r">REVENUE</th></tr></thead><tbody>` +
        secRows.map(x => `<tr><td>${esc(x.section)}</td><td class="r">${int(x.tickets)}</td>` +
          `<td class="r">${money(x.revenue)}</td></tr>`).join('') +
        '</tbody></table>' : '<div class="muted small">no sectioned sales</div>'}
    </div>`;
  }

  async function loadPerformer(pid) {
    pid = parseInt(pid, 10);
    if (!Number.isFinite(pid) || pid <= 0) return;
    el.perfInput.value = pid;
    el.performer.innerHTML = '<div class="empty">loading…</div>';
    // Reflect in URL so the report is shareable/bookmarkable.
    try {
      const u = new URL(window.location.href);
      u.searchParams.set('performer', pid);
      window.history.replaceState(null, '', u);
    } catch (_) {}
    try {
      const [hdr, src, secs] = await Promise.all([
        T.api(`/api/d0/sales/performers/${pid}`),
        T.api(`/api/d0/sales/performers/${pid}/by-source`).catch(() => ({ by_source: [] })),
        T.api(`/api/d0/sales/performers/${pid}/sections?top5=true`).catch(() => ({ sections: [] })),
      ]);
      const ha = hdr.home_away || {};
      const ps = hdr.price_stats || {};
      const wtd = hdr.weighted || {};
      const sections = secs.sections || [];
      const bySource = (src.by_source || []);
      const totalRev = num(ha.total_revenue);

      const srcRows = bySource.length ? `<table class="sales-tbl compact"><thead><tr>
        <th>SOURCE</th><th>ROLE</th><th>OWNED?</th><th class="r">TIX</th><th class="r">REVENUE</th>
        </tr></thead><tbody>` + bySource.map(r =>
          `<tr><td>${esc(r.source)}</td><td class="muted">${esc(r.role)}</td>` +
          `<td>${r.is_owned ? '<span class="pos">owned</span>' : '<span class="muted">market</span>'}</td>` +
          `<td class="r">${int(r.tickets)}</td><td class="r">${money(r.revenue)}</td></tr>`).join('') +
        '</tbody></table>' : '';

      el.performer.innerHTML =
        `<div class="panel-title row"><span>${esc(hdr.performer_name || 'performer ' + pid)} ` +
        `<span class="muted small">${esc(hdr.league || '')} · id ${pid}</span></span>` +
        `<span class="kpi-val">${money(totalRev)} <span class="muted small">total</span></span></div>` +
        '<div class="role-grid">' +
        roleBlock('home', ha, ps.home, wtd.home, sections) +
        roleBlock('away', ha, ps.away, wtd.away, sections) +
        '</div>' +
        (srcRows ? '<div class="panel-title small"><span>BY SOURCE — OWNED vs MARKET</span></div>' + srcRows : '');
    } catch (e) {
      const msg = /404/.test(e.message) ? `no sales for performer ${pid}` : e.message;
      el.performer.innerHTML = `<div class="empty neg">${esc(msg)}</div>`;
    }
  }

  // ---------- init ----------
  el.perfForm.addEventListener('submit', e => { e.preventDefault(); loadPerformer(el.perfInput.value); });

  loadHealth();
  loadLeagues();
  const initPerf = new URLSearchParams(window.location.search).get('performer');
  if (initPerf) loadPerformer(initPerf);
})();

// D0 Terminal — Racing page (RACING nav tab).
//
// Series calendar + driver championship standings for F1 + NASCAR Cup/Xfinity/
// Truck, backed by two SECDEF RPCs over the espn-racing pipeline:
//   get_espn_racing_events(series)     -> race schedule (espn_racing_events)
//   get_espn_racing_standings(series)  -> driver standings (espn_racing_standings)
// Series is chosen by the button row (default NASCAR Cup) and mirrored to
// ?series= in the URL.

(function () {
  'use strict';
  const T = window.Terminal;
  const escapeHtml = window.TermRender.escapeHtml;

  const SERIES = ['nascar-cup', 'nascar-xfinity', 'nascar-truck', 'f1'];
  const LABEL = {
    'nascar-cup': 'NASCAR Cup', 'nascar-xfinity': 'Xfinity',
    'nascar-truck': 'Truck', 'f1': 'Formula 1',
  };

  function currentSeries() {
    const q = (new URLSearchParams(location.search).get('series') || '').trim();
    return SERIES.includes(q) ? q : 'nascar-cup';
  }

  async function init() {
    if (window.TerminalAuth) await window.TerminalAuth.requireAuth();
    const Auth = window.TerminalAuth;
    if (!Auth || !Auth.client || !Auth.getAccessToken()) {
      document.getElementById('raceSchedBody').innerHTML =
        '<div class="empty">racing needs auth — sign in with @s4kent.com</div>';
      document.getElementById('raceStandBody').innerHTML = '';
      T.setStatus('Auth required', 'err');
      return;
    }
    wireSeriesButtons();
    return loadSeries(currentSeries());
  }

  function wireSeriesButtons() {
    document.querySelectorAll('.race-tab').forEach(btn => {
      btn.addEventListener('click', () => {
        const s = btn.dataset.series;
        const url = new URL(location.href);
        url.searchParams.set('series', s);
        history.replaceState(null, '', url);
        loadSeries(s);
      });
    });
  }

  function markActive(series) {
    document.querySelectorAll('.race-tab').forEach(b =>
      b.classList.toggle('active', b.dataset.series === series));
  }

  async function loadSeries(series) {
    markActive(series);
    T.setStatus('Loading ' + (LABEL[series] || series) + '…');
    document.getElementById('raceSchedBody').innerHTML = '<div class="empty">loading…</div>';
    document.getElementById('raceStandBody').innerHTML = '<div class="empty">loading…</div>';
    const Auth = window.TerminalAuth;
    const [ev, st] = await Promise.all([
      Auth.client.rpc('get_espn_racing_events', { p_series: series, p_limit: 60 }),
      Auth.client.rpc('get_espn_racing_standings', { p_series: series, p_limit: 60 }),
    ]);
    if (ev.error) { T.setStatus(ev.error.message, 'err'); }
    else renderSchedule(ev.data || []);
    if (st.error) { T.setStatus(st.error.message, 'err'); }
    else renderStandings(st.data || []);
    if (!ev.error && !st.error) T.setStatus('Loaded', 'ok');
  }

  function renderSchedule(races) {
    const body = document.getElementById('raceSchedBody');
    const meta = document.getElementById('raceSchedMeta');
    if (!races.length) { body.innerHTML = '<div class="empty">no races on file</div>'; if (meta) meta.textContent = ''; return; }
    const done = races.filter(r => r.completed).length;
    if (meta) meta.textContent = `${races.length} races · ${done} run`;
    // Split: upcoming (soonest first) then completed (most recent first). RPC
    // returns date DESC; find the next-up race to anchor the visual divider.
    const rows = races.map(r => {
      const st = raceStatus(r);
      return `<tr class="${r.completed ? 'race-done' : ''}">
        <td class="muted">${r.event_date ? T.fmtDate(r.event_date) : '—'}</td>
        <td>${escapeHtml(r.short_name || r.name || '—')}</td>
        <td>${st}</td>
        <td class="muted small">${escapeHtml(r.venue || '')}</td>
      </tr>`;
    }).join('');
    body.innerHTML = `<div style="overflow-x:auto"><table class="espn-recent race-tbl">
      <thead><tr><th>Date</th><th>Race</th><th>Status</th><th>Track</th></tr></thead>
      <tbody>${rows}</tbody></table></div>`;
  }

  function raceStatus(r) {
    if (r.completed || r.status_state === 'post') return '<span class="race-badge done">FINAL</span>';
    if (r.status_state === 'in') return '<span class="race-badge live">LIVE</span>';
    return '<span class="race-badge sched">SCHED</span>';
  }

  function renderStandings(rows) {
    const body = document.getElementById('raceStandBody');
    const meta = document.getElementById('raceStandMeta');
    if (!rows.length) { body.innerHTML = '<div class="empty">no standings yet</div>'; if (meta) meta.textContent = ''; return; }
    if (meta) meta.textContent = `${rows.length} drivers`;
    const trs = rows.map(d => `<tr>
      <td class="num muted">${d.rank ?? '—'}</td>
      <td>${escapeHtml(d.driver_name || '—')}${d.driver_abbr ? ` <span class="muted small">${escapeHtml(d.driver_abbr)}</span>` : ''}</td>
      <td class="muted small">${escapeHtml(d.country || '')}</td>
      <td class="num">${d.points != null ? T.fmtNum(d.points) : '—'}</td>
      <td class="num">${d.wins ?? 0}</td>
    </tr>`).join('');
    body.innerHTML = `<div style="overflow-x:auto"><table class="espn-recent race-tbl">
      <thead><tr><th>#</th><th>Driver</th><th>Country</th><th>Pts</th><th>W</th></tr></thead>
      <tbody>${trs}</tbody></table></div>`;
  }

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', init);
  else init();
})();

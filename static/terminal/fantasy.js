// D0 Terminal — Fantasy page (FANTASY nav tab).
//
// A read-first browser over the fantasy engine (migs 070000/130000/150000):
//   get_fantasy_leagues()                 -> league selector
//   get_fantasy_league_detail(league_id)  -> standings + teams/rosters + window pts
//   fantasy_create_demo_league(league)    -> one-click: create + draft + score
// Rosters link starters/bench to the player detail page. Scoring uses each
// team's STARTERS over the league's detail window (trailing 30d by default).

(function () {
  'use strict';
  const T = window.Terminal;
  const escapeHtml = window.TermRender.escapeHtml;

  let leagues = [];
  let selectedId = null;

  function auth() { return window.TerminalAuth; }
  function authed() {
    const A = auth();
    return A && A.client && A.getAccessToken();
  }

  async function init() {
    if (auth()) await auth().requireAuth();
    if (!authed()) {
      document.getElementById('fan-empty').removeAttribute('hidden');
      document.getElementById('fan-empty').innerHTML =
        '<div class="empty">fantasy needs auth — sign in with @s4kent.com</div>';
      T.setStatus('Auth required', 'err');
      return;
    }
    document.getElementById('fanNewDemo').addEventListener('click', createDemo);
    return loadLeagues();
  }

  async function loadLeagues(preferId) {
    T.setStatus('Loading leagues…');
    const res = await auth().client.rpc('get_fantasy_leagues');
    if (res.error) { T.setStatus(res.error.message, 'err'); return; }
    leagues = res.data || [];
    renderLeagueTabs();
    if (!leagues.length) {
      document.getElementById('fan-empty').removeAttribute('hidden');
      document.getElementById('fan-detail').setAttribute('hidden', '');
      T.setStatus('No leagues', 'ok');
      return;
    }
    document.getElementById('fan-empty').setAttribute('hidden', '');
    const pick = (preferId && leagues.some(l => l.id === preferId)) ? preferId : leagues[0].id;
    return loadLeague(pick);
  }

  function renderLeagueTabs() {
    const host = document.getElementById('fanLeagues');
    if (!leagues.length) { host.innerHTML = ''; return; }
    host.innerHTML = leagues.map(l =>
      `<button class="fan-league-tab" data-id="${l.id}">${escapeHtml(l.name)} <span class="muted small">${escapeHtml(l.espn_league || '')} · ${l.team_count}t</span></button>`
    ).join('');
    host.querySelectorAll('.fan-league-tab').forEach(b =>
      b.addEventListener('click', () => loadLeague(Number(b.dataset.id))));
  }

  function markActive() {
    document.querySelectorAll('.fan-league-tab').forEach(b =>
      b.classList.toggle('active', Number(b.dataset.id) === selectedId));
  }

  async function loadLeague(id) {
    selectedId = id;
    markActive();
    document.getElementById('fan-detail').removeAttribute('hidden');
    document.getElementById('fanStandBody').innerHTML = '<div class="empty">loading…</div>';
    document.getElementById('fanTeamsBody').innerHTML = '<div class="empty">loading…</div>';
    T.setStatus('Loading league…');
    const res = await auth().client.rpc('get_fantasy_league_detail', { p_league_id: id });
    if (res.error) { T.setStatus(res.error.message, 'err'); return; }
    const d = res.data || {};
    if (d.hidden) { T.setStatus('League not found', 'err'); return; }
    T.setStatus('Loaded', 'ok');
    renderStandings(d.standings || [], d.window || {});
    renderTeams(d.teams || [], d.league || {}, d.window || {});
  }

  function renderStandings(rows, win) {
    const body = document.getElementById('fanStandBody');
    const meta = document.getElementById('fanStandMeta');
    if (meta) meta.textContent = win.start ? `since ${win.start}` : '';
    if (!rows.length) { body.innerHTML = '<div class="empty">no standings yet</div>'; return; }
    const played = rows.some(r => (r.wins + r.losses + r.ties) > 0);
    if (!played) { body.innerHTML = '<div class="empty">teams drafted — no matchups scored yet</div>'; return; }
    const trs = rows.map((r, i) => `<tr>
      <td class="num muted">${i + 1}</td>
      <td>${escapeHtml(r.team_name || '—')}</td>
      <td class="num">${r.wins}-${r.losses}${r.ties ? '-' + r.ties : ''}</td>
      <td class="num">${T.fmtNum(r.points_for)}</td>
      <td class="num muted">${T.fmtNum(r.points_against)}</td>
    </tr>`).join('');
    body.innerHTML = `<div style="overflow-x:auto"><table class="espn-recent race-tbl">
      <thead><tr><th>#</th><th>Team</th><th>Rec</th><th>PF</th><th>PA</th></tr></thead>
      <tbody>${trs}</tbody></table></div>`;
  }

  function renderTeams(teams, league, win) {
    const body = document.getElementById('fanTeamsBody');
    const meta = document.getElementById('fanTeamsMeta');
    const lg = league.espn_league || '';
    if (meta) meta.textContent = league.ruleset ? `${escapeHtml(league.ruleset)}` : '';
    if (!teams.length) { body.innerHTML = '<div class="empty">no teams</div>'; return; }
    body.innerHTML = teams.map(t => {
      const roster = (t.roster || []).map(p => {
        const href = `player.html?player=${encodeURIComponent(p.espn_athlete_id)}&league=${encodeURIComponent(lg)}`;
        const starter = p.slot === 'starter';
        return `<a class="fan-player ${starter ? 'starter' : 'bench'}" href="${href}">
          <span class="fan-slot">${starter ? 'ST' : 'BN'}</span>
          <span class="fan-pname">${escapeHtml(p.name || p.espn_athlete_id)}</span>
          <span class="muted small">${escapeHtml(p.position || '')}</span>
        </a>`;
      }).join('');
      return `<div class="fan-team">
        <div class="fan-team-head">
          <span class="fan-team-name">${escapeHtml(t.team_name || '—')}</span>
          <span class="fan-pts" title="starter points over ${escapeHtml(String(win.start || ''))}–${escapeHtml(String(win.end || ''))}">${T.fmtNum(t.window_points || 0)} pts</span>
        </div>
        <div class="fan-roster">${roster || '<span class="muted small">empty roster</span>'}</div>
      </div>`;
    }).join('');
  }

  async function createDemo() {
    const btn = document.getElementById('fanNewDemo');
    const lg = document.getElementById('fanDemoLeague').value || 'NBA';
    btn.disabled = true;
    const prev = btn.textContent;
    btn.textContent = 'Building…';
    T.setStatus('Creating demo league (draft + score)…');
    const res = await auth().client.rpc('fantasy_create_demo_league', { p_league: lg });
    btn.disabled = false;
    btn.textContent = prev;
    if (res.error) { T.setStatus(res.error.message, 'err'); return; }
    const d = res.data || {};
    if (d.ok === false) { T.setStatus('Demo failed: ' + (d.error || 'unknown'), 'err'); return; }
    T.setStatus(`Demo league built — ${d.drafted} drafted`, 'ok');
    return loadLeagues(d.league_id);
  }

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', init);
  else init();
})();

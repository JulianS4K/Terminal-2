// D5 Fantasy — standalone surface (spun off from the D0 terminal FANTASY tab).
// Served at /fantasy/ under the hub shell; reuses the terminal's shared libs
// (supabase/render/app/auth) but not nav.js. Roster links point back to the
// terminal player page (/terminal/player.html) — connections kept intact.
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
  let detail = null;         // last league detail (for re-render without refetch)
  let manageTeamId = null;   // team whose roster is being edited (null = view-only)
  let faTimer = null;

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
    document.getElementById('fanAdvance').addEventListener('click', advanceWeek);
    document.getElementById('fanManage').addEventListener('change', onManageChange);
    document.getElementById('fanFaSearch').addEventListener('input', () => {
      clearTimeout(faTimer);
      faTimer = setTimeout(loadFreeAgents, 250);
    });
    const pref = Number(new URLSearchParams(location.search).get('league')) || null;
    return loadLeagues(pref);
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
    document.getElementById('fanAdvance').removeAttribute('hidden');
    document.getElementById('fan-detail').removeAttribute('hidden');
    document.getElementById('fanStandBody').innerHTML = '<div class="empty">loading…</div>';
    document.getElementById('fanTeamsBody').innerHTML = '<div class="empty">loading…</div>';
    T.setStatus('Loading league…');
    const res = await auth().client.rpc('get_fantasy_league_detail', { p_league_id: id });
    if (res.error) { T.setStatus(res.error.message, 'err'); return; }
    const d = res.data || {};
    if (d.hidden) { T.setStatus('League not found', 'err'); return; }
    T.setStatus('Loaded', 'ok');
    detail = d;
    if (manageTeamId != null && !(d.teams || []).some(t => t.id === manageTeamId)) manageTeamId = null;
    renderDetail();
    populateManage(d.teams || []);
  }

  function renderDetail() {
    if (!detail) return;
    renderStandings(detail.standings || [], detail.window || {});
    renderTeams(detail.teams || [], detail.league || {}, detail.window || {});
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
      const managing = t.id === manageTeamId;
      const roster = (t.roster || []).map(p => {
        const id = p.espn_athlete_id;
        const href = `/terminal/player.html?player=${encodeURIComponent(id)}&league=${encodeURIComponent(lg)}`;
        const starter = p.slot !== 'bench';
        const slotLabel = starter ? p.slot : 'BN';
        let ctrls = '';
        if (managing) {
          const toggle = starter
            ? `<button class="fan-lineup" data-bench="${escapeHtml(id)}" title="Move to bench">↓</button>`
            : `<button class="fan-lineup" data-start="${escapeHtml(id)}" title="Move to starting lineup">↑</button>`;
          ctrls = toggle + `<button class="fan-drop" data-drop="${escapeHtml(id)}" title="Drop">✕</button>`;
        }
        return `<span class="fan-player-wrap"><a class="fan-player ${starter ? 'starter' : 'bench'}" href="${href}">
          <span class="fan-slot">${escapeHtml(slotLabel)}</span>
          <span class="fan-pname">${escapeHtml(p.name || id)}</span>
          <span class="muted small">${escapeHtml(p.position || '')}</span>
        </a>${ctrls}</span>`;
      }).join('');
      return `<div class="fan-team${managing ? ' managing' : ''}">
        <div class="fan-team-head">
          <span class="fan-team-name">${escapeHtml(t.team_name || '—')}</span>
          <span class="fan-pts" title="starter points over ${escapeHtml(String(win.start || ''))}–${escapeHtml(String(win.end || ''))}">${T.fmtNum(t.window_points || 0)} pts</span>
        </div>
        <div class="fan-roster">${roster || '<span class="muted small">empty roster</span>'}</div>
      </div>`;
    }).join('');
    // Wire manage controls for the managed team.
    body.querySelectorAll('.fan-drop').forEach(b =>
      b.addEventListener('click', () => rosterMove('drop', b.dataset.drop)));
    body.querySelectorAll('.fan-lineup[data-start]').forEach(b =>
      b.addEventListener('click', () => lineupMove('start', b.dataset.start)));
    body.querySelectorAll('.fan-lineup[data-bench]').forEach(b =>
      b.addEventListener('click', () => lineupMove('bench', b.dataset.bench)));
  }

  async function lineupMove(action, athleteId) {
    if (manageTeamId == null) return;
    const fn = action === 'start' ? 'fantasy_start_player' : 'fantasy_bench_player';
    T.setStatus(action === 'start' ? 'Starting…' : 'Benching…');
    const res = await auth().client.rpc(fn, { p_team_id: manageTeamId, p_athlete_id: athleteId });
    if (res.error) { T.setStatus(res.error.message, 'err'); return; }
    const d = res.data || {};
    if (d.ok === false) {
      T.setStatus(d.error === 'no_open_slot'
        ? `No open ${d.position || ''} slot — bench a starter first` : ('Move failed: ' + (d.error || 'unknown')), 'err');
      return;
    }
    T.setStatus(action === 'start' ? `Started (${d.slot})` : 'Benched', 'ok');
    await loadLeague(selectedId);
  }

  // ---- roster management (add/drop free agents) ----
  function populateManage(teams) {
    const sel = document.getElementById('fanManage');
    sel.innerHTML = '<option value="">Manage: view-only</option>' +
      teams.map(t => `<option value="${t.id}">Manage: ${escapeHtml(t.team_name || ('#' + t.id))}</option>`).join('');
    sel.value = manageTeamId != null ? String(manageTeamId) : '';
    sel.removeAttribute('hidden');
  }

  function onManageChange() {
    const v = document.getElementById('fanManage').value;
    manageTeamId = v ? Number(v) : null;
    const fa = document.getElementById('fan-freeagents');
    if (manageTeamId == null) { fa.setAttribute('hidden', ''); renderDetail(); return; }
    fa.removeAttribute('hidden');
    const team = (detail.teams || []).find(t => t.id === manageTeamId);
    document.getElementById('fanFaTeam').textContent = team ? '→ ' + (team.team_name || '') : '';
    renderDetail();
    loadFreeAgents();
  }

  async function loadFreeAgents() {
    if (manageTeamId == null) return;
    const search = document.getElementById('fanFaSearch').value.trim();
    const body = document.getElementById('fanFaBody');
    body.innerHTML = '<div class="empty">loading…</div>';
    const res = await auth().client.rpc('get_fantasy_free_agents',
      { p_league_id: selectedId, p_search: search || null, p_limit: 60 });
    if (res.error) { body.innerHTML = `<div class="empty">${escapeHtml(res.error.message)}</div>`; return; }
    const rows = res.data || [];
    if (!rows.length) { body.innerHTML = '<div class="empty">no available players</div>'; return; }
    body.innerHTML = `<div class="fan-fa-list">` + rows.map(p =>
      `<div class="fan-fa-row">
        <button class="fan-add" data-add="${escapeHtml(p.espn_athlete_id)}" title="Add to bench">+</button>
        <span class="fan-fa-name">${escapeHtml(p.full_name || p.espn_athlete_id)}</span>
        <span class="muted small">${escapeHtml(p.position || '')}${p.team_abbr ? ' · ' + escapeHtml(p.team_abbr) : ''}</span>
      </div>`).join('') + `</div>`;
    body.querySelectorAll('.fan-add').forEach(b =>
      b.addEventListener('click', () => rosterMove('add', b.dataset.add)));
  }

  async function rosterMove(action, athleteId) {
    if (manageTeamId == null) return;
    T.setStatus(action === 'add' ? 'Adding…' : 'Dropping…');
    const res = await auth().client.rpc('fantasy_roster_move',
      { p_team_id: manageTeamId, p_athlete_id: athleteId, p_action: action, p_slot: 'bench' });
    if (res.error) { T.setStatus(res.error.message, 'err'); return; }
    const d = res.data || {};
    if (d.ok === false) { T.setStatus('Move failed: ' + (d.error || 'unknown'), 'err'); return; }
    T.setStatus(action === 'add' ? 'Added' : 'Dropped', 'ok');
    await loadLeague(selectedId);   // refresh rosters + standings window pts
    loadFreeAgents();
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

  async function advanceWeek() {
    if (!selectedId) return;
    const btn = document.getElementById('fanAdvance');
    btn.disabled = true;
    const prev = btn.textContent;
    btn.textContent = 'Scoring…';
    T.setStatus('Scheduling + scoring next week…');
    const res = await auth().client.rpc('fantasy_advance_week', { p_league_id: selectedId });
    btn.disabled = false;
    btn.textContent = prev;
    if (res.error) { T.setStatus(res.error.message, 'err'); return; }
    const d = res.data || {};
    if (d.ok === false) { T.setStatus('Advance failed: ' + (d.error || 'unknown'), 'err'); return; }
    if (d.done) { T.setStatus('Season complete — no more game data', 'ok'); return; }
    T.setStatus(`Week ${d.week} scored (${d.matchups} matchups)`, 'ok');
    return loadLeague(selectedId);
  }

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', init);
  else init();
})();

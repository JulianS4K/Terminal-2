// D0 Terminal — Fantasy League surface.
//
// Reads go through Terminal.api('/api/fantasy/...') (FastAPI, service_role,
// global/aggregate views). User-scoped WRITES go through
// TerminalAuth.client.rpc('fantasy_*', {...}) — the only path where auth.uid()
// resolves (mirrors nav.js / alerts.js). No inline scripts (CSP script-src 'self').

(function () {
  'use strict';

  const T = window.Terminal;
  const Auth = window.TerminalAuth;
  const $ = (id) => document.getElementById(id);
  const esc = (s) => String(s == null ? '' : s).replace(/[&<>"']/g,
    (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  const num = (v) => (v == null ? '—' : (Math.round(Number(v) * 10) / 10).toLocaleString());

  function leagueIdFromUrl() {
    return new URLSearchParams(location.search).get('league');
  }
  function gotoLeague(id) { location.href = 'fantasy.html?league=' + encodeURIComponent(id); }

  async function rpc(fn, args) {
    const { data, error } = await Auth.client.rpc(fn, args);
    if (error) throw new Error(error.message || String(error));
    return data;
  }

  // ---------------- Lobby ----------------
  async function renderLobby() {
    $('fl-lobby').hidden = false;
    T.setStatus('Fantasy — lobby');
    bindLobbyForms();
    await loadMyLeagues();
  }

  async function loadMyLeagues() {
    const box = $('fl-mine');
    try {
      const leagues = await rpc('fantasy_my_leagues', {});
      if (!leagues || !leagues.length) {
        box.innerHTML = '<div class="empty">No leagues yet — create or join one above.</div>';
        return;
      }
      box.innerHTML = leagues.map((l) => `
        <div class="fl-card" data-go="${esc(l.league_id)}">
          <h3>${esc(l.name)}<span class="fl-pill">${esc(l.espn_league)}</span></h3>
          <div class="meta">${esc(l.team_name)} · ${esc(l.role)} · ${esc(l.status)}
            · ${esc(l.member_count)} mgr${l.member_count == 1 ? '' : 's'}</div>
          ${l.status === 'forming' ? `<div class="meta">code <b>${esc(l.join_code)}</b></div>` : ''}
        </div>`).join('');
      box.querySelectorAll('[data-go]').forEach((el) =>
        el.addEventListener('click', () => gotoLeague(el.dataset.go)));
    } catch (e) {
      box.innerHTML = `<div class="empty">load failed — ${esc(e.message)}</div>`;
    }
  }

  function bindLobbyForms() {
    $('fl-create').addEventListener('submit', async (ev) => {
      ev.preventDefault();
      const f = ev.target;
      try {
        T.setStatus('Creating…');
        const league = await rpc('fantasy_create_league', {
          p_name: f.name.value.trim(),
          p_espn_league: f.espn_league.value,
          p_team_name: f.team_name.value.trim(),
        });
        gotoLeague(league.id);
      } catch (e) { T.setStatus('Create failed — ' + e.message, 'bad'); }
    });
    $('fl-join').addEventListener('submit', async (ev) => {
      ev.preventDefault();
      const f = ev.target;
      try {
        T.setStatus('Joining…');
        const m = await rpc('fantasy_join_league', {
          p_join_code: f.join_code.value.trim(),
          p_team_name: f.team_name.value.trim(),
        });
        gotoLeague(m.league_id);
      } catch (e) { T.setStatus('Join failed — ' + e.message, 'bad'); }
    });
  }

  // ---------------- League view ----------------
  let LEAGUE = null;      // {league, members}
  let MEMBERS = {};       // membership_id -> member

  async function renderLeague(id) {
    $('fl-league').hidden = false;
    try {
      LEAGUE = await T.api('/api/fantasy/leagues/' + id);
    } catch (e) {
      T.setStatus('League load failed — ' + e.message, 'bad');
      return;
    }
    MEMBERS = {};
    (LEAGUE.members || []).forEach((m) => { MEMBERS[m.id] = m; });
    const l = LEAGUE.league;
    $('fl-title').textContent = l.name;
    $('fl-sub').textContent = `${l.espn_league} · ${l.status} · ${LEAGUE.members.length} managers`;
    if (l.status === 'forming') {
      const h = $('fl-join-hint');
      h.hidden = false;
      h.innerHTML = `Share join code <b>${esc(l.join_code)}</b> · the commissioner starts the draft once everyone's in.`;
    }
    bindTabs(id);
    await renderDraft(id);   // default tab
  }

  function bindTabs(id) {
    const tabs = $('fl-tabs');
    tabs.querySelectorAll('.event-tab').forEach((btn) => {
      btn.addEventListener('click', () => {
        tabs.querySelectorAll('.event-tab').forEach((b) => b.classList.remove('active'));
        btn.classList.add('active');
        const tab = btn.dataset.tab;
        ['draft', 'rosters', 'standings', 'scores'].forEach((t) => {
          $('fl-pane-' + t).hidden = (t !== tab);
        });
        if (tab === 'draft') renderDraft(id);
        else if (tab === 'rosters') renderRosters(id);
        else if (tab === 'standings') renderStandings(id);
        else if (tab === 'scores') renderScores(id);
      });
    });
  }

  // ---------------- Draft ----------------
  async function renderDraft(id) {
    const l = LEAGUE.league;
    const me = LEAGUE.members.find((m) => m.user_id === (Auth.getSession() && Auth.getSession().user.id));
    const startBtn = $('fl-startdraft');
    startBtn.hidden = !(l.status === 'forming' && me && me.role === 'commissioner');
    startBtn.onclick = async () => {
      try { await rpc('fantasy_start_draft', { p_league_id: id }); location.reload(); }
      catch (e) { T.setStatus('Start failed — ' + e.message, 'bad'); }
    };

    let state;
    try { state = await T.api('/api/fantasy/leagues/' + id + '/draft'); }
    catch (e) { $('fl-board').innerHTML = `<div class="empty">${esc(e.message)}</div>`; return; }

    const d = state.draft;
    const onClock = d && d.status === 'in_progress'
      ? Number(d.pick_order[d.current_pick_no - 1]) : null;
    const myMid = me ? me.id : null;
    const myTurn = onClock && myMid === onClock;
    $('fl-draftstatus').innerHTML = !d ? 'draft not started'
      : d.status === 'complete' ? 'draft complete'
      : `pick #${d.current_pick_no} — ${myTurn ? '<span class="fl-clock">YOUR PICK</span>'
          : 'on the clock: ' + esc((MEMBERS[onClock] || {}).team_name || onClock)}`;

    $('fl-board').innerHTML = (state.picks || []).length
      ? state.picks.map((p) => `<div class="fl-draftpick"><span class="pno">#${p.pick_no}</span>
          <span>${esc((MEMBERS[p.membership_id] || {}).team_name || p.membership_id)}</span>
          <span class="sub">→ ${esc(p.espn_athlete_id)}</span></div>`).join('')
      : '<div class="empty">no picks yet</div>';

    await loadAvailable(id, myTurn);
    const search = $('fl-search');
    search.oninput = debounce(() => loadAvailable(id, myTurn), 250);
  }

  async function loadAvailable(id, myTurn) {
    const q = $('fl-search').value.trim();
    const box = $('fl-available');
    try {
      const res = await T.api('/api/fantasy/available?league_id=' + encodeURIComponent(id)
        + (q ? '&q=' + encodeURIComponent(q) : '') + '&limit=40');
      const players = res.players || [];
      box.innerHTML = players.length ? players.map((p) => `
        <div class="fl-row">
          <span class="name">${esc(p.full_name)}</span>
          <span class="sub">${esc(p.position_abbr || '')}</span>
          ${myTurn ? `<button class="event-tab" data-pick="${esc(p.espn_athlete_id)}"
             data-slot="${esc(p.position_abbr || 'BENCH')}" style="margin-left:auto;padding:3px 9px;">draft</button>` : ''}
        </div>`).join('') : '<div class="empty">none available</div>';
      box.querySelectorAll('[data-pick]').forEach((btn) => btn.addEventListener('click', async () => {
        try {
          await rpc('fantasy_make_pick', {
            p_league_id: id, p_espn_athlete_id: btn.dataset.pick, p_slot: btn.dataset.slot,
          });
          await renderDraft(id);
        } catch (e) {
          // position may not fit its natural slot → retry onto the bench
          if (/not eligible/.test(e.message)) {
            try { await rpc('fantasy_make_pick', { p_league_id: id, p_espn_athlete_id: btn.dataset.pick, p_slot: 'BENCH' });
                  await renderDraft(id); return; } catch (_) {}
          }
          T.setStatus('Pick failed — ' + e.message, 'bad');
        }
      }));
    } catch (e) { box.innerHTML = `<div class="empty">${esc(e.message)}</div>`; }
  }

  // ---------------- Rosters ----------------
  async function renderRosters(id) {
    const box = $('fl-rosters');
    try {
      const res = await T.api('/api/fantasy/leagues/' + id + '/rosters');
      box.innerHTML = (res.rosters || []).map((r) => {
        const m = MEMBERS[r.membership_id] || {};
        const rows = (r.players || []).map((p) => {
          const a = p.athlete || {};
          const inj = p.injury && p.injury.status && p.injury.status !== 'Active'
            ? ` <span class="fl-out">${esc(p.injury.status)}</span>` : '';
          return `<div class="fl-row"><span class="name">${esc(a.full_name || p.espn_athlete_id)}</span>
            <span class="sub">${esc(p.slot)}${a.position_abbr ? ' · ' + esc(a.position_abbr) : ''}${inj}</span>
            <span class="pts">${p.is_starter ? 'ST' : 'BN'}</span></div>`;
        }).join('') || '<div class="empty">empty roster</div>';
        return `<section style="margin-bottom:18px;"><div class="panel-title">${esc(m.team_name || r.membership_id)}</div>${rows}</section>`;
      }).join('') || '<div class="empty">no rosters yet</div>';
    } catch (e) { box.innerHTML = `<div class="empty">${esc(e.message)}</div>`; }
  }

  // ---------------- Standings ----------------
  async function renderStandings(id) {
    const box = $('fl-standings');
    try {
      const res = await T.api('/api/fantasy/leagues/' + id + '/standings');
      const rows = res.standings || [];
      box.innerHTML = rows.length ? `<table class="fl-tbl"><thead><tr>
        <th>#</th><th>Team</th><th class="num">W</th><th class="num">L</th><th class="num">T</th>
        <th class="num">PF</th><th class="num">PA</th></tr></thead><tbody>${
        rows.map((s) => `<tr><td>${s.rank}</td><td>${esc(s.team_name)}</td>
          <td class="num">${s.wins}</td><td class="num">${s.losses}</td><td class="num">${s.ties}</td>
          <td class="num">${num(s.points_for)}</td><td class="num">${num(s.points_against)}</td></tr>`).join('')
        }</tbody></table>` : '<div class="empty">no results yet — standings populate after the first scored week</div>';
    } catch (e) { box.innerHTML = `<div class="empty">${esc(e.message)}</div>`; }
  }

  // ---------------- Scores ----------------
  async function renderScores(id) {
    const box = $('fl-scores');
    try {
      const res = await T.api('/api/fantasy/leagues/' + id + '/scores');
      if (!res.period) { box.innerHTML = '<div class="empty">no scoring periods yet</div>'; return; }
      const ts = {}; (res.team_scores || []).forEach((t) => { ts[t.membership_id] = t.points; });
      const matchups = (res.matchups || []).map((mt) => {
        const h = MEMBERS[mt.home_membership_id] || {};
        const a = mt.away_membership_id ? (MEMBERS[mt.away_membership_id] || {}) : null;
        const win = mt.winner_membership_id;
        const side = (m, mid, pts) => `<span class="${win === mid ? 'fl-clock' : ''}">${esc((m || {}).team_name || 'BYE')}</span> <b>${num(pts)}</b>`;
        return `<div class="fl-row">${side(h, mt.home_membership_id, mt.home_points)}
          <span class="sub" style="margin:0 8px;">vs</span>
          ${a ? side(a, mt.away_membership_id, mt.away_points) : '<span class="sub">BYE</span>'}</div>`;
      }).join('') || '<div class="empty">no matchups</div>';
      const top = (res.player_scores || []).slice(0, 15).map((p) =>
        `<div class="fl-row"><span class="name">${esc(p.espn_athlete_id)}</span>
          <span class="pts">${num(p.points)}</span></div>`).join('');
      box.innerHTML = `<div class="panel-title">WEEK ${res.period.period_no} · ${esc(res.period.status)}</div>
        ${matchups}<div class="panel-title" style="margin-top:14px;">TOP PERFORMERS</div>${top || '<div class="empty">—</div>'}`;
    } catch (e) { box.innerHTML = `<div class="empty">${esc(e.message)}</div>`; }
  }

  function debounce(fn, ms) {
    let t; return (...a) => { clearTimeout(t); t = setTimeout(() => fn(...a), ms); };
  }

  // ---------------- boot ----------------
  (async function init() {
    try { await Auth.requireAuth(); } catch (_) { return; }   // redirects to login on failure
    const id = leagueIdFromUrl();
    if (id) await renderLeague(id);
    else await renderLobby();
  })();
})();

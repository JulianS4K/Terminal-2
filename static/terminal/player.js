// D0 Terminal — Player detail page.
//
// Reached from a team's ROSTER tab (performer page) or topbar search:
//   player.html?player=<espn_athlete_id>&league=<ESPN league>
// One RPC (get_broker_player_page) returns bio + team + season stats + game log.
//
// Note: espn_athlete_id is TEXT (unlike the bigint performer/venue ids).

(function () {
  'use strict';
  const T = window.Terminal;

  function getParams() {
    const q = new URLSearchParams(location.search);
    const id = (q.get('player') || '').trim();
    const league = (q.get('league') || '').trim();
    return { id: id || null, league: league || null };
  }

  async function init() {
    if (window.TerminalAuth) await window.TerminalAuth.requireAuth();
    const { id, league } = getParams();
    if (!id || !league) {
      document.getElementById('player-empty').removeAttribute('hidden');
      T.setStatus('No player selected', 'ok');
      return;
    }
    return loadPlayer(id, league);
  }

  async function loadPlayer(id, league) {
    T.setStatus('Loading player…');
    const Auth = window.TerminalAuth;
    if (!Auth || !Auth.client || !Auth.getAccessToken()) {
      document.getElementById('player-empty').removeAttribute('hidden');
      document.getElementById('player-empty').innerHTML =
        '<div class="empty">player detail needs auth — sign in with @s4kent.com</div>';
      T.setStatus('Auth required', 'err');
      return;
    }
    const res = await Auth.client.rpc('get_broker_player_page', { p_athlete_id: id, p_league: league });
    if (res.error) { T.setStatus(res.error.message, 'err'); return; }
    const d = res.data || {};
    if (d.hidden) {
      document.getElementById('player-empty').removeAttribute('hidden');
      document.getElementById('player-empty').innerHTML =
        `<div class="empty">no player found (${escapeHtml(d.reason || 'hidden')})</div>`;
      T.setStatus('Not found', 'err');
      return;
    }
    T.setStatus('Loaded', 'ok');
    renderHero(d, league);
    renderSeasonStats(d.season_stats || {});
    renderGameLog(d.recent_games || [], league);
  }

  function renderHero(d, league) {
    const bio = d.bio || {};
    const team = d.team || {};
    document.getElementById('player-hero').removeAttribute('hidden');
    const hero = document.getElementById('plHero');
    if (bio.headshot_url) { hero.src = bio.headshot_url; hero.alt = bio.full_name || ''; }
    else { hero.style.display = 'none'; }
    setText('plName', bio.full_name || '—');
    const teamEl = document.getElementById('plTeam');
    if (teamEl) teamEl.textContent = (team.display_name || bio.espn_team_id || '—') + (league ? ' · ' + league : '');
    setText('plPos', bio.position || bio.position_abbr || '—');
    setText('plJersey', bio.jersey ? '#' + bio.jersey : '—');
    const bits = [];
    if (bio.age != null) bits.push(bio.age + ' yrs');
    if (bio.height_inches) bits.push(Math.floor(bio.height_inches / 12) + "'" + (bio.height_inches % 12) + '"');
    if (bio.weight_lbs) bits.push(bio.weight_lbs + ' lbs');
    if (bio.experience_years != null) bits.push(bio.experience_years + ' yr exp');
    setText('plMeta', bits.join(' · ') || '—');
    setText('plStatus', bio.status || 'active');
  }

  function renderSeasonStats(stats) {
    const host = document.getElementById('player-stats');
    const body = document.getElementById('plStatsBody');
    host.removeAttribute('hidden');
    const cats = Object.keys(stats);
    if (!cats.length) { body.innerHTML = '<div class="empty">no season stats yet</div>'; return; }
    body.innerHTML = cats.map(cat => {
      const s = stats[cat] || {};
      const kv = s.stats || {};
      const cells = Object.keys(kv).map(k =>
        `<div class="ru-cell"><span class="ru-num">${escapeHtml(String(kv[k]))}</span><span class="ru-lbl">${escapeHtml(k)}</span></div>`
      ).join('');
      return `<div class="panel-title" style="margin-top:8px">${escapeHtml(cat.toUpperCase())}${s.season ? ' · ' + s.season : ''}</div>` +
             `<div class="rollup-grid">${cells}</div>`;
    }).join('');
  }

  // Preferred stat-column order for basketball; other leagues fall back to
  // whatever keys the game line carries.
  const GL_ORDER = { NBA: ['MIN','PTS','REB','AST','STL','BLK','TO','FG','3PT','FT'],
                     WNBA: ['MIN','PTS','REB','AST','STL','BLK','TO','FG','3PT','FT'] };

  function renderGameLog(games, league) {
    const host = document.getElementById('player-games');
    const body = document.getElementById('plGamesBody');
    const meta = document.getElementById('plGamesMeta');
    host.removeAttribute('hidden');
    if (!games.length) { body.innerHTML = '<div class="empty">no game log yet (syncing)</div>'; return; }
    if (meta) meta.textContent = `${games.length} games`;
    const first = games[0].stats || {};
    const pref = GL_ORDER[league] || [];
    const cols = pref.filter(k => k in first);
    for (const k of Object.keys(first)) if (!cols.includes(k)) cols.push(k);
    const head = ['Date', '', 'Opp', 'Res', ...cols].map(h => `<th>${escapeHtml(h)}</th>`).join('');
    const rows = games.map(g => {
      const s = g.stats || {};
      const cells = cols.map(k => `<td class="num">${escapeHtml(String(s[k] ?? '—'))}</td>`).join('');
      const res = g.result === 'W' ? '<span class="espn-wl espn-wl-w">W</span>'
        : g.result === 'L' ? '<span class="espn-wl espn-wl-l">L</span>' : '';
      return `<tr>
        <td class="muted">${g.game_date ? T.fmtDate(g.game_date) : '—'}</td>
        <td>${escapeHtml(g.home_away || '')}</td>
        <td>${escapeHtml(g.opponent_abbr || '—')}</td>
        <td>${res}</td>${cells}</tr>`;
    }).join('');
    body.innerHTML = `<div style="overflow-x:auto"><table class="espn-recent">
      <thead><tr>${head}</tr></thead><tbody>${rows}</tbody></table></div>`;
  }

  function setText(id, v) { const el = document.getElementById(id); if (el) el.textContent = v; }

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', init);
  else init();
})();

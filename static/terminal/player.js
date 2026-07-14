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
  // escapeHtml is exposed as window.TermRender.escapeHtml (render.js) — bind it
  // locally like every other terminal page. Without this, bare escapeHtml(...)
  // is a ReferenceError, which threw in renderSeasonStats/renderGameLog for any
  // player that actually HAS stats (e.g. LeBron), leaving the page stuck on
  // "loading…" and blocking the market/buzz panels downstream.
  const escapeHtml = window.TermRender.escapeHtml;

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
    loadPlayerTxns(id, league);
    loadPlayerMarket(id, league);
    loadPlayerNews((d.bio || {}).full_name, league);
    loadPlayerSocial((d.bio || {}).full_name, league);
  }

  // ESPN news mentioning this player (name-filtered over the espn_news wire).
  // Additive: silent if none/unsupported.
  async function loadPlayerNews(name, league) {
    if (!name) return;
    const Auth = window.TerminalAuth;
    const res = await Auth.client.rpc('get_player_espn_news',
      { p_name: name, p_league: league, p_limit: 20 });
    if (res.error) return;
    const items = (res.data || {}).items || [];
    if (!items.length) return;
    document.getElementById('player-news').removeAttribute('hidden');
    const meta = document.getElementById('plNewsMeta');
    if (meta) meta.textContent = `${items.length} stor${items.length === 1 ? 'y' : 'ies'}`;
    document.getElementById('plNewsBody').innerHTML = items.map(it => {
      const img = it.image_url
        ? `<img src="${escapeHtml(it.image_url)}" alt="" loading="lazy" style="width:64px;height:44px;object-fit:cover;border-radius:6px;flex:0 0 auto" />`
        : '';
      const head = it.url
        ? `<a href="${escapeHtml(it.url)}" target="_blank" rel="noopener noreferrer">${escapeHtml(it.headline || '')}</a>`
        : escapeHtml(it.headline || '');
      const summary = it.summary
        ? `<div class="txn-desc muted small">${escapeHtml(it.summary.slice(0, 160))}${it.summary.length > 160 ? '…' : ''}</div>`
        : '';
      return `<div class="txn-row" style="display:flex;gap:10px;align-items:flex-start">
        ${img}
        <div style="flex:1;min-width:0">
          <div class="txn-row-head">
            <span class="txn-team">${head}</span>
            <span class="txn-date muted">${it.published_at ? T.fmtDate(it.published_at) : ''}</span>
          </div>
          ${summary}
        </div>
      </div>`;
    }).join('');
  }

  // Kalshi (etc.) prediction markets about this player — e.g. next-team
  // "transfer" odds. Additive: silent if untracked/unsupported.
  async function loadPlayerMarket(id, league) {
    const Auth = window.TerminalAuth;
    const res = await Auth.client.rpc('get_player_prediction_markets',
      { p_athlete_id: id, p_league: league });
    if (res.error) return;
    const d = res.data || {};
    const cands = d.applicable ? (d.candidates || []) : [];
    if (!cands.length) return;
    document.getElementById('player-market').removeAttribute('hidden');
    const label = d.market_kind === 'next_team' ? 'TRANSFER MARKET · NEXT TEAM' : 'MARKET';
    setText('plMktTitle', label);
    const meta = document.getElementById('plMktMeta');
    if (meta) {
      const src = cands[0] && cands[0].source ? cands[0].source : 'market';
      meta.textContent = src.toUpperCase()
        + (d.close_time ? ' · settles ' + T.fmtDate(d.close_time) : '');
    }
    const max = Math.max(...cands.map(c => Number(c.yes_price) || 0), 0.01);
    document.getElementById('plMktBody').innerHTML = cands.map(c => {
      const pct = Math.round((Number(c.yes_price) || 0) * 100);
      const w = Math.max(2, Math.round(((Number(c.yes_price) || 0) / max) * 100));
      const name = c.dest_performer_id != null
        ? `<a href="performer.html?performer=${encodeURIComponent(c.dest_performer_id)}">${escapeHtml(c.dest_team_name || c.dest_team_token || '—')}</a>`
        : escapeHtml(c.dest_team_name || c.dest_team_token || '—');
      return `<div class="mkt-row" style="display:flex;align-items:center;gap:8px;padding:3px 0">
        <span class="mkt-name" style="flex:0 0 42%;overflow:hidden;text-overflow:ellipsis;white-space:nowrap">${name}</span>
        <span class="mkt-bar" style="flex:1;height:8px;border-radius:4px;background:var(--panel-2,#1a1a1a);overflow:hidden">
          <span style="display:block;height:100%;width:${w}%;background:var(--accent,#4ea1ff)"></span>
        </span>
        <span class="mkt-pct num" style="flex:0 0 44px;text-align:right">${pct}%</span>
      </div>`;
    }).join('') +
      (cands[0] && cands[0].url
        ? `<div class="muted small" style="margin-top:6px"><a href="${escapeHtml(cands[0].url)}" target="_blank" rel="noopener noreferrer">view on source ↗</a></div>`
        : '');
  }

  // Name-scoped social buzz (X + Reddit wire posts mentioning the player).
  async function loadPlayerSocial(name, league) {
    if (!name) return;
    const Auth = window.TerminalAuth;
    const res = await Auth.client.rpc('get_player_social',
      { p_name: name, p_league: league, p_limit: 30 });
    if (res.error) return;
    const items = (res.data || {}).items || [];
    if (!items.length) return;
    document.getElementById('player-social').removeAttribute('hidden');
    const meta = document.getElementById('plSocialMeta');
    if (meta) meta.textContent = `${items.length} post${items.length === 1 ? '' : 's'}`;
    document.getElementById('plSocialBody').innerHTML = items.map(it => {
      const head = it.url
        ? `<a href="${escapeHtml(it.url)}" target="_blank" rel="noopener noreferrer">${escapeHtml(it.handle || it.source)}</a>`
        : `<span>${escapeHtml(it.handle || it.source)}</span>`;
      return `<div class="txn-row">
        <div class="txn-row-head">
          <span class="badge">${escapeHtml(it.source || '')}</span>
          <span class="txn-team">${head}</span>
          <span class="txn-date muted">${it.published_at ? T.fmtDate(it.published_at) : ''}</span>
        </div>
        <div class="txn-desc">${escapeHtml(it.title || '')}</div>
      </div>`;
    }).join('');
  }

  // Recent ESPN transactions mentioning this player (name-matched, league-scoped)
  // — see get_espn_player_transactions. Best-effort: silent if none/unsupported.
  async function loadPlayerTxns(id, league) {
    const Auth = window.TerminalAuth;
    const res = await Auth.client.rpc('get_espn_player_transactions',
      { p_athlete_id: id, p_league: league, p_limit: 20 });
    if (res.error) return;   // block is additive; don't disrupt the page on error
    const rows = res.data || [];
    if (!rows.length) return;
    document.getElementById('player-txns').removeAttribute('hidden');
    const meta = document.getElementById('plTxnMeta');
    if (meta) meta.textContent = `${rows.length} move${rows.length === 1 ? '' : 's'}`;
    document.getElementById('plTxnBody').innerHTML = rows.map(r => {
      const team = r.tevo_performer_id != null
        ? `<a class="txn-team" href="performer.html?performer=${encodeURIComponent(r.tevo_performer_id)}">${escapeHtml(r.team || '—')}</a>`
        : `<span class="txn-team">${escapeHtml(r.team || '—')}</span>`;
      return `<div class="txn-row">
        <div class="txn-row-head">
          <span class="txn-date muted">${r.txn_date ? T.fmtDate(r.txn_date) : '—'}</span>
          ${team}
        </div>
        <div class="txn-desc">${escapeHtml(r.description || '')}</div>
      </div>`;
    }).join('');
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

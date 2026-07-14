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
    loadPlayerMarket(id, league);
    startPlayerFeed(id, (d.bio || {}).full_name, league);
  }

  // ---- LIVE FEED: one merged stream (ESPN news + Reddit + X + transactions +
  // market pulse), name-scoped, newest-first, auto-refreshing every 30s. ------
  let feedTimer = null;
  function startPlayerFeed(id, name, league) {
    if (!name) return;
    if (feedTimer) { clearInterval(feedTimer); feedTimer = null; }
    loadPlayerFeed(id, name, league);
    // Poll for a live feed; the page is single-view so no teardown needed.
    feedTimer = setInterval(() => loadPlayerFeed(id, name, league), 30000);
  }

  const FEED_BADGE = {
    news: '#2a5db0', reddit: '#d24d1f', x: '#1d9bf0',
    transaction: '#1e7a3a', market: '#6a4ea1'
  };

  async function loadPlayerFeed(id, name, league) {
    const Auth = window.TerminalAuth;
    if (!Auth || !Auth.client || !Auth.getAccessToken()) return;
    const res = await Auth.client.rpc('get_player_feed',
      { p_athlete_id: id, p_name: name, p_league: league, p_window_hours: 72, p_limit: 40 });
    if (res.error) return;   // additive; leave the last good render in place
    const items = (res.data || {}).items || [];
    document.getElementById('player-feed').removeAttribute('hidden');
    const meta = document.getElementById('plFeedMeta');
    if (meta) meta.textContent = `${items.length} · updated ${new Date().toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })}`;
    const body = document.getElementById('plFeedBody');
    if (!items.length) { body.innerHTML = '<div class="empty">no recent activity</div>'; return; }
    body.innerHTML = items.map(it => {
      const color = FEED_BADGE[it.item_type] || '#333';
      const badge = `<span class="badge" style="background:${color};color:#fff">${escapeHtml(it.source || it.item_type || '')}</span>`;
      const handle = it.handle ? `<span class="muted small">${escapeHtml(it.handle)}</span>` : '';
      const when = it.published_at ? `<span class="txn-date muted">${T.fmtDate(it.published_at)}</span>` : '';
      const title = it.url
        ? `<a href="${escapeHtml(it.url)}" target="_blank" rel="noopener noreferrer">${escapeHtml(it.title || '')}</a>`
        : escapeHtml(it.title || '');
      const img = (it.item_type === 'news' && it.image_url)
        ? `<img src="${escapeHtml(it.image_url)}" alt="" loading="lazy" style="width:58px;height:40px;object-fit:cover;border-radius:6px;flex:0 0 auto" />`
        : '';
      const summary = it.summary
        ? `<div class="txn-desc muted small">${escapeHtml(it.summary.slice(0, 150))}${it.summary.length > 150 ? '…' : ''}</div>`
        : '';
      return `<div class="txn-row" style="display:flex;gap:10px;align-items:flex-start">
        ${img}
        <div style="flex:1;min-width:0">
          <div class="txn-row-head" style="display:flex;gap:6px;align-items:center;flex-wrap:wrap">
            ${badge}${handle}${when}
          </div>
          <div class="txn-team" style="margin-top:2px">${title}</div>
          ${summary}
        </div>
      </div>`;
    }).join('');
  }

  // Kalshi (etc.) prediction markets about this player — e.g. next-team
  // "transfer" odds. Additive: silent if untracked/unsupported.
  // Prediction markets about this player: Kalshi next-team odds + Polymarket
  // markets (next-team + props). Additive: silent if none.
  async function loadPlayerMarket(id, league) {
    const Auth = window.TerminalAuth;
    const res = await Auth.client.rpc('get_player_prediction_markets',
      { p_athlete_id: id, p_league: league });
    if (res.error) return;
    const d = res.data || {};
    const cands = d.applicable ? (d.candidates || []) : [];
    const poly = d.applicable ? (d.polymarket || []) : [];
    if (!cands.length && !poly.length) return;
    document.getElementById('player-market').removeAttribute('hidden');
    setText('plMktTitle', (d.market_kind === 'next_team' || poly.length) ? 'TRANSFER MARKET · NEXT TEAM' : 'MARKET');
    const meta = document.getElementById('plMktMeta');
    if (meta) {
      const srcs = [];
      if (cands.length) srcs.push('Kalshi');
      if (poly.length) srcs.push('Polymarket');
      meta.textContent = srcs.join(' + ') + (d.close_time ? ' · settles ' + T.fmtDate(d.close_time) : '');
    }

    // one implied-probability bar row
    function bar(text, pct, href, external) {
      const p = Math.max(0, Math.min(100, Math.round(Number(pct) || 0)));
      const nm = href
        ? `<a href="${href}"${external ? ' target="_blank" rel="noopener noreferrer"' : ''}>${escapeHtml(text)}</a>`
        : escapeHtml(text);
      return `<div class="mkt-row" style="display:flex;align-items:center;gap:8px;padding:3px 0">
        <span style="flex:0 0 48%;overflow:hidden;text-overflow:ellipsis;white-space:nowrap">${nm}</span>
        <span style="flex:1;height:8px;border-radius:4px;background:var(--panel-2,#1a1a1a);overflow:hidden">
          <span style="display:block;height:100%;width:${Math.max(2, p)}%;background:var(--accent,#4ea1ff)"></span>
        </span>
        <span class="num" style="flex:0 0 44px;text-align:right">${p}%</span>
      </div>`;
    }

    let html = '';
    if (cands.length) {
      html += '<div class="muted small" style="margin:2px 0 1px">Kalshi</div>';
      html += cands.map(c => bar(
        c.dest_team_name || c.dest_team_token || '—',
        (Number(c.yes_price) || 0) * 100,
        c.dest_performer_id != null ? `performer.html?performer=${encodeURIComponent(c.dest_performer_id)}` : null,
        false
      )).join('');
    }
    if (poly.length) {
      html += '<div class="muted small" style="margin:8px 0 1px">Polymarket</div>';
      html += poly.map(m => {
        const lbl = (m.subtitle && m.subtitle.trim())
          ? m.subtitle
          : String(m.question || m.title || '—').replace(/^NBA:\s*/, '');
        const href = /^https?:\/\//i.test(m.url || '') ? escapeHtml(m.url) : null;
        return bar(lbl, (Number(m.yes_price) || 0) * 100, href, true);
      }).join('');
    }
    document.getElementById('plMktBody').innerHTML = html;
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

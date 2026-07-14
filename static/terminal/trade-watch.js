// D0 Terminal — Trade Watch.
//
// "Be the first to know when he trades." One consolidated RPC (get_trade_watch,
// mig 20260714130000) returns, per tracked player: ESPN roster team/status, the
// Kalshi next-team market (leader + candidates), a high-frequency Wikipedia
// team-hint + change flag, and a fused MOVED/WATCHING state.
//
// Tracked players are seeded in player_market_athlete_map (LeBron today; add a
// row per player). Fully auth-gated (@s4kent.com), like the rest of the terminal.

(function () {
  'use strict';
  const T = window.Terminal;
  const escapeHtml = window.TermRender.escapeHtml;

  async function init() {
    if (window.TerminalAuth) await window.TerminalAuth.requireAuth();
    const Auth = window.TerminalAuth;
    if (!Auth || !Auth.client || !Auth.getAccessToken()) {
      showEmpty('trade watch needs auth — sign in with @s4kent.com', 'err');
      return;
    }
    T.setStatus('Loading trade watch…');
    const res = await Auth.client.rpc('get_trade_watch');
    if (res.error) { showEmpty(escapeHtml(res.error.message), 'err'); return; }
    const players = (res.data || {}).players || [];
    if (!players.length) {
      showEmpty('no tracked players yet — seed player_market_athlete_map', 'ok');
      return;
    }
    T.setStatus('Loaded', 'ok');
    const meta = document.getElementById('twMeta');
    if (meta) meta.textContent = `${players.length} tracked`;
    document.getElementById('tw-body').innerHTML = players.map(renderCard).join('');
  }

  function showEmpty(html, kind) {
    const el = document.getElementById('tw-empty');
    el.removeAttribute('hidden');
    el.innerHTML = `<div class="empty">${html}</div>`;
    T.setStatus(kind === 'err' ? 'Error' : 'Ready', kind || 'ok');
  }

  function renderCard(p) {
    const moved = p.state === 'MOVED';
    const badge = moved
      ? '<span class="badge" style="background:#1e7a3a;color:#fff">● MOVED</span>'
      : '<span class="badge" style="background:#2a2a2a;color:#ddd">◌ WATCHING</span>';
    const playerHref = `player.html?player=${encodeURIComponent(p.espn_athlete_id)}&league=${encodeURIComponent(p.espn_league || '')}`;
    const head = p.headshot_url
      ? `<img src="${escapeHtml(p.headshot_url)}" alt="" style="width:52px;height:52px;border-radius:50%;object-fit:cover;flex:0 0 auto" />`
      : '';

    // Market candidate bars (top 6).
    const cands = (p.candidates || []).slice(0, 6);
    const max = Math.max(...cands.map(c => Number(c.pct) || 0), 1);
    const bars = cands.map(c => {
      const pct = Number(c.pct) || 0;
      const w = Math.max(2, Math.round((pct / max) * 100));
      const name = c.performer_id != null
        ? `<a href="performer.html?performer=${encodeURIComponent(c.performer_id)}">${escapeHtml(c.team || '—')}</a>`
        : escapeHtml(c.team || '—');
      return `<div style="display:flex;align-items:center;gap:8px;padding:2px 0">
        <span style="flex:0 0 40%;overflow:hidden;text-overflow:ellipsis;white-space:nowrap">${name}</span>
        <span style="flex:1;height:7px;border-radius:4px;background:var(--panel-2,#1a1a1a);overflow:hidden">
          <span style="display:block;height:100%;width:${w}%;background:var(--accent,#4ea1ff)"></span>
        </span>
        <span class="num" style="flex:0 0 40px;text-align:right">${pct}%</span>
      </div>`;
    }).join('') || '<div class="empty">no market yet</div>';

    const leader = p.market_leader
      ? `${escapeHtml(p.market_leader.team || '—')} <strong>${p.market_leader.pct}%</strong>`
      : '—';

    // Wikipedia line + change flag.
    const wikiChanged = p.wiki_changed_at
      ? `<span class="badge" style="background:#7a1e1e;color:#fff;margin-left:6px">team change detected</span>` : '';
    const wikiLine = p.wiki_team
      ? `Wikipedia: <strong>${escapeHtml(p.wiki_team)}</strong>${wikiChanged}
         <span class="muted small">· checked ${p.wiki_checked_at ? T.fmtDate(p.wiki_checked_at) : '—'}</span>`
      : '<span class="muted small">Wikipedia: (no team parsed yet)</span>';

    const rosterLine = `Roster: <strong>${escapeHtml(p.roster_team || '—')}</strong>`
      + ` <span class="muted small">(${escapeHtml(p.roster_status || 'active')})</span>`;

    const close = p.close_time ? ` · settles ${T.fmtDate(p.close_time)}` : '';

    return `<div class="tw-card" style="border:1px solid var(--border,#222);border-radius:10px;padding:12px;margin-bottom:12px">
      <div style="display:flex;align-items:center;gap:12px">
        ${head}
        <div style="flex:1;min-width:0">
          <div style="display:flex;align-items:center;gap:8px;flex-wrap:wrap">
            <a href="${playerHref}" class="title" style="font-size:1.05rem">${escapeHtml(p.athlete_name || '—')}</a>
            <span class="muted small">${escapeHtml(p.espn_league || '')}</span>
            ${badge}
          </div>
          <div class="muted small" style="margin-top:2px">${rosterLine}</div>
        </div>
      </div>

      <div class="panel-title" style="margin-top:10px">MARKET · NEXT TEAM${close}</div>
      <div class="muted small" style="margin-bottom:4px">Leader: ${leader}</div>
      ${bars}

      <div class="panel-title" style="margin-top:10px">SIGNALS</div>
      <div class="muted small" style="line-height:1.7">
        ${wikiLine}<br/>
        ${p.wiki_extract ? escapeHtml(p.wiki_extract.slice(0, 220)) + (p.wiki_extract.length > 220 ? '…' : '') : ''}
      </div>
      <div style="margin-top:8px"><a href="${playerHref}">open player page ↗</a></div>
    </div>`;
  }

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', init);
  else init();
})();

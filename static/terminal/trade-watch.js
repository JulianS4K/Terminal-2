// D0 Terminal — Trade Watch (player watchlist).
//
// get_trade_watch() returns, per watchlisted player: ESPN roster team/status,
// the prediction market (leader + candidates), a Wikipedia team-hint + change
// flag, and a fused MOVED/WATCHING state. The watchlist is managed here —
// add via player search (terminal_search → watchlist_add), remove per card
// (watchlist_remove). Everything downstream (feeds, wiki-watch, social poll)
// picks up a watchlisted athlete automatically. Auth-gated (@s4kent.com).

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
    setupAdd();
    setupRemove();
    return loadWatch();
  }

  async function loadWatch() {
    const Auth = window.TerminalAuth;
    T.setStatus('Loading trade watch…');
    const res = await Auth.client.rpc('get_trade_watch');
    if (res.error) { showEmpty(escapeHtml(res.error.message), 'err'); return; }
    const players = (res.data || {}).players || [];
    const meta = document.getElementById('twMeta');
    if (meta) meta.textContent = `${players.length} watched`;
    const empty = document.getElementById('tw-empty');
    if (!players.length) {
      empty.removeAttribute('hidden');
      empty.innerHTML = '<div class="empty">watchlist is empty — add a player above</div>';
      document.getElementById('tw-body').innerHTML = '';
    } else {
      empty.setAttribute('hidden', '');
      document.getElementById('tw-body').innerHTML = players.map(renderCard).join('');
    }
    T.setStatus('Loaded', 'ok');
  }

  function showEmpty(html, kind) {
    const el = document.getElementById('tw-empty');
    el.removeAttribute('hidden');
    el.innerHTML = `<div class="empty">${html}</div>`;
    T.setStatus(kind === 'err' ? 'Error' : 'Ready', kind || 'ok');
  }

  // ---- Add a player (search → watchlist_add) --------------------------------
  function setupAdd() {
    const input = document.getElementById('twAddInput');
    const sugg = document.getElementById('twAddSuggest');
    if (!input || !sugg || input.dataset.wired) return;
    input.dataset.wired = '1';
    let debounceT = 0, lastQ = '';

    async function run(q) {
      if (q === lastQ) return;
      lastQ = q;
      if (q.length < 2) { sugg.setAttribute('hidden', ''); return; }
      const Auth = window.TerminalAuth;
      const res = await Auth.client.rpc('terminal_search', { p_q: q, p_limit: 6 });
      if (res.error) { sugg.setAttribute('hidden', ''); return; }
      const players = (res.data || {}).players || [];
      if (!players.length) {
        sugg.innerHTML = '<div class="empty" style="padding:8px">no players match</div>';
        sugg.removeAttribute('hidden');
        return;
      }
      sugg.innerHTML = players.map(pl => {
        const meta = [pl.team_name, pl.espn_league].filter(Boolean).join(' · ');
        return `<div class="tw-sugg-row" role="button" tabindex="0"
            data-id="${escapeHtml(String(pl.espn_athlete_id || ''))}"
            data-league="${escapeHtml(String(pl.espn_league || ''))}"
            style="display:flex;justify-content:space-between;gap:8px;padding:7px 10px;cursor:pointer;border-bottom:1px solid var(--border,#222)">
          <span>${escapeHtml(pl.full_name || '—')}</span>
          <span class="muted small">${escapeHtml(meta)}</span>
        </div>`;
      }).join('');
      sugg.removeAttribute('hidden');
    }

    input.addEventListener('input', () => {
      clearTimeout(debounceT);
      const q = input.value.trim();
      debounceT = setTimeout(() => run(q), 250);
    });
    async function pick(row) {
      const id = row.getAttribute('data-id');
      const league = row.getAttribute('data-league');
      if (!id || !league) return;
      const Auth = window.TerminalAuth;
      T.setStatus('Adding…');
      const res = await Auth.client.rpc('watchlist_add', { p_athlete_id: id, p_league: league });
      sugg.setAttribute('hidden', '');
      input.value = ''; lastQ = '';
      if (res.error || !(res.data || {}).ok) { T.setStatus('Add failed', 'err'); return; }
      await loadWatch();
    }
    sugg.addEventListener('click', e => {
      const row = e.target.closest('.tw-sugg-row');
      if (row) pick(row);
    });
    sugg.addEventListener('keydown', e => {
      if (e.key === 'Enter') { const row = e.target.closest('.tw-sugg-row'); if (row) pick(row); }
    });
    document.addEventListener('click', e => {
      if (!input.contains(e.target) && !sugg.contains(e.target)) sugg.setAttribute('hidden', '');
    });
  }

  // ---- Remove a player (delegated on the card container) --------------------
  function setupRemove() {
    const body = document.getElementById('tw-body');
    if (!body || body.dataset.wired) return;
    body.dataset.wired = '1';
    body.addEventListener('click', async e => {
      const btn = e.target.closest('.tw-remove');
      if (!btn) return;
      const id = btn.getAttribute('data-id');
      const league = btn.getAttribute('data-league');
      if (!id || !league) return;
      const Auth = window.TerminalAuth;
      T.setStatus('Removing…');
      const res = await Auth.client.rpc('watchlist_remove', { p_athlete_id: id, p_league: league });
      if (res.error) { T.setStatus('Remove failed', 'err'); return; }
      await loadWatch();
    });
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

    const wikiChanged = p.wiki_changed_at
      ? `<span class="badge" style="background:#7a1e1e;color:#fff;margin-left:6px">team change detected</span>` : '';
    const wikiLine = p.wiki_team
      ? `Wikipedia: <strong>${escapeHtml(p.wiki_team)}</strong>${wikiChanged}
         <span class="muted small">· checked ${p.wiki_checked_at ? T.fmtDate(p.wiki_checked_at) : '—'}</span>`
      : '<span class="muted small">Wikipedia: (no team parsed yet)</span>';

    const rosterLine = `Roster: <strong>${escapeHtml(p.roster_team || '—')}</strong>`
      + ` <span class="muted small">(${escapeHtml(p.roster_status || 'active')})</span>`;

    const close = p.close_time ? ` · settles ${T.fmtDate(p.close_time)}` : '';
    const remove = `<button class="tw-remove" title="remove from watchlist"
      data-id="${escapeHtml(String(p.espn_athlete_id || ''))}" data-league="${escapeHtml(String(p.espn_league || ''))}"
      style="margin-left:auto;background:none;border:1px solid var(--border,#333);color:var(--muted,#888);border-radius:6px;padding:1px 7px;cursor:pointer">✕</button>`;

    return `<div class="tw-card" style="border:1px solid var(--border,#222);border-radius:10px;padding:12px;margin-bottom:12px">
      <div style="display:flex;align-items:center;gap:12px">
        ${head}
        <div style="flex:1;min-width:0">
          <div style="display:flex;align-items:center;gap:8px;flex-wrap:wrap">
            <a href="${playerHref}" class="title" style="font-size:1.05rem">${escapeHtml(p.athlete_name || '—')}</a>
            <span class="muted small">${escapeHtml(p.espn_league || '')}</span>
            ${badge}
            ${remove}
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

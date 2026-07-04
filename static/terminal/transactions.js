// D0 Terminal — Transactions page (TRANSACTIONS nav tab).
//
// Enriched ESPN transactions feed (get_espn_transactions): each move maps to our
// databases — the team links to its TEvo performer page, and named players are
// matched to espn_athletes and link to the player page. League filter + search
// are server params (debounced re-query). Backed by the espn_transactions
// pipeline (polled every 5 min).

(function () {
  'use strict';
  const T = window.Terminal;
  const escapeHtml = window.TermRender.escapeHtml;

  const state = { league: '', search: '', type: '' };
  let searchTimer = null;
  let allRows = [];

  function auth() { return window.TerminalAuth; }

  async function init() {
    if (auth()) await auth().requireAuth();
    if (!auth() || !auth().client || !auth().getAccessToken()) {
      document.getElementById('txnBody').innerHTML =
        '<div class="empty">transactions need auth — sign in with @s4kent.com</div>';
      T.setStatus('Auth required', 'err');
      return;
    }
    // preselect league from ?league=
    const q = (new URLSearchParams(location.search).get('league') || '').trim().toUpperCase();
    if (q) state.league = q;
    wireControls();
    return load();
  }

  function wireControls() {
    document.querySelectorAll('.txn-tab').forEach(btn => {
      btn.classList.toggle('active', (btn.dataset.league || '') === state.league);
      btn.addEventListener('click', () => {
        state.league = btn.dataset.league || '';
        document.querySelectorAll('.txn-tab').forEach(b => b.classList.remove('active'));
        btn.classList.add('active');
        load();
      });
    });
    const s = document.getElementById('txnSearch');
    s.value = state.search;
    s.addEventListener('input', () => {
      clearTimeout(searchTimer);
      searchTimer = setTimeout(() => { state.search = s.value.trim(); load(); }, 250);
    });
    document.getElementById('txnType').addEventListener('change', e => {
      state.type = e.target.value || '';
      applyRender();
    });
  }

  // Move-type filter is client-side over the fetched rows (league + search are
  // the server params). Rebuild its options from what's currently loaded.
  function populateTypes() {
    const counts = new Map();
    allRows.forEach(r => counts.set(r.move_type, (counts.get(r.move_type) || 0) + 1));
    const opts = ['<option value="">All types</option>'].concat(
      Array.from(counts.entries()).sort((a, b) => b[1] - a[1])
        .map(([t, n]) => `<option value="${escapeHtml(t)}">${escapeHtml(t)} (${n})</option>`));
    const sel = document.getElementById('txnType');
    sel.innerHTML = opts.join('');
    sel.value = counts.has(state.type) ? state.type : '';
    if (!counts.has(state.type)) state.type = '';
  }

  function applyRender() {
    render(state.type ? allRows.filter(r => r.move_type === state.type) : allRows);
  }

  async function load() {
    T.setStatus('Loading transactions…');
    document.getElementById('txnBody').innerHTML = '<div class="empty">loading…</div>';
    const res = await auth().client.rpc('get_espn_transactions', {
      p_league: state.league || null,
      p_search: state.search || null,
      p_limit: 120,
    });
    if (res.error) { T.setStatus(res.error.message, 'err'); document.getElementById('txnBody').innerHTML =
      `<div class="empty">${escapeHtml(res.error.message)}</div>`; return; }
    allRows = res.data || [];
    T.setStatus('Loaded', 'ok');
    populateTypes();
    applyRender();
  }

  function render(rows) {
    const body = document.getElementById('txnBody');
    const meta = document.getElementById('txnMeta');
    if (meta) meta.textContent = rows.length
      ? `${rows.length} moves${state.league ? ' · ' + state.league : ''}${state.type ? ' · ' + state.type : ''}` : '';
    if (!rows.length) { body.innerHTML = '<div class="empty">no transactions for this filter</div>'; return; }
    body.innerHTML = rows.map(r => {
      const teamCell = r.tevo_performer_id != null
        ? `<a class="txn-team" href="performer.html?performer=${encodeURIComponent(r.tevo_performer_id)}">${escapeHtml(r.team || '—')}</a>`
        : `<span class="txn-team">${escapeHtml(r.team || '—')}</span>`;
      const type = r.move_type
        ? `<span class="txn-mtype txn-mtype-${escapeHtml(r.move_type)}">${escapeHtml(r.move_type)}</span>` : '';
      const players = (r.players || []).map(p => {
        const href = `player.html?player=${encodeURIComponent(p.espn_athlete_id)}&league=${encodeURIComponent(r.espn_league)}`;
        return `<a class="txn-player" href="${href}">${escapeHtml(p.name)}${p.position ? ` <span class="muted small">${escapeHtml(p.position)}</span>` : ''}</a>`;
      }).join('');
      return `<div class="txn-row">
        <div class="txn-row-head">
          <span class="txn-date muted">${r.txn_date ? T.fmtDate(r.txn_date) : '—'}</span>
          <span class="news-badge">${escapeHtml(r.espn_league || '')}</span>
          ${type}
          ${teamCell}
        </div>
        <div class="txn-desc">${escapeHtml(r.description || '')}</div>
        ${players ? `<div class="txn-players">${players}</div>` : ''}
      </div>`;
    }).join('');
  }

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', init);
  else init();
})();

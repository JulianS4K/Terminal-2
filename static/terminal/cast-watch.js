// D0 Terminal — Cast Watch (Broadway twin of Trade Watch).
//
// get_cast_watch() returns, per tracked show: current cast (broadway_cast_run),
// the last Wikipedia cast-section change flag (broadway_cast_pull_log), and a
// CHANGED/STABLE state. "Cast change detected" is the theatre analog of a trade.
// Auth-gated (@s4kent.com).

(function () {
  'use strict';
  const T = window.Terminal;
  const escapeHtml = window.TermRender.escapeHtml;

  async function init() {
    if (window.TerminalAuth) await window.TerminalAuth.requireAuth();
    const Auth = window.TerminalAuth;
    if (!Auth || !Auth.client || !Auth.getAccessToken()) {
      showEmpty('cast watch needs auth — sign in with @s4kent.com', 'err');
      return;
    }
    T.setStatus('Loading cast watch…');
    const res = await Auth.client.rpc('get_cast_watch');
    if (res.error) { showEmpty(escapeHtml(res.error.message), 'err'); return; }
    const shows = (res.data || {}).shows || [];
    const meta = document.getElementById('cwMeta');
    if (meta) meta.textContent = `${shows.length} shows`;
    const empty = document.getElementById('cw-empty');
    if (!shows.length) {
      empty.removeAttribute('hidden');
      empty.innerHTML = '<div class="empty">no tracked shows</div>';
    } else {
      empty.setAttribute('hidden', '');
      document.getElementById('cw-body').innerHTML = shows.map(renderCard).join('');
    }
    T.setStatus('Loaded', 'ok');
  }

  function showEmpty(html, kind) {
    const el = document.getElementById('cw-empty');
    el.removeAttribute('hidden');
    el.innerHTML = `<div class="empty">${html}</div>`;
    T.setStatus(kind === 'err' ? 'Error' : 'Ready', kind || 'ok');
  }

  function renderCard(s) {
    const changed = s.state === 'CHANGED';
    const badge = changed
      ? '<span class="badge" style="background:#7a1e1e;color:#fff">● CAST CHANGED</span>'
      : '<span class="badge" style="background:#2a2a2a;color:#ddd">◌ STABLE</span>';
    const showHref = s.tevo_performer_id != null
      ? `performer.html?performer=${encodeURIComponent(s.tevo_performer_id)}`
        + (s.tevo_venue_id != null ? `&venue=${encodeURIComponent(s.tevo_venue_id)}` : '')
      : null;
    const titleEl = showHref
      ? `<a href="${showHref}" class="title" style="font-size:1.05rem">${escapeHtml(s.title || '—')}</a>`
      : `<span class="title" style="font-size:1.05rem">${escapeHtml(s.title || '—')}</span>`;

    const leads = (s.leads || []);
    const castLine = leads.length
      ? leads.map(l => {
          const role = l.role ? ` <span class="muted small">(${escapeHtml(l.role)})</span>` : '';
          return `<span>${escapeHtml(l.performer || '—')}${role}</span>`;
        }).join(' · ')
      : '<span class="muted small">cast roster not parsed for this show</span>';

    const flagLine = s.last_change
      ? `Last cast change: <strong>${T.fmtDate(s.last_change)}</strong>`
        + (s.change_flags_30d ? ` <span class="muted small">· ${s.change_flags_30d} flag${s.change_flags_30d === 1 ? '' : 's'}/30d</span>` : '')
      : '<span class="muted small">no cast change detected yet</span>';
    const polled = s.cast_last_polled_at
      ? ` <span class="muted small">· checked ${T.fmtDate(s.cast_last_polled_at)}</span>` : '';

    return `<div class="cw-card" style="border:1px solid var(--border,#222);border-radius:10px;padding:12px;margin-bottom:12px">
      <div style="display:flex;align-items:center;gap:8px;flex-wrap:wrap">
        ${titleEl}
        ${badge}
      </div>
      <div class="panel-title" style="margin-top:10px">CURRENT CAST</div>
      <div class="muted small" style="line-height:1.7">${castLine}</div>
      <div class="panel-title" style="margin-top:10px">SIGNAL</div>
      <div class="muted small">${flagLine}${polled}</div>
      ${showHref ? `<div style="margin-top:8px"><a href="${showHref}">open show page ↗</a></div>` : ''}
    </div>`;
  }

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', init);
  else init();
})();

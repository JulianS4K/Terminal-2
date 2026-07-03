// Shared "participant get-in" panel (window.CastPanel).
//
// Renders the generic {kind, subject, metric, participants:[{name, role, window,
// avg_getin, measured, …}]} contract returned by the broadway-cast routes
// (event- and performer-scoped) as a get-in-by-lead bar list. Source-agnostic on
// purpose: an ESPN athlete feed (kind='espn') can reuse this renderer unchanged.
//
// Used by both static/terminal/event.js (event Cast tab) and performer.js
// (show-as-performer Cast tab).
(function () {
  'use strict';

  const esc = (s) => (window.TermRender && window.TermRender.escapeHtml)
    ? window.TermRender.escapeHtml(s)
    : String(s == null ? '' : s).replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));

  function injectStyle() {
    if (document.getElementById('cast-style')) return;
    const st = document.createElement('style');
    st.id = 'cast-style';
    st.textContent =
      '.cast-list{display:flex;flex-direction:column;gap:8px;margin-top:6px}' +
      '.cast-row{display:grid;grid-template-columns:186px 1fr;gap:12px;align-items:center}' +
      '.cast-lead .nm{color:var(--text);font-weight:600;font-size:13px}' +
      '.cast-lead .nm .now{color:var(--accent);font-family:var(--mono);font-size:9px;border:1px solid var(--accent);border-radius:3px;padding:0 4px;margin-left:6px;vertical-align:middle;text-transform:uppercase;letter-spacing:.5px}' +
      '.cast-lead .mt{color:var(--muted);font-size:11px;font-family:var(--mono)}' +
      '.cast-bar{display:flex;align-items:center;gap:10px}' +
      '.cast-track{flex:1;position:relative;height:26px;background:var(--panel-2);border-radius:4px;overflow:hidden}' +
      '.cast-fill{height:100%;border-radius:4px 0 0 4px;background:var(--info)}' +
      '.cast-fill.cur{background:var(--accent)}' +
      '.cast-ghost{position:absolute;inset:0;border:1px dashed var(--line);border-radius:4px;display:flex;align-items:center;justify-content:center}' +
      '.cast-ghost .lbl{color:var(--dim);font-size:10px;font-family:var(--mono);text-transform:uppercase;letter-spacing:.5px}' +
      '.cast-val{width:56px;text-align:right;color:var(--text);font-family:var(--mono);font-size:12px;font-weight:600;white-space:nowrap}' +
      '.cast-val.dim{color:var(--muted);font-weight:400}';
    document.head.appendChild(st);
  }

  function render(root, data) {
    if (!root) return;
    injectStyle();
    const parts = (data && data.participants) || [];
    const today = new Date().toISOString().slice(0, 10);
    const measured = parts.filter((p) => p.measured && p.avg_getin != null).map((p) => p.avg_getin);
    const scaleMax = Math.max(160, ...(measured.length ? measured : [0])) * 1.1;
    const isCurrent = (p) => (!p.window_start || p.window_start <= today) && (!p.window_end || p.window_end >= today);
    const rows = parts.map((p) => {
      const cur = isCurrent(p);
      const dateStr = p.window_end ? ('final ' + p.window_end) : (p.window_start ? ('from ' + p.window_start) : '');
      const sub = [dateStr, p.role].filter(Boolean).join(' · ');
      let bar, val;
      if (p.measured && p.avg_getin != null) {
        const pct = Math.max(2, Math.min(100, p.avg_getin / scaleMax * 100));
        const tip = `avg $${Math.round(p.avg_getin)}` +
          (p.min_getin != null ? ` · ${Math.round(p.min_getin)}–${Math.round(p.max_getin)}` : '') +
          (p.snapshot_rows != null ? ` · ${p.snapshot_rows} snapshots` : '');
        bar = `<div class="cast-track" title="${esc(tip)}"><div class="cast-fill${cur ? ' cur' : ''}" style="width:${pct}%"></div></div>`;
        val = `<div class="cast-val">$${Math.round(p.avg_getin)}</div>`;
      } else {
        bar = '<div class="cast-track"><div class="cast-ghost"><span class="lbl">awaiting coverage</span></div></div>';
        val = '<div class="cast-val dim">—</div>';
      }
      return `<div class="cast-row"><div class="cast-lead">` +
        `<div class="nm">${esc(p.name)}${cur ? '<span class="now">now</span>' : ''}</div>` +
        `<div class="mt">${esc(sub)}</div></div>` +
        `<div class="cast-bar">${bar}${val}</div></div>`;
    }).join('');
    root.innerHTML = `<div class="cast-list">${rows}</div>`;
  }

  window.CastPanel = { render };
})();

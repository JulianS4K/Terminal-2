// D0 Terminal — Health / uptime page.
// Reads get_health_dashboard() (SECDEF, @s4kent-gated) via the Path-C Supabase
// client and renders overall status, per-web-service reachability, a 24h
// timeline, and per-check status with 24h/7d uptime %. Auto-refreshes.

(function () {
  'use strict';
  const T = window.Terminal;
  const REFRESH_MS = 30000;
  let timer = null;

  async function init() {
    if (window.TerminalAuth) await window.TerminalAuth.requireAuth();
    await load();
    timer = setInterval(load, REFRESH_MS);
    document.addEventListener('visibilitychange', () => {
      if (document.hidden) { clearInterval(timer); timer = null; }
      else if (!timer) { load(); timer = setInterval(load, REFRESH_MS); }
    });
  }

  async function load() {
    const Auth = window.TerminalAuth;
    if (!Auth || !Auth.client || !Auth.getAccessToken()) {
      if (T) T.setStatus('not signed in', 'err');
      return;
    }
    try {
      const { data, error } = await Auth.client.rpc('get_health_dashboard');
      if (error) throw error;
      render(data);
      if (T) T.setStatus('updated ' + new Date().toLocaleTimeString(), 'ok');
    } catch (e) {
      console.error('[health]', e);
      if (T) T.setStatus('error: ' + (e.message || e), 'err');
    }
  }

  function render(d) {
    d = d || {};
    renderOverall(d.overall, d.latest_snapshot_at);
    renderWeb(d.web || []);
    renderTimeline(d.timeline || []);
    renderChecks(d.checks || []);
    const foot = document.getElementById('hz-foot');
    if (foot) {
      foot.textContent =
        'snapshot: ' + (d.latest_snapshot_at ? T.fmtDate(d.latest_snapshot_at) : '—') +
        ' · generated: ' + (d.generated_at ? new Date(d.generated_at).toLocaleTimeString() : '—') +
        ' · source: release_health_check() snapshots @ */5min + web pings';
    }
  }

  function renderOverall(ov, snapAt) {
    const el = document.getElementById('hz-overall');
    if (!el) return;
    if (!ov) {
      el.className = 'hz-overall';
      el.innerHTML = '<span class="hz-dot"></span><span class="hz-big">no data yet — first snapshot pending</span>';
      return;
    }
    const st = ov.status || 'warn';
    const label = st === 'ok' ? 'ALL SYSTEMS OPERATIONAL'
      : st === 'warn' ? 'DEGRADED' : 'INCIDENT';
    el.className = 'hz-overall ' + st;
    el.innerHTML =
      `<span class="hz-dot ${st}"></span>` +
      `<span class="hz-big">${label}</span>` +
      `<div class="hz-metrics">` +
        metric(pct(ov.uptime_24h), 'uptime 24h') +
        metric(pct(ov.uptime_7d), 'uptime 7d') +
        metric((ov.failing ?? 0) + ' / ' + (ov.checks_total ?? 0), 'failing checks') +
        metric((ov.warning ?? 0), 'warnings') +
      `</div>`;
  }

  function metric(v, l) {
    return `<div class="hz-metric"><div class="v">${v}</div><div class="l">${esc(l)}</div></div>`;
  }

  function renderWeb(web) {
    const el = document.getElementById('hz-web');
    if (!el) return;
    if (!web.length) { el.innerHTML = '<div class="muted small">no web pings recorded yet</div>'; return; }
    el.innerHTML = web.map(w => card(
      w.check_name, w.status, w.detail,
      w.ok_24h != null ? `${pct(w.ok_24h)} up · ${w.samples_24h || 0} pings/24h` : ''
    )).join('');
  }

  function renderChecks(checks) {
    const el = document.getElementById('hz-checks');
    if (!el) return;
    if (!checks.length) { el.innerHTML = ''; return; }
    const byClass = {};
    checks.forEach(c => { (byClass[c.check_class] = byClass[c.check_class] || []).push(c); });
    let html = '';
    Object.keys(byClass).sort().forEach(cls => {
      html += `<div class="hz-class">${esc(cls.replace(/_/g, ' '))}</div><div class="hz-grid">`;
      html += byClass[cls].map(c => card(
        c.check_name, c.status, c.detail,
        c.ok_24h != null ? `${pct(c.ok_24h)} ok 24h · ${pct(c.ok_7d)} 7d` : ''
      )).join('');
      html += `</div>`;
    });
    el.innerHTML = html;
  }

  function card(name, status, detail, up) {
    const st = status || 'warn';
    return `<div class="hz-card">` +
      `<div class="row1"><span class="hz-dot ${st}"></span>` +
      `<span class="nm">${esc(prettyName(name))}</span>` +
      `<span class="hz-pill ${st}">${esc(st)}</span></div>` +
      (detail ? `<div class="detail">${esc(detail)}</div>` : '') +
      (up ? `<div class="up">${esc(up)}</div>` : '') +
      `</div>`;
  }

  function renderTimeline(tl) {
    const el = document.getElementById('hz-timeline');
    if (!el) return;
    if (!tl.length) { el.innerHTML = '<div class="muted small">no history yet</div>'; return; }
    el.innerHTML = tl.map(p =>
      `<span class="hz-tick ${p.status || ''}" title="${esc(T.fmtDate(p.t))}: ${esc(p.status || '')}"></span>`
    ).join('');
  }

  function prettyName(n) { return String(n || '').replace(/_/g, ' '); }
  function pct(v) { return (v === null || v === undefined) ? '—' : (+v).toFixed(2) + '%'; }
  function esc(s) {
    if (s === null || s === undefined) return '';
    return String(s).replace(/[&<>"']/g, c => ({ '&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;' }[c]));
  }

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', init);
  else init();
})();

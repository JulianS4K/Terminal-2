// Undelivered doorway — D0/D2 Option C. Pings D2 /healthz unauthenticated +
// surfaces auth state on the status pill. Same pattern as static/terminal/orders.js.

(function () {
  'use strict';
  const Auth = window.TerminalAuth;
  const D2_BASE = 'https://d2-orders-dashboard.onrender.com';

  function isLocalhost() {
    const h = location.hostname;
    return h === 'localhost' || h === '127.0.0.1' || h === '';
  }

  function setStatus(text, cls) {
    const el = document.getElementById('status');
    if (!el) return;
    el.textContent = text;
    el.className = 'status' + (cls ? ' ' + cls : '');
  }

  function setHealth(cls, text) {
    const badge = document.getElementById('d2HealthBadge');
    if (!badge) return;
    badge.className = 'health-badge ' + cls;
    badge.textContent = text;
  }

  function pingD2Health() {
    const t0 = performance.now();
    fetch(`${D2_BASE}/healthz`, { credentials: 'omit', mode: 'cors' })
      .then(res => {
        const ms = Math.round(performance.now() - t0);
        if (res.ok) setHealth('live', `live · ${ms}ms`);
        else        setHealth('down', `HTTP ${res.status}`);
      })
      .catch(() => setHealth('dim', 'status unknown'));
  }

  function init() {
    pingD2Health();
    if (!Auth) { setStatus('auth offline'); return; }
    Auth.ready.then(async () => {
      if (isLocalhost()) { setStatus('localhost · doorway', 'ok'); return; }
      const email = Auth.getEmail();
      if (!email) { setStatus('not signed in', ''); return; }
      if (!Auth.isAllowedEmail(email)) {
        setStatus(`${email} — not @s4kent.com`, 'err');
        return;
      }
      setStatus(`signed in · ${email}`, 'ok');
    });
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init);
  } else {
    init();
  }
})();

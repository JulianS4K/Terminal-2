// D0 Terminal — Orders page (doorway to D2's dashboard).
// Pings D2's /healthz (unauthenticated) cross-origin to surface live/down
// state for the CTA badge. Fails silently if CORS blocks — D2 may not
// allowlist us until a real inline-data integration is requested.

(function () {
  'use strict';
  const T = window.Terminal;
  const D2_BASE = '';  // same-origin — D2 dashboard is merged into this service (/d2 + /api/d2/*)

  async function init() {
    if (window.TerminalAuth) await window.TerminalAuth.requireAuth();
    if (T && T.setStatus) T.setStatus('D2 doorway', 'ok');
    pingD2Health();
  }

  function pingD2Health() {
    const badge = document.getElementById('d2HealthBadge');
    if (!badge) return;
    const t0 = performance.now();
    // /healthz is unauthenticated on the D2 service. CORS-allowed in default
    // FastAPI deploys via the CORSMiddleware (D2 doesn't currently configure
    // one explicitly — if this fails with CORS, we silently show "unknown"
    // and the CTA still works).
    fetch(`${D2_BASE}/healthz`, { credentials: 'omit', mode: 'cors' })
      .then(res => {
        const ms = Math.round(performance.now() - t0);
        if (res.ok) setHealth('live', `live · ${ms}ms`);
        else        setHealth('down', `HTTP ${res.status}`);
      })
      .catch(() => {
        // CORS or network error — D2 may not allowlist us. Silent.
        setHealth('dim', 'status unknown');
      });
  }

  function setHealth(cls, text) {
    const badge = document.getElementById('d2HealthBadge');
    if (!badge) return;
    badge.className = 'health-badge ' + cls;
    badge.textContent = text;
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init);
  } else {
    init();
  }
})();

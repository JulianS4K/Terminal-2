// D0 Terminal — PWA bootstrap (service-worker registration).
//
// Standalone so it satisfies CSP `script-src 'self'` and can load on EVERY
// terminal page — including login.html, which intentionally does NOT pull in
// app.js. Previously the SW registration lived inside app.js, so the login
// page (the entry point for unauthenticated visitors) never registered the
// worker and was not installable/offline-capable. Keeping this in its own
// tiny file guarantees uniform PWA behavior across all pages.
//
// The worker itself (sw.js) is network-first; see that file for caching
// strategy. Registration is idempotent, so loading this alongside app.js is
// harmless.
(function () {
  'use strict';
  if (!('serviceWorker' in navigator)) return;
  window.addEventListener('load', () => {
    navigator.serviceWorker.register('/sw.js')
      .catch((e) => console.warn('[pwa] sw register failed', e));
  });
})();

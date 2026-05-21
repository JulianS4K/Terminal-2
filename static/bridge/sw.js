// Exos service worker.
//
// Goals:
//   * Make the app installable as a PWA.
//   * Survive flaky/no connectivity for the static shell.
//   * NEVER serve a cached response for API or auth/database traffic — that
//     would let stale Stripe sessions, stale Firestore reads, or stale auth
//     state leak through after the network came back.
//
// Strategy:
//   * Static assets: stale-while-revalidate.
//   * Navigations (HTML): network-first with the offline shell as fallback.
//   * Everything else (API, Firestore, Stripe, Identity Toolkit, etc.):
//     pass straight through to the network — no caching.

// Bumped when the cache-eligible static set changes shape, so a
// previous-version SW correctly purges its cache on activate.
const VERSION = 'vibepass-v4-pwa';
const STATIC_CACHE = `${VERSION}-static`;
const SHELL = ['/', '/index.html', '/manifest.json', '/icon.svg', '/icon-192.png', '/icon-512.png'];

// Hosts whose responses must NEVER be cached. Includes our own /api routes
// and the Firebase / Stripe surfaces the SPA talks to.
const NEVER_CACHE_HOSTS = [
  'firestore.googleapis.com',
  'firebase.googleapis.com',
  'firebaseinstallations.googleapis.com',
  'identitytoolkit.googleapis.com',
  'securetoken.googleapis.com',
  'firebaseio.com',
  'api.stripe.com',
  'js.stripe.com',
];

self.addEventListener('install', (event) => {
  event.waitUntil(
    caches.open(STATIC_CACHE).then((cache) => cache.addAll(SHELL))
  );
  // Take over immediately — we want the new SW to start serving the moment
  // it installs, especially during cache-strategy fixes like this one.
  self.skipWaiting();
});

// Allow the page to ask a waiting SW to activate ASAP. Used by the
// "Update available — Reload" toast in lib/registerSW.ts: the toast
// posts SKIP_WAITING then reloads the page, so the user gets the new
// build on their next paint cycle without us yanking the page out
// from under whatever they were doing first.
self.addEventListener('message', (event) => {
  if (event.data && event.data.type === 'SKIP_WAITING') {
    self.skipWaiting();
  }
});

self.addEventListener('activate', (event) => {
  event.waitUntil(
    (async () => {
      // Drop any cache from a prior version.
      const keys = await caches.keys();
      await Promise.all(
        keys.filter((k) => !k.startsWith(VERSION)).map((k) => caches.delete(k))
      );
      await self.clients.claim();
    })()
  );
});

function isNeverCached(url) {
  if (NEVER_CACHE_HOSTS.includes(url.hostname)) return true;
  // Same-origin API routes.
  if (url.origin === self.location.origin && url.pathname.startsWith('/api/')) {
    return true;
  }
  return false;
}

self.addEventListener('fetch', (event) => {
  const req = event.request;

  // Only handle GETs — POST/PUT/DELETE etc. always go straight to network.
  if (req.method !== 'GET') return;

  const url = new URL(req.url);

  // 1) Hard pass-through for API / Firestore / Stripe / auth.
  if (isNeverCached(url)) return; // Don't call respondWith — default network fetch.

  // 2) Navigations: network-first, fall back to cached shell when offline.
  if (req.mode === 'navigate') {
    event.respondWith(
      fetch(req)
        .then((res) => {
          // Cache a copy of index.html for offline boot.
          if (res.ok && url.origin === self.location.origin) {
            const copy = res.clone();
            caches.open(STATIC_CACHE).then((c) => c.put('/index.html', copy));
          }
          return res;
        })
        .catch(() =>
          caches.match('/index.html').then((cached) => cached || Response.error())
        )
    );
    return;
  }

  // 3) Static assets (same-origin, non-API): stale-while-revalidate.
  if (url.origin === self.location.origin) {
    event.respondWith(
      caches.open(STATIC_CACHE).then(async (cache) => {
        const cached = await cache.match(req);
        const network = fetch(req)
          .then((res) => {
            if (res.ok) cache.put(req, res.clone());
            return res;
          })
          .catch(() => cached || Response.error());
        return cached || network;
      })
    );
    return;
  }

  // 4) Cross-origin assets we didn't classify above — let the browser handle.
});

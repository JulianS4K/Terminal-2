// VibePass storefront — minimal PWA service worker (installability + offline shell).
//
// Served from /store-sw.js (a ROOT path) so it can claim scope '/store': a SW
// only controls pages at/below its own URL directory, so from /static/store/ it
// could never cover the /store routes. store.js registers it with scope '/store'
// and app.py serves it with Service-Worker-Allowed: /store.
//
// Strategy (conservative — never breaks auth, live inventory, or the seat map):
//   - Only same-origin GETs are touched. Cross-origin (Supabase, the TEvo seat-
//     map CDN maps.ticketevolution.com) passes straight through, never cached.
//   - /api/* is bypassed even when same-origin (dynamic catalog / reserve).
//   - Everything else (the /store HTML shells + css/js/svg): NETWORK-FIRST so a
//     deploy is never masked by a stale bundle; cache is the offline fallback.
// Bump CACHE to invalidate the offline shell on the next visit.

const CACHE = 'vibepass-store-v2';
const SHELL = [
  '/store',
  '/static/store/style.css',
  '/static/store/theme.js',
  '/static/store/store.js',
  '/static/store/seatmap.js',
  '/static/store/lib/tevomaps.bundle.js',
  '/static/store/favicon.svg',
  '/static/store/manifest.json',
];

self.addEventListener('install', (event) => {
  event.waitUntil(
    caches.open(CACHE)
      .then((c) => Promise.allSettled(SHELL.map((u) => c.add(new Request(u, { cache: 'reload' })))))
      .then(() => self.skipWaiting())
  );
});

self.addEventListener('activate', (event) => {
  event.waitUntil(
    caches.keys()
      .then((keys) => Promise.all(keys.filter((k) => k !== CACHE).map((k) => caches.delete(k))))
      .then(() => self.clients.claim())
  );
});

self.addEventListener('fetch', (event) => {
  const req = event.request;
  if (req.method !== 'GET') return;
  const url = new URL(req.url);
  if (url.origin !== self.location.origin) return;   // Supabase / TEvo maps CDN → passthrough
  if (url.pathname.startsWith('/api/')) return;        // dynamic API → never cache

  // Network-first; cache is the offline fallback only.
  event.respondWith(
    fetch(req)
      .then((res) => { cachePut(req, res.clone()); return res; })
      .catch(() => caches.match(req).then((m) =>
        m || (req.mode === 'navigate' ? caches.match('/store') : Response.error())))
  );
});

function cachePut(req, res) {
  if (res && res.ok && res.type === 'basic') {
    caches.open(CACHE).then((c) => c.put(req, res)).catch(() => {});
  }
}

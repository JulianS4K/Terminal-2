// S4K Terminal — minimal PWA service worker (installability + offline app shell).
//
// Strategy (deliberately conservative so it never breaks auth or live data):
//   - Only same-origin GETs are touched. Cross-origin (Supabase RPC, the
//     storefront /api host) is passed straight through — never cached.
//   - /api/* is bypassed even if same-origin (could be the unified service).
//   - Everything else (HTML + css/js/svg): NETWORK-FIRST — always prefer fresh
//     so a deploy is never masked by a stale cached bundle; the cache is only an
//     offline fallback. (Cache-first would risk serving old JS on this
//     fast-iterating app.) Successful responses refresh the cache.
// Bump CACHE to invalidate the offline shell on the next visit.

const CACHE = 's4k-terminal-v2';
const SHELL = [
  '/', '/index.html', '/style.css',
  '/pwa.js', '/app.js', '/auth.js', '/nav.js', '/home.js', '/event.js', '/movers.js',
  '/orders.js', '/discovery.js', '/venue.js', '/performer.js', '/login.js',
  '/lib/uplot.iife.min.js', '/lib/uplot.min.css', '/lib/supabase.js',
  '/favicon.svg', '/manifest.json',
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
  if (url.origin !== self.location.origin) return;   // Supabase / cross-origin API → passthrough
  if (url.pathname.startsWith('/api/')) return;        // dynamic API → never cache

  // Network-first; cache is the offline fallback only.
  event.respondWith(
    fetch(req)
      .then((res) => { cachePut(req, res.clone()); return res; })
      .catch(() => caches.match(req).then((m) =>
        m || (req.mode === 'navigate' ? caches.match('/index.html') : Response.error())))
  );
});

function cachePut(req, res) {
  if (res && res.ok && res.type === 'basic') {
    caches.open(CACHE).then((c) => c.put(req, res)).catch(() => {});
  }
}

// Service worker registration + update flow.
//
// Registers the service worker (at the app's base path) on first load
// and dispatches a custom DOM event
// when a new SW version takes over so the app can render an inline
// "Update available — Reload" banner. We dispatch an event rather
// than calling toast() directly because the toast queue may not be
// mounted yet when registration completes (registration runs after
// the React tree mounts, but the timing is racey on slow devices).
//
// Why we want this for Bridge: in production, a venue's door staff
// has the scanner page open for hours during an event. If we ship a
// fix to OrganizerCheckIn at 7pm and they don't reload, they're
// running stale code through the entire show. The banner nudges
// without forcing a reload mid-scan.

export const SW_UPDATE_EVENT = 'vibepass:sw-update';

export interface SwUpdatePayload {
  /** Tells the waiting SW to take over now and reload the page. */
  apply: () => void;
}

export function registerServiceWorker(): void {
  if (!('serviceWorker' in navigator)) return;

  // Hold registration off the critical path. Doing it on `load`
  // means the SW install doesn't compete with the initial render
  // for network or main-thread bandwidth.
  window.addEventListener('load', async () => {
    try {
      // The app is served under a path prefix (Vite base, e.g. '/bridge/').
      // Register the worker at that prefix — NOT the origin root, where the
      // file 404s (or binds the hub's root SW). A worker served from
      // '/bridge/sw.js' has a default scope of '/bridge/', so no
      // Service-Worker-Allowed header is needed.
      // Env access mirrors App.tsx / lib/supabase.ts: `(import.meta as any).env`.
      const base = ((import.meta as any).env?.BASE_URL ?? '/') as string;
      const registration = await navigator.serviceWorker.register(`${base}sw.js`, {
        scope: base,
      });

      // Track updates. When a new SW is found and starts installing,
      // wait until it reaches the 'installed' state, then signal.
      // Skip the signal if there was no previous controller — that
      // means this is the first SW install, which is silent by design.
      registration.addEventListener('updatefound', () => {
        const newSW = registration.installing;
        if (!newSW) return;
        newSW.addEventListener('statechange', () => {
          if (newSW.state === 'installed' && navigator.serviceWorker.controller) {
            // We have a previous SW AND a new one just installed —
            // a real update. Dispatch a DOM event the app can listen
            // for and surface to the user.
            const detail: SwUpdatePayload = {
              apply: () => {
                newSW.postMessage({ type: 'SKIP_WAITING' });
                window.location.reload();
              },
            };
            window.dispatchEvent(new CustomEvent<SwUpdatePayload>(SW_UPDATE_EVENT, { detail }));
          }
        });
      });
    } catch (err) {
      // SW registration failures are non-fatal; the app still works,
      // just without offline shell or install support.
      console.warn('Service worker registration failed:', err);
    }
  });
}

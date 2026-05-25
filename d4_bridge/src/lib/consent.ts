// Marketing-cookie consent store.
//
// Third-party pixels (Meta/GA4/TikTok) set cookies and phone home, so
// they must not load until the visitor opts in. This is the gate the
// growth-primitives migration deferred ("CSP/consent review"): pixels in
// lib/pixels.ts register their loaders here and only fire once consent is
// 'granted'. Denial is sticky too — a visitor who declines isn't re-asked.
//
// Persisted in localStorage so the choice survives reloads. No cookie is
// set for the consent flag itself (it's first-party functional state, not
// tracking), which keeps the gate itself outside the thing it gates.

const KEY = 'exos.consent.marketing.v1';

export type ConsentState = 'granted' | 'denied' | 'unset';

const listeners = new Set<(s: ConsentState) => void>();

export function getConsent(): ConsentState {
  if (typeof localStorage === 'undefined') return 'unset';
  const v = localStorage.getItem(KEY);
  return v === 'granted' || v === 'denied' ? v : 'unset';
}

export function setConsent(granted: boolean): void {
  if (typeof localStorage !== 'undefined') {
    localStorage.setItem(KEY, granted ? 'granted' : 'denied');
  }
  const state: ConsentState = granted ? 'granted' : 'denied';
  for (const fn of listeners) fn(state);
}

// Subscribe to consent changes. Returns an unsubscribe fn.
export function onConsentChange(fn: (s: ConsentState) => void): () => void {
  listeners.add(fn);
  return () => listeners.delete(fn);
}

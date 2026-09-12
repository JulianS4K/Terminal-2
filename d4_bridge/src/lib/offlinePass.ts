// Offline pass cache — the holder's own passes, on-device.
//
// Why this exists: the single most common real-world failure for a ticketing
// app is the door itself. A packed venue means no cell signal, the holder taps
// their pass, the app spins, and the queue stops. Every read in this app goes
// to Supabase over the network, and the service worker deliberately refuses to
// cache Supabase responses (public/sw.js) — correct for auth and money, fatal
// for a QR code someone needs in ten seconds with one bar.
//
// So we keep a small, explicit copy of the viewer's OWN passes in
// localStorage, and the pass views fall back to it when the network read
// fails. The rotating barcode keeps rotating offline: it is
// HMAC(secret, "ticketId:ownerId:bucket") with a wall-clock bucket
// (lib/barcode.ts), so a cached ticket + the device clock is all the signing
// needs. No server round-trip.
//
// What this means for the barcode secret:
//   * It goes to disk on the holder's own device. That is the same trade an
//     Apple Wallet pass makes — the pass is the credential, offline by design.
//   * It is NOT the security boundary. The door RPC re-checks status, owner,
//     bucket and HMAC server-side (mig 20260702120000), so a stale cached copy
//     of a voided / transferred / already-scanned ticket is refused at the
//     scanner even though it renders here.
//   * We keep the blast radius small: one user's passes at a time, wiped on
//     sign-out, dropped when a different user id is seen, pruned to events
//     that have not already ended, and capped.
//
// Everything above the storage seam is pure and unit-tested; the localStorage
// calls are individually guarded because Safari private mode throws on write.

import { Timestamp } from './timestamp';
import type { Event, Ticket } from '../types';

export type PassRecord = Ticket & { event?: Event };

/** Storage key. Bump the suffix if the envelope shape ever changes. */
const KEY = 'vibepass:offline-passes:v1';

/** Keep a pass this long past the event start (late shows + post-event lookup). */
export const KEEP_AFTER_START_MS = 24 * 3600_000;

/** Hard cap on cached passes — a heavy user should not fill the quota. */
export const MAX_PASSES = 40;

/** Discard the whole snapshot once it is this old; the data is too cold to trust. */
export const MAX_AGE_MS = 30 * 24 * 3600_000;

/** What we actually write: one user's passes plus when they were fetched. */
export interface PassSnapshot {
  v: 1;
  userId: string;
  savedAt: number;
  passes: PassRecord[];
}

// --- Timestamp-safe (de)serialization ---------------------------------------
// Ticket and Event carry `Timestamp` instances (lib/timestamp.ts), which JSON
// flattens to `{seconds, nanoseconds}` — a plain object with no `.toDate()`.
// Every pass view calls `.toDate()`, so a naive round-trip crashes the very
// screen this cache exists to save. Encode them to a tagged number and revive
// them on read.

const TS_TAG = '__ts';

/** Deep-encode a value for storage: Timestamp / Date → `{__ts: millis}`. */
export function encodePasses(value: unknown): unknown {
  if (value instanceof Timestamp) return { [TS_TAG]: value.toMillis() };
  if (value instanceof Date) return { [TS_TAG]: value.getTime() };
  if (Array.isArray(value)) return value.map(encodePasses);
  if (value && typeof value === 'object') {
    const out: Record<string, unknown> = {};
    for (const [k, v] of Object.entries(value as Record<string, unknown>)) {
      // Drop undefined rather than letting JSON.stringify eat it silently —
      // keeps encode/decode symmetric so the tests mean something.
      if (v === undefined) continue;
      out[k] = encodePasses(v);
    }
    return out;
  }
  return value;
}

/** Deep-decode a stored value: `{__ts: millis}` → Timestamp. */
export function decodePasses(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(decodePasses);
  if (value && typeof value === 'object') {
    const rec = value as Record<string, unknown>;
    const keys = Object.keys(rec);
    if (keys.length === 1 && keys[0] === TS_TAG && typeof rec[TS_TAG] === 'number') {
      return Timestamp.fromMillis(rec[TS_TAG] as number);
    }
    const out: Record<string, unknown> = {};
    for (const [k, v] of Object.entries(rec)) out[k] = decodePasses(v);
    return out;
  }
  return value;
}

// --- Pruning ----------------------------------------------------------------

function startMs(p: PassRecord): number {
  try {
    return p.event?.date?.toDate ? p.event.date.toDate().getTime() : 0;
  } catch {
    return 0;
  }
}

/**
 * Keep the passes worth carrying offline: events that have not already ended
 * (unknown date counts as upcoming — better to keep a pass we cannot place
 * than to drop the one the holder needs), soonest first, capped.
 *
 * Voided and used passes are kept deliberately. Offline, a muted pass stamped
 * REFUNDED or ENTERED tells the holder the truth; a missing pass just looks
 * like the app is broken.
 */
export function prunePasses(passes: PassRecord[], now: number = Date.now()): PassRecord[] {
  return passes
    .filter((p) => {
      const at = startMs(p);
      return at === 0 || at + KEEP_AFTER_START_MS >= now;
    })
    .sort((a, b) => {
      const av = startMs(a) || Number.MAX_SAFE_INTEGER;
      const bv = startMs(b) || Number.MAX_SAFE_INTEGER;
      return av - bv;
    })
    .slice(0, MAX_PASSES);
}

// --- Sync age ---------------------------------------------------------------

export type SyncAge =
  | { unit: 'now'; value: 0 }
  | { unit: 'min' | 'hour' | 'day'; value: number };

/**
 * How stale the cached copy is, as a unit + count so the view can render it
 * through i18n instead of baking English into this module.
 */
export function syncAge(savedAt: number, now: number = Date.now()): SyncAge {
  const ms = Math.max(0, now - savedAt);
  if (ms < 60_000) return { unit: 'now', value: 0 };
  if (ms < 3600_000) return { unit: 'min', value: Math.floor(ms / 60_000) };
  if (ms < 24 * 3600_000) return { unit: 'hour', value: Math.floor(ms / 3600_000) };
  return { unit: 'day', value: Math.floor(ms / (24 * 3600_000)) };
}

// --- Storage seam -----------------------------------------------------------

function store(): Storage | null {
  try {
    return typeof localStorage === 'undefined' ? null : localStorage;
  } catch {
    return null;
  }
}

/**
 * Persist this user's passes. Best-effort: a full or unavailable quota must
 * never break the online path that just succeeded.
 */
export function saveOfflinePasses(
  userId: string,
  passes: PassRecord[],
  now: number = Date.now(),
): void {
  const s = store();
  if (!s || !userId) return;
  try {
    const snapshot: PassSnapshot = {
      v: 1,
      userId,
      savedAt: now,
      passes: prunePasses(passes, now),
    };
    s.setItem(KEY, JSON.stringify(encodePasses(snapshot)));
  } catch (err) {
    // Quota exceeded / private mode / disabled storage. Non-fatal by design.
    console.warn('offline pass cache write failed (non-fatal):', err);
  }
}

/**
 * Read this user's cached passes. Returns null when there is nothing usable:
 * no cache, a different signed-in user, a stale snapshot, or corrupt JSON.
 * A cache belonging to someone else is wiped rather than ignored — a shared
 * device should not keep the previous person's barcode secrets around.
 */
export function loadOfflinePasses(
  userId: string,
  now: number = Date.now(),
): { passes: PassRecord[]; savedAt: number } | null {
  const s = store();
  if (!s || !userId) return null;
  let raw: string | null = null;
  try {
    raw = s.getItem(KEY);
  } catch {
    return null;
  }
  if (!raw) return null;
  try {
    const snap = decodePasses(JSON.parse(raw)) as PassSnapshot;
    if (!snap || snap.v !== 1 || !Array.isArray(snap.passes)) return null;
    if (snap.userId !== userId) {
      clearOfflinePasses();
      return null;
    }
    if (typeof snap.savedAt !== 'number' || now - snap.savedAt > MAX_AGE_MS) {
      clearOfflinePasses();
      return null;
    }
    return { passes: prunePasses(snap.passes, now), savedAt: snap.savedAt };
  } catch {
    // Corrupt payload — drop it rather than retry-looping on every render.
    clearOfflinePasses();
    return null;
  }
}

/** One cached pass by id, or null. */
export function loadOfflinePass(
  userId: string,
  ticketId: string,
  now: number = Date.now(),
): { pass: PassRecord; savedAt: number } | null {
  const hit = loadOfflinePasses(userId, now);
  if (!hit) return null;
  const pass = hit.passes.find((p) => p.id === ticketId);
  return pass ? { pass, savedAt: hit.savedAt } : null;
}

/**
 * Merge a single freshly-read pass into the cache without clobbering the rest.
 * The pass views load one ticket at a time; My Tickets replaces the whole set.
 */
export function cacheOnePass(userId: string, pass: PassRecord, now: number = Date.now()): void {
  if (!userId || !pass?.id) return;
  const existing = loadOfflinePasses(userId, now)?.passes ?? [];
  saveOfflinePasses(userId, [pass, ...existing.filter((p) => p.id !== pass.id)], now);
}

/** Wipe the cache. Called on sign-out and whenever a foreign snapshot is seen. */
export function clearOfflinePasses(): void {
  const s = store();
  if (!s) return;
  try {
    s.removeItem(KEY);
  } catch {
    /* nothing we can do, and nothing that should break the caller */
  }
}

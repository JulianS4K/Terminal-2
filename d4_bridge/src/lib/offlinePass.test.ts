import { describe, it, expect, beforeEach, vi } from 'vitest';
import { Timestamp } from './timestamp';
import type { Event, Ticket } from '../types';
import {
  encodePasses,
  decodePasses,
  prunePasses,
  syncAge,
  saveOfflinePasses,
  loadOfflinePasses,
  loadOfflinePass,
  cacheOnePass,
  clearOfflinePasses,
  MAX_PASSES,
  MAX_AGE_MS,
  KEEP_AFTER_START_MS,
  type PassRecord,
} from './offlinePass';

// The module under test only touches localStorage + our own Timestamp, but it
// imports types from '../types', which pulls nothing at runtime. Supabase is
// mocked defensively in case the import graph grows a client reference.
vi.mock('./supabase', () => ({ supabase: {} }));

// vitest runs in the node environment here (no jsdom dependency in this repo),
// so stand up the smallest localStorage that satisfies the Storage contract
// the module actually uses. Installed on globalThis before any test runs;
// `store()` reads the global lazily, so this is picked up.
class MemoryStorage {
  private map = new Map<string, string>();
  get length() { return this.map.size; }
  key(i: number) { return [...this.map.keys()][i] ?? null; }
  getItem(k: string) { return this.map.has(k) ? (this.map.get(k) as string) : null; }
  setItem(k: string, v: string) { this.map.set(k, String(v)); }
  removeItem(k: string) { this.map.delete(k); }
  clear() { this.map.clear(); }
}
const memoryStorage = new MemoryStorage();
(globalThis as unknown as { localStorage: unknown }).localStorage = memoryStorage;

const NOW = Date.UTC(2026, 8, 12, 18, 0, 0);

function pass(id: string, startsInMs: number | null, extra: Partial<Ticket> = {}): PassRecord {
  const event = (
    startsInMs === null
      ? { id: `e-${id}`, title: `Event ${id}` }
      : { id: `e-${id}`, title: `Event ${id}`, date: Timestamp.fromMillis(NOW + startsInMs) }
  ) as unknown as Event;
  return {
    id,
    eventId: `e-${id}`,
    buyerId: 'u1',
    ownerId: 'u1',
    organizerId: 'org1',
    status: 'active',
    barcodeValue: '',
    barcodeSecret: `secret-${id}`,
    event,
    ...extra,
  } as PassRecord;
}

describe('encodePasses / decodePasses', () => {
  it('round-trips a Timestamp through JSON with .toDate() intact', () => {
    const original = pass('t1', 3600_000);
    const revived = decodePasses(JSON.parse(JSON.stringify(encodePasses(original)))) as PassRecord;
    expect(revived.event?.date).toBeInstanceOf(Timestamp);
    expect(revived.event?.date?.toDate().getTime()).toBe(NOW + 3600_000);
    expect(revived.barcodeSecret).toBe('secret-t1');
  });

  it('revives nested and array timestamps', () => {
    const input = { a: [Timestamp.fromMillis(5)], b: { c: Timestamp.fromMillis(7) } };
    const out = decodePasses(JSON.parse(JSON.stringify(encodePasses(input)))) as typeof input;
    expect(out.a[0].toMillis()).toBe(5);
    expect(out.b.c.toMillis()).toBe(7);
  });

  it('encodes a Date the same way', () => {
    const out = decodePasses(encodePasses({ d: new Date(1234) })) as { d: Timestamp };
    expect(out.d).toBeInstanceOf(Timestamp);
    expect(out.d.toMillis()).toBe(1234);
  });

  it('drops undefined so encode/decode stay symmetric', () => {
    expect(encodePasses({ a: 1, b: undefined })).toEqual({ a: 1 });
  });

  it('leaves a plain object that merely has extra keys alone', () => {
    // A real payload key called __ts alongside others must not be swallowed.
    const out = decodePasses({ __ts: 5, other: 1 }) as Record<string, unknown>;
    expect(out).toEqual({ __ts: 5, other: 1 });
  });
});

describe('prunePasses', () => {
  it('keeps upcoming events and drops ones long finished', () => {
    const kept = pass('keep', 2 * 3600_000);
    const grace = pass('grace', -(KEEP_AFTER_START_MS - 3600_000));
    const gone = pass('gone', -(KEEP_AFTER_START_MS + 3600_000));
    const ids = prunePasses([gone, kept, grace], NOW).map((p) => p.id);
    expect(ids).toContain('keep');
    expect(ids).toContain('grace');
    expect(ids).not.toContain('gone');
  });

  it('keeps a pass whose event date is unknown', () => {
    expect(prunePasses([pass('nodate', null)], NOW).map((p) => p.id)).toEqual(['nodate']);
  });

  it('keeps used and voided passes so the stamp still renders offline', () => {
    const used = pass('used', 3600_000, { status: 'used' });
    const voided = pass('void', 3600_000, { status: 'voided' });
    expect(prunePasses([used, voided], NOW)).toHaveLength(2);
  });

  it('sorts soonest first and caps the count', () => {
    const many = Array.from({ length: MAX_PASSES + 5 }, (_, i) =>
      pass(`p${i}`, (MAX_PASSES + 5 - i) * 3600_000),
    );
    const out = prunePasses(many, NOW);
    expect(out).toHaveLength(MAX_PASSES);
    expect(out[0].id).toBe(`p${MAX_PASSES + 4}`);
  });
});

describe('syncAge', () => {
  it('reports fresh, minutes, hours and days', () => {
    expect(syncAge(NOW - 5_000, NOW)).toEqual({ unit: 'now', value: 0 });
    expect(syncAge(NOW - 5 * 60_000, NOW)).toEqual({ unit: 'min', value: 5 });
    expect(syncAge(NOW - 3 * 3600_000, NOW)).toEqual({ unit: 'hour', value: 3 });
    expect(syncAge(NOW - 2 * 24 * 3600_000, NOW)).toEqual({ unit: 'day', value: 2 });
  });

  it('never reports a negative age from a clock that jumped back', () => {
    expect(syncAge(NOW + 10_000, NOW)).toEqual({ unit: 'now', value: 0 });
  });
});

describe('the storage seam', () => {
  beforeEach(() => {
    localStorage.clear();
  });

  it('saves and reads back a usable pass', () => {
    saveOfflinePasses('u1', [pass('t1', 3600_000)], NOW);
    const hit = loadOfflinePasses('u1', NOW);
    expect(hit?.savedAt).toBe(NOW);
    expect(hit?.passes[0].event?.date?.toDate().getTime()).toBe(NOW + 3600_000);
  });

  it('returns null and wipes the cache for a different user', () => {
    saveOfflinePasses('u1', [pass('t1', 3600_000)], NOW);
    expect(loadOfflinePasses('u2', NOW)).toBeNull();
    expect(loadOfflinePasses('u1', NOW)).toBeNull();
  });

  it('discards a snapshot older than the max age', () => {
    saveOfflinePasses('u1', [pass('t1', 3600_000)], NOW);
    expect(loadOfflinePasses('u1', NOW + MAX_AGE_MS + 1)).toBeNull();
  });

  it('drops corrupt JSON instead of throwing', () => {
    localStorage.setItem('vibepass:offline-passes:v1', '{not json');
    expect(loadOfflinePasses('u1', NOW)).toBeNull();
  });

  it('finds one pass by id', () => {
    saveOfflinePasses('u1', [pass('t1', 3600_000), pass('t2', 7200_000)], NOW);
    expect(loadOfflinePass('u1', 't2', NOW)?.pass.id).toBe('t2');
    expect(loadOfflinePass('u1', 'nope', NOW)).toBeNull();
  });

  it('merges one pass without dropping the others', () => {
    saveOfflinePasses('u1', [pass('t1', 3600_000), pass('t2', 7200_000)], NOW);
    cacheOnePass('u1', pass('t2', 7200_000, { status: 'used' }), NOW);
    const hit = loadOfflinePasses('u1', NOW);
    expect(hit?.passes.map((p) => p.id).sort()).toEqual(['t1', 't2']);
    expect(hit?.passes.find((p) => p.id === 't2')?.status).toBe('used');
  });

  it('clears on demand', () => {
    saveOfflinePasses('u1', [pass('t1', 3600_000)], NOW);
    clearOfflinePasses();
    expect(loadOfflinePasses('u1', NOW)).toBeNull();
  });

  it('never throws when storage rejects the write', () => {
    const spy = vi.spyOn(memoryStorage, 'setItem').mockImplementation(() => {
      throw new Error('QuotaExceededError');
    });
    const warn = vi.spyOn(console, 'warn').mockImplementation(() => {});
    expect(() => saveOfflinePasses('u1', [pass('t1', 3600_000)], NOW)).not.toThrow();
    spy.mockRestore();
    warn.mockRestore();
  });

  it('ignores an empty user id in both directions', () => {
    saveOfflinePasses('', [pass('t1', 3600_000)], NOW);
    expect(localStorage.getItem('vibepass:offline-passes:v1')).toBeNull();
    expect(loadOfflinePasses('', NOW)).toBeNull();
  });
});

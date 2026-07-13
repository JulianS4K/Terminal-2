import { describe, it, expect } from 'vitest';
import { OfflineCheckInQueue, type KeyValueStore, type PendingCheckIn } from './offlineQueue';

function memStore(): KeyValueStore {
  const m = new Map<string, string>();
  return {
    getItem: (k) => (m.has(k) ? m.get(k)! : null),
    setItem: (k, v) => void m.set(k, v),
    removeItem: (k) => void m.delete(k),
  };
}

const EVENT = 'evt-1';

describe('OfflineCheckInQueue', () => {
  it('enqueues and dedupes by ticket id (stable idempotency key)', () => {
    const q = new OfflineCheckInQueue(memStore(), EVENT);
    const a = q.enqueue({ ticketId: 't1', source: 'camera', verification: 'verified' });
    const b = q.enqueue({ ticketId: 't1', source: 'manual', verification: 'manual' });
    expect(q.size()).toBe(1);
    expect(a.idempotencyKey).toBe(b.idempotencyKey);
  });

  it('persists across instances (durability)', () => {
    const store = memStore();
    new OfflineCheckInQueue(store, EVENT).enqueue({ ticketId: 't1', source: 'camera', verification: 'verified' });
    const reopened = new OfflineCheckInQueue(store, EVENT);
    expect(reopened.size()).toBe(1);
  });

  it('flush drops committed and idempotent-used items, keeps thrown ones', async () => {
    const q = new OfflineCheckInQueue(memStore(), EVENT);
    q.enqueue({ ticketId: 'ok', source: 'camera', verification: 'verified' });
    q.enqueue({ ticketId: 'used', source: 'camera', verification: 'verified' });
    q.enqueue({ ticketId: 'boom', source: 'camera', verification: 'verified' });

    const replay = async (item: PendingCheckIn) => {
      if (item.ticketId === 'ok') return { ok: true, reason: 'checked-in' };
      if (item.ticketId === 'used') return { ok: false, reason: 'used' };
      throw new Error('network down');
    };
    const summary = await q.flush(replay);
    expect(summary.synced).toBe(2); // ok + used both leave the queue
    expect(summary.failed).toBe(1);
    const remaining = q.list();
    expect(remaining).toHaveLength(1);
    expect(remaining[0].ticketId).toBe('boom');
    expect(remaining[0].attempts).toBe(1);
    expect(remaining[0].lastError).toContain('network');
  });

  it('sends the SAME idempotency key on retry after a failure', async () => {
    const q = new OfflineCheckInQueue(memStore(), EVENT);
    const rec = q.enqueue({ ticketId: 't1', source: 'camera', verification: 'verified' });
    const seen: string[] = [];
    const failing = async (item: PendingCheckIn) => {
      seen.push(item.idempotencyKey);
      throw new Error('down');
    };
    await q.flush(failing);
    await q.flush(failing);
    expect(seen).toHaveLength(2);
    expect(seen[0]).toBe(rec.idempotencyKey);
    expect(seen[1]).toBe(rec.idempotencyKey); // crash-safe: stable across retries
  });
});

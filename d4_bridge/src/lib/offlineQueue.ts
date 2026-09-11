// Exos (Bridge / D4) — durable, idempotent, crash-safe check-in queue.
//
// The existing OrganizerCheckIn flow keeps a `pending_updates_${eventId}` array
// of ticket ids admitted offline and replays them on reconnect. That works, but
// it has two crash windows:
//
//   1. Double-count on crash-mid-flush. If the server commits the check-in but
//      the tab dies (or the network drops) before the id is removed from the
//      queue, the replay flips an already-'used' ticket again. Today that is
//      absorbed because a second flip returns {ok:false, reason:'used'} — but
//      the AUDIT row (exos_event_checkins) can still be written twice, inflating
//      the head-count. An IDEMPOTENCY KEY makes the server treat the retry as
//      the same logical check-in and return the first result verbatim.
//
//   2. Lost context on crash. The plain array carries only the ticket id, so a
//      replay can't record HOW the ticket was verified (camera vs manual,
//      signed payload vs staff override) or WHEN it was actually admitted. This
//      queue persists the full record, so the reconciled audit reflects reality
//      even if the reconnect happens hours later on a different device session.
//
// Storage is injected (any localStorage-shaped object) so the logic is pure and
// unit-testable, and so a future move to IndexedDB is a one-line swap.

export interface KeyValueStore {
  getItem(key: string): string | null;
  setItem(key: string, value: string): void;
  removeItem(key: string): void;
}

export interface PendingCheckIn {
  ticketId: string;
  eventId: string;
  /** Stable per-attempt key; the server dedupes replays on this. */
  idempotencyKey: string;
  /** ms epoch the ticket was actually admitted offline. */
  admittedAt: number;
  source: 'camera' | 'manual';
  verification: 'verified' | 'legacy' | 'manual';
  /** The scanned barcode payload, so the server can re-verify on replay. */
  barcodePayload?: string;
  attempts: number;
  lastError?: string;
}

function newIdempotencyKey(): string {
  // crypto.randomUUID is present in browsers (secure context) and Node 16+.
  if (typeof crypto !== 'undefined' && typeof crypto.randomUUID === 'function') {
    return crypto.randomUUID();
  }
  // Fallback: time + counter-ish. Only reached on ancient engines; the server
  // still dedupes on whatever value we send, so uniqueness is best-effort.
  return `idem-${Date.now().toString(36)}-${Math.floor(Math.random() * 1e9).toString(36)}`;
}

export class OfflineCheckInQueue {
  private readonly key: string;

  constructor(
    private readonly store: KeyValueStore,
    private readonly eventId: string,
  ) {
    this.key = `pending_checkins_v2_${eventId}`;
  }

  private read(): PendingCheckIn[] {
    const raw = this.store.getItem(this.key);
    if (!raw) return [];
    try {
      const parsed = JSON.parse(raw);
      return Array.isArray(parsed) ? (parsed as PendingCheckIn[]) : [];
    } catch {
      // Corrupt payload — drop it rather than wedge the queue forever.
      this.store.removeItem(this.key);
      return [];
    }
  }

  private write(items: PendingCheckIn[]): void {
    this.store.setItem(this.key, JSON.stringify(items));
  }

  list(): PendingCheckIn[] {
    return this.read();
  }

  size(): number {
    return this.read().length;
  }

  /**
   * Queue an offline-admitted check-in. Idempotent by ticket id: enqueuing the
   * same ticket twice keeps the FIRST record (and its idempotency key), so a
   * double-scan at the door can't create two queue entries that both replay.
   * Returns the record that is now queued (existing or new).
   */
  enqueue(input: {
    ticketId: string;
    source: 'camera' | 'manual';
    verification: 'verified' | 'legacy' | 'manual';
    barcodePayload?: string;
    admittedAt?: number;
  }): PendingCheckIn {
    const items = this.read();
    const existing = items.find((i) => i.ticketId === input.ticketId);
    if (existing) return existing;
    const record: PendingCheckIn = {
      ticketId: input.ticketId,
      eventId: this.eventId,
      idempotencyKey: newIdempotencyKey(),
      admittedAt: input.admittedAt ?? Date.now(),
      source: input.source,
      verification: input.verification,
      barcodePayload: input.barcodePayload,
      attempts: 0,
    };
    items.push(record);
    this.write(items);
    return record;
  }

  /** Remove a successfully-synced check-in from the queue. */
  markSynced(ticketId: string): void {
    this.write(this.read().filter((i) => i.ticketId !== ticketId));
  }

  /** Record a failed replay (keeps the item queued, bumps attempts). */
  markFailed(ticketId: string, error?: string): void {
    const items = this.read();
    const item = items.find((i) => i.ticketId === ticketId);
    if (!item) return;
    item.attempts += 1;
    item.lastError = error;
    this.write(items);
  }

  clear(): void {
    this.store.removeItem(this.key);
  }

  /**
   * Flush the queue through the supplied replayer. Each item is retried
   * independently (one failure never aborts the rest), carrying its stable
   * idempotency key so a server that already committed the first attempt
   * returns the same result instead of double-recording. Returns a summary.
   */
  async flush(
    replay: (item: PendingCheckIn) => Promise<{ ok: boolean; reason?: string }>,
  ): Promise<{ synced: number; failed: number }> {
    let synced = 0;
    let failed = 0;
    for (const item of this.read()) {
      try {
        const result = await replay(item);
        // A committed check-in OR an idempotent "already used" both mean the
        // server has this check-in — drop it from the queue either way. Only a
        // thrown error (network/auth) keeps it for the next flush.
        if (result.ok || result.reason === 'used' || result.reason === 'duplicate') {
          this.markSynced(item.ticketId);
          synced += 1;
        } else {
          this.markFailed(item.ticketId, result.reason);
          failed += 1;
        }
      } catch (err) {
        this.markFailed(item.ticketId, err instanceof Error ? err.message : String(err));
        failed += 1;
      }
    }
    return { synced, failed };
  }
}

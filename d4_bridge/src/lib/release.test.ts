import { describe, it, expect } from 'vitest';
import { canHolderRelease } from './release';
import { Timestamp } from './timestamp';
import type { Event, Ticket } from '../types';

const NOW = Date.UTC(2026, 8, 11, 12, 0, 0);
const H = 3600_000;
const ev = (over: Partial<Event> = {}): Event =>
  ({ id: 'e', title: 'E', description: '', date: Timestamp.fromMillis(NOW + 48 * H), location: '', price: 0, organizerId: 'o', totalTickets: 1, ticketsSold: 1, image: '', category: '', status: 'published', ...over }) as Event;
const tk = (over: Partial<Ticket> = {}): Ticket =>
  ({ id: 't', eventId: 'e', buyerId: 'u', ownerId: 'u', organizerId: 'o', status: 'active', pendingTransferId: null, pricePaid: 0, purchaseDate: Timestamp.fromMillis(NOW), barcodeValue: '', ...over }) as Ticket;

describe('canHolderRelease', () => {
  it('allows a free active ticket on a published upcoming event', () => {
    expect(canHolderRelease(tk(), ev(), NOW)).toEqual({ ok: true });
  });
  it('blocks used / voided / in-transfer / paid tickets', () => {
    expect(canHolderRelease(tk({ status: 'used' }), ev(), NOW).reason).toBe('not-active');
    expect(canHolderRelease(tk({ status: 'voided' }), ev(), NOW).reason).toBe('not-active');
    expect(canHolderRelease(tk({ pendingTransferId: 'x' }), ev(), NOW).reason).toBe('in-transfer');
    expect(canHolderRelease(tk({ pricePaid: 25 }), ev(), NOW).reason).toBe('paid');
  });
  it('respects organizer policy, cancellation and start time', () => {
    expect(canHolderRelease(tk(), ev({ allowHolderRelease: false }), NOW).reason).toBe('policy-off');
    expect(canHolderRelease(tk(), ev({ status: 'cancelled' }), NOW).reason).toBe('cancelled');
    expect(canHolderRelease(tk(), ev({ date: Timestamp.fromMillis(NOW - H) }), NOW).reason).toBe('started');
  });
  it('applies the cutoff window and reports when it closes', () => {
    const open = canHolderRelease(tk(), ev({ releaseCutoffHours: 24 }), NOW);
    expect(open.ok).toBe(true);
    expect(open.closesAt?.getTime()).toBe(NOW + 24 * H);
    const closed = canHolderRelease(tk(), ev({ date: Timestamp.fromMillis(NOW + 10 * H), releaseCutoffHours: 24 }), NOW);
    expect(closed).toMatchObject({ ok: false, reason: 'cutoff' });
  });
  it('treats an unknown price as free and a missing event as allowed (server decides)', () => {
    expect(canHolderRelease(tk({ pricePaid: undefined }), undefined, NOW).ok).toBe(true);
  });
});

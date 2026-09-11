import { describe, it, expect } from 'vitest';
import { activeCount, isArchived, groupStamp, splitGroups, EVENT_GRACE_MS, type TicketWithEvent } from './ticketGroups';
import { Timestamp } from './timestamp';
import type { Event, Ticket } from '../types';

const NOW = Date.UTC(2026, 8, 11, 12, 0, 0);
const H = 3600_000;

function ev(id: string, at: number, status: Event['status'] = 'published'): Event {
  return { id, title: id, description: '', date: Timestamp.fromMillis(at), location: '', price: 0, organizerId: 'o', totalTickets: 1, ticketsSold: 1, image: '', category: '', status } as Event;
}
function tk(id: string, e: Event, status: Ticket['status'] = 'active', pending: string | null = null): TicketWithEvent {
  return { id, eventId: e.id, buyerId: 'u', ownerId: 'u', organizerId: 'o', status, pendingTransferId: pending, purchaseDate: Timestamp.fromMillis(NOW), barcodeValue: '', event: e } as TicketWithEvent;
}

describe('activeCount / isArchived / groupStamp', () => {
  const soon = ev('soon', NOW + 24 * H);
  it('counts scannable passes only', () => {
    expect(activeCount([tk('1', soon), tk('2', soon, 'used'), tk('3', soon, 'active', 'tr'), tk('4', soon, 'voided')])).toBe(1);
  });
  it('an upcoming event with an active pass is active', () => {
    const g = [tk('1', soon), tk('2', soon, 'used')];
    expect(isArchived(g, NOW)).toBe(false);
    expect(groupStamp(g, NOW)).toBe('active');
  });
  it('past events archive after the grace window', () => {
    const justStarted = ev('js', NOW - 2 * H);
    const long = ev('long', NOW - EVENT_GRACE_MS - H);
    expect(isArchived([tk('1', justStarted)], NOW)).toBe(false);
    expect(isArchived([tk('1', long)], NOW)).toBe(true);
    expect(groupStamp([tk('1', long)], NOW)).toBe('past');
  });
  it('all used or voided archives even when upcoming; cancelled archives', () => {
    expect(isArchived([tk('1', soon, 'used'), tk('2', soon, 'voided')], NOW)).toBe(true);
    expect(groupStamp([tk('1', soon, 'used'), tk('2', soon, 'voided')], NOW)).toBe('used');
    expect(groupStamp([tk('1', soon, 'voided')], NOW)).toBe('voided');
    expect(isArchived([tk('1', ev('c', NOW + H, 'cancelled'))], NOW)).toBe(true);
  });
  it('a pass in transfer is not active but the group stays in ACTIVE until the event passes', () => {
    const g = [tk('1', soon, 'active', 'tr')];
    expect(activeCount(g)).toBe(0);
    expect(isArchived(g, NOW)).toBe(false);
    expect(groupStamp(g, NOW)).toBe('transfer');
  });
});

describe('splitGroups', () => {
  it('sorts active by soonest event and archive by most recent', () => {
    const a = ev('a', NOW + 48 * H), b = ev('b', NOW + 2 * H), c = ev('c', NOW - 10 * H), d = ev('d', NOW - 30 * H);
    const { active, archive } = splitGroups({ a: [tk('1', a)], b: [tk('2', b)], c: [tk('3', c)], d: [tk('4', d)] }, NOW);
    expect(active.map(([id]) => id)).toEqual(['b', 'a']);
    expect(archive.map(([id]) => id)).toEqual(['c', 'd']);
  });
});

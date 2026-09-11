import { describe, it, expect, vi } from 'vitest';

// The module under test pulls the Supabase client in for its fetchers; the
// resolvers are pure, so stub the client (no env in unit tests).
vi.mock('./supabase', () => ({ supabase: {} }));
import {
  reminderItems,
  cancellationItems,
  announcementItems,
  rescheduleItems,
  priceStepItems,
  ticketsByEvent,
  type TicketWithEvent,
} from './notifications';
import { Timestamp } from './timestamp';
import type { Event, Ticket } from '../types';

const NOW = Date.UTC(2026, 8, 11, 12, 0, 0); // 2026-09-11T12:00Z
const H = 3600_000;

function event(over: Partial<Event> & { id: string; at: number }): Event {
  const { at, ...rest } = over;
  return {
    id: over.id,
    title: 'Evt ' + over.id,
    description: '',
    date: Timestamp.fromMillis(at),
    location: 'Brooklyn Steel',
    price: 0,
    organizerId: 'org',
    totalTickets: 10,
    ticketsSold: 1,
    image: '',
    category: 'Music',
    status: 'published',
    timezone: 'America/New_York',
    currency: 'USD',
    ...rest,
  } as Event;
}

function ticket(id: string, ev: Event, status: Ticket['status'] = 'active'): TicketWithEvent {
  return {
    id,
    eventId: ev.id,
    buyerId: 'u',
    ownerId: 'u',
    organizerId: 'org',
    status,
    purchaseDate: Timestamp.fromMillis(NOW - 5 * H),
    barcodeValue: '',
    event: ev,
  } as TicketWithEvent;
}

describe('reminderItems', () => {
  it('emits a day-before alert inside 24h and a starts-soon alert inside 2h', () => {
    const e1 = event({ id: 'a', at: NOW + 20 * H });
    const e2 = event({ id: 'b', at: NOW + 90 * 60_000 });
    const items = reminderItems([ticket('t1', e1), ticket('t2', e2)], NOW);
    expect(items.map((i) => i.id).sort()).toEqual(['rem-24h-a', 'rem-2h-b']);
    const soon = items.find((i) => i.id === 'rem-2h-b')!;
    expect(soon.title).toBe('Evt b starts in 2h');
    expect(soon.to).toBe('/ticket/t2');
    const tomorrow = items.find((i) => i.id === 'rem-24h-a')!;
    expect(tomorrow.title).toBe('Tomorrow: Evt a');
    expect(tomorrow.body).toContain('Brooklyn Steel');
  });

  it('skips past, far-future, cancelled, used and voided cases and dedupes per event', () => {
    const past = event({ id: 'p', at: NOW - H });
    const far = event({ id: 'f', at: NOW + 30 * H });
    const can = event({ id: 'c', at: NOW + 3 * H, status: 'cancelled' });
    const ok = event({ id: 'o', at: NOW + 3 * H });
    const items = reminderItems(
      [
        ticket('1', past),
        ticket('2', far),
        ticket('3', can),
        ticket('4', ok, 'used'),
        ticket('5', ok, 'voided'),
        ticket('6', ok),
        ticket('7', ok), // second active ticket → still one item
      ],
      NOW,
    );
    expect(items.map((i) => i.id)).toEqual(['rem-24h-o']);
    expect(items[0].to).toBe('/ticket/6');
  });
});

describe('cancellationItems', () => {
  it('flags cancelled ticketed events with the reason, once per event', () => {
    const c = event({ id: 'c', at: NOW + 48 * H, status: 'cancelled', cancelReason: 'Venue flooded', cancelledAt: Timestamp.fromMillis(NOW - H) });
    const items = cancellationItems([ticket('x', c), ticket('y', c), ticket('z', event({ id: 'live', at: NOW + H }))]);
    expect(items).toHaveLength(1);
    expect(items[0]).toMatchObject({ id: 'can-c', icon: 'cancel', body: 'Venue flooded', to: '/ticket/x', ts: NOW - H });
  });

  it('ignores voided tickets on a cancelled event', () => {
    const c = event({ id: 'c', at: NOW + 48 * H, status: 'cancelled' });
    expect(cancellationItems([ticket('x', c, 'voided')])).toEqual([]);
  });
});

describe('announcementItems / rescheduleItems', () => {
  const e = event({ id: 'e', at: NOW + 48 * H });
  const byEvent = ticketsByEvent([ticket('tk', e)]);

  it('links announcements to the holder ticket and marks recent ones unread', () => {
    const items = announcementItems(
      [
        { id: 'a1', event_id: 'e', subject: 'Doors 7pm', body: 'Come early.', created_at: new Date(NOW - 2 * H).toISOString() },
        { id: 'a2', event_id: 'other', subject: 'Old', body: 'x', created_at: new Date(NOW - 30 * 24 * H).toISOString() },
      ],
      byEvent,
      NOW,
    );
    expect(items[0]).toMatchObject({ id: 'ann-a1', title: 'Evt e: Doors 7pm', to: '/ticket/tk', unread: true, icon: 'announce' });
    expect(items[1]).toMatchObject({ id: 'ann-a2', title: 'Old', to: '/event/other', unread: false });
  });

  it('renders reschedules with old and new times in the event zone', () => {
    const items = rescheduleItems(
      [{ id: 'r1', event_id: 'e', old_starts_at: '2026-09-13T00:00:00Z', new_starts_at: '2026-09-20T00:00:00Z', reason: 'Artist travel', created_at: new Date(NOW - H).toISOString() }],
      byEvent,
      NOW,
    );
    expect(items[0].title).toBe('Rescheduled: Evt e');
    expect(items[0].body).toContain('Now Sep 19, 2026');
    expect(items[0].body).toContain('was Sep 12, 2026');
    expect(items[0].body).toContain('Artist travel');
    expect(items[0].unread).toBe(true);
  });
});

describe('priceStepItems', () => {
  it('nudges on the earliest step within a week across public tiers, one per saved event', () => {
    const e = event({ id: 's', at: NOW + 10 * 24 * H });
    const items = priceStepItems(
      [e],
      [
        { event_id: 's', name: 'GA', price_schedule: [{ startsAt: new Date(NOW + 3 * 24 * H).toISOString(), price: 40 }] },
        { event_id: 's', name: 'VIP', price_schedule: [{ startsAt: new Date(NOW + 2 * 24 * H).toISOString(), price: 120 }] },
        { event_id: 'zzz', name: 'GA', price_schedule: [{ startsAt: new Date(NOW + H).toISOString(), price: 1 }] },
      ],
      NOW,
    );
    expect(items).toHaveLength(1);
    expect(items[0].body).toContain('VIP goes to $120.00');
    expect(items[0].to).toBe('/event/s');
  });

  it('ignores steps more than a week out, past steps, and cancelled events', () => {
    const e = event({ id: 's', at: NOW + 30 * 24 * H });
    const far = [{ event_id: 's', name: 'GA', price_schedule: [{ startsAt: new Date(NOW + 9 * 24 * H).toISOString(), price: 40 }] }];
    const past = [{ event_id: 's', name: 'GA', price_schedule: [{ startsAt: new Date(NOW - H).toISOString(), price: 40 }] }];
    expect(priceStepItems([e], far, NOW)).toEqual([]);
    expect(priceStepItems([e], past, NOW)).toEqual([]);
    expect(priceStepItems([{ ...e, status: 'cancelled' }], [{ event_id: 's', name: 'GA', price_schedule: [{ startsAt: new Date(NOW + H).toISOString(), price: 40 }] }], NOW)).toEqual([]);
  });
});

import { describe, it, expect } from 'vitest';
import { collapseSeries, seriesSiblings } from './seriesGroups';
import { Timestamp } from './timestamp';
import type { Event } from '../types';

const NOW = Date.UTC(2026, 8, 11, 12, 0, 0);
const D = 24 * 3600_000;
const ev = (id: string, at: number, seriesId?: string): Event =>
  ({ id, title: id, description: '', date: Timestamp.fromMillis(at), location: '', price: 0, organizerId: 'o', totalTickets: 1, ticketsSold: 0, image: '', category: '', status: 'published', seriesId }) as Event;

describe('collapseSeries', () => {
  it('keeps standalone events and collapses a series to its next occurrence with a date count', () => {
    const list = [
      ev('solo1', NOW + 1 * D),
      ev('fri-past', NOW - 8 * D, 's1'),
      ev('fri1', NOW + 2 * D, 's1'),
      ev('solo2', NOW + 3 * D),
      ev('fri2', NOW + 9 * D, 's1'),
      ev('fri3', NOW + 16 * D, 's1'),
    ];
    const { list: out, dates } = collapseSeries(list, NOW);
    expect(out.map((e) => e.id)).toEqual(['solo1', 'fri1', 'solo2']);
    expect(dates.get('fri1')).toBe(3); // past member excluded from the count
    expect(dates.has('solo1')).toBe(false);
  });
  it('a series with a single upcoming date gets no badge, and an all-past series shows its earliest', () => {
    const one = collapseSeries([ev('a', NOW + D, 's'), ev('b', NOW - 5 * D, 's')], NOW);
    expect(one.list.map((e) => e.id)).toEqual(['a']);
    expect(one.dates.size).toBe(0);
    const past = collapseSeries([ev('y', NOW - 2 * D, 's'), ev('x', NOW - 5 * D, 's')], NOW);
    expect(past.list.map((e) => e.id)).toEqual(['x']);
  });
  it('a show that started within the grace window still counts as next', () => {
    const { list } = collapseSeries([ev('now', NOW - 3600_000, 's'), ev('later', NOW + 7 * D, 's')], NOW);
    expect(list[0].id).toBe('now');
  });
});

describe('seriesSiblings', () => {
  it('lists upcoming other dates soonest first, and nothing for standalone events', () => {
    const cur = ev('fri1', NOW + 2 * D, 's1');
    const members = [ev('fri-past', NOW - 8 * D, 's1'), cur, ev('fri3', NOW + 16 * D, 's1'), ev('fri2', NOW + 9 * D, 's1'), ev('other', NOW + 4 * D, 's2')];
    expect(seriesSiblings(cur, members, NOW).map((e) => e.id)).toEqual(['fri2', 'fri3']);
    expect(seriesSiblings(ev('solo', NOW + D), members, NOW)).toEqual([]);
  });
});

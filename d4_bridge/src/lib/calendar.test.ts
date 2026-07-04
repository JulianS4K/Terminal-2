import { describe, it, expect } from 'vitest';
import { Timestamp } from './timestamp';
import {
  eventCalendarFields,
  googleCalendarUrl,
  icsForEvent,
  icsFilename,
} from './calendar';
import type { Event } from '../types';

const start = new Date('2026-08-15T23:30:00Z');
const end = new Date('2026-08-16T03:00:00Z');

function makeEvent(over: Partial<Event> = {}): Event {
  return {
    id: 'abc-123',
    title: 'Skrillex: Quest Tour',
    description: 'Doors 7pm.\nAll ages.',
    location: 'Brooklyn Steel',
    address: { street: '319 Frost St', city: 'Brooklyn', region: 'NY', postal: '11222' },
    date: Timestamp.fromDate(start),
    timing: { startTime: Timestamp.fromDate(start), endTime: Timestamp.fromDate(end) },
    ...over,
  } as Event;
}

describe('eventCalendarFields', () => {
  it('joins location + structured address and builds the public url', () => {
    const f = eventCalendarFields(makeEvent())!;
    expect(f.location).toBe('Brooklyn Steel, 319 Frost St, Brooklyn, NY, 11222');
    expect(f.url).toBe('/event/abc-123');
  });

  it('returns null when there is no start instant', () => {
    expect(eventCalendarFields({ id: 'x', title: 'T' } as Event)).toBeNull();
  });

  it('defaults to a 2h block when end is missing or before start', () => {
    const f = eventCalendarFields(
      makeEvent({ timing: { startTime: Timestamp.fromDate(start), endTime: Timestamp.fromDate(new Date('2020-01-01T00:00:00Z')) } }),
    )!;
    expect(f.end.getTime() - f.start.getTime()).toBe(2 * 60 * 60 * 1000);
  });
});

describe('googleCalendarUrl', () => {
  it('encodes title, UTC dates, and location', () => {
    const g = googleCalendarUrl(makeEvent())!;
    expect(g).toContain('dates=20260815T233000Z%2F20260816T030000Z');
    expect(g).toContain('text=Skrillex%3A+Quest+Tour');
    expect(g).toContain('location=Brooklyn+Steel');
  });
  it('returns null without a start instant', () => {
    expect(googleCalendarUrl({ id: 'x', title: 'T' } as Event)).toBeNull();
  });
});

describe('icsForEvent', () => {
  const ics = icsForEvent(makeEvent(), new Date('2026-07-04T00:00:00Z'))!;

  it('is a CRLF VCALENDAR envelope with UTC stamps', () => {
    expect(ics.includes('\r\n')).toBe(true);
    expect(ics.startsWith('BEGIN:VCALENDAR')).toBe(true);
    expect(ics.trim().endsWith('END:VCALENDAR')).toBe(true);
    expect(ics).toMatch(/DTSTART:20260815T233000Z/);
    expect(ics).toMatch(/DTEND:20260816T030000Z/);
    expect(ics).toMatch(/DTSTAMP:20260704T000000Z/);
  });

  it('escapes text fields (newline -> \\n) and appends the url', () => {
    const desc = ics.split('\r\n').find((l) => l.startsWith('DESCRIPTION'))!;
    expect(desc).toBe('DESCRIPTION:Doors 7pm.\\nAll ages.\\n\\n/event/abc-123');
  });
});

describe('icsFilename', () => {
  it('slugifies the title', () => {
    expect(icsFilename(makeEvent())).toBe('skrillex-quest-tour.ics');
    expect(icsFilename(makeEvent({ title: '' }))).toBe('event.ics');
  });
});

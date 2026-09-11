import { describe, it, expect } from 'vitest';
import {
  addLocalDays,
  generateRecurring,
  generateTimedEntry,
  localDateRange,
  localWeekday,
  occurrenceLabel,
  MAX_OCCURRENCES,
} from './seriesModel';

const NY = 'America/New_York';

describe('addLocalDays / localWeekday', () => {
  it('rolls month ends and reports weekdays', () => {
    expect(addLocalDays('2026-01-31', 1)).toBe('2026-02-01');
    expect(addLocalDays('2026-03-01', -1)).toBe('2026-02-28');
    expect(localWeekday('2026-09-11')).toBe(5); // Friday
  });
});

describe('generateRecurring', () => {
  it('daily × count keeps the wall-clock across a DST change', () => {
    // 2026-11-01 02:00 is the US fall-back in New York.
    const out = generateRecurring({
      kind: 'recurring', start: '2026-10-30T20:00', timezone: NY, freq: 'daily', interval: 1, count: 3,
    });
    expect(out.map((d) => occurrenceLabel(d, NY))).toEqual([
      '2026-10-31 20:00', '2026-11-01 20:00', '2026-11-02 20:00',
    ]);
    // …which means the UTC instants are NOT 24h apart across the change
    // (Oct 31 20:00 EDT → Nov 1 20:00 EST is 25h; the next step is 24h again).
    expect(out[1].getTime() - out[0].getTime()).toBe(25 * 3600 * 1000);
    expect(out[2].getTime() - out[1].getTime()).toBe(24 * 3600 * 1000);
  });

  it('weekly on chosen weekdays until a date, excluding the template start', () => {
    // Template: Friday 2026-09-11 20:00. Fire Fri + Sat until 2026-09-26.
    const out = generateRecurring({
      kind: 'recurring', start: '2026-09-11T20:00', timezone: NY, freq: 'weekly', interval: 1,
      weekdays: [5, 6], until: '2026-09-26',
    });
    expect(out.map((d) => occurrenceLabel(d, NY))).toEqual([
      '2026-09-12 20:00', '2026-09-18 20:00', '2026-09-19 20:00', '2026-09-25 20:00', '2026-09-26 20:00',
    ]);
  });

  it('every-2-weeks skips alternate weeks', () => {
    const out = generateRecurring({
      kind: 'recurring', start: '2026-09-11T20:00', timezone: NY, freq: 'weekly', interval: 2, count: 3,
    });
    expect(out.map((d) => occurrenceLabel(d, NY))).toEqual([
      '2026-09-25 20:00', '2026-10-09 20:00', '2026-10-23 20:00',
    ]);
  });

  it('needs a stop condition and caps at MAX_OCCURRENCES', () => {
    expect(generateRecurring({ kind: 'recurring', start: '2026-09-11T20:00', timezone: NY, freq: 'daily', interval: 1 })).toEqual([]);
    const out = generateRecurring({ kind: 'recurring', start: '2026-09-11T20:00', timezone: NY, freq: 'daily', interval: 1, count: 999 });
    expect(out).toHaveLength(MAX_OCCURRENCES);
  });
});

describe('generateTimedEntry', () => {
  it('lays out slots per day, slotMinutes apart, in the event tz', () => {
    const out = generateTimedEntry({
      kind: 'timed-entry', days: ['2026-09-12', '2026-09-12', '2026-09-13'], timezone: NY,
      firstSlot: '10:00', slotMinutes: 90, slotsPerDay: 3,
    });
    expect(out.map((d) => occurrenceLabel(d, NY))).toEqual([
      '2026-09-12 10:00', '2026-09-12 11:30', '2026-09-12 13:00',
      '2026-09-13 10:00', '2026-09-13 11:30', '2026-09-13 13:00',
    ]);
  });

  it('rejects a malformed first slot', () => {
    expect(generateTimedEntry({ kind: 'timed-entry', days: ['2026-09-12'], timezone: NY, firstSlot: '10', slotMinutes: 60, slotsPerDay: 2 })).toEqual([]);
  });
});

describe('localDateRange', () => {
  it('is inclusive and refuses a reversed range', () => {
    expect(localDateRange('2026-09-11', '2026-09-13')).toEqual(['2026-09-11', '2026-09-12', '2026-09-13']);
    expect(localDateRange('2026-09-13', '2026-09-11')).toEqual([]);
  });
});

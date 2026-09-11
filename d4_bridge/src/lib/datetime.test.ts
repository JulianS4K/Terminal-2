import { describe, it, expect } from 'vitest';
import {
  isValidTimezone,
  isWithinHoursBefore,
  zonedWallClockToUtc,
  utcToZonedWallClock,
  utcToOccursAtLocal,
  formatInTz,
} from './datetime';

const NY = 'America/New_York';
const LA = 'America/Los_Angeles';
const BERLIN = 'Europe/Berlin';

describe('isValidTimezone', () => {
  it('accepts IANA zones and rejects junk', () => {
    expect(isValidTimezone(NY)).toBe(true);
    expect(isValidTimezone('UTC')).toBe(true);
    expect(isValidTimezone('')).toBe(false);
    expect(isValidTimezone('Mars/Olympus_Mons')).toBe(false);
  });
});

describe('isWithinHoursBefore', () => {
  it('opens the window once now >= date - hours, and never locks out on a missing date', () => {
    const in23h = new Date(Date.now() + 23 * 3600_000);
    const in25h = new Date(Date.now() + 25 * 3600_000);
    expect(isWithinHoursBefore(in23h, 24)).toBe(true);
    expect(isWithinHoursBefore(in25h, 24)).toBe(false);
    expect(isWithinHoursBefore(null, 24)).toBe(true);
  });
});

describe('zonedWallClockToUtc', () => {
  it('interprets a datetime-local string in the given zone (EDT)', () => {
    // 8pm New York on 2026-07-04 is EDT (UTC-4) → 00:00Z next day.
    expect(zonedWallClockToUtc('2026-07-04T20:00', NY)?.toISOString()).toBe('2026-07-05T00:00:00.000Z');
  });

  it('handles standard time (EST) and other zones', () => {
    expect(zonedWallClockToUtc('2026-01-15T20:00', NY)?.toISOString()).toBe('2026-01-16T01:00:00.000Z');
    expect(zonedWallClockToUtc('2026-01-15T20:00', LA)?.toISOString()).toBe('2026-01-16T04:00:00.000Z');
    expect(zonedWallClockToUtc('2026-07-15T20:00', BERLIN)?.toISOString()).toBe('2026-07-15T18:00:00.000Z');
  });

  it('accepts optional seconds and rejects unparseable input', () => {
    expect(zonedWallClockToUtc('2026-07-04T20:00:30', 'UTC')?.toISOString()).toBe('2026-07-04T20:00:30.000Z');
    expect(zonedWallClockToUtc('', NY)).toBeNull();
    expect(zonedWallClockToUtc('July 4 8pm', NY)).toBeNull();
    expect(zonedWallClockToUtc('2026-07-04', NY)).toBeNull();
  });

  it('is exact across the spring-forward DST boundary', () => {
    // US DST 2026 begins 2026-03-08 02:00 local. 01:30 is still EST (UTC-5);
    // 03:30 is EDT (UTC-4).
    expect(zonedWallClockToUtc('2026-03-08T01:30', NY)?.toISOString()).toBe('2026-03-08T06:30:00.000Z');
    expect(zonedWallClockToUtc('2026-03-08T03:30', NY)?.toISOString()).toBe('2026-03-08T07:30:00.000Z');
  });

  it('round-trips through utcToZonedWallClock', () => {
    for (const [wall, tz] of [
      ['2026-07-04T20:00', NY],
      ['2026-12-31T23:59', LA],
      ['2026-10-25T02:30', BERLIN],
    ] as const) {
      const utc = zonedWallClockToUtc(wall, tz)!;
      expect(utcToZonedWallClock(utc, tz)).toBe(wall);
    }
  });
});

describe('utcToOccursAtLocal', () => {
  it('renders the TEvo-style local string with the correct offset suffix', () => {
    const utc = new Date('2026-05-22T00:00:00Z'); // 8pm EDT on 2026-05-21
    expect(utcToOccursAtLocal(utc, NY)).toBe('2026-05-21T20:00:00-04:00');
    expect(utcToOccursAtLocal(new Date('2026-01-16T01:00:00Z'), NY)).toBe('2026-01-15T20:00:00-05:00');
    expect(utcToOccursAtLocal(new Date('2026-07-15T18:00:00Z'), BERLIN)).toBe('2026-07-15T20:00:00+02:00');
    expect(utcToOccursAtLocal(new Date('2026-07-15T18:00:00Z'), 'UTC')).toBe('2026-07-15T18:00:00+00:00');
  });

  it('handles half-hour offsets', () => {
    expect(utcToOccursAtLocal(new Date('2026-07-15T12:00:00Z'), 'Asia/Kolkata')).toBe('2026-07-15T17:30:00+05:30');
  });

  it('returns empty for a missing date', () => {
    expect(utcToOccursAtLocal(null, NY)).toBe('');
    expect(utcToOccursAtLocal(undefined, NY)).toBe('');
  });
});

describe('formatInTz', () => {
  it('formats in the event zone regardless of the viewer zone', () => {
    const utc = new Date('2026-05-22T00:00:00Z');
    const out = formatInTz(utc, NY, { hour: 'numeric', minute: '2-digit', hour12: true });
    expect(out.replace(/ /g, ' ')).toBe('8:00 PM');
    expect(formatInTz(null, NY)).toBe('');
  });
});

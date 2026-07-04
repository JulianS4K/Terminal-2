import { describe, it, expect } from 'vitest';
import { normalizeSchedule, effectiveTierPrice, nextPriceStep } from './pricing';

const NOW = new Date('2026-07-04T12:00:00Z');
const past1 = '2026-07-01T00:00:00Z';
const past2 = '2026-07-03T00:00:00Z';
const future = '2026-07-10T00:00:00Z';

describe('normalizeSchedule', () => {
  it('drops non-arrays and malformed entries', () => {
    expect(normalizeSchedule(undefined)).toEqual([]);
    expect(normalizeSchedule('nope')).toEqual([]);
    expect(normalizeSchedule([{ price: 'x', startsAt: past1 }])).toEqual([]);
    expect(normalizeSchedule([{ price: -5, startsAt: past1 }])).toEqual([]);
    expect(normalizeSchedule([{ price: 10, startsAt: 'not-a-date' }])).toEqual([]);
    expect(normalizeSchedule([{ price: 10 }])).toEqual([]);
  });

  it('sorts ascending by time and normalizes to ISO', () => {
    const out = normalizeSchedule([
      { price: 30, startsAt: past2 },
      { price: 20, startsAt: past1 },
    ]);
    expect(out.map((s) => s.price)).toEqual([20, 30]);
    expect(out[0].startsAt).toBe(new Date(past1).toISOString());
  });

  it('keeps zero as a valid price', () => {
    expect(normalizeSchedule([{ price: 0, startsAt: past1 }])).toHaveLength(1);
  });
});

describe('effectiveTierPrice', () => {
  it('returns base when schedule empty/invalid', () => {
    expect(effectiveTierPrice(50, undefined, NOW)).toBe(50);
    expect(effectiveTierPrice(50, [], NOW)).toBe(50);
  });

  it('returns base when every step is in the future', () => {
    expect(effectiveTierPrice(50, [{ price: 80, startsAt: future }], NOW)).toBe(50);
  });

  it('applies the latest already-active step', () => {
    const sched = [
      { price: 60, startsAt: past1 },
      { price: 75, startsAt: past2 },
      { price: 90, startsAt: future },
    ];
    expect(effectiveTierPrice(50, sched, NOW)).toBe(75);
  });

  it('treats startsAt == now as active (inclusive)', () => {
    expect(effectiveTierPrice(50, [{ price: 65, startsAt: NOW.toISOString() }], NOW)).toBe(65);
  });
});

describe('nextPriceStep', () => {
  it('returns the soonest future step', () => {
    const next = nextPriceStep(
      [{ price: 90, startsAt: future }, { price: 75, startsAt: past2 }],
      NOW,
    );
    expect(next?.price).toBe(90);
  });

  it('returns null when nothing upcoming', () => {
    expect(nextPriceStep([{ price: 75, startsAt: past2 }], NOW)).toBeNull();
    expect(nextPriceStep([], NOW)).toBeNull();
  });
});

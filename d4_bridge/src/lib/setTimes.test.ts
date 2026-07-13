import { describe, it, expect } from 'vitest';
import { normalizeSetTimes, setTimesToRows, MAX_SET_TIMES, type SetTimeRow } from './setTimes';
import { Timestamp } from './timestamp';

describe('normalizeSetTimes', () => {
  it('drops rows missing a label or a time', () => {
    const rows: SetTimeRow[] = [
      { label: '', local: '2026-08-01T20:00' },
      { label: 'Opener', local: '' },
      { label: '   ', local: '2026-08-01T20:00' },
    ];
    expect(normalizeSetTimes(rows, 'UTC')).toEqual([]);
  });

  it('converts venue wall-clock (UTC zone) to the same ISO instant', () => {
    const out = normalizeSetTimes([{ label: 'Headliner', local: '2026-08-01T21:30' }], 'UTC');
    expect(out).toHaveLength(1);
    expect(out[0].label).toBe('Headliner');
    expect(out[0].at).toBe('2026-08-01T21:30:00.000Z');
  });

  it('sorts chronologically regardless of entry order', () => {
    const out = normalizeSetTimes(
      [
        { label: 'Headliner', local: '2026-08-01T21:30' },
        { label: 'Opener', local: '2026-08-01T20:00' },
      ],
      'UTC',
    );
    expect(out.map((s) => s.label)).toEqual(['Opener', 'Headliner']);
  });

  it('trims and truncates the label to 80 chars', () => {
    const long = 'x'.repeat(200);
    const out = normalizeSetTimes([{ label: `  ${long}  `, local: '2026-08-01T20:00' }], 'UTC');
    expect(out[0].label).toHaveLength(80);
  });

  it('drops unparseable times', () => {
    expect(normalizeSetTimes([{ label: 'Bad', local: 'not-a-date' }], 'UTC')).toEqual([]);
  });

  it('caps the number of set times', () => {
    const rows: SetTimeRow[] = Array.from({ length: MAX_SET_TIMES + 5 }, (_, i) => ({
      label: `Act ${i}`,
      local: `2026-08-01T${String(i % 24).padStart(2, '0')}:00`,
    }));
    expect(normalizeSetTimes(rows, 'UTC').length).toBe(MAX_SET_TIMES);
  });
});

describe('setTimesToRows', () => {
  it('round-trips stored set times back to editor rows', () => {
    const stored = [{ label: 'Opener', at: Timestamp.fromDate(new Date('2026-08-01T20:00:00Z')) }];
    const rows = setTimesToRows(stored, 'UTC');
    expect(rows).toEqual([{ label: 'Opener', local: '2026-08-01T20:00' }]);
    // And normalizing the rows returns the original instant.
    expect(normalizeSetTimes(rows, 'UTC')[0].at).toBe('2026-08-01T20:00:00.000Z');
  });

  it('returns [] for empty/undefined input', () => {
    expect(setTimesToRows(undefined, 'UTC')).toEqual([]);
    expect(setTimesToRows([], 'UTC')).toEqual([]);
  });
});
